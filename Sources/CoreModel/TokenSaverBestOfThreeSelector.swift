import CryptoKit
import Foundation

/// Provider-neutral selection for one canonical Human payload and three final
/// provider-visible envelopes.
///
/// The selector invokes one package-owned counter capability on the exact bytes
/// it ranks. Counts are modeled context, never billing evidence. Any uncertainty
/// or operational error preserves the canonical Human bytes.
public enum TokenSaverBestOfThreeSelector {
    public enum Format: String, Sendable, Codable, CaseIterable {
        case human
        case rcw1
        case caveman
    }

    public enum GateStatus: String, Sendable, Codable {
        case passed
        case failed
        case unknown
        case notRequired = "not_required"
    }

    public enum CounterQuality: String, Sendable, Codable {
        case exactLocalTokenizer = "exact_local_tokenizer"
        case exactResolvedModelTokenizer = "exact_resolved_model_tokenizer"
        case estimated
        case unknown

        fileprivate var isExact: Bool {
            self == .exactLocalTokenizer || self == .exactResolvedModelTokenizer
        }
    }

    public enum Reason: String, Sendable, Codable {
        case uniqueStrictMinimum = "unique_strict_minimum"
        case humanLowestCost = "human_lowest_cost"
        case tie
        case noEligibleOptimizedCandidate = "no_eligible_optimized_candidate"
        case counterUnavailable = "counter_unavailable"
        case counterUncertain = "counter_uncertain"
        case counterError = "counter_error"
        case counterBindingMismatch = "counter_binding_mismatch"
        case candidateError = "candidate_error"
        case candidateUnknown = "candidate_unknown"
        case invalidMeasurement = "invalid_measurement"
    }

    public struct Target: Sendable, Equatable, Codable {
        public let provider: String
        public let resolvedModel: String
        public let counterID: String
        public let counterRevision: String
        public let encoding: String

        package init(
            provider: String,
            resolvedModel: String,
            counterID: String,
            counterRevision: String,
            encoding: String
        ) {
            self.provider = provider
            self.resolvedModel = resolvedModel
            self.counterID = counterID
            self.counterRevision = counterRevision
            self.encoding = encoding
        }
    }

    public struct Candidate: Sendable, Equatable {
        public let format: Format
        public let sourceSHA256: String
        public let payload: String
        public let abi: String
        public let effectiveEnvelope: String
        public let handle: String?
        public let producerID: String
        public let producerRevision: String
        public let abiRevision: String
        public let generation: GateStatus
        public let structural: GateStatus
        public let semantic: GateStatus
        public let recovery: GateStatus

        package init(
            format: Format,
            sourceSHA256: String,
            payload: String,
            abi: String,
            effectiveEnvelope: String,
            handle: String?,
            producerID: String,
            producerRevision: String,
            abiRevision: String,
            generation: GateStatus,
            structural: GateStatus,
            semantic: GateStatus,
            recovery: GateStatus
        ) {
            self.format = format
            self.sourceSHA256 = sourceSHA256
            self.payload = payload
            self.abi = abi
            self.effectiveEnvelope = effectiveEnvelope
            self.handle = handle
            self.producerID = producerID
            self.producerRevision = producerRevision
            self.abiRevision = abiRevision
            self.generation = generation
            self.structural = structural
            self.semantic = semantic
            self.recovery = recovery
        }
    }

    public struct Counter: Sendable, Equatable, Codable {
        public let id: String
        public let revision: String
        public let encoding: String
        public let provider: String
        public let resolvedModel: String
        public let quality: CounterQuality

        package init(
            id: String,
            revision: String,
            encoding: String,
            provider: String,
            resolvedModel: String,
            quality: CounterQuality
        ) {
            self.id = id
            self.revision = revision
            self.encoding = encoding
            self.provider = provider
            self.resolvedModel = resolvedModel
            self.quality = quality
        }
    }

