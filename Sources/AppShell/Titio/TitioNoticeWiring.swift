import AgentRuntime
import AppKit
import CoreModel
import Foundation
import Persistence
import SocketServer
import Surfaces

/// Weak link from the notice hub's hooks to the app context (set once the
/// router is attached, so the hub never keeps the context alive).
final class TitioNoticeContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: AppContext?

    var context: AppContext? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The §16 language input: the newest user message in any Titio
/// conversation, read off the MainActor and cached briefly.
final class TitioLanguageInputCache: @unchecked Sendable {
    static let lifetime: TimeInterval = 30
    private let lock = NSLock()
    private var cached: (text: String?, at: Date)?
    private let botStore: BotStore
    private let messageRepo: AgentMessageRepository

    init(botStore: BotStore, messageRepo: AgentMessageRepository) {
        self.botStore = botStore
        self.messageRepo = messageRepo
    }

    func invalidate() {
        lock.withLock { cached = nil }
    }

    func lastUserText(now: Date = Date()) -> String? {
        if let cached = lock.withLock({ cached }), now.timeIntervalSince(cached.at) < Self.lifetime {
            return cached.text
        }
        let text = readLastUserText()
        lock.withLock { cached = (text, now) }
        return text
    }

    private func readLastUserText() -> String? {
        guard let titio = (try? botStore.list(includeHidden: true))?
            .first(where: { $0.handle.lowercased() == TitioBot.handle && $0.deletedAt == nil }),
              let conversations = try? botStore.listConversations(botID: titio.id) else { return nil }
        var newest: AgentMessage?
        for thread in Set(conversations.compactMap(\.linkedAgentThreadID)) {
            guard let recent = try? messageRepo.listRecent(threadId: thread, limit: 30),
                  let user = recent.last(where: { $0.role == .user }) else { continue }
            if newest.map({ user.createdAt > $0.createdAt }) ?? true { newest = user }
        }
        return newest?.content
    }
}

extension AppContext {
    /// Production hooks for `TitioNoticeCenter`. Ledger, message and store
    /// work stays on the hub's actor; only the desk/state reads hop to the
    /// MainActor.
    nonisolated static func makeTitioNoticeHooks(
        box: TitioNoticeContextBox,
        db: SQLiteDB,
        botStore: BotStore,
        messageRepo: AgentMessageRepository,
        runRepo: AgentRunRepository,
        bridge: PrivateNotificationBridge,
        hostID: String
    ) -> TitioNoticeHooks {
        let language = TitioLanguageInputCache(botStore: botStore, messageRepo: messageRepo)
        let bindings = BotAttentionPushBindingStore(db: db)
        let settings = SettingsStore(db: db)
        return TitioNoticeHooks(
            resolveInbox: { lang in
                await MainActor.run { box.context?.router?.resolveTitioInbox(language: lang) }
            },
            isInboxViewed: { target in
                await MainActor.run { box.context?.router?.isTitioInboxViewed(target.conversationID) ?? false }
            },
            isTitioRunActive: { target in
                ((try? runRepo.latestActive(for: target.threadID)) ?? nil) != nil
            },
            languageInputs: {
                TitioNoticeLanguageInputs(
                    lastUserText: language.lastUserText(),
                    preferredLanguages: Locale.preferredLanguages
                )
            },
            messagePosted: { posted in
                EventBus.shared.publish(
                    kind: .agentMessageAppended,
                    payload: AgentMessageTransport.appendedEventPayload(from: posted.message, bodyRevision: posted.bodyRevision)
                )
                await MainActor.run {
                    guard let router = box.context?.router else { return }
                    router.botsViewModel?.appendHostAssistantMessage(
                        botID: posted.target.botID,
                        conversationID: posted.target.conversationID,
                        message: posted.message,
                        conversation: posted.conversation
                    )
                    router.projectTitioInboxMessage(posted.message)
                }
            },
            inboxChanged: { snapshot in
                EventBus.shared.publish(kind: .botUpdated, payload: .object([
                    "method": .string("bot.titio_inbox"),
                    "reason": .string("titio_inbox"),
                    "bot_id": .string(snapshot.botID.value.uuidString.lowercased()),
                    "titio_inbox": snapshot.wireObject,
                ]))
            },
            postBanner: { content in
                SystemNotifier.shared.post(content, settings: settings.load())
            },
            deliverPush: { content in
                await bridge.deliver(content)
            },
            pushBinding: {
                TitioNoticePushBinding(profileID: bindings.unique(hostID: hostID)?.profileID, hostID: hostID)
            },
            workspaceName: { workspaceID in
                await MainActor.run { box.context?.state.workspaces[workspaceID]?.name }
            },
            isFocusedSuccess: { event in
                await MainActor.run { box.context?.router?.isFocusedPetSuccess(event) ?? false }
            }
        )
    }

