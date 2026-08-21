import XCTest
import CoreModel
@testable import AgentRuntime

/// Delegated bot-peer runs are workers, not primary threads: they leave the
/// Active Threads count and surface as Subagents telemetry instead.
final class BotDelegationSubagentTests: XCTestCase {

    func test_primaryActiveThreadIds_excludesDelegatedRuns() {
        let hostThread = AgentThreadID()
        let peerThread = AgentThreadID()
        let hostRun = AgentRunID()
        let peerRun = AgentRunID()
        let primary = AgentRunCoordinator.primaryActiveThreadIds(
            activeThreads: [hostThread: hostRun, peerThread: peerRun],
            delegatedRunParents: [peerRun: hostRun]
        )
        XCTAssertEqual(
            primary,
            [hostThread],
            "one host consulting one bot must count as ONE active thread"
        )
    }

    func test_primaryActiveThreadIds_keepsIndependentBotThreads() {
        // A bot the user talks to directly (own Desk run) is a primary thread;
        // only runs registered as delegated children are excluded.
        let deskThread = AgentThreadID()
        let deskRun = AgentRunID()
        let primary = AgentRunCoordinator.primaryActiveThreadIds(
            activeThreads: [deskThread: deskRun],
            delegatedRunParents: [:]
        )
        XCTAssertEqual(primary, [deskThread])
    }

    private final class ClockBox: @unchecked Sendable {
        var value = Date(timeIntervalSince1970: 1_000_000)
    }

    func test_recordBotDelegationTelemetry_writesAcceptedReceiptOnHostThread() throws {
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-delegation-receipts-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: auditURL) }
        // ISO8601 persistence truncates to seconds, so record → finalize must
        // cross a second boundary for latest-by-id to pick the finalized row.
        let clock = ClockBox()
        let runtime = AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(auditLogURL: auditURL),
            packageVerification: { true },
            killSwitch: { false },
            now: { [clock] in clock.value }
        )
        let hostThread = AgentThreadID()
        let peerRun = AgentRunID()
        let receipt = try runtime.recordBotDelegationTelemetry(
            runId: peerRun,
            hostThreadId: hostThread,
            nodeId: "bot.ceo.\(peerRun.value.uuidString)",
            provider: .grok,
            providerInstanceId: "grok",
            model: "grok-4",
            reasoningEffort: .high,
            permissionMode: .fullAccess
        )
        XCTAssertEqual(receipt.threadId, hostThread, "row must scope to the HOST thread's Subagents panel")
        XCTAssertEqual(receipt.runId, peerRun)
        XCTAssertEqual(receipt.lifecycleStatus, .accepted)
        XCTAssertNil(receipt.delegationCapabilitySHA256, "telemetry-only: must never authorize descendants")
        XCTAssertNil(receipt.finalizationCapabilitySHA256)
        XCTAssertNotNil(receipt.deadlineAt, "a crash-orphaned row must be able to demote, not spin forever")
        XCTAssertEqual(receipt.decisionReason, AgentOrchestrationRuntime.botDelegationDecisionReason)

        // Idempotent for the same run.
        let again = try runtime.recordBotDelegationTelemetry(
            runId: peerRun,
            hostThreadId: hostThread,
            nodeId: "bot.ceo.other",
            provider: .grok,
            providerInstanceId: "grok",
            model: "grok-4",
            permissionMode: .fullAccess
        )
        XCTAssertEqual(again.id, receipt.id)

        clock.value = clock.value.addingTimeInterval(5)
        try runtime.finalizeReceipt(runId: peerRun, status: .cancelled)
        let rows = try runtime.activityReceipts(threadIds: [hostThread], limit: 16)
        let finalized = try XCTUnwrap(rows.first(where: { $0.runId == peerRun }))
        XCTAssertEqual(finalized.lifecycleStatus, .finalized)
        XCTAssertEqual(finalized.finalRunStatus, .cancelled)
    }
}
