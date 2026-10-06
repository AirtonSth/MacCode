import Foundation
import AgentRuntime
import CoreModel
import Surfaces

extension AppCommandRouter {
    static let macExecutionApprovedFollowUp = "Execução no Mac aprovada pelo usuário. Continue."
    static let macExecutionDeclinedFollowUp = "O usuário recusou a execução no Mac. Continue na VM ou pare e explique."

    func handleMacExecutionRequested(threadID: AgentThreadID, reason: String) {
        pendingMacExecution[threadID] = reason
        for case let agent as AgentAppSurface in SurfaceRegistry.shared.all() {
            agent.viewModel.pendingMacExecutionByThread[threadID] = reason
        }
    }

    /// Approve switches the thread to the Mac (actor and lock kept); decline leaves the target alone.
    /// Both send a follow-up so the bot learns the outcome. Only ever called from a user click.
    func resolveMacExecution(thread: AgentThreadID, approve: Bool) async {
        guard pendingMacExecution.removeValue(forKey: thread) != nil else { return }
        for case let agent as AgentAppSurface in SurfaceRegistry.shared.all() {
            agent.viewModel.pendingMacExecutionByThread[thread] = nil
        }
        if approve {
            guard let stored = try? context?.threadRepo.get(id: thread),
                  (try? context?.threadRepo.setActor(
                      id: thread, actor: stored.actor, lockedAt: stored.actorLockedAt, executionTarget: .mac
                  )) == true else { return }
            for case let agent as AgentAppSurface in SurfaceRegistry.shared.all() {
                agent.viewModel.mirrorExecutionTarget(.mac, thread: thread)
            }
        }
        _ = try? await sendAgentMessage(
            thread: thread,
            text: approve ? Self.macExecutionApprovedFollowUp : Self.macExecutionDeclinedFollowUp,
            provider: nil, model: nil, permissionMode: nil, reasoningEffort: nil
        )
    }

    /// nil when Docker answers and the run's workspace is mounted; otherwise the user-facing failure.
    /// A bot already running elsewhere keeps its container: the send queues instead of remounting.
    func botVMPreflight(_ botID: BotID, workspace: String) async -> String? {
        guard let ctx = context else { return "Contexto indisponível." }
        let docker = botVMDocker
        let service = botVMService(appSupport: ctx.appSupportDirectory)
        let registered = Set(ctx.state.workspaces.values.map(\.cwd))
        let prefetch = guestDistillPrefetch()
        return await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                prefetch(try docker.info())
                if BotVMRunRegistry.shared.active(botID: botID) == nil {
                    try service.ensureWorkspaceMounted(botID: botID, workspace: workspace, registered: registered)
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

extension AppCommandRouter {
    /// Scans Docker-desktop bot containers off the main thread; Docker being down is not an error.
    func scanBotVMOrphansOnLaunch() {
        guard let store = context?.botStore else { return }
        let docker = botVMDocker
        DispatchQueue.global(qos: .utility).async {
            let bots = (try? store.list()) ?? []
            let names = bots.compactMap { bot -> String? in
                guard let revisionID = bot.currentRevisionID,
                      let revision = (try? store.getRevision(id: revisionID)) ?? nil,
                      revision.desktopKind == .dockerDesktop else { return nil }
                return BotComputerGuestSpec.containerName(botID: bot.id)
            }
            BotVMOrphanScan.reap(docker: docker, names: names)
        }
    }
}