    /// Production host side effects of card actions (§7 step 4). The pending
    /// request check reads SQLite on the hub's actor; router and Bots calls
    /// hop to the MainActor where those APIs live.
    nonisolated static func makeTitioNoticeActionHooks(
        box: TitioNoticeContextBox,
        db: SQLiteDB,
        botStore: BotStore
    ) -> TitioNoticeActionHooks {
        let pending = ProviderPendingCallbackRepository(db: db)
        @Sendable func router() async throws -> AppCommandRouter {
            guard let router = await MainActor.run(body: { box.context?.router }) else {
                throw TitioNoticeActionError(reason: "RemoteCode is not ready")
            }
            return router
        }
        return TitioNoticeActionHooks(
            isRequestOpen: { thread, request, kind in
                // No recorded callback (its write failed): let the provider decide.
                guard let row = (try? pending.get(
                    threadId: thread, requestId: request, kind: kind == .approval ? .approval : .userInput
                )) ?? nil else { return true }
                return row.state == .pending
            },
            respondRequest: { thread, request, decision in
                let response: AgentProviderRequestResponse
                switch decision {
                case .approve: response = .approve
                case .approveForSession: response = .approveForSession
                case .decline: response = .decline(nil)
                }
                try await router().respondAgentRequest(thread: thread, requestId: request, response: response)
            },
            respondUserInput: { thread, request, text in
                try await router().respondAgentUserInput(thread: thread, requestId: request, text: text)
            },
            sendBotMessage: { bot, conversation, text in
                let router = try await router()
                try await MainActor.run {
                    guard let vm = router.botsViewModel else {
                        throw TitioNoticeActionError(reason: "the Bot runtime is unavailable")
                    }
                    _ = try vm.enqueueHostMessage(botID: bot, text: text, conversationID: conversation)
                }
            },
            acknowledgeBotAttention: { item in
                try botStore.acknowledgeAttention(id: item)
                await MainActor.run {
                    box.context?.router?.botsViewModel?.noteAttentionAcknowledged(item)
                    BotsViewModel.publishDestAttentionChanged()
                }
            },
            continueRun: { thread in
                _ = try await router().continueAgentRun(thread: thread)
            },
            rerunScheduledTask: { task in
                let router = try await router()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task { @MainActor in
                        guard let scheduler = router.scheduledTaskScheduler else {
                            continuation.resume(throwing: TitioNoticeActionError(reason: "scheduled tasks are not running"))
                            return
                        }
                        scheduler.runNow(taskID: task) { continuation.resume(with: $0) }
                    }
                }
            },
            acknowledgeActivity: { item in
                let router = try await router()
                _ = try await MainActor.run { try router.activityAcknowledge(params: ["item_id": .string(item)]) }
            }
        )
    }

    /// Facts a run-terminal notice needs beyond the legacy inputs (§5).
    struct TitioRunFacts: Sendable {
        /// The Bot conversation this thread belongs to, if any.
        let botConversation: BotConversation?
        let bot: BotDefinition?
        let summary: String?
        let durationMs: Int?
        /// Titio's reply text for the direct reply banner.
        let finalMessageText: String?
    }

    nonisolated static func titioRunFacts(
        runId: AgentRunID,
        threadId: AgentThreadID,
        finalMessageId: String?,
        db: SQLiteDB,
        botStore: BotStore,
        runRepo: AgentRunRepository
    ) -> TitioRunFacts {
        let conversation = (try? botStore.conversationLinked(to: threadId)) ?? nil
        let bot = conversation.flatMap { (try? botStore.get(id: $0.botID)) ?? nil }
        let result = (try? AgentRunResultRepository(db: db).get(runId: runId)) ?? nil
        let run = (try? runRepo.get(id: runId)) ?? nil
        let durationMs = run.flatMap { run -> Int? in
            guard let finished = run.finishedAt else { return nil }
            return max(0, Int(finished.timeIntervalSince(run.startedAt) * 1_000))
        }
        var finalText: String?
        if bot?.handle.lowercased() == TitioBot.handle,
           let finalMessageId, let uuid = UUID(uuidString: finalMessageId) {
            finalText = (try? AgentMessageRepository(db: db).get(id: AgentMessageID(uuid)))??.content
        }
        return TitioRunFacts(
            botConversation: conversation,
            bot: bot,
            summary: result?.summary,
            durationMs: durationMs,
            finalMessageText: finalText
        )
    }

    /// Run outcomes (§2, §5). Returns true when the hub took the notice (or
    /// deliberately produced nothing); false keeps today's banner code.
    /// Policy checks (muted workspace, toggles, nested worker, side thread,
    /// user stop, pausedForUser) already ran before this branch.
    func ingestTitioRunOutcome(
        threadId: AgentThreadID,
        runId: AgentRunID,
        status: AgentRunStatus,
        workspaceId: WorkspaceID?,
        threadTitle: String?,
        finalMessageId: String?,
        facts: TitioRunFacts,
        legacy: RemoteCodeNotificationContent
    ) -> Bool {
        let outcome: TitioNoticeIDs.RunOutcome
        let kind: TitioNoticeKind
        switch status {
        case .completed: outcome = .completed; kind = .runCompleted
        case .failed: outcome = .failed; kind = .runFailed
        case .interrupted: outcome = .interrupted; kind = .runInterrupted
        case .cancelled, .pending, .running: return false
        }
        let rid = runId.value.uuidString
        let tid = threadId.value.uuidString
        if let conversation = facts.botConversation, let bot = facts.bot {
            if bot.handle.lowercased() == TitioBot.handle {
                // Titio's own replies: a direct reply banner, never a notice.
                // Its failures keep today's banner.
                guard status == .completed else { return false }
                if let text = facts.finalMessageText {
                    titioNoticeCenter.postDirectReplyBanner(
                        botID: bot.id,
                        conversationID: conversation.id,
                        runID: runId,
                        text: text,
                        messageID: finalMessageId.flatMap(UUID.init(uuidString:)).map(AgentMessageID.init)
                    )
                }
                return true
            }
            // Bot failures come only from the bot-attention projector.
            guard status == .completed else { return true }
            guard bot.notificationsEnabled else { return true }
            if router?.isBotConversationFocused(conversation.id) == true { return true }
            let botFacts = TitioNoticeFacts(
                workspaceName: workspaceId.flatMap { state.workspaces[$0]?.name },
                botName: bot.name,
                summary: facts.summary
            )
            titioNoticeCenter.ingest(TitioNoticeFact(
                key: TitioNoticeIDs.botReply(runId: rid),
                kind: .botReply,
                source: TitioNoticeSource(
                    threadId: tid,
                    runId: rid,
                    workspaceId: workspaceId?.value.uuidString,
                    botId: bot.id.value.uuidString.lowercased(),
                    conversationId: conversation.id.value.uuidString.lowercased(),
                    finalMessageId: finalMessageId
                ),
                facts: botFacts
            ))
            return true
        }
        // Successes whose destination is focused are excluded; failures never are.
        if status == .completed, router?.isAgentThreadFocused(threadId) == true { return true }
        let noticeFacts = TitioNoticeFacts(
            title: threadTitle,
            workspaceName: workspaceId.flatMap { state.workspaces[$0]?.name },
            summary: facts.summary,
            durationMs: status == .completed ? facts.durationMs : nil
        )
        titioNoticeCenter.ingest(
            TitioNoticeFact(
                key: TitioNoticeIDs.runOutcome(runId: rid, outcome: outcome),
                kind: kind,
                source: TitioNoticeSource(
                    threadId: tid,
                    runId: rid,
                    workspaceId: workspaceId?.value.uuidString,
                    activityItemId: "run:\(rid.lowercased())",
                    finalMessageId: finalMessageId
                ),
                facts: noticeFacts,
                actions: TitioNoticeAction.defaultActions(kind: kind, facts: noticeFacts)
            ),
            legacy: status == .completed ? nil : TitioNoticeLegacyDelivery(content: legacy, pushes: true)
        )
        return true
    }
}

