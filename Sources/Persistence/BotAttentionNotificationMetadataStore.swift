import Foundation

public struct BotAttentionNotificationMetadata: Codable, Equatable, Sendable {
    public let notificationID: String
    public let profileID: String
    public let hostID: String
    public let attentionItemID: String
    public let botID: String
    public let source: String

    public init(
        notificationID: String,
        profileID: String,
        hostID: String,
        attentionItemID: String,
        botID: String,
        source: String
    ) {
        self.notificationID = notificationID
        self.profileID = profileID
        self.hostID = hostID
        self.attentionItemID = attentionItemID
        self.botID = botID
        self.source = source
    }

    public var fields: [String: String] {
        [
            "profile_id": profileID,
            "host_id": hostID,
            "attention_item_id": attentionItemID,
            "notification_id": notificationID,
            "bot_id": botID,
            "source": source,
        ]
    }
}

/// Extra routing identity for Bot-owned rows in NotificationRepository.
/// Keeping it separate preserves the legacy notification schema while making
/// notification.list and notification.created expose the same exact tuple.
public final class BotAttentionNotificationMetadataStore: @unchecked Sendable {
    private static let key = "bot.attention.notification_metadata"
    private static let lock = NSLock()
    // SEP-3: reuse one codec pair instead of allocating per call
    // (codecs are not thread-safe; all use already holds Self.lock).
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()
    private let repo: SettingsRepository

    public init(db: SQLiteDB) {
        repo = SettingsRepository(db: db)
    }

    public func record(_ metadata: BotAttentionNotificationMetadata) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var values = loadUnlocked()
        values[metadata.notificationID] = metadata
        let data = try Self.encoder.encode(values)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try repo.set(Self.key, json)
    }

    public func metadata(notificationID: String) -> BotAttentionNotificationMetadata? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return loadUnlocked()[notificationID]
    }

    public func all() -> [String: BotAttentionNotificationMetadata] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> [String: BotAttentionNotificationMetadata] {
        guard let json = try? repo.get(Self.key),
              let data = json.data(using: .utf8),
              let values = try? Self.decoder.decode(
                  [String: BotAttentionNotificationMetadata].self,
                  from: data
              ) else {
            return [:]
        }
        return values
    }
}
