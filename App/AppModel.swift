import Foundation
import SwiftUI
import RVPKit

struct Contact: Identifiable, Hashable {
    var id: String { RVPAccount.key(principal) }
    var principal: URL
    var signInName: String
    var displayName: String?
    var state: PresenceState?
    var unread = 0

    var title: String { displayName ?? signInName }
    var isOnline: Bool { state?.isOnline ?? false }
}

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    var fromMe: Bool
    var text: String
    var date = Date()
    var failed = false
}

@MainActor
final class AppModel: ObservableObject {
    // Settings (persisted)
    @Published var signInName = UserDefaults.standard.string(forKey: "signInName") ?? "" {
        didSet { UserDefaults.standard.set(signInName, forKey: "signInName") }
    }
    @Published var server = UserDefaults.standard.string(forKey: "server") ?? "" {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }
    @Published var authUser = UserDefaults.standard.string(forKey: "authUser") ?? "" {
        didSet { UserDefaults.standard.set(authUser, forKey: "authUser") }
    }
    @Published var callbackPort = UserDefaults.standard.integer(forKey: "callbackPort") {
        didSet { UserDefaults.standard.set(callbackPort, forKey: "callbackPort") }
    }
    @Published var rememberPassword = (UserDefaults.standard.object(forKey: "rememberPassword") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(rememberPassword, forKey: "rememberPassword") }
    }
    @Published var password = ""

    // Session state
    @Published private(set) var connection: RVPConnectionState = .signedOut
    @Published private(set) var myDisplayName = ""
    @Published var myPresence: PresenceState = .online
    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var watchers: [URL] = []
    @Published private(set) var conversations: [String: [ChatMessage]] = [:]
    @Published private(set) var typing: Set<String> = []
    @Published var selection: String?
    @Published private(set) var log: [String] = []
    @Published var lastError: String?

    private var client: RVPClient?
    private var eventTask: Task<Void, Never>?
    private var typingClear: [String: Task<Void, Never>] = [:]
    private var lastTypingSent: [String: Date] = [:]

    private var savedContacts: [String] {
        get { UserDefaults.standard.stringArray(forKey: "contacts") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "contacts") }
    }

    init() {
        if let pw = Keychain.load(account: "rvp-password") { password = pw }
    }

    var account: RVPAccount {
        RVPAccount(signInName: signInName, server: server, authUser: authUser,
                   callbackPort: UInt16(clamping: callbackPort))
    }

    var isSignedIn: Bool { connection == .signedIn }

    // MARK: - Session

    func signIn() async {
        lastError = nil
        let account = self.account
        if rememberPassword { Keychain.save(password, account: "rvp-password") } else { Keychain.delete(account: "rvp-password") }

        // Load the locally stored contact list.
        contacts = savedContacts.compactMap { URL(string: $0) }.map {
            Contact(principal: $0, signInName: account.signInName(for: $0))
        }

        let client = RVPClient(account: account, password: password)
        self.client = client
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in client.events {
                self?.handle(event)
            }
        }
        do {
            try await client.signIn(presence: myPresence == .offline ? .online : myPresence,
                                    contacts: contacts.map(\.principal))
        } catch {
            lastError = error.localizedDescription
            self.client = nil
        }
    }

    func signOut() async {
        await client?.signOut()
        client = nil
        connection = .signedOut
        typing = []
    }

    func setPresence(_ state: PresenceState) async {
        do { try await client?.setPresence(state) } catch { lastError = error.localizedDescription }
    }

    func addContact(_ name: String) async {
        guard let url = account.principal(forSignInName: name) else {
            lastError = "\"\(name)\" is not a valid sign-in name."
            return
        }
        let key = RVPAccount.key(url)
        if !contacts.contains(where: { $0.id == key }) {
            contacts.append(Contact(principal: url, signInName: account.signInName(for: url)))
            savedContacts.append(url.absoluteString)
        }
        do { try await client?.addContact(url) } catch {
            lastError = "Could not add \(name): \(error.localizedDescription)"
        }
    }

    func removeContact(_ contact: Contact) async {
        contacts.removeAll { $0.id == contact.id }
        savedContacts.removeAll { $0.lowercased() == contact.id }
        await client?.removeContact(contact.principal)
    }

    func send(_ text: String, to contact: Contact) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client else { return }
        var msg = ChatMessage(fromMe: true, text: trimmed)
        do {
            try await client.send(text: trimmed, to: contact.principal)
        } catch {
            msg.failed = true
            lastError = "Message not delivered: \(error.localizedDescription)"
        }
        conversations[contact.id, default: []].append(msg)
        lastTypingSent[contact.id] = nil
    }

    func userIsTyping(to contact: Contact) {
        guard let client else { return }
        let now = Date()
        if let last = lastTypingSent[contact.id], now.timeIntervalSince(last) < RVPDefaults.typingInterval { return }
        lastTypingSent[contact.id] = now
        Task { await client.sendTyping(to: contact.principal) }
    }

    func markRead(_ id: String) {
        if let i = contacts.firstIndex(where: { $0.id == id }) { contacts[i].unread = 0 }
    }

    // MARK: - Events

    private func handle(_ event: RVPEvent) {
        switch event {
        case .connection(let s):
            connection = s
        case .ownDisplayName(let n):
            myDisplayName = n
        case .ownPresence(let p):
            myPresence = p
        case .contactUpdated(let url, let state, let name):
            let i = ensureContact(url, persist: false)
            if let state { contacts[i].state = state }
            if let name, !name.isEmpty { contacts[i].displayName = name }
            if state == .offline { typing.remove(contacts[i].id) }
        case .watchers(let w):
            watchers = w
        case .message(let from, let text, _):
            let i = ensureContact(from.principal, persist: false)
            if let d = from.description, !d.isEmpty, contacts[i].displayName == nil { contacts[i].displayName = d }
            let id = contacts[i].id
            conversations[id, default: []].append(ChatMessage(fromMe: false, text: text))
            typing.remove(id)
            if selection != id { contacts[i].unread += 1 }
        case .typing(let url):
            let id = RVPAccount.key(url)
            typing.insert(id)
            typingClear[id]?.cancel()
            typingClear[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((RVPDefaults.typingInterval + 2) * 1_000_000_000))
                if !Task.isCancelled { self?.typing.remove(id) }
            }
        case .log(let line):
            log.append(line)
            if log.count > 500 { log.removeFirst(log.count - 500) }
        }
    }

    /// Returns the index of the contact, adding a temporary entry for strangers who message us.
    private func ensureContact(_ url: URL, persist: Bool) -> Int {
        let key = RVPAccount.key(url)
        if let i = contacts.firstIndex(where: { $0.id == key }) { return i }
        contacts.append(Contact(principal: url, signInName: account.signInName(for: url)))
        if persist { savedContacts.append(url.absoluteString) }
        return contacts.count - 1
    }

    func isSaved(_ contact: Contact) -> Bool {
        savedContacts.contains { $0.lowercased() == contact.id }
    }
}
