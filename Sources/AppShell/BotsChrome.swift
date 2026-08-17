import SwiftUI
import CoreModel
import DesignSystemKit

/// Visible Bots chrome and Bots-only visual tokens.
/// Mockups use a violet primary; global DS accent stays cyan for the rest of the shell.
public enum BotsChrome {
    public enum Label {
        public static let agentic = "Agentic"
        public static let bots = "Bots"
        public static let newBot = "New Bot"
        public static let myBots = "My Bots"
        public static let botRoster = "BOT ROSTER"
        public static let search = "Search bots..."
        public static let openChat = "Open Chat"
        public static let saveBot = "Save Bot"
        public static let currentGoal = "Current Goal"
        public static let todaysActivity = "Today's Activity"
        public static let nextRoutine = "Next Routine"
        public static let memory = "Memory"
        public static let skills = "Skills"
        public static let routines = "Routines"
        public static let approvals = "Approvals"
        public static let roleAndIdentity = "Role & Identity"
        public static let providerRouting = "Provider routing"
        public static let instructions = "Instructions"
        public static let configurationSummary = "Configuration summary"
        public static let security = "Security"
        public static let desktop = "Desktop"
        public static let brain = "Brain"
        public static let source = "Source"
        public static let effective = "Effective"
        public static let brainPreviewHonesty = "Local compile. This is not a model call."
        public static let brainReceiptHonesty = "Receipt from the last compiled send."
        public static let honesty = BotDesktopKind.logicalExecutionSpaceHonestyLabel
    }

    /// Violet primary from the plan mockups (not the global DS cyan).
    public static let primary = Color(hex: 0x7B5CFF)
    public static let onPrimary = Color.white
    public static let primarySoft = Color(hex: 0x7B5CFF).opacity(0.16)
    public static let hitTarget: CGFloat = 44
    public static let rosterWidth: CGFloat = 272
    public static let desktopPaneWidth: CGFloat = 340

    /// Studio Avatar is a chip picker. Default matches BotDefinition.
    public static let avatarSymbols: [String] = [
        "person.crop.circle",
        "brain.head.profile",
        "hammer.fill",
        "terminal.fill",
        "sparkles",
        "star.fill",
        "ant.fill",
        "leaf.fill",
    ]

    public static func avatarSymbolName(_ symbol: String) -> String {
        switch symbol {
        case "person.crop.circle": return "Person"
        case "brain.head.profile": return "Brain"
        case "hammer.fill": return "Hammer"
        case "terminal.fill": return "Terminal"
        case "sparkles": return "Sparkles"
        case "star.fill": return "Star"
        case "ant.fill": return "Ant"
        case "leaf.fill": return "Leaf"
        default: return symbol
        }
    }

    public static let allVisibleLabels: [String] = [
        Label.agentic,
        Label.bots,
        Label.newBot,
        Label.myBots,
        Label.botRoster,
        Label.openChat,
        Label.saveBot,
        Label.currentGoal,
        Label.todaysActivity,
        Label.nextRoutine,
        Label.memory,
        Label.skills,
        Label.routines,
        Label.approvals,
        Label.roleAndIdentity,
        Label.providerRouting,
        Label.instructions,
        Label.configurationSummary,
        Label.security,
        Label.brain,
        Label.brainPreviewHonesty,
        Label.brainReceiptHonesty,
        Label.honesty,
    ]

    public static func avatarColor(for handle: String) -> Color {
        let palette: [Color] = [
            Color(hex: 0x7B5CFF),
            Color(hex: 0x3B82F6),
            Color(hex: 0xF59E0B),
            Color(hex: 0x22C55E),
            Color(hex: 0xEC4899),
            Color(hex: 0x06B6D4),
        ]
        let index = abs(handle.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }) % palette.count
        return palette[index]
    }

    public static func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        if letters.isEmpty { return "B" }
        return letters.joined().uppercased()
    }

    public static func statusTitle(for state: BotAttentionState) -> String {
        switch state {
        case .working: return "Busy"
        case .needsAttention: return "Needs you"
        case .unreadActivity: return "Unread"
        case .none: return "Online"
        }
    }
}

public struct BotsAvatarView: View {
    public let name: String
    public let handle: String
    public var size: CGFloat = 36

    public init(name: String, handle: String, size: CGFloat = 36) {
        self.name = name
        self.handle = handle
        self.size = size
    }

    public var body: some View {
        let ink = BotsChrome.avatarColor(for: handle)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(ink)
            Text(BotsChrome.initials(for: name))
                .font(.system(size: max(11, size * 0.36), weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

public struct BotsPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.body.weight(.semibold))
            .foregroundColor(BotsChrome.onPrimary)
            .frame(minHeight: BotsChrome.hitTarget)
            .padding(.horizontal, DS.Space.xl)
            .background(BotsChrome.primary.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

public struct BotActivityRow: Identifiable, Equatable {
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}
