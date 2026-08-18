import SwiftUI
import CoreModel
import DesignSystemKit

/// Visible Bots chrome and Bots-only visual tokens.
/// Bots surfaces speak the global DS language (accent, surfaces, radii);
/// only per-bot avatar identity colors are local to Bots.
public enum BotsChrome {
    public enum Label {
        public static let agentic = "Agentic"
        public static let bots = "Bots"
        public static let newBot = "New Bot"
        public static let activeBots = "Active Bots"
        public static let scheduleTasks = "Schedule Tasks"
        public static let myBots = "My Bots"
        public static let botRoster = "BOT ROSTER"
        public static let search = "Search bots..."
        public static let openChat = "Open Chat"
        public static let saveBot = "Save Bot"
        public static let unsavedNewBotConfirmTitle = "Don't save this Bot?"
        public static let unsavedNewBotConfirmMessage = "This teammate has not been saved."
        public static let unsavedNewBotDontSave = "Don't Save"
        public static let currentGoal = "Current Goal"
        public static let todaysActivity = "Today's Activity"
        public static let nextRoutine = "Next Routine"
        public static let files = "Files"
        public static let routines = "Schedule Tasks"
        public static let approvals = "Approvals"
        public static let roleAndIdentity = "Role & Identity"
        public static let description = "Description"
        public static let descriptionCaption =
            "Who this teammate is. A short about line. Empty stays out of the prompt."
        public static let instructions = "Instructions"
        public static let instructionsCaption =
            "How this teammate should work. Always sent. Empty uses the built-in teammate default. Write your own to replace it."
        public static let security = "Security"
        public static let notifications = "Notifications"
        public static let desktop = "Desktop"
        public static let brain = "Brain"
        public static let source = "Source"
        public static let effective = "Effective"
        public static let brainPreviewHonesty = "Local compile. This is not a model call."
        public static let brainReceiptHonesty = "Receipt from the last compiled send."
        public static let honesty = BotDesktopKind.logicalExecutionSpaceHonestyLabel
    }

    public static let hitTarget: CGFloat = 44
    public static let rosterWidth: CGFloat = 272
    public static let desktopPaneWidth: CGFloat = 340
    public static let desktopPaneMinWidth: CGFloat = 240
    public static let desktopPaneMaxWidth: CGFloat = 560

    /// Leftover SF chips. Studio Avatar is the blobatar composer.
    public static let avatarSymbols: [String] = BotAvatar.advertisedSymbols

    public static func avatarSymbolName(_ symbol: String) -> String {
        BotAvatar.advertisedName(for: symbol)
    }

    public static let allVisibleLabels: [String] = [
        Label.agentic,
        Label.bots,
        Label.newBot,
        Label.activeBots,
        Label.scheduleTasks,
        Label.myBots,
        Label.botRoster,
        Label.openChat,
        Label.saveBot,
        Label.unsavedNewBotConfirmTitle,
        Label.unsavedNewBotConfirmMessage,
        Label.unsavedNewBotDontSave,
        Label.currentGoal,
        Label.todaysActivity,
        Label.nextRoutine,
        Label.files,
        Label.routines,
        Label.approvals,
        Label.roleAndIdentity,
        Label.description,
        Label.descriptionCaption,
        Label.instructions,
        Label.instructionsCaption,
        Label.security,
        Label.notifications,
        Label.desktop,
        Label.brain,
        Label.brainPreviewHonesty,
        Label.brainReceiptHonesty,
        Label.honesty,
    ]

    public static func avatarHex(for handle: String) -> UInt32 {
        let palette: [UInt32] = [
            0x7B5CFF,
            0x3B82F6,
            0xF59E0B,
            0x22C55E,
            0xEC4899,
            0x06B6D4,
        ]
        let index = abs(handle.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }) % palette.count
        return palette[index]
    }

    public static func avatarColor(for handle: String) -> Color {
        Color(hex: avatarHex(for: handle))
    }

    /// Painted avatar ink. Blobatar uses the figure head; leftover SF chips
    /// keep the handle swatch so roster highlight matches the glyph.
    public static func identityHex(name: String, handle: String, symbol: String) -> UInt32 {
        if let spec = BotBlobatarSpec.parse(symbol) {
            return BotBlobatar.figure(
                name: name.isEmpty ? handle : name,
                spec: spec,
                handle: handle
            ).palette.head
        }
        return avatarHex(for: handle)
    }

    public static func identityColor(name: String, handle: String, symbol: String) -> Color {
        Color(hex: identityHex(name: name, handle: handle, symbol: symbol))
    }

    public static func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        if letters.isEmpty { return "B" }
        return letters.joined().uppercased()
    }

    public static func statusTitle(for state: BotAttentionState) -> String {
        switch state {
        case .working: return "Working"
        case .needsAttention: return "Needs you"
        case .unreadActivity: return "Unread"
        case .none: return "Online"
        }
    }
}

/// DS primary button at the Bots 44pt hit target (DSPrimaryButtonStyle is shorter).
public struct BotsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.body.weight(.semibold))
            .foregroundColor(DS.Palette.onAccent)
            .frame(minHeight: BotsChrome.hitTarget)
            .padding(.horizontal, DS.Space.xl)
            .background(DS.Palette.accent.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .opacity(DSButtonOpacity.effectiveOpacity(isEnabled: isEnabled, isHovering: hovering))
            .onHover { hovering = $0 }
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
