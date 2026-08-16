import Foundation

/// Content-free persistence DTO for one context-slot selection.
/// Rows never carry source, payload, handle, ABI, envelope, SHA, or billing.
public enum TokenSaverContextSelectionReceipt {
    public enum SlotRole: String, Sendable, Codable, Equatable {
        case user
        case assistant
    }

    public struct Winner: Sendable, Equatable, Codable {
        public var runId: String
        public var destinationProviderThreadId: String
        public var snapshotDigest: String
        public var sourceMessageId: String
        public var role: SlotRole
        public var ordinal: Int
        public var provider: String
        public var resolvedModel: String
        public var selectedFormat: TokenSaverRequestSelectionReceipt.SelectedFormat
        public var reason: TokenSaverBestOfThreeSelector.Reason
        public var modeledContextDelta: Int
        public var counterId: String?
        public var counterRevision: String?
        public var encoding: String?
        public var counterStatus: TokenSaverRequestSelectionReceipt.CounterStatus
        public var lifecycle: TokenSaverRequestSelectionReceipt.Lifecycle
        public var billingClaim: Bool
        public var createdAt: String?
        public var updatedAt: String?

        public init(
            runId: String,
            destinationProviderThreadId: String,
            snapshotDigest: String,
            sourceMessageId: String,
            role: SlotRole,
            ordinal: Int,
            provider: String,
            resolvedModel: String,
            selectedFormat: TokenSaverRequestSelectionReceipt.SelectedFormat,
            reason: TokenSaverBestOfThreeSelector.Reason,
            modeledContextDelta: Int,
            counterId: String?,
            counterRevision: String?,
            encoding: String?,
            counterStatus: TokenSaverRequestSelectionReceipt.CounterStatus,
            lifecycle: TokenSaverRequestSelectionReceipt.Lifecycle,
            billingClaim _: Bool = false,
            createdAt: String? = nil,
            updatedAt: String? = nil
        ) {
            self.runId = runId
            self.destinationProviderThreadId = destinationProviderThreadId
            self.snapshotDigest = snapshotDigest
            self.sourceMessageId = sourceMessageId
            self.role = role
            self.ordinal = max(0, ordinal)
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

    public struct Record: Sendable, Equatable, Codable {
        public var winner: Winner
        public var arms: [TokenSaverRequestSelectionReceipt.Arm]

        public init(winner: Winner, arms: [TokenSaverRequestSelectionReceipt.Arm]) {
            self.winner = winner
            self.arms = TokenSaverBestOfThreeSelector.Format.allCases.compactMap { format in
                arms.first { $0.format == format }
            }
        }

        public func arm(_ format: TokenSaverBestOfThreeSelector.Format) -> TokenSaverRequestSelectionReceipt.Arm? {
            arms.first { $0.format == format }
        }
    }

    public static func project(
        decision: TokenSaverBestOfThreeSelector.Decision,
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String,
        sourceMessageId: String,
        role: SlotRole,
        ordinal: Int,
        provider: String,
        resolvedModel: String,
        host: TokenSaverRequestSelectionReceipt.HostDecisions = .productionC11
    ) -> Record {
        let request = TokenSaverRequestSelectionReceipt.project(
            decision: decision,
            runId: runId,
            threadId: destinationProviderThreadId,
            provider: provider,
            resolvedModel: resolvedModel,
            host: host
        )
        let winner = Winner(
            runId: runId,
            destinationProviderThreadId: destinationProviderThreadId,
            snapshotDigest: snapshotDigest,
            sourceMessageId: sourceMessageId,
            role: role,
            ordinal: ordinal,
            provider: provider,
            resolvedModel: resolvedModel,
            selectedFormat: request.winner.selectedFormat,
            reason: request.winner.reason,
            modeledContextDelta: request.winner.modeledContextDelta,
            counterId: request.winner.counterId,
            counterRevision: request.winner.counterRevision,
            encoding: request.winner.encoding,
            counterStatus: request.winner.counterStatus,
            lifecycle: .provisional,
            billingClaim: false
        )
        return Record(winner: winner, arms: request.arms)
    }

    public static func humanUserSlot(
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String,
        sourceMessageId: String,
        ordinal: Int,
        provider: String,
        resolvedModel: String
    ) -> Record {
        let winner = Winner(
            runId: runId,
            destinationProviderThreadId: destinationProviderThreadId,
            snapshotDigest: snapshotDigest,
            sourceMessageId: sourceMessageId,
            role: .user,
            ordinal: ordinal,
            provider: provider,
            resolvedModel: resolvedModel,
            selectedFormat: .human,
            reason: .noEligibleOptimizedCandidate,
            modeledContextDelta: 0,
            counterId: nil,
            counterRevision: nil,
            encoding: nil,
            counterStatus: .unavailable,
            lifecycle: .provisional
        )
        let arms = TokenSaverBestOfThreeSelector.Format.allCases.map { format in
            TokenSaverRequestSelectionReceipt.Arm(
                runId: runId,
                format: format,
                sourceBound: format == .human,
                producerId: format == .human
                    ? TokenSaverRequestSelectionReceipt.humanProducerID
                    : (format == .rcs1
                        ? TokenSaverRequestSelectionReceipt.rcs1UnavailableProducerID
                        : TokenSaverRequestSelectionReceipt.rcw1ProducerID),
                producerRevision: format == .human ? "1" : "unavailable",
                abiRevision: format == .human ? "1" : "unavailable",
                generation: format == .human ? .notRequired : .failed,
                structural: format == .human ? .notRequired : .failed,
                semantic: format == .human ? .notRequired : .failed,
                recovery: format == .human ? .notRequired : .failed,
                projection: format == .human ? .projected : .notProjected,
                availability: format == .human ? .available : .unavailable,
                eligible: format == .human,
                provenEffectiveCount: nil
            )
        }
        return Record(winner: winner, arms: arms)
    }

    public static func identityMatches(_ lhs: Record, _ rhs: Record) -> Bool {
        lhs.winner.runId == rhs.winner.runId
            && lhs.winner.destinationProviderThreadId == rhs.winner.destinationProviderThreadId
            && lhs.winner.snapshotDigest == rhs.winner.snapshotDigest
            && lhs.winner.sourceMessageId == rhs.winner.sourceMessageId
            && lhs.winner.role == rhs.winner.role
            && lhs.winner.ordinal == rhs.winner.ordinal
            && lhs.winner.selectedFormat == rhs.winner.selectedFormat
            && lhs.winner.reason == rhs.winner.reason
            && lhs.winner.modeledContextDelta == rhs.winner.modeledContextDelta
            && lhs.winner.counterId == rhs.winner.counterId
            && lhs.winner.counterRevision == rhs.winner.counterRevision
            && lhs.winner.encoding == rhs.winner.encoding
            && lhs.winner.counterStatus == rhs.winner.counterStatus
            && lhs.arms.map(armIdentity) == rhs.arms.map(armIdentity)
    }

    private static func armIdentity(_ arm: TokenSaverRequestSelectionReceipt.Arm) -> String {
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
}

public struct TokenSaverContextSelectionLifecycleAck: Sendable, Equatable {
    public let runId: String
    public let destinationProviderThreadId: String
    public let snapshotDigest: String
    public let sourceMessageId: String
    public let ordinal: Int
    public let lifecycle: TokenSaverRequestSelectionReceipt.Lifecycle

    public init(
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String,
        sourceMessageId: String,
        ordinal: Int,
        lifecycle: TokenSaverRequestSelectionReceipt.Lifecycle
    ) {
        self.runId = runId
        self.destinationProviderThreadId = destinationProviderThreadId
        self.snapshotDigest = snapshotDigest
        self.sourceMessageId = sourceMessageId
        self.ordinal = ordinal
        self.lifecycle = lifecycle
    }
}

public struct TokenSaverPreparedContextSeed: Sendable, Equatable {
    public let encoded: String
    public let document: TokenSaverContextSeed.Document
    public let receipts: [TokenSaverContextSelectionReceipt.Record]

    public init(
        encoded: String,
        document: TokenSaverContextSeed.Document,
        receipts: [TokenSaverContextSelectionReceipt.Record]
    ) {
        self.encoded = encoded
        self.document = document
        self.receipts = receipts
    }
}

public enum TokenSaverContextSelectionReceiptError: Error, Equatable {
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
