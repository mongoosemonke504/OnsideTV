import Foundation
import Network

/// A tiny HTTP server on the phone's own loopback interface, for handing
/// AVPlayer things it can only take over HTTP. Nothing outside the phone can
/// reach it.
nonisolated final class LocalStreamServer: @unchecked Sendable {
    struct Response: Sendable {
        let type: String
        let body: Data
    }

    private let queue = DispatchQueue(label: "local.stream.server", qos: .userInitiated)
    private let handler: @Sendable (String) -> Response?
    /// In the path, so no other app can guess its way in.
    private let token = UUID().uuidString
    private let lock = NSLock()
    private var listener: NWListener?

    init(handler: @escaping @Sendable (String) -> Response?) { self.handler = handler }
    deinit { listener?.cancel() }

    /// Starts listening, on a new port if it already was, and answers with the
    /// address of `index.m3u8`.
    func start() async -> URL? {
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        lock.withLock { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, Data())
        }
        let port: UInt16? = await withCheckedContinuation { continuation in
            let answered = Flag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if answered.set() { continuation.resume(returning: listener.port?.rawValue) }
                case .failed, .cancelled:
                    if answered.set() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/\(token)/index.m3u8")
    }

    func stop() {
        lock.withLock {
            listener?.cancel()
            listener = nil
        }
    }

    /// Only ever touched on the server's queue.
    private final class Flag: @unchecked Sendable {
        private var value = false
        func set() -> Bool { defer { value = true }; return !value }
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var request = buffer
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, request)
            } else if done || error != nil || request.count > 32_768 {
                connection.cancel()
            } else {
                self.receive(connection, request)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ request: Data) {
        let line = String(decoding: request.prefix(while: { $0 != 0x0D }), as: UTF8.self).split(separator: " ")
        var response: Response?
        if line.count > 1, line[0] == "GET" || line[0] == "HEAD" {
            let parts = line[1].split(separator: "/")
            if parts.count == 2, parts[0] == token { response = handler(String(parts[1])) }
        }
        let status = response == nil ? "404 Not Found" : "200 OK"
        let body = response?.body ?? Data()
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(response?.type ?? "text/plain")\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        if line.first != "HEAD" { out.append(body) }
        connection.send(content: out, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
