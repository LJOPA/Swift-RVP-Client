import Foundation

public enum RVPConnectionState: Sendable, Equatable {
    case signedOut
    case signingIn
    case signedIn
    case failed(String)
}

public enum RVPEvent: Sendable {
    case connection(RVPConnectionState)
    case ownDisplayName(String)
    case ownPresence(PresenceState)
    /// Presence and/or display name of a contact changed. Nil fields are unknown.
    case contactUpdated(principal: URL, state: PresenceState?, displayName: String?)
    /// Principals currently subscribed to our presence (people who added us).
    case watchers([URL])
    case message(from: RVPContactRef, text: String, sessionID: String)
    case typing(from: URL)
    /// Protocol trace line, for the in-app log.
    case log(String)
}

/// One signed-in RVP session. Create a new instance for each sign-in.
///
/// Sign-in sequence (matches librvp and the IETF draft):
///  1. Open a local HTTP listener; advertise it as Call-Back.
///  2. SUBSCRIBE own principal, Notification-Type: pragma/notify, Call-Back: http://ip:port
///  3. PROPPATCH own principal: leased presence state
///  4. PROPFIND own principal: d:displayname
///  5. SUBSCRIPTIONS own principal: who is watching us
///  6. SUBSCRIBE each contact, Notification-Type: update/propchange, Call-Back: own principal
///     (the server routes their changes to us through the step 2 subscription)
public actor RVPClient {
    public nonisolated let events: AsyncStream<RVPEvent>
    private let continuation: AsyncStream<RVPEvent>.Continuation

    public let account: RVPAccount
    private let http: RVPHTTPClient
    private var server: RVPCallbackServer?
    private var callbackURL: String?

    private struct Subscription {
        var id: String?
        var expiry: Date
    }

    private var selfSub: Subscription?
    private var contactSubs: [String: (url: URL, sub: Subscription)] = [:]
    private var viewID: String?
    private var presence: PresenceState = .online
    private var presenceExpiry = Date.distantPast
    private var displayName: String?
    private var sessions: [String: String] = [:]
    private var renewTask: Task<Void, Never>?
    private var signedIn = false

    /// When true, request, response and callback bodies go to the log as well.
    private let trace: Bool

    public init(account: RVPAccount, password: String, trace: Bool = false) {
        self.account = account
        self.trace = trace
        self.http = RVPHTTPClient(user: account.effectiveAuthUser, password: password)
        var cont: AsyncStream<RVPEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    // MARK: - Public API

    public func signIn(presence initial: PresenceState = .online, contacts: [URL]) async throws {
        emit(.connection(.signingIn))
        do {
            try await performSignIn(initial: initial, contacts: contacts)
        } catch {
            await teardown()
            emit(.connection(.failed(error.localizedDescription)))
            throw error
        }
    }

    public func signOut() async {
        guard signedIn else { await teardown(); return }
        renewTask?.cancel()
        _ = try? await request("PROPPATCH", account.principal,
                               body: RVPBody.presence(.offline, lease: RVPDefaults.presenceLease, viewID: viewID))
        for (_, entry) in contactSubs {
            if let id = entry.sub.id {
                _ = try? await request("UNSUBSCRIBE", entry.url, headers: [RVPHeader.subscriptionID: id])
            }
        }
        if let id = selfSub?.id {
            _ = try? await request("UNSUBSCRIBE", account.principal, headers: [RVPHeader.subscriptionID: id])
        }
        await teardown()
        emit(.connection(.signedOut))
        continuation.finish()
    }

    public func setPresence(_ state: PresenceState) async throws {
        let r = try await request("PROPPATCH", account.principal,
                                  body: RVPBody.presence(state, lease: RVPDefaults.presenceLease, viewID: viewID))
        try expectSuccess(r, "PROPPATCH")
        if r.status == 207 {
            let props = RVPParse.multistatus(r.body)
            if let v = props.viewID { viewID = v }
        }
        presence = state
        presenceExpiry = Date().addingTimeInterval(TimeInterval(RVPDefaults.presenceLease))
        emit(.ownPresence(state))
    }

    public func addContact(_ principal: URL) async throws {
        try await subscribe(contact: principal)
    }

    public func removeContact(_ principal: URL) async {
        let key = RVPAccount.key(principal)
        guard let entry = contactSubs.removeValue(forKey: key) else { return }
        if let id = entry.sub.id {
            _ = try? await request("UNSUBSCRIBE", principal, headers: [RVPHeader.subscriptionID: id])
        }
    }

    public func send(text: String, to principal: URL) async throws {
        let payload = IMPayload(kind: .text(text), sessionID: session(for: principal))
        let r = try await notify(principal, payload: payload)
        try expectSuccess(r, "NOTIFY")
    }

    /// Call while the user is typing; callers should throttle to `RVPDefaults.typingInterval`.
    public func sendTyping(to principal: URL) async {
        let payload = IMPayload(kind: .typing(user: account.signInName), sessionID: session(for: principal))
        _ = try? await notify(principal, payload: payload)
    }

    // MARK: - Sign-in

    private func performSignIn(initial: PresenceState, contacts: [URL]) async throws {
        guard let ip = LocalAddress.outboundIPv4(toward: account.host, port: account.port) else {
            throw RVPClientError.noLocalAddress(host: account.host)
        }
        let server = RVPCallbackServer(notificationsVersion: account.notificationsVersion) { [weak self] req in
            Task { await self?.handleIncoming(req) }
        }
        self.server = server
        let port = try await server.start(port: account.callbackPort)
        let cb = "http://\(ip):\(port)"
        callbackURL = cb
        log("Listening for callbacks at \(cb)")

        // 1. Self subscription: this is where the server delivers everything.
        let r = try await request("SUBSCRIBE", account.principal, headers: [
            RVPHeader.notificationType: "pragma/notify",
            RVPHeader.subscriptionLifetime: String(RVPDefaults.subscriptionLifetime),
            RVPHeader.callBack: cb,
        ])
        try expectSuccess(r, "SUBSCRIBE")
        selfSub = Subscription(id: r.header(RVPHeader.subscriptionID), expiry: expiry(from: r))

        // 2. Presence.
        try await setPresence(initial)

        // 3. Own display name (non-fatal).
        if let r = try? await request("PROPFIND", account.principal, headers: [RVPHeader.depth: "0"],
                                      body: RVPBody.propfind(["d:displayname"])),
           r.status == 207, let dn = RVPParse.multistatus(r.body).displayName {
            displayName = dn
            emit(.ownDisplayName(dn))
        }

        // 4. Watchers (non-fatal).
        if let r = try? await request("SUBSCRIPTIONS", account.principal,
                                      headers: [RVPHeader.notificationType: "update/propchange"]),
           (200..<300).contains(r.status) {
            let watchers = RVPParse.subscribers(r.body)
                .filter { RVPAccount.key($0) != RVPAccount.key(account.principal) }
            emit(.watchers(watchers))
        }

        signedIn = true
        emit(.connection(.signedIn))

        // 5. Contacts (each failure is logged, not fatal).
        for c in contacts {
            do { try await subscribe(contact: c) } catch {
                log("Could not subscribe to \(c.absoluteString): \(error.localizedDescription)")
            }
        }

        startRenewal()
    }

    private func subscribe(contact principal: URL) async throws {
        let r = try await request("SUBSCRIBE", principal, headers: [
            RVPHeader.notificationType: "update/propchange",
            RVPHeader.subscriptionLifetime: String(RVPDefaults.subscriptionLifetime),
            RVPHeader.callBack: account.principal.absoluteString,
        ])
        try expectSuccess(r, "SUBSCRIBE")
        contactSubs[RVPAccount.key(principal)] =
            (principal, Subscription(id: r.header(RVPHeader.subscriptionID), expiry: expiry(from: r)))
        if r.status == 207 {
            let props = RVPParse.multistatus(r.body)
            emit(.contactUpdated(principal: principal, state: props.state, displayName: props.displayName))
        }
    }

    // MARK: - Lease renewal

    private func startRenewal() {
        renewTask?.cancel()
        renewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                await self?.renewDue()
            }
        }
    }

    private func renewDue() async {
        let now = Date()
        // Self subscription: refresh 5 minutes early; on failure, subscribe again from scratch.
        if let sub = selfSub, sub.expiry.timeIntervalSince(now) < 300, let cb = callbackURL {
            var ok = false
            if let id = sub.id,
               let r = try? await request("SUBSCRIBE", account.principal, headers: [
                   RVPHeader.subscriptionID: id,
                   RVPHeader.subscriptionLifetime: String(RVPDefaults.subscriptionLifetime),
               ]), (200..<300).contains(r.status) {
                selfSub = Subscription(id: r.header(RVPHeader.subscriptionID) ?? id, expiry: expiry(from: r))
                ok = true
            }
            if !ok, let r = try? await request("SUBSCRIBE", account.principal, headers: [
                RVPHeader.notificationType: "pragma/notify",
                RVPHeader.subscriptionLifetime: String(RVPDefaults.subscriptionLifetime),
                RVPHeader.callBack: cb,
            ]), (200..<300).contains(r.status) {
                selfSub = Subscription(id: r.header(RVPHeader.subscriptionID), expiry: expiry(from: r))
            }
        }
        // Presence lease: refresh 2 minutes early (draft: ~29 of 30 min).
        if presence != .offline, presenceExpiry.timeIntervalSince(now) < 120 {
            try? await setPresence(presence)
        }
        // Contact subscriptions: re-subscribe fresh (librvp notes reusing ids caused trouble).
        for (key, entry) in contactSubs where entry.sub.expiry.timeIntervalSince(now) < 300 {
            if let id = entry.sub.id {
                _ = try? await request("UNSUBSCRIBE", entry.url, headers: [RVPHeader.subscriptionID: id])
            }
            contactSubs[key] = nil
            try? await subscribe(contact: entry.url)
        }
    }

    // MARK: - Incoming

    private func handleIncoming(_ req: RVPIncomingRequest) {
        log("← \(req.method) \(req.path) (\(req.body.count) bytes)")
        if trace {
            log("  headers: \(req.headers)")
            if !req.body.isEmpty { log(String(decoding: req.body, as: UTF8.self)) }
        }
        guard req.method.uppercased() == "NOTIFY", !req.body.isEmpty else { return }
        let items: [RVPNotification]
        do {
            items = try RVPParse.notifications(req.body)
        } catch {
            log("Unparseable NOTIFY: \(String(decoding: req.body, as: UTF8.self))")
            return
        }
        let me = RVPAccount.key(account.principal)
        for item in items {
            switch item {
            case .message(let from, _, let payload):
                let key = RVPAccount.key(from.principal)
                if !payload.sessionID.isEmpty { sessions[key] = payload.sessionID }
                switch payload.kind {
                case .text(let text):
                    emit(.message(from: from, text: text, sessionID: payload.sessionID))
                case .typing:
                    emit(.typing(from: from.principal))
                case .leave:
                    log("\(from.principal.absoluteString) left the conversation")
                case .invite:
                    log("Ignored invitation (file transfer etc.) from \(from.principal.absoluteString)")
                case .other(let ct, _):
                    log("Ignored message of type \(ct)")
                }
            case .presence(let from, let state):
                guard RVPAccount.key(from.principal) != me else { continue }
                emit(.contactUpdated(principal: from.principal, state: state, displayName: from.description))
            }
        }
    }

    // MARK: - Helpers

    private func notify(_ principal: URL, payload: IMPayload) async throws -> RVPResponse {
        let me = RVPContactRef(principal: account.principal, description: displayName ?? account.alias)
        let body = RVPBody.notification(from: me, to: [RVPContactRef(principal: principal)], payload: payload)
        return try await request("NOTIFY", principal, headers: [
            RVPHeader.ackType: "DeepOr",
            RVPHeader.hopCount: "1",
        ], body: body)
    }

    private func session(for principal: URL) -> String {
        let key = RVPAccount.key(principal)
        if let s = sessions[key] { return s }
        let s = IMPayload.newSessionID()
        sessions[key] = s
        return s
    }

    private func request(_ method: String, _ url: URL, headers: [String: String] = [:],
                         body: Data? = nil) async throws -> RVPResponse {
        var h = headers
        h[RVPHeader.fromPrincipal] = account.principal.absoluteString
        if body != nil, h["Content-Type"] == nil { h["Content-Type"] = "text/xml" }
        log("→ \(method) \(url.absoluteString)")
        if trace {
            log("  headers: \(h)")
            if let body, !body.isEmpty { log(String(decoding: body, as: UTF8.self)) }
        }
        let r = try await http.send(method, to: url, headers: h, body: body,
                                    notificationsVersion: account.notificationsVersion)
        log("  \(r.status)")
        if trace {
            log("  response headers: \(r.headers)")
            if !r.body.isEmpty { log(String(decoding: r.body.prefix(4000), as: UTF8.self)) }
        }
        return r
    }

    private func expectSuccess(_ r: RVPResponse, _ method: String) throws {
        guard (200..<300).contains(r.status) else {
            if !r.body.isEmpty { log(String(decoding: r.body.prefix(2000), as: UTF8.self)) }
            throw RVPClientError.unexpectedStatus(method: method, status: r.status)
        }
    }

    private func expiry(from r: RVPResponse) -> Date {
        let secs = Int(r.header(RVPHeader.subscriptionLifetime) ?? "") ?? RVPDefaults.subscriptionLifetime
        return Date().addingTimeInterval(TimeInterval(secs))
    }

    private func teardown() async {
        renewTask?.cancel()
        renewTask = nil
        server?.stop()
        server = nil
        http.invalidate()
        signedIn = false
    }

    private func emit(_ e: RVPEvent) { continuation.yield(e) }
    private func log(_ s: String) { continuation.yield(.log(s)) }
}
