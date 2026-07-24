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

    /// Receipts require an authoritative ledger snapshot. Snapshots exist only after
    /// `Ledger.markProviderMeasured` (internal / same-module) — public CoreModel APIs
    /// cannot forge measured tokens from raw scalars.
    public enum ReceiptFactory {
        /// Mint from local ledger measured state. Binding comes from the ledger, not the caller.
        public static func fromLocalLedger(
            ledger: TokenSaverAccountingV2.Ledger,
            operationDigest: String
        ) -> MeasuredSavingsReceipt? {
            mint(ledger: ledger, operationDigest: operationDigest, source: .localLedger)
        }

        /// Mint after provider usage was recorded via `markProviderMeasured`.
        /// Binding and tokens come only from the ledger.
        public static func fromProviderUsage(
            ledger: TokenSaverAccountingV2.Ledger,
            operationDigest: String
        ) -> MeasuredSavingsReceipt? {
            mint(ledger: ledger, operationDigest: operationDigest, source: .providerUsage)
        }

        private static func mint(
            ledger: TokenSaverAccountingV2.Ledger,
            operationDigest: String,
            source: MeasuredSavingsReceipt.Source
        ) -> MeasuredSavingsReceipt? {
            guard !operationDigest.isEmpty else { return nil }
            guard let snap = ledger.measuredSnapshot(for: operationDigest) else { return nil }
            _ = snap.evidenceDigest // available for callers that bind evidence separately
            return MeasuredSavingsReceipt(
                bindingDigest: snap.bindingDigest,
                source: source,
                tokens: snap.tokens
            )
        }
    }

    public static func admitSearch(
        queryScopeDigest: String,
        resultScopeDigest: String,
        live: Bool = defaultEnabled
    ) -> Bool {
        // Rollout OR explicit live flag (callers may pass `isLive` after activate).
        let on = live || isLive
        return on && !queryScopeDigest.isEmpty && queryScopeDigest == resultScopeDigest
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
        let on = live || isLive
        let handleOK = !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return on && handleOK && !revoked && retrieveExact(bytes: bytes, original: original)
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
