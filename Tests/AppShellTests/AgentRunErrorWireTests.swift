import XCTest
import CoreModel
import Persistence
@testable import AppShell
import SocketServer

/// `agent.run.error` / `agent.run.failed` carry the action iOS renders.
final class AgentRunErrorWireTests: XCTestCase {
    func test_failedRunFields_carryDisplayTextAndRecoveryAction() {
        let raw = "[fresh-session:incompatible-history] The model rejected this Distill session's history; Retry starts a new Distill session: boom"
        let fields = AgentRunErrorWire.fields(message: raw, recoverable: false)
        XCTAssertEqual(fields["message"], .string("The model rejected this Distill session's history; Retry starts a new Distill session: boom"),
                       "iOS shows `message` as-is, so the host strips the machine marker")
        XCTAssertEqual(fields["recovery_action"], .string("new_session"))
        XCTAssertEqual(AgentRunErrorWire.fields(message: "[auth-required] 401", recoverable: false)["recovery_action"], .string("sign_in"))
    }

    func test_failedRunFields_sendExplicitNullWhenNoActionIsSafe() {
        // WHY: an explicit null tells a new client "no action" (the host
        // advertises run_recovery_action_v1, so the key is always present).
        let fields = AgentRunErrorWire.fields(message: "invalid request payload", recoverable: false)
        XCTAssertEqual(fields["recovery_action"], .null)
        XCTAssertEqual(fields["message"], .string("invalid request payload"))
    }

    func test_failedEventFields_streamErrorActionWinsOverStoredMessage() {
        // WHY: the Mac row keeps the stream error's classification at finish;
        // re-classifying the stored text as not recoverable would wipe a Retry.
        let fields = AgentRunErrorWire.failedEventFields(
            status: .failed, storedMessage: "Claude Agent SDK error", streamErrorAction: .string("retry")
        )
        XCTAssertEqual(fields["recovery_action"], .string("retry"))
        XCTAssertEqual(fields["message"], .string("Claude Agent SDK error"))
        XCTAssertEqual(
            AgentRunErrorWire.failedEventFields(status: .cancelled, storedMessage: nil, streamErrorAction: nil),
            ["recovery_action": .null], "a cancelled run offers no error action"
        )
        XCTAssertEqual(
            AgentRunErrorWire.failedEventFields(status: .failed, storedMessage: nil, streamErrorAction: nil),
            ["recovery_action": .null], "the key is present even without a stored message"
        )
    }

    func test_ledger_takesOnceAndStaysBounded() {
        let ledger = AgentRunErrorActionLedger(capacity: 2)
        let a = AgentRunID(), b = AgentRunID(), c = AgentRunID()
        ledger.record(runId: a, action: .string("retry"))
        ledger.record(runId: a, action: .string("sign_in"))
        XCTAssertEqual(ledger.take(runId: a), .string("sign_in"), "the run's last stream error wins, as on the Mac")
        XCTAssertNil(ledger.take(runId: a))
        ledger.record(runId: a, action: .null)
        ledger.record(runId: b, action: .null)
        ledger.record(runId: c, action: .string("retry"))
        XCTAssertNil(ledger.take(runId: a), "the oldest entry is evicted past capacity")
        XCTAssertEqual(ledger.take(runId: c), .string("retry"))
    }
}

