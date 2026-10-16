import Foundation
import AgentRuntime
import CoreModel
import Persistence
import SocketServer

/// Prepares scoped resources without admitting a provider process.
final class BotContextGuestResources {
    private static let lock = NSLock()
    // Retain listeners until network cleanup is proven, including failed preparation.
    private static var live: [BotID: BotContextGuestResources] = [:]

    let identity: BotContextRuntimeIdentity
    let runID: AgentRunID
    private(set) var container = ""
    private(set) var envFileURL: URL?
    private(set) var configDirectory: URL?
    private let service: BotComputerGuestService
    private let gateway: BotGuestMCPGateway
    private var networkLease: BotContextGatewayLease?
    private var installationAttempted = false
    private var homeDirectory: PrivateDirectory?
    private let operationLock = NSLock()
    private var finished = false
    private var directoryName: String { ".distill-context-\(runID.value.uuidString.lowercased())" }

    private init(identity: BotContextRuntimeIdentity, runID: AgentRunID, service: BotComputerGuestService, gateway: BotGuestMCPGateway) {
        self.identity = identity
        self.runID = runID
        self.service = service
        self.gateway = gateway
    }

    static func prepare(
        request: AgentRunRequest,
        hostID: String,
        store: BotStore,
        threadRepo: AgentThreadRepository,
        service: BotComputerGuestService,
        appSupport: URL,
        workspace: Workspace?,
        registeredWorkspaces: Set<String>,
        secretStore: any BotSecretStore
    ) throws -> BotContextGuestResources {
        do {
            guard request.runAsUser == nil || request.runAsUser?.uid == getuid() else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            guard let pin = try store.conversationContextPin(linkedTo: request.threadId), pin.hostID == hostID,
                  let thread = try threadRepo.get(id: request.threadId),
                  thread.actor == .bot(pin.botID), thread.executionTarget == .vm,
                  thread.runAsUser == nil || thread.runAsUser?.uid == getuid(),
                  try threadRepo.guestPlacement(of: request.threadId)?.guestRuntime == BotGuestRuntime.distillV1,
                  let conversation = try store.conversation(id: pin.conversationID),
                  conversation.botID == pin.botID, conversation.linkedAgentThreadID == thread.id,
                  let binding = try store.getContextBinding(hostID: hostID, botID: pin.botID, context: pin.context),
                  binding.policyRevision == pin.policyRevision else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            let identity = try BotContextRuntimeIdentity(binding: binding)
            let authorize: @Sendable () -> Bool = {
                let actions: [BotContextAction] = workspace == nil ? [.read, .send, .configure] : [.read, .send, .configure, .files]
                return actions.allSatisfy {
                    (try? store.authorizes(hostID: hostID, botID: pin.botID, context: pin.context, action: $0, policyRevision: pin.policyRevision)) == true
                } && (try? store.conversationContextPin(linkedTo: request.threadId)) == pin
            }
            guard authorize() else {
                throw BotComputerGuestServiceError.contextualRuntimeUnavailable
            }
            let home = BotComputerGuestSpec.guestHomeURL(appSupport: appSupport, botID: identity.storageBotID)
            switch pin.context {
            case .general:
                guard workspace == nil, thread.workspaceId == nil else {
                    throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                }
            case .workspace(let id):
                guard let workspace, workspace.id == id, thread.workspaceId == id,
                      request.cwd == workspace.cwd, registeredWorkspaces.contains(workspace.cwd) else {
                    throw BotComputerGuestServiceError.contextualRuntimeUnavailable
                }
            }
            let context = BotGuestMCPGateway.ContextBinding(pin: pin, threadID: request.threadId)
            let gateway = BotGuestMCPGateway(context: context, contextStore: store, secretStore: secretStore)
            let resources = BotContextGuestResources(identity: identity, runID: request.runId, service: service, gateway: gateway)
            let claimed = lock.withLock {
                guard live[identity.storageBotID] == nil else { return false }
                live[identity.storageBotID] = resources
                return true
            }
            guard claimed else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
            do {
                let adapter = BotContextSecretStore(identity: identity, store: secretStore, authorizes: authorize)
                let trustedEnvironment = try BotSecretEnvironment.applying(to: [
                    BotSecretEnvironment.botIDEnvironmentKey: pin.botID.value.uuidString,
                    BotPeerDelegation.threadEnvironmentKey: thread.id.value.uuidString,
                ], store: adapter)
                resources.container = try service.provision(contextBinding: binding, workspace: workspace, registeredWorkspaces: registeredWorkspaces, requestingThreadID: request.threadId).containerID
                guard authorize() else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
                let run = request.runId.value.uuidString.lowercased()
                let issued = try gateway.issue(.init(runID: run, hostEnvironment: [:], context: context))
                resources.installationAttempted = true
                resources.networkLease = try service.installGatewayLease(identity: identity, runID: request.runId, port: issued.port)
                let parent = try PrivateDirectory(home, create: false)
                resources.homeDirectory = parent
                let directory = home.appendingPathComponent(resources.directoryName, isDirectory: true)
                guard mkdir(directory.path, 0o700) == 0 else {
                    throw DistillGuestCredentialError.writeFailed(path: directory.path, errno: errno)
                }
                resources.configDirectory = directory
                let rendered = DistillGuestConfig.render(hostConfig: "", gatewayPort: issued.port, servers: [
                    .init(name: BotSelfConfigCatalog.serverName, toolTimeoutSeconds: 900),
                ], hostEnvironment: [:])
                resources.envFileURL = try DistillGuestEnvironment.writeRunFiles(
                    rendered: rendered, configDirectory: directory,
                    guestDistillHome: BotComputerGuestSpec.guestUserHome + "/" + resources.directoryName,
                    providerEnvironment: trustedEnvironment, runID: run, gatewayToken: issued.token,
                    gitIdentity: nil, codexClientVersion: nil,
                    runsDirectory: DistillGuestEnvironment.runsDirectory(appSupport: appSupport)
                        .appendingPathComponent(identity.storageBotID.value.uuidString.lowercased(), isDirectory: true)
                )
                guard authorize() else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
                return resources
            } catch {
                try? resources.finish()
                throw error
            }
        }
    }

    func finish() throws {
        try operationLock.withLock { try finishLocked() }
    }

    private func finishLocked() throws {
        guard !finished else { return }
        gateway.revoke(runID: runID.value.uuidString.lowercased())
        // Remove distributed credentials even if the network cannot be reconciled.
        if let envFileURL {
            guard unlink(envFileURL.path) == 0 || errno == ENOENT else {
                throw DistillGuestEnvironmentError.writeFailed(path: envFileURL.path, errno: errno)
            }
            self.envFileURL = nil
        }
        if let networkLease {
            try service.revokeGatewayLease(networkLease)
        } else if installationAttempted {
            throw BotComputerGuestServiceError.contextualRuntimeUnavailable
        }
        gateway.stop()
        if let homeDirectory {
            if configDirectory != nil { homeDirectory.removeTree(directoryName) }
            homeDirectory.close()
            self.homeDirectory = nil
        }
        finished = true
        Self.lock.withLock { _ = Self.live.removeValue(forKey: identity.storageBotID) }
    }
}
