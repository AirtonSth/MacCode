import XCTest
@testable import AppShell
import CoreModel

final class PetLiveActivityCopyTests: XCTestCase {
    private let workspace = WorkspaceID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let threadA = AgentThreadID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    private let threadB = AgentThreadID(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

    func testEmptySurfaceReturnsNilSoLiveActivityEnds() {
        let output = PetLiveActivityCopy.make(.init(active: [], needsYou: [], completed: []))
        XCTAssertNil(output)
    }

    func testSingleActiveMatchesPetRowShape() {
        let active = PetActiveThreadItem(
            threadID: threadA,
            workspaceID: workspace,
            workspaceName: "star",
            providerName: "Grok",
            threadTitle: "ship labels",
            startedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 160)
        )
        guard let output = PetLiveActivityCopy.make(.init(
            active: [active], needsYou: [], completed: []
        )) else { return XCTFail("expected single-active surface") }
        XCTAssertEqual(output.phase, .running)
        XCTAssertEqual(output.activeThreadCount, 1)
        // Title is always the running count — most important Lock Screen signal.
        XCTAssertEqual(output.title, "1 agent running")
        XCTAssertEqual(output.statusLine, active.detail)
        XCTAssertEqual(output.threadId, threadA.value.uuidString)
        // No lastUpdatePreview → identity/detail fallback (legacy shape).
        XCTAssertEqual(output.preview, active.detail)
    }

    func testSingleActivePreviewPrefersLastThreadUpdateOverIdentityDetail() {
        // WHY: Lock Screen description must track Mac mid-run progress (tools /
        // assistant), not restating "workspace - provider - title" alone.
        let active = PetActiveThreadItem(
            threadID: threadA,
            workspaceID: workspace,
            workspaceName: "elephant",
            providerName: "Claude",
            threadTitle: "teste o funcionamento do distill",
            startedAt: Date(timeIntervalSince1970: 100),
            lastUpdatePreview: "Running: git status",
            now: Date(timeIntervalSince1970: 160)
        )
        guard let output = PetLiveActivityCopy.make(.init(
            active: [active], needsYou: [], completed: []
        )) else { return XCTFail("expected single-active surface") }
        XCTAssertEqual(output.preview, "Running: git status")
        XCTAssertEqual(output.statusLine, active.detail)
        XCTAssertFalse(output.preview.contains("elephant - Claude"))
    }

    func testItemStartedPreviewPrefersThinkingAndRejectsRuntimeNoise() {
        // WHY: Lock Screen was showing "claude runtime: claude.session.snapshot";
        // Agent App copy is Thinking / replies / tool runs.
        let thinking = PetController.itemStartedPreview(payload: [
            "item": .object([
                "id": .string("r1"),
                "type": .string("reasoning"),
                "body": .string("Considering how to run the distill checks.")
            ])
        ])
        XCTAssertEqual(thinking, "Considering how to run the distill checks.")

        let tool = PetController.itemStartedPreview(payload: [
            "item": .object([
                "id": .string("t1"),
                "type": .string("commandExecution"),
                "summary": .string("git status"),
                "body": .string("git status --short")
            ])
        ])
        XCTAssertEqual(tool, "Running: git status")

        let noise = PetController.itemStartedPreview(payload: [
            "item": .object([
                "id": .string("n1"),
                "type": .string("tool"),
                "summary": .string("claude.session.snapshot"),
                "body": .string("")
            ])
        ])
        XCTAssertNil(noise, "dotted provider method ids must not become LA description")
        XCTAssertTrue(PetController.isProviderRuntimeNoise("claude runtime: claude.session.snapshot"))
        XCTAssertFalse(PetController.isProviderRuntimeNoise("Running: git status"))
    }

