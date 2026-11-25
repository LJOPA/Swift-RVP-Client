import Foundation

/// Connection settings for one Exchange 2000 IM account.
public struct RVPAccount: Codable, Sendable, Equatable {
    /// "alias@domain", e.g. "luke@enterprise.bahamut.zone".
    public var signInName: String
    /// IM home server host, optionally with ":port", e.g. "im.enterprise.bahamut.zone".
    public var server: String
    /// User name for NTLM. Empty means the alias. Use "DOMAIN\\user" if the
    /// Windows domain differs from what the server infers.
    public var authUser: String
    /// Local TCP port for server callbacks. 0 picks a free port each sign-in.
    public var callbackPort: UInt16
    public var notificationsVersion: String

    public init(signInName: String, server: String = "", authUser: String = "",
                callbackPort: UInt16 = 0, notificationsVersion: String = RVPDefaults.notificationsVersion) {
        self.signInName = signInName.trimmingCharacters(in: .whitespaces)
        self.server = server.trimmingCharacters(in: .whitespaces)
        self.authUser = authUser
        self.callbackPort = callbackPort
        self.notificationsVersion = notificationsVersion
        if self.server.isEmpty, !domain.isEmpty {
            // Exchange convention: IM host is im.<domain>. librvp tries the
            // _rvp._tcp.<domain> SRV record first; SRV lookup is not in v1.
            self.server = "im.\(domain)"
        }
    }

    public var alias: String {
        String(signInName.split(separator: "@", maxSplits: 1).first ?? "")
    }

    public var domain: String {
        let parts = signInName.split(separator: "@", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]).lowercased() : ""
    }

    public var host: String {
        String(server.split(separator: ":").first ?? Substring(server))
    }

    public var port: UInt16 {
        let parts = server.split(separator: ":")
        return parts.count == 2 ? UInt16(parts[1]) ?? 80 : 80
    }

    public var effectiveAuthUser: String { authUser.isEmpty ? alias : authUser }

    private var hostPort: String { port == 80 ? host : "\(host):\(port)" }

    /// Our logical principal URL, e.g. http://im.example.com/instmsg/aliases/luke
    public var principal: URL {
        principal(alias: alias, host: hostPort)
    }

    private func principal(alias: String, host: String) -> URL {
        let escaped = alias.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? alias
        // Fallback only hit while the sign-in form is still empty.
        return URL(string: "http://\(host)/instmsg/aliases/\(escaped)")
            ?? URL(string: "http://invalid/instmsg/aliases/")!
    }

    /// Principal URL for a contact typed as "alias" or "alias@domain".
    /// GUESS: contacts in another domain live at im.<their domain>.
    public func principal(forSignInName name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("http://") { return URL(string: trimmed) }
        let parts = trimmed.split(separator: "@", maxSplits: 1).map(String.init)
        guard let a = parts.first, !a.isEmpty else { return nil }
        if parts.count == 1 || parts[1].lowercased() == domain {
            return principal(alias: a, host: hostPort)
        }
        return principal(alias: a, host: "im.\(parts[1].lowercased())")
    }

    /// "alias@domain" for a principal URL. Handles the routed form
    /// http://home/instmsg/local/<im-host>/instmsg/aliases/<alias>.
    public func signInName(for principal: URL) -> String {
        let comps = principal.pathComponents
        let alias = comps.last.map { $0.removingPercentEncoding ?? $0 } ?? principal.absoluteString
        var imHost = principal.host ?? ""
        if let i = comps.firstIndex(of: "local"), i + 1 < comps.count { imHost = comps[i + 1] }
        let d: String
        if imHost.lowercased() == host.lowercased() {
            d = domain
        } else if imHost.lowercased().hasPrefix("im.") {
            d = String(imHost.dropFirst(3))
        } else {
            d = imHost
        }
        return d.isEmpty ? alias : "\(alias)@\(d)"
    }

    /// Canonical key for comparing principal URLs.
    public static func key(_ url: URL) -> String {
        url.absoluteString.lowercased()
    }
}
