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

    func test_selectThread_readWriteFailureKeepsUnreadAndPublishesNoReadEvent() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-ReadFailure-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "READ-FAILURE", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        var thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "unread",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        thread.hasUnread = true
        try ctx.threadRepo.upsert(thread)
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Agent App"
        )
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface)
        surface.viewModel.reloadThreads()
        var readEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.thread.read" else { return }
            readEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }
        try ctx.db.execute("""
            CREATE TRIGGER fail_agent_thread_read
            BEFORE UPDATE OF has_unread ON agent_threads
            WHEN OLD.id = '\(thread.id.value.uuidString)' AND NEW.has_unread = 0
            BEGIN
                SELECT RAISE(FAIL, 'forced read failure');
            END;
            """)

        surface.viewModel.selectThread(thread.id)

        XCTAssertTrue(try XCTUnwrap(ctx.threadRepo.get(id: thread.id)).hasUnread,
            "a failed canonical read write must leave persisted attention unread")
        XCTAssertTrue(surface.viewModel.threads.first(where: { $0.id == thread.id })?.hasUnread == true,
            "the local rail must clear only after the canonical read mutation succeeds")
        XCTAssertTrue(readEvents.isEmpty,
            "a failed read write must never publish agent.thread.read")
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

    // MARK: Canonical exact-thread route

    func test_openAgentThread_reusesAgentSurface_andBindsExactThreadWithoutImplicitRead() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-OpenExisting-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let controller = MainWindowController(context: ctx, router: router)
        router.windowController = controller
        defer { controller.window.orderOut(nil) }

        let targetWorkspace = try router.createWorkspace(name: "TARGET", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: targetWorkspace.id) }
        let previous = try router.createAgentThread(
            workspace: targetWorkspace.id,
            title: "previous",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        var target = try router.createAgentThread(
            workspace: targetWorkspace.id,
            title: "target",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        target.hasUnread = true
        try ctx.threadRepo.upsert(target)

        let existing = try router.createSurface(
            workspace: targetWorkspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Agent App"
        )
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(existing.id) as? AgentAppSurface)
        surface.viewModel.selectThread(previous.id)

        let otherWorkspace = try router.createWorkspace(name: "OTHER", cwd: NSTemporaryDirectory())
        XCTAssertEqual(ctx.state.window.selectedWorkspaceID, otherWorkspace.id)
        var readEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.thread.read",
                  case .object(let payload) = event.payload,
                  payload["thread_id"]?.stringValue == target.id.value.uuidString else { return }
            readEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        let routed = try router.openAgentThread(thread: target.id, markRead: false)

        XCTAssertTrue(controller.window.isVisible,
            "opening an exact thread must activate and show the RemoteCode window")
        XCTAssertEqual(ctx.state.window.selectedWorkspaceID, targetWorkspace.id,
            "the thread repository workspace is authoritative for the destination")
        XCTAssertEqual(routed.id, existing.id,
            "an existing Agent App surface must be reused instead of adding duplicate tabs")
        XCTAssertEqual(surface.viewModel.selectedThreadId, target.id,
            "the addressed surface must bind the exact requested thread")
        XCTAssertTrue(try XCTUnwrap(ctx.threadRepo.get(id: target.id)).hasUnread,
            "navigation without markRead must preserve unread state")
        XCTAssertTrue(readEvents.isEmpty,
            "a deferred Pet route must not tell mirrors the thread was read before canonical acknowledgement")
    }

    func test_openAgentThread_createsAgentSurface_andMarksReadOnlyAfterBinding() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-OpenCreate-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let controller = MainWindowController(context: ctx, router: router)
        router.windowController = controller
        router.destinationWindowIsKeyForTests = { $0 === controller.window }
        defer { controller.window.orderOut(nil) }
        let workspace = try router.createWorkspace(name: "CREATE", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        var target = try router.createAgentThread(
            workspace: workspace.id,
            title: "unread",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        target.hasUnread = true
        try ctx.threadRepo.upsert(target)
        XCTAssertTrue(agentSurfaces(in: workspace.id).isEmpty)
        var readEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.thread.read",
                  case .object(let payload) = event.payload,
                  payload["thread_id"]?.stringValue == target.id.value.uuidString else { return }
            readEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        let routed = try router.openAgentThread(thread: target.id, markRead: true)
        let created = try XCTUnwrap(SurfaceRegistry.shared.surface(routed.id) as? AgentAppSurface)

        XCTAssertEqual(agentSurfaces(in: workspace.id).count, 1,
            "the canonical route must create one Agent App surface when none exists")
        XCTAssertEqual(created.viewModel.selectedThreadId, target.id,
            "the new surface must bind successfully before the route can complete")
        XCTAssertFalse(try XCTUnwrap(ctx.threadRepo.get(id: target.id)).hasUnread,
            "a successful route requested with markRead must clear unread state")
        XCTAssertEqual(readEvents.count, 1,
            "verified routing must broadcast exactly one canonical read event")
    }

    func test_openAgentThread_missingDestinationWindowPreservesUnread() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-OpenMissingWindow-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "MISSING-WINDOW", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        var target = try router.createAgentThread(
            workspace: workspace.id,
            title: "unread",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        target.hasUnread = true
        try ctx.threadRepo.upsert(target)

        XCTAssertThrowsError(try router.openAgentThread(thread: target.id, markRead: true)) { error in
            XCTAssertEqual(error as? LayoutError, .surfaceNotFound)
        }
        XCTAssertTrue(try XCTUnwrap(ctx.threadRepo.get(id: target.id)).hasUnread,
            "a route without a concrete destination window must retain unread attention")
    }

    func test_openAgentThread_nonKeyDestinationWindowPreservesUnread() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-OpenNonKeyWindow-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let controller = MainWindowController(context: ctx, router: router)
        router.windowController = controller
        router.destinationWindowIsKeyForTests = { _ in false }
        defer { controller.window.orderOut(nil) }
        let workspace = try router.createWorkspace(name: "NON-KEY-WINDOW", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        var target = try router.createAgentThread(
            workspace: workspace.id,
            title: "unread",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        target.hasUnread = true
        try ctx.threadRepo.upsert(target)

        XCTAssertThrowsError(try router.openAgentThread(thread: target.id, markRead: true)) { error in
            XCTAssertEqual(error as? LayoutError, .surfaceNotFound)
        }
        XCTAssertTrue(try XCTUnwrap(ctx.threadRepo.get(id: target.id)).hasUnread,
            "a route whose destination did not become key must retain unread attention")
    }

    func test_openAgentThread_activatesOwningDetachedWindowBeforeMarkingRead() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-OpenDetached-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let controller = MainWindowController(context: ctx, router: router)
        router.windowController = controller
        defer { controller.window.orderOut(nil) }

        let targetWorkspace = try router.createWorkspace(name: "DETACHED", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: targetWorkspace.id) }
        var target = try router.createAgentThread(
            workspace: targetWorkspace.id,
            title: "target",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let descriptor = try router.createSurface(
            workspace: targetWorkspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Agent App"
        )
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface)
        let otherWorkspace = try router.createWorkspace(name: "MAIN", cwd: NSTemporaryDirectory())
        controller.openWorkspaceInNewWindow(targetWorkspace.id)
        let detachedWindow = try XCTUnwrap(controller.workspaceWindow(for: targetWorkspace.id))
        router.destinationWindowIsKeyForTests = { $0 === detachedWindow }
        defer { detachedWindow.orderOut(nil) }
        target.hasUnread = true
        try ctx.threadRepo.upsert(target)

        _ = try router.openAgentThread(thread: target.id, markRead: true)

        XCTAssertTrue(detachedWindow.isVisible)
        XCTAssertTrue(
            detachedWindow.isKeyWindow || !NSApp.isActive,
            "The owning window must become key whenever the XCTest host permits app activation."
        )
        XCTAssertTrue(surface.view.window === detachedWindow)
        XCTAssertEqual(ctx.state.window.selectedWorkspaceID, otherWorkspace.id)
        XCTAssertFalse(try XCTUnwrap(ctx.threadRepo.get(id: target.id)).hasUnread)
    }

    func test_openAgentThread_failedDestination_preservesUnread() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-OpenFailure-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let target = AgentThread(
            workspaceId: nil,
            title: "orphan",
            provider: .codex,
            model: "fake-model",
            status: .completed,
            hasUnread: true
        )
        try ctx.threadRepo.upsert(target)

        XCTAssertThrowsError(try router.openAgentThread(thread: target.id, markRead: true)) { error in
            XCTAssertEqual(error as? LayoutError, .workspaceNotFound)
        }
        XCTAssertTrue(try XCTUnwrap(ctx.threadRepo.get(id: target.id)).hasUnread,
            "route failure must never clear an item the user could not open")
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

    // MARK: Plan-note realtime mirror wiring

    func test_localPlanNotesSave_persistsThenPublishesOneMirrorEvent() throws {
        let dir = NSTemporaryDirectory() + "RC2PlanNotes-Local-" + UUID().uuidString
        let (_, router) = try makeRouter(dir)
        let ws = try router.createWorkspace(name: "PLAN-LOCAL", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: ws.id) }
        let thread = try router.createAgentThread(workspace: ws.id, title: "plan", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)
        let desc = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "Agent App")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(desc.id) as? AgentAppSurface)
        surface.viewModel.selectThread(thread.id)
        let before = EventBus.shared.currentSeq

        surface.viewModel.planNotes = "typed on Mac"
        surface.viewModel.savePlanNotes()

        XCTAssertEqual(try router.agentPlanNotes(thread: thread.id), "typed on Mac",
                       "the host must persist local notes before advertising them to mirrors")
        let updates = EventBus.shared.recentEvents(since: before, maxBytes: nil).events.filter {
            $0.kind == "agent.plan.notes.updated"
        }
        XCTAssertEqual(updates.count, 1,
                       "one local TextEditor save must produce exactly one realtime mirror update")
        XCTAssertEqual(updates.first?.payload.objectValue?["thread_id"]?.stringValue, thread.id.value.uuidString)
        XCTAssertEqual(updates.first?.payload.objectValue?["notes"]?.stringValue, "typed on Mac")
    }

    func test_remotePlanNotesUpdate_doesNotEchoThroughLocalSaveObserver() throws {
        let dir = NSTemporaryDirectory() + "RC2PlanNotes-Remote-" + UUID().uuidString
        let (_, router) = try makeRouter(dir)
        let ws = try router.createWorkspace(name: "PLAN-REMOTE", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: ws.id) }
        let thread = try router.createAgentThread(workspace: ws.id, title: "plan", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)
        let desc = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "Agent App")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(desc.id) as? AgentAppSurface)
        surface.viewModel.selectThread(thread.id)
        let before = EventBus.shared.currentSeq

        try router.saveAgentPlanNotes(thread: thread.id, notes: "received from iOS")
        surface.viewModel.savePlanNotes() // Simulates TextEditor's onChange callback.

        let updates = EventBus.shared.recentEvents(since: before, maxBytes: nil).events.filter {
            $0.kind == "agent.plan.notes.updated"
        }
        XCTAssertEqual(updates.count, 1,
                       "applying an iOS note must publish once at the RPC source and never echo through TextEditor")
    }

    func test_remotePlanNotesPersistenceFailurePublishesNoSuccessEvent() throws {
        let dir = NSTemporaryDirectory() + "RC2PlanNotes-Failure-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let ws = try router.createWorkspace(name: "PLAN-FAIL", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: ws.id) }
        let thread = try router.createAgentThread(workspace: ws.id, title: "plan", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)
        try ctx.db.execute("""
            CREATE TRIGGER fail_plan_notes_insert
            BEFORE INSERT ON settings
            WHEN NEW.key LIKE 'agent.plan_notes.%'
            BEGIN
                SELECT RAISE(FAIL, 'injected plan-notes write failure');
            END;
            """)
        let before = EventBus.shared.currentSeq

        XCTAssertThrowsError(try router.saveAgentPlanNotes(thread: thread.id, notes: "not durable"))

        let updates = EventBus.shared.recentEvents(since: before, maxBytes: nil).events.filter {
            $0.kind == "agent.plan.notes.updated"
        }
        XCTAssertTrue(updates.isEmpty,
                      "a failed write must not advertise notes that the host cannot read back after restart")
    }

    // MARK: Bug C — RPC/iOS reply must not yank sibling Agent App tabs

    /// Regression for: replying in one Agent App thread (via agent.message.send /
    /// iOS / CLI) force-selected that thread on every open Agent App tab, so a
    /// response in thread A appeared to affect thread B's tab as well.
    func test_sendAgentMessage_doesNotYankSiblingAgentTabSelection() async throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-SendYank-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)

        ctx.coordinator.replaceProvider(
            .codex,
            runner: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: "ok"))
        )

        let ws = try router.createWorkspace(name: "SEND-YANK", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: ws.id) }

        let threadA = try router.createAgentThread(
            workspace: ws.id,
            title: "Thread A",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let threadB = try router.createAgentThread(
            workspace: ws.id,
            title: "Thread B",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )

        // S1 and S3 view A; S2 views B. A remote reply to A must refresh S1/S3
        // but leave S2 on B.
        let d1 = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "S1")
        let d2 = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "S2")
        let d3 = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "S3")
        let s1 = try XCTUnwrap(SurfaceRegistry.shared.surface(d1.id) as? AgentAppSurface)
        let s2 = try XCTUnwrap(SurfaceRegistry.shared.surface(d2.id) as? AgentAppSurface)
        let s3 = try XCTUnwrap(SurfaceRegistry.shared.surface(d3.id) as? AgentAppSurface)
        s1.viewModel.selectThread(threadA.id)
        s2.viewModel.selectThread(threadB.id)
        s3.viewModel.selectThread(threadA.id)

        XCTAssertEqual(s1.viewModel.selectedThreadId, threadA.id)
        XCTAssertEqual(s2.viewModel.selectedThreadId, threadB.id)
        XCTAssertEqual(s3.viewModel.selectedThreadId, threadA.id)

        let result = try await router.sendAgentMessage(
            thread: threadA.id,
            text: "reply only on A",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        XCTAssertEqual(result.status, .started,
                       "the remote send must start a provider run on thread A")

        XCTAssertEqual(s1.viewModel.selectedThreadId, threadA.id,
                       "S1 was already on A and must stay on A")
        XCTAssertEqual(s2.viewModel.selectedThreadId, threadB.id,
                       "S2 is bound to B — an RPC reply on A must not yank it onto A (Bug C / residual Bug B)")
        XCTAssertEqual(s3.viewModel.selectedThreadId, threadA.id,
                       "S3 was already on A and must stay on A")

        // Durable messages for B must not include A's remote prompt; the send
        // path must target only the requested thread id.
        let messagesOnB = try router.listAgentMessages(thread: threadB.id, limit: 50)
        XCTAssertFalse(
            messagesOnB.contains(where: { $0.content.contains("reply only on A") }),
            "thread B's durable transcript must not receive the user message sent to thread A"
        )
        let messagesOnA = try router.listAgentMessages(thread: threadA.id, limit: 50)
        XCTAssertTrue(
            messagesOnA.contains(where: { $0.content.contains("reply only on A") }),
            "thread A must own the remote user message"
        )
    }
}
