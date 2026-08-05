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
        context: AppContext,
        statuses: [AgentRunStatus] = [.completed]
    ) throws -> Set<AgentThreadID> {
        precondition(!statuses.isEmpty)
        var ids: Set<AgentThreadID> = []
        for index in 0..<AgentThreadRepository.maxThreadsPerWorkspace {
            var thread = AgentThread(
                workspaceId: workspaceID,
                title: "existing \(index)",
                provider: .codex,
                model: "fake-model"
            )
            thread.status = statuses[index % statuses.count]
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

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AgentSurfaceThreadBindingRouterTests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: text]
            )
        }
        return text
    }

    private func makePullRequestRepository(number: Int = 7) throws -> (checkout: String, bare: String) {
        let checkout = NSTemporaryDirectory() + "RC2Bind-PRRepo-" + UUID().uuidString
        let bare = checkout + "-origin.git"
        try FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main", checkout])
        try runGit(["-C", checkout, "config", "user.email", "test@remotecode.local"])
        try runGit(["-C", checkout, "config", "user.name", "RemoteCode Test"])
        try Data("base\n".utf8).write(to: URL(fileURLWithPath: checkout).appendingPathComponent("base.txt"))
        try runGit(["-C", checkout, "add", "base.txt"])
        try runGit(["-C", checkout, "commit", "-q", "-m", "base"])
        try runGit(["init", "--bare", "-q", bare])
        try runGit(["-C", checkout, "remote", "add", "origin", bare])
        try runGit(["-C", checkout, "push", "-q", "origin", "main"])
        try runGit(["-C", checkout, "checkout", "-q", "-b", "feature/pr-\(number)"])
        try Data("pull request\n".utf8).write(to: URL(fileURLWithPath: checkout).appendingPathComponent("pr.txt"))
        try runGit(["-C", checkout, "add", "pr.txt"])
        try runGit(["-C", checkout, "commit", "-q", "-m", "pull request"])
        try runGit(["-C", checkout, "push", "-q", "origin", "HEAD:refs/pull/\(number)/head"])
        try runGit(["-C", checkout, "checkout", "-q", "main"])
        return (checkout, bare)
    }

    private func defaultPullRequestWorktreePath(checkout: String, number: Int = 7) -> String {
        let root = URL(fileURLWithPath: checkout).standardizedFileURL
        return root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-pr-worktrees")
            .appendingPathComponent("pr-\(number)").path
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
        secondSurface.viewModel.selectThread(victim.id)
        secondSurface.viewModel.seedAdditionalThreadCachesForTesting(victim.id)
        secondSurface.viewModel.selectThread(secondSelection)
        ctx.coordinator.seedAutoContinuationStateForTesting(victim.id)
        firstSurface.viewModel.seedRunThreadProjectionForTesting(victim.id)

        XCTAssertTrue(firstSurface.viewModel.threadCacheResidueForTesting.contains(victim.id),
                      "precondition: first surface caches the future victim")
        XCTAssertTrue(secondSurface.viewModel.threadCacheResidueForTesting.contains(victim.id),
                      "precondition: second surface caches the future victim")
        XCTAssertEqual(firstSurface.viewModel.activeThreadCount, 1,
                       "precondition: the first surface projects the future victim run")
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

        // publishAgentThreadLifecycle synchronously applies authoritative IDs to
        // every registered surface before it emits the asynchronous EventBus
        // notification. These assertions deliberately run before any yield.
        XCTAssertFalse(firstSurface.viewModel.threadCacheResidueForTesting.contains(victim.id))
        XCTAssertFalse(secondSurface.viewModel.threadCacheResidueForTesting.contains(victim.id))
        XCTAssertFalse(firstSurface.viewModel.threads.contains(where: { $0.id == victim.id }))
        XCTAssertFalse(secondSurface.viewModel.threads.contains(where: { $0.id == victim.id }))
        XCTAssertEqual(firstSurface.viewModel.activeThreadCount, 0,
                       "synchronous deletion must remove the victim run projection")
        XCTAssertFalse(ctx.coordinator.autoContinuationThreadIdsForTesting.contains(victim.id))
        XCTAssertNil(firstSurface.viewModel.selectedThreadId)
        XCTAssertEqual(firstSurface.viewModel.prompt, "first surface victim draft",
                       "synchronous selected-victim recovery must preserve the unsent draft")

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

    /// WHY: scheduled/RPC creation has no Agent App surface to evict local
    /// state. Its cap commit must still release the host queue state, completed
    /// resident session, and coordinator retry buffers exactly once.
    func test_headlessCreateAtCap_retiresGlobalRuntimeWithoutAnAgentSurface() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-HeadlessRetire-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "HEADLESS-RETIRE", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        closeAndUnregisterAgentSurfaces(workspace: workspace.id)
        XCTAssertTrue(agentSurfaces(in: workspace.id).isEmpty,
                      "precondition: this producer must run without an Agent App surface")

        let oldest = Date(timeIntervalSince1970: 1_700_000_000)
        var victim = AgentThread(workspaceId: workspace.id, title: "headless victim", provider: .codex, model: "m")
        victim.status = .completed
        victim.updatedAt = oldest
        try ctx.threadRepo.upsert(victim)
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 1) {
            var survivor = AgentThread(workspaceId: workspace.id, title: "survivor \(index)", provider: .codex, model: "m")
            survivor.status = .completed
            survivor.updatedAt = oldest.addingTimeInterval(TimeInterval(index + 1))
            try ctx.threadRepo.upsert(survivor)
        }

        let adapter = IdleSessionRetirementAdapter(provider: .codex)
        adapter.seedTerminalSession(threadId: victim.id)
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        ctx.coordinator.seedDeletedThreadRuntimeStateForTesting(victim.id)
        ctx.seedDeletedThreadQueueRuntimeStateForTesting(victim.id)

        _ = try router.createAgentThread(
            workspace: workspace.id,
            title: "scheduled create",
            provider: .codex,
            model: "m",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            routingConfiguration: nil,
            quiet: true
        )

        XCTAssertNil(try ctx.threadRepo.get(id: victim.id))
        XCTAssertEqual(adapter.stopSessionCallCount, 1,
                       "headless cap eviction must release a terminal resident provider session")
        XCTAssertFalse(ctx.coordinator.deletedThreadRuntimeResidueForTesting.contains(victim.id),
                       "headless cap eviction must clear coordinator buffers and retry failures")
        XCTAssertFalse(ctx.deletedThreadQueueRuntimeResidueForTesting.contains(victim.id),
                       "headless cap eviction must clear queue waiters, permits, leases, and promotions")
    }

    /// WHY: the Agent App producer must use the same post-commit path as the
    /// headless producer, before it fans out the deleted lifecycle event.
    func test_surfaceCreateAtCap_retiresGlobalRuntimeBeforeLifecycleFanout() throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-SurfaceRetire-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "SURFACE-RETIRE", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        let surface = try XCTUnwrap(agentSurfaces(in: workspace.id).first)

        let oldest = Date(timeIntervalSince1970: 1_700_000_000)
        var victim = AgentThread(workspaceId: workspace.id, title: "surface victim", provider: .codex, model: "m")
        victim.status = .completed
        victim.updatedAt = oldest
        try ctx.threadRepo.upsert(victim)
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 1) {
            var survivor = AgentThread(workspaceId: workspace.id, title: "survivor \(index)", provider: .codex, model: "m")
            survivor.status = .completed
            survivor.updatedAt = oldest.addingTimeInterval(TimeInterval(index + 1))
            try ctx.threadRepo.upsert(survivor)
        }
        surface.viewModel.reloadThreads()

        let adapter = IdleSessionRetirementAdapter(provider: .codex)
        adapter.seedTerminalSession(threadId: victim.id)
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        ctx.coordinator.seedDeletedThreadRuntimeStateForTesting(victim.id)
        ctx.seedDeletedThreadQueueRuntimeStateForTesting(victim.id)
        let existingLifecycle = surface.viewModel.onThreadLifecycle
        var lifecycleObservedRetirement = false
        surface.viewModel.onThreadLifecycle = { event in
            if case let .deleted(ids) = event, ids.contains(victim.id) {
                lifecycleObservedRetirement = adapter.stopSessionCallCount == 1
                    && !ctx.coordinator.deletedThreadRuntimeResidueForTesting.contains(victim.id)
                    && !ctx.deletedThreadQueueRuntimeResidueForTesting.contains(victim.id)
            }
            existingLifecycle?(event)
        }

        surface.viewModel.createThread(title: "surface create")

        XCTAssertNil(try ctx.threadRepo.get(id: victim.id))
        XCTAssertTrue(lifecycleObservedRetirement,
                      "surface lifecycle fan-out must observe globally retired cap-victim state")
        XCTAssertEqual(adapter.stopSessionCallCount, 1,
                       "surface cap eviction must release the completed resident session once")
        XCTAssertFalse(ctx.coordinator.deletedThreadRuntimeResidueForTesting.contains(victim.id),
                       "surface cap eviction must clear coordinator retry/buffer state")
        XCTAssertFalse(ctx.deletedThreadQueueRuntimeResidueForTesting.contains(victim.id),
                       "surface cap eviction must clear AppContext queue state")
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

    func test_createAtCapWithOnlyProtectedRows_rejectsEveryProducerWithoutEvents() async throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-ProtectedCap-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "PROTECTED-CAP", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        let surface = try XCTUnwrap(agentSurfaces(in: workspace.id).first)
        let existingIDs = try fillWorkspaceToThreadCap(
            workspace.id,
            context: ctx,
            statuses: [.running, .pending]
        )
        surface.viewModel.reloadThreads()
        var lifecycleEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.thread.created"
                    || event.kind == "agent.thread.deleted"
                    || event.kind == "agent.thread.deleted_many" else { return }
            lifecycleEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        func assertOriginalState(_ producer: String) throws {
            XCTAssertEqual(try ctx.threadRepo.count(workspaceId: workspace.id),
                           AgentThreadRepository.maxThreadsPerWorkspace,
                           "\(producer) must leave the protected workspace at its cap")
            XCTAssertEqual(Set(try ctx.threadRepo.list(workspaceId: workspace.id).map(\.id)), existingIDs,
                           "\(producer) must roll back its new row")
            XCTAssertTrue(lifecycleEvents.isEmpty,
                          "\(producer) must publish no lifecycle for a rejected create")
        }

        XCTAssertThrowsError(try router.createAgentThread(
            workspace: workspace.id,
            title: "rejected normal router",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            routingConfiguration: nil,
            quiet: true
        )) { error in
            XCTAssertEqual(
                error as? AgentThreadCapacityError,
                .workspaceLimitExceeded(
                    workspaceId: workspace.id,
                    limit: AgentThreadRepository.maxThreadsPerWorkspace,
                    actualCount: AgentThreadRepository.maxThreadsPerWorkspace + 1
                )
            )
        }
        try assertOriginalState("normal router")

        let selection = AgentModelSelection(
            provider: .codex,
            modelId: "gpt-5.6",
            reasoningEffort: .medium,
            serviceTier: .auto
        )
        do {
            _ = try await router.createAgentThreadRouting(
                workspace: workspace.id,
                title: "rejected routed router",
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
            XCTFail("routed create must reject a workspace containing only protected rows")
        } catch {
            XCTAssertEqual(
                error as? AgentThreadCapacityError,
                .workspaceLimitExceeded(
                    workspaceId: workspace.id,
                    limit: AgentThreadRepository.maxThreadsPerWorkspace,
                    actualCount: AgentThreadRepository.maxThreadsPerWorkspace + 1
                )
            )
        }
        try assertOriginalState("routed router")

        XCTAssertThrowsError(try router.prepareAgentThreadForPullRequest(
            workspace: workspace.id,
            url: "not-a-pull-request",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            serviceTier: .auto,
            modelSelection: nil,
            providerInstanceId: nil
        )) { error in
            XCTAssertTrue(error is AgentThreadCapacityError,
                          "capacity preflight must reject before pull-request worktree preparation")
        }
        try assertOriginalState("pull-request router")

        surface.viewModel.createThread(title: "rejected local UI")
        XCTAssertTrue(surface.viewModel.statusMessage.contains("Could not create thread"),
                      "local create must fail loud at protected capacity")
        XCTAssertTrue(surface.viewModel.statusMessage.contains("Agent thread capacity exceeded"),
                      "local create must explain why the protected workspace cannot accept another thread")
        try assertOriginalState("local UI")
    }

    func test_preparePullRequestAtCapPrunesVictimAndPublishesDeletion() throws {
        let repository = try makePullRequestRepository()
        let worktreeRoot = URL(
            fileURLWithPath: defaultPullRequestWorktreePath(checkout: repository.checkout)
        ).deletingLastPathComponent().path
        defer {
            try? FileManager.default.removeItem(atPath: worktreeRoot)
            try? FileManager.default.removeItem(atPath: repository.checkout)
            try? FileManager.default.removeItem(atPath: repository.bare)
        }
        let dir = NSTemporaryDirectory() + "RC2Bind-PRCapSuccess-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "PR-CAP-SUCCESS", cwd: repository.checkout)
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        var victim = AgentThread(
            workspaceId: workspace.id,
            title: "old PR victim",
            provider: .codex,
            model: "m",
            status: .completed
        )
        victim.updatedAt = Date(timeIntervalSince1970: 1)
        try ctx.threadRepo.upsert(victim)
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 1) {
            var protected = AgentThread(
                workspaceId: workspace.id,
                title: "protected \(index)",
                provider: .codex,
                model: "m"
            )
            protected.status = index.isMultiple(of: 2) ? .running : .pending
            try ctx.threadRepo.upsert(protected)
        }
        var deletedEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.thread.deleted" else { return }
            deletedEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        let created = try router.prepareAgentThreadForPullRequest(
            workspace: workspace.id,
            url: "https://github.com/acme/widget/pull/7",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            serviceTier: .auto,
            modelSelection: nil,
            providerInstanceId: nil
        )
        defer {
            _ = GitDiff.removeRegisteredWorktree(
                in: repository.checkout,
                worktreePath: created.worktreePath ?? ""
            )
        }

        XCTAssertEqual(try ctx.threadRepo.count(workspaceId: workspace.id),
                       AgentThreadRepository.maxThreadsPerWorkspace)
        XCTAssertNil(try ctx.threadRepo.get(id: victim.id))
        XCTAssertNotNil(try ctx.threadRepo.get(id: created.id))
        XCTAssertEqual(deletedEvents.count, 1)
        XCTAssertEqual(deletedEvents.first?.payload.objectValue?["thread_id"]?.stringValue,
                       victim.id.value.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(created.worktreePath)))
    }

    func test_preparePullRequestCapacityRaceCleansOnlyCreatedWorktree() throws {
        let repository = try makePullRequestRepository()
        let preparedPath = defaultPullRequestWorktreePath(checkout: repository.checkout)
        let worktreeRoot = URL(fileURLWithPath: preparedPath).deletingLastPathComponent().path
        let unrelatedPath = repository.checkout + "-unrelated-worktree"
        defer {
            try? FileManager.default.removeItem(atPath: worktreeRoot)
            try? FileManager.default.removeItem(atPath: unrelatedPath)
            try? FileManager.default.removeItem(atPath: repository.checkout)
            try? FileManager.default.removeItem(atPath: repository.bare)
        }
        XCTAssertTrue(GitDiff.createWorktree(
            in: repository.checkout,
            path: unrelatedPath,
            branch: "unrelated-race",
            baseBranch: "main"
        ).ok)
        let dir = NSTemporaryDirectory() + "RC2Bind-PRCapRace-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "PR-CAP-RACE", cwd: repository.checkout)
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 1) {
            var protected = AgentThread(
                workspaceId: workspace.id,
                title: "protected \(index)",
                provider: .codex,
                model: "m"
            )
            protected.status = index.isMultiple(of: 2) ? .running : .pending
            try ctx.threadRepo.upsert(protected)
        }
        var concurrent = AgentThread(
            workspaceId: workspace.id,
            title: "concurrent protected create",
            provider: .codex,
            model: "m"
        )
        concurrent.status = .running
        router.beforePullRequestThreadCommitForTesting = {
            try ctx.threadRepo.upsert(concurrent)
        }
        defer { router.beforePullRequestThreadCommitForTesting = nil }

        XCTAssertThrowsError(try router.prepareAgentThreadForPullRequest(
            workspace: workspace.id,
            url: "https://github.com/acme/widget/pull/7",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            serviceTier: .auto,
            modelSelection: nil,
            providerInstanceId: nil
        )) { error in
            XCTAssertTrue(error is AgentThreadCapacityError)
        }

        XCTAssertEqual(try ctx.threadRepo.count(workspaceId: workspace.id),
                       AgentThreadRepository.maxThreadsPerWorkspace)
        XCTAssertNotNil(try ctx.threadRepo.get(id: concurrent.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedPath),
                       "a raced post-preflight capacity failure must remove its new PR worktree")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPath),
                      "cleanup must preserve unrelated registered worktrees")
        XCTAssertTrue(GitDiff.isGit(repository.checkout),
                      "cleanup must preserve the primary checkout")
        _ = GitDiff.removeRegisteredWorktree(in: repository.checkout, worktreePath: unrelatedPath)
    }

    func test_preparePullRequestVictimDeleteFailureCleansOnlyCreatedWorktree() throws {
        let repository = try makePullRequestRepository()
        let preparedPath = defaultPullRequestWorktreePath(checkout: repository.checkout)
        let worktreeRoot = URL(fileURLWithPath: preparedPath).deletingLastPathComponent().path
        let unrelatedPath = repository.checkout + "-unrelated-delete-worktree"
        defer {
            try? FileManager.default.removeItem(atPath: worktreeRoot)
            try? FileManager.default.removeItem(atPath: unrelatedPath)
            try? FileManager.default.removeItem(atPath: repository.checkout)
            try? FileManager.default.removeItem(atPath: repository.bare)
        }
        XCTAssertTrue(GitDiff.createWorktree(
            in: repository.checkout,
            path: unrelatedPath,
            branch: "unrelated-delete",
            baseBranch: "main"
        ).ok)
        let dir = NSTemporaryDirectory() + "RC2Bind-PRDeleteFailure-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "PR-DELETE-FAILURE", cwd: repository.checkout)
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        let originalIDs = try fillWorkspaceToThreadCap(workspace.id, context: ctx)
        let triggerName = "fail_pr_cap_delete"
        try installThreadCapDeleteAbortTrigger(ctx, named: triggerName)
        defer { try? ctx.db.execute("DROP TRIGGER \(triggerName);") }

        XCTAssertThrowsError(try router.prepareAgentThreadForPullRequest(
            workspace: workspace.id,
            url: "https://github.com/acme/widget/pull/7",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            serviceTier: .auto,
            modelSelection: nil,
            providerInstanceId: nil
        ))

        XCTAssertEqual(Set(try ctx.threadRepo.list(workspaceId: workspace.id).map(\.id)), originalIDs,
                       "victim-delete failure must roll back the PR thread and preserve every original row")
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPath))
        XCTAssertTrue(GitDiff.isGit(repository.checkout))
        _ = GitDiff.removeRegisteredWorktree(in: repository.checkout, worktreePath: unrelatedPath)
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

    func test_reloadThreads_capVictimFansOutToSiblingSurfaceBeforeFailedList() async throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-ReloadCapFanout-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "RELOAD-CAP-FANOUT", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        let producer = try XCTUnwrap(agentSurfaces(in: workspace.id).first)
        let receiverDescriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Reload cap receiver"
        )
        let receiver = try XCTUnwrap(
            SurfaceRegistry.shared.surface(receiverDescriptor.id) as? AgentAppSurface
        )

        var victim = AgentThread(
            workspaceId: workspace.id,
            title: "old reload victim",
            provider: .codex,
            model: "m",
            status: .completed
        )
        victim.updatedAt = Date(timeIntervalSince1970: 1)
        try ctx.threadRepo.upsert(victim)
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 1) {
            var survivor = AgentThread(
                workspaceId: workspace.id,
                title: "survivor \(index)",
                provider: .codex,
                model: "m",
                status: .completed
            )
            survivor.updatedAt = Date(timeIntervalSince1970: TimeInterval(100 + index))
            try ctx.threadRepo.upsert(survivor)
        }
        producer.viewModel.reloadThreads()
        receiver.viewModel.reloadThreads()
        receiver.viewModel.selectThread(victim.id)
        receiver.viewModel.prompt = "preserve reload victim draft"
        receiver.viewModel.seedAdditionalThreadCachesForTesting(victim.id)
        receiver.viewModel.seedRunThreadProjectionForTesting(victim.id)
        ctx.coordinator.seedAutoContinuationStateForTesting(victim.id)

        var overflow = AgentThread(
            workspaceId: workspace.id,
            title: "raw overflow",
            provider: .codex,
            model: "m",
            status: .completed
        )
        overflow.updatedAt = Date(timeIntervalSince1970: 10_000)
        try ctx.threadRepo.upsert(overflow)
        receiver.viewModel.setReloadThreadListForTesting {
            throw NSError(domain: "AgentSurfaceThreadBindingRouterTests.reloadCapFanout", code: 1)
        }
        var deletedEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.thread.deleted" else { return }
            deletedEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        producer.viewModel.reloadThreads()

        for _ in 0..<100 where receiver.viewModel.threadCacheResidueForTesting.contains(victim.id)
            || !receiver.viewModel.statusMessage.contains("Could not reload threads") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        receiver.viewModel.setReloadThreadListForTesting(nil)

        XCTAssertEqual(try ctx.threadRepo.count(workspaceId: workspace.id),
                       AgentThreadRepository.maxThreadsPerWorkspace)
        XCTAssertNil(try ctx.threadRepo.get(id: victim.id))
        XCTAssertEqual(deletedEvents.count, 1,
                       "reload-time cap enforcement must publish each committed victim once")
        XCTAssertEqual(deletedEvents.first?.payload.objectValue?["thread_id"]?.stringValue,
                       victim.id.value.uuidString)
        XCTAssertFalse(receiver.viewModel.threadCacheResidueForTesting.contains(victim.id),
                       "the sibling surface must apply the authoritative victim before its list fails")
        XCTAssertFalse(ctx.coordinator.autoContinuationThreadIdsForTesting.contains(victim.id))
        XCTAssertNil(receiver.viewModel.selectedThreadId)
        XCTAssertEqual(receiver.viewModel.prompt, "preserve reload victim draft")
        XCTAssertTrue(receiver.viewModel.statusMessage.contains("Could not reload threads"))
    }

    func test_recoveredForkVictimQueuedBeforeRouterDrainsOnceAndEvictsSurfaces() async throws {
        let dir = NSTemporaryDirectory() + "RC2Bind-RecoveredForkQueue-" + UUID().uuidString
        let (ctx, router) = try makeRouter(dir)
        let workspace = try router.createWorkspace(name: "RECOVERED-FORK-QUEUE", cwd: NSTemporaryDirectory())
        defer { closeAndUnregisterAgentSurfaces(workspace: workspace.id) }
        let producer = try XCTUnwrap(agentSurfaces(in: workspace.id).first)
        let receiverDescriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Recovered fork receiver"
        )
        let receiver = try XCTUnwrap(
            SurfaceRegistry.shared.surface(receiverDescriptor.id) as? AgentAppSurface
        )
        let victim = AgentThread(
            workspaceId: workspace.id,
            title: "launch-recovery victim",
            provider: .codex,
            model: "m"
        )
        try ctx.threadRepo.upsert(victim)
        producer.viewModel.reloadThreads()
        receiver.viewModel.reloadThreads()
        receiver.viewModel.selectThread(victim.id)
        receiver.viewModel.prompt = "preserve recovered-fork draft"
        receiver.viewModel.seedAdditionalThreadCachesForTesting(victim.id)
        receiver.viewModel.seedRunThreadProjectionForTesting(victim.id)
        ctx.coordinator.seedAutoContinuationStateForTesting(victim.id)

        try ctx.threadRepo.delete(id: victim.id)
        receiver.viewModel.setReloadThreadListForTesting {
            throw NSError(domain: "AgentSurfaceThreadBindingRouterTests.recoveredForkQueue", code: 1)
        }
        ctx.router = nil
        ctx.enqueueRecoveredForkPrunedThreadIDs([victim.id, victim.id])
        XCTAssertTrue(receiver.viewModel.threadCacheResidueForTesting.contains(victim.id),
                      "without a router, the committed victim must remain queued rather than silently dropped")
        var deletedEvents: [EventBus.Event] = []
        var createdEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "agent.thread.deleted" { deletedEvents.append(event) }
            if event.kind == "agent.thread.created" { createdEvents.append(event) }
        }
        defer { EventBus.shared.unsubscribe(token) }

        ctx.router = router

        for _ in 0..<100 where receiver.viewModel.threadCacheResidueForTesting.contains(victim.id)
            || !receiver.viewModel.statusMessage.contains("Could not reload threads") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        receiver.viewModel.setReloadThreadListForTesting(nil)

        XCTAssertEqual(deletedEvents.count, 1,
                       "the pending set must deduplicate and drain the committed victim once")
        XCTAssertEqual(deletedEvents.first?.payload.objectValue?["thread_id"]?.stringValue,
                       victim.id.value.uuidString)
        XCTAssertTrue(createdEvents.isEmpty,
                      "launch recovery must not synthesize a created event for the pruned victim")
        XCTAssertFalse(receiver.viewModel.threadCacheResidueForTesting.contains(victim.id))
        XCTAssertFalse(ctx.coordinator.autoContinuationThreadIdsForTesting.contains(victim.id))
        XCTAssertNil(receiver.viewModel.selectedThreadId)
        XCTAssertEqual(receiver.viewModel.prompt, "preserve recovered-fork draft")
        XCTAssertTrue(receiver.viewModel.statusMessage.contains("Could not reload threads"))
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

    func test_perSurfaceThreadBinding_persistsAcrossRestart() async throws {
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
        let (ctx2, router2) = try makeRouter(dir)
        defer { closeAndUnregisterAgentSurfaces(workspace: workspaceId) }
        router2.reinstantiateRestoredSurfaces()

        let restored = agentSurfaces(in: workspaceId)
        XCTAssertEqual(restored.count, 1, "the default agent tab restores (no phantom duplicate)")
        XCTAssertEqual(restored.first?.viewModel.selectedThreadId, threadId,
            "each agent tab must reopen its OWN bound thread after restart, not threads.first.")
        let restoredSurface = try XCTUnwrap(restored.first)

        restoredSurface.viewModel.prompt = "restored unsent draft"
        restoredSurface.viewModel.seedAdditionalThreadCachesForTesting(threadId)
        restoredSurface.viewModel.seedRunThreadProjectionForTesting(threadId)
        ctx2.coordinator.seedAutoContinuationStateForTesting(threadId)
        XCTAssertTrue(restoredSurface.viewModel.threadCacheResidueForTesting.contains(threadId))
        XCTAssertEqual(restoredSurface.viewModel.activeThreadCount, 1,
                       "precondition: the restored surface projects a victim run")
        XCTAssertTrue(ctx2.coordinator.autoContinuationThreadIdsForTesting.contains(threadId))

        try ctx2.threadRepo.delete(id: threadId)
        restoredSurface.viewModel.setReloadThreadListForTesting {
            throw NSError(domain: "AgentSurfaceThreadBindingRouterTests.restoredDelete", code: 1)
        }
        EventBus.shared.publish(kind: "agent.thread.deleted", payload: .object([
            "thread_id": .string(threadId.value.uuidString)
        ]))

        // Yield only until the restored subscription's main-queue callback has
        // attempted its injected-failure reload; do not manually reload/reconcile.
        for _ in 0..<100 where !restoredSurface.viewModel.statusMessage.contains("Could not reload threads") {
            await Task.yield()
        }
        restoredSurface.viewModel.setReloadThreadListForTesting(nil)

        XCTAssertTrue(restoredSurface.viewModel.statusMessage.contains("Could not reload threads"))
        XCTAssertFalse(restoredSurface.viewModel.threads.contains(where: { $0.id == threadId }))
        XCTAssertFalse(restoredSurface.viewModel.threadCacheResidueForTesting.contains(threadId))
        XCTAssertEqual(restoredSurface.viewModel.activeThreadCount, 0,
                       "the restored subscription must remove the victim run projection")
        XCTAssertFalse(ctx2.coordinator.autoContinuationThreadIdsForTesting.contains(threadId))
        XCTAssertNil(restoredSurface.viewModel.selectedThreadId)
        XCTAssertEqual(restoredSurface.viewModel.prompt, "restored unsent draft",
                       "restored subscription recovery must preserve the unsent draft")
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

private final class IdleSessionRetirementAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var sessions: [AgentThreadID: AgentProviderSessionSummary] = [:]
    private var stops = 0

    init(provider: AgentProvider) {
        self.provider = provider
    }

    var stopSessionCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stops
    }

    func seedTerminalSession(threadId: AgentThreadID) {
        lock.lock()
        sessions[threadId] = AgentProviderSessionSummary(
            threadId: threadId,
            provider: provider,
            status: .completed,
            providerThreadId: "resident-idle"
        )
        lock.unlock()
    }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }
    func sendTurn(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(
        threadId: AgentThreadID,
        requestId: String,
        response: AgentProviderRequestResponse
    ) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        stops += 1
        sessions.removeValue(forKey: threadId)
        lock.unlock()
    }
    func recoverSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return Array(sessions.values)
    }
    func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId] != nil
    }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {
        lock.lock()
        sessions.removeAll()
        lock.unlock()
    }
    func streamEvents(
        threadId: AgentThreadID,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) throws {}
}
