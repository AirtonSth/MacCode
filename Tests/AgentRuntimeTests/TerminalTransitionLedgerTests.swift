import XCTest
@testable import AgentRuntime
import CoreModel

/// plan-final W0/W1: terminal reason classes never masquerade as provider completed.
final class TerminalTransitionLedgerTests: XCTestCase {
    func test_classify_relaunchIsInterruptedNotCompleted() {
        let reason = TerminalTransitionReason.classify(
            requestedStatus: .running,
            initiator: .relaunchReconcile
        )
        XCTAssertEqual(reason, .relaunchReconcile)
        XCTAssertEqual(reason.durableStatus, .interrupted)
        XCTAssertFalse(reason.mayRenderAsProviderCompleted)
        XCTAssertEqual(reason.durableErrorMessage, "Interrupted by app restart.")
    }

    func test_classify_lockSaturationNotCompleted() {
        let reason = TerminalTransitionReason.classify(
            requestedStatus: .failed,
            initiator: .lockSaturation
        )
        XCTAssertEqual(reason, .lockSaturation)
        XCTAssertFalse(reason.mayRenderAsProviderCompleted)
    }

    func test_classify_rpcTimeoutNotCompleted() {
        let reason = TerminalTransitionReason.classify(
            requestedStatus: .failed,
            initiator: .rpcTimeout
        )
        XCTAssertEqual(reason, .rpcTimeout)
        XCTAssertFalse(reason.mayRenderAsProviderCompleted)
    }

    func test_policy_rejectsFalseCompletedPresentation() {
        let record = TerminalTransitionRecord(
            runId: "r1",
            threadId: "t1",
            reason: .relaunchReconcile,
            initiator: .relaunchReconcile,
            requestedStatus: .completed
        )
        XCTAssertFalse(TerminalTransitionPolicy.allowsCompletedPresentation(record))
        XCTAssertEqual(
            TerminalTransitionPolicy.reconciledStatus(requested: .completed, reason: .relaunchReconcile),
            .interrupted
        )
    }

    func test_policy_allowsTrueProviderCompleted() {
        let record = TerminalTransitionRecord(
            runId: "r1",
            threadId: "t1",
            reason: .providerCompleted,
            initiator: .providerTerminal,
            requestedStatus: .completed
        )
        XCTAssertTrue(TerminalTransitionPolicy.allowsCompletedPresentation(record))
    }

    func test_ledger_appendAndReadRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-term-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = TerminalTransitionLedger(directory: dir, maxRows: 10, ttl: 3600)
        let record = TerminalTransitionRecord(
            runId: "run-1",
            threadId: "thread-1",
            reason: .processDeath,
            initiator: .processDeath,
            requestedStatus: .failed,
            providerPid: 42
        )
        let committed = try ledger.append(record)
        XCTAssertNotNil(committed.commitTime)
        let all = try ledger.allRecords()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].runId, "run-1")
        XCTAssertEqual(all[0].reason, .processDeath)
        XCTAssertEqual(try ledger.records(forRunId: "run-1").count, 1)
    }
}
