import Foundation

/// Generation-owned single-flight pressure coordinator (S7 / T-003).
///
/// Revalidates epoch freshness plus surface visibility, provider/session activity,
/// sidecar request generation, and Graphify child identity before every mutation.
/// Never kills active turns or defers scheduled occurrences.

public struct PressureMutationTarget: Sendable, Equatable {
    public var epoch: UInt64
    public var surfaceVisible: Bool
    public var providerSessionActive: Bool
    public var sidecarRequestGeneration: UInt64
    public var graphifyChildIdentity: String?

    public init(
        epoch: UInt64,
        surfaceVisible: Bool,
        providerSessionActive: Bool,
        sidecarRequestGeneration: UInt64,
        graphifyChildIdentity: String? = nil
    ) {
        self.epoch = epoch
        self.surfaceVisible = surfaceVisible
        self.providerSessionActive = providerSessionActive
        self.sidecarRequestGeneration = sidecarRequestGeneration
        self.graphifyChildIdentity = graphifyChildIdentity
    }
}

public struct PressureMutationPlan: Sendable, Equatable {
    public var actions: [PressureActionKind]
    public var target: PressureMutationTarget

    public init(actions: [PressureActionKind], target: PressureMutationTarget) {
        self.actions = actions
        self.target = target
    }
}

public struct PressureMutationOutcome: Sendable, Equatable {
    public var applied: [PressureActionKind]
    public var skipped: [PressureActionKind]
    public var reason: String?

    public init(
        applied: [PressureActionKind] = [],
        skipped: [PressureActionKind] = [],
        reason: String? = nil
    ) {
        self.applied = applied
        self.skipped = skipped
        self.reason = reason
    }
}

public final class PressureGovernorCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var state: PressureGovernorState
    private var thresholds: PressureThresholds
    private var inFlight = false
    private var lastSidecarGeneration: UInt64 = 0
    private var lastGraphifyIdentity: String?

    public init(
        state: PressureGovernorState = PressureGovernorState(),
        thresholds: PressureThresholds = .default
    ) {
        self.state = state
        self.thresholds = thresholds
    }

    public func currentState() -> PressureGovernorState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func ingest(
        sample: PressureSample,
        now: Date? = nil
    ) -> PressureTransitionResult {
        lock.lock()
        defer { lock.unlock() }
        let result = PressureGovernorStateMachine.apply(
            state: state,
            sample: sample,
            thresholds: thresholds,
            now: now
        )
        state = result.state
        return result
    }

    /// Execute planned actions only when epoch/target still match.
    public func execute(
        plan: PressureMutationPlan,
        liveTarget: PressureMutationTarget
    ) -> PressureMutationOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight else {
            return PressureMutationOutcome(skipped: plan.actions, reason: "single_flight")
        }
        guard PressureGovernorStateMachine.isEpochFresh(state: state, expectedEpoch: plan.target.epoch) else {
            return PressureMutationOutcome(skipped: plan.actions, reason: "stale_epoch")
        }
        guard plan.target.epoch == liveTarget.epoch else {
            return PressureMutationOutcome(skipped: plan.actions, reason: "target_epoch_mismatch")
        }
        // Revalidate sidecar request generation and Graphify child identity (S7).
        if plan.target.sidecarRequestGeneration != liveTarget.sidecarRequestGeneration {
            return PressureMutationOutcome(skipped: plan.actions, reason: "sidecar_generation_mismatch")
        }
        if plan.target.graphifyChildIdentity != liveTarget.graphifyChildIdentity {
            return PressureMutationOutcome(skipped: plan.actions, reason: "graphify_identity_mismatch")
        }
        // Never act on incomplete accounting.
        if state.frozenAccounting {
            return PressureMutationOutcome(skipped: plan.actions, reason: "frozen_accounting")
        }

        inFlight = true
        defer { inFlight = false }

        var applied: [PressureActionKind] = []
        var skipped: [PressureActionKind] = []
        for action in plan.actions {
            // Hard cuts: these never execute as live mutations.
            if action == .neverKillActiveTurn || action == .neverDeferScheduledOccurrence {
                skipped.append(action)
                continue
            }
            // Do not reclaim UI that is visible / has active provider when action is UI reclaim.
            if action == .reclaimHiddenRecomputableUI && liveTarget.surfaceVisible {
                skipped.append(action)
                continue
            }
            if action == .shortenCompletedIdleProviderSessions && liveTarget.providerSessionActive {
                // Only idle completed sessions — active provider sessions are skipped.
                skipped.append(action)
                continue
            }
            if action == .pauseGraphifyEnsureAndWatchCallbacks {
                lastGraphifyIdentity = liveTarget.graphifyChildIdentity
            }
            if action == .releaseDistillIdleModelGPU {
                lastSidecarGeneration = liveTarget.sidecarRequestGeneration
            }
            applied.append(action)
        }
        return PressureMutationOutcome(applied: applied, skipped: skipped)
    }

    public func pacedRecovery(at date: Date) -> PressureTransitionResult {
        lock.lock()
        defer { lock.unlock() }
        let result = PressureGovernorStateMachine.pacedRecoveryTick(
            state: state,
            at: date,
            thresholds: thresholds
        )
        state = result.state
        return result
    }

    /// Product invariant: pressure never defers scheduled occurrences.
    public static let defersScheduledOccurrences = false
    /// Product invariant: pressure never kills active provider turns.
    public static let killsActiveTurns = false
}
