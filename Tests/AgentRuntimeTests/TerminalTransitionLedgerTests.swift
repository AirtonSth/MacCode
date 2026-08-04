import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

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

    func test_terminalInitiator_userStop_processDeath_rpcTimeout() {
        XCTAssertEqual(
            AgentRunCoordinator.terminalInitiator(
                status: .cancelled,
                providerTerminalAcknowledged: false
            ),
            .userStop
        )
        XCTAssertEqual(
            AgentRunCoordinator.terminalInitiator(
                status: .failed,
                providerTerminalAcknowledged: false
            ),
            .processDeath
        )
        XCTAssertEqual(
            AgentRunCoordinator.terminalInitiator(
                status: .failed,
                providerTerminalAcknowledged: true,
                errorMessage: "request timed out after 30s"
            ),
            .rpcTimeout
        )
        XCTAssertEqual(
            AgentRunCoordinator.terminalInitiator(
                status: .completed,
                providerTerminalAcknowledged: true
            ),
            .providerTerminal
        )
        XCTAssertEqual(
            AgentRunCoordinator.terminalInitiator(
                status: .interrupted,
                providerTerminalAcknowledged: false
            ),
            .relaunchReconcile
        )
    }

    func test_recordTerminalTransition_usesPolicy_blocksFalseCompleted() throws {
        let tmp = NSTemporaryDirectory() + "rc2-term-policy-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let ledger = TerminalTransitionLedger(
            directory: URL(fileURLWithPath: tmp).appendingPathComponent("diagnostics")
        )
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: AgentThreadRepository(db: db),
            providers: [:],
            terminalTransitionLedger: ledger
        )
        // Local initiator claiming completed must not present as completed.
        let presentation = coordinator.recordTerminalTransition(
            runId: AgentRunID(),
            threadId: AgentThreadID(),
            requestedStatus: .completed,
            initiator: .relaunchReconcile
        )
        XCTAssertEqual(presentation, .interrupted)
        XCTAssertFalse(
            TerminalTransitionPolicy.allowsCompletedPresentation(
                TerminalTransitionRecord(
                    runId: "x",
                    threadId: "y",
                    reason: .relaunchReconcile,
                    initiator: .relaunchReconcile,
                    requestedStatus: .completed
                )
            )
        )
        let rows = try ledger.allRecords()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].reason, .relaunchReconcile)
    }
}
