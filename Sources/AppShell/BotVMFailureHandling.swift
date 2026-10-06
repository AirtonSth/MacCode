import Foundation
import AgentRuntime
import CoreModel
import Surfaces

extension AppCommandRouter {
    static let macExecutionApprovedFollowUp = "Execução no Mac aprovada pelo usuário. Continue."
    static let macExecutionDeclinedFollowUp = "O usuário recusou a execução no Mac. Continue na VM ou pare e explique."

    /// Every Agent App view model that can show a bot thread: the Agent App
    /// tabs and the embedded Bots Desk.
    var botThreadViewModels: [AgentAppViewModel] {
        var models: [AgentAppViewModel] = []
        for case let agent as AgentAppSurface in SurfaceRegistry.shared.all() {
            models.append(agent.viewModel)
        }
        if let desk = botsViewModel?.deskAgentVM { models.append(desk) }
        return models
    }

    /// D12 before a router start: claims the bot's VM for `runID` on a thread
    /// locked to the bot's VM. nil for any other thread. `holder` is the other
    /// thread's run when the VM is busy (nothing was claimed then).
    /// `firstMessage` names a never-used thread as the send will rename it.
    func claimBotVMRun(
        thread: AgentThreadID,
        runID: AgentRunID,
        firstMessage: String? = nil
    ) -> (botID: BotID, holder: BotVMRunRegistry.Entry?)? {
        guard let ctx = context,
              (try? ctx.threadRepo.guestPlacement(of: thread))??.executionTarget == .vm,
              let row = (try? ctx.threadRepo.get(id: thread)) ?? nil else { return nil }
        let botID: BotID
        if case .bot(let id) = row.actor {
            botID = id
        } else if let conversation = (try? ctx.botStore.conversationLinked(to: thread)) ?? nil {
            botID = conversation.botID
        } else {
            return nil
        }
        let untitled = AgentThreadTitle.isPlaceholder(row.title)
            && (try? ctx.messageRepo.hasAny(threadId: thread)) != true
        let title = untitled ? firstMessage.map(AgentThreadTitle.titleFromFirstMessage) ?? row.title : row.title
        let holder = BotVMRunRegistry.shared.tryBegin(
            botID: botID,
            entry: BotVMRunRegistry.Entry(
                threadID: thread, runID: runID, title: title, workspace: row.worktreePath ?? ""
            )
        )
        return (botID, holder)
    }

    /// Frees a claim whose run never started and hands the VM to the next
    /// queued thread, as the run-finished callback does for a started run.
    func releaseBotVMRun(_ runID: AgentRunID) {
        guard let next = BotVMRunRegistry.shared.releaseAndNextWaiting(runID: runID) else { return }
        Task { @MainActor [weak self] in try? await self?.drainNextQueuedAgentMessage(thread: next, botVMHandOff: true) }
    }

    /// Queues `thread` behind the run holding the bot's VM and shows the
    /// notice on the surfaces showing it. Returns the notice.
    @discardableResult
    func waitForBotVM(botID: BotID, thread: AgentThreadID, holder: BotVMRunRegistry.Entry) -> String {
        BotVMRunRegistry.shared.addWaiting(botID: botID, threadID: thread)
        let notice = "bot ocupado em \(holder.title)"
        for viewModel in botThreadViewModels where viewModel.selectedThreadId == thread {
            viewModel.statusMessage = notice
        }
        return notice
    }

    func handleMacExecutionRequested(threadID: AgentThreadID, reason: String) {
        pendingMacExecution[threadID] = reason
        for viewModel in botThreadViewModels {
            viewModel.pendingMacExecutionByThread[threadID] = reason
        }
    }