    /// The only package entry point for lexical evidence. The selector, not the
    /// consumer, chooses every string passed to this capability.
    package struct CounterCapability: Sendable {
        package let counter: Counter
        fileprivate let count: @Sendable (String) async throws -> Int

        package init(
            counter: Counter,
            count: @escaping @Sendable (String) async throws -> Int
        ) {
            self.counter = counter
            self.count = count
        }
    }

    public struct Cost: Sendable, Equatable, Codable {
        public let format: Format
        public let payloadSHA256: String
        public let handleSHA256: String?
        public let abiSHA256: String?
        public let effectiveEnvelopeSHA256: String
        public let payloadTokensIncludingHandle: Int
        public let handleTokens: Int
        public let abiTokens: Int
        public let effectiveEnvelopeTokens: Int

        fileprivate init(
            format: Format,
            payloadSHA256: String,
            handleSHA256: String?,
            abiSHA256: String?,
            effectiveEnvelopeSHA256: String,
            payloadTokensIncludingHandle: Int,
            handleTokens: Int,
            abiTokens: Int,
            effectiveEnvelopeTokens: Int
        ) {
            self.format = format
            self.payloadSHA256 = payloadSHA256
            self.handleSHA256 = handleSHA256
            self.abiSHA256 = abiSHA256
            self.effectiveEnvelopeSHA256 = effectiveEnvelopeSHA256
            self.payloadTokensIncludingHandle = payloadTokensIncludingHandle
            self.handleTokens = handleTokens
            self.abiTokens = abiTokens
            self.effectiveEnvelopeTokens = effectiveEnvelopeTokens
        }
    }

    public struct ArmReceipt: Sendable, Equatable, Codable {
        public let format: Format
        public let sourceBound: Bool
        public let producerID: String
        public let producerRevision: String
        public let abiRevision: String
        public let generation: GateStatus
        public let structural: GateStatus
        public let semantic: GateStatus
        public let recovery: GateStatus
        public let eligible: Bool
    }

    /// Durable audit data deliberately excludes canonical and candidate text.
    public struct DecisionReceipt: Sendable, Equatable, Codable {
        public let sourceSHA256: String
        public let selectedFormat: Format
        public let reason: Reason
        public let modeledContextDelta: Int
        public let counter: Counter?
        public let costs: [Cost]
        public let arms: [ArmReceipt]
        public let billingClaim: Bool
    }

    public struct Decision: Sendable, Equatable {
        public let sourceSHA256: String
        public let selectedFormat: Format
        public let selectedPayload: String
        public let reason: Reason
        public let modeledContextDelta: Int
        public let counter: Counter?
        public let costs: [Cost]
        public let arms: [ArmReceipt]

        public var billingClaim: Bool { false }

        public var receipt: DecisionReceipt {
            DecisionReceipt(
                sourceSHA256: sourceSHA256,
                selectedFormat: selectedFormat,
                reason: reason,
                modeledContextDelta: modeledContextDelta,
                counter: counter,
                costs: costs,
                arms: arms,
                billingClaim: false
            )
        }

        public func cost(_ format: Format) -> Cost? {
            costs.first { $0.format == format }
        }

        public func arm(_ format: Format) -> ArmReceipt? {
            arms.first { $0.format == format }
        }
    }

