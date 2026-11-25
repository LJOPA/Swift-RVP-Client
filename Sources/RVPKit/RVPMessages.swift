import Foundation

/// A sender or recipient in a notification (`<r:contact>`).
public struct RVPContactRef: Sendable, Hashable {
    public var principal: URL
    public var description: String?

    public init(principal: URL, description: String? = nil) {
        self.principal = principal
        self.description = description
    }
}

// MARK: - MIME payload carried in <r:mime-data>

/// The MIME-style block inside `<r:mime-data>`. Format confirmed from librvp:
///
///     MIME-Version: 1.0\r\n
///     Content-Type: text/plain; charset=UTF-8\r\n
///     X-MMS-IM-Format: FN=MS%20Shell%20Dlg; EF=; CO=0; CS=0; PF=0\r\n
///     Session-Id: {GUID}\r\n
///     \r\n
///     message text
public struct IMPayload: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text(String)
        /// `text/x-msmsgscontrol` with a `TypingUser` header.
        case typing(user: String)
        /// `text/x-msmsgsinvite` (file transfer etc.). Not supported in v1; body kept for logging.
        case invite(String)
        /// `text/x-imleave` (left a multi-party chat).
        case leave
        case other(contentType: String, body: String)
    }

    public var kind: Kind
    /// GUID without braces.
    public var sessionID: String
    public var format: String?

    public init(kind: Kind, sessionID: String, format: String? = nil) {
        self.kind = kind
        self.sessionID = sessionID
        self.format = format
    }

    public func serialize() -> String {
        var lines = ["MIME-Version: 1.0"]
        var body = ""
        switch kind {
        case .text(let text):
            lines.append("Content-Type: text/plain; charset=UTF-8")
            lines.append("X-MMS-IM-Format: \(format ?? RVPDefaults.imFormat)")
            body = text.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\n", with: "\r\n")
        case .typing(let user):
            lines.append("Content-Type: text/x-msmsgscontrol; charset=UTF-8")
            lines.append("TypingUser: \(user)")
        case .invite(let b):
            lines.append("Content-Type: text/x-msmsgsinvite; charset=UTF-8")
            body = b
        case .leave:
            lines.append("Content-Type: text/x-imleave; charset=UTF-8")
        case .other(let ct, let b):
            lines.append("Content-Type: \(ct)")
            body = b
        }
        lines.append("Session-Id: {\(sessionID)}")
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    public static func parse(_ raw: String) -> IMPayload? {
        // librvp accepts both CRLF and bare LF separators; so do we.
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let headerPart: Substring
        let body: String
        if let r = normalized.range(of: "\n\n") {
            headerPart = normalized[..<r.lowerBound]
            body = String(normalized[r.upperBound...])
        } else {
            headerPart = Substring(normalized)
            body = ""
        }
        var headers: [String: String] = [:]
        for line in headerPart.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentType = headers["content-type"] ?? "text/plain"
        let ct = contentType.lowercased()
        let sid = (headers["session-id"] ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
        let kind: Kind
        if ct.hasPrefix("text/plain") {
            kind = .text(body)
        } else if ct.hasPrefix("text/x-msmsgscontrol") {
            kind = .typing(user: headers["typinguser"] ?? "")
        } else if ct.hasPrefix("text/x-msmsgsinvite") {
            kind = .invite(body)
        } else if ct.hasPrefix("text/x-imleave") {
            kind = .leave
        } else {
            kind = .other(contentType: contentType, body: body)
        }
        return IMPayload(kind: kind, sessionID: sid, format: headers["x-mms-im-format"])
    }

    public static func newSessionID() -> String {
        UUID().uuidString.lowercased()
    }
}

// MARK: - Request bodies

enum RVPBody {
    static let prolog = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    static let rootNS = "xmlns:d=\"DAV:\" xmlns:r=\"\(RVPNamespace.rvp)\" xmlns:a=\"\(RVPNamespace.acl)\""

    /// PROPPATCH body that sets our presence. Shape copied from librvp:
    /// offline uses a short form without a lease (librvp notes a real server needs this).
    static func presence(_ state: PresenceState, lease: Int, viewID: String?) -> Data {
        let view = viewID.map { "<r:view-id>\(XMLText.escape($0))</r:view-id>" } ?? ""
        let stateXML: String
        if state == .offline {
            stateXML = "<r:state><r:offline/>\(view)</r:state>"
        } else {
            stateXML = "<r:state><r:leased-value>"
                + "<r:value><r:\(state.rawValue)/></r:value>"
                + "<r:default-value><r:offline/></r:default-value>"
                + "<d:timeout>\(lease)</d:timeout>"
                + "</r:leased-value>\(view)</r:state>"
        }
        let xml = "\(prolog)<d:propertyupdate \(rootNS)><d:set><d:prop>\(stateXML)</d:prop></d:set></d:propertyupdate>"
        return Data(xml.utf8)
    }

    /// PROPFIND body. `props` are qualified names such as "d:displayname".
    static func propfind(_ props: [String]) -> Data {
        let inner = props.map { "<\($0)/>" }.joined()
        let xml = "\(prolog)<d:propfind \(rootNS)><d:prop>\(inner)</d:prop></d:propfind>"
        return Data(xml.utf8)
    }

    /// NOTIFY body that delivers an instant message or control payload.
    static func notification(from: RVPContactRef, to: [RVPContactRef], payload: IMPayload) -> Data {
        func contact(_ c: RVPContactRef) -> String {
            "<r:contact><d:href>\(XMLText.escape(c.principal.absoluteString))</d:href>"
                + "<r:description>\(XMLText.escape(c.description ?? ""))</r:description></r:contact>"
        }
        let xml = prolog
            + "<r:notification \(rootNS)><r:message>"
            + "<r:notification-from>\(contact(from))</r:notification-from>"
            + "<r:notification-to>\(to.map(contact).joined())</r:notification-to>"
            + "<r:msgbody><r:mime-data>\(XMLText.cdata(payload.serialize()))</r:mime-data></r:msgbody>"
            + "</r:message></r:notification>"
        return Data(xml.utf8)
    }
}

// MARK: - Parsed server/peer documents

/// One item from an incoming NOTIFY.
public enum RVPNotification: Sendable {
    case message(from: RVPContactRef, to: [RVPContactRef], payload: IMPayload)
    case presence(from: RVPContactRef, state: PresenceState)
}

enum RVPParse {
    static func contacts(in node: RVPXMLNode?) -> [RVPContactRef] {
        guard let node else { return [] }
        return node.all("contact").compactMap { c in
            guard let href = c.child("href")?.trimmedText, let url = URL(string: href) else { return nil }
            let desc = c.child("description")?.trimmedText
            return RVPContactRef(principal: url, description: (desc?.isEmpty ?? true) ? nil : desc)
        }
    }

    /// Reads a `<state>` element: either `<state><online/></state>` or
    /// `<state><leased-value><value><online/></value>...</leased-value></state>`.
    static func state(from stateNode: RVPXMLNode) -> PresenceState? {
        if let value = stateNode.first("value"), let s = value.children.first {
            return PresenceState(elementName: s.name)
        }
        if let s = stateNode.children.first(where: { $0.name != "view-id" && $0.name != "leased-value" }) {
            return PresenceState(elementName: s.name)
        }
        return nil
    }

    /// Parses the body of an incoming NOTIFY (root `<notification>`).
    static func notifications(_ data: Data) throws -> [RVPNotification] {
        let root = try RVPXMLParser.parse(data)
        guard root.name == "notification" else { return [] }
        var out: [RVPNotification] = []
        for item in root.children {
            guard let from = contacts(in: item.child("notification-from")).first else { continue }
            let to = contacts(in: item.child("notification-to"))
            switch item.name {
            case "message":
                if let mime = item.first("mime-data"), let payload = IMPayload.parse(mime.text) {
                    out.append(.message(from: from, to: to, payload: payload))
                }
            case "propnotification":
                if let st = item.first("state"), let parsed = RVPParse.state(from: st) {
                    out.append(.presence(from: from, state: parsed))
                }
            default:
                continue
            }
        }
        return out
    }

    struct PropResult {
        var state: PresenceState?
        var displayName: String?
        var email: String?
        var viewID: String?
    }

    /// Parses a 207 Multi-Status body (SUBSCRIBE propchange, PROPFIND, PROPPATCH).
    static func multistatus(_ data: Data) -> PropResult {
        var r = PropResult()
        guard let root = try? RVPXMLParser.parse(data) else { return r }
        if let st = root.first("state") { r.state = state(from: st) }
        if let dn = root.first("displayname")?.trimmedText, !dn.isEmpty { r.displayName = dn }
        if let em = root.first("email")?.trimmedText, !em.isEmpty { r.email = em }
        if let v = root.first("view-id")?.trimmedText, !v.isEmpty { r.viewID = v }
        return r
    }

    /// Parses a SUBSCRIPTIONS response: principals currently subscribed to our node.
    static func subscribers(_ data: Data) -> [URL] {
        guard let root = try? RVPXMLParser.parse(data) else { return [] }
        return root.all("subscription").compactMap { sub in
            guard let p = sub.first("rvp-principal")?.trimmedText else { return nil }
            return URL(string: p)
        }
    }
}
