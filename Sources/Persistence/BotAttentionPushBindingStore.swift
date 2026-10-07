import Foundation

public struct BotAttentionPushBinding: Codable, Equatable, Sendable {
    public let profileID: String
    public let hostID: String
    public let deviceID: String
    public let updatedAt: TimeInterval

    public init(profileID: String, hostID: String, deviceID: String, updatedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.profileID = profileID
        self.hostID = hostID
        self.deviceID = deviceID
        self.updatedAt = updatedAt
    }
}

/// Authenticated iOS profile -> paired device -> Mac host binding used only
/// for Bot attention routing. Tokens remain owned by PrivatePushTargetStore.
public final class BotAttentionPushBindingStore: @unchecked Sendable {
    private static let key = "bot.attention.push_bindings"
    private static let lock = NSLock()
    // SEP-3: reuse one codec pair instead of allocating per call
    // (codecs are not thread-safe; all use already holds Self.lock).
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()
    private let repo: SettingsRepository

    public init(db: SQLiteDB) {
        repo = SettingsRepository(db: db)
    }

    public func bind(profileID: String, hostID: String, deviceID: String) throws {
        let profileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostID = hostID.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profileID.isEmpty, !hostID.isEmpty, !deviceID.isEmpty else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var values = loadUnlocked().filter { !($0.hostID == hostID && $0.deviceID == deviceID) }
        values.append(BotAttentionPushBinding(profileID: profileID, hostID: hostID, deviceID: deviceID))
        let data = try Self.encoder.encode(values)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try repo.set(Self.key, json)
    }

    public func contains(profileID: String, hostID: String) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return loadUnlocked().contains { $0.profileID == profileID && $0.hostID == hostID }
    }

    /// True when `bind` with these arguments would rewrite only `updatedAt`.
    public func contains(profileID: String, hostID: String, deviceID: String) -> Bool {
        let profileID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostID = hostID.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profileID.isEmpty, !hostID.isEmpty, !deviceID.isEmpty else { return false }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return loadUnlocked().contains {
            $0.profileID == profileID && $0.hostID == hostID && $0.deviceID == deviceID
        }
    }

    public func unique(hostID: String) -> BotAttentionPushBinding? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let matches = loadUnlocked().filter { $0.hostID == hostID }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func loadUnlocked() -> [BotAttentionPushBinding] {
        guard let json = try? repo.get(Self.key),
              let data = json.data(using: .utf8),
              let values = try? Self.decoder.decode([BotAttentionPushBinding].self, from: data) else {
            return []
        }
        return values
    }
}
