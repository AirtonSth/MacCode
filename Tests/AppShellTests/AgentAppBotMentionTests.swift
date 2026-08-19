import XCTest
import AgentRuntime
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import Surfaces

/// Agent App `@bot` mentions must dispatch to the shared teammate runner.
@MainActor
final class AgentAppBotMentionTests: XCTestCase {
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
        let parsed = try XCTUnwrap(BotPeerTranscript.parse(inbound.content))
        XCTAssertTrue(parsed.caption.contains("Message from Quinn"))
        XCTAssertTrue(parsed.body.contains("PONG from Quinn"))
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
        let dir = NSTemporaryDirectory() + "RC2AgentMentionLive-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let fake = FakeProviderRunner(provider: .claude, scenario: .simpleAssistant(reply: peerReply))
        ctx.coordinator.replaceProvider(.claude, runner: fake)
        ctx.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: peerReply)))
        ctx.coordinator.replaceProvider(.grok, runner: FakeProviderRunner(provider: .grok, scenario: .simpleAssistant(reply: peerReply)))
        let botsVM = BotsViewModel(context: ctx, router: router)
        router.botsViewModel = botsVM
        let quinn = try botsVM.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        botsVM.setDeskProvider(.claude)
        let surface = AgentAppSurface(
            workspaceID: WorkspaceID(),
            cwd: dir,
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo
        )
        surface.viewModel.mentionableBotsProvider = { botsVM.bots }
        surface.viewModel.createThread(title: "Mention thread")
        let threadId = try XCTUnwrap(surface.viewModel.selectedThreadId)
        return (router, botsVM, surface, quinn, threadId, ctx)
    }
}
