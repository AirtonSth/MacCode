import Foundation
import Security

/// Metadata for one bot-owned secret. Values are intentionally not part of
/// this type so listings can never disclose secret material.
public struct BotSecretMetadata: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let name: String

    public var id: String { name }

    public init(name: String) {
        self.name = name
    }
}

public enum BotSecretStoreError: Error, Equatable, CustomStringConvertible {
    case invalidName
    case emptyValue
    case keychain(OSStatus)
    case invalidUTF8

    public var description: String {
        switch self {
        case .invalidName:
            return "Secret name must be an environment-variable name and cannot replace a RemoteCode runtime key."
        case .emptyValue:
            return "Secret value is required."
        case .keychain:
            return "Protected secret storage is unavailable."
        case .invalidUTF8:
            return "Protected secret storage returned an invalid value."
        }
    }
}

public enum BotContextSecretStoreError: Error, Equatable, CustomStringConvertible {
    case unavailable

    public var description: String {
        "Contextual secret storage is unavailable."
    }
}

/// Bot-secret access scoped to one authorized contextual storage namespace.
public struct BotContextSecretStore: BotSecretStore {
    private let identity: BotContextRuntimeIdentity
    private let store: any BotSecretStore
    private let authorizes: @Sendable () -> Bool

    public init(
        identity: BotContextRuntimeIdentity,
        store: any BotSecretStore,
        authorizes: @escaping @Sendable () -> Bool
    ) {
        self.identity = identity
        self.store = store
        self.authorizes = authorizes
    }

    public func list(botID: BotID) throws -> [BotSecretMetadata] {
        try authorize(botID)
        let result = try store.list(botID: identity.storageBotID)
        try authorize(botID)
        return result
    }

    public func save(botID: BotID, name: String, value: String) throws {
        try authorize(botID)
        try store.save(botID: identity.storageBotID, name: name, value: value)
    }

    public func load(botID: BotID, name: String) throws -> String? {
        try authorize(botID)
        let result = try store.load(botID: identity.storageBotID, name: name)
        try authorize(botID)
        return result
    }

    public func delete(botID: BotID, name: String) throws {
        try authorize(botID)
        try store.delete(botID: identity.storageBotID, name: name)
    }

    public func deleteAll(botID: BotID) throws {
        try authorize(botID)
        try store.deleteAll(botID: identity.storageBotID)
    }

    private func authorize(_ botID: BotID) throws {
        guard botID == identity.botID, authorizes() else {
            throw BotContextSecretStoreError.unavailable
        }
    }
}

public enum BotSecretEnvironmentError: Error, Equatable, CustomStringConvertible {
    case protectedStorageUnavailable

    public var description: String {
        "Protected secret storage is unavailable."
    }
}

/// Protected bot-secret storage. Implementations must keep values out of
/// metadata, prompts, logs, and user-facing responses.
public protocol BotSecretStore: Sendable {
    func list(botID: BotID) throws -> [BotSecretMetadata]
    func save(botID: BotID, name: String, value: String) throws
    func load(botID: BotID, name: String) throws -> String?
    func delete(botID: BotID, name: String) throws
    func deleteAll(botID: BotID) throws
}

/// Generic-password Keychain storage. The bot id is part of every account so
/// one bot cannot read another bot's entries. Listings request attributes only.
public struct BotKeychainSecretStore: BotSecretStore, Sendable {
    public static let defaultService = "io.remotecode.bot-secrets.v1"

    private let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func list(botID: BotID) throws -> [BotSecretMetadata] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw BotSecretStoreError.keychain(status) }
        guard let rows = item as? [[String: Any]] else { return [] }
        let prefix = accountPrefix(botID: botID)
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else { return nil }
            let name = String(account.dropFirst(prefix.count))
            guard Self.isValidName(name) else { return nil }
            return BotSecretMetadata(name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(botID: BotID, name: String, value: String) throws {
        let name = try Self.normalizedName(name)
        guard !value.isEmpty else { throw BotSecretStoreError.emptyValue }
        let data = Data(value.utf8)
        let query = baseQuery(botID: botID, name: name)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw BotSecretStoreError.keychain(updateStatus)
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if retryStatus == errSecSuccess { return }
            throw BotSecretStoreError.keychain(retryStatus)
        }
        throw BotSecretStoreError.keychain(addStatus)
    }

    public func load(botID: BotID, name: String) throws -> String? {
        let name = try Self.normalizedName(name)
        var query = baseQuery(botID: botID, name: name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw BotSecretStoreError.keychain(status) }
        guard let data = item as? Data else { throw BotSecretStoreError.invalidUTF8 }
        guard let value = String(data: data, encoding: .utf8) else {
            throw BotSecretStoreError.invalidUTF8
        }
        return value
    }

    public func delete(botID: BotID, name: String) throws {
        let name = try Self.normalizedName(name)
        let status = SecItemDelete(baseQuery(botID: botID, name: name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BotSecretStoreError.keychain(status)
        }
    }

    public func deleteAll(botID: BotID) throws {
        for secret in try list(botID: botID) {
            try delete(botID: botID, name: secret.name)
        }
    }

    public static func normalizedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(name) else { throw BotSecretStoreError.invalidName }
        return name
    }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128,
              let first = name.utf8.first,
              first == 95 || (first >= 65 && first <= 90) || (first >= 97 && first <= 122) else {
            return false
        }
        guard name.utf8.dropFirst().allSatisfy({
            $0 == 95 || ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
        }) else { return false }
        let uppercased = name.uppercased()
        return !reservedNames.contains(uppercased)
            && !reservedPrefixes.contains(where: { uppercased.hasPrefix($0) })
    }

    private static let reservedNames: Set<String> = [
        "PATH", "HOME", "CODEX_HOME", "GROK_HOME", "DISTILL_HOME",
        "RC_REMOTE_CODE_BOT_ID", "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY",
        "RC_REMOTE_CODE_SUBAGENT_THREAD_ID", "RC_REMOTE_CODE_ROOT_RUN_ID",
        "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH", "RC_REMOTE_CODE_DELEGATION_CAPABILITY",
    ]
    private static let reservedPrefixes = ["RC_", "RC2_", "REMOTE_CODE_"]

    private func accountPrefix(botID: BotID) -> String {
        "\(botID.value.uuidString.lowercased()):"
    }

    private func baseQuery(botID: BotID, name: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        query[kSecAttrAccount as String] = accountPrefix(botID: botID) + (name ?? "")
        return query
    }
}

