import Foundation

public struct RVPResponse: Sendable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public enum RVPClientError: Error, LocalizedError, Sendable {
    case authenticationFailed
    case unexpectedStatus(method: String, status: Int)
    case noLocalAddress(host: String)
    case notSignedIn
    case listenerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "The server rejected the user name or password."
        case .unexpectedStatus(let m, let s):
            return "\(m) failed with HTTP \(s)."
        case .noLocalAddress(let h):
            return "Could not find a local network address that reaches \(h). Check that this device is on the same network as the server."
        case .notSignedIn:
            return "Not signed in."
        case .listenerFailed(let why):
            return "Could not open the local port the server calls back on: \(why)"
        }
    }
}

/// Sends RVP requests (custom HTTP methods) through URLSession.
///
/// Authentication: URLSession performs the NTLM, Digest and Basic handshakes
/// natively on Apple platforms when given a URLCredential.
/// GUESS / RISK: URLSession has not been verified against Exchange 2000 with
/// RVP's non-standard methods (SUBSCRIBE, NOTIFY...). If NTLM fails while the
/// same credentials work in Windows Messenger, a raw-socket transport with a
/// hand-rolled NTLM implementation is the fallback (see PROTOCOL.md).
final class RVPHTTPClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let user: String
    private let password: String
    private var session: URLSession!

    init(user: String, password: String) {
        self.user = user
        self.password = password
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpShouldUsePipelining = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func send(_ method: String, to url: URL, headers: [String: String], body: Data? = nil,
              notificationsVersion: String) async throws -> RVPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(notificationsVersion, forHTTPHeaderField: RVPHeader.notificationsVersion)
        req.setValue("RVPKit/0.1", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        // Always send a body so URLSession emits Content-Length (RVP examples send
        // "Content-Length: 0" on body-less requests). GUESS: URLSession may still drop
        // a zero-length header for custom methods; IIS would then answer 411.
        req.httpBody = body ?? Data()

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw RVPClientError.unexpectedStatus(method: method, status: -1)
        }
        var hdrs: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { hdrs[k.lowercased()] = v }
        }
        if http.statusCode == 401 { throw RVPClientError.authenticationFailed }
        return RVPResponse(status: http.statusCode, headers: hdrs, body: data)
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        switch method {
        case NSURLAuthenticationMethodNTLM,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodHTTPBasic:
            if challenge.previousFailureCount >= 2 {
                // Let the 401 through so the caller sees authenticationFailed.
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.useCredential,
                                  URLCredential(user: user, password: password, persistence: .forSession))
            }
        case NSURLAuthenticationMethodNegotiate:
            // IIS offers "Negotiate" before "NTLM". Kerberos will not work off-domain,
            // so skip it and let URLSession fall through to NTLM.
            completionHandler(.rejectProtectionSpace, nil)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
