import Foundation
import Network

/// An HTTP request the Exchange server sent to our Call-Back URL.
public struct RVPIncomingRequest: Sendable {
    public var method: String
    public var path: String
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data
}

/// Tiny HTTP/1.1 listener for RVP callbacks.
///
/// RVP is push-by-callback: at sign-in the client SUBSCRIBEs to its own principal
/// with `Call-Back: http://<client-ip>:<port>`, and the server then opens TCP
/// connections to that address and sends NOTIFY requests (messages, presence).
/// This server parses each request, answers `200 Successful`, and hands it on.
final class RVPCallbackServer: @unchecked Sendable {
    typealias Handler = @Sendable (RVPIncomingRequest) -> Void

    private let queue = DispatchQueue(label: "RVPCallbackServer")
    private var listener: NWListener?
    private let handler: Handler
    private let notificationsVersion: String

    init(notificationsVersion: String, handler: @escaping Handler) {
        self.notificationsVersion = notificationsVersion
        self.handler = handler
    }

    /// Starts listening. Pass 0 for an ephemeral port. Returns the bound port.
    func start(port: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        return try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume(returning: listener.port?.rawValue ?? port) }
                case .failed(let err):
                    if once.claim() { cont.resume(throwing: RVPClientError.listenerFailed(err.localizedDescription)) }
                case .cancelled:
                    if once.claim() { cont.resume(throwing: RVPClientError.listenerFailed("cancelled")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(on: conn, buffer: Data())
    }

    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            // Process as many complete requests as the buffer holds (keep-alive).
            while case let (req, consumed, wantsContinue)? = Self.parseRequest(buf) {
                if wantsContinue && req == nil {
                    conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                    break
                }
                guard let req else { break }
                buf = Data(buf.dropFirst(consumed))
                self.respond(on: conn)
                self.handler(req)
            }
            if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receive(on: conn, buffer: buf)
            }
        }
    }

    private func respond(on conn: NWConnection) {
        let reply = "HTTP/1.1 200 Successful\r\n"
            + "\(RVPHeader.notificationsVersion): \(notificationsVersion)\r\n"
            + "Content-Length: 0\r\n\r\n"
        conn.send(content: Data(reply.utf8), completion: .idempotent)
    }

    /// Returns (request, bytesConsumed, expects100Continue) when the header block is
    /// complete. `request` is nil while the body is still incomplete.
    static func parseRequest(_ buf: Data) -> (RVPIncomingRequest?, Int, Bool)? {
        let sep = Data("\r\n\r\n".utf8)
        guard let headerEnd = buf.range(of: sep) else { return nil }
        let headerText = String(decoding: buf[buf.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        let available = buf.endIndex - bodyStart
        if available < length {
            let expects = headers["expect"]?.lowercased() == "100-continue" && available == 0
            return expects ? (nil, 0, true) : nil
        }
        let body = buf[bodyStart..<(bodyStart + length)]
        let req = RVPIncomingRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                                     headers: headers, body: Data(body))
        return (req, bodyStart + length - buf.startIndex, false)
    }
}

/// Thread-safe one-shot flag (state handlers run on a dispatch queue).
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