    package static func select(
        canonicalHuman: String,
        humanEffectiveEnvelope: String,
        target: Target,
        candidates: [Candidate],
        counter capability: CounterCapability?
    ) async -> Decision {
        let sourceSHA256 = sha256Hex(canonicalHuman)
        let arms = candidates
            .map { armReceipt($0, sourceSHA256: sourceSHA256) }
            .sorted { formatRank($0.format) < formatRank($1.format) }

        func human(
            _ reason: Reason,
            counter: Counter? = capability?.counter,
            costs: [Cost] = []
        ) -> Decision {
            Decision(
                sourceSHA256: sourceSHA256,
                selectedFormat: .human,
                selectedPayload: canonicalHuman,
                reason: reason,
                modeledContextDelta: 0,
                counter: counter,
                costs: costs,
                arms: arms
            )
        }

        guard !canonicalHuman.isEmpty,
              !humanEffectiveEnvelope.isEmpty,
              occursExactlyOnce(canonicalHuman, in: humanEffectiveEnvelope),
              validTarget(target),
              candidates.count == 2,
              Set(candidates.map(\.format)) == Set([.rcw1, .caveman]),
              candidates.allSatisfy(validCandidateIdentity) else {
            return human(.candidateError)
        }
        if candidates.contains(where: { $0.generation == .failed || $0.generation == .notRequired }) {
            return human(.candidateError)
        }
        if candidates.contains(where: hasUnknownRequiredGate) {
            return human(.candidateUnknown)
        }
        guard let capability else {
            return human(.counterUnavailable, counter: nil)
        }
        guard capability.counter.quality.isExact else {
            return human(.counterUncertain)
        }
        guard counter(capability.counter, matches: target) else {
            return human(.counterBindingMismatch)
        }

        let costs: [Cost]
        do {
            costs = try await measure(
                canonicalHuman: canonicalHuman,
                humanEffectiveEnvelope: humanEffectiveEnvelope,
                candidates: candidates,
                with: capability
            )
        } catch MeasurementFailure.invalid {
            return human(.invalidMeasurement)
        } catch {
            return human(.counterError)
        }

        let costsByFormat = Dictionary(uniqueKeysWithValues: costs.map { ($0.format, $0) })
        let eligibleOptimized = arms.filter(\.eligible).map(\.format)
        guard !eligibleOptimized.isEmpty else {
            return human(.noEligibleOptimizedCandidate, costs: costs)
        }

        let eligibleFormats = [Format.human] + eligibleOptimized
        guard let minimum = eligibleFormats.compactMap({
            costsByFormat[$0]?.effectiveEnvelopeTokens
        }).min() else {
            return human(.invalidMeasurement, costs: costs)
        }
        let winners = eligibleFormats.filter {
            costsByFormat[$0]?.effectiveEnvelopeTokens == minimum
        }
        guard winners.count == 1, let winner = winners.first else {
            return human(.tie, costs: costs)
        }
        guard winner != .human else {
            return human(.humanLowestCost, costs: costs)
        }
        guard let selected = candidates.first(where: { $0.format == winner }),
              let humanTokens = costsByFormat[.human]?.effectiveEnvelopeTokens,
              let winnerTokens = costsByFormat[winner]?.effectiveEnvelopeTokens,
              winnerTokens < humanTokens else {
            return human(.humanLowestCost, costs: costs)
        }
        return Decision(
            sourceSHA256: sourceSHA256,
            selectedFormat: winner,
            selectedPayload: selected.payload,
            reason: .uniqueStrictMinimum,
            modeledContextDelta: humanTokens - winnerTokens,
            counter: capability.counter,
            costs: costs,
            arms: arms
        )
    }

