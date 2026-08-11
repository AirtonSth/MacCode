import Foundation

/// Pure pressure governor transition table (plan-optimize-swift S1/S7 / T-003).
///
/// Rules:
/// - OS critical/warning has immediate precedence.
/// - Complete managed-RSS samples may escalate after two samples at/above tier.
/// - Incomplete/stale samples never clear pressure and never trigger destructive action.
/// - Exit warning/critical requires three fresh samples below (threshold − 8pp)
///   and a minimum 60-second dwell.
/// - Epoch IDs are monotonic; actions are idempotent; recovery is rate-limited.
/// - No schedule deferral and no kill-active-turn actions exist in this table.

public enum PressureOSSignal: String, Sendable, Codable, Equatable {
    case normal
    case warning
    case critical
}

public enum PressureLevel: String, Sendable, Codable, Equatable, Comparable {
    case normal
    case warning
    case critical

    public static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }
}

public enum PressureActionKind: String, Sendable, Codable, Equatable, CaseIterable {
    case reclaimHiddenRecomputableUI
    case shortenCompletedIdleProviderSessions
    case releaseDistillIdleModelGPU
    case pauseGraphifyEnsureAndWatchCallbacks
    case deferMaintenancePrune
    case resumeOptionalWorkUnit
    /// Explicit non-actions preserved as documentation of the cut features.
    case neverKillActiveTurn
    case neverDeferScheduledOccurrence
}

public struct PressureSample: Sendable, Equatable {
    public var date: Date
    /// OS memory pressure signal when available.
    public var osSignal: PressureOSSignal
    /// Fraction of physical memory used by managed host accounting (0...1+).
    public var managedRSSFraction: Double?
    public var isComplete: Bool
    public var isStale: Bool

    public init(
        date: Date,
        osSignal: PressureOSSignal = .normal,
        managedRSSFraction: Double?,
        isComplete: Bool,
        isStale: Bool = false
    ) {
        self.date = date
        self.osSignal = osSignal
        self.managedRSSFraction = managedRSSFraction
        self.isComplete = isComplete
        self.isStale = isStale
    }
}

public struct PressureThresholds: Sendable, Equatable {
    public var warningFraction: Double
    public var criticalFraction: Double
    /// Exit requires samples below tier threshold minus this absolute fraction (8pp).
    public var exitHysteresisPoints: Double
    public var escalateSampleCount: Int
    public var recoverSampleCount: Int
    public var minDwellSeconds: TimeInterval
    public var recoveryMinIntervalSeconds: TimeInterval

    public static let `default` = PressureThresholds(
        warningFraction: 0.75,
        criticalFraction: 0.90,
        exitHysteresisPoints: 0.08,
        escalateSampleCount: 2,
        recoverSampleCount: 3,
        minDwellSeconds: 60,
        recoveryMinIntervalSeconds: 5
    )

    public init(
        warningFraction: Double,
        criticalFraction: Double,
        exitHysteresisPoints: Double = 0.08,
        escalateSampleCount: Int = 2,
        recoverSampleCount: Int = 3,
        minDwellSeconds: TimeInterval = 60,
        recoveryMinIntervalSeconds: TimeInterval = 5
    ) {
        self.warningFraction = warningFraction
        self.criticalFraction = criticalFraction
        self.exitHysteresisPoints = exitHysteresisPoints
        self.escalateSampleCount = escalateSampleCount
        self.recoverSampleCount = recoverSampleCount
        self.minDwellSeconds = minDwellSeconds
        self.recoveryMinIntervalSeconds = recoveryMinIntervalSeconds
    }
}

public struct PressureGovernorState: Sendable, Equatable {
    public var level: PressureLevel
    public var epoch: UInt64
    public var levelEnteredAt: Date
    /// Consecutive complete RSS samples observed at/above `escalateTargetLevel`.
    public var consecutiveEscalateSamples: Int
    /// The pressure tier currently being accumulated toward (tier-specific).
    public var escalateTargetLevel: PressureLevel?
    /// Consecutive complete samples below the exit band of `level` (for one-step recovery).
    public var consecutiveRecoverSamples: Int
    public var lastActionKey: String?
    public var lastActionAt: Date?
    public var lastRecoveryAt: Date?
    public var frozenAccounting: Bool
    public var actionCount: Int
    /// Actions emitted for the current epoch (bounded; holds do not re-emit).
    public var actionsEmittedThisEpoch: Int

