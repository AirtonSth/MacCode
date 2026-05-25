import XCTest
@testable import AppShell
@testable import CoreModel
@testable import Surfaces
import Persistence

@MainActor
final class PersistenceRestoreTests: XCTestCase {
    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    /// Workspaces and tabs must survive a process restart even without a
    /// clean quit — i.e. the snapshot is written on mutation, not only on
    /// applicationWillTerminate.
    func test_workspacesAndTabs_persistAcrossRestart() throws {
        let dir = NSTemporaryDirectory() + "RC2Persist-" + UUID().uuidString

        // ── Session 1: create a workspace + two surfaces, flush snapshot.
        do {
            let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let ws = try router.createWorkspace(name: "PERSISTME", cwd: NSTemporaryDirectory())
            _ = try router.createSurface(workspace: ws.id, type: .terminal, paneID: nil, title: "t")
            _ = try router.createSurface(workspace: ws.id, type: .browser, paneID: nil, title: "b")
            ctx.saveSnapshot() // immediate flush (debounced timer would also fire)
            defer { closeAndUnregisterAllSurfaces() }
        }

        // ── Session 2: fresh AppContext on the SAME app-support dir.
        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        let names = ctx2.state.workspaces.values.map { $0.name }
        XCTAssertTrue(names.contains("PERSISTME"),
                      "workspace must persist across restart, got \(names)")
        let restored = ctx2.state.workspaces.values.first { $0.name == "PERSISTME" }
        let restoredWS = try XCTUnwrap(restored)
        guard case .pane(let pane) = restoredWS.layout else {
            return XCTFail("expected the restored workspace to keep its pane")
        }
        // Default terminal (1) + the two added tabs (terminal, browser) = 3.
        XCTAssertEqual(pane.surfaces.count, 3, "all tabs must persist")
        XCTAssertEqual(Set(pane.surfaces.map(\.type)), [.terminal, .browser])
        // And the window selection points at the restored workspace.
        XCTAssertEqual(ctx2.state.window.selectedWorkspaceID, restoredWS.id)
    }

    func test_applyMutation_schedulesSnapshotSave() throws {
        let dir = NSTemporaryDirectory() + "RC2Persist-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        try ctx.apply(.createWorkspace(name: "A", cwd: "/tmp", initial: nil))
        // Force the debounced write immediately and confirm it lands.
        ctx.saveSnapshot()
        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        XCTAssertTrue(ctx2.state.workspaces.values.contains { $0.name == "A" })
    }

    func test_saveAgentPlanWritesExactMarkdownInsideWorkspace() throws {
        let support = NSTemporaryDirectory() + "RC2PlanSave-" + UUID().uuidString
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2PlanWorkspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let ctx = try AppContext(channel: .debug, appSupportOverride: support)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let ws = try router.createWorkspace(name: "PLAN", cwd: workspace.path)
        let thread = try router.createAgentThread(workspace: ws.id, title: "plan", provider: .codex, model: "gpt-5.5", permissionMode: .supervised, reasoningEffort: .medium, serviceTier: .auto, modelSelection: nil)
        let markdown = "\n# Keep exact markdown\n\n1. Inspect\n"
        try ctx.proposedPlanRepo.upsert(threadId: thread.id, plan: AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: markdown))

        let saved = try router.saveAgentPlan(thread: thread.id, planId: "plan-1", planMarkdown: nil, relativePath: nil)