/// What a request notice needs (§5 "Requests"): the real request fields that
/// `postAgentUserActionPushIfNeeded` used to discard.
struct TitioRequestFacts: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case approval, userInput, manualAction }

    var kind: Kind
    var requestTitle: String?
    var detail: String?
    var prompt: String?
    var options: [String]?
    var isSecret: Bool
    var questionCount: Int
    /// Manual actions: the Bot that asked.
    var botName: String?
    /// The exact `actionTitle` today's code passes (the kill-switch path).
    var legacyActionTitle: String
    /// False when the provider cannot approve for the session: the card then
    /// offers no "Approve for session".
    var allowsSessionApproval: Bool

    init(
        kind: Kind,
        legacyActionTitle: String,
        requestTitle: String? = nil,
        detail: String? = nil,
        prompt: String? = nil,
        options: [String]? = nil,
        isSecret: Bool = false,
        questionCount: Int = 0,
        botName: String? = nil,
        allowsSessionApproval: Bool = true
    ) {
        self.kind = kind
        self.requestTitle = requestTitle
        self.detail = detail
        self.prompt = prompt
        self.options = options
        self.isSecret = isSecret
        self.questionCount = questionCount
        self.botName = botName
        self.legacyActionTitle = legacyActionTitle
        self.allowsSessionApproval = allowsSessionApproval
    }

    /// The card for this request (§2), without "Approve for session" when the
    /// provider does not support it.
    func actions(facts: TitioNoticeFacts) -> [TitioNoticeAction]? {
        let actions = TitioNoticeAction.defaultActions(kind: noticeKind, facts: facts)
        guard !allowsSessionApproval else { return actions }
        return actions?.filter { $0 != .approveSession }
    }

    var noticeKind: TitioNoticeKind {
        switch kind {
        case .approval: return .approval
        case .userInput: return .userInput
        case .manualAction: return .manualAction
        }
    }

    func noticeFacts(threadTitle: String?, workspaceName: String?) -> TitioNoticeFacts {
        TitioNoticeFacts(
            title: threadTitle,
            workspaceName: workspaceName,
            botName: botName,
            detail: detail,
            requestTitle: requestTitle,
            prompt: prompt,
            options: options,
            isSecret: isSecret ? true : nil,
            questionCount: questionCount > 0 ? questionCount : nil
        )
    }
}

