import CoreModel
import Foundation
import Persistence
import Surfaces

extension AppCommandRouter {
    /// The live conversation behind an Activity item, pinned to its thread. It is shown
    /// without a composer: replies still go through the thread's own chat, which owns
    /// the provider, workspace and bot-desk wiring a send needs.
    func makeActivityConversation(_ item: ActivityWireItem) -> AgentAppViewModel? {
        guard let context, let threadID = item.thread_id.flatMap(UUID.init(uuidString:)).map(AgentThreadID.init),
              let thread = try? context.threadRepo.get(id: threadID) else { return nil }
        let viewModel = AgentAppViewModel(
            workspaceID: thread.workspaceId ?? BotsViewModel.botDeskWorkspaceID,
            cwd: thread.workspaceId.flatMap { context.state.workspaces[$0]?.cwd } ?? context.appSupportDirectory.path,
            coordinator: context.coordinator,
            threadRepo: context.threadRepo,
            messageRepo: context.messageRepo,
            // No draft repository: this host has no composer, and the unsent draft belongs to the real chat.
            attachmentStore: AgentAttachmentStore(
                root: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)
            ),
            queuedMessageRepo: context.queuedMessageRepo,
            providerSessionRepo: context.providerSessionRuntimeRepo,
            pendingCallbackRepo: context.providerPendingCallbackRepo,
            proposedPlanRepo: context.proposedPlanRepo,
            checkpointRepo: context.turnCheckpointRepo,
            promptHistoryStore: PromptHistoryStore(db: context.db),
            customModelStore: AgentCustomModelStore(repo: context.settingsRepo),
            planNotesStore: PlanNotesStore(db: context.db),
            initialThreadId: threadID,
            initialRoutingMode: .manual,
            orchestrationRuntime: context.orchestrationRuntime,
            embedding: AgentAppEmbedding(pinnedThreadId: threadID, pinnedThread: thread, ownsComposerDraft: false)
        )
        viewModel.botNameProvider = { [weak context] botID in
            (try? context?.botStore.get(id: botID))??.name
        }
        viewModel.markThreadRead = { [weak self] id in
            try self?.markAgentThreadRead(thread: id)
        }
        return viewModel
    }
}
