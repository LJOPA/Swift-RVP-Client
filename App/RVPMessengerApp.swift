import SwiftUI
import RVPKit

@main
struct RVPMessengerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        #if os(macOS)
        .defaultSize(width: 820, height: 560)
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.isSignedIn {
                MainView()
            } else {
                SignInView()
            }
        }
        .alert("Error", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } })
        ) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

extension PresenceState {
    var color: Color {
        switch self {
        case .online: return .green
        case .busy, .onPhone: return .red
        case .idle, .away, .backSoon, .atLunch: return .orange
        case .offline: return .gray
        }
    }
}

struct PresenceDot: View {
    var state: PresenceState?
    var body: some View {
        Circle()
            .fill((state ?? .offline).color)
            .frame(width: 10, height: 10)
            .accessibilityLabel((state ?? .offline).displayName)
    }
}