extension AppContext {
    /// Requests (§5): approvals, input questions and manual actions. True when
    /// the hub took it; a Titio-linked thread keeps today's banner (Titio's own
    /// threads never produce a notice). Runs after the policy checks.
    func ingestTitioRequest(
        threadId: AgentThreadID,
        runId: AgentRunID,
        requestId: String,
        facts: TitioRequestFacts,
        chrome: AgentThreadRepository.ListChrome?,
        legacy: RemoteCodeNotificationContent
    ) -> Bool {
        let conversation = (try? botStore.conversationLinked(to: threadId)) ?? nil
        var request = facts
        if let conversation, let bot = (try? botStore.get(id: conversation.botID)) ?? nil {
            if bot.handle.lowercased() == TitioBot.handle { return false }
            if request.botName == nil { request.botName = bot.name }
        }
        let tid = threadId.value.uuidString
        let noticeFacts = request.noticeFacts(
            threadTitle: chrome?.title,
            workspaceName: chrome?.workspaceId.flatMap { state.workspaces[$0]?.name }
        )
        titioNoticeCenter.ingest(
            TitioNoticeFact(
                key: TitioNoticeIDs.threadAttention(threadId: tid, requestId: requestId),
                kind: request.noticeKind,
                source: TitioNoticeSource(
                    threadId: tid,
                    runId: runId.value.uuidString,
                    requestId: requestId,
                    workspaceId: chrome?.workspaceId?.value.uuidString,
                    botId: conversation?.botID.value.uuidString.lowercased(),
                    conversationId: conversation?.id.value.uuidString.lowercased()
                ),
                facts: noticeFacts,
                actions: request.actions(facts: noticeFacts)
            ),
            legacy: TitioNoticeLegacyDelivery(content: legacy, pushes: true)
        )
        return true
    }
}

