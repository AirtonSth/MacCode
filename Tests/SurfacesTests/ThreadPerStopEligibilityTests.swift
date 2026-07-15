import XCTest
@testable import Surfaces
import CoreModel

/// Proves the per-thread stop eligibility helper that drives the stop affordance
/// in the thread rail. The helper is pure (no MainActor, no UI types), so these
/// tests run without the surface and are not annotated @MainActor.
///
/// Business rule: a stop affordance must appear while a run is pending or
/// running. Pending work is cancellable before the provider handle is registered;
/// finished work must never expose a phantom stop action.
final class ThreadPerStopEligibilityTests: XCTestCase {

    // MARK: - isEligible

    func test_isEligible_running_returnsTrue() {
        // Running thread must show a stop affordance so the user can kill it
        // without switching selection to that thread first.
        XCTAssertTrue(
            AgentThreadStopEligibility.isEligible(threadStatus: .running),
            "a running thread must be eligible for per-thread stop"
        )
    }

    func test_isEligible_pending_returnsTrue() {
        // The coordinator retains a pending stop and applies it as soon as the
        // provider handle is registered. Hiding Stop here makes that safety seam
        // unreachable during slow provider startup.
        XCTAssertTrue(
            AgentThreadStopEligibility.isEligible(threadStatus: .pending),
            "a pending run must be cancellable before provider startup completes"
        )
    }

    func test_isEligible_completed_returnsFalse() {
        XCTAssertFalse(
            AgentThreadStopEligibility.isEligible(threadStatus: .completed),
            "a completed thread needs no stop affordance"
        )
    }

    func test_isEligible_failed_returnsFalse() {
        XCTAssertFalse(
            AgentThreadStopEligibility.isEligible(threadStatus: .failed),
            "a failed thread needs no stop affordance"
        )
    }

    func test_isEligible_cancelled_returnsFalse() {
        XCTAssertFalse(
            AgentThreadStopEligibility.isEligible(threadStatus: .cancelled),
            "a cancelled thread needs no stop affordance"
        )
    }

    func test_isEligible_interrupted_returnsFalse() {
        XCTAssertFalse(
            AgentThreadStopEligibility.isEligible(threadStatus: .interrupted),
            "an interrupted thread needs no stop affordance"
        )
    }

    // MARK: - targetThreadId

    func test_targetThreadId_runningThread_returnsItsOwnId() {
        // The stop action must target the row's own thread, not the selected thread.
        // This is the per-thread stop contract: stopping thread B while A is selected.
        let id = AgentThreadID()
        let thread = AgentThread(
            id: id,
            workspaceId: WorkspaceID(),
            title: "background run",
            provider: .codex,
            model: "gpt-4o",
            status: .running
        )

        let target = AgentThreadStopEligibility.targetThreadId(thread: thread)
        XCTAssertEqual(target, id,
            "stop action for a running thread must target that thread's own id, not the selected thread")
    }

    func test_targetThreadId_nonRunningThread_returnsNil() {
        // No stop affordance should be shown or actionable for a non-running thread.
        let thread = AgentThread(
            workspaceId: WorkspaceID(),
            title: "finished",
            provider: .codex,
            model: "gpt-4o",
            status: .completed
        )

        XCTAssertNil(
            AgentThreadStopEligibility.targetThreadId(thread: thread),
            "targetThreadId must return nil for non-running threads to prevent phantom stop actions"
        )
    }

    func test_targetThreadId_pendingThread_returnsItsOwnId() {
        let id = AgentThreadID()
        let thread = AgentThread(
            id: id,
            workspaceId: WorkspaceID(),
            title: "provider starting",
            provider: .codex,
            model: "gpt-4o",
            status: .pending
        )

        XCTAssertEqual(
            AgentThreadStopEligibility.targetThreadId(thread: thread),
            id,
            "pending cancellation must target the row's thread even before a provider process exists"
        )
    }
}