    private static func measure(
        canonicalHuman: String,
        humanEffectiveEnvelope: String,
        candidates: [Candidate],
        with capability: CounterCapability
    ) async throws -> [Cost] {
        let humanPayloadTokens = try await positiveCount(canonicalHuman, with: capability)
        let humanEnvelopeTokens = try await positiveCount(humanEffectiveEnvelope, with: capability)
        var costs = [Cost(
            format: .human,
            payloadSHA256: sha256Hex(canonicalHuman),
            handleSHA256: nil,
            abiSHA256: nil,
            effectiveEnvelopeSHA256: sha256Hex(humanEffectiveEnvelope),
            payloadTokensIncludingHandle: humanPayloadTokens,
            handleTokens: 0,
            abiTokens: 0,
            effectiveEnvelopeTokens: humanEnvelopeTokens
        )]
        for candidate in candidates.sorted(by: { formatRank($0.format) < formatRank($1.format) }) {
            let payloadTokens = try await positiveCount(candidate.payload, with: capability)
            let handleTokens: Int
            if let handle = candidate.handle {
                handleTokens = try await positiveCount(handle, with: capability)
            } else {
                handleTokens = 0
            }
            let abiTokens = try await positiveCount(candidate.abi, with: capability)
            let envelopeTokens = try await positiveCount(candidate.effectiveEnvelope, with: capability)
            costs.append(Cost(
                format: candidate.format,
                payloadSHA256: sha256Hex(candidate.payload),
                handleSHA256: candidate.handle.map(sha256Hex),
                abiSHA256: sha256Hex(candidate.abi),
                effectiveEnvelopeSHA256: sha256Hex(candidate.effectiveEnvelope),
                payloadTokensIncludingHandle: payloadTokens,
                handleTokens: handleTokens,
                abiTokens: abiTokens,
                effectiveEnvelopeTokens: envelopeTokens
            ))
        }
        return costs
    }

    private static func positiveCount(
        _ text: String,
        with capability: CounterCapability
    ) async throws -> Int {
        let count = try await capability.count(text)
        guard count > 0 else { throw MeasurementFailure.invalid }
        return count
    }

    private static func armReceipt(
        _ candidate: Candidate,
        sourceSHA256: String
    ) -> ArmReceipt {
        let sourceBound = candidate.sourceSHA256 == sourceSHA256
        return ArmReceipt(
            format: candidate.format,
            sourceBound: sourceBound,
            producerID: candidate.producerID,
            producerRevision: candidate.producerRevision,
            abiRevision: candidate.abiRevision,
            generation: candidate.generation,
            structural: candidate.structural,
            semantic: candidate.semantic,
            recovery: candidate.recovery,
            eligible: validCandidateIdentity(candidate)
                && sourceBound
                && candidate.generation == .passed
                && candidate.structural == .passed
                && candidate.semantic == .passed
                && candidate.recovery == .passed
        )
    }

    private static func validCandidateIdentity(_ candidate: Candidate) -> Bool {
        guard !candidate.payload.isEmpty,
              !candidate.abi.isEmpty,
              !candidate.effectiveEnvelope.isEmpty,
              [candidate.producerID, candidate.producerRevision, candidate.abiRevision]
                .allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              occursExactlyOnce(candidate.payload, in: candidate.effectiveEnvelope),
              occursExactlyOnce(candidate.abi, in: candidate.effectiveEnvelope) else {
            return false
        }
        guard let handle = candidate.handle else { return true }
        return handle == handle.trimmingCharacters(in: .whitespacesAndNewlines)
            && !handle.isEmpty
            && !handle.contains(where: \.isWhitespace)
            && occursExactlyOnce(handle, in: candidate.payload)
    }

    private static func hasUnknownRequiredGate(_ candidate: Candidate) -> Bool {
        candidate.generation == .unknown
            || candidate.structural == .unknown
            || candidate.structural == .notRequired
            || candidate.semantic == .unknown
            || candidate.semantic == .notRequired
            || candidate.recovery == .unknown
    }

    private static func validTarget(_ target: Target) -> Bool {
        [target.provider, target.resolvedModel, target.counterID, target.counterRevision, target.encoding]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func counter(_ counter: Counter, matches target: Target) -> Bool {
        counter.provider == target.provider
            && counter.resolvedModel == target.resolvedModel
            && counter.id == target.counterID
            && counter.revision == target.counterRevision
            && counter.encoding == target.encoding
    }

    private static func occursExactlyOnce(_ needle: String, in text: String) -> Bool {
        guard !needle.isEmpty, let first = text.range(of: needle) else { return false }
        return text[first.upperBound...].range(of: needle) == nil
    }

    private static func formatRank(_ format: Format) -> Int {
        Format.allCases.firstIndex(of: format) ?? Format.allCases.count
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private enum MeasurementFailure: Error {
        case invalid
    }
}
