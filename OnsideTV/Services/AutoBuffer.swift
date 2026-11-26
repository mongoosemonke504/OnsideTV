import Foundation

/// The player's buffer when Auto Buffer is on.
///
/// Every channel opens on ten seconds, as Auto always did. One that stalls
/// is given more the next time it opens, up to twenty, and one that then
/// plays smoothly for a while gets some of it back.
nonisolated enum AutoBuffer {
    static let shortest = 10000
    static let longest = 20000
    private static let stallStep = 3000
    private static let smoothStep = 1000
    private static let key = "autoBufferByChannel"
    private static let lock = NSLock()

    /// Milliseconds of buffer for this stream.
    static func milliseconds(for stream: URL?) -> Int {
        guard let id = stream.map(channelKey) else { return shortest }
        return lock.withLock { stored()[id] } ?? shortest
    }

    /// It stopped to buffer while playing.
    static func noteStall(_ stream: URL?) { adjust(stream, by: stallStep) }

    /// It has played a good while without stopping.
    static func noteSmooth(_ stream: URL?) { adjust(stream, by: -smoothStep) }

    private static func adjust(_ stream: URL?, by change: Int) {
        guard let id = stream.map(channelKey) else { return }
        lock.withLock {
            var all = stored()
            let value = min(longest, max(shortest, (all[id] ?? shortest) + change))
            if value == shortest { all.removeValue(forKey: id) } else { all[id] = value }
            // Only channels that needed more are kept, so this stays small.
            if all.count > 400 { all = Dictionary(uniqueKeysWithValues: all.sorted { $0.value > $1.value }.prefix(300).map { ($0.key, $0.value) }) }
            UserDefaults.standard.set(all, forKey: key)
        }
    }

    private static func stored() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    /// A hash, so no stream address (and the login in it) is saved.
    private static func channelKey(_ url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 36)
    }
}
