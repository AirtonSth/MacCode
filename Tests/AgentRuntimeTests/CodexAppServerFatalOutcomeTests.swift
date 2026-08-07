import XCTest
@testable import AgentRuntime
import CoreModel

// P1: a fatal mid-turn error (auth death, server error) must terminate the run
// so the UI does not show a stuck spinner forever, while retry-able errors must
// keep the run alive. These tests pin the pure classifier that drives that
// decision so the business rule cannot silently regress.
final class CodexAppServerFatalOutcomeTests: XCTestCase {
    func test_retryableErrorKeepsRunAlive() {
        // WHY: an error the provider will retry must NOT terminate the run;
        // terminating here would abort a turn that is about to recover on its own.
        let outcome = CodexAppServerAdapter.classifyFatalOutcome(
            eventKind: "error",
            willRetry: true,
            errorCode: "rate_limited"
        )
        XCTAssertNil(outcome, "willRetry=true must keep the run running (nil outcome)")
    }

    func test_nonRetryableErrorFailsRun() {
        // WHY: a fatal error with willRetry=false leaves a stuck spinner today;
        // it must map to a terminal .failed so the run actually terminates.
        let outcome = CodexAppServerAdapter.classifyFatalOutcome(
            eventKind: "error",
            willRetry: false,
            errorCode: "internal_error"
        )
        XCTAssertEqual(outcome, .failed(isAuth: false), "willRetry=false must terminate as .failed (non-auth)")
    }

    func test_turnFailedAlwaysFailsRun() {
        // WHY: turn/failed is intrinsically terminal regardless of willRetry,
        // so the spinner must stop on this signal.
        let outcome = CodexAppServerAdapter.classifyFatalOutcome(
            eventKind: "turn/failed",
            willRetry: false,
            errorCode: nil
        )
        XCTAssertEqual(outcome, .failed(isAuth: false), "turn/failed must terminate as .failed")
    }

    func test_turnCompletedFailedAlwaysFailsRun() {
        // WHY: live app-server uses turn/completed + status=failed; the adapter
        // classifies that path as turn/completed-failed and must still terminate.
        let outcome = CodexAppServerAdapter.classifyFatalOutcome(
            eventKind: "turn/completed-failed",
            willRetry: false,
            errorCode: nil
        )
        XCTAssertEqual(outcome, .failed(isAuth: false), "turn/completed-failed must terminate as .failed")
    }

    func test_turnCompletedWireStatusPrefersNestedTurnStatus() {
        // WHY: wire contract puts status on turn.status; top-level is fallback only.
        XCTAssertEqual(
            CodexAppServerAdapter.turnCompletedWireStatus(from: [
                "status": "completed",
                "turn": ["id": "t1", "status": "failed"]
            ]),
            "failed"
        )
        XCTAssertEqual(
            CodexAppServerAdapter.turnCompletedWireStatus(from: ["status": "interrupted"]),
            "interrupted"
        )
        XCTAssertNil(CodexAppServerAdapter.turnCompletedWireStatus(from: ["turnId": "t1"]))
        XCTAssertTrue(CodexAppServerAdapter.isFailedTurnStatus("Failed"))
        XCTAssertTrue(CodexAppServerAdapter.isInterruptedTurnStatus("INTERRUPTED"))
        XCTAssertFalse(CodexAppServerAdapter.isFailedTurnStatus("completed"))
    }

    func test_authClassErrorFailsRunFlaggedAuth() {
        // WHY: an auth death must terminate AND be flagged auth so the UI can
        // show a 'Sign in' CTA instead of a generic error banner.
        let outcome = CodexAppServerAdapter.classifyFatalOutcome(
            eventKind: "error",
            willRetry: false,
            errorCode: "401 Unauthorized"
        )
        XCTAssertEqual(outcome, .failed(isAuth: true), "auth-class fatal error must be flagged isAuth=true")
    }

    func test_authClassTurnFailedIsFlaggedAuth() {
        // WHY: auth death can arrive on turn/failed too; the auth flag must
        // survive that path so the Sign-in CTA still appears.
        let outcome = CodexAppServerAdapter.classifyFatalOutcome(
            eventKind: "turn.failed",
            willRetry: false,
            errorCode: "token_expired"
        )
        XCTAssertEqual(outcome, .failed(isAuth: true), "auth-class turn/failed must be flagged isAuth=true")
    }

    func test_unknownEventKindKeepsRunAlive() {
        // WHY: only error / turn/failed are fatal; unrelated signals must never
        // terminate the run.
        let outcome = CodexAppServerAdapter.classifyFatalOutcome(
            eventKind: "turn/completed",
            willRetry: false,
            errorCode: "401"
        )
        XCTAssertNil(outcome, "non-fatal event kinds must keep the run running")
    }

    func test_authFailedEventCarriesSignInMarker() {
        // WHY: the adapter must surface an auth-aware signal; the failed event
        // for an auth outcome must carry the auth marker so the UI can route to
        // the Sign-in CTA, and a non-auth failure must NOT carry it.
        let authEvent = CodexAppServerAdapter.failedEvent(
            for: .failed(isAuth: true),
            message: "Unauthorized",
            providerThreadId: "thread-1"
        )
        guard case let .finished(status, finalMessage, providerThreadId) = authEvent else {
            return XCTFail("auth failure must be a .finished event")
        }
        XCTAssertEqual(status, .failed)
        XCTAssertEqual(providerThreadId, "thread-1")
        XCTAssertEqual(finalMessage, "\(CodexAppServerAdapter.authFailureMarker) Unauthorized")

        let plainEvent = CodexAppServerAdapter.failedEvent(
            for: .failed(isAuth: false),
            message: "Internal error",
            providerThreadId: "thread-1"
        )
        guard case let .finished(_, plainMessage, _) = plainEvent else {
            return XCTFail("non-auth failure must be a .finished event")
        }
        XCTAssertEqual(plainMessage, "Internal error", "non-auth failure must not carry the auth marker")
    }
}
