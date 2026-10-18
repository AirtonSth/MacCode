import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

@MainActor
final class BotContextResolverDockerProbeTests: XCTestCase {
    func test_liveResolverProvisionsScopedRuntimesBeforeProviderGate() async throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for the real resolver Docker probe")
        }
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        guard try docker.imageExists(tag: BotComputerGuestSpec.imageTag),
              try docker.imageLabel(tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey) == BotComputerGuestSpec.recipeRevision else {
            throw XCTSkip("matching existing guest image unavailable; probe never builds or pulls")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-docker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cleanupConfirmed = true
        defer {
            if cleanupConfirmed { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let database = root.appendingPathComponent("probe.sqlite")
        let ctx = try AppContext(channel: .debug, dbPathOverride: database.path, appSupportOverride: support.path, privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: true, contextualSecretStore: InMemoryBotSecretStore())
        ctx.router = AppCommandRouter(context: ctx)
        let router = try XCTUnwrap(ctx.router)
        let host = ctx.liveActivityHostIdentity.serverId
        let paths = ["workspace-a", "workspace-b"].map { root.appendingPathComponent($0, isDirectory: true) }
        for path in paths { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let markerValues = [UUID().uuidString, UUID().uuidString]
        for index in paths.indices { try Data(markerValues[index].utf8).write(to: paths[index].appendingPathComponent("private-marker")) }
        let workspaces = try paths.enumerated().map { try router.createWorkspace(name: "Resolver \($0.offset)", cwd: $0.element.path) }
        let bot = try ctx.botStore.create(name: "Resolver", title: "Resolver", description: "", handle: "resolver-\(UUID().uuidString.prefix(8))", soul: "", provider: .distill, model: "test")
        let bindings = try workspaces.map { try ctx.botStore.grantContext(hostID: host, botID: bot.id, context: .workspace($0.id), actions: [.read, .send, .configure, .files], expectedRevision: 0) }
        let identities = try bindings.map { try BotContextRuntimeIdentity(binding: $0) }
        let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil)
        defer {
            for identity in identities {
                do {
                    try service.wipe(identity: identity)
                    let container = BotComputerGuestSpec.containerName(botID: identity.storageBotID)
                    let network = BotComputerGuestSpec.networkName(botID: identity.storageBotID)
                    let containerExists = try docker.containerExists(name: container)
                    let networkExists = try docker.networkExists(name: network)
                    cleanupConfirmed = cleanupConfirmed && !containerExists && !networkExists
                    XCTAssertFalse(containerExists)
                    XCTAssertFalse(networkExists)
                } catch { cleanupConfirmed = false; XCTFail("Owned runtime cleanup failed: \(error)") }
            }
        }
        let markerScript = root.appendingPathComponent("provider-must-not-run")
        try Data("#!/bin/sh\nprintf invoked > '\(root.appendingPathComponent("provider-was-run").path)'\nexit 99\n".utf8).write(to: markerScript)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: markerScript.path)
        var requests: [AgentRunRequest] = []
        for index in workspaces.indices {
            let thread = AgentThread(workspaceId: workspaces[index].id, title: "Pinned resolver probe", provider: .distill, model: "test")
            _ = try ctx.botStore.createContextualConversation(BotConversation(botID: bot.id, title: "Pinned resolver probe", linkedAgentThreadID: thread.id), newThread: thread, hostID: host, context: bindings[index].context, policyRevision: bindings[index].policyRevision)
            requests.append(AgentRunRequest(threadId: thread.id, provider: .distill, model: "test", cwd: paths[index].path, prompt: "runtime preparation probe", providerBinary: markerScript.path))
        }
        for request in requests {
            do {
                _ = try await ctx.coordinator.startRun(request)
                XCTFail("Provider gate must refuse runtime-only contextual execution")
            } catch {
                XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("context"), "Expected contextual-unavailable refusal, got \(error)")
            }
            XCTAssertEqual(try ctx.runRepo.get(id: request.runId)?.status, .failed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("provider-was-run").path), "Provider executable must never run")
        let legacyContainer = BotComputerGuestSpec.containerName(botID: bot.id)
        XCTAssertFalse(try docker.containerExists(name: legacyContainer), "Legacy per-bot guest must not be used")
        for index in identities.indices {
            let name = BotComputerGuestSpec.containerName(botID: identities[index].storageBotID)
            XCTAssertTrue(try docker.containerExists(name: name), "Actual resolver must provision owned runtime before refusal")
            XCTAssertFalse(try docker.inspect(name: name).running, "Denied provider preparation must leave its runtime stopped")
            let resumed = try service.provision(contextBinding: bindings[index], workspace: workspaces[index], registeredWorkspaces: Set(paths.map(\.path)))
            XCTAssertEqual(resumed.containerID, name, "Marker inspection must reuse the runtime chosen by the resolver")
            let observed = try docker.inspect(name: name)
            let otherPath = paths[1 - index].path
            let command = "test \"$(cat \"$1/private-marker\")\" = \"$2\" && test ! -e \"$3\" && printf %s \"$2\" > \"$4/resolver-marker\" && cat \"$4/resolver-marker\""
            XCTAssertEqual(String(decoding: try docker.exec(name: name, command: ["sh", "-c", command, "probe", paths[index].path, markerValues[index], otherPath, BotComputerGuestSpec.guestUserHome], user: BotComputerGuestSpec.agentUser), as: UTF8.self), markerValues[index])
            let peer = try docker.inspect(name: BotComputerGuestSpec.containerName(botID: identities[1 - index].storageBotID))
            XCTAssertNotEqual(observed.homeSource, peer.homeSource)
            XCTAssertTrue(Set(observed.networkNames).isDisjoint(with: Set(peer.networkNames)))
            _ = try docker.exec(name: name, command: ["sh", "-c", "test ! -e \"$1/.distill/accounts\" && test ! -e \"$1/.distill/claude-auth.json\" && test ! -e \"$1/.distill/codex-auth.json\" && test ! -e \"$1/.distill/auth.json\"", "probe", BotComputerGuestSpec.guestUserHome], user: BotComputerGuestSpec.agentUser)
            XCTAssertFalse(FileManager.default.fileExists(atPath: BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: bot.id).path))
            let scopedHome = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: identities[index].storageBotID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: scopedHome.appendingPathComponent(".distill-context-\(requests[index].runId.value.uuidString.lowercased())").path))
        }
        let runsDirectory = DistillGuestEnvironment.runsDirectory(appSupport: support)
        let stagedFiles = FileManager.default.enumerator(atPath: runsDirectory.path)?.allObjects as? [String] ?? []
        XCTAssertFalse(stagedFiles.contains { $0.hasSuffix(".env") }, "Runtime-only preparation must not stage credentials")
        XCTAssertTrue(try ctx.runRepo.listActive().isEmpty)
        for identity in identities { try service.wipe(identity: identity) }
        for index in identities.indices {
            let name = BotComputerGuestSpec.containerName(botID: identities[index].storageBotID)
            XCTAssertFalse(try docker.containerExists(name: name))
            XCTAssertFalse(try docker.networkExists(name: BotComputerGuestSpec.networkName(botID: identities[index].storageBotID)))
        }
        do {
            _ = try await router.sendAgentMessage(thread: requests[0].threadId, text: "must remain rejected", provider: nil, model: nil, permissionMode: nil, reasoningEffort: nil)
            XCTFail("Pinned public send must remain rejected")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32602)
            XCTAssertTrue(error.message.contains("Contextual execution is unavailable"))
        }
        for identity in identities {
            XCTAssertFalse(try docker.containerExists(name: BotComputerGuestSpec.containerName(botID: identity.storageBotID)), "Rejected public send must not provision runtime")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("provider-was-run").path))
    }
}
