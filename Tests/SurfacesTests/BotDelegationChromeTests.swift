import XCTest
import CoreModel
import AgentRuntime
@testable import Surfaces

/// Chrome contracts for delegated bot-peer runs: they paint as Subagents on
/// the host thread, and a stale waiting row can never pin the tab/workspace
/// spinner after the thread reached a terminal status.
final class BotDelegationChromeTests: XCTestCase {

    func test_botDelegationNodeId_displaysAsHandle() {
        XCTAssertEqual(SubagentActivityProjection.botDelegationHandle(from: "bot.ceo.1234"), "ceo")
        XCTAssertNil(SubagentActivityProjection.botDelegationHandle(from: "nested.claude.1234"))
        XCTAssertNil(SubagentActivityProjection.botDelegationHandle(from: "root"))
        XCTAssertEqual(
            SubagentActivityProjection.displayName(nodeId: "bot.ceo.abcd", provider: .grok, model: "grok-4"),
            "@ceo",
            "operators know the teammate by @handle, not by a worker hash"
        )
    }

    func test_botDelegationReceipt_projectsAsActiveSubagentOnHostThread() {
        let hostThread = AgentThreadID()
        let peerRun = AgentRunID()
        let receipt = AgentOrchestrationAdmissionReceipt(
            runId: peerRun,
            threadId: hostThread,
            nodeId: "bot.ceo.\(peerRun.value.uuidString)",
            routingRevision: 0,
            policyDigest: "bot-delegation",
            packageRevision: "bot-delegation",
            provider: .grok,
            providerInstanceId: "grok",
            model: "grok-4",
            capabilitySnapshotId: "bot-delegation",
            decisionReason: AgentOrchestrationRuntime.botDelegationDecisionReason,
            lifecycleStatus: .accepted,
            permissionMode: .fullAccess
        )
        let snapshot = SubagentActivityProjection.project(
            receipts: [receipt],
            threadIds: [hostThread],
            activeRunIds: [peerRun]
        )
        XCTAssertEqual(snapshot.activeCount, 1, "a working bot belongs in the Subagents Active list")
        XCTAssertEqual(snapshot.active.first?.displayName, "@ceo")
        XCTAssertEqual(snapshot.active.first?.phase, .working)

        let otherThread = SubagentActivityProjection.project(
            receipts: [receipt],
            threadIds: [AgentThreadID()],
            activeRunIds: [peerRun]
        )
        XCTAssertTrue(otherThread.isEmpty, "bot rows must not leak into unrelated threads")
    }

    func test_waitingPeerActivity_neverSpinsChromeOnTerminalStoppedThreads() {
        // WHY (reported): Stop left the tab + workspace spinners latched on a
        // stale `.waiting` peer row even with the thread already cancelled.
        XCTAssertTrue(AgentAppViewModel.waitingPeerActivityKeepsChromeBusy(threadStatus: .running))
        XCTAssertTrue(AgentAppViewModel.waitingPeerActivityKeepsChromeBusy(threadStatus: .pending))
        XCTAssertTrue(
            AgentAppViewModel.waitingPeerActivityKeepsChromeBusy(threadStatus: .completed),
            "reply_only tails land after the host completes; reconciliation settles the row"
        )
        XCTAssertFalse(AgentAppViewModel.waitingPeerActivityKeepsChromeBusy(threadStatus: .cancelled))
        XCTAssertFalse(AgentAppViewModel.waitingPeerActivityKeepsChromeBusy(threadStatus: .failed))
        XCTAssertFalse(AgentAppViewModel.waitingPeerActivityKeepsChromeBusy(threadStatus: .interrupted))
    }
}
