import XCTest
import CoreModel

/// Cross-provider follow-up contract: historical resume/load replay must not
/// paint under a newer user message for Grok, Claude, or Codex.
final class FollowUpTurnBoundaryTests: XCTestCase {
    func test_mayAcceptTimelineEvent_blocksUserFacingEventsUntilTurnArmed() {
        let turnStarted = AssistantEvent.turnStarted(turnId: "t1")
        let tool = AssistantEvent.itemStarted(item: AssistantItem(
            id: "tool-1",
            turnId: "t1",
            type: .tool,
            state: .streaming,
            summary: "run",
            body: "",
            startedAtMs: 1
        ))
        let runtime = AssistantEvent.providerRuntime(ProviderRuntimeEvent(
            provider: .grok,
            source: "test",
            method: "available_commands_update",
            providerItemId: nil,
            payloadJSON: "{}",
            receivedAtMs: 1
        ))

        XCTAssertFalse(
            FollowUpTurnBoundary.mayAcceptTimelineEvent(userTurnArmed: false, event: turnStarted),
            "turnStarted is user-facing and must wait until the prompt arms the turn"
        )
        XCTAssertFalse(
            FollowUpTurnBoundary.mayAcceptTimelineEvent(userTurnArmed: false, event: tool),
            "historical tool_call replay must not enter an unarmed follow-up"
        )
        XCTAssertTrue(
            FollowUpTurnBoundary.mayAcceptTimelineEvent(userTurnArmed: false, event: runtime),
            "session state/runtime may land before the user turn"
        )
        XCTAssertTrue(
            FollowUpTurnBoundary.mayAcceptTimelineEvent(userTurnArmed: true, event: tool),
            "once armed, live tools are accepted for every provider"
        )
    }

    func test_userFacingTimelineClassification_coversItemAndPlanLifecycle() {
        XCTAssertTrue(FollowUpTurnBoundary.isUserFacingTimelineEvent(.turnCompleted(turnId: "t", finalMessage: nil)))
        XCTAssertTrue(FollowUpTurnBoundary.isUserFacingTimelineEvent(.activePlanUpdated(
            AssistantActivePlan(steps: [], updatedAtMs: 1)
        )))
        XCTAssertFalse(FollowUpTurnBoundary.isUserFacingTimelineEvent(.threadStarted(threadId: "s", providerThreadId: "s")))
        XCTAssertFalse(FollowUpTurnBoundary.isUserFacingTimelineEvent(.tokenUsage(
            AssistantTokenUsage(inputTokens: 1, outputTokens: 1, totalTokens: 2)
        )))
    }
}
