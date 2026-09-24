import Foundation
import Network

/// A tiny in-process HTTP/1.1 server on 127.0.0.1 (random port), built on
/// Network.framework, for tests that need a real socket: AVPlayer loads media
/// with its own loader, so the URLProtocol stubs used elsewhere never see its
/// requests. One request per connection (`Connection: close`); `Range:
/// bytes=a-b` is honoured with a 206. Every request is recorded.
///
/// Reusable: give it a handler that maps a request to a response.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        /// Path without the query.
        let path: String
        let query: String?
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        var status: Int
        var contentType: String
        var body: Data
        var delay: TimeInterval = 0

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(status: status, contentType: "application/json", body: Data(text.utf8))
        }
        static let notFound = Response.json(#"{"error":"Not found"}"#, status: 404)
    }

    typealias Handler = @Sendable (Request) -> Response

    private let queue = DispatchQueue(label: "PigTVTests.LocalHTTPServer")
    private let listener: NWListener
    private let handler: Handler
    private let lock = NSLock()
    private var recorded: [Request] = []
    private(set) var port: UInt16 = 0

    /// Starts listening; returns once the port is known.
    init(handler: @escaping Handler) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let failure = Locked<NWError?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure.value = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw URLError(.cannotConnectToHost) }
        if let error = failure.value { throw error }
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }

    func stop() { listener.cancel() }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    var requests: [Request] { lock.withLock { recorded } }

    func requests(path: String, method: String? = nil) -> [Request] {
        requests.filter { $0.path == path && (method == nil || $0.method == method) }
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.withLock { self.recorded.append(request) }
                self.respond(to: request, on: connection)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) {
        var response = handler(request)
        var status = response.status
        var extra = ""
        // Byte ranges, for players that ask for part of a file.
        if status == 200, let range = request.headers["range"], let bounds = Self.byteRange(range, size: response.body.count) {
            extra = "Content-Range: bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(response.body.count)\r\n"
            response.body = response.body.subdata(in: bounds.lowerBound..<(bounds.upperBound + 1))
            status = 206
        }
        let head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n" +
            "Content-Type: \(response.contentType)\r\n" +
            "Content-Length: \(response.body.count)\r\n" +
            "Accept-Ranges: bytes\r\n" + extra +
            "Cache-Control: no-cache\r\n" +
            "Connection: close\r\n\r\n"
        let payload = Data(head.utf8) + (request.method == "HEAD" ? Data() : response.body)
        let send = {
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }
        if response.delay > 0 { queue.asyncAfter(deadline: .now() + response.delay, execute: send) } else { send() }
    }

    /// A complete request (head plus Content-Length body), or nil to read more.
    static func parse(_ data: Data) -> Request? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = split.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        let target = String(parts[1])
        let pieces = target.split(separator: "?", maxSplits: 1).map(String.init)
        return Request(method: String(parts[0]), path: pieces.first ?? target,
                       query: pieces.count > 1 ? pieces[1] : nil, headers: headers, body: body)
    }

    static func byteRange(_ header: String, size: Int) -> ClosedRange<Int>? {
        guard size > 0, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first ?? ""
        let ends = spec.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard ends.count == 2 else { return nil }
        let lower: Int
        let upper: Int
        switch (ends[0], ends[1]) {
        case let (start?, end?): lower = start; upper = min(end, size - 1)
        case let (start?, nil): lower = start; upper = size - 1
        case let (nil, suffix?): lower = max(0, size - suffix); upper = size - 1
        default: return nil
        }
        guard lower <= upper, lower < size else { return nil }
        return lower...upper
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 409: return "Conflict"
        default: return "Status"
        }
    }
}

/// A value shared across queues in tests.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
