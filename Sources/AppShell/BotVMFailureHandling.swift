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

    /// nil when Docker answers; otherwise the user-facing failure.
    func botVMPreflight(_ botID: BotID) async -> String? {
        let docker = botVMDocker
        return await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                _ = try docker.info()
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }.value
    }

    /// nil on success; otherwise the user-facing failure.
    func provisionBotVM(_ botID: BotID) async -> String? {
        guard let appSupport = context?.appSupportDirectory else { return "Contexto indisponível." }
        let service = botVMProvisionServiceForTesting ?? BotComputerGuestService(
            appSupport: appSupport,
            docker: botVMDocker,
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL()
        )
        return await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                _ = try service.provision(botID: botID)
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }.value
    }
}