    func testSingleActiveAttentionBeatsLastThreadUpdate() {
        let active = PetActiveThreadItem(
            threadID: threadA,
            workspaceID: workspace,
            workspaceName: "elephant",
            providerName: "Claude",
            threadTitle: "mid run",
            lastUpdatePreview: "Running: ls"
        )
        let needs = PetAttentionItem(
            id: "cb1",
            kind: .callback(.approval, isStale: false),
            title: "Approve: Run command",
            detail: "elephant - Claude - mid run",
            workspaceName: "elephant",
            createdAt: Date(),
            route: .agentThread(threadID: threadA, workspaceID: workspace),
            source: .callback(threadID: threadA, requestID: "r1", kind: .approval)
        )
        guard let output = PetLiveActivityCopy.make(.init(
            active: [active], needsYou: [needs], completed: []
        )) else { return XCTFail("expected surface") }
        XCTAssertTrue(output.preview.hasPrefix("Needs you"))
        XCTAssertTrue(output.preview.contains("Approve: Run command"))
    }

    func testMultiActiveUsesOverviewAndPrefersNeedsYouInPreview() {
        let a = PetActiveThreadItem(
            threadID: threadA, workspaceID: workspace, workspaceName: "star",
            providerName: "Grok", threadTitle: "one"
        )
        let b = PetActiveThreadItem(
            threadID: threadB, workspaceID: workspace, workspaceName: "elephant",
            providerName: "Claude", threadTitle: "two"
        )
        let needs = PetAttentionItem(
            id: "cb1",
            kind: .callback(.approval, isStale: false),
            title: "Approve: Run command",
            detail: "star - Grok - shell",
            workspaceName: "star",
            createdAt: Date(),
            route: .agentThread(threadID: threadA, workspaceID: workspace),
            source: .callback(threadID: threadA, requestID: "r1", kind: .approval)
        )
        guard let output = PetLiveActivityCopy.make(.init(
            active: [a, b], needsYou: [needs], completed: []
        )) else { return XCTFail("expected multi-active surface") }
        XCTAssertEqual(output.title, "2 agents running")
        XCTAssertTrue(output.statusLine.contains("star") || output.statusLine.contains("elephant"))
        XCTAssertTrue(output.preview.hasPrefix("Needs you"))
        XCTAssertTrue(output.preview.contains("Approve: Run command"))
        XCTAssertNil(output.threadId)
    }

    func testAttentionOnlyWithNoActiveShowsNeedsYouCard() {
        let needs = PetAttentionItem(
            id: "cb1",
            kind: .callback(.approval, isStale: false),
            title: "Approve: Run command",
            detail: "star - Grok - make title",
            workspaceName: "star",
            createdAt: Date(),
            route: .agentThread(threadID: threadA, workspaceID: workspace),
            source: .callback(threadID: threadA, requestID: "r1", kind: .approval)
        )
        let done = PetAttentionItem(
            id: "t1",
            kind: .agentOutcome(.completed),
            title: "Agent run completed",
            detail: "star - Grok - done work",
            workspaceName: "star",
            createdAt: Date(),
            route: .agentThread(threadID: threadB, workspaceID: workspace),
            source: .agentThread(threadID: threadB)
        )
        guard let output = PetLiveActivityCopy.make(.init(
            active: [], needsYou: [needs], completed: [done]
        )) else { return XCTFail("expected attention-only surface") }
        XCTAssertEqual(output.activeThreadCount, 0)
        XCTAssertEqual(output.title, "1 item needs attention")
        XCTAssertEqual(output.statusLine, "Approve: Run command")
        XCTAssertTrue(output.preview.contains("star - Grok") || output.preview.contains("+1 more"))
        XCTAssertEqual(output.phase, .failed)
    }

    func testCompletedOnlyReadyCard() {
        let done = PetAttentionItem(
            id: "t1",
            kind: .agentOutcome(.completed),
            title: "Agent run completed",
            detail: "star - Grok - finished",
            workspaceName: "star",
            createdAt: Date(),
            route: .agentThread(threadID: threadA, workspaceID: workspace),
            source: .agentThread(threadID: threadA)
        )
        guard let output = PetLiveActivityCopy.make(.init(
            active: [], needsYou: [], completed: [done]
        )) else { return XCTFail("expected completed-only surface") }
        XCTAssertEqual(output.title, "1 item ready")
        XCTAssertEqual(output.statusLine, "Agent run completed")
        XCTAssertEqual(output.phase, .completed)
        XCTAssertEqual(output.threadId, threadA.value.uuidString)
    }
}
