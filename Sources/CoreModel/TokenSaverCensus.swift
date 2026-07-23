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
    /// Wire volume is useful operationally, but must never be treated as tokens.
    public let eligibleBytes: Int64
    /// Provider-measured eligible tokens. Zero when no authoritative measurement exists.
    public let eligibleTokens: Int64
    public let hasMeasuredEligibleTokens: Bool
    public let parserMatched: Bool
    public let streamKind: TokenSaverCensusStreamKind
    public let toolKind: TokenSaverCensusToolKind
    public let isSameUser: Bool
    public let recordedAt: Date

    public init(
        binding: TokenSaverBindingID,
        control: TokenSaverCensusControl,
        eligibleBytes: Int64 = 0,
        eligibleTokens: Int64,
        hasMeasuredEligibleTokens: Bool = true,
        parserMatched: Bool,
        streamKind: TokenSaverCensusStreamKind,
        toolKind: TokenSaverCensusToolKind,
        isSameUser: Bool,
        recordedAt: Date = Date()
    ) {
        self.bindingDigestHex = binding.digestHex
        self.bindingDimensions = binding.dimensions
        self.control = control
        self.eligibleBytes = max(0, eligibleBytes)
        self.eligibleTokens = max(0, eligibleTokens)
        self.hasMeasuredEligibleTokens = hasMeasuredEligibleTokens
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
            && bindingDimensions
                .filter { $0.key != "schema_version" }
                .values
                .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && bindingDigestHex.count == 64
    }
}

public struct TokenSaverCensusAggregate: Sendable, Equatable {
    public let bindingDigestHex: String
    public let absoluteEligibleTokens: Int64
    public let absoluteEligibleBytes: Int64
    public let observationCount: Int
    public let measuredTokenObservationCount: Int
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
    private struct Accumulator {
        var tokens: Int64 = 0
        var bytes: Int64 = 0
        var count: Int = 0
        var measuredTokenCount: Int = 0
        var matches: Int = 0
        var controls: Set<String> = []
    }

    private let lock = NSLock()
    private var observations: [TokenSaverCensusObservation] = []
    private var nextObservationIndex = 0
    private var accumulators: [String: Accumulator] = [:]
    private var totalObservationCount = 0
    private var droppedObservationCount = 0
    private let maxRecentObservations: Int
    private let maxBindings: Int

    public init(maxRecentObservations: Int = 1_024, maxBindings: Int = 4_096) {
        self.maxRecentObservations = max(0, maxRecentObservations)
        self.maxBindings = max(1, maxBindings)
    }

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
        let digest = observation.bindingDigestHex
        if accumulators[digest] == nil && accumulators.count >= maxBindings {
            if droppedObservationCount < .max { droppedObservationCount += 1 }
            return false
        }
        var accumulator = accumulators[digest] ?? Accumulator()
        if observation.hasMeasuredEligibleTokens {
            accumulator.tokens = Self.saturatingAdd(accumulator.tokens, observation.eligibleTokens)
            if accumulator.measuredTokenCount < .max { accumulator.measuredTokenCount += 1 }
        }
        accumulator.bytes = Self.saturatingAdd(accumulator.bytes, observation.eligibleBytes)
        if accumulator.count < .max { accumulator.count += 1 }
        if observation.parserMatched && accumulator.matches < .max { accumulator.matches += 1 }
        accumulator.controls.insert(observation.control.rawValue)
        accumulators[digest] = accumulator
        if totalObservationCount < .max { totalObservationCount += 1 }
        if maxRecentObservations > 0 {
            if observations.count < maxRecentObservations {
                observations.append(observation)
            } else {
                observations[nextObservationIndex] = observation
                nextObservationIndex = (nextObservationIndex + 1) % maxRecentObservations
            }
        }
        return true
    }

    public func snapshot() -> [TokenSaverCensusObservation] {
        lock.lock()
        defer { lock.unlock() }
        guard observations.count == maxRecentObservations, nextObservationIndex > 0 else {
            return observations
        }
        return Array(observations[nextObservationIndex...]) + Array(observations[..<nextObservationIndex])
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        observations.removeAll()
        nextObservationIndex = 0
        accumulators.removeAll()
        totalObservationCount = 0
        droppedObservationCount = 0
    }

    public func aggregates() -> [TokenSaverCensusAggregate] {
        struct Draft {
            let digest: String
            let tokens: Int64
            let bytes: Int64
            let count: Int
            let measuredTokenCount: Int
            let matches: Int
            let controls: Set<String>
        }

        lock.lock()
        let aggregateSnapshot = accumulators
        lock.unlock()
        let drafts: [Draft] = aggregateSnapshot.map { digest, value in
            Draft(
                digest: digest,
                tokens: value.tokens,
                bytes: value.bytes,
                count: value.count,
                measuredTokenCount: value.measuredTokenCount,
                matches: value.matches,
                controls: value.controls
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
                absoluteEligibleBytes: draft.bytes,
                observationCount: draft.count,
                measuredTokenObservationCount: draft.measuredTokenCount,
                parserMatchCount: draft.matches,
                controlsSeen: draft.controls,
                rankByAbsoluteVolume: rank,
                isValidForGate: draft.tokens > 0 && draft.measuredTokenCount == draft.count
            )
        }
    }

    /// Content-free JSON export for debug/ops (no payloads, no savings fields).
    public func exportJSON(pretty: Bool = true) throws -> Data {
        lock.lock()
        let total = totalObservationCount
        let recent = observations.count
        let dropped = droppedObservationCount
        lock.unlock()
        let payload: [String: Any] = [
            "schema": "token-saver-census-v1",
            "observation_count": total,
            "recent_observation_count": recent,
            "dropped_observation_count": dropped,
            "aggregates": aggregates().map { agg -> [String: Any] in
                [
                    "binding_digest": agg.bindingDigestHex,
                    "absolute_eligible_tokens": agg.absoluteEligibleTokens,
                    "absolute_eligible_bytes": agg.absoluteEligibleBytes,
                    "observation_count": agg.observationCount,
                    "measured_token_observation_count": agg.measuredTokenObservationCount,
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

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
