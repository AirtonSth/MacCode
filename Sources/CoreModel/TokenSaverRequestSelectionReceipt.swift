import Foundation

/// Content-free persistence DTO for one typed request-selection Decision.
/// Rows never carry source, payload, handle, ABI, envelope, SHA, or billing.
public enum TokenSaverRequestSelectionReceipt {
    public static let humanProducerID = "remotecode-human"
    public static let rcw1ProducerID = "remotecode-rcw1"
    public static let rcs1ProducerID = "remotecode-rcs1"
    public static let rcs1UnavailableProducerID = "remotecode-rcs1-unavailable"

    public enum SelectedFormat: String, Sendable, Codable, Equatable {
        case human
        case rcw1
        case rcs1
    }

    public enum Lifecycle: String, Sendable, Codable, Equatable {
        case provisional
        case delivered
        case notDelivered = "not_delivered"
        case deliveryUnknown = "delivery_unknown"
    }

    public enum CounterStatus: String, Sendable, Codable, Equatable {
        case exactLocalTokenizer = "exact_local_tokenizer"
        case exactResolvedModelTokenizer = "exact_resolved_model_tokenizer"
        case unavailable
        case uncertain
        case error
        case bindingMismatch = "binding_mismatch"
    }

    public enum ProjectionStatus: String, Sendable, Codable, Equatable {
        case projected
        case notProjected = "not_projected"
        case unknown
    }

    public enum AvailabilityStatus: String, Sendable, Codable, Equatable {
        case available
        case unavailable
        case unknown
    }

    public struct HostArmDecision: Sendable, Equatable {
        public var projection: ProjectionStatus
        public var availability: AvailabilityStatus

        public init(projection: ProjectionStatus, availability: AvailabilityStatus) {
            self.projection = projection
            self.availability = availability
        }
    }

    public struct HostDecisions: Sendable, Equatable {
        public var human: HostArmDecision
        public var rcw1: HostArmDecision
        public var rcs1: HostArmDecision

        public static let productionC11 = HostDecisions(
            human: HostArmDecision(projection: .projected, availability: .available),
            rcw1: HostArmDecision(projection: .projected, availability: .available),
            rcs1: HostArmDecision(projection: .projected, availability: .available)
        )

        public init(human: HostArmDecision, rcw1: HostArmDecision, rcs1: HostArmDecision) {
            self.human = human
            self.rcw1 = rcw1
            self.rcs1 = rcs1
        }

        public func state(for format: TokenSaverBestOfThreeSelector.Format) -> HostArmDecision {
            switch format {
            case .human: return human
            case .rcw1: return rcw1
            case .rcs1: return rcs1
            }
        }
    }

    public struct Winner: Sendable, Equatable, Codable {
        public var runId: String
        public var threadId: String
        public var provider: String
        public var resolvedModel: String
        public var selectedFormat: SelectedFormat
        public var reason: TokenSaverBestOfThreeSelector.Reason
        public var modeledContextDelta: Int
        public var counterId: String?
        public var counterRevision: String?
        public var encoding: String?
        public var counterStatus: CounterStatus
        public var lifecycle: Lifecycle
        public var billingClaim: Bool
        public var createdAt: String?
        public var updatedAt: String?

