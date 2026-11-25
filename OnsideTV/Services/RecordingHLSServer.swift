import Foundation
import Network

/// Lets AVPlayer, and so Picture in Picture, play a recording.
///
/// A recording is a raw MPEG-TS file. VLC plays those; AVPlayer won't open one
/// at all, but it does play the very same data as HLS. So this cuts the file
/// into segments where its keyframes are and serves them, with a playlist, to
/// the app itself over the loopback interface. Nothing is re-encoded or copied
/// on disk, and nothing outside the phone can reach it.
nonisolated final class RecordingHLSServer: @unchecked Sendable {

    // MARK: Index

    struct Segment: Sendable {
        let offset: Int
        let length: Int
        let duration: Double
        /// The stream's clock jumps here (the recorder reconnected).
        let discontinuity: Bool
    }

    struct Index: Sendable {
        let file: URL
        /// The program tables, put in front of every segment: each has to
        /// stand on its own, and the file only repeats them now and then.
        let tables: Data
        let segments: [Segment]
        var duration: Double { segments.reduce(0) { $0 + $1.duration } }

        var playlist: String {
            let target = Int((segments.map(\.duration).max() ?? 10).rounded(.up))
            var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(max(target, 1))",
                         "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"]
            for (i, segment) in segments.enumerated() {
                if segment.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
                lines.append(String(format: "#EXTINF:%.3f,", locale: Locale(identifier: "en_US_POSIX"), segment.duration))
                lines.append("\(i).ts")
            }
            lines.append("#EXT-X-ENDLIST")
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// Reads the file just enough to know where to cut it. Off the main thread.
    static func index(file: URL) async -> Index? {
        await Task.detached(priority: .userInitiated) { buildIndex(file: file) }.value
    }

    private static let packet = 188
    private static let clock: Double = 90_000
    private static let wrap: Int64 = 1 << 33
    private static let targetDuration: Double = 6
    /// Keyframes further apart than this on the clock didn't follow each other.
    private static let longestGap: Double = 20

    private struct Keyframe { let offset: Int; let pts: Int64 }

    private static func buildIndex(file: URL) -> Index? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped), data.count > packet * 20 else { return nil }
        return data.withUnsafeBytes { raw -> Index? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let count = raw.count
            guard let tables = findTables(base, count) else { return nil }
            let videoPID = tables.videoPID
            let hevc = tables.hevc
            // AVPlayer plays the sound of HEVC in a transport stream and shows
            // no picture, so there is nothing to float.
            guard !hevc else { return nil }

            func next(from: Int, to end: Int) -> Keyframe? {
                nextKeyframe(base, count, from: from, to: end, pid: videoPID, hevc: hevc)
            }
            func seconds(_ a: Keyframe, _ b: Keyframe) -> Double {
                Double((b.pts - a.pts + wrap) % wrap) / clock
            }

            guard let first = next(from: 0, to: count) else { return nil }
            // How much to jump over between cuts, from the first stretch.
            var skip = 0
            do {
                var last = first
                while seconds(first, last) < 4, let n = next(from: last.offset + packet, to: count) {
                    let gap = seconds(last, n)
                    guard gap > 0, gap < longestGap else { break }
                    last = n
                }
                let span = seconds(first, last)
                if span > 0 {
                    let rate = Double(last.offset - first.offset) / span
                    // Short of the target, so the next keyframe lands near it.
                    skip = Int(rate * targetDuration * 0.7) / packet * packet
                }
            }

            var segments: [Segment] = []
            var start = first
            var startsAfterJump = false
            while true {
                let cut = next(from: min(start.offset + max(skip, packet), count), to: count)
                if let cut, case let length = seconds(start, cut), length > 0, length < longestGap {
                    segments.append(Segment(offset: start.offset, length: cut.offset - start.offset,
                                            duration: length, discontinuity: startsAfterJump))
                    start = cut
                    startsAfterJump = false
                    continue
                }
                // Either the end of the file, or the clock jumped somewhere in
                // this stretch: walk it keyframe by keyframe to find out.
                var last = start
                var jump: Keyframe?
                var step = 0.0
                while let n = next(from: last.offset + packet, to: count) {
                    let gap = seconds(last, n)
                    if gap <= 0 || gap >= longestGap { jump = n; break }
                    step = gap
                    last = n
                    if seconds(start, last) >= targetDuration { break }
                }
                if jump == nil, last.offset > start.offset, seconds(start, last) >= targetDuration {
                    segments.append(Segment(offset: start.offset, length: last.offset - start.offset,
                                            duration: seconds(start, last), discontinuity: startsAfterJump))
                    start = last
                    startsAfterJump = false
                    continue
                }
                if jump == nil {
                    // The last stretch runs to the last picture in the file.
                    var tail = max(start.offset, count - (2 << 20) / packet * packet)
                    while let n = nextKeyframe(base, count, from: tail, to: count, pid: videoPID, hevc: hevc, anyFrame: true) {
                        let length = seconds(start, n)
                        if length > seconds(start, last), length < 120 { last = n; step = 0.04 }
                        tail = n.offset + packet
                    }
                }
                let end = jump?.offset ?? count
                if end > start.offset {
                    segments.append(Segment(offset: start.offset, length: end - start.offset,
                                            duration: max(seconds(start, last) + (step > 0 ? step : 1), 0.5),
                                            discontinuity: startsAfterJump))
                }
                guard let jump else { break }
                start = jump
                startsAfterJump = true
            }
            guard !segments.isEmpty else { return nil }
            return Index(file: file, tables: tables.packets, segments: segments)
        }
    }

    /// The next packet boundary at or after `i`. A recording can break off
    /// mid-packet where the recorder reconnected.
    @inline(__always)
    private static func sync(_ p: UnsafePointer<UInt8>, _ count: Int, _ start: Int) -> Int? {
        var i = start
        while i + packet <= count {
            if p[i] == 0x47,
               i + packet >= count || p[i + packet] == 0x47,
               i + packet * 2 >= count || p[i + packet * 2] == 0x47 { return i }
            i += 1
        }
        return nil
    }

    /// The program tables and which stream in them is the video.
    private static func findTables(_ p: UnsafePointer<UInt8>, _ count: Int) -> (packets: Data, videoPID: Int, hevc: Bool)? {
        var pat: Data?
        var pmtPID: Int?
        var i = 0
        let limit = min(count, 40 << 20)
        while let at = sync(p, count, i), at < limit {
            i = at + packet
            let pid = Int(p[at + 1] & 0x1F) << 8 | Int(p[at + 2])
            guard pid == 0 || pid == pmtPID else { continue }
            guard p[at + 1] & 0x40 != 0, p[at + 3] & 0x10 != 0 else { continue }
            var body = at + 4
            if p[at + 3] & 0x20 != 0 { body += 1 + Int(p[body]) }
            guard body < at + packet else { continue }
            body += 1 + Int(p[body])
            let end = at + packet
            guard body + 12 < end else { continue }
            let sectionEnd = min(body + 3 + (Int(p[body + 1] & 0x0F) << 8 | Int(p[body + 2])) - 4, end)

            if pid == 0, p[body] == 0x00 {
                var e = body + 8
                while e + 4 <= sectionEnd {
                    let program = Int(p[e]) << 8 | Int(p[e + 1])
                    if program != 0 {
                        pmtPID = Int(p[e + 2] & 0x1F) << 8 | Int(p[e + 3])
                        pat = Data(bytes: p + at, count: packet)
                        break
                    }
                    e += 4
                }
            } else if pid == pmtPID, p[body] == 0x02, let pat {
                var e = body + 12 + (Int(p[body + 10] & 0x0F) << 8 | Int(p[body + 11]))
                while e + 5 <= sectionEnd {
                    let type = p[e]
                    if type == 0x1B || type == 0x24 || type == 0x02 {
                        let videoPID = Int(p[e + 1] & 0x1F) << 8 | Int(p[e + 2])
                        return (pat + Data(bytes: p + at, count: packet), videoPID, type == 0x24)
                    }
                    e += 5 + (Int(p[e + 3] & 0x0F) << 8 | Int(p[e + 4]))
                }
            }
        }
        return nil
    }

    private static func nextKeyframe(_ p: UnsafePointer<UInt8>, _ count: Int, from: Int, to end: Int,
                                     pid wanted: Int, hevc: Bool, anyFrame: Bool = false) -> Keyframe? {
        var i = from
        while i + packet <= end {
            if p[i] != 0x47 || (i + packet < count && p[i + packet] != 0x47) {
                guard let at = sync(p, count, p[i] == 0x47 ? i + 1 : i), at + packet <= end else { return nil }
                i = at
            }
            let at = i
            i += packet
            guard p[at + 1] & 0x40 != 0,
                  Int(p[at + 1] & 0x1F) << 8 | Int(p[at + 2]) == wanted,
                  p[at + 3] & 0x10 != 0 else { continue }
            var body = at + 4
            var randomAccess = false
            if p[at + 3] & 0x20 != 0 {
                let length = Int(p[body])
                if length > 0 { randomAccess = p[body + 1] & 0x40 != 0 }
                body += 1 + length
            }
            let stop = at + packet
            // A PES header with a timestamp.
            guard body + 14 <= stop, p[body] == 0, p[body + 1] == 0, p[body + 2] == 1, p[body + 7] & 0x80 != 0 else { continue }
            if anyFrame { randomAccess = true }
            if !randomAccess {
                // Not every encoder sets the flag. A keyframe carries its
                // parameter sets in front of it.
                var n = body + 9 + Int(p[body + 8])
                while n + 3 < stop {
                    if p[n] == 0, p[n + 1] == 0, p[n + 2] == 1 {
                        let type = hevc ? (p[n + 3] >> 1) & 0x3F : p[n + 3] & 0x1F
                        if hevc ? (type == 32 || type == 33 || (16...21).contains(type)) : (type == 7 || type == 5) {
                            randomAccess = true
                            break
                        }
                        n += 3
                    } else {
                        n += 1
                    }
                }
            }
            guard randomAccess else { continue }
            let t = body + 9
            let pts = Int64(p[t] & 0x0E) << 29 | Int64(p[t + 1]) << 22 | Int64(p[t + 2] & 0xFE) << 14
                | Int64(p[t + 3]) << 7 | Int64(p[t + 4]) >> 1
            return Keyframe(offset: at, pts: pts)
        }
        return nil
    }

    // MARK: Serving

    let index: Index
    private let server: LocalStreamServer

    init(index: Index) {
        self.index = index
        let playlist = Data(index.playlist.utf8)
        server = LocalStreamServer { path in
            if path == "index.m3u8" { return .init(type: "application/vnd.apple.mpegurl", body: playlist) }
            guard path.hasSuffix(".ts"), let number = Int(path.dropLast(3)), index.segments.indices.contains(number),
                  let handle = try? FileHandle(forReadingFrom: index.file) else { return nil }
            defer { try? handle.close() }
            let segment = index.segments[number]
            guard (try? handle.seek(toOffset: UInt64(segment.offset))) != nil,
                  let media = try? handle.read(upToCount: segment.length) else { return nil }
            return .init(type: "video/mp2t", body: index.tables + media)
        }
    }

    /// Starts (or restarts) serving and answers with the playlist's address.
    func start() async -> URL? { await server.start() }
    func stop() { server.stop() }
}