    public init(
        level: PressureLevel = .normal,
        epoch: UInt64 = 0,
        levelEnteredAt: Date = Date(timeIntervalSince1970: 0),
        consecutiveEscalateSamples: Int = 0,
        escalateTargetLevel: PressureLevel? = nil,
        consecutiveRecoverSamples: Int = 0,
        lastActionKey: String? = nil,
        lastActionAt: Date? = nil,
        lastRecoveryAt: Date? = nil,
        frozenAccounting: Bool = false,
        actionCount: Int = 0,
        actionsEmittedThisEpoch: Int = 0
    ) {
        self.level = level
        self.epoch = epoch
        self.levelEnteredAt = levelEnteredAt
        self.consecutiveEscalateSamples = consecutiveEscalateSamples
        self.escalateTargetLevel = escalateTargetLevel
        self.consecutiveRecoverSamples = consecutiveRecoverSamples
        self.lastActionKey = lastActionKey
        self.lastActionAt = lastActionAt
        self.lastRecoveryAt = lastRecoveryAt
        self.frozenAccounting = frozenAccounting
        self.actionCount = actionCount
        self.actionsEmittedThisEpoch = actionsEmittedThisEpoch
    }
}

public struct PressureTransitionResult: Sendable, Equatable {
    public var state: PressureGovernorState
    public var emittedActions: [PressureActionKind]
    public var levelChanged: Bool
    public var ignoredReason: String?

    public init(
        state: PressureGovernorState,
        emittedActions: [PressureActionKind] = [],
        levelChanged: Bool = false,
        ignoredReason: String? = nil
    ) {
        self.state = state
        self.emittedActions = emittedActions
        self.levelChanged = levelChanged
        self.ignoredReason = ignoredReason
    }
}

public enum PressureGovernorStateMachine {
    /// Warning ladder: optional/recomputable work only.
    public static let warningActions: [PressureActionKind] = [
        .reclaimHiddenRecomputableUI,
        .shortenCompletedIdleProviderSessions,
        .releaseDistillIdleModelGPU,
        .pauseGraphifyEnsureAndWatchCallbacks,
        .deferMaintenancePrune,
    ]

    /// Critical repeats warning more aggressively; still never kills or defers schedule.
    public static let criticalActions: [PressureActionKind] = warningActions

    public static func levelFromOS(_ os: PressureOSSignal) -> PressureLevel {
        switch os {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        }
    }

    public static func levelFromRSS(
        fraction: Double,
        thresholds: PressureThresholds
    ) -> PressureLevel {
        if fraction >= thresholds.criticalFraction { return .critical }
        if fraction >= thresholds.warningFraction { return .warning }
        return .normal
    }

    /// Apply one sample. Pure: no I/O, no process signals.
    ///
    /// RSS escalation is **tier-specific**: two consecutive complete samples at
    /// or above a given target tier are required before entering that tier.
    /// Recovery steps **one level at a time** (critical→warning→normal), each
    /// requiring dwell + three fresh samples below that level's exit band.
    public static func apply(
        state: PressureGovernorState,
        sample: PressureSample,
        thresholds: PressureThresholds = .default,
        now: Date? = nil
    ) -> PressureTransitionResult {
        let clock = now ?? sample.date
        var next = state

        // Incomplete/stale: freeze actions; never clear pressure; never escalate on RSS.
        if sample.isStale || !sample.isComplete || sample.managedRSSFraction == nil {
            next.frozenAccounting = true
            next.consecutiveEscalateSamples = 0
            next.escalateTargetLevel = nil
            // OS signal still has immediate precedence for escalation.
            let osLevel = levelFromOS(sample.osSignal)
            if osLevel > next.level {
                return escalate(state: next, to: osLevel, at: clock, reason: "os_signal")
            }
            return PressureTransitionResult(
                state: next,
                emittedActions: [],
                levelChanged: false,
                ignoredReason: sample.isStale ? "stale_sample" : "incomplete_sample"
            )
        }

        next.frozenAccounting = false
        let osLevel = levelFromOS(sample.osSignal)
        let rssLevel = levelFromRSS(fraction: sample.managedRSSFraction!, thresholds: thresholds)
        // OS has immediate precedence when higher than current.
        if osLevel > next.level {
            return escalate(state: next, to: osLevel, at: clock, reason: "os_signal")
        }

        let observed = max(osLevel, rssLevel)

        if observed > next.level {
            next.consecutiveRecoverSamples = 0
            // Tier-specific streak: only accumulate toward the same target.
            if next.escalateTargetLevel != observed {
                next.escalateTargetLevel = observed
                next.consecutiveEscalateSamples = 1
            } else {
                next.consecutiveEscalateSamples += 1
            }
            if next.consecutiveEscalateSamples >= thresholds.escalateSampleCount {
                return escalate(state: next, to: observed, at: clock, reason: "rss_samples")
            }
            return PressureTransitionResult(state: next)
        }

        // Observed is not higher — reset escalate streak for any other tier.
        next.consecutiveEscalateSamples = 0
        next.escalateTargetLevel = nil

        if observed < next.level {
            // One-step recovery only (critical→warning or warning→normal).
            let stepDown: PressureLevel = {
                switch next.level {
                case .critical: return .warning
                case .warning: return .normal
                case .normal: return .normal
                }
            }()
            let dwell = clock.timeIntervalSince(next.levelEnteredAt)
            let exitThreshold = exitBand(for: next.level, thresholds: thresholds)
            let fraction = sample.managedRSSFraction!
            // Sample must be strictly below current level's exit band; OS normal.
            // For critical→warning, observed may still be warning (fraction in warning band).
            let eligibleForStepDown: Bool = {
                guard osLevel == .normal else { return false }
                guard fraction < exitThreshold else { return false }
                // Must not still be at current level by RSS.
                return rssLevel < next.level
            }()
            if dwell >= thresholds.minDwellSeconds && eligibleForStepDown {
                next.consecutiveRecoverSamples += 1
                if next.consecutiveRecoverSamples >= thresholds.recoverSampleCount {
                    return recover(state: next, to: stepDown, at: clock)
                }
            } else {
                next.consecutiveRecoverSamples = 0
            }
            // Still under pressure: actions already bound to epoch (no re-emit).
            return revalidateActions(state: next, at: clock, thresholds: thresholds)
        }

        // Same level: reset recover streak.
        next.consecutiveRecoverSamples = 0
        return revalidateActions(state: next, at: clock, thresholds: thresholds)
    }

