import XCTest
import AgentRuntime
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import Surfaces

/// Agent App `@bot` mentions must dispatch to the shared teammate runner.
@MainActor
final class AgentAppBotMentionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns")
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns")
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
        super.tearDown()
    }

    func test_agentAppSendDispatchesBotMentions() throws {
        // WHY: typing @quinn in Agent App must start that teammate. If
        // dispatch only existed on Bots Desk, the Agent thread could never
        // hand a turn to another bot.
        let dir = NSTemporaryDirectory() + "RC2AgentMention-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let surface = AgentAppSurface(
            workspaceID: WorkspaceID(),
            cwd: dir,
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo
        )
        let quinn = BotDefinition(
            handle: "quinn",
            name: "Quinn",
            title: "CRM Controller",
            description: ""
        )
        surface.viewModel.mentionableBotsProvider = { [quinn] }
        surface.viewModel.createThread(title: "Mention thread")
        let threadId = try XCTUnwrap(surface.viewModel.selectedThreadId)
        var captured: ([BotDefinition], String, AgentThreadID)?
        let done = expectation(description: "mention dispatch")
        surface.viewModel.onDispatchBotMentions = { peers, text, id in
            captured = (peers, text, id)
            done.fulfill()
        }
        surface.viewModel.dispatchBotMentions(in: "@quinn check WhatsApp", threadId: threadId)
        XCTAssertEqual(surface.viewModel.lastDispatchedMentionHandlesForTesting, ["quinn"])
        wait(for: [done], timeout: 1)
        XCTAssertEqual(captured?.0.map(\.id), [quinn.id])
        XCTAssertEqual(captured?.1, "@quinn check WhatsApp")
        XCTAssertEqual(captured?.2, threadId)

        surface.viewModel.presentBotPeerMessage(peer: quinn, text: "Inbox is clear.", threadId: threadId)
        XCTAssertTrue(surface.viewModel.statusMessage.isEmpty, surface.viewModel.statusMessage)
        let stored = try ctx.messageRepo.listRecent(threadId: threadId, limit: 8)
        let inbound = try XCTUnwrap(stored.last)
        XCTAssertEqual(inbound.role, .assistant)
        let parsed = try XCTUnwrap(BotPeerTranscript.parse(inbound.content))
        XCTAssertTrue(parsed.caption.contains("Message from Quinn"))
        XCTAssertEqual(parsed.body, "Inbox is clear.")
    }

    func test_configureAgentAppBotMentionsReadsBotStore() throws {
        // WHY: the router must publish live bots into the composer. A
        // hard-coded empty provider would show @ suggestions that never resolve.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift")
        let source = try String(contentsOf: sourceURL)
        XCTAssertTrue(source.contains("configureAgentAppBotMentions"))
        XCTAssertTrue(source.contains("runMentionedPrompt"))
        XCTAssertTrue(source.contains("presentBotPeerActivity"))
        XCTAssertTrue(source.contains("presentBotPeerMessage"))
        XCTAssertTrue(source.contains("replacing:"))
    }

    func test_agentAppDispatchStartsPeerAndPaintsReply() async throws {
        // WHY: Agent App used to stub dispatch. The shipped router must
        // start the mentioned bot and persist Message from on this thread.
        let (router, botsVM, surface, quinn, threadId, ctx) = try makeWiredMentionSurface(
            peerReply: "PONG from Quinn"
        )
        await router.dispatchAgentAppBotMentions(
            peers: [quinn],
            text: "@\(quinn.handle) check WhatsApp",
            threadId: threadId,
            onto: surface
        )
        XCTAssertEqual(botsVM.lastMentionedBotIDForTesting, quinn.id)
        XCTAssertTrue(
            botsVM.supervisedRunBotIDsForTesting.contains(quinn.id),
            "Agent App mention must start the peer provider run"
        )
        let stored = try ctx.messageRepo.listRecent(threadId: threadId, limit: 16)
        let assistantRows = stored.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.count, 1, "waiting must update into reply, not remain as a second row")
        let inbound = try XCTUnwrap(assistantRows.first)
        guard let parsed = BotPeerTranscript.parse(inbound.content) else {
            let rowSummary = stored.map { "\($0.role.rawValue):\($0.id.value.uuidString)" }.joined(separator: ",")
            let handoff = botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).first
            let hostStatus = try handoff?.hostRunID.flatMap { try ctx.runRepo.get(id: $0)?.status }
            let thread = try ctx.threadRepo.get(id: threadId)
            let queueCount = try ctx.queuedMessageRepo.list(threadId: threadId).count
            let routing = thread?.effectiveRoutingConfiguration
            let cachedSnapshots = router.cachedProviderSnapshotsForSend()
                .map {
                    "\($0.id):\($0.provider.rawValue):auth=\(String(describing: $0.authenticated))"
                        + ":binary=\(String(describing: $0.binaryPath))"
                        + ":models=\($0.models.map(\.id).joined(separator: "+"))"
                }
                .joined(separator: ",")
            XCTFail(
                "expected durable peer transcript; inbound=\(inbound.id.value.uuidString) "
                    + "role=\(inbound.role.rawValue) content=\(inbound.content.debugDescription) rows=\(rowSummary) "
                    + "phase=\(String(describing: handoff?.phase)) host=\(String(describing: handoff?.hostRunID)) "
                    + "hostStatus=\(String(describing: hostStatus)) threadStatus=\(String(describing: thread?.status)) "
                    + "model=\(String(describing: thread?.model)) instance=\(String(describing: thread?.providerInstanceId)) "
                    + "routing=\(String(describing: routing?.mode.rawValue)) "
                    + "routingInstance=\(String(describing: routing?.manualProviderInstanceId)) "
                    + "routingProvider=\(String(describing: routing?.manualSelection.provider.rawValue)) "
                    + "routingModel=\(String(describing: routing?.manualSelection.effectiveModel)) "
                    + "cache=\(cachedSnapshots) queued=\(queueCount)"
            )
            return
        }
        XCTAssertTrue(parsed.caption.contains("Message from Quinn"))
        XCTAssertTrue(parsed.body.contains("PONG from Quinn"))
    }

    func test_agentAppDispatchDoesNotRetainInitiatingBotsWindowWhileExactPeerIsPending() async throws {
        // WHY: Agent App handoff continuation belongs to the context authority.
        // Closing the Bots window that happened to be registered on Router must
        // release that VM while the exact peer is still pending, without moving
        // the Agent composer or a non-owner Bots window to finish the captured run.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-agent-weak-vm-\(UUID().uuidString)", isDirectory: true)
        let workspaceDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        context.coordinator.replaceProvider(.codex, runner: hostRunner)
        context.coordinator.replaceProvider(
            .grok,
            runner: FakeProviderRunner(provider: .grok, scenario: .simpleAssistant(reply: "unused"))
        )
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })

        var initiatingVM: BotsViewModel? = BotsViewModel(context: context, router: router)
        let (quinn, rory): (BotDefinition, BotDefinition) = try {
            let scopedVM = try XCTUnwrap(initiatingVM)
            let peer = try scopedVM.create(name: "Quinn", title: "CRM Controller", provider: .claude)
            let observerSelection = try scopedVM.create(
                name: "Rory",
                title: "Research Controller",
                provider: .grok
            )
            scopedVM.openDesk(peer)
            scopedVM.setDeskProvider(.claude)
            return (peer, observerSelection)
        }()
        router.botsViewModel = initiatingVM
        let workspace = try router.createWorkspace(
            name: "t005 Agent weak VM",
            cwd: workspaceDirectory.path
        )
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "T005 weak VM origin",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let surface = AgentAppSurface(
            workspaceID: workspace.id,
            cwd: workspaceDirectory.path,
            coordinator: context.coordinator,
            threadRepo: context.threadRepo,
            messageRepo: context.messageRepo,
            queuedMessageRepo: context.queuedMessageRepo,
            providerSessionRepo: context.providerSessionRuntimeRepo,
            checkpointRepo: context.turnCheckpointRepo,
            initialThreadId: thread.id
        )
        surface.viewModel.mentionableBotsProvider = { [quinn] }
        surface.viewModel.selectThread(thread.id)
        surface.viewModel.prompt = "AGENT_DRAFT_MUST_SURVIVE"
        let agentFocus = surface.viewModel.focusTick

        let observingVM = BotsViewModel(context: context, router: router)
        observingVM.openDesk(rory)
        observingVM.screen = .studio
        observingVM.composerText = "NON_OWNER_DRAFT_MUST_SURVIVE"
        observingVM.attachments = [AgentAttachment(
            path: root.appendingPathComponent("non-owner.txt").path,
            displayName: "non-owner.txt",
            kind: .file
        )]
        let observerSelection = observingVM.selectedBotID
        let observerScreen = observingVM.screen
        let observerComposer = observingVM.composerText
        let observerAttachments = observingVM.attachments

        let dispatch = Task { @MainActor in
            await router.dispatchAgentAppBotMentions(
                peers: [quinn],
                text: "@\(quinn.handle) T005_AGENT_WEAK_VM",
                threadId: thread.id,
                onto: surface
            )
        }
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("T005_AGENT_WEAK_VM") }
        }
        XCTAssertTrue(peerStarted)
        let running = try XCTUnwrap(observingVM.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: thread.id
        ).first)
        let peerRunID = try XCTUnwrap(running.peerRunID)
        let hostRunID = try XCTUnwrap(running.hostRunID)
        XCTAssertEqual(peerRunner.requests.filter { $0.runId == peerRunID }.count, 1)

        // Router is weak and VM B is only an observer/non-owner. VM A must not
        // remain hidden in the suspended optional-await call stack.
        router.botsViewModel = observingVM
        weak var releasedInitiator = initiatingVM
        initiatingVM = nil
        let deallocatedWhilePending = await waitUntil(timeout: 0.5) {
            releasedInitiator == nil
        }
        XCTAssertTrue(
            deallocatedWhilePending,
            "Agent App dispatch must not retain its initiating Bots VM across the pending exact peer"
        )
        XCTAssertEqual(try context.runRepo.get(id: peerRunID)?.status, .running)

        XCTAssertTrue(peerRunner.finish(
            runID: peerRunID,
            status: .completed,
            reply: "EXACT_AGENT_WEAK_REPLY"
        ))
        let hostStarted = await waitUntil(timeout: 5) {
            hostRunner.requests.contains { $0.runId == hostRunID }
        }
        XCTAssertTrue(hostStarted)
        let hostBound = await waitUntil(timeout: 5) {
            observingVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: thread.id
            ).first?.phase == .hostRunning
        }
        XCTAssertTrue(hostBound)
        await Task.yield()
        XCTAssertEqual(peerRunner.requests.filter { $0.runId == peerRunID }.count, 1)
        XCTAssertEqual(hostRunner.requests.filter { $0.runId == hostRunID }.count, 1)
        XCTAssertTrue(hostRunner.finish(
            runID: hostRunID,
            status: .completed,
            reply: "EXACT_AGENT_HOST_OUTCOME"
        ))
        await dispatch.value

        let completed = await waitUntil(timeout: 5) {
            observingVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: thread.id
            ).first?.phase == .completed
        }
        XCTAssertTrue(completed)
        let inbound = try XCTUnwrap(
            try context.messageRepo.get(id: AgentMessageID(running.inboundMessageID))
        )
        XCTAssertEqual(BotPeerTranscript.parse(inbound.content)?.body, "EXACT_AGENT_WEAK_REPLY")
        XCTAssertEqual(peerRunner.requests.filter { $0.runId == peerRunID }.count, 1)
        XCTAssertEqual(hostRunner.requests.filter { $0.runId == hostRunID }.count, 1)

        XCTAssertEqual(surface.viewModel.selectedThreadId, thread.id)
        XCTAssertEqual(surface.viewModel.prompt, "AGENT_DRAFT_MUST_SURVIVE")
        XCTAssertEqual(surface.viewModel.focusTick, agentFocus)
        XCTAssertEqual(observingVM.selectedBotID, observerSelection)
        XCTAssertEqual(observingVM.screen, observerScreen)
        XCTAssertEqual(observingVM.composerText, observerComposer)
        XCTAssertEqual(observingVM.attachments, observerAttachments)
    }

    func test_agentAppHopOmitsMentionToken() async throws {
        // WHY: hop-1 must feed the Agent thread the peer reply without
        // `@handle`, or dispatchBotMentions would loop.
        let (router, _, surface, quinn, threadId, _) = try makeWiredMentionSurface(
            peerReply: "inbox is clear"
        )
        await router.dispatchAgentAppBotMentions(
            peers: [quinn],
            text: "@\(quinn.handle) what is in the inbox?",
            threadId: threadId,
            onto: surface
        )
        let hop = try XCTUnwrap(router.lastAgentAppHopTextForTesting)
        XCTAssertEqual(
            hop,
            BotPeerTranscript.hostHopPrompt(peerName: quinn.name, reply: "inbox is clear")
        )
        XCTAssertFalse(BotPeerTranscript.containsMentionToken(hop, handle: quinn.handle))
        XCTAssertFalse(hop.contains("@\(quinn.handle)"))
    }

    func test_agentAppCompletedHostWithoutExactCheckpointNeedsAttentionInsteadOfFalseSuccess() async throws {
        // WHY: provider terminal status is not the reply ownership proof. A
        // completed host run with no checkpoint assistant must never make the
        // captured handoff look successfully settled.
        let (router, botsVM, surface, quinn, threadId, ctx) = try makeWiredMentionSurface(
            peerReply: "unused controlled reply"
        )
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.claude, runner: peerRunner)
        ctx.coordinator.replaceProvider(.codex, runner: hostRunner)

        let dispatch = Task {
            await router.dispatchAgentAppBotMentions(
                peers: [quinn],
                text: "@\(quinn.handle) CHECKPOINT_REQUIRED",
                threadId: threadId,
                onto: surface
            )
        }
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("CHECKPOINT_REQUIRED") }
        }
        XCTAssertTrue(peerStarted)
        XCTAssertTrue(peerRunner.finish(promptContaining: "CHECKPOINT_REQUIRED", reply: "exact peer reply"))
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let hostBound = await waitUntil(timeout: 5) {
            botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).first?.phase == .hostRunning
        }
        XCTAssertTrue(hostBound)
        await dispatch.value
        let handoff = try XCTUnwrap(botsVM.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: threadId
        ).first)
        let hostRunID = try XCTUnwrap(handoff.hostRunID)
        XCTAssertEqual(hostRunner.requests.first?.runId, hostRunID)
        let checkpointRemover = CheckpointAssistantRemovingObserver(
            db: ctx.db,
            runID: hostRunID
        )
        ctx.coordinator.removeObserver(botsVM)
        ctx.coordinator.addObserver(checkpointRemover)
        ctx.coordinator.addObserver(botsVM)
        defer { ctx.coordinator.removeObserver(checkpointRemover) }
        let activityMessageID = AgentMessageID(handoff.activityID)
        let settlement = Task { @MainActor in
            await botsVM.settleAgentAppHost(activityMessageID: activityMessageID)
        }
        await Task.yield()
        XCTAssertTrue(hostRunner.finish(runID: hostRunID, status: .completed, reply: "host assistant"))
        let hostTerminal = await waitUntil(timeout: 5) {
            (try? ctx.runRepo.get(id: hostRunID)?.status) == .completed
        }
        XCTAssertTrue(hostTerminal)
        XCTAssertTrue(checkpointRemover.didRemoveExactAssistant)
        let hostCheckpoint = try XCTUnwrap(
            ctx.turnCheckpointRepo.list(threadId: threadId).last { $0.runId == hostRunID }
        )
        XCTAssertNil(
            hostCheckpoint.assistantMessageId,
            "the didFinish interleaving must expose a completed run after the checkpoint attempt but without ownership"
        )
        let needsAttention = await waitUntil(timeout: 1) {
            botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).first?.phase == .needsAttention
        }
        if !needsAttention {
            botsVM.markAgentAppHostDispatchFailed(activityMessageID: activityMessageID)
        }
        await settlement.value
        XCTAssertTrue(
            needsAttention,
            "completed status without the exact checkpoint assistant must fail closed instead of false-succeeding"
        )
    }

    func test_terminalBeforeSecondWaiterRegistrationSettlesFromDurableExactRunWithoutHanging() async throws {
        // WHY: observer delivery is edge-triggered. A waiter registered after
        // that edge must immediately reconcile the durable terminal run and its
        // exact checkpoint instead of waiting forever for an event that passed.
        let (router, botsVM, surface, quinn, threadId, _) = try makeWiredMentionSurface(
            peerReply: "terminal before waiter"
        )
        await router.dispatchAgentAppBotMentions(
            peers: [quinn],
            text: "@\(quinn.handle) TERMINAL_BEFORE_WAITER",
            threadId: threadId,
            onto: surface
        )
        let initiallyCompleted = await waitUntil(timeout: 5) {
            botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).first?.phase == .completed
        }
        XCTAssertTrue(initiallyCompleted)
        let handoff = try XCTUnwrap(botsVM.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: threadId
        ).first)
        let activityMessageID = AgentMessageID(handoff.activityID)

        var secondSettlementReturned = false
        let secondSettlement = Task { @MainActor in
            await botsVM.settleAgentAppHost(activityMessageID: activityMessageID)
            secondSettlementReturned = true
        }
        let returnedFromDurableRead = await waitUntil(timeout: 1) {
            secondSettlementReturned
        }
        let phaseBeforeCleanup = botsVM.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: threadId
        ).first?.phase
        if !returnedFromDurableRead {
            botsVM.markAgentAppHostDispatchFailed(activityMessageID: activityMessageID)
        }
        await secondSettlement.value

        XCTAssertTrue(
            returnedFromDurableRead,
            "a waiter registered after didFinish must settle from the immediate durable read"
        )
        XCTAssertEqual(
            phaseBeforeCleanup,
            .completed,
            "the exact durable checkpoint keeps the already-settled handoff completed"
        )
    }

    func test_relaunchObservesBoundQueuedHostRunBeforeItsRunRowExistsWithoutRedispatch() async throws {
        // WHY: a queued Agent App continuation owns its future run ID before a
        // run row exists. Relaunch must observe that exact queue row through
        // launch and terminal settlement, never downgrade or invent a send.
        let (router, botsVM, surface, quinn, threadId, ctx) = try makeWiredMentionSurface(
            peerReply: "unused queued reply"
        )
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.claude, runner: peerRunner)
        ctx.coordinator.replaceProviderAdapter(
            .codex,
            adapter: TerminalRetiringOneShotAdapter(runner: hostRunner)
        )

        let occupying = try await router.sendAgentMessage(
            thread: threadId,
            text: "occupy origin before queued handoff",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let occupyingRunID = try XCTUnwrap(occupying.runId)
        let dispatch = Task {
            await router.dispatchAgentAppBotMentions(
                peers: [quinn],
                text: "@\(quinn.handle) QUEUED_RELAUNCH",
                threadId: threadId,
                onto: surface
            )
        }
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("QUEUED_RELAUNCH") }
        }
        XCTAssertTrue(peerStarted)
        XCTAssertTrue(peerRunner.finish(promptContaining: "QUEUED_RELAUNCH", reply: "queued peer reply"))
        let hostBound = await waitUntil(timeout: 5) {
            botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).first?.phase == .hostRunning
        }
        XCTAssertTrue(hostBound)
        await dispatch.value
        let handoff = try XCTUnwrap(botsVM.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: threadId
        ).first)
        let hostRunID = try XCTUnwrap(handoff.hostRunID)
        let queuedID = AgentQueuedMessageID(hostRunID.value)
        XCTAssertEqual(try ctx.queuedMessageRepo.get(id: queuedID)?.id, queuedID)
        XCTAssertNil(
            try ctx.runRepo.get(id: hostRunID),
            "the crash boundary is after exact queue binding but before provider launch creates the run row"
        )

        let reopened = BotsViewModel(context: ctx, router: router)
        let restored = try XCTUnwrap(reopened.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: threadId
        ).first)
        guard restored.phase == .hostRunning else {
            botsVM.markAgentAppHostDispatchFailed(activityMessageID: AgentMessageID(handoff.activityID))
            _ = hostRunner.finish(runID: occupyingRunID, status: .cancelled, reply: nil)
            XCTFail(
                "an exact queued future host run is still observable after relaunch; phase=\(restored.phase)"
            )
            return
        }

        XCTAssertTrue(hostRunner.finish(runID: occupyingRunID, status: .completed, reply: "occupier done"))
        let queuedHostStarted = await waitUntil(timeout: 5) {
            hostRunner.requests.contains { $0.runId == hostRunID }
        }
        XCTAssertTrue(queuedHostStarted)
        XCTAssertEqual(hostRunner.requests.filter { $0.runId == hostRunID }.count, 1)
        XCTAssertTrue(hostRunner.finish(runID: hostRunID, status: .completed, reply: "host exact reply"))
        let restoredCompleted = await waitUntil(timeout: 5) {
            reopened.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).first?.phase == .completed
        }
        XCTAssertTrue(restoredCompleted)
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queuedID))
        XCTAssertEqual(hostRunner.requests.filter { $0.runId == hostRunID }.count, 1)
    }

    func test_restoredQueuedHostAuthorityOutlivesInitialReconcilingWindowAndSettlesForNewObserverWithoutRedispatch() async throws {
        // WHY: startup reconciliation is context work, not window work. Closing
        // the first Bots window after it discovers an exact future host queue
        // must not discard the observer that settles that run for later windows.
        let seed = try await makeRestoredQueuedHostSeed(
            prompt: "RESTORED_AUTHORITY_SEED",
            reply: "RESTORED_AUTHORITY_REPLY"
        )
        let fresh = try makeFreshRestoredHandoffContext(
            rawHandoffs: seed.rawHandoffs,
            sourceThread: seed.thread,
            queued: seed.queued
        )
        defer { try? FileManager.default.removeItem(at: fresh.root) }
        let context = fresh.context
        let router = fresh.router
        let peerRunner = fresh.peerRunner
        let hostRunner = fresh.hostRunner
        let thread = fresh.thread
        let hostRunID = try XCTUnwrap(seed.handoff.hostRunID)
        XCTAssertEqual(seed.queued.id, AgentQueuedMessageID(hostRunID.value))
        XCTAssertNil(try context.runRepo.get(id: hostRunID))
        context.router = router

        var firstWindow: BotsViewModel? = BotsViewModel(context: context, router: router)
        let initiallyObserved = try XCTUnwrap(firstWindow?.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: thread.id
        ).first)
        XCTAssertEqual(initiallyObserved.activityID, seed.handoff.activityID)
        XCTAssertEqual(initiallyObserved.phase, .hostRunning)
        weak var releasedFirstWindow = firstWindow
        firstWindow = nil
        let firstWindowReleased = await waitUntil(timeout: 0.5) {
            releasedFirstWindow == nil
        }
        XCTAssertTrue(
            firstWindowReleased,
            "the context authority, not the initially reconciling Bots window, must own the exact queued-run observer"
        )

        try await router.drainNextQueuedAgentMessage(thread: thread.id)
        let exactHostStarted = await waitUntil(timeout: 5) {
            hostRunner.requests.contains { $0.runId == hostRunID }
        }
        XCTAssertTrue(exactHostStarted)
        XCTAssertEqual(hostRunner.requests.filter { $0.runId == hostRunID }.count, 1)
        XCTAssertTrue(hostRunner.finish(
            runID: hostRunID,
            status: .completed,
            reply: "RESTORED_HOST_OUTCOME"
        ))
        let durableTerminal = await waitUntil(timeout: 5) {
            (try? context.runRepo.get(id: hostRunID)?.status) == .completed
        }
        XCTAssertTrue(durableTerminal)

        let observer = BotsViewModel(context: context, router: router)
        let authoritySettled = await waitUntil(timeout: 2) {
            observer.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: thread.id
            ).first?.phase == .completed
        }
        XCTAssertTrue(authoritySettled)
        let restoredRows = try context.messageRepo.list(threadId: thread.id).filter {
            $0.id == AgentMessageID(seed.handoff.inboundMessageID)
        }
        XCTAssertEqual(restoredRows.count, 1)
        XCTAssertEqual(BotPeerTranscript.parse(restoredRows.first?.content ?? "")?.body, "RESTORED_AUTHORITY_REPLY")
        XCTAssertTrue(peerRunner.requests.isEmpty, "restoration must never redispatch the already-finished peer")
        XCTAssertEqual(hostRunner.requests.filter { $0.runId == hostRunID }.count, 1)
        XCTAssertNil(try context.queuedMessageRepo.get(id: seed.queued.id))
    }

    func test_peerCompletedQueueCrashRetriesSameReplyAfterTransientImportFailureWithoutRedispatch() async throws {
        // WHY: a crash can leave the durable peer reply and exact future host
        // queue ID committed before the phase advances. A transient transcript
        // write failure must keep that handoff replayable at the same message
        // ID; relaunch then retries exactly once and observes the queued run.
        let seed = try await makeRestoredQueuedHostSeed(
            prompt: "IMPORT_RETRY",
            reply: "stable restored reply"
        )
        let handoff = seed.handoff
        let threadId = seed.thread.id
        let hostRunID = try XCTUnwrap(handoff.hostRunID)
        let queuedID = AgentQueuedMessageID(hostRunID.value)
        let stableMessageID = AgentMessageID(handoff.inboundMessageID)
        let crashHandoffs = try replacingOnlyPersistedHandoffPhase(
            in: seed.rawHandoffs,
            from: .hostRunning,
            to: .peerCompleted
        )
        let fresh = try makeFreshRestoredHandoffContext(
            rawHandoffs: crashHandoffs,
            sourceThread: seed.thread,
            queued: seed.queued
        )
        defer { try? FileManager.default.removeItem(at: fresh.root) }
        XCTAssertEqual(try fresh.context.queuedMessageRepo.get(id: queuedID)?.id, queuedID)
        XCTAssertNil(try fresh.context.runRepo.get(id: hostRunID))
        XCTAssertNil(try fresh.context.messageRepo.get(id: stableMessageID))

        var rejectedFirstReplyAppend = false
        fresh.context.db.beforeStatementStepForTesting = { sql in
            guard !rejectedFirstReplyAppend,
                  sql.contains("INSERT INTO agent_messages") else { return }
            rejectedFirstReplyAppend = true
            fresh.context.db.injectedResultCodesForTesting = [10] // SQLITE_IOERR
        }
        fresh.context.router = fresh.router
        let firstRelaunch = BotsViewModel(context: fresh.context, router: fresh.router)
        fresh.context.db.beforeStatementStepForTesting = nil

        XCTAssertTrue(rejectedFirstReplyAppend, "the first restored reply append must hit the injected failure")
        let replayable = try XCTUnwrap(firstRelaunch.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: threadId
        ).first)
        XCTAssertEqual(
            replayable.phase,
            .peerCompleted,
            "a transient import failure must not consume the replayable crash record"
        )
        let attention = try XCTUnwrap(try fresh.context.messageRepo.get(id: stableMessageID))
        XCTAssertEqual(attention.id, stableMessageID)
        XCTAssertEqual(attention.threadId, threadId)
        XCTAssertEqual(attention.role, .assistant)
        XCTAssertEqual(BotPeerTranscript.parseActivity(attention.content)?.phase, .needsAttention)
        XCTAssertTrue(fresh.peerRunner.requests.isEmpty)
        XCTAssertEqual(fresh.hostRunner.requests.filter { $0.runId == hostRunID }.count, 0)

        firstRelaunch.reconcilePeerHandoffsForTesting()
        let imported = try XCTUnwrap(try fresh.context.messageRepo.get(id: stableMessageID))
        XCTAssertEqual(BotPeerTranscript.parse(imported.content)?.body, "stable restored reply")
        XCTAssertEqual(
            try fresh.context.messageRepo.list(threadId: threadId).filter { $0.id == stableMessageID }.count,
            1,
            "retry must overwrite the stable attention row instead of duplicating the peer reply"
        )

        let secondRelaunch = BotsViewModel(context: fresh.context, router: fresh.router)
        secondRelaunch.reconcilePeerHandoffsForTesting()
        XCTAssertEqual(
            try fresh.context.messageRepo.list(threadId: threadId).filter { $0.id == stableMessageID }.count,
            1,
            "a second relaunch/reconcile must remain idempotent"
        )
        XCTAssertEqual(fresh.hostRunner.requests.filter { $0.runId == hostRunID }.count, 0)

        try await fresh.router.drainNextQueuedAgentMessage(thread: threadId)
        let queuedHostStarted = await waitUntil(timeout: 5) {
            fresh.hostRunner.requests.contains { $0.runId == hostRunID }
        }
        XCTAssertTrue(queuedHostStarted)
        XCTAssertEqual(fresh.hostRunner.requests.filter { $0.runId == hostRunID }.count, 1)
        XCTAssertTrue(fresh.hostRunner.finish(
            runID: hostRunID,
            status: .completed,
            reply: "host completed exactly"
        ))
        let settledExactly = await waitUntil(timeout: 5) {
            firstRelaunch.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).first?.phase == .completed
                && secondRelaunch.peerHandoffSnapshotsForTesting(
                    originConversationID: nil,
                    originThreadID: threadId
                ).first?.phase == .completed
        }
        XCTAssertTrue(settledExactly)
        XCTAssertNil(try fresh.context.queuedMessageRepo.get(id: queuedID))
        XCTAssertEqual(fresh.hostRunner.requests.filter { $0.runId == hostRunID }.count, 1)
    }

    func test_relaunchWithCompletedPeerButUnboundHostPreservesReplyAndNeedsAttentionWithoutRedispatch() async throws {
        // WHY: after the peer reply is durable, a crash may reveal that no
        // host queue/run binding survived. Recovery must preserve the captured
        // reply and surface attention; inventing a replacement send could run
        // the user's continuation twice.
        let seed = try await makeRestoredQueuedHostSeed(
            prompt: "HOST_UNBOUND",
            reply: "preserved peer reply"
        )
        let handoff = seed.handoff
        let threadId = seed.thread.id
        let hostRunID = try XCTUnwrap(handoff.hostRunID)
        let queuedID = AgentQueuedMessageID(hostRunID.value)
        let crashHandoffs = try removingPersistedHostBinding(
            from: seed.rawHandoffs,
            activityID: handoff.activityID
        )
        let fresh = try makeFreshRestoredHandoffContext(
            rawHandoffs: crashHandoffs,
            sourceThread: seed.thread,
            queued: nil
        )
        defer { try? FileManager.default.removeItem(at: fresh.root) }
        XCTAssertNil(try fresh.context.queuedMessageRepo.get(id: queuedID))
        XCTAssertNil(try fresh.context.runRepo.get(id: hostRunID))
        fresh.context.router = fresh.router

        let firstRelaunch = BotsViewModel(context: fresh.context, router: fresh.router)
        let secondRelaunch = BotsViewModel(context: fresh.context, router: fresh.router)
        for reopened in [firstRelaunch, secondRelaunch] {
            reopened.reconcilePeerHandoffsForTesting()
            let restored = try XCTUnwrap(reopened.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).first)
            XCTAssertEqual(restored.phase, .needsAttention)
            XCTAssertNil(restored.hostThreadID)
            XCTAssertNil(restored.hostRunID)
        }

        let stableMessageID = AgentMessageID(handoff.inboundMessageID)
        let preserved = try XCTUnwrap(try fresh.context.messageRepo.get(id: stableMessageID))
        XCTAssertEqual(preserved.id, stableMessageID)
        XCTAssertEqual(preserved.threadId, threadId)
        XCTAssertEqual(BotPeerTranscript.parse(preserved.content)?.body, "preserved peer reply")
        XCTAssertEqual(
            try fresh.context.messageRepo.list(threadId: threadId).filter { $0.id == stableMessageID }.count,
            1
        )
        XCTAssertTrue(
            fresh.hostRunner.requests.isEmpty,
            "neither relaunch nor explicit reconciliation may synthesize a host dispatch"
        )
        XCTAssertTrue(fresh.peerRunner.requests.isEmpty)
    }

    func test_cancellingOneObservedFutureHostQueueSettlesOnlyItsExactHandoff() async throws {
        // WHY: queue cancellation is identified by its future run UUID. Two
        // handoffs may wait behind the same active thread, so cancelling one
        // row must not disarm, dispatch, or settle the sibling row.
        let (router, botsVM, surface, quinn, threadId, ctx) = try makeWiredMentionSurface(
            peerReply: "unused queue cancellation reply"
        )
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.claude, runner: peerRunner)
        ctx.coordinator.replaceProviderAdapter(
            .codex,
            adapter: TerminalRetiringOneShotAdapter(runner: hostRunner)
        )

        let occupying = try await router.sendAgentMessage(
            thread: threadId,
            text: "occupy origin before two queued handoffs",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let occupyingRunID = try XCTUnwrap(occupying.runId)

        let dispatchA = Task {
            await router.dispatchAgentAppBotMentions(
                peers: [quinn],
                text: "@\(quinn.handle) QUEUE_CANCEL_A",
                threadId: threadId,
                onto: surface
            )
        }
        let peerAStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("QUEUE_CANCEL_A") }
        }
        XCTAssertTrue(peerAStarted)
        XCTAssertTrue(peerRunner.finish(promptContaining: "QUEUE_CANCEL_A", reply: "reply A"))
        let firstHostBound = await waitUntil(timeout: 5) {
            botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).count == 1
                && botsVM.peerHandoffSnapshotsForTesting(
                    originConversationID: nil,
                    originThreadID: threadId
                ).first?.phase == .hostRunning
        }
        XCTAssertTrue(firstHostBound)
        await dispatchA.value

        let dispatchB = Task {
            await router.dispatchAgentAppBotMentions(
                peers: [quinn],
                text: "@\(quinn.handle) QUEUE_CANCEL_B",
                threadId: threadId,
                onto: surface
            )
        }
        let peerBStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("QUEUE_CANCEL_B") }
        }
        XCTAssertTrue(peerBStarted)
        XCTAssertTrue(peerRunner.finish(promptContaining: "QUEUE_CANCEL_B", reply: "reply B"))
        let bothHostBound = await waitUntil(timeout: 5) {
            let handoffs = botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            )
            return handoffs.count == 2 && handoffs.allSatisfy { $0.phase == .hostRunning }
        }
        XCTAssertTrue(bothHostBound)
        await dispatchB.value

        let handoffs = botsVM.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: threadId
        )
        let peerRunA = try XCTUnwrap(
            peerRunner.requests.first { $0.prompt.contains("QUEUE_CANCEL_A") }?.runId
        )
        let peerRunB = try XCTUnwrap(
            peerRunner.requests.first { $0.prompt.contains("QUEUE_CANCEL_B") }?.runId
        )
        let handoffA = try XCTUnwrap(handoffs.first { $0.peerRunID == peerRunA })
        let handoffB = try XCTUnwrap(handoffs.first { $0.peerRunID == peerRunB })
        let hostRunA = try XCTUnwrap(handoffA.hostRunID)
        let hostRunB = try XCTUnwrap(handoffB.hostRunID)
        let queuedA = AgentQueuedMessageID(hostRunA.value)
        let queuedB = AgentQueuedMessageID(hostRunB.value)
        XCTAssertNotNil(try ctx.queuedMessageRepo.get(id: queuedA))
        XCTAssertNotNil(try ctx.queuedMessageRepo.get(id: queuedB))
        XCTAssertNil(try ctx.runRepo.get(id: hostRunA))
        XCTAssertNil(try ctx.runRepo.get(id: hostRunB))

        _ = try router.cancelAgentQueuedMessage(id: queuedA)
        let exactCancellationSettled = await waitUntil(timeout: 2) {
            botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).first { $0.activityID == handoffA.activityID }?.phase == .needsAttention
        }
        XCTAssertTrue(exactCancellationSettled)
        XCTAssertEqual(
            botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).first { $0.activityID == handoffB.activityID }?.phase,
            .hostRunning,
            "the sibling future run remains observable after another queue row is cancelled"
        )
        XCTAssertNil(try ctx.queuedMessageRepo.get(id: queuedA))
        XCTAssertNotNil(try ctx.queuedMessageRepo.get(id: queuedB))
        XCTAssertNil(try ctx.runRepo.get(id: hostRunB))
        XCTAssertEqual(
            hostRunner.requests.map(\.runId),
            [occupyingRunID],
            "queue lifecycle settlement must never start either future provider run"
        )
        XCTAssertEqual(
            BotPeerTranscript.parse(try XCTUnwrap(try ctx.messageRepo.get(
                id: AgentMessageID(handoffA.inboundMessageID)
            )).content)?.body,
            "reply A"
        )
        XCTAssertEqual(
            BotPeerTranscript.parse(try XCTUnwrap(try ctx.messageRepo.get(
                id: AgentMessageID(handoffB.inboundMessageID)
            )).content)?.body,
            "reply B"
        )

        _ = try router.cancelAgentQueuedMessage(id: queuedB)
        XCTAssertTrue(hostRunner.finish(runID: occupyingRunID, status: .cancelled, reply: nil))
    }

    func test_twoAgentAppTargetsStartIndependentlySoSlowFirstPeerCannotBlockFastSecond() async throws {
        // WHY: one mention can name multiple teammates. Each target owns an
        // independent exact handoff, so a slow first provider must not block
        // the second provider from starting, replying, or retaining its stable
        // activity ID.
        let (router, botsVM, surface, quinn, threadId, ctx) = try makeWiredMentionSurface(
            peerReply: "unused multi-target reply"
        )
        let rory = try botsVM.create(
            name: "Rory",
            title: "Research Controller",
            provider: .grok
        )
        botsVM.openDesk(rory)
        botsVM.setDeskProvider(.grok)
        let slowRunner = ControlledBotHandoffRunner(provider: .claude)
        let fastRunner = ControlledBotHandoffRunner(provider: .grok)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.claude, runner: slowRunner)
        ctx.coordinator.replaceProvider(.grok, runner: fastRunner)
        ctx.coordinator.replaceProviderAdapter(
            .codex,
            adapter: TerminalRetiringOneShotAdapter(runner: hostRunner)
        )

        let occupying = try await router.sendAgentMessage(
            thread: threadId,
            text: "occupy origin during multi-target fan-out",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let occupyingRunID = try XCTUnwrap(occupying.runId)
        let dispatch = Task {
            await router.dispatchAgentAppBotMentions(
                peers: [quinn, rory],
                text: "@\(quinn.handle) @\(rory.handle) MULTI_TARGET",
                threadId: threadId,
                onto: surface
            )
        }
        let slowStarted = await waitUntil(timeout: 5) {
            slowRunner.requests.contains { $0.prompt.contains("MULTI_TARGET") }
        }
        XCTAssertTrue(slowStarted)
        let bothStartedBeforeEitherTerminal = await waitUntil(timeout: 1) {
            fastRunner.requests.contains { $0.prompt.contains("MULTI_TARGET") }
        }
        XCTAssertTrue(
            bothStartedBeforeEitherTerminal,
            "target B must start while target A is still pending; sequential await adds head-of-line blocking"
        )

        if bothStartedBeforeEitherTerminal {
            XCTAssertTrue(fastRunner.finish(promptContaining: "MULTI_TARGET", reply: "RORY_FAST_REPLY"))
            let fastReplyImported = await waitUntil(timeout: 5) {
                let roryHandoff = botsVM.peerHandoffSnapshotsForTesting(
                    originConversationID: nil,
                    originThreadID: threadId
                ).first { $0.peerBotID == rory.id }
                guard let roryHandoff,
                      let message = try? ctx.messageRepo.get(
                        id: AgentMessageID(roryHandoff.inboundMessageID)
                      ) else { return false }
                return BotPeerTranscript.parse(message.content)?.body == "RORY_FAST_REPLY"
            }
            XCTAssertTrue(fastReplyImported)
            XCTAssertEqual(
                botsVM.peerHandoffSnapshotsForTesting(
                    originConversationID: nil,
                    originThreadID: threadId
                ).first { $0.peerBotID == quinn.id }?.phase,
                .peerRunning,
                "the fast target must import independently while the slow target remains owned"
            )
            XCTAssertTrue(slowRunner.finish(promptContaining: "MULTI_TARGET", reply: "QUINN_SLOW_REPLY"))
        } else {
            // Cleanup for the red characterization: release the serial first
            // target so the second target can start and no task leaks.
            XCTAssertTrue(slowRunner.finish(promptContaining: "MULTI_TARGET", reply: "QUINN_SLOW_REPLY"))
            let fastEventuallyStarted = await waitUntil(timeout: 5) {
                fastRunner.requests.contains { $0.prompt.contains("MULTI_TARGET") }
            }
            XCTAssertTrue(fastEventuallyStarted)
            XCTAssertTrue(fastRunner.finish(promptContaining: "MULTI_TARGET", reply: "RORY_FAST_REPLY"))
        }

        await dispatch.value
        let bothBound = await waitUntil(timeout: 5) {
            let handoffs = botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            )
            return handoffs.count == 2 && handoffs.allSatisfy { $0.phase == .hostRunning }
        }
        XCTAssertTrue(bothBound)
        let handoffs = botsVM.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: threadId
        )
        let quinnHandoff = try XCTUnwrap(handoffs.first { $0.peerBotID == quinn.id })
        let roryHandoff = try XCTUnwrap(handoffs.first { $0.peerBotID == rory.id })
        XCTAssertNotEqual(quinnHandoff.peerRunID, roryHandoff.peerRunID)
        XCTAssertNotEqual(quinnHandoff.inboundMessageID, roryHandoff.inboundMessageID)
        XCTAssertEqual(
            BotPeerTranscript.parse(try XCTUnwrap(try ctx.messageRepo.get(
                id: AgentMessageID(quinnHandoff.inboundMessageID)
            )).content)?.body,
            "QUINN_SLOW_REPLY"
        )
        XCTAssertEqual(
            BotPeerTranscript.parse(try XCTUnwrap(try ctx.messageRepo.get(
                id: AgentMessageID(roryHandoff.inboundMessageID)
            )).content)?.body,
            "RORY_FAST_REPLY"
        )
        let hostRunIDs = try handoffs.map { try XCTUnwrap($0.hostRunID) }
        XCTAssertEqual(Set(hostRunIDs).count, 2)
        for hostRunID in hostRunIDs {
            let queuedID = AgentQueuedMessageID(hostRunID.value)
            XCTAssertNotNil(try ctx.queuedMessageRepo.get(id: queuedID))
            XCTAssertNil(try ctx.runRepo.get(id: hostRunID))
            _ = try router.cancelAgentQueuedMessage(id: queuedID)
        }
        XCTAssertEqual(hostRunner.requests.map(\.runId), [occupyingRunID])
        XCTAssertTrue(hostRunner.finish(runID: occupyingRunID, status: .cancelled, reply: nil))
    }

    func test_agentAppPeerActivityUpsertsOneDurableRow() async throws {
        // WHY: waiting and reply are one teammate turn. Appending the reply as
        // a second row leaves stale "Waiting" chrome after completion/relaunch.
        let dir = NSTemporaryDirectory() + "RC2AgentPeerActivity-" + UUID().uuidString
        let workspaceID = WorkspaceID()
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let surface = AgentAppSurface(
            workspaceID: workspaceID,
            cwd: dir,
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo
        )
        let quinn = BotDefinition(
            handle: "quinn",
            name: "Quinn",
            title: "CRM Controller",
            description: ""
        )
        surface.viewModel.createThread(title: "Peer activity reply")
        let threadId = try XCTUnwrap(surface.viewModel.selectedThreadId)

        let waitingID = try XCTUnwrap(surface.viewModel.presentBotPeerActivity(
            peer: quinn,
            phase: .waiting,
            threadId: threadId
        ))
        let waitingRows = try ctx.messageRepo.list(threadId: threadId)
        XCTAssertEqual(waitingRows.count, 1)
        XCTAssertEqual(waitingRows.first?.id, waitingID)
        XCTAssertEqual(
            waitingRows.first.map(\.content).flatMap(BotPeerTranscript.parseActivity),
            BotPeerActivitySnapshot(
                phase: .waiting,
                name: "Quinn",
                title: "CRM Controller",
                handle: "quinn"
            )
        )
        let waitingCreatedAt = try XCTUnwrap(waitingRows.first?.createdAt)

        let replyID = try XCTUnwrap(surface.viewModel.presentBotPeerMessage(
            peer: quinn,
            text: "Inbox is clear.",
            threadId: threadId,
            replacing: waitingID
        ))
        XCTAssertEqual(replyID, waitingID)
        XCTAssertEqual(surface.viewModel.messages.count, 1)
        XCTAssertEqual(surface.viewModel.messages.first?.id, waitingID)

        let replyRows = try ctx.messageRepo.list(threadId: threadId)
        XCTAssertEqual(replyRows.count, 1)
        let reply = try XCTUnwrap(replyRows.first)
        XCTAssertEqual(reply.id, waitingID)
        XCTAssertEqual(reply.createdAt, waitingCreatedAt)
        let parsedReply = try XCTUnwrap(BotPeerTranscript.parse(reply.content))
        XCTAssertEqual(parsedReply.caption, "Message from Quinn - CRM Controller - quinn")
        XCTAssertEqual(parsedReply.body, "Inbox is clear.")
        XCTAssertEqual(parsedReply.name, "Quinn")
        XCTAssertEqual(parsedReply.title, "CRM Controller")
        XCTAssertEqual(parsedReply.handle, "quinn")

        let reloaded = AgentAppSurface(
            workspaceID: workspaceID,
            cwd: dir,
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo,
            initialThreadId: threadId
        )
        await reloaded.viewModel.waitForMessageHistoryLoad()
        XCTAssertEqual(reloaded.viewModel.messages.count, 1)
        XCTAssertEqual(reloaded.viewModel.messages.first?.id, waitingID)
        XCTAssertEqual(
            reloaded.viewModel.messages.first.flatMap { BotPeerTranscript.parse($0.content)?.body },
            "Inbox is clear."
        )
    }

    func test_agentAppPeerActivityFailureUpdatesSameRow() async throws {
        // WHY: a peer that produces no answer must replace its live waiting row
        // with durable recovery chrome instead of disappearing or duplicating it.
        let dir = NSTemporaryDirectory() + "RC2AgentPeerFailure-" + UUID().uuidString
        let workspaceID = WorkspaceID()
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let surface = AgentAppSurface(
            workspaceID: workspaceID,
            cwd: dir,
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo
        )
        let quinn = BotDefinition(
            handle: "quinn",
            name: "Quinn",
            title: "CRM Controller",
            description: ""
        )
        surface.viewModel.createThread(title: "Peer activity failure")
        let threadId = try XCTUnwrap(surface.viewModel.selectedThreadId)

        let waitingID = try XCTUnwrap(surface.viewModel.presentBotPeerActivity(
            peer: quinn,
            phase: .waiting,
            threadId: threadId
        ))
        let waitingRows = try ctx.messageRepo.list(threadId: threadId)
        XCTAssertEqual(waitingRows.count, 1)
        XCTAssertEqual(waitingRows.first?.id, waitingID)
        XCTAssertEqual(
            waitingRows.first.map(\.content).flatMap(BotPeerTranscript.parseActivity)?.phase,
            .waiting
        )
        let waitingCreatedAt = try XCTUnwrap(waitingRows.first?.createdAt)

        let failureID = try XCTUnwrap(surface.viewModel.presentBotPeerActivity(
            peer: quinn,
            phase: .needsAttention,
            threadId: threadId,
            replacing: waitingID
        ))
        XCTAssertEqual(failureID, waitingID)
        XCTAssertEqual(surface.viewModel.messages.count, 1)
        XCTAssertEqual(surface.viewModel.messages.first?.id, waitingID)

        let failureRows = try ctx.messageRepo.list(threadId: threadId)
        XCTAssertEqual(failureRows.count, 1)
        let failure = try XCTUnwrap(failureRows.first)
        XCTAssertEqual(failure.id, waitingID)
        XCTAssertEqual(failure.createdAt, waitingCreatedAt)
        XCTAssertEqual(
            BotPeerTranscript.parseActivity(failure.content),
            BotPeerActivitySnapshot(
                phase: .needsAttention,
                name: "Quinn",
                title: "CRM Controller",
                handle: "quinn"
            )
        )

        let reloaded = AgentAppSurface(
            workspaceID: workspaceID,
            cwd: dir,
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo,
            initialThreadId: threadId
        )
        await reloaded.viewModel.waitForMessageHistoryLoad()
        XCTAssertEqual(reloaded.viewModel.messages.count, 1)
        XCTAssertEqual(reloaded.viewModel.messages.first?.id, waitingID)
        XCTAssertEqual(
            reloaded.viewModel.messages.first.map(\.content).flatMap(BotPeerTranscript.parseActivity),
            BotPeerActivitySnapshot(
                phase: .needsAttention,
                name: "Quinn",
                title: "CRM Controller",
                handle: "quinn"
            )
        )
    }

    func test_switchingAwayKeepsReplyAndFollowUpOnCapturedThreadWithoutFocusTheft() async throws {
        // WHY: a Bot reply is background work owned by the thread that sent
        // the mention. Switching to another conversation must not drop the
        // continuation, move content, consume its draft, or reselect origin.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2AgentMentionSwitch-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.claude, runner: peerRunner)
        ctx.coordinator.replaceProvider(.codex, runner: hostRunner)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            let candidateModelIDs = [BotsViewModel.defaultModel(for: provider)]
                + (provider == .codex ? ["gpt-5.5"] : [])
            var seenModelIDs = Set<String>()
            let models = candidateModelIDs
                .filter { seenModelIDs.insert($0).inserted }
                .map { AgentModelDescriptor(id: $0, label: $0, provider: provider) }
            return AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: models,
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let botsVM = BotsViewModel(context: ctx, router: router)
        router.botsViewModel = botsVM
        let quinn = try botsVM.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        botsVM.openDesk(quinn)
        botsVM.setDeskProvider(.claude)

        let workspace = try router.createWorkspace(name: "mention-switch", cwd: workspaceDir.path)
        let origin = try router.createAgentThread(
            workspace: workspace.id,
            title: "Origin",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let other = try router.createAgentThread(
            workspace: workspace.id,
            title: "Other",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let surface = AgentAppSurface(
            workspaceID: workspace.id,
            cwd: workspaceDir.path,
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo,
            queuedMessageRepo: ctx.queuedMessageRepo,
            providerSessionRepo: ctx.providerSessionRuntimeRepo,
            checkpointRepo: ctx.turnCheckpointRepo,
            initialThreadId: origin.id
        )
        surface.viewModel.selectThread(origin.id)

        let dispatch = Task {
            await router.dispatchAgentAppBotMentions(
                peers: [quinn],
                text: "@\(quinn.handle) SWITCH_ORIGIN",
                threadId: origin.id,
                onto: surface
            )
        }
        defer {
            dispatch.cancel()
            for request in peerRunner.requests {
                _ = peerRunner.finish(runID: request.runId, status: .cancelled, reply: nil)
            }
            for request in hostRunner.requests {
                _ = hostRunner.finish(runID: request.runId, status: .cancelled, reply: nil)
            }
            surface.viewModel.mentionableBotsProvider = { [] }
            surface.close()
            router.botsViewModel = nil
            ctx.router = nil
        }
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("SWITCH_ORIGIN") }
        }
        XCTAssertTrue(peerStarted)
        surface.viewModel.selectThread(other.id)
        surface.viewModel.prompt = "draft that belongs to Other"

        XCTAssertTrue(peerRunner.finish(promptContaining: "SWITCH_ORIGIN", reply: "ORIGIN_REPLY"))
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        XCTAssertEqual(surface.viewModel.selectedThreadId, other.id)
        XCTAssertEqual(surface.viewModel.prompt, "draft that belongs to Other")
        XCTAssertEqual(hostRunner.requests.first?.threadId, origin.id)
        XCTAssertTrue(try ctx.messageRepo.list(threadId: other.id).isEmpty)
        let originRows = try ctx.messageRepo.list(threadId: origin.id)
        XCTAssertEqual(
            originRows.filter {
                $0.role == .assistant
                    && BotPeerTranscript.parse($0.content)?.body == "ORIGIN_REPLY"
            }.count,
            1,
            "the stable activity row must become one exact reply on origin"
        )

        let snapshot = try XCTUnwrap(botsVM.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: origin.id
        ).first)
        XCTAssertEqual(snapshot.originThreadID, origin.id)
        XCTAssertEqual(snapshot.peerRunID, peerRunner.requests.first?.runId)
        XCTAssertEqual(snapshot.hostThreadID, origin.id)
        XCTAssertEqual(snapshot.hostRunID, hostRunner.requests.first?.runId)

        XCTAssertTrue(hostRunner.finish(
            runID: try XCTUnwrap(snapshot.hostRunID),
            status: .completed,
            reply: "origin follow-up complete"
        ))
        _ = await dispatch.value
        let originBecameUnread = await waitUntil(timeout: 5) {
            (try? ctx.threadRepo.get(id: origin.id)?.hasUnread) == true
        }
        XCTAssertTrue(originBecameUnread)
        XCTAssertEqual(surface.viewModel.selectedThreadId, other.id)
        XCTAssertEqual(surface.viewModel.prompt, "draft that belongs to Other")
        XCTAssertEqual(try ctx.threadRepo.get(id: other.id)?.hasUnread, false)
        XCTAssertTrue(try ctx.messageRepo.list(threadId: other.id).isEmpty)
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    private struct RestoredQueuedHostSeed {
        let rawHandoffs: Data
        let handoff: BotPeerHandoffSnapshot
        let thread: AgentThread
        let queued: AgentQueuedMessage
    }

    private final class RestoredBootstrapWeakRefs {
        weak var context: AppContext?
        weak var authority: BotPeerHandoffAuthority?
        weak var router: AppCommandRouter?
        weak var viewModel: BotsViewModel?
        weak var surface: AgentAppSurface?

        init(
            context: AppContext,
            authority: BotPeerHandoffAuthority,
            router: AppCommandRouter,
            viewModel: BotsViewModel,
            surface: AgentAppSurface
        ) {
            self.context = context
            self.authority = authority
            self.router = router
            self.viewModel = viewModel
            self.surface = surface
        }

        var retainedObjectNames: [String] {
            [
                viewModel != nil ? "viewModel" : nil,
                surface != nil ? "surface" : nil,
                router != nil ? "router" : nil,
                authority != nil ? "authority" : nil,
                context != nil ? "context" : nil,
            ].compactMap { $0 }
        }
    }

    private func makeRestoredQueuedHostSeed(
        prompt: String,
        reply: String
    ) async throws -> RestoredQueuedHostSeed {
        let (seed, released) = try await makeRestoredQueuedHostBootstrap(
            prompt: prompt,
            reply: reply
        )

        let windowOwnersReleased = await waitUntil(timeout: 2) {
            released.viewModel == nil && released.surface == nil
        }
        XCTAssertTrue(
            windowOwnersReleased,
            "the crash seed must release its VM and surface before fresh activation; retained=\(released.retainedObjectNames)"
        )
        return seed
    }

    private func makeRestoredQueuedHostBootstrap(
        prompt: String,
        reply: String
    ) async throws -> (seed: RestoredQueuedHostSeed, released: RestoredBootstrapWeakRefs) {
        let (router, botsVM, surface, quinn, threadID, context) = try makeWiredMentionSurface(
            peerReply: "unused restored seed"
        )
        let released = RestoredBootstrapWeakRefs(
            context: context,
            authority: context.botPeerHandoffAuthority,
            router: router,
            viewModel: botsVM,
            surface: surface
        )
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        context.coordinator.replaceProviderAdapter(
            .codex,
            adapter: TerminalRetiringOneShotAdapter(runner: hostRunner)
        )
        let occupying = try await router.sendAgentMessage(
            thread: threadID,
            text: "occupy bootstrap origin",
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )
        let occupyingRunID = try XCTUnwrap(occupying.runId)
        let dispatch = Task { @MainActor in
            await router.dispatchAgentAppBotMentions(
                peers: [quinn],
                text: "@\(quinn.handle) \(prompt)",
                threadId: threadID,
                onto: surface
            )
        }
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains(prompt) }
        }
        XCTAssertTrue(peerStarted)
        XCTAssertTrue(peerRunner.finish(promptContaining: prompt, reply: reply))
        let hostBound = await waitUntil(timeout: 5) {
            botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadID
            ).first?.phase == .hostRunning
        }
        XCTAssertTrue(hostBound)
        await dispatch.value

        let handoff = try XCTUnwrap(botsVM.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: threadID
        ).first)
        let hostRunID = try XCTUnwrap(handoff.hostRunID)
        let queued = try XCTUnwrap(try context.queuedMessageRepo.get(
            id: AgentQueuedMessageID(hostRunID.value)
        ))
        XCTAssertNil(try context.runRepo.get(id: hostRunID))
        let seed = RestoredQueuedHostSeed(
            rawHandoffs: try XCTUnwrap(
                UserDefaults.standard.data(forKey: "bots.peerTurns.v2")
            ),
            handoff: handoff,
            thread: try XCTUnwrap(try context.threadRepo.get(id: threadID)),
            queued: queued
        )

        _ = try router.cancelAgentQueuedMessage(id: queued.id)
        XCTAssertTrue(hostRunner.finish(
            runID: occupyingRunID,
            status: .cancelled,
            reply: nil
        ))
        let bootstrapTerminated = await waitUntil(timeout: 2) {
            (try? context.runRepo.get(id: occupyingRunID)?.status) == .cancelled
                && (try? context.queuedMessageRepo.get(id: queued.id)) == nil
                && botsVM.peerHandoffSnapshotsForTesting(
                    originConversationID: nil,
                    originThreadID: threadID
                ).first?.phase == .needsAttention
        }
        XCTAssertTrue(bootstrapTerminated)
        surface.viewModel.mentionableBotsProvider = { [] }
        surface.close()
        context.router = nil
        XCTAssertNil(context.router, "bootstrap must sever its context-to-router edge before returning")
        return (seed, released)
    }

    private func replacingOnlyPersistedHandoffPhase(
        in data: Data,
        from oldPhase: BotPeerHandoffPhase,
        to newPhase: BotPeerHandoffPhase
    ) throws -> Data {
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        let oldFragment = "\"phase\":\"\(oldPhase.rawValue)\""
        let newFragment = "\"phase\":\"\(newPhase.rawValue)\""
        XCTAssertEqual(
            encoded.components(separatedBy: oldFragment).count - 1,
            1,
            "the crash fixture must mutate one exact persisted handoff"
        )
        let changed = encoded.replacingOccurrences(of: oldFragment, with: newFragment)
        return try XCTUnwrap(changed.data(using: .utf8))
    }

    private func removingPersistedHostBinding(
        from data: Data,
        activityID: UUID
    ) throws -> Data {
        var entries = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [Any]
        )
        var matched = 0
        for index in entries.indices {
            guard var record = entries[index] as? [String: Any],
                  let rawActivityID = record["activityID"] as? String,
                  UUID(uuidString: rawActivityID) == activityID else { continue }
            matched += 1
            record["phase"] = BotPeerHandoffPhase.peerCompleted.rawValue
            record.removeValue(forKey: "hostThreadID")
            record.removeValue(forKey: "hostRunID")
            record.removeValue(forKey: "hostRoute")
            entries[index] = record
        }
        XCTAssertEqual(matched, 1, "the host-unbound crash fixture must rewrite one exact record")
        return try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
    }

    private func makeFreshRestoredHandoffContext(
        rawHandoffs: Data,
        sourceThread: AgentThread,
        queued: AgentQueuedMessage?
    ) throws -> (
        root: URL,
        context: AppContext,
        router: AppCommandRouter,
        peerRunner: ControlledBotHandoffRunner,
        hostRunner: ControlledBotHandoffRunner,
        thread: AgentThread
    ) {
        let key = "bots.peerTurns.v2"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t005-restored-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.set(rawHandoffs, forKey: key)
        XCTAssertTrue(UserDefaults.standard.synchronize())
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), rawHandoffs)

        let context = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path
        )
        try context.settingsRepo.set(key, "base64:\(rawHandoffs.base64EncodedString())")
        let router = AppCommandRouter(context: context)
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        context.coordinator.replaceProviderAdapter(
            .codex,
            adapter: TerminalRetiringOneShotAdapter(runner: hostRunner)
        )
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let thread = AgentThread(
            id: sourceThread.id,
            title: sourceThread.title,
            provider: sourceThread.provider,
            providerInstanceId: sourceThread.providerInstanceId,
            model: sourceThread.model,
            status: .completed,
            permissionMode: sourceThread.permissionMode,
            reasoningEffort: sourceThread.reasoningEffort,
            serviceTier: sourceThread.serviceTier,
            modelSelection: sourceThread.modelSelection,
            interactionMode: sourceThread.effectiveInteractionMode,
            runAsUser: sourceThread.runAsUser,
            routingConfiguration: sourceThread.routingConfiguration
        )
        try context.threadRepo.upsert(thread)
        if let queued {
            try context.queuedMessageRepo.upsert(queued)
        }
        XCTAssertEqual(
            try context.settingsRepo.get(key),
            "base64:\(rawHandoffs.base64EncodedString())"
        )
        return (root, context, router, peerRunner, hostRunner, thread)
    }

    private func makeWiredMentionSurface(
        peerReply: String
    ) throws -> (
        router: AppCommandRouter,
        botsVM: BotsViewModel,
        surface: AgentAppSurface,
        quinn: BotDefinition,
        threadId: AgentThreadID,
        ctx: AppContext
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2AgentMentionLive-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let fake = FakeProviderRunner(provider: .claude, scenario: .simpleAssistant(reply: peerReply))
        ctx.coordinator.replaceProvider(.claude, runner: fake)
        ctx.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: peerReply)))
        ctx.coordinator.replaceProvider(.grok, runner: FakeProviderRunner(provider: .grok, scenario: .simpleAssistant(reply: peerReply)))
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let botsVM = BotsViewModel(context: ctx, router: router)
        router.botsViewModel = botsVM
        let quinn = try botsVM.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        botsVM.setDeskProvider(.claude)
        let workspace = try router.createWorkspace(name: "mention-live", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Mention thread",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let surface = AgentAppSurface(
            workspaceID: workspace.id,
            cwd: workspaceDir.path,
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo,
            queuedMessageRepo: ctx.queuedMessageRepo,
            providerSessionRepo: ctx.providerSessionRuntimeRepo,
            checkpointRepo: ctx.turnCheckpointRepo,
            initialThreadId: thread.id
        )
        surface.viewModel.mentionableBotsProvider = { botsVM.bots }
        surface.viewModel.selectThread(thread.id)
        return (router, botsVM, surface, quinn, thread.id, ctx)
    }
}

private final class CheckpointAssistantRemovingObserver: AgentRunObserver, @unchecked Sendable {
    private let db: SQLiteDB
    private let runID: AgentRunID
    private let lock = NSLock()
    private var removed = false

    init(db: SQLiteDB, runID: AgentRunID) {
        self.db = db
        self.runID = runID
    }

    var didRemoveExactAssistant: Bool {
        lock.withLock { removed }
    }

    func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didReceive event: AssistantEvent,
        run: AgentRunID,
        threadId: AgentThreadID
    ) {}

    func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didFinish finishedRunID: AgentRunID,
        threadId: AgentThreadID,
        status: AgentRunStatus,
        finalMessage: String?,
        providerThreadId: String?
    ) {
        guard finishedRunID == runID else { return }
        do {
            let statement = try db.prepare("""
                UPDATE agent_turn_checkpoints
                SET assistant_message_id = NULL
                WHERE run_id = ?;
            """)
            try statement.bind(1, runID.value.uuidString)
            _ = try statement.step()
            lock.withLock { removed = true }
        } catch {}
    }

    func runCoordinator(
        _ coordinator: AgentRunCoordinator,
        didChangeStatus status: AgentRunStatus,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) {}
}
