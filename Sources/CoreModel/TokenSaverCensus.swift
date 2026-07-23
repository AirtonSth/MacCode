import Foundation

/// Shadow-only census for Token Saver (task-03 / Fase -1).
/// Records content-free opportunity metrics keyed by full `TokenSaverBindingID`.
/// Never mutates provider-visible payloads and never promotes lanes.
public enum TokenSaverCensusControl: String, Sendable, CaseIterable, Codable {
    case noChange = "no_change"
    case wrappers
    case providerNative = "provider_native"
}

public enum TokenSaverCensusStreamKind: String, Sendable, Codable {
    case streaming
    case completedTranscript = "completed_transcript"
}

public enum TokenSaverCensusToolKind: String, Sendable, Codable {
    case mcp
    case builtin
    case unknown
}

public struct TokenSaverCensusObservation: Sendable, Equatable, Codable {
    public let bindingDigestHex: String
    /// Full dimension map at observation time (BindingID complete, not a reduced tuple).
    public let bindingDimensions: [String: String]
    public let control: TokenSaverCensusControl
    public let eligibleTokens: Int64
    public let parserMatched: Bool
    public let streamKind: TokenSaverCensusStreamKind
    public let toolKind: TokenSaverCensusToolKind
    public let isSameUser: Bool
    public let recordedAt: Date

    public init(
        binding: TokenSaverBindingID,
        control: TokenSaverCensusControl,
        eligibleTokens: Int64,
        parserMatched: Bool,
        streamKind: TokenSaverCensusStreamKind,
        toolKind: TokenSaverCensusToolKind,
        isSameUser: Bool,
        recordedAt: Date = Date()
    ) {
        self.bindingDigestHex = binding.digestHex
        self.bindingDimensions = binding.dimensions
        self.control = control
        self.eligibleTokens = eligibleTokens
        self.parserMatched = parserMatched
        self.streamKind = streamKind
        self.toolKind = toolKind
        self.isSameUser = isSameUser
        self.recordedAt = recordedAt
    }

    /// Binding is complete when all canonical fields are present.
    public var hasCompleteBindingID: Bool {
        let keys = Set(bindingDimensions.keys)
        return TokenSaverBindingID.canonicalFieldOrder.allSatisfy { keys.contains($0) }
            && bindingDigestHex.count == 64
    }
}

public struct TokenSaverCensusAggregate: Sendable, Equatable {
    public let bindingDigestHex: String
    public let absoluteEligibleTokens: Int64
    public let observationCount: Int
    public let parserMatchCount: Int
    public let controlsSeen: Set<String>
    /// Rank among aggregates sorted by absolute volume descending; nil if volume is zero.
    public let rankByAbsoluteVolume: Int?
    /// Top rank without absolute volume is invalid for Gate -1.
    public let isValidForGate: Bool

    public var parserMatchRate: Double {
        observationCount == 0 ? 0 : Double(parserMatchCount) / Double(observationCount)
    }
}

/// In-memory census store. Fail-open: recording errors must not affect provider turns.
public final class TokenSaverCensusStore: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [TokenSaverCensusObservation] = []

    public init() {}

    /// Identity helper for AC-01 proofs: census must not alter provider-visible bytes.
    public static func providerVisiblePayloadUnchanged(_ payload: Data) -> Data {
        payload
    }

    /// Records a same-user observation. Cross-user returns false and stores nothing.
    @discardableResult
    public func record(_ observation: TokenSaverCensusObservation) -> Bool {
        guard observation.isSameUser else { return false }
        guard observation.hasCompleteBindingID else { return false }
        lock.lock()
        defer { lock.unlock() }
        observations.append(observation)
        return true
    }

    public func snapshot() -> [TokenSaverCensusObservation] {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        observations.removeAll()
    }

    public func aggregates() -> [TokenSaverCensusAggregate] {
        let rows = snapshot()
        var byDigest: [String: [TokenSaverCensusObservation]] = [:]
        for row in rows {
            byDigest[row.bindingDigestHex, default: []].append(row)
        }

        struct Draft {
            let digest: String
            let tokens: Int64
            let count: Int
            let matches: Int
            let controls: Set<String>
        }

        let drafts: [Draft] = byDigest.map { digest, list in
            Draft(
                digest: digest,
                tokens: list.reduce(0) { $0 + $1.eligibleTokens },
                count: list.count,
                matches: list.filter(\.parserMatched).count,
                controls: Set(list.map(\.control.rawValue))
            )
        }

        let sorted = drafts.sorted {
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            return $0.digest < $1.digest
        }

        var rankCursor = 0
        return sorted.map { draft in
            let rank: Int?
            if draft.tokens > 0 {
                rankCursor += 1
                rank = rankCursor
            } else {
                rank = nil
            }
            return TokenSaverCensusAggregate(
                bindingDigestHex: draft.digest,
                absoluteEligibleTokens: draft.tokens,
                observationCount: draft.count,
                parserMatchCount: draft.matches,
                controlsSeen: draft.controls,
                rankByAbsoluteVolume: rank,
                isValidForGate: draft.tokens > 0
            )
        }
    }

    /// Content-free JSON export for debug/ops (no payloads, no savings fields).
    public func exportJSON(pretty: Bool = true) throws -> Data {
        let payload: [String: Any] = [
            "schema": "token-saver-census-v1",
            "observation_count": snapshot().count,
            "aggregates": aggregates().map { agg -> [String: Any] in
                [
                    "binding_digest": agg.bindingDigestHex,
                    "absolute_eligible_tokens": agg.absoluteEligibleTokens,
                    "observation_count": agg.observationCount,
                    "parser_match_rate": agg.parserMatchRate,
                    "controls": Array(agg.controlsSeen).sorted(),
                    "rank_by_absolute_volume": agg.rankByAbsoluteVolume.map { $0 as Any } ?? NSNull(),
                    "valid_for_gate": agg.isValidForGate,
                ]
            },
        ]
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        )
    }

    /// Adapter-seam helper: record metadata while the provider-visible buffer is held
    /// separately. Returns the buffer unchanged so callers can prove AC-01 golden equality.
    public func observeWithoutMutatingProviderPayload(
        observation: TokenSaverCensusObservation,
        providerVisiblePayload: Data
    ) -> Data {
        _ = record(observation)
        return Self.providerVisiblePayloadUnchanged(providerVisiblePayload)
    }
}
