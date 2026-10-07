import Foundation

/// Generation-owned single-flight pressure coordinator (S7 / T-003).
///
/// Revalidates epoch freshness plus surface visibility and provider/session
/// activity before every mutation.
/// Never kills active turns or defers scheduled occurrences.

public struct PressureMutationTarget: Sendable, Equatable {
    public var epoch: UInt64
    public var surfaceVisible: Bool
    public var providerSessionActive: Bool

    public init(
        epoch: UInt64,
        surfaceVisible: Bool,
        providerSessionActive: Bool
    ) {
        self.epoch = epoch
        self.surfaceVisible = surfaceVisible
        self.providerSessionActive = providerSessionActive
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
        now: Date? = nil,
        thresholds: PressureThresholds? = nil
    ) -> PressureTransitionResult {
        lock.lock()
        defer { lock.unlock() }
        if let thresholds {
            self.thresholds = thresholds
        }
        let result = PressureGovernorStateMachine.apply(
            state: state,
            sample: sample,
            thresholds: self.thresholds,
            now: now
        )
        state = result.state
        // S12: keep Capacity UX reachable from production pressure path.
        CapacityUXStatusStore.shared.publishFromPressure(
            host: result.state.level,
            actions: result.emittedActions.map(\.rawValue)
        )
        return result
    }

    /// Execute planned actions only when epoch/target still match.
    public func execute(
        plan: PressureMutationPlan,
        liveTarget: PressureMutationTarget
    ) -> PressureMutationOutcome {
        execute(plan: plan, liveTargetProvider: { liveTarget })
    }

    /// Same as `execute(plan:liveTarget:)` but re-reads identity immediately
    /// before each mutation so surface/provider drift is observed (S7).
    public func execute(
        plan: PressureMutationPlan,
        liveTargetProvider: () -> PressureMutationTarget
    ) -> PressureMutationOutcome {
        lock.lock()
        guard !inFlight else {
            lock.unlock()
            return PressureMutationOutcome(skipped: plan.actions, reason: "single_flight")
        }
        // Reserve single-flight under the lock, then release so concurrent
        // callers observe inFlight without serializing the whole mutation body.
        inFlight = true
        let epochFresh = PressureGovernorStateMachine.isEpochFresh(
            state: state,
            expectedEpoch: plan.target.epoch
        )
        let frozen = state.frozenAccounting
        lock.unlock()

        defer {
            lock.lock()
            inFlight = false
            lock.unlock()
        }

        guard epochFresh else {
            return PressureMutationOutcome(skipped: plan.actions, reason: "stale_epoch")
        }
        if frozen {
            return PressureMutationOutcome(skipped: plan.actions, reason: "frozen_accounting")
        }

        var applied: [PressureActionKind] = []
        var skipped: [PressureActionKind] = []
        var remaining = plan.actions
        while !remaining.isEmpty {
            let action = remaining.removeFirst()
            // Re-read live identity + coordinator accounting at each mutation.
            let liveTarget = liveTargetProvider()
            lock.lock()
            let epochStillFresh = PressureGovernorStateMachine.isEpochFresh(
                state: state,
                expectedEpoch: plan.target.epoch
            )
            let stillFrozen = state.frozenAccounting
            lock.unlock()
            if !epochStillFresh {
                skipped.append(action)
                skipped.append(contentsOf: remaining)
                return PressureMutationOutcome(
                    applied: applied,
                    skipped: skipped,
                    reason: "stale_epoch"
                )
            }
            if stillFrozen {
                skipped.append(action)
                skipped.append(contentsOf: remaining)
                return PressureMutationOutcome(
                    applied: applied,
                    skipped: skipped,
                    reason: "frozen_accounting"
                )
            }
            if plan.target.epoch != liveTarget.epoch {
                skipped.append(action)
                skipped.append(contentsOf: remaining)
                return PressureMutationOutcome(
                    applied: applied,
                    skipped: skipped,
                    reason: "target_epoch_mismatch"
                )
            }
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
                skipped.append(action)
                continue
            }
            // Atomic claim: revalidate epoch/frozen under the same lock as mutation.
            lock.lock()
            let epochOK = PressureGovernorStateMachine.isEpochFresh(
                state: state,
                expectedEpoch: plan.target.epoch
            )
            let frozenNow = state.frozenAccounting
            if !epochOK || frozenNow {
                lock.unlock()
                skipped.append(action)
                skipped.append(contentsOf: remaining)
                return PressureMutationOutcome(
                    applied: applied,
                    skipped: skipped,
                    reason: !epochOK ? "stale_epoch" : "frozen_accounting"
                )
            }
            lock.unlock()
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
