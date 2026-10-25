import Foundation

/// One-time transition to chat-first presentation. Later explicit pane choices
/// remain authoritative; this never resets drafts, selection or saved widths.
enum BotChatPresentationPreferences {
    static func migrateIfNeeded(in defaults: UserDefaults) {
        let versionKey = "bots.cleanChatPresentationVersion"
        guard defaults.integer(forKey: versionKey) < 1 else { return }
        defaults.set(false, forKey: "bots.deskSidePane")
        defaults.set(false, forKey: "bots.deskThreadRail")
        defaults.set(false, forKey: "bots.groupInspector")
        defaults.set(1, forKey: versionKey)
    }
}
