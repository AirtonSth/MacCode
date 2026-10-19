import CoreModel
import Foundation
import Persistence
import Surfaces

/// The live conversation shown in Activity's detail pane.
@MainActor
final class ActivityConversation {
    let viewModel: AgentAppViewModel
    /// True when the pane shows the same composer a workspace tab would.
    let showsComposer: Bool
    private let onClose: () -> Void

    init(viewModel: AgentAppViewModel, showsComposer: Bool, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.showsComposer = showsComposer
        self.onClose = onClose
    }

    func close() { onClose() }
}

extension AppCommandRouter {
    /// A thread whose workspace is open gets a real Agent App wired exactly like a
    /// workspace tab (composer, bot prompts, queue, providers), but never registered as
    /// a tab. A thread with no open workspace (a General Bot's Desk thread) stays a
    /// read-only pinned view: its replies need the Desk's own wiring.
    func makeActivityConversation(_ item: ActivityWireItem) -> ActivityConversation? {
        guard let context, let threadID = item.thread_id.flatMap(UUID.init(uuidString:)).map(AgentThreadID.init),
              let thread = try? context.threadRepo.get(id: threadID) else { return nil }
        if let workspaceID = thread.workspaceId, let workspace = context.state.workspaces[workspaceID] {
            let agent = AgentAppSurface(
                workspaceID: workspaceID, cwd: workspace.cwd, coordinator: context.coordinator,
                threadRepo: context.threadRepo, messageRepo: context.messageRepo,
                draftRepo: AgentThreadDraftRepository(db: context.db),
                attachmentStore: AgentAttachmentStore(root: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)),
                queuedMessageRepo: context.queuedMessageRepo, providerSessionRepo: context.providerSessionRuntimeRepo,
                pendingCallbackRepo: context.providerPendingCallbackRepo, proposedPlanRepo: context.proposedPlanRepo,
                checkpointRepo: context.turnCheckpointRepo, promptHistoryStore: PromptHistoryStore(db: context.db),
                customModelStore: AgentCustomModelStore(repo: context.settingsRepo), planNotesStore: PlanNotesStore(db: context.db),
                initialThreadId: threadID, orchestrationRuntime: context.orchestrationRuntime
            )
            wireWorkspaceAgentSurface(agent, workspace: workspaceID, ctx: context)
            return ActivityConversation(viewModel: agent.viewModel, showsComposer: true) { [weak context] in
                agent.close()
                context?.threadRepo.setLiveSurfaceBinding(surfaceID: agent.descriptor.id, threadID: nil)
            }
        }
        let viewModel = AgentAppViewModel(
            workspaceID: thread.workspaceId ?? BotsViewModel.botDeskWorkspaceID,
            cwd: context.appSupportDirectory.path,
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
        return ActivityConversation(viewModel: viewModel, showsComposer: false) { viewModel.dispose() }
    }
}
