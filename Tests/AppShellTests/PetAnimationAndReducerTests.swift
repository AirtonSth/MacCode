import XCTest
@testable import AppShell
import CoreModel

final class PetAnimationAndReducerTests: XCTestCase {
    func test_manifestOrderContainsExactlyTheThirtyFourStableAtlasRows() {
        XCTAssertEqual(
            PetAnimationState.allCases.map(\.rawValue),
            [
                "idle", "listening", "thinking", "coding", "editing", "terminal",
                "search", "gitReview", "success", "approval", "question", "waiting",
                "failed", "interrupted", "reconnecting", "sleeping",
                "idleBall", "idleScratch", "idleGroom", "idleStretch",
                "idleBox", "idleButterfly", "eating", "drinking",
                "purring", "playing", "comfort", "notificationPounce",
                "workingMouse", "workingBug", "workingEngineer", "celebrateTreat",
                "idleYawn", "pickedUp"
            ],
            "Atlas row order is a shipped resource contract; reordering a case renders the wrong reaction."
        )
    }

    func test_everyAssistantItemTypeMapsToTheIntendedReactionOrExplicitNoise() {
        let expected: [(AssistantItemType, PetAnimationState?)] = [
            (.reasoning, .thinking),
            (.plan, .thinking),
            (.tool, .coding),
            (.assistantMessage, nil),
            (.commandExecution, .terminal),
            (.fileChange, .editing),
            (.mcpToolCall, .coding),
            (.dynamicToolCall, .coding),
            (.collabToolCall, .coding),
            (.webSearch, .search),
            (.imageView, .gitReview),
            (.review, .gitReview),
            (.contextCompaction, .thinking),
            (.error, .failed)
        ]

        for (itemType, state) in expected {
            XCTAssertEqual(
                PetAnimationState.state(for: itemType),
                state,
                "Every provider item type needs one deliberate animation/noise decision."
            )
        }
    }

    func test_priorityKeepsNeedsYouAheadOfOutcomeAndActiveWork() {
        XCTAssertEqual(
            PetAnimationState.highestPriority(in: [
                .idle, .sleeping, .waiting, .reconnecting, .coding, .thinking,
                .editing, .interrupted, .success, .failed, .question, .approval
            ]),
            .approval,
            "An unresolved approval must never be hidden by a celebration or active-work loop."
        )
        XCTAssertEqual(PetAnimationState.highestPriority(in: [.success, .failed]), .failed)
        XCTAssertEqual(PetAnimationState.highestPriority(in: [.editing, .success]), .success)
        XCTAssertEqual(PetAnimationState.highestPriority(in: [.coding, .editing]), .editing)
        XCTAssertEqual(PetAnimationState.highestPriority(in: [.reconnecting, .coding]), .coding)
        XCTAssertEqual(PetAnimationState.highestPriority(in: [.sleeping, .reconnecting]), .reconnecting)
        XCTAssertEqual(PetAnimationState.highestPriority(in: [.idle, .sleeping]), .sleeping)
        XCTAssertNil(PetAnimationState.highestPriority(in: []))
    }

    func test_noiseEventsNeverRestartAnimationOrRequestAttentionRefresh() {
        var reducer = PetEventReducer()
        let noise: [PetDomainEvent] = [
            .agentItemDelta,
            .agentItemProgress,
            .surfaceOutput,
            .tokenUsage,
            .layoutChanged,
            .filesystemChanged
        ]

        for (offset, event) in noise.enumerated() {
            let result = reducer.reduce(event, atMilliseconds: Int64(offset))
            XCTAssertEqual(result.state, .idle)
            XCTAssertEqual(result.disposition, .ignored(.noise))
            XCTAssertFalse(result.shouldRefreshAttention)
        }
    }

    func test_identicalStateInputsCoalesceInsideFixedOneHundredTwentyMillisecondWindow() {
        var reducer = PetEventReducer()

        let first = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 1_000)
        let insideWindow = reducer.reduce(.agentRunStarted(runID: "run-2"), atMilliseconds: 1_119)
        let boundary = reducer.reduce(.agentRunStarted(runID: "run-3"), atMilliseconds: 1_120)