extension AppCommandRouter {
    /// Ensures Titio, its Notifications conversation and the linked thread
    /// (hub spec §8). Nil while the Bots view model is not up yet (launch):
    /// the hub keeps the rows pending and retries with backoff.
    func resolveTitioInbox(language: TitioNoticeLanguage) -> TitioInboxTarget? {
        guard let ctx = context, let vm = botsViewModel else { return nil }
        do {
            let bot = try TitioBot.ensure(store: ctx.botStore, appSupportDirectory: ctx.appSupportDirectory)
            let ensured = try TitioBot.ensureInboxConversation(
                store: ctx.botStore,
                notices: TitioNoticeRepository(db: ctx.db),
                bot: bot,
                language: language
            )
            let linked = try vm.ensureTitioInboxThread(bot: bot, conversation: ensured.conversation)
            vm.onTitioInboxSelected = { [weak ctx] _ in
                ctx?.titioNoticeCenter.markInboxRead()
                // The user is now reading the inbox: the pet stops talking over it.
                (NSApp?.delegate as? AppDelegate)?.petController?.reevaluateSpeech()
            }
            if ensured.created {
                EventBus.shared.publish(kind: .botConversationUpdated, payload: .object([
                    "method": .string("bot.conversation.create"),
                    "reason": .string("titio_inbox"),
                    "bot_id": .string(bot.id.value.uuidString.lowercased()),
                    "conversation_id": .string(linked.conversation.id.value.uuidString.lowercased()),
                ]))
            }
            return TitioInboxTarget(botID: bot.id, conversationID: linked.conversation.id, threadID: linked.thread.id)
        } catch {
            NSLog("RemoteCode: Titio inbox unavailable: \(error)")
            return nil
        }
    }

    /// A host-written inbox row (notice, act user row, result line, rewrite)
    /// repaints every open Agent App on that thread from the row itself,
    /// without reading SQLite on the MainActor.
    func projectTitioInboxMessage(_ message: AgentMessage) {
        botsViewModel?.deskAgentVM?.applyHostWrittenMessage(message)
        for surface in SurfaceRegistry.shared.all() {
            guard let agent = surface as? AgentAppSurface else { continue }
            agent.viewModel.applyHostWrittenMessage(message)
        }
    }

    /// The Mac desk shows the inbox and its window is key (§8 "viewing").
    func isTitioInboxViewed(_ conversationID: BotConversationID) -> Bool {
        guard let window = windowController?.window, window.isKeyWindow,
              NSApp?.isActive == true,
              windowController?.isShowingBotsContent == true,
              let vm = botsViewModel else { return false }
        return vm.isDeskShowing(conversationID: conversationID)
    }

    /// A Bot conversation the user is looking at on the Mac desk.
    func isBotConversationFocused(_ conversationID: BotConversationID) -> Bool {
        isTitioInboxViewed(conversationID)
    }

    /// A successful pet/terminal event whose destination is focused, by the
    /// same rule the pet uses (`PetAttentionFocusPolicy`, §2).
    func isFocusedPetSuccess(_ event: EventBus.Event) -> Bool {
        guard let ctx = context else { return false }
        let focusedSurfaceByWorkspace = ctx.state.workspaces.reduce(into: [WorkspaceID: SurfaceID]()) { result, entry in
            guard let paneID = entry.value.focusedPaneID,
                  let surfaceID = entry.value.layout.find(paneID: paneID)?.selectedSurfaceID else { return }
            result[entry.key] = surfaceID
        }
        let detached = Set(ctx.state.workspaces.keys.filter { windowController?.workspaceWindow(for: $0) != nil })
        let destination = PetAttentionFocusPolicy.resolveDestination(
            event: event,
            mainSelectedWorkspaceID: ctx.state.window.selectedWorkspaceID,
            focusedSurfaceByWorkspace: focusedSurfaceByWorkspace,
            detachedWorkspaceIDs: detached
        )
        let window = destination.detachedWorkspaceID.flatMap { windowController?.workspaceWindow(for: $0) }
            ?? windowController?.window
        return !PetAttentionFocusPolicy.shouldPersist(
            event: event,
            isAppActive: NSApp?.isActive == true,
            isDestinationWindowFocused: window?.isVisible == true && window?.isMiniaturized == false
                && window?.isKeyWindow == true,
            selectedWorkspaceID: destination.selectedWorkspaceID,
            focusedSurfaceID: destination.focusedSurfaceID
        )
    }

    /// The Agent App thread in the focused pane of the key main window (§2:
    /// a success there is not announced).
    func isAgentThreadFocused(_ threadID: AgentThreadID) -> Bool {
        guard let window = windowController?.window, window.isKeyWindow,
              NSApp?.isActive == true,
              windowController?.isShowingWorkspaceContent == true,
              let ctx = context,
              let workspaceID = ctx.state.window.selectedWorkspaceID,
              let workspace = ctx.state.workspaces[workspaceID],
              let pane = workspace.focusedPaneID,
              let surfaceID = workspace.layout.find(paneID: pane)?.selectedSurfaceID,
              let agent = SurfaceRegistry.shared.surface(surfaceID) as? AgentAppSurface else { return false }
        return agent.viewModel.selectedThreadId == threadID
    }
}
