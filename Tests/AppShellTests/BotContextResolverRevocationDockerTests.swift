import Foundation
import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

@MainActor
final class BotContextResolverRevocationDockerTests: XCTestCase {
    func testRevocationDuringPreparationCannotLeaveLateContainerRunning() async throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for the real Docker preparation/revocation probe")
        }
        let realDocker = BotComputerDockerCLI()
        _ = try realDocker.info()
        guard try realDocker.imageExists(tag: BotComputerGuestSpec.imageTag),
              try realDocker.imageLabel(tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey) == BotComputerGuestSpec.recipeRevision else {
            throw XCTSkip("matching existing Docker image required; probe never pulls or builds")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-revoke-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cleanupConfirmed = true
        defer {
            if cleanupConfirmed { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let context = try AppContext(channel: .debug, appSupportOverride: support.path, privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: false)
        let router = AppCommandRouter(context: context)
        context.router = router
        let hostID = context.liveActivityHostIdentity.serverId
        let workspacePath = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        let workspace = try XCTUnwrap(context.router).createWorkspace(name: "Revocation race", cwd: workspacePath.path)
        let bot = try context.botStore.create(name: "Revocation race", title: "Revocation race", description: "", handle: "revocation-race", soul: "", provider: .distill, model: "test")
        let binding = try context.botStore.grantContext(hostID: hostID, botID: bot.id, context: .workspace(workspace.id), actions: [.read, .send, .configure, .files], expectedRevision: 0)
        let thread = AgentThread(workspaceId: workspace.id, title: "Revocation race", provider: .distill, model: "test")
        _ = try context.botStore.createContextualConversation(BotConversation(botID: bot.id, title: thread.title, linkedAgentThreadID: thread.id), newThread: thread, hostID: hostID, context: binding.context, policyRevision: binding.policyRevision)
        let request = AgentRunRequest(threadId: thread.id, provider: .distill, model: "test", cwd: workspace.cwd, prompt: "synthetic revocation race")
        let identity = try BotContextRuntimeIdentity(binding: binding)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blocker = BlockingImageDocker(entered: entered, release: release)
        let service = BotComputerGuestService(appSupport: support, docker: blocker, recipeContext: nil)
        let preparationDone = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var preparationJoined = false
        var preparation: Result<BotContextGuestResources, Error>?
        defer {
            release.signal()
            if !preparationJoined {
                preparationJoined = preparationDone.wait(timeout: .now() + 30) == .success
            }
            if preparationJoined {
                do {
                    try service.wipe(identity: identity)
                    let containerExists = try realDocker.containerExists(name: BotComputerGuestSpec.containerName(botID: identity.storageBotID))
                    let networkExists = try realDocker.networkExists(name: BotComputerGuestSpec.networkName(botID: identity.storageBotID))
                    cleanupConfirmed = !containerExists && !networkExists
                    XCTAssertFalse(containerExists)
                    XCTAssertFalse(networkExists)
                } catch { cleanupConfirmed = false; XCTFail("Revocation fixture cleanup unconfirmed: \(error)") }
            } else {
                cleanupConfirmed = false
                XCTFail("Preparation worker did not exit; preserving fixture at \(root.path)")
            }
        }
        DispatchQueue.global().async {
            let result = Result {
                try BotContextGuestResources.prepare(request: request, hostID: hostID, store: context.botStore, threadRepo: context.threadRepo, service: service, appSupport: support, workspace: workspace, registeredWorkspaces: [workspace.cwd], secretStore: nil)
            }
            resultLock.withLock { preparation = result }
            preparationDone.signal()
        }
        guard entered.wait(timeout: .now() + 10) == .success else {
            XCTFail("Preparation did not block at Docker image lookup")
            return
        }

        _ = try await XCTUnwrap(context.router).dispatchPairedBotRemote(method: "bot.context.revoke", params: [
            "client_request_id": .string(UUID().uuidString),
            "host_id": .string(hostID),
            "bot_id": .string(bot.id.value.uuidString),
            "context_key": .string(binding.context.storageKey),
            "context_version": .number(1),
            "policy_revision": .number(Double(binding.policyRevision)),
        ])
        XCTAssertFalse(try context.botStore.authorizes(hostID: hostID, botID: bot.id, context: binding.context, action: .read, policyRevision: binding.policyRevision))

        let journal = DistillGuestEnvironment.runsDirectory(appSupport: support)
            .appendingPathComponent(identity.storageBotID.value.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(request.runId.value.uuidString.lowercased() + ".context.json")
        let pendingDeadline = Date().addingTimeInterval(0.3)
        var observedPending = false
        while Date() < pendingDeadline {
            if let data = try? Data(contentsOf: journal),
               let record = try? JSONDecoder().decode(BotContextGuestRecovery.Record.self, from: data) {
                XCTAssertEqual(record.state, .pending)
                observedPending = record.state == .pending
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(observedPending, "Revocation cleanup must not end the record while preparation owns its operation lock")
        XCTAssertEqual(preparationDone.wait(timeout: .now()), .timedOut, "Preparation must remain blocked until released")

        release.signal()
        guard preparationDone.wait(timeout: .now() + 30) == .success else {
            XCTFail("Preparation did not finish after Docker barrier release")
            return
        }
        preparationJoined = true
        let finalPreparation = resultLock.withLock { preparation }
        guard case .failure = finalPreparation else {
            XCTFail("Revoked preparation must throw")
            if case .success(let resources) = finalPreparation { try? resources.cancel() }
            return
        }

        let container = BotComputerGuestSpec.containerName(botID: identity.storageBotID)
        let settledBy = Date().addingTimeInterval(10)
        var endedAndStopped = false
        while Date() < settledBy {
            let record = try? JSONDecoder().decode(BotContextGuestRecovery.Record.self, from: Data(contentsOf: journal))
            let exists = (try? realDocker.containerExists(name: container)) ?? false
            let running = exists ? ((try? realDocker.inspect(name: container).running) ?? true) : false
            if record?.state == .ended && !running {
                endedAndStopped = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(endedAndStopped, "Recovery record must end and revoked runtime must not run")
        if try realDocker.containerExists(name: container) { XCTAssertFalse(try realDocker.inspect(name: container).running) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path.replacingOccurrences(of: ".context.json", with: ".env")))
        let runDirectory = journal.deletingLastPathComponent()
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: runDirectory.path).contains { $0.hasSuffix(".env") })
        let guestHome = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: identity.storageBotID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: guestHome.appendingPathComponent(".distill-context-\(request.runId.value.uuidString.lowercased())").path))
        XCTAssertFalse(try context.botStore.authorizes(hostID: hostID, botID: bot.id, context: binding.context, action: .send, policyRevision: binding.policyRevision))
        try service.wipe(identity: identity)
        XCTAssertFalse(try realDocker.containerExists(name: container))
        XCTAssertFalse(try realDocker.networkExists(name: BotComputerGuestSpec.networkName(botID: identity.storageBotID)))
    }
}
