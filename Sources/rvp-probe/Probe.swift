import Foundation
import RVPKit

/// Command-line sign-in test against a live Exchange 2000 IM server.
///
/// Configuration comes from environment variables so the password never
/// appears in shell history or the process list:
///
///   RVP_SIGNIN          alias@domain (required)
///   RVP_PASSWORD        password; if unset, read from the first line of stdin
///   RVP_SERVER          host[:port]; default im.<domain>
///   RVP_AUTH_USER       NTLM user, e.g. DOMAIN\alias; default alias
///   RVP_VERSION         RVP-Notifications-Version; default 0.2
///   RVP_CONTACTS        comma-separated contacts to subscribe to
///   RVP_SEND_TO         contact to send one test message to
///   RVP_SEND_TEXT       text of that message
///   RVP_LISTEN_SECONDS  how long to stay signed in and print callbacks; default 60
///   RVP_PRESENCE        presence to publish (online, busy, away...); default online
@main
struct Probe {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        guard let signIn = env["RVP_SIGNIN"], signIn.contains("@") else {
            FileHandle.standardError.write(Data("Set RVP_SIGNIN=alias@domain (see Probe.swift for options).\n".utf8))
            exit(2)
        }
        guard let password = env["RVP_PASSWORD"] ?? readLine(strippingNewline: true), !password.isEmpty else {
            FileHandle.standardError.write(Data("Set RVP_PASSWORD or pipe the password on stdin.\n".utf8))
            exit(2)
        }

        let account = RVPAccount(signInName: signIn,
                                 server: env["RVP_SERVER"] ?? "",
                                 authUser: env["RVP_AUTH_USER"] ?? "",
                                 notificationsVersion: env["RVP_VERSION"] ?? RVPDefaults.notificationsVersion)
        let contacts = (env["RVP_CONTACTS"] ?? "")
            .split(separator: ",")
            .compactMap { account.principal(forSignInName: String($0)) }
        let listen = Double(env["RVP_LISTEN_SECONDS"] ?? "") ?? 60
        let presence = PresenceState(rawValue: env["RVP_PRESENCE"] ?? "online") ?? .online

        print("Principal: \(account.principal.absoluteString)")
        print("NTLM user: \(account.effectiveAuthUser)")

        let client = RVPClient(account: account, password: password, trace: true)
        let printer = Task {
            for await event in client.events {
                print(describe(event))
            }
        }

        do {
            try await client.signIn(presence: presence, contacts: contacts)
        } catch {
            print("RESULT: sign-in failed: \(error.localizedDescription)")
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(1)
        }

        if let to = env["RVP_SEND_TO"], let url = account.principal(forSignInName: to) {
            do {
                try await client.send(text: env["RVP_SEND_TEXT"] ?? "RVPKit test message", to: url)
                print("RESULT: message to \(to) accepted")
            } catch {
                print("RESULT: message to \(to) failed: \(error.localizedDescription)")
            }
        }

        print("Signed in. Listening for \(Int(listen)) s…")
        try? await Task.sleep(nanoseconds: UInt64(listen * 1_000_000_000))
        await client.signOut()
        try? await Task.sleep(nanoseconds: 300_000_000)
        printer.cancel()
        print("RESULT: done")
    }

    static func describe(_ e: RVPEvent) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        switch e {
        case .connection(let s): return "\(stamp) [state] \(s)"
        case .ownDisplayName(let n): return "\(stamp) [me] display name \(n)"
        case .ownPresence(let p): return "\(stamp) [me] presence \(p.rawValue)"
        case .contactUpdated(let u, let s, let n):
            return "\(stamp) [contact] \(u.absoluteString) state=\(s?.rawValue ?? "?") name=\(n ?? "?")"
        case .watchers(let w): return "\(stamp) [watchers] \(w.map(\.absoluteString))"
        case .message(let from, let text, let sid):
            return "\(stamp) [message] from \(from.principal.absoluteString) session \(sid): \(text)"
        case .typing(let u): return "\(stamp) [typing] \(u.absoluteString)"
        case .log(let line): return "\(stamp) \(line)"
        }
    }
}
