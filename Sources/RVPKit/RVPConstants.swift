import Foundation

/// XML namespaces used by Exchange 2000 Instant Messaging (RVP).
public enum RVPNamespace {
    public static let dav = "DAV:"
    public static let rvp = "http://schemas.microsoft.com/rvp/"
    public static let acl = "http://schemas.microsoft.com/rvp/acl/"
}

/// RVP-specific HTTP header names.
public enum RVPHeader {
    public static let notificationsVersion = "RVP-Notifications-Version"
    public static let fromPrincipal = "RVP-From-Principal"
    public static let notificationType = "Notification-Type"
    public static let subscriptionLifetime = "Subscription-Lifetime"
    public static let subscriptionID = "Subscription-Id"
    public static let callBack = "Call-Back"
    public static let ackType = "RVP-Ack-Type"
    public static let hopCount = "RVP-Hop-Count"
    public static let depth = "Depth"
}

public enum RVPDefaults {
    /// The IETF draft examples say 1.0. librvp (used against real Exchange 2000
    /// servers) sends 0.2. GUESS: 0.2 matches what Windows Messenger sent.
    /// If the server answers 400, try "1.0" via `RVPAccount.notificationsVersion`.
    public static let notificationsVersion = "0.2"
    /// Seconds. librvp uses 14000; the draft examples use 14400.
    public static let subscriptionLifetime = 14000
    /// Presence lease in seconds. The draft says Exchange 2000 uses 20 minutes.
    public static let presenceLease = 1200
    /// Windows Messenger re-sends typing control messages about every 4 s (librvp).
    public static let typingInterval: TimeInterval = 4
    /// Matches librvp / Windows Messenger default font descriptor.
    public static let imFormat = "FN=MS%20Shell%20Dlg; EF=; CO=0; CS=0; PF=0"
}

/// Presence states. Raw values are the RVP element local names
/// (e.g. `<r:online/>`), confirmed against librvp's state table.
public enum PresenceState: String, CaseIterable, Codable, Sendable, Hashable {
    case online
    case busy
    case idle
    case backSoon = "back-soon"
    case away
    case onPhone = "on-phone"
    case atLunch = "at-lunch"
    case offline

    public var displayName: String {
        switch self {
        case .online: return "Online"
        case .busy: return "Busy"
        case .idle: return "Idle"
        case .backSoon: return "Be Right Back"
        case .away: return "Away"
        case .onPhone: return "On the Phone"
        case .atLunch: return "Out to Lunch"
        case .offline: return "Offline"
        }
    }

    /// States a user may choose for themselves (idle is set automatically).
    public static var selectable: [PresenceState] {
        [.online, .busy, .backSoon, .away, .onPhone, .atLunch]
    }

    public var isOnline: Bool { self != .offline }

    public init(elementName: String) {
        self = PresenceState(rawValue: elementName.lowercased()) ?? .offline
    }
}