    private static func exitBand(for level: PressureLevel, thresholds: PressureThresholds) -> Double {
        switch level {
        case .critical:
            return thresholds.criticalFraction - thresholds.exitHysteresisPoints
        case .warning:
            return thresholds.warningFraction - thresholds.exitHysteresisPoints
        case .normal:
            return 0
        }
    }

    /// Emit a paced recovery tick (one optional unit) when level is normal.
    public static func pacedRecoveryTick(
        state: PressureGovernorState,
        at clock: Date,
        thresholds: PressureThresholds = .default
    ) -> PressureTransitionResult {
        guard state.level == .normal else {
            return PressureTransitionResult(state: state, ignoredReason: "not_normal")
        }
        if let last = state.lastRecoveryAt,
           clock.timeIntervalSince(last) < thresholds.recoveryMinIntervalSeconds {
            return PressureTransitionResult(state: state, ignoredReason: "recovery_rate_limited")
        }
        var next = state
        next.lastRecoveryAt = clock
        next.lastActionAt = clock
        next.lastActionKey = PressureActionKind.resumeOptionalWorkUnit.rawValue
        next.actionCount += 1
        return PressureTransitionResult(
            state: next,
            emittedActions: [.resumeOptionalWorkUnit]
        )
    }

    /// Revalidate that a planned mutation still targets the current epoch/generation.
    public static func isEpochFresh(state: PressureGovernorState, expectedEpoch: UInt64) -> Bool {
        state.epoch == expectedEpoch
    }

    /// Max actions counted per epoch (enter ladder once; holds are silent).
    public static let maxActionsPerEpoch = 5

    private static func bumpEpoch(_ epoch: UInt64) -> UInt64 {
        epoch == UInt64.max ? UInt64.max : epoch + 1
    }

    private static func escalate(
        state: PressureGovernorState,
        to level: PressureLevel,
        at clock: Date,
        reason: String
    ) -> PressureTransitionResult {
        var next = state
        let changed = next.level != level
        if changed {
            next.level = level
            next.epoch = bumpEpoch(next.epoch)
            next.levelEnteredAt = clock
            next.actionsEmittedThisEpoch = 0
        }
        next.consecutiveEscalateSamples = 0
        next.escalateTargetLevel = nil
        next.consecutiveRecoverSamples = 0
        let actions = actionsFor(level: level)
        let actionKey = "\(level.rawValue):enter:\(next.epoch)"
        // Exactly once per epoch: enter actions only.
        if next.actionsEmittedThisEpoch == 0 {
            next.lastActionKey = actionKey
            next.lastActionAt = clock
            next.actionCount += actions.count
            next.actionsEmittedThisEpoch = actions.count
            return PressureTransitionResult(
                state: next,
                emittedActions: actions,
                levelChanged: changed
            )
        }
        return PressureTransitionResult(
            state: next,
            emittedActions: [],
            levelChanged: changed
        )
    }

    private static func recover(
        state: PressureGovernorState,
        to level: PressureLevel,
        at clock: Date
    ) -> PressureTransitionResult {
        var next = state
        let changed = next.level != level
        if changed {
            next.level = level
            next.epoch = bumpEpoch(next.epoch)
            next.levelEnteredAt = clock
            next.actionsEmittedThisEpoch = 0
        }
        next.consecutiveEscalateSamples = 0
        next.escalateTargetLevel = nil
        next.consecutiveRecoverSamples = 0
        return PressureTransitionResult(
            state: next,
            emittedActions: [],
            levelChanged: changed
        )
    }

    private static func revalidateActions(
        state: PressureGovernorState,
        at clock: Date,
        thresholds: PressureThresholds
    ) -> PressureTransitionResult {
        // Holds never re-emit; actions are bound to epoch entry only.
        _ = clock
        _ = thresholds
        return PressureTransitionResult(state: state, emittedActions: [])
    }

    private static func actionsFor(level: PressureLevel) -> [PressureActionKind] {
        switch level {
        case .normal:
            return []
        case .warning:
            return warningActions
        case .critical:
            return criticalActions
        }
    }
}
