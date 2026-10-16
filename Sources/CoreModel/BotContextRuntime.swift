import CryptoKit
import Foundation

/// Storage identity for one contextual guest runtime. `storageBotID` is only a namespace;
/// it must never be used as the bound Bot's authority or actor identity.
public struct BotContextRuntimeIdentity: Equatable, Sendable {
    public static let schemaVersion = 1

    public let hostID: String
    public let botID: BotID
    public let context: BotContext
    public let policyRevision: Int64
    public let storageBotID: BotID
    public let schemaVersion: Int

    public init(binding: BotContextBinding) throws {
        guard !binding.hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              binding.state == .active,
              binding.actions.contains(.send),
              binding.policyRevision > 0 else {
            throw BotContextRuntimeIdentityError.invalidBinding
        }

        self.hostID = binding.hostID
        self.botID = binding.botID
        self.context = binding.context
        self.policyRevision = binding.policyRevision
        self.schemaVersion = Self.schemaVersion

        var input = Data("RemoteCode.BotContextRuntime.v1".utf8)
        Self.append(binding.hostID, to: &input)
        Self.append(binding.botID.value.uuidString.lowercased(), to: &input)
        Self.append(binding.context.storageKey, to: &input)
        let digest = SHA256.hash(data: input)
        let opaqueID = digest.map { String(format: "%02x", $0) }.joined()
        let uuidText = opaqueID.prefix(32)
        let formattedUUID = "\(uuidText.prefix(8))-\(uuidText.dropFirst(8).prefix(4))-\(uuidText.dropFirst(12).prefix(4))-\(uuidText.dropFirst(16).prefix(4))-\(uuidText.dropFirst(20).prefix(12))"
        self.storageBotID = BotID(UUID(uuidString: formattedUUID)!)
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}

public enum BotContextRuntimeIdentityError: Error, Equatable, Sendable {
    case invalidBinding
}
