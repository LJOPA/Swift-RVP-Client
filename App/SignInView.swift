import SwiftUI
import RVPKit

struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdvanced = false

    private var busy: Bool { model.connection == .signingIn }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Sign-in name (user@domain)", text: $model.signInName)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        #endif
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                    Toggle("Remember password", isOn: $model.rememberPassword)
                } header: {
                    Text("Exchange Instant Messaging")
                }

                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        TextField("Server (default im.<domain>)", text: $model.server)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        TextField("Windows user (DOMAIN\\user), optional", text: $model.authUser)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        TextField("Callback port (0 = automatic)", value: $model.callbackPort, format: .number)
                    }
                } footer: {
                    Text("Will connect to \(model.account.principal.absoluteString)")
                        .font(.caption)
                }

                Section {
                    Button {
                        Task { await model.signIn() }
                    } label: {
                        HStack {
                            Text(busy ? "Signing in…" : "Sign In")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || model.signInName.isEmpty || !model.signInName.contains("@"))
                    .keyboardShortcut(.defaultAction)
                }

                if case .failed(let why) = model.connection {
                    Section("Last attempt") {
                        Text(why).foregroundStyle(.red)
                    }
                }

                if !model.log.isEmpty {
                    Section("Protocol log") {
                        LogList(lines: model.log.suffix(40))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sign In")
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}

struct LogList: View {
    var lines: ArraySlice<String>
    var body: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
