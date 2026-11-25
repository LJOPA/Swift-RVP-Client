import SwiftUI
import RVPKit

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    var contact: Contact
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var messages: [ChatMessage] { model.conversations[contact.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { MessageBubble(message: $0) }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if model.typing.contains(contact.id) {
                Text("\(contact.title) is typing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Divider()
            HStack(alignment: .bottom) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .onChange(of: draft) { newValue in
                        if !newValue.isEmpty { model.userIsTyping(to: contact) }
                    }
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .navigationTitle(contact.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem {
                HStack(spacing: 6) {
                    PresenceDot(state: contact.state)
                    Text((contact.state ?? .offline).displayName).font(.caption)
                }
            }
        }
        .onAppear {
            inputFocused = true
            model.markRead(contact.id)
        }
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await model.send(text, to: contact) }
    }
}

struct MessageBubble: View {
    var message: ChatMessage

    var body: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 40) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(message.fromMe ? Color.accentColor : Color.secondary.opacity(0.2)))
                    .foregroundStyle(message.fromMe ? Color.white : Color.primary)
                HStack(spacing: 4) {
                    if message.failed {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        Text("Not delivered")
                    }
                    Text(message.date, style: .time)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !message.fromMe { Spacer(minLength: 40) }
        }
        .id(message.id)
    }
}
