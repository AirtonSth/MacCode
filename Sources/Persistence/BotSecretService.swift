import Foundation
import CoreModel

/// Bot self-config dispatch for protected secrets. Values are accepted only
/// for a confirmed write and never appear in any returned object.
public struct BotSecretService: Sendable {
    private let callerBotID: BotID
    private let store: any BotSecretStore

    public init(callerBotID: BotID, store: any BotSecretStore) {
        self.callerBotID = callerBotID
        self.store = store
    }

    public func invoke(name: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        try assertOwn(arguments["bot_id"])
        switch name {
        case BotSelfConfigCatalog.listSecrets:
            return [
                "secrets": try store.list(botID: callerBotID).map(\.name),
            ]
        case BotSelfConfigCatalog.saveSecret:
            try requireExplicitConfirmation(arguments)
            guard let rawName = arguments["name"] as? String else {
                throw BotSelfConfigError.invalid("name is required.")
            }
            guard let value = arguments["value"] as? String else {
                throw BotSelfConfigError.invalid("value is required.")
            }
            let name = try BotKeychainSecretStore.normalizedName(rawName)
            try store.save(botID: callerBotID, name: name, value: value)
            return ["saved": true, "name": name]
        case BotSelfConfigCatalog.deleteSecret:
            try requireExplicitConfirmation(arguments)
            guard let rawName = arguments["name"] as? String else {
                throw BotSelfConfigError.invalid("name is required.")
            }
            let name = try BotKeychainSecretStore.normalizedName(rawName)
            try store.delete(botID: callerBotID, name: name)
            return ["deleted": true, "name": name]
        default:
            throw BotSelfConfigError.invalid("Unknown secret tool.")
        }
    }

    private func assertOwn(_ rawBotID: Any?) throws {
        guard let rawBotID else { return }
        guard let raw = rawBotID as? String,
              let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              BotID(uuid) == callerBotID else {
            throw BotSelfConfigError.crossBot
        }
    }

    private func requireExplicitConfirmation(_ arguments: [String: Any]) throws {
        guard arguments["user_confirmed"] as? Bool == true else {
            throw BotSelfConfigError.invalid(
                "Protected secret changes require explicit user instruction (user_confirmed=true)."
            )
        }
    }
}
