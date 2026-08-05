import XCTest
@testable import AgentRuntime
import CoreModel

/// Regression: Codex may complete a final_answer item without turn/completed.
/// Reconciliation must be phase-gated and authority-gated (thread/read), never
/// inferred from ordinary assistant text alone. Matched-turn status owns the
/// outcome; thread idle must not override a still-active matched turn.
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

    func test_matchedTurnStatus_extractsTurnStatusOnlyWhenPresent() {
        let withTurn: [String: Any] = [
            "thread": [
                "status": "idle",
                "turns": [
                    ["id": "t1", "status": "failed", "items": []]
                ]
            ]
        ]
        XCTAssertEqual(
            CodexAppServerAdapter.matchedTurnStatus(in: withTurn, turnId: "t1"),
            "failed"
        )

        let missingTurn: [String: Any] = [
            "thread": [
                "status": "idle",
                "turns": [
                    ["id": "other", "status": "completed", "items": []]
                ]
            ]
        ]
        XCTAssertNil(
            CodexAppServerAdapter.matchedTurnStatus(in: missingTurn, turnId: "t1"),
            "idle fallback applies only when the expected turn is absent"
        )
    }

    func test_turnIsAuthoritativelyTerminal_matchedActiveTurnIgnoresThreadIdle() {
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

        // WHY: a matched in-progress turn means Codex is still working on this
        // generation. Thread "idle" is ambient and must not terminalize an
        // active matched turn (false success / false cancel).
        let idleWhileMatchedActive: [String: Any] = [
            "thread": [
                "status": "idle",
                "turns": [
                    ["id": "t1", "status": "in_progress", "items": []]
                ]
            ]
        ]
        XCTAssertFalse(
            CodexAppServerAdapter.turnIsAuthoritativelyTerminal(in: idleWhileMatchedActive, turnId: "t1"),
            "thread idle must not override a matched active turn"
        )

        let idleWhileMatchedStatusMissing: [String: Any] = [
            "thread": [
                "status": "idle",
                "turns": [["id": "t1", "items": []]]
            ]
        ]
        XCTAssertFalse(
            CodexAppServerAdapter.turnIsAuthoritativelyTerminal(
                in: idleWhileMatchedStatusMissing,
                turnId: "t1"
            ),
            "a present expected turn with no status is not the same as an absent turn"
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

        // Absent expected turn + idle thread remains terminal authority.
        let absentTurnIdle: [String: Any] = [
            "thread": [
                "status": "idle",
                "turns": [
                    ["id": "other", "status": "completed", "items": []]
                ]
            ]
        ]
        XCTAssertTrue(
            CodexAppServerAdapter.turnIsAuthoritativelyTerminal(in: absentTurnIdle, turnId: "t1"),
            "when the expected turn is absent, idle thread status is authoritative"
        )

        for terminal in ["failed", "cancelled", "canceled", "interrupted"] {
            let payload: [String: Any] = [
                "thread": [
                    "status": "active",
                    "turns": [
                        ["id": "t1", "status": terminal, "items": []]
                    ]
                ]
            ]
            XCTAssertTrue(
                CodexAppServerAdapter.turnIsAuthoritativelyTerminal(in: payload, turnId: "t1"),
                "\(terminal) matched turn is terminal even if thread is still active"
            )
        }
    }

    func test_reconcileTerminalOutcome_preservesMatchedStatusAndClassifierPolicy() {
        let completedWithOutput = CodexAppServerAdapter.reconcileTerminalOutcome(
            matchedTurnStatus: "completed",
            finalMessage: "Loop concluído"
        )
        XCTAssertEqual(completedWithOutput.status, .completed)
        XCTAssertEqual(completedWithOutput.finalMessage, "Loop concluído")
        XCTAssertTrue(completedWithOutput.emitSuccessfulTurnCompleted)
        XCTAssertNil(completedWithOutput.errorMessage)

        // WHY: empty completed is not success — same policy as ProviderStderrClassifier.
        let completedWithoutOutput = CodexAppServerAdapter.reconcileTerminalOutcome(
            matchedTurnStatus: "completed",
            finalMessage: nil
        )
        XCTAssertEqual(completedWithoutOutput.status, .failed)
        XCTAssertFalse(
            completedWithoutOutput.emitSuccessfulTurnCompleted,
            "never emit successful turnCompleted semantics for a non-success"
        )
        XCTAssertEqual(
            completedWithoutOutput.errorMessage,
            ProviderStderrClassifier.resolveTerminal(
                provider: .codex,
                status: .completed,
                observedDetail: nil,
                producedAssistantOutput: false
            ).errorMessage
        )

        let failed = CodexAppServerAdapter.reconcileTerminalOutcome(
            matchedTurnStatus: "failed",
            finalMessage: "provider boom"
        )
        XCTAssertEqual(failed.status, .failed)
        XCTAssertFalse(failed.emitSuccessfulTurnCompleted)
        XCTAssertEqual(failed.finalMessage, "provider boom")

        let cancelled = CodexAppServerAdapter.reconcileTerminalOutcome(
            matchedTurnStatus: "cancelled",
            finalMessage: "should not surface as success"
        )
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertFalse(cancelled.emitSuccessfulTurnCompleted)

        let interrupted = CodexAppServerAdapter.reconcileTerminalOutcome(
            matchedTurnStatus: "interrupted",
            finalMessage: nil
        )
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertFalse(interrupted.emitSuccessfulTurnCompleted)

        // Absent matched status (idle-only authority) defaults to completed path.
        let idleAbsent = CodexAppServerAdapter.reconcileTerminalOutcome(
            matchedTurnStatus: nil,
            finalMessage: "from buffer"
        )
        XCTAssertEqual(idleAbsent.status, .completed)
        XCTAssertTrue(idleAbsent.emitSuccessfulTurnCompleted)
        XCTAssertEqual(idleAbsent.finalMessage, "from buffer")
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

    func test_finalMessageFromThreadRead_doesNotBorrowAnotherTurnWhenExpectedTurnIsAbsent() {
        let response: CodexAppServerClient.JSONObject = [
            "thread": [
                "turns": [[
                    "id": "older-turn",
                    "items": [[
                        "id": "older-answer",
                        "type": "agentMessage",
                        "text": "answer from a different turn"
                    ]]
                ]]
            ]
        ]

        XCTAssertNil(
            CodexAppServerAdapter.finalMessageFromThreadRead(response, turnId: "missing-current-turn"),
            "an idle snapshot with the expected turn absent must not classify success from a prior turn's answer"
        )
    }
}
