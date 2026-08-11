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
        let gen = state.generation
        state = ProviderPreparationStateMachine.apply(state: state, event: .stopRequested).state
        XCTAssertNotEqual(state.generation, gen, "cancel bumps generation")

        let latePrep = ProviderPreparationStateMachine.apply(state: state, event: .preparationFinished)
        XCTAssertFalse(latePrep.allowProviderSpawn)
        XCTAssertEqual(latePrep.ignoredReason, "not_preparing")

        let late = ProviderPreparationStateMachine.apply(
            state: state,
            event: .lateCallback(generation: gen)
        )
        XCTAssertTrue(late.suppressLateCallback)
    }

    func test_happyPath_runningOnlyAfterSpawn() {
        var state = ProviderPreparationState()
        state = ProviderPreparationStateMachine.apply(
            state: state,
            event: .accept(draftMessageId: "d", atMs: 1)
        ).state
        let prepDone = ProviderPreparationStateMachine.apply(state: state, event: .preparationFinished)
        XCTAssertTrue(prepDone.allowProviderSpawn)
        XCTAssertEqual(prepDone.state.phase, .providerStarting)
        XCTAssertFalse(ProviderPreparationStateMachine.isRunningAnnounced(prepDone.state))
        state = prepDone.state

        let spawned = ProviderPreparationStateMachine.apply(state: state, event: .providerSpawned)
        XCTAssertEqual(spawned.state.phase, .running)
        XCTAssertTrue(ProviderPreparationStateMachine.isRunningAnnounced(spawned.state))
        state = spawned.state

        let done = ProviderPreparationStateMachine.apply(
            state: state,
            event: .providerFinished(.completed)
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
}