        XCTAssertEqual(saved.relativePath, ".remotecode/plans/keep-exact-markdown.md")
        XCTAssertEqual(try String(contentsOfFile: saved.path), markdown,
                       "mobile host-save must write the exact proposed-plan markdown, not a trimmed or rendered copy")
        XCTAssertThrowsError(try router.saveAgentPlan(thread: thread.id, planId: "plan-1", planMarkdown: markdown, relativePath: "../plan.md"),
                             "mobile clients must not be able to save plan markdown outside the workspace")
    }

    func test_browserLastURL_persistsAcrossRestart() throws {
        let dir = NSTemporaryDirectory() + "RC2Persist-" + UUID().uuidString
        let target = "https://example.com/docs?tab=api"

        do {
            let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let ws = try router.createWorkspace(name: "WEB", cwd: NSTemporaryDirectory())
            let browser = try router.createSurface(workspace: ws.id, type: .browser, paneID: nil, title: "browser")
            let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(browser.id) as? BrowserSurface)

            surface.publishNavigationChange(url: try XCTUnwrap(URL(string: target)), title: "API Docs")
            ctx.saveSnapshot()
        }

        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        let restored = try XCTUnwrap(ctx2.state.workspaces.values.first { $0.name == "WEB" })
        guard case .pane(let pane) = restored.layout else {
            return XCTFail("expected browser workspace to restore as pane")
        }
        let browser = try XCTUnwrap(pane.surfaces.first { $0.type == .browser })
        XCTAssertEqual(browser.metadata["url"], target,
                       "browser tabs must reopen on the last URL after RemoteCode restarts")
        XCTAssertEqual(browser.title, "API Docs",
                       "browser tab title must persist with the last visited page")
    }

    func test_providerCallbackState_persistsAndMarksOpenCallbacksStaleOnRestart() throws {
        let dir = NSTemporaryDirectory() + "RC2Callbacks-" + UUID().uuidString
        let threadId: AgentThreadID
        do {
            let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
            let thread = AgentThread(title: "callback", provider: .codex, model: "gpt-5.5")
            threadId = thread.id
            try ctx.threadRepo.upsert(thread)
            let run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-5.5")
            try ctx.runRepo.upsert(run)

            ctx.coordinator.onAssistantEvent?(.requestOpened(AssistantPendingRequest(
                id: "approval-1",
                turnId: "turn-1",
                kind: .commandExecution,
                title: "Run command",
                detail: "swift test",
                createdAtMs: 1_000
            )), thread.id, run.id)
            ctx.coordinator.onAssistantEvent?(.userInputRequested(AssistantUserInputRequest(
                id: "question-1",
                turnId: "turn-1",
                prompt: "Continue?",
                options: ["Plan", "Run"],
                createdAtMs: 2_000
            )), thread.id, run.id)
            ctx.coordinator.onAssistantEvent?(.requestResolved(requestId: "approval-1", state: .approved), thread.id, run.id)
        }

        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        let router2 = AppCommandRouter(context: ctx2)
        let approval = try XCTUnwrap(try ctx2.providerPendingCallbackRepo.get(threadId: threadId, requestId: "approval-1", kind: .approval))
        let question = try XCTUnwrap(try ctx2.providerPendingCallbackRepo.get(threadId: threadId, requestId: "question-1", kind: .userInput))
        let visible = try router2.listAgentPendingCallbacks(thread: threadId)

        XCTAssertEqual(approval.state, .approved,
                       "resolved provider approvals must not be resurrected when the app restarts")
        XCTAssertEqual(question.state, .stale,
                       "unresolved provider questions must become explicitly stale after restart instead of trapping the Agent App in dead callback UI")
        XCTAssertTrue(question.staleReason?.contains("Provider callback state does not survive app restarts") == true)
        XCTAssertEqual(visible.requests.map(\.id), [],
                       "host callback reload must hide resolved approvals after restart")
        XCTAssertEqual(visible.userInputs.first?.id, "question-1",
                       "host callback reload must expose stale unanswered provider questions for macOS/iOS recovery")
        XCTAssertEqual(visible.userInputs.first?.state, .stale)
    }

    func test_failedProviderCallbackResponseMarksStoredCallbackStale() throws {
        let dir = NSTemporaryDirectory() + "RC2CallbackFailure-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        let thread = AgentThread(title: "callback", provider: .codex, model: "gpt-5.5")
        try ctx.threadRepo.upsert(thread)
        try ctx.providerPendingCallbackRepo.record(threadId: thread.id, request: AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run command",
            detail: "swift test",
            createdAtMs: 1
        ))
        try ctx.providerPendingCallbackRepo.record(threadId: thread.id, userInput: AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Continue?",
            options: ["Plan", "Run"],
            createdAtMs: 2
        ))

        XCTAssertThrowsError(try router.respondAgentRequest(thread: thread.id, requestId: "approval-1", response: .approve))
        XCTAssertThrowsError(try router.respondAgentUserInput(thread: thread.id, requestId: "question-1", text: "Run"))

        let approval = try XCTUnwrap(try ctx.providerPendingCallbackRepo.get(threadId: thread.id, requestId: "approval-1", kind: .approval))
        let question = try XCTUnwrap(try ctx.providerPendingCallbackRepo.get(threadId: thread.id, requestId: "question-1", kind: .userInput))
        let visible = try router.listAgentPendingCallbacks(thread: thread.id)
        XCTAssertEqual(approval.state, .stale,
                       "a failed provider approval response must not remain pending forever after the provider session is gone")
        XCTAssertEqual(question.state, .stale,
                       "a failed provider question response must not remain pending forever after the provider session is gone")
        XCTAssertTrue(visible.requests.first?.detail?.contains("Provider approval response failed") == true)
        XCTAssertEqual(visible.userInputs.first?.state, .stale)
    }
}
