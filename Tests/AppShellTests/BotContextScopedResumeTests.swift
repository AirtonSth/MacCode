import AgentRuntime
import CoreModel
import Foundation
import Persistence
import SocketServer
import XCTest
@testable import AppShell

@MainActor
final class BotContextScopedResumeTests: XCTestCase {
    private let model = "openrouter/provider/model"

    private func scratchRoot() throws -> URL {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"], "RC_CONTEXT_PROBE_ROOT must name invocation-owned scratch")
        let root = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("ScopedResume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func makeContext(root: URL, dbName: String = "owned.sqlite", hostsGuestRuns: Bool = false) throws -> AppContext {
        let context = try AppContext(channel: .debug, dbPathOverride: root.appendingPathComponent(dbName).path,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path,
            privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: hostsGuestRuns,
            contextualSecretStore: InMemoryBotSecretStore())
        context.router = AppCommandRouter(context: context)
        return context
    }

    private func fixture(context: AppContext, root: URL) throws -> (AgentThread, BotConversationContextPin, String) {
        let host = context.liveActivityHostIdentity.serverId
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let workspace = try XCTUnwrap(context.router).createWorkspace(name: "Scoped resume", cwd: workspaceRoot.path)
        let bot = try context.botStore.create(name: "Scoped resume", title: "Scoped resume", description: "", handle: "scoped-resume", soul: "", provider: .distill, model: model)
        let grant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .workspace(workspace.id), actions: [.read, .send, .configure, .files], expectedRevision: 0)
        let thread = AgentThread(workspaceId: workspace.id, title: "Scoped resume", provider: .distill, model: model)
        let conversation = BotConversation(botID: bot.id, title: thread.title, linkedAgentThreadID: thread.id)
        try context.botStore.createContextualConversation(conversation, newThread: thread, hostID: host, context: grant.context, policyRevision: grant.policyRevision)
        return (thread, try XCTUnwrap(context.botStore.conversationContextPin(linkedTo: thread.id)), workspace.cwd)
    }

