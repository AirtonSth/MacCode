import XCTest
@testable import AgentRuntime

/// S5: cancellable preparation generation machine.
final class ProviderPreparationStateMachineTests: XCTestCase {
    func test_accept_persistsDraftAndEntersPreparing() {
        var state = ProviderPreparationState()
        let t = ProviderPreparationStateMachine.apply(
            state: state,
            event: .accept(draftMessageId: "draft-1", atMs: 100)
        )
        XCTAssertEqual(t.state.phase, .preparing)
        XCTAssertEqual(t.state.draftMessageId, "draft-1")
        XCTAssertEqual(t.state.acceptedAtMs, 100)
        XCTAssertTrue(t.clearComposer)
        XCTAssertEqual(t.state.accessibleStatus, "Preparing")
        XCTAssertFalse(ProviderPreparationStateMachine.isRunningAnnounced(t.state))
        state = t.state

        let stop = ProviderPreparationStateMachine.apply(state: state, event: .stopRequested)
        XCTAssertEqual(stop.state.phase, .terminal)
        XCTAssertEqual(stop.state.terminalReason, .cancelled)
        XCTAssertFalse(stop.allowProviderSpawn)
    }

    func test_cancelledGeneration_neverSpawns() {
        var state = ProviderPreparationState()
        state = ProviderPreparationStateMachine.apply(
            state: state,
            event: .accept(draftMessageId: "d", atMs: 1)
        ).state
        let genA = state.generation
        state = ProviderPreparationStateMachine.apply(state: state, event: .stopRequested).state
        XCTAssertNotEqual(state.generation, genA, "cancel bumps generation")

        // Re-accept generation B.
        state = ProviderPreparationStateMachine.apply(
            state: state,
            event: .accept(draftMessageId: "d2", atMs: 2)
        ).state
        let genB = state.generation
        XCTAssertNotEqual(genA, genB)

        // Stale generation A completion must not spawn into B.
        let latePrep = ProviderPreparationStateMachine.apply(
            state: state,
            event: .preparationFinished(generation: genA)
        )
        XCTAssertFalse(latePrep.allowProviderSpawn)
        XCTAssertTrue(latePrep.suppressLateCallback)
        XCTAssertEqual(state.phase, .preparing)

        let late = ProviderPreparationStateMachine.apply(
            state: state,
            event: .lateCallback(generation: genA)
        )
        XCTAssertTrue(late.suppressLateCallback)
    }

    func test_happyPath_runningOnlyAfterSpawn() {
        var state = ProviderPreparationState()
        state = ProviderPreparationStateMachine.apply(
            state: state,
            event: .accept(draftMessageId: "d", atMs: 1)
        ).state
        let gen = state.generation
        let prepDone = ProviderPreparationStateMachine.apply(
            state: state,
            event: .preparationFinished(generation: gen)
        )
        XCTAssertTrue(prepDone.allowProviderSpawn)
        XCTAssertEqual(prepDone.state.phase, .providerStarting)
        XCTAssertFalse(ProviderPreparationStateMachine.isRunningAnnounced(prepDone.state))
        state = prepDone.state

        let spawned = ProviderPreparationStateMachine.apply(
            state: state,
            event: .providerSpawned(generation: gen)
        )
        XCTAssertEqual(spawned.state.phase, .running)
        XCTAssertTrue(ProviderPreparationStateMachine.isRunningAnnounced(spawned.state))
        state = spawned.state

        let done = ProviderPreparationStateMachine.apply(
            state: state,
            event: .providerFinished(generation: gen, reason: .completed)
        )
        XCTAssertEqual(done.state.phase, .terminal)
        XCTAssertEqual(done.state.terminalReason, .completed)
    }

    func test_stopWhileRunning_entersStopping() {
        var state = ProviderPreparationState(phase: .running, generation: 3)
        let t = ProviderPreparationStateMachine.apply(state: state, event: .stopRequested)
        XCTAssertEqual(t.state.phase, .stopping)
        XCTAssertEqual(t.state.accessibleStatus, "Stopping")
    }

    func test_spawnPermit_revokedAfterStopAtWriteBoundary() {
        var state = ProviderPreparationState()
        state = ProviderPreparationStateMachine.apply(
            state: state,
            event: .accept(draftMessageId: "d", atMs: 1)
        ).state
        let gen = state.generation
        let prepDone = ProviderPreparationStateMachine.apply(
            state: state,
            event: .preparationFinished(generation: gen)
        )
        XCTAssertTrue(prepDone.allowProviderSpawn)
        XCTAssertEqual(prepDone.spawnPermitGeneration, gen)
        XCTAssertTrue(
            ProviderPreparationStateMachine.mayClaimSpawn(
                state: prepDone.state,
                permitGeneration: prepDone.spawnPermitGeneration
            )
        )
        let claimed = ProviderPreparationStateMachine.claimSpawn(
            state: prepDone.state,
            permitGeneration: prepDone.spawnPermitGeneration
        )
        XCTAssertEqual(claimed.state.phase, .running)
        // Second claim on pre-claim snapshot succeeds only if still providerStarting;
        // after consume via live state, claim fails.
        let second = ProviderPreparationStateMachine.claimSpawn(
            state: claimed.state,
            permitGeneration: prepDone.spawnPermitGeneration
        )
        XCTAssertEqual(second.ignoredReason, "not_provider_starting")
        // Stop after preparationFinished revokes the retained permit.
        let stopped = ProviderPreparationStateMachine.apply(
            state: prepDone.state,
            event: .stopRequested
        )
        XCTAssertFalse(
            ProviderPreparationStateMachine.mayClaimSpawn(
                state: stopped.state,
                permitGeneration: prepDone.spawnPermitGeneration
            ),
            "retained allowProviderSpawn must not spawn after generation cancel"
        )
        let stoppedClaim = ProviderPreparationStateMachine.claimSpawn(
            state: stopped.state,
            permitGeneration: prepDone.spawnPermitGeneration
        )
        XCTAssertNotNil(stoppedClaim.ignoredReason)
    }

    func test_preparationFailed_leavesPreparing() {
        var state = ProviderPreparationState()
        state = ProviderPreparationStateMachine.apply(
            state: state,
            event: .accept(draftMessageId: "d", atMs: 1)
        ).state
        let gen = state.generation
        let failed = ProviderPreparationStateMachine.apply(
            state: state,
            event: .preparationFailed(generation: gen, reason: .durabilityFailure)
        )
        XCTAssertEqual(failed.state.phase, .terminal)
        XCTAssertEqual(failed.state.terminalReason, .durabilityFailure)
        XCTAssertFalse(failed.allowProviderSpawn)
    }
}