        public init(
            runId: String,
            threadId: String,
            provider: String,
            resolvedModel: String,
            selectedFormat: SelectedFormat,
            reason: TokenSaverBestOfThreeSelector.Reason,
            modeledContextDelta: Int,
            counterId: String?,
            counterRevision: String?,
            encoding: String?,
            counterStatus: CounterStatus,
            lifecycle: Lifecycle,
            billingClaim _: Bool = false,
            createdAt: String? = nil,
            updatedAt: String? = nil
        ) {
            self.runId = runId
            self.threadId = threadId
            self.provider = provider
            self.resolvedModel = resolvedModel
            self.selectedFormat = selectedFormat
            self.reason = reason
            self.modeledContextDelta = max(0, modeledContextDelta)
            self.counterStatus = counterStatus
            if counterStatus == .exactLocalTokenizer || counterStatus == .exactResolvedModelTokenizer {
                self.counterId = counterId
                self.counterRevision = counterRevision
                self.encoding = encoding
            } else {
                self.counterId = nil
                self.counterRevision = nil
                self.encoding = nil
            }
            self.lifecycle = lifecycle
            self.billingClaim = false
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    public struct Arm: Sendable, Equatable, Codable {
        public var runId: String
        public var format: TokenSaverBestOfThreeSelector.Format
        public var sourceBound: Bool
        public var producerId: String
        public var producerRevision: String
        public var abiRevision: String
        public var generation: TokenSaverBestOfThreeSelector.GateStatus
        public var structural: TokenSaverBestOfThreeSelector.GateStatus
        public var semantic: TokenSaverBestOfThreeSelector.GateStatus
        public var recovery: TokenSaverBestOfThreeSelector.GateStatus
        public var projection: ProjectionStatus
        public var availability: AvailabilityStatus
        public var eligible: Bool
        public var provenEffectiveCount: Int?

        public init(
            runId: String,
            format: TokenSaverBestOfThreeSelector.Format,
            sourceBound: Bool,
            producerId: String,
            producerRevision: String,
            abiRevision: String,
            generation: TokenSaverBestOfThreeSelector.GateStatus,
            structural: TokenSaverBestOfThreeSelector.GateStatus,
            semantic: TokenSaverBestOfThreeSelector.GateStatus,
            recovery: TokenSaverBestOfThreeSelector.GateStatus,
            projection: ProjectionStatus,
            availability: AvailabilityStatus,
            eligible: Bool,
            provenEffectiveCount: Int?
        ) {
            self.runId = runId
            self.format = format
            self.sourceBound = sourceBound
            self.producerId = producerId
            self.producerRevision = producerRevision
            self.abiRevision = abiRevision
            self.generation = generation
            self.structural = structural
            self.semantic = semantic
            self.recovery = recovery
            self.projection = projection
            self.availability = availability
            self.eligible = eligible
            self.provenEffectiveCount = provenEffectiveCount.flatMap { $0 >= 0 ? $0 : nil }
        }
    }

    public struct Record: Sendable, Equatable, Codable {
        public var winner: Winner
        public var arms: [Arm]

        public init(winner: Winner, arms: [Arm]) {
            self.winner = winner
            self.arms = TokenSaverBestOfThreeSelector.Format.allCases.compactMap { format in
                arms.first { $0.format == format }
            }
        }

        public func arm(_ format: TokenSaverBestOfThreeSelector.Format) -> Arm? {
            arms.first { $0.format == format }
        }

        public func withBillingClaimForTest(_ value: Bool) -> Record {
            var next = self
            next.winner.billingClaim = value
            return next
        }

        public func withReasonForTest(_ reason: TokenSaverBestOfThreeSelector.Reason) -> Record {
            var next = self
            next.winner.reason = reason
            return next
        }
    }

    public struct Report: Sendable, Equatable, Codable {
        public var records: [Record]

        public init(records: [Record]) {
            self.records = records
        }
    }

    /// Project the live Decision after binding and host availability. RCS1 is a
    /// first-class selected format when the Decision chose it.
    public static func project(
        decision: TokenSaverBestOfThreeSelector.Decision,
        runId: String,
        threadId: String,
        provider: String,
        resolvedModel: String,
        host: HostDecisions = .productionC11
    ) -> Record {
        let selectedFormat: SelectedFormat
        switch decision.selectedFormat {
        case .human: selectedFormat = .human
        case .rcw1: selectedFormat = .rcw1
        case .rcs1: selectedFormat = .rcs1
        }
        let reason = decision.reason
        let delta = selectedFormat == .human ? 0 : max(0, decision.modeledContextDelta)
        let counterStatus = counterStatus(for: decision)
        let exact = counterStatus == .exactLocalTokenizer
            || counterStatus == .exactResolvedModelTokenizer
        let winner = Winner(
            runId: runId,
            threadId: threadId,
            provider: provider,
            resolvedModel: resolvedModel,
            selectedFormat: selectedFormat,
            reason: reason,
            modeledContextDelta: delta,
            counterId: exact ? decision.counter?.id : nil,
            counterRevision: exact ? decision.counter?.revision : nil,
            encoding: exact ? decision.counter?.encoding : nil,
            counterStatus: counterStatus,
            lifecycle: .provisional,
            billingClaim: false
        )
        let arms = TokenSaverBestOfThreeSelector.Format.allCases.map { format in
            arm(
                format,
                decision: decision,
                runId: runId,
                host: host.state(for: format),
                exact: exact
            )
        }
        return Record(winner: winner, arms: arms)
    }

    public static func encodeReport(_ report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(report)
    }

    public static func identityMatches(_ lhs: Record, _ rhs: Record) -> Bool {
        winnerIdentity(lhs.winner) == winnerIdentity(rhs.winner)
            && lhs.arms.map(armIdentity) == rhs.arms.map(armIdentity)
    }

    private static func winnerIdentity(_ winner: Winner) -> String {
        [
            winner.runId,
            winner.threadId,
            winner.provider,
            winner.resolvedModel,
            winner.selectedFormat.rawValue,
            winner.reason.rawValue,
            String(winner.modeledContextDelta),
            winner.counterId ?? "",
            winner.counterRevision ?? "",
            winner.encoding ?? "",
            winner.counterStatus.rawValue,
        ].joined(separator: "\u{1e}")
    }

    private static func armIdentity(_ arm: Arm) -> String {
        [
            arm.runId,
            arm.format.rawValue,
            arm.sourceBound ? "1" : "0",
            arm.producerId,
            arm.producerRevision,
            arm.abiRevision,
            arm.generation.rawValue,
            arm.structural.rawValue,
            arm.semantic.rawValue,
            arm.recovery.rawValue,
            arm.projection.rawValue,
            arm.availability.rawValue,
            arm.eligible ? "1" : "0",
            arm.provenEffectiveCount.map(String.init) ?? "",
        ].joined(separator: "\u{1e}")
    }

    private static func counterStatus(
        for decision: TokenSaverBestOfThreeSelector.Decision
    ) -> CounterStatus {
        switch decision.reason {
        case .counterBindingMismatch:
            return .bindingMismatch
        case .counterError:
            return .error
        case .counterUncertain:
            return .uncertain
        case .counterUnavailable:
            return .unavailable
        default:
            break
        }
        guard let counter = decision.counter else { return .unavailable }
        switch counter.quality {
        case .exactLocalTokenizer:
            return .exactLocalTokenizer
        case .exactResolvedModelTokenizer:
            return .exactResolvedModelTokenizer
        case .estimated, .unknown:
            return .uncertain
        }
    }

    private static func arm(
        _ format: TokenSaverBestOfThreeSelector.Format,
        decision: TokenSaverBestOfThreeSelector.Decision,
        runId: String,
        host: HostArmDecision,
        exact: Bool
    ) -> Arm {
        if format == .human {
            let projected = host.projection == .projected && host.availability == .available
            let count = (exact && projected)
                ? decision.cost(.human)?.effectiveEnvelopeTokens
                : nil
            return Arm(
                runId: runId,
                format: .human,
                sourceBound: true,
                producerId: humanProducerID,
                producerRevision: "1",
                abiRevision: "1",
                generation: .notRequired,
                structural: .notRequired,
                semantic: .notRequired,
                recovery: .notRequired,
                projection: host.projection,
                availability: host.availability,
                eligible: true,
                provenEffectiveCount: count
            )
        }
        if let existing = decision.arm(format) {
            let projected = existing.eligible
                && host.projection == .projected
                && host.availability == .available
            let count = (exact && projected)
                ? decision.cost(format)?.effectiveEnvelopeTokens
                : nil
            return Arm(
                runId: runId,
                format: format,
                sourceBound: existing.sourceBound,
                producerId: existing.producerID,
                producerRevision: existing.producerRevision,
                abiRevision: existing.abiRevision,
                generation: existing.generation,
                structural: existing.structural,
                semantic: existing.semantic,
                recovery: existing.recovery,
                projection: host.projection,
                availability: host.availability,
                eligible: existing.eligible,
                provenEffectiveCount: count
            )
        }
        return Arm(
            runId: runId,
            format: format,
            sourceBound: false,
            producerId: format == .rcs1 ? rcs1UnavailableProducerID : rcw1ProducerID,
            producerRevision: "unavailable",
            abiRevision: "unavailable",
            generation: .failed,
            structural: .failed,
            semantic: .failed,
            recovery: .failed,
            projection: .notProjected,
            availability: .unavailable,
            eligible: false,
            provenEffectiveCount: nil
        )
    }
}

public struct TokenSaverRequestSelectionLifecycleAck: Sendable, Equatable {
    public let runId: String
    public let lifecycle: TokenSaverRequestSelectionReceipt.Lifecycle

    public init(runId: String, lifecycle: TokenSaverRequestSelectionReceipt.Lifecycle) {
        self.runId = runId
        self.lifecycle = lifecycle
    }
}

public enum TokenSaverRequestSelectionReceiptError: Error, Equatable {
    case identityMismatch(runId: String)
    case missingReceipt(runId: String)
    case illegalLifecycleTransition(
        runId: String,
        from: TokenSaverRequestSelectionReceipt.Lifecycle,
        to: TokenSaverRequestSelectionReceipt.Lifecycle
    )
    case invalidArmSet
    case runIdentityMismatch
}