/// Test-only-friendly protected store. It is deliberately injectable; tests
/// never touch the user's Keychain namespace.
public final class InMemoryBotSecretStore: BotSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: String]] = [:]

    public init() {}

    public func list(botID: BotID) throws -> [BotSecretMetadata] {
        lock.lock()
        let names = values[botKey(botID)].map { Array($0.keys) } ?? []
        lock.unlock()
        return names.sorted().map(BotSecretMetadata.init(name:))
    }

    public func save(botID: BotID, name: String, value: String) throws {
        let name = try BotKeychainSecretStore.normalizedName(name)
        guard !value.isEmpty else { throw BotSecretStoreError.emptyValue }
        lock.lock()
        values[botKey(botID), default: [:]][name] = value
        lock.unlock()
    }

    public func load(botID: BotID, name: String) throws -> String? {
        let name = try BotKeychainSecretStore.normalizedName(name)
        lock.lock()
        let value = values[botKey(botID)]?[name]
        lock.unlock()
        return value
    }

    public func delete(botID: BotID, name: String) throws {
        let name = try BotKeychainSecretStore.normalizedName(name)
        lock.lock()
        values[botKey(botID)]?[name] = nil
        lock.unlock()
    }

    public func deleteAll(botID: BotID) throws {
        lock.lock()
        values[botKey(botID)] = nil
        lock.unlock()
    }

    private func botKey(_ botID: BotID) -> String {
        botID.value.uuidString.lowercased()
    }
}

public enum BotSecretEnvironment {
    public static let botIDEnvironmentKey = "RC_REMOTE_CODE_BOT_ID"
    public static let secretNamesEnvironmentKey = "RC_REMOTE_CODE_BOT_SECRET_NAMES"

    public static func applying(
        to environment: [String: String],
        store: any BotSecretStore = BotKeychainSecretStore()
    ) throws -> [String: String] {
        var next = scrubbingMarkedValues(from: environment)

        guard let rawBotID = environment[botIDEnvironmentKey],
              let uuid = UUID(uuidString: rawBotID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return next
        }
        let botID = BotID(uuid)
        let metadata: [BotSecretMetadata]
        do {
            metadata = try store.list(botID: botID)
        } catch {
            throw BotSecretEnvironmentError.protectedStorageUnavailable
        }
        var injectedNames = Set<String>()
        for secret in metadata {
            guard BotKeychainSecretStore.isValidName(secret.name) else { continue }
            let value: String?
            do {
                value = try store.load(botID: botID, name: secret.name)
            } catch {
                throw BotSecretEnvironmentError.protectedStorageUnavailable
            }
            guard let value else { continue }
            next[secret.name] = value
            injectedNames.insert(secret.name)
        }
        next[secretNamesEnvironmentKey] = injectedNames.sorted().joined(separator: ",")
        return next
    }

    /// Removes bot-owned secret values and identity from an inherited process
    /// environment. Exact current-run overrides are applied by the caller after
    /// this scrub.
    public static func scrubbingInherited(from environment: [String: String]) -> [String: String] {
        var next = scrubbingMarkedValues(from: environment)
        next.removeValue(forKey: botIDEnvironmentKey)
        return next
    }

    private static func scrubbingMarkedValues(from environment: [String: String]) -> [String: String] {
        var next = environment
        for name in inheritedSecretNames(from: environment[secretNamesEnvironmentKey]) {
            next.removeValue(forKey: name)
        }
        next.removeValue(forKey: secretNamesEnvironmentKey)
        return next
    }

    private static func inheritedSecretNames(from marker: String?) -> [String] {
        guard let marker else { return [] }
        return marker
            .split(separator: ",", omittingEmptySubsequences: true)
            .map(String.init)
            .filter(BotKeychainSecretStore.isValidName)
    }
}