/// The payloads AppContext actually publishes on EventBus.
@MainActor
final class AgentRunErrorEventPayloadTests: XCTestCase {
    private func makeRun(_ ctx: AppContext, errorMessage: String?) throws -> (AgentThreadID, AgentRunID) {
        let thread = AgentThread(title: "run-error-wire", provider: .claude, model: "m")
        try ctx.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .claude, model: "m", status: .failed,
                           startedAt: Date(), errorMessage: errorMessage)
        try ctx.runRepo.upsert(run)
        return (thread.id, run.id)
    }

    /// Collects this run's `agent.run.error` / `agent.run.failed` payloads.
    private func capture(runId: AgentRunID, _ body: () -> Void) async throws -> [String: [String: JSONValue]] {
        let rid = runId.value.uuidString.lowercased()
        let lock = NSLock()
        var seen: [String: [String: JSONValue]] = [:]
        let got = expectation(description: "agent.run.failed published")
        let sub = EventBus.shared.subscribeFromCurrent { event in
            guard event.kind == "agent.run.error" || event.kind == "agent.run.failed",
                  let payload = event.payload.objectValue, payload["run_id"] == .string(rid) else { return }
            lock.lock(); seen[event.kind] = payload; lock.unlock()
            if event.kind == "agent.run.failed" { got.fulfill() }
        }
        defer { EventBus.shared.unsubscribe(sub.id) }
        body()
        await fulfillment(of: [got], timeout: 5)
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    func test_recoverableStreamErrorThenFailedFinish_isRetryOnBothEvents() async throws {
        let ctx = try AppContext(channel: .debug, appSupportOverride: NSTemporaryDirectory() + "rc2-run-error-wire-" + UUID().uuidString)
        let (tid, rid) = try makeRun(ctx, errorMessage: "Claude Agent SDK error")
        let seen = try await capture(runId: rid) {
            ctx.coordinator.onAssistantEvent?(.error(message: "Claude Agent SDK error", recoverable: true), tid, rid)
            ctx.coordinator.onRunFinished?(tid, rid, .failed)
        }
        XCTAssertEqual(seen["agent.run.error"]?["recovery_action"], .string("retry"))
        XCTAssertEqual(seen["agent.run.error"]?["recoverable"], .bool(true))
        XCTAssertEqual(seen["agent.run.failed"]?["recovery_action"], .string("retry"),
                       "the later event must not wipe the Retry the Mac row still offers")
        XCTAssertEqual(seen["agent.run.failed"]?["message"], .string("Claude Agent SDK error"))
    }

    func test_freshSessionFailure_isStrippedAndNewSessionOnBothEvents() async throws {
        let ctx = try AppContext(channel: .debug, appSupportOverride: NSTemporaryDirectory() + "rc2-run-error-wire-" + UUID().uuidString)
        let raw = "[fresh-session:incompatible-history] The model rejected this session's history: boom"
        let (tid, rid) = try makeRun(ctx, errorMessage: raw)
        let seen = try await capture(runId: rid) {
            ctx.coordinator.onAssistantEvent?(.error(message: raw, recoverable: false), tid, rid)
            ctx.coordinator.onRunFinished?(tid, rid, .failed)
        }
        for kind in ["agent.run.error", "agent.run.failed"] {
            XCTAssertEqual(seen[kind]?["message"], .string("The model rejected this session's history: boom"), kind)
            XCTAssertEqual(seen[kind]?["recovery_action"], .string("new_session"), kind)
        }
    }

    func test_failedFinishWithoutStreamError_classifiesStoredMessage_andCancelIsNull() async throws {
        let ctx = try AppContext(channel: .debug, appSupportOverride: NSTemporaryDirectory() + "rc2-run-error-wire-" + UUID().uuidString)
        let (tid, rid) = try makeRun(ctx, errorMessage: "[auth-required] 401 Unauthorized")
        let seen = try await capture(runId: rid) {
            ctx.coordinator.onRunFinished?(tid, rid, .failed)
        }
        XCTAssertEqual(seen["agent.run.failed"]?["recovery_action"], .string("sign_in"))

        let (tid2, rid2) = try makeRun(ctx, errorMessage: "[auth-required] 401 Unauthorized")
        let cancelled = try await capture(runId: rid2) {
            ctx.coordinator.onRunFinished?(tid2, rid2, .cancelled)
        }
        XCTAssertEqual(cancelled["agent.run.failed"]?["recovery_action"], .null, "a cancelled run offers no error action")
        XCTAssertNil(cancelled["agent.run.failed"]?["message"], "a cancel is not shown as an error")
    }
}
