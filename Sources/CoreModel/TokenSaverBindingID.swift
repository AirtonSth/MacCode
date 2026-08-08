import CryptoKit
import Foundation

/// Canonical Token Saver binding identity (task-02 / plan BindingID).
///
/// `BindingID = SHA-256` over a frozen, ordered canonical serialization of all
/// dimensions. Census, corpus, registry, adapter matrix, experiment, validator,
/// ledger, estimator, presentation, and operations must use the same ID.
///
/// **Cross-binding reuse of evidence is prohibited.** Display projections may
/// omit dimensions for UI only; they never authorize promotion, estimation, or
/// evidence sharing across digests.
public struct TokenSaverBindingID: Sendable, Hashable, Equatable {
    public static let schemaVersion = 1

    /// Ordered field names for canonical serialization (frozen).
    public static let canonicalFieldOrder: [String] = [
        "schema_version",
        "trigger",
        "provider",
        "provider_adapter_version",
        "tool_shape",
        "model",
        "cache_policy",
        "trigger_policy_classifier_recipe_index_version",
        "billing_cohort",
        "hardware_tier",
        "consent_version",
    ]

    public let trigger: String
    public let provider: String
    public let providerAdapterVersion: String
    public let toolShape: String
    public let model: String
    public let cachePolicy: String
    public let triggerPolicyClassifierRecipeIndexVersion: String
    public let billingCohort: String
    public let hardwareTier: String
    public let consentVersion: String

    /// Lowercase hex SHA-256 of `canonicalUTF8`.
    public let digestHex: String

    public init(
        trigger: String,
        provider: String,
        providerAdapterVersion: String,
        toolShape: String,
        model: String,
        cachePolicy: String,
        triggerPolicyClassifierRecipeIndexVersion: String,
        billingCohort: String,
        hardwareTier: String,
        consentVersion: String
    ) {
        self.trigger = trigger
        self.provider = provider
        self.providerAdapterVersion = providerAdapterVersion
        self.toolShape = toolShape
        self.model = model
        self.cachePolicy = cachePolicy
        self.triggerPolicyClassifierRecipeIndexVersion = triggerPolicyClassifierRecipeIndexVersion
        self.billingCohort = billingCohort
        self.hardwareTier = hardwareTier
        self.consentVersion = consentVersion
        self.digestHex = Self.digestHex(for: Self.canonicalUTF8(
            trigger: trigger,
            provider: provider,
            providerAdapterVersion: providerAdapterVersion,
            toolShape: toolShape,
            model: model,
            cachePolicy: cachePolicy,
            triggerPolicyClassifierRecipeIndexVersion: triggerPolicyClassifierRecipeIndexVersion,
            billingCohort: billingCohort,
            hardwareTier: hardwareTier,
            consentVersion: consentVersion
        ))
    }

    /// Canonical bytes: `key=<base64(utf8 value)>` lines in `canonicalFieldOrder`, joined by `\n`.
    /// Base64 values are lossless for any Unicode (including CR/LF); no silent stripping.
    public var canonicalUTF8: Data {
        Self.canonicalUTF8(
            trigger: trigger,
            provider: provider,
            providerAdapterVersion: providerAdapterVersion,
            toolShape: toolShape,
            model: model,
            cachePolicy: cachePolicy,
            triggerPolicyClassifierRecipeIndexVersion: triggerPolicyClassifierRecipeIndexVersion,
            billingCohort: billingCohort,
            hardwareTier: hardwareTier,
            consentVersion: consentVersion
        )
    }

    public var dimensions: [String: String] {
        [
            "schema_version": "\(Self.schemaVersion)",
            "trigger": trigger,
            "provider": provider,
            "provider_adapter_version": providerAdapterVersion,
            "tool_shape": toolShape,
            "model": model,
            "cache_policy": cachePolicy,
            "trigger_policy_classifier_recipe_index_version": triggerPolicyClassifierRecipeIndexVersion,
            "billing_cohort": billingCohort,
            "hardware_tier": hardwareTier,
            "consent_version": consentVersion,
        ]
    }

    /// Authorization and evidence paths require every semantic dimension to be present.
    public var isComplete: Bool {
        [
            trigger,
            provider,
            providerAdapterVersion,
            toolShape,
            model,
            cachePolicy,
            triggerPolicyClassifierRecipeIndexVersion,
            billingCohort,
            hardwareTier,
            consentVersion,
        ].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Display-only projection. Must never be used for promotion or evidence reuse.
    public func displayProjection(includeFields: Set<String>? = nil) -> TokenSaverBindingIDDisplayProjection {
        let all = dimensions
        let filtered: [String: String]
        if let includeFields {
            filtered = all.filter { includeFields.contains($0.key) }
        } else {
            filtered = all.filter { ["trigger", "provider", "tool_shape", "model"].contains($0.key) }
        }
        return TokenSaverBindingIDDisplayProjection(sourceDigestHex: digestHex, fields: filtered)
    }

    public static func == (lhs: TokenSaverBindingID, rhs: TokenSaverBindingID) -> Bool {
        lhs.digestHex == rhs.digestHex
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(digestHex)
    }

    // MARK: - Canonicalization

    private static func encodeValue(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func canonicalUTF8(
        trigger: String,
        provider: String,
        providerAdapterVersion: String,
        toolShape: String,
        model: String,
        cachePolicy: String,
        triggerPolicyClassifierRecipeIndexVersion: String,
        billingCohort: String,
        hardwareTier: String,
        consentVersion: String
    ) -> Data {
        let values: [String: String] = [
            "schema_version": encodeValue("\(schemaVersion)"),
            "trigger": encodeValue(trigger),
            "provider": encodeValue(provider),
            "provider_adapter_version": encodeValue(providerAdapterVersion),
            "tool_shape": encodeValue(toolShape),
            "model": encodeValue(model),
            "cache_policy": encodeValue(cachePolicy),
            "trigger_policy_classifier_recipe_index_version": encodeValue(triggerPolicyClassifierRecipeIndexVersion),
            "billing_cohort": encodeValue(billingCohort),
            "hardware_tier": encodeValue(hardwareTier),
            "consent_version": encodeValue(consentVersion),
        ]
        let lines = canonicalFieldOrder.map { key in
            "\(key)=\(values[key] ?? encodeValue(""))"
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// PERF: nibble table instead of per-byte `String(format:)` so binding
    /// digests avoid 32 formatter calls while keeping the same CryptoKit
    /// lowercase hex contract for census/ledger/promotion identity.
    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func digestHex(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }
}

/// Display-only view of a BindingID. Intentionally has no promote/estimate API.
/// `isCompleteBinding` is always false and cannot be constructed as true.
public struct TokenSaverBindingIDDisplayProjection: Sendable, Equatable {
    public let sourceDigestHex: String
    public let fields: [String: String]
    public let isCompleteBinding: Bool

    fileprivate init(sourceDigestHex: String, fields: [String: String]) {
        self.sourceDigestHex = sourceDigestHex
        self.fields = fields
        self.isCompleteBinding = false
    }
}
