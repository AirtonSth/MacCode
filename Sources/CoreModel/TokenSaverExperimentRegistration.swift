import Foundation

/// Fase 0B pre-registered experiment framework (task-05).
/// Incomplete registration cannot seal; sealed stats are immutable;
/// INCONCLUSIVE → STOP (never soft-GO). Does not promote BindingIDs.
public struct TokenSaverExperimentRegistration: Sendable, Equatable {
    public static let schemaVersion = 1
    public static let taskID = "task-05"

    public struct DeltaMargins: Sendable, Equatable {
        public let taskSuccessDelta: Double
        public let correctionsDelta: Double
        public let criticalSuppressionDelta: Double

        public init(taskSuccessDelta: Double, correctionsDelta: Double, criticalSuppressionDelta: Double) {
            self.taskSuccessDelta = taskSuccessDelta
            self.correctionsDelta = correctionsDelta
            self.criticalSuppressionDelta = criticalSuppressionDelta
        }

        public var isComplete: Bool {
            // All three Δ margins must be present as finite non-negative bounds.
            [taskSuccessDelta, correctionsDelta, criticalSuppressionDelta].allSatisfy { $0.isFinite && $0 >= 0 }
        }
    }

    public struct Statistics: Sendable, Equatable {
        public let primaryOutcome: String
        public let minimumDetectableEffect: Double
        public let margins: DeltaMargins
        public let oneSidedAlpha: Double
        public let power: Double
        public let multiplicityAdjustment: String
        public let missingnessRule: String

        public init(
            primaryOutcome: String,
            minimumDetectableEffect: Double,
            margins: DeltaMargins,
            oneSidedAlpha: Double,
            power: Double,
            multiplicityAdjustment: String,
            missingnessRule: String
        ) {
            self.primaryOutcome = primaryOutcome
            self.minimumDetectableEffect = minimumDetectableEffect
            self.margins = margins
            self.oneSidedAlpha = oneSidedAlpha
            self.power = power
            self.multiplicityAdjustment = multiplicityAdjustment
            self.missingnessRule = missingnessRule
        }

        public var isComplete: Bool {
            !primaryOutcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && minimumDetectableEffect > 0 && minimumDetectableEffect.isFinite
                && margins.isComplete
                && oneSidedAlpha > 0 && oneSidedAlpha < 0.5
                && power > 0 && power < 1
                && !multiplicityAdjustment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !missingnessRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public enum Outcome: String, Sendable, Equatable {
        case go
        case inconclusive
        case stop
    }

    public enum Decision: String, Sendable, Equatable {
        case go
        case stop
    }

    public let binding: TokenSaverBindingID
    public let statistics: Statistics
    public let isSealed: Bool

    /// Unsealed registration only. Sealing is exclusively via `sealed()`.
    public init(binding: TokenSaverBindingID, statistics: Statistics) {
        self.binding = binding
        self.statistics = statistics
        self.isSealed = false
    }

    private init(binding: TokenSaverBindingID, statistics: Statistics, sealed: Bool) {
        self.binding = binding
        self.statistics = statistics
        self.isSealed = sealed
    }

    public var canSeal: Bool { binding.isComplete && statistics.isComplete && !isSealed }

    /// Seal only when complete. Returns new sealed copy; original unchanged if incomplete.
    public func sealed() -> TokenSaverExperimentRegistration? {
        guard canSeal else { return nil }
        return TokenSaverExperimentRegistration(binding: binding, statistics: statistics, sealed: true)
    }

    /// After seal, statistics cannot be replaced (API returns nil).
    public func replacingStatistics(_ newStats: Statistics) -> TokenSaverExperimentRegistration? {
        guard !isSealed else { return nil }
        return TokenSaverExperimentRegistration(binding: binding, statistics: newStats)
    }

    /// Map experimental outcome → decision. INCONCLUSIVE is STOP, never GO.
    public static func decision(for outcome: Outcome) -> Decision {
        switch outcome {
        case .go: return .go
        case .inconclusive, .stop: return .stop
        }
    }

    /// Explicit: this type never promotes a BindingID.
    public static func promotesBindingID(_: TokenSaverBindingID) -> Bool { false }
}