        XCTAssertEqual(first.disposition, .emitted)
        XCTAssertEqual(first.state, .coding)
        XCTAssertEqual(insideWindow.disposition, .coalesced)
        XCTAssertEqual(boundary.disposition, .emitted)
        XCTAssertEqual(reducer.activeRunCount, 3)
    }

    func test_noiseDoesNotSlideTheCoalescingWindow() {
        var reducer = PetEventReducer()

        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 1_000)
        XCTAssertEqual(
            reducer.reduce(.agentItemDelta, atMilliseconds: 1_110).disposition,
            .ignored(.noise)
        )
        XCTAssertEqual(
            reducer.reduce(.agentRunStarted(runID: "run-2"), atMilliseconds: 1_120).disposition,
            .emitted,
            "Ignored deltas must not extend the suppression window and starve legitimate updates."
        )
    }

    func test_itemLifecycleFallsBackToRunStateWithoutReactingToDeltas() {
        var reducer = PetEventReducer()

        XCTAssertEqual(
            reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0).state,
            .coding
        )
        XCTAssertEqual(
            reducer.reduce(
                .agentItemStarted(itemID: "search-1", type: .webSearch),
                atMilliseconds: 200
            ).state,
            .search
        )
        XCTAssertEqual(
            reducer.reduce(.agentItemDelta, atMilliseconds: 250).disposition,
            .ignored(.noise)
        )
        XCTAssertEqual(
            reducer.reduce(.agentItemCompleted(itemID: "search-1"), atMilliseconds: 400).state,
            .coding,
            "Finishing a specific tool must return to the still-active generic run."
        )
    }

    func test_runStartRequestsAttentionRefreshBecauseItClearsPriorUnreadOutcome() {
        var reducer = PetEventReducer()
        let result = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)

        XCTAssertTrue(
            result.shouldRefreshAttention,
            "Starting a new run clears the thread's previous unread outcome in persistence."
        )
    }

    func test_approvalAndQuestionRemainPersistentUntilTheirExactRequestResolves() {
        var reducer = PetEventReducer()

        XCTAssertEqual(
            reducer.reduce(.questionOpened(requestID: "question-1"), atMilliseconds: 0).state,
            .question
        )
        XCTAssertEqual(
            reducer.reduce(.approvalOpened(requestID: "approval-1"), atMilliseconds: 200).state,
            .approval
        )
        let staleResolution = reducer.reduce(
            .approvalResolved(requestID: "different"),
            atMilliseconds: 400
        )
        XCTAssertEqual(
            staleResolution.state,
            .approval,
            "Resolving a different callback must not clear the visible blocker."
        )
        XCTAssertFalse(
            staleResolution.shouldRefreshAttention,
            "A stale callback must not trigger an unnecessary unread refresh."
        )
        XCTAssertEqual(
            reducer.reduce(.approvalResolved(requestID: "approval-1"), atMilliseconds: 600).state,
            .question
        )
        XCTAssertEqual(
            reducer.reduce(.questionResolved(requestID: "question-1"), atMilliseconds: 800).state,
            .idle
        )
    }

    func test_terminalOutcomeQueuesBehindBlockerThenSettlesToPersistentWaiting() {
        var reducer = PetEventReducer()
        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)
        _ = reducer.reduce(.approvalOpened(requestID: "approval-1"), atMilliseconds: 200)

        let blockedOutcome = reducer.reduce(
            .agentRunFinished(runID: "run-1", status: .failed),
            atMilliseconds: 400
        )
        XCTAssertEqual(blockedOutcome.state, .approval)
        XCTAssertTrue(blockedOutcome.shouldRefreshAttention)

        _ = reducer.reduce(.attentionCountChanged(1), atMilliseconds: 600)
        XCTAssertEqual(
            reducer.reduce(.approvalResolved(requestID: "approval-1"), atMilliseconds: 800).state,
            .failed
        )
        XCTAssertEqual(
            reducer.reduce(.transientExpired, atMilliseconds: 1_000).state,
            .waiting
        )
    }

    func test_attentionHydrationRestoresSemanticPriorityInsteadOfGenericWaiting() {
        var reducer = PetEventReducer()

        XCTAssertEqual(
            reducer.reduce(
                .attentionHydrated(PetAttentionHydration(
                    approvalIDs: ["approval-1"],
                    questionIDs: ["question-1"],
                    fileConflictIDs: ["conflict-1"],
                    count: 4,
                    isReconnecting: true
                )),
                atMilliseconds: 0
            ).state,
            .approval
        )
        XCTAssertEqual(
            reducer.reduce(
                .attentionHydrated(PetAttentionHydration(
                    questionIDs: ["question-1"],
                    fileConflictIDs: ["conflict-1"],
                    count: 3,
                    isReconnecting: true
                )),
                atMilliseconds: 1
            ).state,
            .approval,
            "A restored file conflict uses the approval reaction."
        )
        XCTAssertEqual(
            reducer.reduce(
                .attentionHydrated(PetAttentionHydration(
                    questionIDs: ["question-1"],
                    count: 2,
                    isReconnecting: true
                )),
                atMilliseconds: 2
            ).state,
            .question
        )
        XCTAssertEqual(
            reducer.reduce(
                .attentionHydrated(PetAttentionHydration(count: 1, isReconnecting: true)),
                atMilliseconds: 3
            ).state,
            .reconnecting
        )
        XCTAssertEqual(
            reducer.reduce(
                .attentionHydrated(PetAttentionHydration(count: 1)),
                atMilliseconds: 4
            ).state,
            .waiting
        )
    }

    func test_hiddenTerminalTransientExpiresBeforeBlockerResolves() {
        var reducer = PetEventReducer()
        _ = reducer.reduce(.attentionCountChanged(1), atMilliseconds: 0)
        _ = reducer.reduce(.approvalOpened(requestID: "approval-1"), atMilliseconds: 1)

        let hidden = reducer.reduce(
            .agentRunFinished(runID: "run-1", status: .completed),
            atMilliseconds: 2
        )
        XCTAssertEqual(hidden.state, .approval)
        XCTAssertEqual(hidden.transientTimerDirective, .schedule(milliseconds: 1_200))

        _ = reducer.reduce(.transientExpired, atMilliseconds: 1_202)
        XCTAssertEqual(
            reducer.reduce(.approvalResolved(requestID: "approval-1"), atMilliseconds: 1_203).state,
            .waiting,
            "A celebration hidden behind a blocker must expire while hidden."
        )
    }

    func test_transientSourcesEmitTimerDirectivesAndSpecificItemsClearTurnThinking() {
        let scheduledEvents: [(PetDomainEvent, PetAnimationState)] = [
            (.contextCompaction, .thinking),
            (.browserNavigation, .search),
            (.file(.opened), .editing),
            (.file(.saved(conflictID: nil)), .editing),
            (.agentRunFinished(runID: "success", status: .completed), .success),
            (.agentRunFinished(runID: "failure", status: .failed), .failed),
            (.agentRunFinished(runID: "interrupted", status: .interrupted), .interrupted),
            (.sshSession(.connected), .success)
        ]

        for (event, state) in scheduledEvents {
            var reducer = PetEventReducer()
            let reduction = reducer.reduce(event, atMilliseconds: 0)
            XCTAssertEqual(reduction.state, state)
            guard case .schedule(let milliseconds) = reduction.transientTimerDirective else {
                return XCTFail("\(event) must schedule its own transient expiry.")
            }
            XCTAssertGreaterThan(milliseconds, 0)
        }

        var reducer = PetEventReducer()
        let turn = reducer.reduce(.agentTurnStarted, atMilliseconds: 0)
        XCTAssertEqual(turn.state, .thinking)
        XCTAssertNotNil(turn.transientTimerDirective)
        let item = reducer.reduce(
            .agentItemStarted(itemID: "command-1", type: .commandExecution),
            atMilliseconds: 1
        )
        XCTAssertEqual(item.state, .terminal)
        XCTAssertEqual(item.transientTimerDirective, .cancel)
        XCTAssertEqual(
            reducer.reduce(.agentItemCompleted(itemID: "command-1"), atMilliseconds: 2).state,
            .idle,
            "Starting a specific item must remove stale turn-level thinking."
        )
    }

    func test_fileResolutionDiscardAndCloseClearEditingTransient() {
        let terminalActivities: [PetFileActivity] = [
            .conflictResolved(id: "conflict-1"),
            .discarded(conflictID: nil),
            .closed(conflictID: nil)
        ]

        for activity in terminalActivities {
            var reducer = PetEventReducer()
            XCTAssertEqual(reducer.reduce(.file(.opened), atMilliseconds: 0).state, .editing)
            let reduction = reducer.reduce(.file(activity), atMilliseconds: 1)
            XCTAssertEqual(reduction.state, .idle)
            XCTAssertEqual(reduction.transientTimerDirective, .cancel)
        }
    }

    func test_fileTerminalEventsRemoveOnlyTheirMatchingConflictIdentity() {
        var savedReducer = PetEventReducer()
        _ = savedReducer.reduce(.file(.conflict(id: "session-1")), atMilliseconds: 0)
        let saved = savedReducer.reduce(
            .file(.saved(conflictID: "session-1")),
            atMilliseconds: 1
        )
        XCTAssertEqual(saved.state, .editing)
        XCTAssertTrue(saved.shouldRefreshAttention)
        XCTAssertEqual(
            savedReducer.reduce(.transientExpired, atMilliseconds: 601).state,
            .idle
        )

        for activity in [
            PetFileActivity.discarded(conflictID: "session-1"),
            PetFileActivity.closed(conflictID: "session-1")
        ] {
            var reducer = PetEventReducer()
            _ = reducer.reduce(.file(.conflict(id: "session-1")), atMilliseconds: 0)
            let terminal = reducer.reduce(.file(activity), atMilliseconds: 1)
            XCTAssertEqual(terminal.state, .idle)
            XCTAssertTrue(terminal.shouldRefreshAttention)
        }

        var mismatched = PetEventReducer()
        _ = mismatched.reduce(.file(.conflict(id: "session-1")), atMilliseconds: 0)
        XCTAssertEqual(
            mismatched.reduce(
                .file(.discarded(conflictID: "different-session")),
                atMilliseconds: 1
            ).state,
            .approval,
            "A terminal event must not clear a different file conflict."
        )
    }

    func test_duplicateTerminalOutcomeCannotCelebrateOrRefreshTwice() {
        var reducer = PetEventReducer()

        let first = reducer.reduce(
            .agentRunFinished(runID: "run-1", status: .completed),
            atMilliseconds: 0
        )
        let duplicate = reducer.reduce(
            .agentRunFinished(runID: "run-1", status: .failed),
            atMilliseconds: 500
        )

        XCTAssertEqual(first.state, .success)
        XCTAssertEqual(first.disposition, .emitted)
        XCTAssertTrue(first.shouldRefreshAttention)
        XCTAssertEqual(duplicate.state, .success)
        XCTAssertEqual(duplicate.disposition, .ignored(.duplicateTerminalOutcome))
        XCTAssertFalse(duplicate.shouldRefreshAttention)
    }

    func test_runErrorIsTransientAndDoesNotConsumeTheCanonicalTerminalOutcome() {
        var reducer = PetEventReducer()
        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)

        let warning = reducer.reduce(
            .agentRunError(runID: "run-1", recoverable: true),
            atMilliseconds: 200
        )
        XCTAssertEqual(warning.state, .interrupted)
        XCTAssertEqual(reducer.activeRunCount, 1)
        XCTAssertFalse(warning.shouldRefreshAttention)

        let finished = reducer.reduce(
            .agentRunFinished(runID: "run-1", status: .completed),
            atMilliseconds: 400
        )
        XCTAssertEqual(finished.state, .success)
        XCTAssertEqual(finished.disposition, .emitted)
        XCTAssertTrue(finished.shouldRefreshAttention)
        XCTAssertEqual(reducer.activeRunCount, 0)
    }

    func test_finishingOneRunDoesNotEraseAnotherRunsActiveReaction() {
        var reducer = PetEventReducer()
        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)
        _ = reducer.reduce(.agentRunStarted(runID: "run-2"), atMilliseconds: 200)
        _ = reducer.reduce(
            .agentItemStarted(itemID: "search-2", type: .webSearch),
            atMilliseconds: 400
        )

        XCTAssertEqual(
            reducer.reduce(
                .agentRunFinished(runID: "run-1", status: .completed),
                atMilliseconds: 600
            ).state,
            .success
        )
        XCTAssertEqual(
            reducer.reduce(.transientExpired, atMilliseconds: 800).state,
            .search,
            "One run's celebration must not erase another active run's specific operation."
        )
    }

    func test_userCancelledRunShowsShortInterruptionButDoesNotRequestAttention() {
        var reducer = PetEventReducer()
        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)

        let result = reducer.reduce(
            .agentRunFinished(runID: "run-1", status: .cancelled),
            atMilliseconds: 200
        )

        XCTAssertEqual(result.state, .interrupted)
        XCTAssertEqual(result.disposition, .emitted)
        XCTAssertFalse(result.shouldRefreshAttention)
    }

    func test_externalOperationAndSessionMappingsAreExplicit() {
        let expected: [(PetDomainEvent, PetAnimationState?)] = [
            (.git(.started), .gitReview),
            (.git(.succeeded), .success),
            (.git(.failed), .failed),
            (.file(.opened), .editing),
            (.file(.saved(conflictID: nil)), .editing),
            (.file(.conflict(id: "conflict-1")), .approval),
            (.projectScript(.started), .terminal),
            (.projectScript(.succeeded), .success),
            (.projectScript(.failed), .failed),
            (.providerUpdate(.succeeded), .success),
            (.providerUpdate(.failed), .failed),
            (.sshTransfer(.started), .terminal),
            (.sshTransfer(.succeeded), .success),
            (.sshTransfer(.failed), .failed),
            (.sshSession(.connected), .success),
            (.sshSession(.connectionFailed), .failed),
            (.sshSession(.unexpectedDisconnect), .reconnecting),
            (.sshSession(.explicitDisconnect), nil),
            (.browserNavigation, .search)
        ]

        for (event, state) in expected {
            XCTAssertEqual(PetEventReducer.mappedState(for: event), state)
        }
    }

    func test_screenLockHardStopsVisibleAnimationUntilUnlock() {
        var reducer = PetEventReducer()
        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)

        XCTAssertEqual(
            reducer.reduce(.screenLockChanged(isLocked: true), atMilliseconds: 200).state,
            .sleeping
        )
        XCTAssertEqual(
            reducer.reduce(.screenLockChanged(isLocked: false), atMilliseconds: 400).state,
            .coding
        )

        var idleReducer = PetEventReducer()
        XCTAssertEqual(idleReducer.reduce(.idleTimeout, atMilliseconds: 0).state, .sleeping)
        _ = idleReducer.reduce(.screenLockChanged(isLocked: true), atMilliseconds: 1)
        XCTAssertEqual(
            idleReducer.reduce(.screenLockChanged(isLocked: false), atMilliseconds: 2).state,
            .idle,
            "Unlock must clear stale idle sleep before the next idle deadline is armed."
        )
    }

    func test_petInteractionWakesIdleSleepWithoutCreatingAttention() {
        var reducer = PetEventReducer()
        XCTAssertEqual(reducer.reduce(.idleTimeout, atMilliseconds: 0).state, .sleeping)
        let interaction = reducer.reduce(.interactionBegan, atMilliseconds: 1)
        XCTAssertEqual(interaction.state, .idle)
        XCTAssertFalse(interaction.shouldRefreshAttention)
    }

    /// Ghost path: EventBus start without finish leaves coding; host projection
    /// empty must clear work pose (Ready-for-you has zero Active).
    func test_reconcileActiveRunIDs_emptyHostClearsGhostCodingPose() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        XCTAssertEqual(
            reducer.reduce(.agentRunStarted(runID: "ghost-run"), atMilliseconds: 0).state,
            .coding
        )
        XCTAssertEqual(reducer.activeRunCount, 1)
        XCTAssertTrue(PetEventReducer.isWorkPose(reducer.state))

        // Missed finish; host ActiveRunProjection is empty.
        let cleared = reducer.reconcileActiveRunIDs([], atMilliseconds: 100)
        XCTAssertEqual(reducer.activeRunCount, 0)
        XCTAssertEqual(cleared.state, .idle)
        XCTAssertFalse(
            PetEventReducer.isWorkPose(cleared.state),
            "zero host active runs must not keep a work pose"
        )
        XCTAssertTrue(reducer.trackedActiveRunIDs.isEmpty)
    }

    func test_reconcileActiveRunIDs_matchesHostProjectionAndKeepsRealWork() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        _ = reducer.reduce(.agentRunStarted(runID: "run-a"), atMilliseconds: 0)
        _ = reducer.reduce(.agentRunStarted(runID: "run-b"), atMilliseconds: 10)
        XCTAssertEqual(reducer.activeRunCount, 2)

        // Host still has only run-a (run-b finished without bus finish).
        let synced = reducer.reconcileActiveRunIDs(["run-a"], atMilliseconds: 20)
        XCTAssertEqual(reducer.trackedActiveRunIDs, ["run-a"])
        XCTAssertEqual(synced.state, .coding)
        XCTAssertTrue(PetEventReducer.isWorkPose(synced.state))

        let done = reducer.reconcileActiveRunIDs([], atMilliseconds: 30)
        XCTAssertEqual(done.state, .idle)
        XCTAssertFalse(PetEventReducer.isWorkPose(done.state))
    }

    func test_reconcileActiveRunIDs_clearsGhostWorkVariantTransient() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)
        XCTAssertEqual(
            reducer.reduce(
                .companionCue(PetCompanionCue(state: .workingEngineer, returnState: .coding)),
                atMilliseconds: 1
            ).state,
            .workingEngineer
        )
        let cleared = reducer.reconcileActiveRunIDs([], atMilliseconds: 2)
        XCTAssertFalse(
            PetEventReducer.isWorkPose(cleared.state),
            "decorative work pose must not stick after host active set is empty"
        )
        XCTAssertEqual(cleared.state, .idle)
    }

    func test_startFinishPath_leavesNonWorkAfterSuccessExpires() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)
        XCTAssertTrue(PetEventReducer.isWorkPose(reducer.state))
        _ = reducer.reduce(
            .agentRunFinished(runID: "run-1", status: .completed),
            atMilliseconds: 1
        )
        XCTAssertEqual(reducer.activeRunCount, 0)
        XCTAssertEqual(reducer.state, .success)
        XCTAssertEqual(reducer.reduce(.transientExpired, atMilliseconds: 2).state, .idle)
        XCTAssertFalse(PetEventReducer.isWorkPose(reducer.state))
    }

    /// WHY: plan item.started without a live run left the pet in thinking/plan
    /// (hard-hat / blueprint) while Ready-for-you Active was empty.
    func test_itemStartedWithoutActiveRun_doesNotStickPlanPose() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        let afterPlan = reducer.reduce(
            .agentItemStarted(itemID: "plan-1", type: .plan),
            atMilliseconds: 0
        )
        XCTAssertEqual(afterPlan.state, .idle)
        XCTAssertEqual(reducer.activeRunCount, 0)
        XCTAssertFalse(
            PetEventReducer.isWorkPose(afterPlan.state),
            "plan item without a run must not put the pet in work/plan mode"
        )
    }

    /// WHY: tool/coding item without a run (or after missed finish) must not keep
    /// the laptop pose when no thread is active.
    func test_itemStartedWithoutActiveRun_doesNotStickCodingPose() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        let afterTool = reducer.reduce(
            .agentItemStarted(itemID: "tool-1", type: .tool),
            atMilliseconds: 0
        )
        XCTAssertEqual(afterTool.state, .idle)
        XCTAssertFalse(PetEventReducer.isWorkPose(afterTool.state))
    }

    /// WHY: work-variant companion cues (engineer hard-hat, laptop) must require
    /// a live run — otherwise the pet freezes in work art with zero Active threads.
    func test_workVariantCue_rejectedWhenNoActiveRun() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        let cue = reducer.reduce(
            .companionCue(PetCompanionCue(state: .workingEngineer, returnState: .coding)),
            atMilliseconds: 0
        )
        XCTAssertEqual(cue.state, .idle)
        XCTAssertFalse(PetEventReducer.isWorkPose(cue.state))
    }

    /// WHY: plan item during a run must clear when host Active goes empty even
    /// if item.completed never arrives.
    func test_reconcileEmpty_clearsPlanItemPoseAfterMissedItemCompleted() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)
        _ = reducer.reduce(
            .agentItemStarted(itemID: "plan-1", type: .plan),
            atMilliseconds: 1
        )
        XCTAssertEqual(reducer.state, .thinking)
        let cleared = reducer.reconcileActiveRunIDs([], atMilliseconds: 2)
        XCTAssertEqual(cleared.state, .idle)
        XCTAssertFalse(PetEventReducer.isWorkPose(cleared.state))
    }
}