    func testOwnedNativeHistoryAndBindingSurviveReopenAndRejectMismatchedBindingsWithoutMutation() throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var context: AppContext? = try makeContext(root: root)
        let (thread, pin, cwd) = try fixture(context: context!, root: root)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let cursor = "native-session-opaque-cursor"
        let identity = try BotContextRuntimeIdentity(hostID: pin.hostID, botID: pin.botID, context: pin.context, policyRevision: pin.policyRevision)
        let storageDirectory = support.appendingPathComponent("bot-context-sessions", isDirectory: true)
        let storageScope = storageDirectory.appendingPathComponent(identity.storageBotID.value.uuidString.lowercased(), isDirectory: true)
        let hostID = context!.liveActivityHostIdentity.serverId
        let botStore = context!.botStore
        let threadRepo = context!.threadRepo
        let runRepo = context!.runRepo
        var isAuthorized: (@Sendable () -> Bool)? = {
            BotContextRunAdmissions.authorizes(pin: pin, threadID: thread.id, runID: AgentRunID(), parentRunID: nil,
                hostID: hostID, store: botStore, threadRepo: threadRepo, runRepo: runRepo)
        }
        let nativeHome = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: identity.storageBotID)
        try FileManager.default.createDirectory(at: nativeHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let home = try BotContextSessionStore.prepare(pin: pin, threadID: thread.id, parentRunID: nil,
            cwd: cwd, resumeCursor: nil, appSupport: support, authorizes: try XCTUnwrap(isAuthorized))
        try BotContextSessionStore.recordOpened(sessionID: cursor, pin: pin, threadID: thread.id,
            parentRunID: nil, cwd: cwd, expectedResumeCursor: nil, appSupport: support, authorizes: try XCTUnwrap(isAuthorized))
        isAuthorized = nil
        let history = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sentinel = history.appendingPathComponent("native-history-sentinel")
        try Data("native history survives host cleanup and reopen".utf8).write(to: sentinel)
        isAuthorized = nil
        context = nil
        let originalBinding = try Data(contentsOf: storageScope
            .appendingPathComponent(pin.conversationID.value.uuidString.lowercased() + ".json"))
        context = try makeContext(root: root)
        let reopened = try XCTUnwrap(context)
        let reopenedThread = try XCTUnwrap(reopened.threadRepo.get(id: thread.id))
        let reopenedPin = try XCTUnwrap(reopened.botStore.conversationContextPin(linkedTo: thread.id))
        let reopenedHostID = reopened.liveActivityHostIdentity.serverId
        let reopenedBotStore = reopened.botStore
        let reopenedThreadRepo = reopened.threadRepo
        let reopenedRunRepo = reopened.runRepo
        let reopenedAuthorization: @Sendable () -> Bool = {
            BotContextRunAdmissions.authorizes(pin: reopenedPin, threadID: reopenedThread.id, runID: AgentRunID(), parentRunID: nil,
                hostID: reopenedHostID, store: reopenedBotStore,
                threadRepo: reopenedThreadRepo, runRepo: reopenedRunRepo)
        }
        XCTAssertEqual(reopenedPin, pin)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("native history survives host cleanup and reopen".utf8))
        XCTAssertNoThrow(try BotContextSessionStore.validate(pin: reopenedPin, threadID: thread.id, parentRunID: nil,
            cwd: cwd, resumeCursor: cursor, appSupport: support, authorizes: reopenedAuthorization))

        func assertRefusedWithoutMutation(pin candidatePin: BotConversationContextPin, parent: AgentRunID? = nil, cursor candidateCursor: String?) throws {
            XCTAssertThrowsError(try BotContextSessionStore.validate(pin: candidatePin, threadID: thread.id,
                parentRunID: parent, cwd: cwd, resumeCursor: candidateCursor, appSupport: support,
                authorizes: reopenedAuthorization))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("native history survives host cleanup and reopen".utf8))
            let current = try Data(contentsOf: storageScope
                .appendingPathComponent(pin.conversationID.value.uuidString.lowercased() + ".json"))
            XCTAssertEqual(current, originalBinding)
        }
        try assertRefusedWithoutMutation(pin: reopenedPin, cursor: "foreign-cursor")
        try assertRefusedWithoutMutation(pin: reopenedPin, cursor: nil)
        try assertRefusedWithoutMutation(pin: BotConversationContextPin(conversationID: pin.conversationID, hostID: "foreign-host-\(UUID().uuidString)",
            botID: pin.botID, context: pin.context, policyRevision: pin.policyRevision), cursor: cursor)
        try assertRefusedWithoutMutation(pin: BotConversationContextPin(conversationID: pin.conversationID, hostID: pin.hostID,
            botID: pin.botID, context: pin.context, policyRevision: pin.policyRevision + 1), cursor: cursor)
        try assertRefusedWithoutMutation(pin: BotConversationContextPin(conversationID: pin.conversationID, hostID: pin.hostID,
            botID: pin.botID, context: .general, policyRevision: pin.policyRevision), cursor: cursor)
        try assertRefusedWithoutMutation(pin: reopenedPin, parent: AgentRunID(), cursor: cursor)

        let metadata = storageScope.appendingPathComponent(pin.conversationID.value.uuidString.lowercased() + ".json")
        let metadataBytes = try Data(contentsOf: metadata)
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: sentinel)
        XCTAssertThrowsError(try BotContextSessionStore.validate(pin: reopenedPin, threadID: thread.id, parentRunID: nil,
            cwd: cwd, resumeCursor: cursor, appSupport: support, authorizes: reopenedAuthorization))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("native history survives host cleanup and reopen".utf8))
        try FileManager.default.removeItem(at: metadata)
        try metadataBytes.write(to: metadata)
        XCTAssertEqual(try Data(contentsOf: metadata), metadataBytes)
    }

    func testLiveDockerPersistentSessionCancelAndRecoveryPreserveOwnedHistory() async throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for real Docker storage lifecycle")
        }
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        guard try docker.imageExists(tag: BotComputerGuestSpec.imageTag),
              try docker.imageLabel(tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey)
                == BotComputerGuestSpec.recipeRevision else {
            throw XCTSkip("matching pre-existing guest image required; test never builds or pulls")
        }
        let root = try scratchRoot()
        var preserveRoot = false
        defer { if !preserveRoot { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) } }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let context = try makeContext(root: root, hostsGuestRuns: true)
        try await context.botGuestLaunchBarrier.wait()
        let (thread, pin, cwd) = try fixture(context: context, root: root)
        let identity = try BotContextRuntimeIdentity(hostID: pin.hostID, botID: pin.botID, context: pin.context,
            policyRevision: pin.policyRevision)
        let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil)
        let secrets = InMemoryBotSecretStore()
        try secrets.save(botID: identity.storageBotID, name: "OPENROUTER_API_KEY", value: "synthetic-invalid-never-used")
        let manifest = root.appendingPathComponent("fixture-manifest.json")
        try JSONSerialization.data(withJSONObject: ["ownedIDs": [identity.storageBotID.value.uuidString.lowercased()]])
            .write(to: manifest, options: .atomic)
        var resources: BotContextGuestResources?
        preserveRoot = true
        var cleanupConfirmed = false
        defer {
            do {
                try resources?.cancel()
                try service.wipe(identity: identity)
                let containerExists = try docker.containerExists(name: BotComputerGuestSpec.containerName(botID: identity.storageBotID))
                let networkExists = try docker.networkExists(name: BotComputerGuestSpec.networkName(botID: identity.storageBotID))
                XCTAssertFalse(containerExists)
                XCTAssertFalse(networkExists)
                cleanupConfirmed = !containerExists && !networkExists
            } catch { XCTFail("Owned Docker fixture cleanup failed; manifest retained at \(manifest.path): \(error)") }
            if cleanupConfirmed { try? FileManager.default.removeItem(at: root) }
        }
        let request = AgentRunRequest(threadId: thread.id, provider: .distill, model: model, cwd: cwd,
            prompt: "storage lifecycle only; provider must not launch")
        guard case .workspace(let workspaceID) = pin.context else { throw BotComputerGuestServiceError.contextualRuntimeUnavailable }
        let workspace = try XCTUnwrap(context.state.workspaces[workspaceID])
        let prepared = try BotContextGuestResources.prepare(request: request, hostID: pin.hostID,
            store: context.botStore, threadRepo: context.threadRepo, service: service, appSupport: support,
            workspace: workspace, registeredWorkspaces: [cwd], secretStore: secrets,
            providerConfiguration: try BotContextRunAdmissions.configuration(model: model), persistentSession: true)
        resources = prepared
        XCTAssertTrue(try docker.inspect(name: prepared.container).running)
        let hostSessionHome = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: identity.storageBotID)
            .appendingPathComponent(".distill-context-session-\(pin.conversationID.value.uuidString.lowercased())", isDirectory: true)
        let guestSessionHome = BotComputerGuestSpec.guestUserHome + "/.distill-context-session-\(pin.conversationID.value.uuidString.lowercased())"
        let historyFile = hostSessionHome.appendingPathComponent("sessions/owned-history")
        _ = try docker.exec(name: prepared.container, command: ["sh", "-lc", "mkdir -p \(guestSessionHome)/sessions && printf owned-history > \(guestSessionHome)/sessions/owned-history"], user: "1000", detach: false)
        let historyBefore = try Data(contentsOf: historyFile)
        XCTAssertEqual(String(decoding: historyBefore, as: UTF8.self), "owned-history")
        let bindingURL = support.appendingPathComponent("bot-context-sessions", isDirectory: true)
            .appendingPathComponent(identity.storageBotID.value.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(pin.conversationID.value.uuidString.lowercased() + ".json")
        let bindingBefore = try Data(contentsOf: bindingURL)
        _ = try docker.exec(name: prepared.container, command: ["test", "!", "-e", bindingURL.path], user: "1000", detach: false)
        let envFile = try XCTUnwrap(prepared.envFileURL)
        try prepared.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: envFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostSessionHome.appendingPathComponent("config.toml").path))
        XCTAssertEqual(try Data(contentsOf: bindingURL), bindingBefore)
        XCTAssertEqual(try Data(contentsOf: historyFile), historyBefore)
        XCTAssertFalse(try docker.inspect(name: prepared.container).running)

        let recoveryRun = AgentRunID()
        try BotContextGuestRecovery.begin(identity: identity, runID: recoveryRun, conversationID: pin.conversationID, appSupport: support)
        let ownedConfig = hostSessionHome.appendingPathComponent("config.toml")
        try Data("harmless recovery fixture\n".utf8).write(to: ownedConfig, options: .atomic)
        let recovery = BotContextGuestRecovery.reconcile(docker: docker, appSupport: support)
        XCTAssertTrue(recovery.failures.isEmpty, "Owned recovery fixture must reconcile: \(recovery.failures)")
        XCTAssertTrue(recovery.reconciled.contains(identity.storageBotID.value.uuidString.lowercased()))
        let journal = DistillGuestEnvironment.runsDirectory(appSupport: support)
            .appendingPathComponent(identity.storageBotID.value.uuidString.lowercased())
            .appendingPathComponent(recoveryRun.value.uuidString.lowercased() + ".context.json")
        XCTAssertEqual(try JSONDecoder().decode(BotContextGuestRecovery.Record.self, from: Data(contentsOf: journal)).state, .ended)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedConfig.path))
        XCTAssertEqual(try Data(contentsOf: historyFile), historyBefore)
        XCTAssertEqual(try Data(contentsOf: bindingURL), bindingBefore)
        XCTAssertFalse(try docker.inspect(name: prepared.container).running)
    }

    func testRevokedGrantAfterStoreReopenRejectsBeforeRunCreationOrGuestEffects() async throws {
        try await assertChangedGrantRejectsAfterReopen(revoke: true)
    }

    func testNewActivePolicyRevisionAfterReopenRejectsBeforeEffects() async throws {
        try await assertChangedGrantRejectsAfterReopen(revoke: false)
    }

    private func assertChangedGrantRejectsAfterReopen(revoke: Bool) async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var context: AppContext? = try makeContext(root: root)
        let (thread, pin, cwd) = try fixture(context: context!, root: root)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let identity = try BotContextRuntimeIdentity(hostID: pin.hostID, botID: pin.botID, context: pin.context, policyRevision: pin.policyRevision)
        let guestHomeRoot = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: identity.storageBotID)
        let hostID = context!.liveActivityHostIdentity.serverId
        let botStore = context!.botStore
        let threadRepo = context!.threadRepo
        let runRepo = context!.runRepo
        var authorization: (@Sendable () -> Bool)? = {
            BotContextRunAdmissions.authorizes(pin: pin, threadID: thread.id, runID: AgentRunID(), parentRunID: nil,
                hostID: hostID, store: botStore, threadRepo: threadRepo, runRepo: runRepo)
        }
        try FileManager.default.createDirectory(at: guestHomeRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stableHome = try BotContextSessionStore.prepare(pin: pin, threadID: thread.id, parentRunID: nil,
            cwd: cwd, resumeCursor: nil, appSupport: support, authorizes: try XCTUnwrap(authorization))
        let metadataURL = support.appendingPathComponent("bot-context-sessions")
            .appendingPathComponent(identity.storageBotID.value.uuidString.lowercased())
            .appendingPathComponent(pin.conversationID.value.uuidString.lowercased() + ".json")
        let before = try Data(contentsOf: metadataURL)
        authorization = nil
        context = nil
        context = try makeContext(root: root, hostsGuestRuns: true)
        let reopened = try XCTUnwrap(context)
        try await reopened.botGuestLaunchBarrier.wait()
        let binding = try XCTUnwrap(reopened.botStore.getContextBinding(hostID: pin.hostID, botID: pin.botID, context: pin.context))
        if revoke {
            _ = try reopened.botStore.revokeContext(hostID: pin.hostID, botID: pin.botID, context: pin.context,
                expectedRevision: binding.policyRevision)
        } else {
            _ = try reopened.botStore.grantContext(hostID: pin.hostID, botID: pin.botID, context: pin.context,
                actions: [.read, .send, .configure, .files], expectedRevision: binding.policyRevision)
        }
        try reopened.contextualSecretStore.save(botID: identity.storageBotID, name: "OPENROUTER_API_KEY", value: "owned-negative-fixture")
        XCTAssertFalse(try reopened.botStore.authorizes(hostID: pin.hostID, botID: pin.botID,
            context: pin.context, action: .send, policyRevision: pin.policyRevision))
        let request = AgentRunRequest(threadId: thread.id, provider: .distill, model: model, cwd: cwd, prompt: "must refuse")
        let homeRoot = guestHomeRoot
        do { _ = try await reopened.startContextualRun(request); XCTFail("Revoked contextual grant must reject after SQLite reopen") }
        catch { }
        XCTAssertNil(try reopened.runRepo.get(id: request.runId))
        XCTAssertTrue(FileManager.default.fileExists(atPath: homeRoot.path))
        XCTAssertEqual(try Data(contentsOf: metadataURL), before, "Denied restart must not rewrite durable session authority")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stableHome.appendingPathComponent("config.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("config.toml").path))
    }
}
