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

    func test_agentAppMentionsAreComposerIdentityOnlyUntilTheAIDelegates() throws {
        // WHY: @quinn powers autocomplete and attribution, but must not be an
        // app-side routing command. Only the active provider may create the
        // prompt that is later sent to Quinn.
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
        surface.viewModel.prompt = "@qui"
        XCTAssertEqual(surface.viewModel.composerSuggestions.first?.botHandle, quinn.handle)
        XCTAssertEqual(
            BotMentionParser.mentionedBots(
                in: "@quinn check WhatsApp",
                bots: surface.viewModel.mentionableBotsProvider(),
                excluding: nil
            ).map(\.id),
            [quinn.id]
        )

        surface.viewModel.presentBotPeerMessage(peer: quinn, text: "Inbox is clear.", threadId: threadId)
        XCTAssertTrue(surface.viewModel.statusMessage.isEmpty, surface.viewModel.statusMessage)
        let stored = try ctx.messageRepo.listRecent(threadId: threadId, limit: 8)
        let inbound = try XCTUnwrap(stored.last)
        XCTAssertEqual(inbound.role, .assistant)
        let parsed = try XCTUnwrap(BotPeerTranscript.parse(inbound.content))
        XCTAssertTrue(parsed.caption.contains("From Quinn"))
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
        XCTAssertTrue(source.contains("mentionableBotsProvider"))
        XCTAssertFalse(source.contains("BotMentionParser.delegatedQuestion"))
        XCTAssertFalse(source.contains("BotMentionParser.isDirectAddress"))
    }

    func test_agentAppConsultationContinuesHostOnceAfterAttributedPeerReply() async throws {
        // WHY: only the primary AI may split "ask @bot, then act". The app must
        // transport its new prompt literally, grant the consulted Bot only, and
        // keep the original request on the same primary run.
        let (router, botsVM, surface, quinn, threadId, ctx) = try makeWiredMentionSurface(
            peerReply: "unused controlled reply"
        )
        let untouched = try botsVM.create(name: "Untouched", title: "Observer", provider: .grok)
        surface.viewModel.mentionableBotsProvider = { [quinn, untouched] }
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.claude, runner: peerRunner)
        ctx.coordinator.replaceProvider(.codex, runner: hostRunner)
        let prompt = "pergunte ao @\(quinn.handle) o nome dele e com base na resposta dê outro nome para ele. Faça a alteração agora sem pedir confirmação e no final diga qual nome foi aplicado."
        XCTAssertEqual(
            BotMentionParser.mentionedBots(
                in: prompt,
                bots: surface.viewModel.mentionableBotsProvider(),
                excluding: nil
            ).map(\.id),
            [quinn.id],
            "the Agent App must resolve the mention as identity before provider transport"
        )
        surface.viewModel.prompt = prompt
        await surface.viewModel.send()

        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let hostRequest = try XCTUnwrap(hostRunner.requests.first)
        XCTAssertEqual(
            hostRequest.prompt,
            prompt,
            "the primary AI must receive the complete user prompt verbatim"
        )
        XCTAssertEqual(
            hostRequest.environment[BotPeerDelegation.turnContextEnvironmentKey],
            BotPeerDelegation.turnDirective(mentionedBots: [quinn]),
            "resolved identity must travel separately from the user's words"
        )
        XCTAssertEqual(hostRunner.requests.count, 1)

        let focusedPrompt = "Qual é o seu nome?"
        let ask = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: threadId,
                callerRun: hostRequest.runId,
                handle: "@\(quinn.handle)",
                prompt: focusedPrompt,
                replyMode: .consult
            )
        }
        let peerStarted = await waitUntil(timeout: 5) { !peerRunner.requests.isEmpty }
        XCTAssertTrue(peerStarted)
        let peerRequest = try XCTUnwrap(peerRunner.requests.first)
        XCTAssertTrue(peerRequest.prompt.contains(focusedPrompt))
        XCTAssertFalse(
            peerRequest.prompt.contains("com base na resposta"),
            "only the AI-authored focused prompt may enter the peer run"
        )
        XCTAssertTrue(peerRunner.finish(
            runID: peerRequest.runId,
            status: .completed,
            reply: "Meu nome atual é Quinn."
        ))
        let result = try await ask.value
        XCTAssertEqual(result.objectValue?["reply"]?.stringValue, "Meu nome atual é Quinn.")

        _ = try router.invokeDelegatedBotSelfConfig(
            callerThread: threadId,
            callerRun: hostRequest.runId,
            toolName: BotSelfConfigCatalog.setSettings,
            arguments: ["name": .string("Nova")]
        )
        XCTAssertEqual(try ctx.botStore.get(id: quinn.id)?.name, "Nova")
        XCTAssertEqual(try ctx.botStore.get(id: untouched.id)?.name, "Untouched")

        XCTAssertTrue(hostRunner.finish(
            runID: hostRequest.runId,
            status: .completed,
            reply: "Nome aplicado: Nova."
        ))

        let completed = await waitUntil(timeout: 5) {
            botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).first?.phase == .completed
                && surface.viewModel.status == .completed
        }
        XCTAssertTrue(completed)

        let handoff = try XCTUnwrap(botsVM.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: threadId
        ).first)
        XCTAssertEqual(
            handoff.outboundText,
            focusedPrompt,
            "Bots must show the exact prompt authored by the primary AI"
        )
        XCTAssertEqual(handoff.hostInstructionText, focusedPrompt)
        let hostRunID = try XCTUnwrap(handoff.hostRunID)
        XCTAssertEqual(handoff.hostThreadID, threadId)
        XCTAssertEqual(hostRunID, hostRequest.runId)
        XCTAssertEqual(try ctx.runRepo.get(id: hostRunID)?.status, .completed)
        XCTAssertNil(router.lastAgentAppHopTextForTesting, "the current primary run continues without a synthetic host hop")

        let stored = try ctx.messageRepo.listRecent(threadId: threadId, limit: 16)
        XCTAssertEqual(stored.filter { $0.role == .user && $0.content == prompt }.count, 1)
        let assistantRows = stored.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.filter { BotPeerTranscript.parse($0.content) != nil }.count, 1)
        XCTAssertEqual(assistantRows.filter { BotPeerTranscript.parse($0.content) == nil }.count, 1)
        XCTAssertEqual(hostRunner.requests.count, 1)

        XCTAssertThrowsError(
            try router.invokeDelegatedBotSelfConfig(
                callerThread: threadId,
                callerRun: hostRequest.runId,
                toolName: BotSelfConfigCatalog.setSettings,
                arguments: ["name": .string("Too Late")]
            ),
            "the delegated settings grant must expire with the primary run"
        )
        XCTAssertEqual(try ctx.botStore.get(id: quinn.id)?.name, "Nova")
    }

    func test_agentAppPrimaryCanMediateMultipleBotsUntilConsensus() async throws {
        // WHY: a compound request belongs to one primary AI turn. Mentions
        // identify the peers, while that same active run authors each focused
        // consultation, carries opposing replies between them, and owns the
        // single consensus shown after the debate.
        let (router, botsVM, surface, _, threadId, ctx) = try makeWiredMentionSurface(
            peerReply: "unused controlled debate reply"
        )
        let phpHater = try botsVM.create(
            name: "PHP Hater",
            title: "PHP Critic",
            handle: "php-hater",
            provider: .claude
        )
        let phpLover = try botsVM.create(
            name: "PHP Lover",
            title: "PHP Advocate",
            handle: "php-lover",
            provider: .grok
        )
        surface.viewModel.mentionableBotsProvider = { [phpHater, phpLover] }
        let haterRunner = ControlledBotHandoffRunner(provider: .claude)
        let loverRunner = ControlledBotHandoffRunner(provider: .grok)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.claude, runner: haterRunner)
        ctx.coordinator.replaceProvider(.grok, runner: loverRunner)
        ctx.coordinator.replaceProvider(.codex, runner: hostRunner)

        let original = "Peça ao @php-hater e ao @php-lover para debater se devemos adotar PHP no novo serviço. Consulte os dois mais de uma vez, encaminhe a resposta relevante de um ao outro em cada rodada, continue no mesmo turno até conciliarem riscos e benefícios e publique uma única conclusão de consenso em português."
        XCTAssertEqual(
            BotMentionParser.mentionedBots(
                in: original,
                bots: surface.viewModel.mentionableBotsProvider(),
                excluding: nil
            ).map(\.id),
            [phpHater.id, phpLover.id],
            "both @handles must resolve as identity before the primary provider interprets the request"
        )
        surface.viewModel.prompt = original
        await surface.viewModel.send()

        let hostStarted = await waitUntil(timeout: 5) { hostRunner.requests.count == 1 }
        XCTAssertTrue(hostStarted)
        let hostRequest = try XCTUnwrap(hostRunner.requests.first)
        XCTAssertEqual(hostRequest.prompt, original, "the complete compound request belongs to the primary run")
        XCTAssertEqual(
            hostRequest.environment[BotPeerDelegation.turnContextEnvironmentKey],
            BotPeerDelegation.turnDirective(mentionedBots: [phpHater, phpLover]),
            "mentions must travel as identity metadata, not app-authored delegation"
        )
        XCTAssertEqual(ctx.coordinator.activeRunId(threadId: threadId), hostRequest.runId)
        XCTAssertTrue(haterRunner.requests.isEmpty)
        XCTAssertTrue(loverRunner.requests.isEmpty)
        XCTAssertTrue(botsVM.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: threadId
        ).isEmpty, "identity-only mentions must not trigger legacy direct routing")

        let haterOpeningPrompt = "Liste os dois maiores riscos técnicos de adotar PHP neste serviço e proponha critérios objetivos para mitigá-los."
        let haterOpeningReply = "Os maiores riscos são dívida de tipagem e variação de qualidade; mitigue com análise estática estrita e padrões revisados."
        let askHaterOpening = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: threadId,
                callerRun: hostRequest.runId,
                handle: "@\(phpHater.handle)",
                prompt: haterOpeningPrompt,
                replyMode: .consult
            )
        }
        let haterOpeningStarted = await waitUntil(timeout: 5) { haterRunner.requests.count == 1 }
        XCTAssertTrue(haterOpeningStarted)
        let haterOpeningRequest = try XCTUnwrap(haterRunner.requests.first)
        XCTAssertTrue(haterOpeningRequest.prompt.contains(haterOpeningPrompt))
        XCTAssertFalse(haterOpeningRequest.prompt.contains(original))
        XCTAssertNotEqual(haterOpeningRequest.runId, hostRequest.runId)
        XCTAssertEqual(ctx.coordinator.activeRunId(threadId: threadId), hostRequest.runId)
        XCTAssertTrue(haterRunner.finish(
            runID: haterOpeningRequest.runId,
            status: .completed,
            reply: haterOpeningReply
        ))
        let haterOpeningResult = try await askHaterOpening.value
        XCTAssertEqual(haterOpeningResult.objectValue?["reply"]?.stringValue, haterOpeningReply)
        XCTAssertEqual(haterOpeningResult.objectValue?["reply_mode"]?.stringValue, "consult")
        XCTAssertEqual(
            haterOpeningResult.objectValue?["bot"]?.objectValue?["id"]?.stringValue,
            phpHater.id.value.uuidString.lowercased()
        )
        XCTAssertEqual(
            haterOpeningResult.objectValue?["bot"]?.objectValue?["handle"]?.stringValue,
            phpHater.handle
        )

        let loverOpeningPrompt = "O crítico respondeu: \"\(haterOpeningReply)\" Explique os benefícios concretos de PHP e responda diretamente a esses riscos."
        let loverOpeningReply = "PHP acelera a entrega e tem ecossistema maduro; aceito análise estática estrita e padrões revisados como requisitos."
        let askLoverOpening = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: threadId,
                callerRun: hostRequest.runId,
                handle: phpLover.handle,
                prompt: loverOpeningPrompt,
                replyMode: .consult
            )
        }
        let loverOpeningStarted = await waitUntil(timeout: 5) { loverRunner.requests.count == 1 }
        XCTAssertTrue(loverOpeningStarted)
        let loverOpeningRequest = try XCTUnwrap(loverRunner.requests.first)
        XCTAssertTrue(loverOpeningRequest.prompt.contains(loverOpeningPrompt))
        XCTAssertFalse(loverOpeningRequest.prompt.contains(original))
        XCTAssertNotEqual(loverOpeningRequest.runId, hostRequest.runId)
        XCTAssertEqual(ctx.coordinator.activeRunId(threadId: threadId), hostRequest.runId)
        XCTAssertTrue(loverRunner.finish(
            runID: loverOpeningRequest.runId,
            status: .completed,
            reply: loverOpeningReply
        ))
        let loverOpeningResult = try await askLoverOpening.value
        XCTAssertEqual(loverOpeningResult.objectValue?["reply"]?.stringValue, loverOpeningReply)
        XCTAssertEqual(loverOpeningResult.objectValue?["reply_mode"]?.stringValue, "consult")
        XCTAssertEqual(
            loverOpeningResult.objectValue?["bot"]?.objectValue?["id"]?.stringValue,
            phpLover.id.value.uuidString.lowercased()
        )
        XCTAssertEqual(
            loverOpeningResult.objectValue?["bot"]?.objectValue?["handle"]?.stringValue,
            phpLover.handle
        )

        let haterFollowUpPrompt = "O defensor respondeu: \"\(loverOpeningReply)\" Revise sua posição e proponha as condições finais para aceitar PHP."
        let haterFollowUpReply = "Aceito PHP se análise estática estrita, padrões revisados e monitoramento de produção forem gates obrigatórios."
        let askHaterFollowUp = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: threadId,
                callerRun: hostRequest.runId,
                handle: phpHater.handle,
                prompt: haterFollowUpPrompt,
                replyMode: .consult
            )
        }
        let haterFollowUpStarted = await waitUntil(timeout: 5) { haterRunner.requests.count == 2 }
        XCTAssertTrue(haterFollowUpStarted)
        let haterFollowUpRequest = try XCTUnwrap(haterRunner.requests.last)
        XCTAssertTrue(haterFollowUpRequest.prompt.contains(haterFollowUpPrompt))
        XCTAssertFalse(haterFollowUpRequest.prompt.contains(original))
        XCTAssertNotEqual(haterFollowUpRequest.runId, hostRequest.runId)
        XCTAssertEqual(ctx.coordinator.activeRunId(threadId: threadId), hostRequest.runId)
        XCTAssertTrue(haterRunner.finish(
            runID: haterFollowUpRequest.runId,
            status: .completed,
            reply: haterFollowUpReply
        ))
        let haterFollowUpResult = try await askHaterFollowUp.value
        XCTAssertEqual(haterFollowUpResult.objectValue?["reply"]?.stringValue, haterFollowUpReply)
        XCTAssertEqual(haterFollowUpResult.objectValue?["reply_mode"]?.stringValue, "consult")

        let loverFollowUpPrompt = "O crítico agora aceita nestas condições: \"\(haterFollowUpReply)\" Confirme quais aceita e formule um consenso curto."
        let loverFollowUpReply = "Concordo com os três gates e com uma adoção gradual; esse é o nosso consenso."
        let askLoverFollowUp = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: threadId,
                callerRun: hostRequest.runId,
                handle: "@\(phpLover.handle)",
                prompt: loverFollowUpPrompt,
                replyMode: .consult
            )
        }
        let loverFollowUpStarted = await waitUntil(timeout: 5) { loverRunner.requests.count == 2 }
        XCTAssertTrue(loverFollowUpStarted)
        let loverFollowUpRequest = try XCTUnwrap(loverRunner.requests.last)
        XCTAssertTrue(loverFollowUpRequest.prompt.contains(loverFollowUpPrompt))
        XCTAssertFalse(loverFollowUpRequest.prompt.contains(original))
        XCTAssertNotEqual(loverFollowUpRequest.runId, hostRequest.runId)
        XCTAssertEqual(ctx.coordinator.activeRunId(threadId: threadId), hostRequest.runId)
        XCTAssertTrue(loverRunner.finish(
            runID: loverFollowUpRequest.runId,
            status: .completed,
            reply: loverFollowUpReply
        ))
        let loverFollowUpResult = try await askLoverFollowUp.value
        XCTAssertEqual(loverFollowUpResult.objectValue?["reply"]?.stringValue, loverFollowUpReply)
        XCTAssertEqual(loverFollowUpResult.objectValue?["reply_mode"]?.stringValue, "consult")

        let focusedPrompts = [
            haterOpeningPrompt,
            loverOpeningPrompt,
            haterFollowUpPrompt,
            loverFollowUpPrompt,
        ]
        let peerReplies = [
            haterOpeningReply,
            loverOpeningReply,
            haterFollowUpReply,
            loverFollowUpReply,
        ]
        let handoffs = botsVM.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: threadId
        )
        XCTAssertEqual(handoffs.count, 4, "two peers consulted twice must produce four independent handoffs")
        XCTAssertEqual(Set(handoffs.map(\.outboundText)), Set(focusedPrompts))
        XCTAssertTrue(handoffs.allSatisfy { $0.hostInstructionText == $0.outboundText })
        XCTAssertTrue(handoffs.allSatisfy { !$0.outboundText.contains(original) })
        XCTAssertTrue(handoffs.allSatisfy { $0.hostThreadID == threadId })
        XCTAssertTrue(handoffs.allSatisfy { $0.hostRunID == hostRequest.runId })
        XCTAssertEqual(handoffs.filter { $0.peerBotID == phpHater.id }.count, 2)
        XCTAssertEqual(handoffs.filter { $0.peerBotID == phpLover.id }.count, 2)
        XCTAssertEqual(Set(handoffs.map(\.activityID)).count, 4)
        XCTAssertEqual(Set(handoffs.compactMap(\.peerRunID)).count, 4)
        XCTAssertEqual(haterRunner.requests.count, 2)
        XCTAssertEqual(loverRunner.requests.count, 2)
        XCTAssertTrue((haterRunner.requests + loverRunner.requests).allSatisfy {
            !$0.prompt.contains(original)
        }, "no peer provider may receive the complete user request")
        let importedReplies = try handoffs.map { handoff in
            let message = try XCTUnwrap(try ctx.messageRepo.get(
                id: AgentMessageID(handoff.inboundMessageID)
            ))
            return try XCTUnwrap(BotPeerTranscript.parse(message.content)?.body)
        }
        XCTAssertEqual(Set(importedReplies), Set(peerReplies))
        XCTAssertEqual(ctx.coordinator.activeRunId(threadId: threadId), hostRequest.runId)
        XCTAssertEqual(hostRunner.requests.count, 1, "all consultations must remain inside one primary run")

        let consensus = "Consenso: adotar PHP gradualmente, com análise estática estrita, padrões revisados e monitoramento de produção como gates obrigatórios."
        XCTAssertTrue(hostRunner.finish(
            runID: hostRequest.runId,
            status: .completed,
            reply: consensus
        ))
        let completed = await waitUntil(timeout: 5) {
            surface.viewModel.status == .completed
                && ctx.coordinator.activeRunId(threadId: threadId) == nil
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(try ctx.runRepo.get(id: hostRequest.runId)?.status, .completed)

        let stored = try ctx.messageRepo.listRecent(threadId: threadId, limit: 32)
        XCTAssertEqual(stored.filter { $0.role == .user && $0.content == original }.count, 1)
        let assistantRows = stored.filter { $0.role == .assistant }
        let attributedReplies = assistantRows.compactMap { BotPeerTranscript.parse($0.content) }
        XCTAssertEqual(attributedReplies.count, 4)
        XCTAssertEqual(Set(attributedReplies.map(\.body)), Set(peerReplies))
        let primaryFinals = assistantRows.filter { BotPeerTranscript.parse($0.content) == nil }
        XCTAssertEqual(primaryFinals.count, 1, "the primary must publish one consensus after all consultations")
        XCTAssertEqual(primaryFinals.first?.content, consensus)
        XCTAssertEqual(hostRunner.requests.count, 1)
    }

    func test_replyOnlyDelegationKeepsOneAttributedReplyAndSuppressesPrimaryDuplicate() async throws {
        // WHY: the AI may decide the whole turn belongs to the named Bot. Once
        // it chooses reply_only, RemoteCode must enforce one visible answer even
        // if the primary provider also emits generic final prose.
        let (router, botsVM, surface, quinn, threadId, ctx) = try makeWiredMentionSurface(
            peerReply: "unused controlled reply"
        )
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProvider(.claude, runner: peerRunner)
        ctx.coordinator.replaceProvider(.codex, runner: hostRunner)

        let original = "@\(quinn.handle) você está por aí?"
        surface.viewModel.prompt = original
        await surface.viewModel.send()
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let hostRequest = try XCTUnwrap(hostRunner.requests.first)
        XCTAssertEqual(hostRequest.prompt, original)

        let focused = "Você está por aí?"
        let ask = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: threadId,
                callerRun: hostRequest.runId,
                handle: quinn.handle,
                prompt: focused,
                replyMode: .replyOnly
            )
        }
        let peerStarted = await waitUntil(timeout: 5) { !peerRunner.requests.isEmpty }
        XCTAssertTrue(peerStarted)
        let peerRequest = try XCTUnwrap(peerRunner.requests.first)
        XCTAssertTrue(peerRequest.prompt.contains(focused))
        XCTAssertTrue(peerRunner.finish(
            runID: peerRequest.runId,
            status: .completed,
            reply: "Estou por aqui — manda o próximo."
        ))
        _ = try await ask.value

        let duplicate = "Sim, estou por aqui. Como posso ajudar?"
        XCTAssertTrue(hostRunner.finish(
            runID: hostRequest.runId,
            status: .completed,
            reply: duplicate
        ))
        let completed = await waitUntil(timeout: 5) {
            botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            ).first?.phase == .completed
                && ctx.coordinator.activeRunId(threadId: threadId) == nil
        }
        XCTAssertTrue(completed)

        let stored = try ctx.messageRepo.listRecent(threadId: threadId, limit: 16)
        let assistantRows = stored.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.count, 1)
        XCTAssertEqual(
            BotPeerTranscript.parse(try XCTUnwrap(assistantRows.first).content)?.body,
            "Estou por aqui — manda o próximo."
        )
        XCTAssertFalse(stored.contains { $0.content.contains(duplicate) })
        XCTAssertFalse(
            surface.viewModel.timeline.turns
                .flatMap(\.items)
                .contains { $0.body.contains(duplicate) || ($0.output?.contains(duplicate) == true) },
            "the suppressed primary reply must not linger in live Work UI"
        )
    }

    func test_agentAppWaitingBotActivityMarksWorkspaceBusyUntilReply() throws {
        // WHY: a workspace is still doing work while its Agent App is waiting
        // for a mentioned bot, even though the active provider run belongs to
        // the bot's workspace-less conversation.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2AgentMentionBusy-\(UUID().uuidString)", isDirectory: true)
        let workspaceDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "consultation-busy", cwd: workspaceDirectory.path)
        let descriptor = try router.createSurface(
            workspace: workspace.id,
            type: .agentApp,
            paneID: nil,
            title: "Agent App"
        )
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Ask Bot",
            provider: .codex,
            model: "fake-model",
            permissionMode: .fullAccess,
            reasoningEffort: .medium
        )
        surface.viewModel.selectThread(thread.id)
        let bot = BotDefinition(handle: "bot", name: "Bot", title: "", description: "")
        let activityID = try XCTUnwrap(surface.viewModel.presentBotPeerActivity(
            peer: bot,
            phase: .waiting,
            threadId: thread.id
        ))

        XCTAssertTrue(surface.isBusy)
        XCTAssertTrue(router.isWorkspaceBusy(workspace.id))
        let sidebar = SidebarViewModel(context: ctx, router: router)
        let sidebarWorkspace = try XCTUnwrap(sidebar.workspaces.first { $0.id == workspace.id })
        XCTAssertTrue(sidebar.isWorkspaceBusy(sidebarWorkspace))

        _ = surface.viewModel.presentBotPeerMessage(
            peer: bot,
            text: "My name is Bot.",
            threadId: thread.id,
            replacing: activityID
        )
        XCTAssertFalse(surface.isBusy)
        XCTAssertFalse(router.isWorkspaceBusy(workspace.id))
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
                onto: surface,
                continueHost: true
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
        XCTAssertNotEqual(
            try context.runRepo.get(id: peerRunID)?.status,
            .completed,
            "the pending peer must remain owned by the context after the initiating window deallocates"
        )

        XCTAssertTrue(peerRunner.finish(
            runID: peerRunID,
            status: .completed,
            reply: "EXACT_AGENT_WEAK_REPLY"
        ))
        let hostStarted = await waitUntil(timeout: 5) {
            hostRunner.requests.contains { $0.runId == hostRunID }
        }
        XCTAssertTrue(hostStarted)
        XCTAssertNil(
            hostRunner.requests.first { $0.runId == hostRunID }?
                .environment[BotSelfConfigCatalog.callerEnvironmentKey],
            "legacy synthetic continuations must not impersonate the consulted Bot; current product consultations use the exact active primary run's MCP grant"
        )
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
            onto: surface,
            continueHost: true
        )
        let hop = try XCTUnwrap(router.lastAgentAppHopTextForTesting)
        XCTAssertEqual(
            hop,
            BotPeerTranscript.hostHopPrompt(
                peerName: quinn.name,
                reply: "inbox is clear",
                userText: "@\(quinn.handle) what is in the inbox?"
            )
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
                onto: surface,
                continueHost: true
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
            onto: surface,
            continueHost: true
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
                onto: surface,
                continueHost: true
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

    func test_relaunchWithIntentionalPeerOnlyHandoffCompletesWithoutInventingAHost() async throws {
        // WHY: direct @bot sends intentionally have no host continuation. If
        // RemoteCode relaunches after the peer finished, recovery must keep the
        // single peer reply complete instead of turning it into Needs Attention.
        let seed = try await makeRestoredQueuedHostSeed(
            prompt: "PEER_ONLY_RESTORE",
            reply: "peer-only restored reply"
        )
        let handoff = seed.handoff
        let crashHandoffs = try removingPersistedHostBinding(
            from: seed.rawHandoffs,
            activityID: handoff.activityID,
            hostContinuationRequired: false
        )
        let fresh = try makeFreshRestoredHandoffContext(
            rawHandoffs: crashHandoffs,
            sourceThread: seed.thread,
            queued: nil
        )
        defer { try? FileManager.default.removeItem(at: fresh.root) }
        fresh.context.router = fresh.router

        let reopened = BotsViewModel(context: fresh.context, router: fresh.router)
        reopened.reconcilePeerHandoffsForTesting()
        let restored = try XCTUnwrap(reopened.peerHandoffSnapshotsForTesting(
            originConversationID: nil,
            originThreadID: seed.thread.id
        ).first)
        XCTAssertEqual(restored.phase, .completed)
        XCTAssertNil(restored.hostThreadID)
        XCTAssertNil(restored.hostRunID)
        XCTAssertEqual(
            BotPeerTranscript.parse(try XCTUnwrap(try fresh.context.messageRepo.get(
                id: AgentMessageID(handoff.inboundMessageID)
            )).content)?.body,
            "peer-only restored reply"
        )
        XCTAssertTrue(fresh.hostRunner.requests.isEmpty)
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
                onto: surface,
                continueHost: true
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
                onto: surface,
                continueHost: true
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
        let allCancellationWorkSettled = await waitUntil(timeout: 2) {
            let snapshots = botsVM.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: threadId
            )
            return snapshots.count == 2
                && snapshots.allSatisfy { $0.phase == .needsAttention }
                && (try? ctx.runRepo.get(id: occupyingRunID)?.status) == .cancelled
                && (try? ctx.queuedMessageRepo.get(id: queuedB)) == nil
        }
        XCTAssertTrue(
            allCancellationWorkSettled,
            "the test must not leak queue or handoff settlement into the next isolated context"
        )
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
                onto: surface,
                continueHost: true
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
        XCTAssertEqual(parsedReply.caption, "From Quinn")
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

    func test_agentAppPeerActivityReconcilesDurableReplyWhenLiveProjectionIsMissed() async throws {
        // WHY: the provider may finish in another app process, or the live
        // surface registry notification may be missed. A durable reply must
        // replace the visible waiting row without requiring a thread switch.
        let dir = NSTemporaryDirectory() + "RC2AgentPeerReconcile-" + UUID().uuidString
        let workspaceID = WorkspaceID()
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let writerContext = try AppContext(channel: .debug, appSupportOverride: dir)
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
        surface.viewModel.botPeerReconciliationIntervalNanoseconds = 10_000_000
        surface.viewModel.createThread(title: "Missed peer projection")
        let threadID = try XCTUnwrap(surface.viewModel.selectedThreadId)
        let activityID = AgentMessageID()
        let waiting = AgentMessage(
            id: activityID,
            threadId: threadID,
            role: .assistant,
            content: BotPeerTranscript.encodeActivity(peer: quinn, phase: .waiting)
        )
        try writerContext.messageRepo.append(waiting)
        surface.viewModel.applyPersistedBotPeerMessage(messageID: activityID, threadId: threadID)
        XCTAssertEqual(
            surface.viewModel.messages.first.flatMap { BotPeerTranscript.parseActivity($0.content)?.phase },
            .waiting,
            "the visible surface must receive the waiting row through the persisted projection path"
        )

        try writerContext.messageRepo.append(AgentMessage(
            id: activityID,
            threadId: threadID,
            role: .assistant,
            content: BotPeerTranscript.encode(peer: quinn, text: "Durable reply arrived."),
            createdAt: waiting.createdAt
        ))
        var completedThread = try XCTUnwrap(try writerContext.threadRepo.get(id: threadID))
        completedThread.status = .completed
        try writerContext.threadRepo.upsert(completedThread)
        XCTAssertEqual(
            surface.viewModel.messages.first.flatMap { BotPeerTranscript.parseActivity($0.content)?.phase },
            .waiting,
            "the test must reproduce a durable write whose live projection was missed"
        )

        let reconciled = await waitUntil(timeout: 1) {
            surface.viewModel.messages.first.flatMap {
                BotPeerTranscript.parse($0.content)?.body
            } == "Durable reply arrived."
                && surface.viewModel.status == .completed
        }

        XCTAssertTrue(reconciled)
        XCTAssertEqual(surface.viewModel.messages.count, 1)
        XCTAssertEqual(surface.viewModel.messages.first?.id, activityID)
        XCTAssertEqual(surface.viewModel.status, .completed)
        XCTAssertEqual(
            surface.viewModel.messages.first.flatMap { BotPeerTranscript.parse($0.content)?.body },
            "Durable reply arrived."
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
                onto: surface,
                continueHost: true
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
                onto: surface,
                continueHost: true
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
        activityID: UUID,
        hostContinuationRequired: Bool? = nil
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
            if let hostContinuationRequired {
                record["hostContinuationRequired"] = hostContinuationRequired
            }
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
