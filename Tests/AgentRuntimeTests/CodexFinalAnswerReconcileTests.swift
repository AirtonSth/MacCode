import XCTest
@testable import AgentRuntime
import CoreModel

/// Regression: Codex may complete a final_answer item without turn/completed.
/// Reconciliation must be phase-gated and authority-gated (thread/read), never
/// inferred from ordinary assistant text alone.
final class CodexFinalAnswerReconcileTests: XCTestCase {
    func test_isFinalAnswerPhaseItem_requiresExplicitPhase() {
        XCTAssertTrue(
            CodexAppServerAdapter.isFinalAnswerPhaseItem(
                ["type": "agentMessage", "phase": "final_answer", "text": "done"],
                type: "agentMessage"
            )
        )
        XCTAssertTrue(
            CodexAppServerAdapter.isFinalAnswerPhaseItem(
                ["type": "assistantMessage", "phase": "finalAnswer"],
                type: "assistantMessage"
            )
        )
        XCTAssertFalse(
            CodexAppServerAdapter.isFinalAnswerPhaseItem(
                ["type": "agentMessage", "text": "Loop concluído"],
                type: "agentMessage"
            ),
            "ordinary assistant text must not arm final_answer reconcile"
        )
        XCTAssertFalse(
            CodexAppServerAdapter.isFinalAnswerPhaseItem(
                ["type": "commandExecution", "phase": "final_answer"],
                type: "commandExecution"
            )
        )
    }

    func test_turnIsAuthoritativelyTerminal_readsTurnAndThreadStatus() {
        let completedTurn: [String: Any] = [
            "thread": [
                "turns": [
                    ["id": "t1", "status": "completed", "items": []]
                ]
            ]
        ]
        XCTAssertTrue(
            CodexAppServerAdapter.turnIsAuthoritativelyTerminal(in: completedTurn, turnId: "t1")
        )

        let idleThread: [String: Any] = [
            "thread": [
                "status": "idle",
                "turns": [
                    ["id": "t1", "status": "in_progress", "items": []]
                ]
            ]
        ]
        XCTAssertTrue(
            CodexAppServerAdapter.turnIsAuthoritativelyTerminal(in: idleThread, turnId: "t1"),
            "idle thread status is authoritative even if turn status lags"
        )

        let stillActive: [String: Any] = [
            "thread": [
                "status": "active",
                "turns": [
                    ["id": "t1", "status": "in_progress", "items": []]
                ]
            ]
        ]
        XCTAssertFalse(
            CodexAppServerAdapter.turnIsAuthoritativelyTerminal(in: stillActive, turnId: "t1")
        )
    }

    func test_finalMessageFromThreadRead_prefersLastAssistantItem() {
        let response: [String: Any] = [
            "thread": [
                "turns": [
                    [
                        "id": "t1",
                        "status": "completed",
                        "items": [
                            ["type": "agentMessage", "text": "preamble"],
                            ["type": "agentMessage", "text": "Loop concluído com sucesso"]
                        ]
                    ]
                ]
            ]
        ]
        XCTAssertEqual(
            CodexAppServerAdapter.finalMessageFromThreadRead(response, turnId: "t1"),
            "Loop concluído com sucesso"
        )
    }
}