    /// Approve switches the thread to the Mac (actor and lock kept); decline leaves the target alone.
    /// Both send a follow-up so the bot learns the outcome. Only ever called from a user click.
    /// A guest thread keeps its marker: its next run (this follow-up, once a
    /// still-finishing guest turn ends) starts a new Mac session with a
    /// handoff summary (`AgentRunCoordinator.pendingMacHandoff`).
    func resolveMacExecution(thread: AgentThreadID, approve: Bool) async {
        guard pendingMacExecution.removeValue(forKey: thread) != nil else { return }
        for viewModel in botThreadViewModels {
            viewModel.pendingMacExecutionByThread[thread] = nil
        }
        if approve {
            guard let stored = try? context?.threadRepo.get(id: thread),
                  (try? context?.threadRepo.setActor(
                      id: thread, actor: stored.actor, lockedAt: stored.actorLockedAt, executionTarget: .mac
                  )) == true else { return }
            for viewModel in botThreadViewModels {
                viewModel.mirrorExecutionTarget(.mac, thread: thread)
            }
        }
        _ = try? await sendAgentMessage(
            thread: thread,
            text: approve ? Self.macExecutionApprovedFollowUp : Self.macExecutionDeclinedFollowUp,
            provider: nil, model: nil, permissionMode: nil, reasoningEffort: nil
        )
    }

    /// nil when Docker answers and the run's workspace is mounted; otherwise the user-facing failure.
    /// A workspace-less thread (`workspace` nil, a Bots Desk thread) only needs the container up:
    /// its agent runs in the guest user's home, and BotHome is never a mountable workspace.
    /// A bot already running elsewhere keeps its container: the send queues instead of remounting.
    func botVMPreflight(_ botID: BotID, workspace: String?) async -> String? {
        guard let ctx = context else { return "Contexto indisponível." }
        let docker = botVMDocker
        let service = botVMService(appSupport: ctx.appSupportDirectory)
        let registered = Set(ctx.state.workspaces.values.map(\.cwd))
        let prefetch = guestDistillPrefetch()
        return await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                prefetch(try docker.info())
                if BotVMRunRegistry.shared.active(botID: botID) == nil {
                    if let workspace {
                        try service.ensureWorkspaceMounted(botID: botID, workspace: workspace, registered: registered)
                    } else {
                        _ = try service.provision(botID: botID)
                    }
                }
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }.value
    }

    private func botVMService(appSupport: URL) -> BotComputerGuestService {
        botVMProvisionServiceForTesting ?? BotComputerGuestService(
            appSupport: appSupport,
            docker: botVMDocker,
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL()
        )
    }

    /// Starts the guest distill download in the background when Docker is up
    /// and distill is installed on the Mac, so a bot's first in-guest run, or
    /// its first run after a host distill update, does not wait for it.
    func guestDistillPrefetch() -> @Sendable (_ dockerInfo: String) -> Void {
        guard let ctx = context else { return { _ in } }
        let provisioner = ctx.distillGuestBinaries
        let override = (try? ctx.settingsRepo.get("cli.distill.path")) ?? nil
        return { info in
            guard let arch = DistillGuestBinaryProvisioner.dockerArchitecture(fromInfo: info),
                  let host = DistillProvisioner.resolveInstalledBinary(override: override) else { return }
            provisioner.prefetch(hostBinary: host, dockerArch: arch)
        }
    }

    /// nil on success; otherwise the user-facing failure.
    func provisionBotVM(_ botID: BotID) async -> String? {
        guard let appSupport = context?.appSupportDirectory else { return "Contexto indisponível." }
        let service = botVMService(appSupport: appSupport)
        let docker = botVMDocker
        let prefetch = guestDistillPrefetch()
        return await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                _ = try service.provision(botID: botID)
                Task.detached(priority: .utility) {
                    if let info = try? docker.info() { prefetch(info) }
                }
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }.value
    }
}

/// A restart leaves `bash -lc` execs running inside bot containers with no run owning them.
/// Only `BotGuestLaunchSweep` reaps them, before guest runs are admitted: a guest run's own
/// tool shells are `bash -lc` too.
enum BotVMOrphanScan {
    static func orphans(docker: any BotComputerDockerClienting, names: [String]) -> [String] {
        names.filter { name in
            (try? docker.top(name: name))?.contains("bash -lc") == true
        }
    }

    /// Logs each orphan and kills its stray shells as root. Returns the orphaned container names.
    @discardableResult
    static func reap(docker: any BotComputerDockerClienting, names: [String]) -> [String] {
        let found = orphans(docker: docker, names: names)
        for name in found {
            NSLog("bot vm orphan exec: \(name)")
            _ = try? docker.exec(name: name, command: ["pkill", "-f", "bash -lc"], user: "root", detach: false)
        }
        return found
    }
}
