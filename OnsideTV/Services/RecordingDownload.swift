import Foundation

/// Downloads a live stream into a file, for as long as it is left running.
///
/// Nothing that goes wrong on the way ends it: a refused connection, a dropped
/// one, a segment that won't come. It tries again, waiting a little longer each
/// time, because a recording can't be made twice. Only a full disk stops it.
actor RecordingDownload {
    private let source: URL
    private let output: URL
    private let session: URLSession
    private var handle: FileHandle?
    private var task: Task<Void, Never>?

    /// When something last reached the file.
    private(set) var lastWrite: Date?
    /// The disk is full, or the file can't be written to.
    private(set) var writeFailed = false

    private struct CannotWrite: Error {}
    private struct NotAStream: Error {}

    init(source: URL, output: URL) {
        self.source = source
        self.output = output
        let config = URLSessionConfiguration.ephemeral
        // Between packets, not in all: a live stream is never finished.
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "com.apple.avfoundation.videoplayer (iPhone; iOS 17.5.1; Scale/3.00)",
            "Accept": "*/*"
        ]
        session = URLSession(configuration: config)
    }

    func start() {
        guard task == nil else { return }
        task = Task(priority: .userInitiated) { await self.run() }
    }

    /// Ends the download. The file is complete and closed when this returns.
    func stop() async {
        task?.cancel()
        await task?.value
        task = nil
    }

    // MARK: Running

    private func run() async {
        defer {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
            session.invalidateAndCancel()
        }
        if !FileManager.default.fileExists(atPath: output.path) {
            FileManager.default.createFile(atPath: output.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: output)
        _ = try? handle?.seekToEnd()
        guard handle != nil else { writeFailed = true; return }

        var failures = 0
        while !Task.isCancelled {
            let before = lastWrite
            do {
                try await connect()
            } catch is CannotWrite {
                writeFailed = true
                return
            } catch {
                print("⚠️ [Recording] \(error.localizedDescription). Trying again.")
            }
            // Something came before it broke: start the waiting over.
            failures = lastWrite != before ? 0 : failures + 1
            await pause(min(0.5 * pow(2, Double(min(failures, 5))), 10))
        }
    }

    /// Opens the stream and finds out what it is from what it sends first. A
    /// playlist is followed; anything else is the video itself and is written
    /// down as it comes.
    private func connect() async throws {
        let fetch = StreamFetch(session: session, url: source)
        defer { fetch.cancel() }
        var head = Data()
        var direct = false
        for try await chunk in fetch.chunks {
            if direct {
                try write(chunk)
                continue
            }
            head.append(chunk)
            guard head.count >= 16 else { continue }
            if Self.isPlaylist(head) {
                if head.count > 2_000_000 { throw NotAStream() }
                continue
            }
            // An error page, not a stream.
            guard !Self.isText(head) else { throw NotAStream() }
            direct = true
            try write(head)
            head = Data()
        }
        guard !direct else { return }
        guard Self.isPlaylist(head) else { throw NotAStream() }
        try await follow(Self.parse(head, base: fetch.finalURL ?? source))
    }

    private static func isPlaylist(_ data: Data) -> Bool {
        var start = data.prefix(16)
        if start.prefix(3) == Data([0xEF, 0xBB, 0xBF]) { start = start.dropFirst(3) }
        while let first = start.first, first <= 0x20 { start = start.dropFirst() }
        return start.prefix(7) == Data("#EXTM3U".utf8)
    }

    private static func isText(_ data: Data) -> Bool {
        data.prefix(16).first(where: { $0 > 0x20 }).map { $0 == UInt8(ascii: "<") || $0 == UInt8(ascii: "{") } ?? true
    }

    // MARK: HLS

    private struct Segment {
        let url: URL
        let sequence: Int
        let map: URL?
    }

    private struct Playlist {
        var target = 10.0
        var sequence = 0
        var segments: [Segment] = []
        /// The best of the qualities, when this only lists them.
        var variant: URL?
        var ended = false
    }

    private static func parse(_ data: Data, base: URL) -> Playlist {
        var playlist = Playlist()
        let text = String(decoding: data, as: UTF8.self)
        var bandwidth = -1
        var pending: Int?
        var map: URL?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                playlist.target = Double(line.dropFirst(22)) ?? 10
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                playlist.sequence = Int(line.dropFirst(22).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = line.range(of: "[:,]BANDWIDTH=[0-9]+", options: .regularExpression)
                    .flatMap { Int(line[$0].drop(while: { !$0.isNumber })) } ?? 0
            } else if line.hasPrefix("#EXT-X-MAP:") {
                if let r = line.range(of: "URI=\"[^\"]+\"", options: .regularExpression) {
                    map = URL(string: String(line[r].dropFirst(5).dropLast()), relativeTo: base)?.absoluteURL
                }
            } else if line == "#EXT-X-ENDLIST" {
                playlist.ended = true
            } else if !line.hasPrefix("#"), !line.isEmpty, let url = URL(string: line, relativeTo: base)?.absoluteURL {
                if let rate = pending {
                    if rate > bandwidth { bandwidth = rate; playlist.variant = url }
                    pending = nil
                } else {
                    playlist.segments.append(Segment(url: url, sequence: playlist.sequence + playlist.segments.count, map: map))
                }
            }
        }
        return playlist
    }

    // Kept across reconnects, so none of it is recorded twice.
    private var lastSequence: Int?
    private var recent: [URL] = []
    private var writtenMap: URL?

    /// Keeps up with a live playlist. A segment that fails goes back in line
    /// and is tried again until it comes or the provider has dropped it, and
    /// everything is written in order whatever order it took.
    private func follow(_ first: Playlist) async throws {
        var address = source
        var playlist = first
        if let variant = playlist.variant {
            address = variant
            playlist = try await fetchPlaylist(variant)
        }
        var queue: [Segment] = []
        var attempts = 0
        var nextPoll = Date.distantPast
        var pollFailures = 0
        var fresh = true

        while !Task.isCancelled {
            if fresh || Date() >= nextPoll {
                do {
                    if !fresh { playlist = try await fetchPlaylist(address) }
                    pollFailures = 0
                } catch {
                    pollFailures += 1
                    // The address itself may have gone stale (a redirect's
                    // token does): go back and ask for a new one, once what
                    // is already in line has been fetched.
                    if pollFailures > 5, queue.isEmpty { throw error }
                }
                if pollFailures == 0 { enqueue(playlist, into: &queue) }
                fresh = false
                nextPoll = Date().addingTimeInterval(pollFailures > 0 ? min(Double(pollFailures) * 0.7, 4)
                                                                      : min(max(playlist.target * 0.4, 1), 5))
            }

            guard let segment = queue.first else {
                if playlist.ended { return try await idle() }
                await pause(max(0.2, nextPoll.timeIntervalSinceNow))
                continue
            }
            do {
                if let map = segment.map, map != writtenMap {
                    try write(try await fetchMedia(map))
                    writtenMap = map
                }
                try write(try await fetchMedia(segment.url))
                queue.removeFirst()
                attempts = 0
            } catch let error as CannotWrite {
                throw error
            } catch {
                if Task.isCancelled { return }
                attempts += 1
                // Long gone from the list, or it was never going to come.
                let expired = segment.sequence < playlist.sequence - 2
                if attempts >= 8 || (attempts >= 3 && expired) {
                    print("⚠️ [Recording] Segment lost after \(attempts) tries.")
                    queue.removeFirst()
                    attempts = 0
                } else {
                    await pause(min(0.4 * Double(attempts), 2.5))
                }
            }
        }
    }

    private func enqueue(_ playlist: Playlist, into queue: inout [Segment]) {
        guard let newest = playlist.segments.last?.sequence else { return }
        if let last = lastSequence, newest < last - 5 {
            // The provider started its numbering over. (A step or two back is
            // only an old copy of the list.)
            lastSequence = nil
            recent = []
        }
        // Joining: the last few, not hours of a list that reaches back.
        if lastSequence == nil, !playlist.ended, playlist.segments.count > 6 {
            lastSequence = newest - 4
        }
        for segment in playlist.segments where segment.sequence > (lastSequence ?? Int.min) {
            lastSequence = segment.sequence
            guard !recent.contains(segment.url) else { continue }
            recent.append(segment.url)
            queue.append(segment)
        }
        if recent.count > 200 { recent.removeFirst(recent.count - 200) }
    }

    /// A finished playlist has nothing more to give; wait to be stopped.
    private func idle() async throws {
        while !Task.isCancelled { await pause(5) }
    }

    private func fetchPlaylist(_ url: URL) async throws -> Playlist {
        let (data, response) = try await session.data(from: url)
        guard Self.ok(response) else { throw URLError(.badServerResponse) }
        guard Self.isPlaylist(data) else { throw NotAStream() }
        return Self.parse(data, base: response.url ?? url)
    }

    private func fetchMedia(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard Self.ok(response) else { throw URLError(.badServerResponse) }
        guard !data.isEmpty, !Self.isText(data) else { throw NotAStream() }
        return data
    }

    private static func ok(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
    }

    // MARK: Writing

    private func write(_ data: Data) throws {
        do {
            try handle?.write(contentsOf: data)
            lastWrite = Date()
        } catch {
            print("❌ [Recording] Couldn't write: \(error.localizedDescription)")
            throw CannotWrite()
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// One request, handed over as it arrives.
nonisolated private final class StreamFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let task: URLSessionDataTask
    private let lock = NSLock()
    private var landed: URL?

    /// Where redirects ended up.
    var finalURL: URL? { lock.withLock { landed } }

    init(session: URLSession, url: URL) {
        (chunks, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        task = session.dataTask(with: url)
        super.init()
        task.delegate = self
        let task = task
        continuation.onTermination = { _ in task.cancel() }
        task.resume()
    }

    func cancel() { task.cancel() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { landed = response.url }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation.finish(throwing: URLError(.badServerResponse))
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
