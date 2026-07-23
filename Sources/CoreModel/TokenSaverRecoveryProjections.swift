import Foundation

/// Wave B recovery search + projections (task-16). Default OFF.
public enum TokenSaverRecoveryProjections {
    public static let taskID = "task-16"
    public static let defaultEnabled = false

    /// Confirmed savings only from trusted factory (ledger / provider usage adapters).
    public struct MeasuredSavingsReceipt: Sendable, Equatable {
        public let bindingDigest: String
        public let source: Source
        public let tokens: Int64
        public enum Source: String, Sendable { case localLedger = "local_ledger", providerUsage = "provider_usage" }

        fileprivate init(bindingDigest: String, source: Source, tokens: Int64) {
            self.bindingDigest = bindingDigest
            self.source = source
            self.tokens = tokens
        }
    }

    /// Only trusted adapters construct receipts — no public free-form token credits.
    public enum ReceiptFactory {
        public static func fromLocalLedger(
            bindingDigest: String,
            confirmedTokens: Int64,
            ledgerDigestMatch: Bool
        ) -> MeasuredSavingsReceipt? {
            guard !bindingDigest.isEmpty, ledgerDigestMatch, confirmedTokens >= 0 else { return nil }
            return MeasuredSavingsReceipt(bindingDigest: bindingDigest, source: .localLedger, tokens: confirmedTokens)
        }

        public static func fromProviderUsage(
            bindingDigest: String,
            providerTokensSaved: Int64,
            usageEventPresent: Bool
        ) -> MeasuredSavingsReceipt? {
            guard !bindingDigest.isEmpty, usageEventPresent, providerTokensSaved >= 0 else { return nil }
            return MeasuredSavingsReceipt(bindingDigest: bindingDigest, source: .providerUsage, tokens: providerTokensSaved)
        }
    }

    public static func admitSearch(
        queryScopeDigest: String,
        resultScopeDigest: String,
        live: Bool = defaultEnabled
    ) -> Bool {
        live && !queryScopeDigest.isEmpty && queryScopeDigest == resultScopeDigest
    }

    public static func retrieveExact(bytes: Data, original: Data) -> Bool {
        bytes == original
    }

    public static func admitRetrieve(
        bytes: Data,
        original: Data,
        handle: String,
        revoked: Bool = false,
        live: Bool = defaultEnabled
    ) -> Bool {
        let handleOK = !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return live && handleOK && !revoked && retrieveExact(bytes: bytes, original: original)
    }

    public static func manifestKeepsCore(systemUntouched: Bool, coreToolsPresent: Bool) -> Bool {
        systemUntouched && coreToolsPresent
    }

    public static func admitManifest(systemUntouched: Bool, coreToolsPresent: Bool, live: Bool = defaultEnabled) -> Bool {
        live && manifestKeepsCore(systemUntouched: systemUntouched, coreToolsPresent: coreToolsPresent)
    }

    public static func workspaceGapForcesFullSnapshot(_ gap: Bool) -> Bool { gap }
    public static func taskDoneRequiresProof(_ hasProof: Bool) -> Bool { hasProof }
    public static func resumeTailGapLoadsFull(_ gap: Bool) -> Bool { gap }

    public static func dedupeHandles(_ handles: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for h in handles where !h.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if seen.insert(h).inserted { out.append(h) }
        }
        return out
    }

    public static func prefetchConfirmedSavings(
        used: Bool,
        receipt: MeasuredSavingsReceipt?,
        creditBindingDigest: String
    ) -> Int64 {
        guard used, let receipt else { return 0 }
        guard receipt.bindingDigest == creditBindingDigest else { return 0 }
        return receipt.tokens
    }

    public static func admitPrefetchSavings(
        used: Bool,
        receipt: MeasuredSavingsReceipt?,
        creditBindingDigest: String,
        live: Bool = defaultEnabled
    ) -> Int64 {
        guard live else { return 0 }
        return prefetchConfirmedSavings(used: used, receipt: receipt, creditBindingDigest: creditBindingDigest)
    }
}
