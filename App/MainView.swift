import SwiftUI
import RVPKit

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdd = false
    @State private var showLog = false

    private var online: [Contact] {
        model.contacts.filter(\.isOnline).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    private var offline: [Contact] {
        model.contacts.filter { !$0.isOnline }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    private var newWatchers: [URL] {
        let known = Set(model.contacts.map(\.id))
        return model.watchers.filter { !known.contains(RVPAccount.key($0)) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Online (\(online.count))") {
                    ForEach(online) { ContactRow(contact: $0).tag($0.id) }
                }
                Section("Offline (\(offline.count))") {
                    ForEach(offline) { ContactRow(contact: $0).tag($0.id) }
                }
                if !newWatchers.isEmpty {
                    Section("People who added you") {
                        ForEach(newWatchers, id: \.self) { url in
                            HStack {
                                Text(model.account.signInName(for: url))
                                Spacer()
                                Button("Add") { Task { await model.addContact(url.absoluteString) } }
                            }
                        }
                    }
                }
            }
            .navigationTitle(model.myDisplayName.isEmpty ? model.account.alias : model.myDisplayName)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Label("Add Contact", systemImage: "person.badge.plus") }
                }
                ToolbarItem {
                    Menu {
                        Picker("Status", selection: Binding(
                            get: { model.myPresence },
                            set: { s in Task { await model.setPresence(s) } })
                        ) {
                            ForEach(PresenceState.selectable, id: \.self) { s in
                                Label(s.displayName, systemImage: "circle.fill").tag(s)
                            }
                            // GUESS: "Appear Offline" = publish offline while keeping subscriptions.
                            Text("Appear Offline").tag(PresenceState.offline)
                        }
                        Divider()
                        Button("Protocol Log") { showLog = true }
                        Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
                    } label: {
                        Label(model.myPresence.displayName, systemImage: "circle.fill")
                            .foregroundStyle(model.myPresence.color)
                    }
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            #endif
        } detail: {
            if let id = model.selection, let contact = model.contacts.first(where: { $0.id == id }) {
                ChatView(contact: contact)
                    .id(id)
            } else {
                Text("Select a contact to start a conversation.")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.selection) { id in
            if let id { model.markRead(id) }
        }
        .sheet(isPresented: $showAdd) { AddContactView() }
        .sheet(isPresented: $showLog) {
            NavigationStack {
                List { LogList(lines: model.log[...]) }
                    .navigationTitle("Protocol Log")
                    .toolbar { Button("Done") { showLog = false } }
            }
            #if os(macOS)
            .frame(minWidth: 560, minHeight: 420)
            #endif
        }
    }
}

struct ContactRow: View {
    @EnvironmentObject var model: AppModel
    var contact: Contact

    var body: some View {
        HStack {
            PresenceDot(state: contact.state)
            VStack(alignment: .leading) {
                Text(contact.title)
                if let s = contact.state, s != .online {
                    Text(s.displayName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if contact.unread > 0 {
                Text("\(contact.unread)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
        }
        .contextMenu {
            Button("Remove Contact", role: .destructive) {
                Task { await model.removeContact(contact) }
            }
        }
    }
}

struct AddContactView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Sign-in name (user or user@domain)", text: $name)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(add)
            }
            .formStyle(.grouped)
            .navigationTitle("Add Contact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 160)
        #endif
    }

    private func add() {
        let n = name
        dismiss()
        Task { await model.addContact(n) }
    }
}
