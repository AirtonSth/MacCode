import XCTest
@testable import AppShell
@testable import AgentRuntime
@testable import CoreModel
@testable import SocketServer
@testable import Surfaces
import Persistence

/// Router-level regression guards for the agent-app selection bugs:
///  - Bug A: a newly created agent tab does not adopt the workspace's first thread.
///  - Bug B: selection no longer fans out across every agent surface — neither
///    mark-read nor an untargeted create/select force-switches an open tab
///    (this is what made an iOS action disturb the macOS UI).
///  - Per-surface binding survives an app restart (each tab reopens its thread).
@MainActor
final class AgentSurfaceThreadBindingRouterTests: XCTestCase {

    private func closeAndUnregisterAgentSurfaces(workspace: WorkspaceID) {
        for s in SurfaceRegistry.shared.all() {
            if let a = s as? AgentAppSurface, a.viewModel.workspaceID == workspace {
                a.close()
                SurfaceRegistry.shared.unregister(a.descriptor.id)
            }
        }
    }

    private func agentSurfaces(in workspace: WorkspaceID) -> [AgentAppSurface] {
        SurfaceRegistry.shared.all().compactMap { $0 as? AgentAppSurface }
            .filter { $0.viewModel.workspaceID == workspace }
    }

    private func makeRouter(_ dir: String) throws -> (AppContext, AppCommandRouter) {
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    // MARK: Bug A — new tab does not adopt the workspace's existing thread

    func test_newAgentTab_doesNotAdoptExistingWorkspaceThread() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-A-" + UUID().uuidString
        let (_, router) = try makeRouter(dir)
        let ws = try router.createWorkspace(name: "BUGA", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: ws.id) }

        // A pre-existing thread in the workspace (e.g. from a prior tab).
        _ = try router.createAgentThread(workspace: ws.id, title: "old", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)

        let desc = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "Agent App")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(desc.id) as? AgentAppSurface)

        XCTAssertNil(surface.viewModel.selectedThreadId,
            "A new agent tab must open thread-free, not clone the workspace's existing thread (Bug A).")
    }

    // MARK: Bug B vector 1 — mark-read must not select

    func test_markRead_doesNotForceSelectOpenAgentSurface() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-B1-" + UUID().uuidString
        let (_, router) = try makeRouter(dir)
        let ws = try router.createWorkspace(name: "BUGB1", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: ws.id) }

        let a = try router.createAgentThread(workspace: ws.id, title: "A", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)
        let b = try router.createAgentThread(workspace: ws.id, title: "B", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)

        let desc = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "Agent App")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(desc.id) as? AgentAppSurface)
        surface.viewModel.selectThread(a.id)
        XCTAssertEqual(surface.viewModel.selectedThreadId, a.id)

        // Another client opening thread B auto-marks it read on the host.
        try router.markAgentThreadRead(thread: b.id)

        XCTAssertEqual(surface.viewModel.selectedThreadId, a.id,
            "mark-read must not yank an open macOS agent tab to another thread (Bug B).")
    }

    // MARK: Bug B vector 2 — untargeted create must not yank

    func test_createThreadWithoutSurfaceID_doesNotYankOpenSurface() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-B2-" + UUID().uuidString
        let (_, router) = try makeRouter(dir)
        let ws = try router.createWorkspace(name: "BUGB2", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: ws.id) }

        let a = try router.createAgentThread(workspace: ws.id, title: "A", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)
        let desc = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "Agent App")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(desc.id) as? AgentAppSurface)
        surface.viewModel.selectThread(a.id)

        // A different client creates a thread (no surface targeted).
        _ = try router.createAgentThread(workspace: ws.id, title: "remote", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium, surfaceID: nil)

        XCTAssertEqual(surface.viewModel.selectedThreadId, a.id,
            "A thread created by another client must not switch an open tab's selection (Bug B).")
    }

    // MARK: selectAgentThread targets exactly one surface when given a surfaceID

    func test_selectAgentThread_targetsOnlyAddressedSurface() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-Sel-" + UUID().uuidString
        let (_, router) = try makeRouter(dir)
        let ws = try router.createWorkspace(name: "SEL", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: ws.id) }

        let a = try router.createAgentThread(workspace: ws.id, title: "A", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)
        let b = try router.createAgentThread(workspace: ws.id, title: "B", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)

        let d1 = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "S1")
        let d2 = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "S2")
        let s1 = try XCTUnwrap(SurfaceRegistry.shared.surface(d1.id) as? AgentAppSurface)
        let s2 = try XCTUnwrap(SurfaceRegistry.shared.surface(d2.id) as? AgentAppSurface)
        s1.viewModel.selectThread(a.id)
        s2.viewModel.selectThread(b.id)

        // Target only S1.
        try router.selectAgentThread(thread: b.id, surfaceID: d1.id)
        XCTAssertEqual(s1.viewModel.selectedThreadId, b.id, "the addressed surface switches")
        XCTAssertEqual(s2.viewModel.selectedThreadId, b.id, "S2 was already on B and is untouched")

        // Untargeted select reloads only — neither surface changes.
        try router.selectAgentThread(thread: a.id, surfaceID: nil)
        XCTAssertEqual(s1.viewModel.selectedThreadId, b.id,
            "an untargeted select must not move any surface's selection")
        XCTAssertEqual(s2.viewModel.selectedThreadId, b.id)
    }

    // MARK: Per-surface binding persists across restart

    func test_perSurfaceThreadBinding_persistsAcrossRestart() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-Restore-" + UUID().uuidString
        var threadId: AgentThreadID!
        var workspaceId: WorkspaceID!

        do {
            let (ctx, router) = try makeRouter(dir)
            let ws = try router.createWorkspace(name: "RESTORE", cwd: NSTemporaryDirectory())
            workspaceId = ws.id
            let t = try router.createAgentThread(workspace: ws.id, title: "bound", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)
            threadId = t.id
            let desc = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "Agent App")
            let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(desc.id) as? AgentAppSurface)
            surface.viewModel.selectThread(t.id) // binds + persists via onSelectedThreadChanged
            ctx.saveSnapshot()
            closeAndUnregisterAgentSurfaces(workspace: ws.id)
        }

        // Fresh process.
        let (_, router2) = try makeRouter(dir)
        defer { closeAndUnregisterAgentSurfaces(workspace: workspaceId) }
        router2.reinstantiateRestoredSurfaces()

        let restored = agentSurfaces(in: workspaceId)
        XCTAssertEqual(restored.count, 1, "the agent tab restores")
        XCTAssertEqual(restored.first?.viewModel.selectedThreadId, threadId,
            "each agent tab must reopen its OWN bound thread after restart, not threads.first.")
    }
}
