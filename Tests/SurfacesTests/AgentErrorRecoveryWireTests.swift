import XCTest
import CoreModel
@testable import Surfaces

/// Paired clients (iOS) render the host's recovery action instead of guessing
/// from error text, so the wire value must come from the same classifier the
/// Mac error row uses, and the display text must not leak machine markers.
final class AgentErrorRecoveryWireTests: XCTestCase {
    private let freshSessionError = "[fresh-session:incompatible-history] The model rejected this Distill session's history; Retry starts a new Distill session: Distill ACP RPC error: API error (status 400 Bad Request): Invalid `signature` in `thinking` block"

    func test_wireValue_followsTheMacClassifierForEveryAction() {
        // WHY: an expired login must open sign-in on iOS, not loop Retry.
        XCTAssertEqual(AgentErrorRecoveryAction.pairedWireValue(message: "[auth-required] 401 Unauthorized", recoverable: false), "sign_in")
        // WHY: a broken resume cursor must not be retried on the same session.
        XCTAssertEqual(AgentErrorRecoveryAction.pairedWireValue(message: "Grok ACP session/load failed: session not found", recoverable: false), "start_fresh")
        XCTAssertEqual(AgentErrorRecoveryAction.pairedWireValue(message: "Grok ACP RPC error: rate limit exceeded", recoverable: false), "retry")
        XCTAssertEqual(AgentErrorRecoveryAction.pairedWireValue(message: "anything", recoverable: true), "retry",
                       "a provider-marked recoverable failure stays retryable on iOS like on the Mac")
        XCTAssertNil(AgentErrorRecoveryAction.pairedWireValue(message: "invalid request payload", recoverable: false),
                     "a fatal error must not offer a misleading action on iOS either")
    }

    func test_freshSessionFailure_isNewSessionOnTheWireButRetryOnTheMac() {
        // WHY: the host already retired the rejected session; iOS must retry on
        // the SAME thread (a bot desk keeps its link), and can say a new session
        // starts. The Mac classifier keeps its Retry for this case.
        XCTAssertEqual(AgentErrorRecoveryAction.pairedWireValue(message: freshSessionError, recoverable: false), "new_session")
        XCTAssertEqual(AgentAppViewModel.errorRecoveryAction(provider: .distill, message: freshSessionError, recoverable: false), .retry)
    }

    func test_displayText_stripsOnlyTheFreshSessionMarker() {
        let shown = AgentErrorRecoveryAction.displayText(freshSessionError)
        XCTAssertFalse(shown.contains("[fresh-session:"), "the machine tag must not be shown to people")
        XCTAssertTrue(shown.hasPrefix("The model rejected this Distill session's history"), shown)
        XCTAssertTrue(shown.hasSuffix("Invalid `signature` in `thinking` block"), "the provider's reason must survive")
        let plain = "Grok ACP RPC error: rate limit exceeded"
        XCTAssertEqual(AgentErrorRecoveryAction.displayText(plain), plain, "text without the marker is unchanged")
        // WHY: the row strips for display only; classification still runs on the
        // raw message, so stripping must never change the action.
        XCTAssertNotEqual(
            AgentErrorRecoveryAction.pairedWireValue(message: shown, recoverable: false),
            AgentErrorRecoveryAction.pairedWireValue(message: freshSessionError, recoverable: false)
        )
    }

    func test_freshSessionNoticeRow_isLabelledNewSessionNotCompacted() {
        // WHY: Distill's replacement-session notice rides as .contextCompaction for
        // decoder compatibility; calling it "Compacted" tells the user the wrong thing.
        let notice = AssistantItem(
            id: "distill-fresh-session-sess-1", turnId: "t", type: .contextCompaction, state: .completed,
            summary: "Switched model family - started a new Distill session",
            body: "Switched model family - started a new Distill session", startedAtMs: 0
        )
        let presentation = AgentTimelineItemPresentation.make(for: notice)
        XCTAssertEqual(presentation.verb, "New session")
        XCTAssertEqual(presentation.icon, "arrow.triangle.2.circlepath")
        XCTAssertTrue(AgentTimelineItemPresentation.toolAccessibilityLabel(for: notice).hasPrefix("New session"))

        let compaction = AssistantItem(
            id: "compact-1", turnId: "t", type: .contextCompaction, state: .completed,
            summary: "Context compacted", body: "", startedAtMs: 0
        )
        XCTAssertEqual(AgentTimelineItemPresentation.make(for: compaction).verb, "Compacted",
                       "a real provider compaction keeps its label")
        XCTAssertEqual(AgentTimelineItemPresentation.make(for: compaction).icon, "rectangle.compress.vertical")
    }
}
