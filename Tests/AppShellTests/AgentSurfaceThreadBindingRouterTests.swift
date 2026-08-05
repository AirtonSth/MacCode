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

    private func fillWorkspaceToThreadCap(
        _ workspaceID: WorkspaceID,
        context: AppContext
    ) throws -> Set<AgentThreadID> {
        var ids: Set<AgentThreadID> = []
        for index in 0..<AgentThreadRepository.maxThreadsPerWorkspace {
            var thread = AgentThread(
                workspaceId: workspaceID,
                title: "existing \(index)",
                provider: .codex,
                model: "fake-model"
            )
            thread.status = .completed
            try context.threadRepo.upsert(thread)
            ids.insert(thread.id)
        }
        return ids
    }

    private func installThreadCapDeleteAbortTrigger(
        _ context: AppContext,
        named name: String
    ) throws {
        try context.db.execute("""
            CREATE TRIGGER \(name)
            BEFORE DELETE ON agent_threads
            BEGIN
                SELECT RAISE(ABORT, 'forced cap victim delete failure');
            END;
            """)
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

    /// PERF-MAC_AGENT-013: scheduled/RPC creation enforces the cap before it
    /// publishes `agent.thread.created`. Every open surface in the workspace
    /// must evict the pre-pruned victim from its local caches when the real
    /// EventBus notification arrives, even if the first rail list fails.
    func test_routerAndUICreateAtCap_publishVictimsBeforeCreatedAndEvictFailedReloadSurfaces() async throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-Cap-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "CAP", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }

        let firstSurface = try XCTUnwrap(agentSurfaces(in: workspace.id).first)
        let secondDescriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Second Agent App"
        )
        let secondSurface = try XCTUnwrap(
            SurfaceRegistry.shared.surface(secondDescriptor.id) as? AgentAppSurface
        )

        let oldest = Date(timeIntervalSince1970: 1_700_000_000)
        var victim = AgentThread(
            workspaceId: workspace.id,
            title: "oldest completed victim",
            provider: .codex,
            model: "fake-model"
        )
        victim.status = .completed
        victim.updatedAt = oldest
        try ctx.threadRepo.upsert(victim)
        var survivors: [AgentThread] = []
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 1) {
            var thread = AgentThread(
                workspaceId: workspace.id,
                title: "existing \(index)",
                provider: .codex,
                model: "fake-model"
            )
            thread.status = .completed
            thread.updatedAt = oldest.addingTimeInterval(TimeInterval(index + 1))
            try ctx.threadRepo.upsert(thread)
            survivors.append(thread)
        }
        XCTAssertEqual(
            try ctx.threadRepo.count(workspaceId: workspace.id),
            AgentThreadRepository.maxThreadsPerWorkspace,
            "precondition: the quiet router create starts at the production cap"
        )
        firstSurface.viewModel.reloadThreads()
        secondSurface.viewModel.reloadThreads()

        let secondSelection = survivors[1].id
        firstSurface.viewModel.selectThread(victim.id)
        firstSurface.viewModel.prompt = "first surface victim draft"
        firstSurface.viewModel.seedAdditionalThreadCachesForTesting(victim.id)
        firstSurface.viewModel.seedRunThreadProjectionForTesting(victim.id)
        secondSurface.viewModel.selectThread(victim.id)
        secondSurface.viewModel.prompt = "second surface victim draft"
        secondSurface.viewModel.seedAdditionalThreadCachesForTesting(victim.id)
        secondSurface.viewModel.selectThread(secondSelection)
        ctx.coordinator.seedAutoContinuationStateForTesting(victim.id)

        XCTAssertTrue(firstSurface.viewModel.threadCacheResidueForTesting.contains(victim.id),
                      "precondition: first surface caches the future victim")
        XCTAssertTrue(secondSurface.viewModel.threadCacheResidueForTesting.contains(victim.id),
                      "precondition: second surface caches the future victim")
        XCTAssertTrue(ctx.coordinator.autoContinuationThreadIdsForTesting.contains(victim.id),
                      "precondition: the shared coordinator caches the future victim")
        XCTAssertEqual(firstSurface.viewModel.selectedThreadId, victim.id)
        XCTAssertEqual(secondSurface.viewModel.selectedThreadId, secondSelection)

        var createdEvents: [EventBus.Event] = []
        var deletedEvents: [EventBus.Event] = []
        let eventSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "agent.thread.created",
               event.payload.objectValue?["workspace_id"]?.stringValue == workspace.id.value.uuidString {
                createdEvents.append(event)
            } else if event.kind == "agent.thread.deleted" {
                deletedEvents.append(event)
            }
        }
        defer { EventBus.shared.unsubscribe(eventSubscription) }
        firstSurface.viewModel.setReloadThreadListForTesting {
            throw NSError(domain: "AgentSurfaceThreadBindingRouterTests.reload", code: 1)
        }
        secondSurface.viewModel.setReloadThreadListForTesting {
            throw NSError(domain: "AgentSurfaceThreadBindingRouterTests.reload", code: 2)
        }

        let created = try router.createAgentThread(
            workspace: workspace.id,
            title: "scheduled quiet create",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            routingConfiguration: nil,
            quiet: true
        )

        for _ in 0..<100 where firstSurface.viewModel.threadCacheResidueForTesting.contains(victim.id)
            || secondSurface.viewModel.threadCacheResidueForTesting.contains(victim.id)
            || !firstSurface.viewModel.statusMessage.contains("Could not reload threads")
            || !secondSurface.viewModel.statusMessage.contains("Could not reload threads") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        firstSurface.viewModel.setReloadThreadListForTesting(nil)
        secondSurface.viewModel.setReloadThreadListForTesting(nil)

        XCTAssertEqual(createdEvents.count, 1,
                       "quiet router creation must publish one real-time thread-created event")
        XCTAssertEqual(deletedEvents.count, 1,
                       "cap pruning must publish the authoritative victim before the created event")
        XCTAssertEqual(deletedEvents.first?.payload.objectValue?["thread_id"]?.stringValue,
                       victim.id.value.uuidString)
        XCTAssertLessThan(try XCTUnwrap(deletedEvents.first?.seq),
                          try XCTUnwrap(createdEvents.first?.seq),
                          "subscribers must receive the victim before the created event triggers a fallible reload")
        XCTAssertEqual(try ctx.threadRepo.count(workspaceId: workspace.id),
                       AgentThreadRepository.maxThreadsPerWorkspace)
        XCTAssertNil(try ctx.threadRepo.get(id: victim.id),
                     "the router must pre-prune the oldest completed victim at 101 rows")
        XCTAssertNotNil(try ctx.threadRepo.get(id: created.id))
        XCTAssertFalse(firstSurface.viewModel.threadCacheResidueForTesting.contains(victim.id),
                       "the first EventBus-subscribed surface must evict the pre-pruned victim")
        XCTAssertFalse(secondSurface.viewModel.threadCacheResidueForTesting.contains(victim.id),
                       "the second EventBus-subscribed surface must evict the pre-pruned victim")
        XCTAssertFalse(ctx.coordinator.autoContinuationThreadIdsForTesting.contains(victim.id),
                       "the shared coordinator must forget the pre-pruned victim before the failed rail reload")
        XCTAssertFalse(firstSurface.viewModel.threads.contains(where: { $0.id == victim.id }),
                       "the authoritative delete event must remove the stale rail row before list failure")
        XCTAssertNil(firstSurface.viewModel.selectedThreadId,
                     "a selected externally pruned victim must recover even when list fails")
        XCTAssertEqual(firstSurface.viewModel.prompt, "first surface victim draft",
                       "external-prune recovery must preserve the selected unsent draft")
        XCTAssertEqual(secondSurface.viewModel.selectedThreadId, secondSelection,
                       "quiet creation must not yank the second open Agent App tab")
        XCTAssertTrue(firstSurface.viewModel.statusMessage.contains("Could not reload threads"))
        XCTAssertTrue(secondSurface.viewModel.statusMessage.contains("Could not reload threads"))

        // Repeat through the local UI producer. Its onThreadLifecycle callback is
        // wired to the same EventBus, so another open surface must receive the
        // victim before its injected reload failure.
        let uiVictim = survivors[0]
        secondSurface.viewModel.selectThread(uiVictim.id)
        secondSurface.viewModel.prompt = "second surface local-create victim draft"
        secondSurface.viewModel.seedAdditionalThreadCachesForTesting(uiVictim.id)
        secondSurface.viewModel.selectThread(secondSelection)
        ctx.coordinator.seedAutoContinuationStateForTesting(uiVictim.id)
        XCTAssertTrue(secondSurface.viewModel.threadCacheResidueForTesting.contains(uiVictim.id))
        createdEvents.removeAll()
        deletedEvents.removeAll()
        secondSurface.viewModel.dismissStatusMessage()
        secondSurface.viewModel.setReloadThreadListForTesting {
            throw NSError(domain: "AgentSurfaceThreadBindingRouterTests.localReload", code: 3)
        }

        firstSurface.viewModel.createThread(title: "local UI create")

        for _ in 0..<100 where secondSurface.viewModel.threadCacheResidueForTesting.contains(uiVictim.id)
            || !secondSurface.viewModel.statusMessage.contains("Could not reload threads") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        secondSurface.viewModel.setReloadThreadListForTesting(nil)

        XCTAssertEqual(deletedEvents.count, 1,
                       "UI creation must publish its authoritative cap victim")
        XCTAssertEqual(createdEvents.count, 1,
                       "UI creation must publish its created thread")
        XCTAssertEqual(deletedEvents.first?.payload.objectValue?["thread_id"]?.stringValue,
                       uiVictim.id.value.uuidString)
        XCTAssertLessThan(try XCTUnwrap(deletedEvents.first?.seq),
                          try XCTUnwrap(createdEvents.first?.seq),
                          "the UI producer must publish delete before create")
        XCTAssertNil(try ctx.threadRepo.get(id: uiVictim.id))
        XCTAssertFalse(secondSurface.viewModel.threadCacheResidueForTesting.contains(uiVictim.id),
                       "the subscribed surface must evict the UI producer's victim before list failure")
        XCTAssertFalse(ctx.coordinator.autoContinuationThreadIdsForTesting.contains(uiVictim.id))
        XCTAssertEqual(secondSurface.viewModel.selectedThreadId, secondSelection,
                       "UI creation must preserve the unrelated surface selection")
        XCTAssertTrue(secondSurface.viewModel.statusMessage.contains("Could not reload threads"))
    }

    func test_targetedCreate_hydratesRepositoryThreadWhenRailReloadFails() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-TargetedCreate-" + UUID().uuidString
        let (_, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "TARGETED-CREATE", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        let surface = try XCTUnwrap(agentSurfaces(in: workspace.id).first)
        let previous = try router.createAgentThread(
            workspace: workspace.id,
            title: "previous",
            provider: .codex,
            model: "gpt-5.6",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            surfaceID: surface.descriptor.id,
            routingConfiguration: nil
        )
        surface.viewModel.prompt = "previous thread draft"
        surface.viewModel.promptWasEdited()
        surface.viewModel.setReloadThreadListForTesting {
            throw NSError(domain: "AgentSurfaceThreadBindingRouterTests.targetedCreate", code: 1)
        }

        let created = try router.createAgentThread(
            workspace: workspace.id,
            title: "targeted",
            provider: .claude,
            model: "claude-sonnet-4-5",
            permissionMode: .fullAccess,
            reasoningEffort: .high,
            surfaceID: surface.descriptor.id,
            routingConfiguration: nil
        )
        surface.viewModel.setReloadThreadListForTesting(nil)

        XCTAssertEqual(surface.viewModel.selectedThreadId, created.id)
        XCTAssertEqual(surface.viewModel.provider, .claude,
                       "repository fallback must hydrate provider after the failed rail reload")
        XCTAssertEqual(surface.viewModel.model, "claude-sonnet-4-5")
        XCTAssertEqual(surface.viewModel.permissionMode, .fullAccess)
        XCTAssertEqual(surface.viewModel.prompt, "",
                       "the new thread must not display the previous thread's composer")
        surface.viewModel.selectThread(previous.id)
        XCTAssertEqual(surface.viewModel.prompt, "previous thread draft",
                       "the previous composer must remain bound to its original thread")
    }

    func test_routedCreateAtCap_enforcesLimitAndPublishesVictim() async throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-RoutedCap-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "ROUTED-CAP", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        closeAndUnregisterAgentSurfaces(workspace: workspace.id)
        XCTAssertTrue(agentSurfaces(in: workspace.id).isEmpty,
                      "the routed RPC cap path must publish its victim without an open Agent surface")
        let oldest = Date(timeIntervalSince1970: 1_700_000_000)
        var victim = AgentThread(workspaceId: workspace.id, title: "routed victim", provider: .codex, model: "m")
        victim.status = .completed
        victim.updatedAt = oldest
        try ctx.threadRepo.upsert(victim)
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 1) {
            var thread = AgentThread(workspaceId: workspace.id, title: "survivor \(index)", provider: .codex, model: "m")
            thread.status = .completed
            thread.updatedAt = oldest.addingTimeInterval(TimeInterval(index + 1))
            try ctx.threadRepo.upsert(thread)
        }
        var victimEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.thread.deleted",
                  event.payload.objectValue?["thread_id"]?.stringValue == victim.id.value.uuidString else { return }
            victimEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }
        let selection = AgentModelSelection(
            provider: .codex,
            modelId: "gpt-5.6",
            reasoningEffort: .medium,
            serviceTier: .auto
        )

        let created = try await router.createAgentThreadRouting(
            workspace: workspace.id,
            title: "routed create",
            provider: .codex,
            model: "gpt-5.6",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            serviceTier: .auto,
            modelSelection: selection,
            providerInstanceId: nil,
            runAsUser: nil,
            surfaceID: nil,
            routing: AgentRoutingRequest(
                mode: .manual,
                expectedRevision: 0,
                manualSelection: selection
            )
        )

        XCTAssertEqual(try ctx.threadRepo.count(workspaceId: workspace.id),
                       AgentThreadRepository.maxThreadsPerWorkspace)
        XCTAssertNil(try ctx.threadRepo.get(id: victim.id),
                     "the explicit-routing RPC path must enforce the same workspace cap")
        XCTAssertNotNil(try ctx.threadRepo.get(id: created.id))
        XCTAssertEqual(victimEvents.count, 1,
                       "the routed producer must publish its authoritative victim")
    }

    func test_routerCreateAtCap_deleteFailureRollsBackCreationAndPublishesNothing() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-AtomicRouterCap-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "ATOMIC-ROUTER-CAP", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        let existingIDs = try fillWorkspaceToThreadCap(workspace.id, context: ctx)
        let triggerName = "fail_router_cap_delete"
        try installThreadCapDeleteAbortTrigger(ctx, named: triggerName)
        defer { try? ctx.db.execute("DROP TRIGGER \(triggerName);") }
        var lifecycleEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.thread.created"
                    || event.kind == "agent.thread.deleted"
                    || event.kind == "agent.thread.deleted_many" else { return }
            lifecycleEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        XCTAssertThrowsError(try router.createAgentThread(
            workspace: workspace.id,
            title: "must roll back",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            routingConfiguration: nil,
            quiet: true
        ))

        XCTAssertEqual(try ctx.threadRepo.count(workspaceId: workspace.id),
                       AgentThreadRepository.maxThreadsPerWorkspace)
        XCTAssertEqual(Set(try ctx.threadRepo.list(workspaceId: workspace.id).map(\.id)), existingIDs,
                       "cap failure must restore the exact pre-create thread set")
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "a rolled-back router create must publish no create or delete lifecycle")
    }

    func test_routedCreateAtCap_deleteFailureRollsBackCreationAndPublishesNothing() async throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-AtomicRoutedCap-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "ATOMIC-ROUTED-CAP", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        let existingIDs = try fillWorkspaceToThreadCap(workspace.id, context: ctx)
        let triggerName = "fail_routed_cap_delete"
        try installThreadCapDeleteAbortTrigger(ctx, named: triggerName)
        defer { try? ctx.db.execute("DROP TRIGGER \(triggerName);") }
        var lifecycleEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.thread.created"
                    || event.kind == "agent.thread.deleted"
                    || event.kind == "agent.thread.deleted_many" else { return }
            lifecycleEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }
        let selection = AgentModelSelection(
            provider: .codex,
            modelId: "gpt-5.6",
            reasoningEffort: .medium,
            serviceTier: .auto
        )

        do {
            _ = try await router.createAgentThreadRouting(
                workspace: workspace.id,
                title: "must roll back routed",
                provider: .codex,
                model: "gpt-5.6",
                permissionMode: .supervised,
                reasoningEffort: .medium,
                serviceTier: .auto,
                modelSelection: selection,
                providerInstanceId: nil,
                runAsUser: nil,
                surfaceID: nil,
                routing: AgentRoutingRequest(
                    mode: .manual,
                    expectedRevision: 0,
                    manualSelection: selection
                )
            )
            XCTFail("routed cap failure must throw")
        } catch {}

        XCTAssertEqual(try ctx.threadRepo.count(workspaceId: workspace.id),
                       AgentThreadRepository.maxThreadsPerWorkspace)
        XCTAssertEqual(Set(try ctx.threadRepo.list(workspaceId: workspace.id).map(\.id)), existingIDs,
                       "routed cap failure must restore the exact pre-create thread set")
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "a rolled-back routed create must publish no create or delete lifecycle")
    }

    func test_localCreateAtCap_deleteFailureRollsBackCreationAndFailsLoudly() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-AtomicLocalCap-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "ATOMIC-LOCAL-CAP", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        let surface = try XCTUnwrap(agentSurfaces(in: workspace.id).first)
        let existingIDs = try fillWorkspaceToThreadCap(workspace.id, context: ctx)
        surface.viewModel.reloadThreads()
        let triggerName = "fail_local_cap_delete"
        try installThreadCapDeleteAbortTrigger(ctx, named: triggerName)
        defer { try? ctx.db.execute("DROP TRIGGER \(triggerName);") }
        var lifecycleEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.thread.created"
                    || event.kind == "agent.thread.deleted"
                    || event.kind == "agent.thread.deleted_many" else { return }
            lifecycleEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        surface.viewModel.createThread(title: "must roll back local")

        XCTAssertEqual(try ctx.threadRepo.count(workspaceId: workspace.id),
                       AgentThreadRepository.maxThreadsPerWorkspace)
        XCTAssertEqual(Set(try ctx.threadRepo.list(workspaceId: workspace.id).map(\.id)), existingIDs,
                       "local cap failure must restore the exact pre-create thread set")
        XCTAssertTrue(surface.viewModel.statusMessage.contains("Could not create thread"),
                      "the local surface must fail loud when atomic creation rolls back")
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "a rolled-back local create must publish no create or delete lifecycle")
    }

    func test_deletionBridges_applyAuthoritativeIDsBeforeFailedSurfaceReload() async throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-DeletionBridges-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "DELETION-BRIDGES", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        let producer = try XCTUnwrap(agentSurfaces(in: workspace.id).first)
        let receiverDescriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Deletion receiver"
        )
        let receiver = try XCTUnwrap(
            SurfaceRegistry.shared.surface(receiverDescriptor.id) as? AgentAppSurface
        )

        let rawSingle = AgentThread(workspaceId: workspace.id, title: "raw single", provider: .codex, model: "m")
        let rawMany = [
            AgentThread(workspaceId: workspace.id, title: "raw many 1", provider: .codex, model: "m"),
            AgentThread(workspaceId: workspace.id, title: "raw many 2", provider: .codex, model: "m")
        ]
        let localMany = [
            AgentThread(workspaceId: workspace.id, title: "local many 1", provider: .codex, model: "m"),
            AgentThread(workspaceId: workspace.id, title: "local many 2", provider: .codex, model: "m")
        ]
        for thread in [rawSingle] + rawMany + localMany {
            try ctx.threadRepo.upsert(thread)
        }
        producer.viewModel.reloadThreads()
        receiver.viewModel.reloadThreads()

        receiver.viewModel.selectThread(rawSingle.id)
        receiver.viewModel.prompt = "raw single draft"
        receiver.viewModel.seedAdditionalThreadCachesForTesting(rawSingle.id)
        receiver.viewModel.seedRunThreadProjectionForTesting(rawSingle.id)
        ctx.coordinator.seedAutoContinuationStateForTesting(rawSingle.id)
        try ctx.threadRepo.delete(id: rawSingle.id)
        receiver.viewModel.setReloadThreadListForTesting {
            throw NSError(domain: "AgentSurfaceThreadBindingRouterTests.rawSingle", code: 1)
        }

        EventBus.shared.publish(kind: "agent.thread.deleted", payload: .object([
            "thread_id": .string(rawSingle.id.value.uuidString)
        ]))

        for _ in 0..<100 where receiver.viewModel.threadCacheResidueForTesting.contains(rawSingle.id)
            || !receiver.viewModel.statusMessage.contains("Could not reload threads") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        receiver.viewModel.setReloadThreadListForTesting(nil)
        XCTAssertFalse(receiver.viewModel.threads.contains(where: { $0.id == rawSingle.id }))
        XCTAssertFalse(receiver.viewModel.threadCacheResidueForTesting.contains(rawSingle.id))
        XCTAssertFalse(ctx.coordinator.autoContinuationThreadIdsForTesting.contains(rawSingle.id))
        XCTAssertNil(receiver.viewModel.selectedThreadId)
        XCTAssertEqual(receiver.viewModel.prompt, "raw single draft",
                       "raw delete recovery must preserve the selected unsent draft")

        receiver.viewModel.dismissStatusMessage()
        receiver.viewModel.reloadThreads()
        let rawManyIDs = Set(rawMany.map(\.id))
        for thread in rawMany {
            receiver.viewModel.selectThread(thread.id)
            receiver.viewModel.seedAdditionalThreadCachesForTesting(thread.id)
            receiver.viewModel.seedRunThreadProjectionForTesting(thread.id)
            ctx.coordinator.seedAutoContinuationStateForTesting(thread.id)
        }
        try ctx.threadRepo.delete(ids: Array(rawManyIDs))
        receiver.viewModel.setReloadThreadListForTesting {
            throw NSError(domain: "AgentSurfaceThreadBindingRouterTests.rawMany", code: 2)
        }

        EventBus.shared.publish(kind: "agent.thread.deleted_many", payload: .object([
            "thread_ids": .array(rawMany.reversed().map { .string($0.id.value.uuidString) })
        ]))

        for _ in 0..<100 where !receiver.viewModel.threadCacheResidueForTesting.isDisjoint(with: rawManyIDs)
            || !receiver.viewModel.statusMessage.contains("Could not reload threads") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        receiver.viewModel.setReloadThreadListForTesting(nil)
        XCTAssertTrue(receiver.viewModel.threadCacheResidueForTesting.isDisjoint(with: rawManyIDs))
        XCTAssertTrue(ctx.coordinator.autoContinuationThreadIdsForTesting.isDisjoint(with: rawManyIDs))
        XCTAssertTrue(receiver.viewModel.threads.allSatisfy { !rawManyIDs.contains($0.id) })
        XCTAssertNil(receiver.viewModel.selectedThreadId)

        receiver.viewModel.dismissStatusMessage()
        receiver.viewModel.reloadThreads()
        let localManyIDs = Set(localMany.map(\.id))
        for thread in localMany {
            receiver.viewModel.selectThread(thread.id)
            receiver.viewModel.seedAdditionalThreadCachesForTesting(thread.id)
            receiver.viewModel.seedRunThreadProjectionForTesting(thread.id)
            ctx.coordinator.seedAutoContinuationStateForTesting(thread.id)
        }
        receiver.viewModel.setReloadThreadListForTesting {
            throw NSError(domain: "AgentSurfaceThreadBindingRouterTests.localMany", code: 3)
        }
        var deletedManyEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.thread.deleted_many" else { return }
            deletedManyEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        let didDeleteLocalMany = await producer.viewModel.deleteThreads(localManyIDs)
        XCTAssertTrue(didDeleteLocalMany)

        for _ in 0..<100 where !receiver.viewModel.threadCacheResidueForTesting.isDisjoint(with: localManyIDs)
            || !receiver.viewModel.statusMessage.contains("Could not reload threads") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        receiver.viewModel.setReloadThreadListForTesting(nil)
        XCTAssertEqual(deletedManyEvents.count, 1)
        let deletedManyEvent = try XCTUnwrap(deletedManyEvents.first)
        let payload = try XCTUnwrap(deletedManyEvent.payload.objectValue)
        XCTAssertEqual(Set(payload.keys), Set(["thread_ids"]))
        XCTAssertEqual(
            payload["thread_ids"]?.arrayValue?.compactMap { $0.stringValue },
            localMany.map { $0.id.value.uuidString }.sorted(),
            "local bulk delete must publish exactly the two sorted durable IDs"
        )
        XCTAssertTrue(receiver.viewModel.threadCacheResidueForTesting.isDisjoint(with: localManyIDs))
        XCTAssertTrue(ctx.coordinator.autoContinuationThreadIdsForTesting.isDisjoint(with: localManyIDs))
        XCTAssertTrue(receiver.viewModel.threads.allSatisfy { !localManyIDs.contains($0.id) })
        XCTAssertNil(receiver.viewModel.selectedThreadId)
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
        // New workspaces open with a default Agent App tab already registered.
        // Tear it down so this case still proves create-on-open when none remain.
        for surface in agentSurfaces(in: workspace.id) {
            try router.closeSurface(workspace: workspace.id, surface: surface.descriptor.id)
            surface.close()
            SurfaceRegistry.shared.unregister(surface.descriptor.id)
        }
        controller.flushPendingRefresh()
        XCTAssertTrue(agentSurfaces(in: workspace.id).isEmpty,
                      "precondition: no Agent App surfaces before the open route")
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

    func test_openAgentThread_fromScheduledTasksShell_mountsAgentAppInWorkspace() throws {
        // WHY: Schedule Tasks replaces workspaceContent. Opening a run-history
        // thread must leave that shell destination, mount Agent App in the
        // workspace, and succeed with markRead — not throw surfaceNotFound
        // because surface.view.window was nil while Schedule Tasks stayed up.
        let dir = NSTemporaryDirectory() + "RC2Bind-OpenFromSchedule-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let controller = MainWindowController(context: ctx, router: router)
        router.windowController = controller
        router.destinationWindowIsKeyForTests = { $0 === controller.window }
        defer { controller.window.orderOut(nil) }

        let workspace = try router.createWorkspace(name: "SCHEDULE-OPEN", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        var target = try router.createAgentThread(
            workspace: workspace.id,
            title: "scheduled-run",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        target.hasUnread = true
        try ctx.threadRepo.upsert(target)

        // Same workspace already selected + Schedule Tasks shell mounted is the
        // failing production path (selectWorkspace no-ops, panes stay unmounted).
        controller.presentScheduledTasksInMainContent()
        XCTAssertEqual(ctx.state.window.selectedWorkspaceID, workspace.id)

        let routed = try router.openAgentThread(thread: target.id, markRead: true)
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(routed.id) as? AgentAppSurface)

        XCTAssertEqual(surface.viewModel.selectedThreadId, target.id)
        XCTAssertTrue(surface.view.window === controller.window,
                      "Agent App must be mounted in the main window after leaving Schedule Tasks")
        XCTAssertFalse(try XCTUnwrap(ctx.threadRepo.get(id: target.id)).hasUnread,
                       "markRead only after the surface is visibly attached")
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
            // createWorkspace already adds the default Agent App tab. Bind on
            // that surface — an extra createSurface would persist a second tab
            // and make restore restore two (not a production duplicate bug).
            let t = try router.createAgentThread(workspace: ws.id, title: "bound", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)
            threadId = t.id
            let defaults = agentSurfaces(in: ws.id)
            XCTAssertEqual(defaults.count, 1, "new workspaces open with exactly one default Agent App tab")
            let surface = try XCTUnwrap(defaults.first)
            surface.viewModel.selectThread(t.id) // binds + persists via onSelectedThreadChanged
            ctx.saveSnapshot()
            closeAndUnregisterAgentSurfaces(workspace: ws.id)
        }

        // Fresh process.
        let (_, router2) = try makeRouter(dir)
        defer { closeAndUnregisterAgentSurfaces(workspace: workspaceId) }
        router2.reinstantiateRestoredSurfaces()

        let restored = agentSurfaces(in: workspaceId)
        XCTAssertEqual(restored.count, 1, "the default agent tab restores (no phantom duplicate)")
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
        let payload = try XCTUnwrap(updates.first?.payload.objectValue)
        XCTAssertEqual(payload["thread_id"]?.stringValue, thread.id.value.uuidString)
        // WHY: full notes on the event overflow the WS budget; mirrors rehydrate
        // via agent.plan.notes.get. Authoritative value still persisted above.
        XCTAssertNil(payload["notes"], "update event must not embed full notes")
        XCTAssertEqual(payload["rehydrate_required"], .bool(true))
        XCTAssertEqual(payload["preview"]?.stringValue, "typed on Mac")
        XCTAssertEqual(payload["content_digest"]?.stringValue,
                       PlanNotesProjectionV1.contentDigest(of: "typed on Mac"))
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
