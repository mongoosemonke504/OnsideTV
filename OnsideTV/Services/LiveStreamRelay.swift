import Foundation

/// Feeds a live stream to Picture in Picture through the app itself.
///
/// AVPlayer reading a provider directly sits close to live with little in
/// hand, and any late or refused segment is a pause. Here the app downloads
/// the segments, trying again when one fails, keeps some back in reserve and
/// hands them over on time from the phone. A provider that goes quiet for a
/// while is covered by what is in hand.
///
/// Plain transport-stream HLS only, which is what IPTV lines serve. Anything
/// else answers nil and is left to AVPlayer.
nonisolated final class LiveStreamRelay: @unchecked Sendable {
    private struct Segment {
        let number: Int
        let file: URL
        let duration: Double
        let discontinuity: Bool
    }

    private let source: URL
    private let folder: URL
    private let session: URLSession
    private let lock = NSLock()

    // Under `lock`.
    private var segments: [Segment] = []
    /// How many of `segments` the player has been told about.
    private var published = 0
    private var lastPublish = Date.distantPast
    private var target = 10
    private var reserve = 0.0
    private var unsupported = false
    private var opened = false
    private var lastArrival = Date()
    private var task: Task<Void, Never>?

    private var server: LocalStreamServer!

    /// Segments kept for the player to fall back on, published ones included.
    private static let keep = 24
    /// How far behind live to start, when the provider's list reaches that far.
    private static let startBehind = 30.0
    /// The most to hold back from the player, so the list it polls keeps
    /// moving while the provider doesn't.
    private static let longestReserve = 12.0

    /// Video in hand before the window is opened.
    private static let enoughToStart = 8.0

    init(source: URL) {
        self.source = source
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pip-\(UUID().uuidString)")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = ["User-Agent": "com.apple.avfoundation.videoplayer (iPhone; iOS 17.5.1; Scale/3.00)"]
        session = URLSession(configuration: config)
        server = LocalStreamServer { [weak self] path in self?.response(path) }
    }

    /// Clears what an earlier session left behind if the app was killed.
    static func removeLeftovers() {
        let temp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix("pip-") {
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }

    /// Starts downloading, and answers once there is enough to play. Nil if
    /// this isn't a stream it can carry, or the provider gave nothing for
    /// `quiet` seconds. Once video is arriving it never gives up on it: slow
    /// is not the same as refused.
    func start(quiet: TimeInterval) async -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let work = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run() ?? ()
        }
        lock.withLock {
            task = work
            lastArrival = Date()
        }
        while !Task.isCancelled {
            let (ready, refused, stopped, idle) = lock.withLock {
                (opened, unsupported, task == nil, Date().timeIntervalSince(lastArrival))
            }
            if refused || stopped || idle > quiet { break }
            if ready { return await server.start() }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        stop()
        return nil
    }

    /// Not a kind of stream this can carry.
    var isUnsupported: Bool { lock.withLock { unsupported } }

    /// The provider is letting it read.
    var hasData: Bool { lock.withLock { !segments.isEmpty } }

    /// A fresh address for the same stream: iOS closes the listener if it
    /// suspends the app.
    func restartServer() async -> URL? { await server.start() }

    func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
        server.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Downloading

    private struct Playlist {
        var target = 10
        var sequence = 0
        var segments: [(url: URL, duration: Double, discontinuity: Bool)] = []
        var base: URL
    }

    private enum PlaylistError: Error { case notPlain }

    private func run() async {
        // Here, not in `stop()`: a request made on an invalidated session is a
        // crash, and only this loop makes them.
        defer { session.finishTasksAndInvalidate() }
        var last: Int?
        var number = 0
        var failures = 0
        var gap = false
        while !Task.isCancelled {
            let playlist: Playlist
            do {
                playlist = try await fetchPlaylist()
                failures = 0
            } catch PlaylistError.notPlain {
                lock.withLock { unsupported = true }
                return
            } catch {
                failures += 1
                await pause(min(0.5 * Double(failures), 3))
                continue
            }
            let count = playlist.segments.count
            guard count > 0 else { await pause(1); continue }
            let newest = playlist.sequence + count - 1

            if last == nil {
                // Join some way back, so there is something in hand at once.
                var behind = 0.0
                var first = count
                while first > 0, behind < Self.startBehind {
                    first -= 1
                    behind += playlist.segments[first].duration
                }
                last = playlist.sequence + first - 1
                lock.withLock {
                    target = playlist.target
                    reserve = min(Self.longestReserve, behind * 0.4)
                }
            } else if let seen = last, newest < seen - 1 || playlist.sequence > seen + 1 {
                // The provider started its numbering over, or moved on past
                // what we had.
                last = newest < seen - 1 ? newest - 1 : playlist.sequence - 1
                gap = true
            }

            var added = false
            for i in 0..<count {
                let sequence = playlist.sequence + i
                guard sequence > last!, !Task.isCancelled else { continue }
                let entry = playlist.segments[i]
                if let data = await download(entry.url) {
                    let file = folder.appendingPathComponent("\(number).ts")
                    if (try? data.write(to: file)) != nil {
                        add(Segment(number: number, file: file, duration: entry.duration,
                                    discontinuity: gap || entry.discontinuity))
                        number += 1
                        gap = false
                        added = true
                    }
                } else {
                    gap = true
                }
                last = sequence
            }
            // Everything the list had at the start is in hand.
            lock.withLock { if !segments.isEmpty { opened = true } }
            await pause(added ? min(Double(playlist.target) * 0.5, 4) : min(Double(playlist.target) * 0.25, 1.5))
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func fetchPlaylist() async throws -> Playlist {
        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // A stream that isn't HLS never ends: read the first of it, not all.
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count == 7, data != Data("#EXTM3U".utf8), data.prefix(3) != Data([0xEF, 0xBB, 0xBF]) { throw PlaylistError.notPlain }
            if data.count > 512_000 { throw PlaylistError.notPlain }
        }
        guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else { throw URLError(.cannotParseResponse) }
        for tag in ["#EXT-X-STREAM-INF", "#EXT-X-MAP", "#EXT-X-BYTERANGE", "#EXT-X-PART", "#EXT-X-ENDLIST"] where text.contains(tag) {
            throw PlaylistError.notPlain
        }
        if text.contains("#EXT-X-KEY"), !text.contains("METHOD=NONE") { throw PlaylistError.notPlain }

        var playlist = Playlist(base: response.url ?? source)
        var duration = 0.0
        var discontinuity = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                playlist.target = max(1, Int(line.dropFirst(22).trimmingCharacters(in: .whitespaces)) ?? 10)
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                playlist.sequence = Int(line.dropFirst(22).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst(8).prefix(while: { $0 != "," })) ?? Double(playlist.target)
            } else if line == "#EXT-X-DISCONTINUITY" {
                discontinuity = true
            } else if !line.hasPrefix("#"), !line.isEmpty {
                if let url = URL(string: line, relativeTo: playlist.base)?.absoluteURL {
                    playlist.segments.append((url, duration > 0 ? duration : Double(playlist.target), discontinuity))
                    discontinuity = false
                }
            }
        }
        return playlist
    }

    private func download(_ url: URL) async -> Data? {
        for attempt in 0..<4 {
            if Task.isCancelled { return nil }
            if let (data, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true,
               data.count > 188, data.first == 0x47 || data.prefix(3) == Data("ID3".utf8) {
                return data
            }
            await pause(0.4 * Double(attempt + 1))
        }
        return nil
    }

    private func add(_ segment: Segment) {
        lock.withLock {
            segments.append(segment)
            lastArrival = Date()
            // Enough to start on; the rest of the list follows while it plays.
            if segments.reduce(0, { $0 + $1.duration }) >= Self.enoughToStart { opened = true }
            while segments.count > Self.keep, published > 8 {
                try? FileManager.default.removeItem(at: segments.removeFirst().file)
                published -= 1
            }
        }
    }

    // MARK: Serving

    private func response(_ path: String) -> LocalStreamServer.Response? {
        lock.lock()
        defer { lock.unlock() }
        if path == "index.m3u8" {
            publish()
            return .init(type: "application/vnd.apple.mpegurl", body: Data(playlist().utf8))
        }
        guard path.hasSuffix(".ts"), let number = Int(path.dropLast(3)),
              let segment = segments.first(where: { $0.number == number }),
              let data = try? Data(contentsOf: segment.file) else { return nil }
        return .init(type: "video/mp2t", body: data)
    }

    /// Moves on what the player may see: everything past the reserve at once,
    /// and from the reserve itself one segment at a time, as it comes due.
    private func publish() {
        func held() -> Double { segments[published...].reduce(0) { $0 + $1.duration } }
        func given() -> Double { segments[..<published].reduce(0) { $0 + $1.duration } }
        let now = Date()
        while published < segments.count, held() - segments[published].duration >= reserve || given() < Self.enoughToStart {
            published += 1
            lastPublish = now
        }
        if published < segments.count, published > 0,
           now.timeIntervalSince(lastPublish) >= segments[published - 1].duration {
            published += 1
            lastPublish = now
        }
    }

    private func playlist() -> String {
        let visible = segments.prefix(published)
        let longest = Int((visible.map(\.duration).max() ?? 0).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(max(target, longest))",
                     "#EXT-X-MEDIA-SEQUENCE:\(visible.first?.number ?? 0)"]
        for segment in visible {
            if segment.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            lines.append(String(format: "#EXTINF:%.3f,", locale: Locale(identifier: "en_US_POSIX"), segment.duration))
            lines.append("\(segment.number).ts")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
