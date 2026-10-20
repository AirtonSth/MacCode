import AgentRuntime
import CoreModel
import Foundation
import Persistence
import SocketServer
import XCTest
@testable import AppShell

@MainActor
final class BotContextInternalAdmissionLiveDockerTests: XCTestCase {
    func testDedicatedProviderCreatesRealChildAndRevokesItsGuest() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RC_LIVE_DOCKER"] == "1" else { throw XCTSkip("set RC_LIVE_DOCKER=1 for the actual provider/guest probe") }
        guard let parentKey = environment["RC_CONTEXT_OPENROUTER_PARENT_TEST_KEY"], !parentKey.isEmpty,
              let childKey = environment["RC_CONTEXT_OPENROUTER_CHILD_TEST_KEY"], !childKey.isEmpty,
              let model = environment["RC_CONTEXT_OPENROUTER_TEST_MODEL"], !model.isEmpty else {
            throw XCTSkip("Dedicated parent/child OpenRouter test keys and explicit model are required; personal sign-ins are never used")
        }
        let scratch = try XCTUnwrap(environment["RC_CONTEXT_PROBE_ROOT"])
        let root = URL(fileURLWithPath: scratch).appendingPathComponent("context-live-admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let support = root.appendingPathComponent("support")
        let secrets = InMemoryBotSecretStore()
        let context = try AppContext(channel: .debug, dbPathOverride: root.appendingPathComponent("probe.sqlite").path,
            appSupportOverride: support.path, privateAccountAPI: SilentWakeRecordingAPI(),
            performLaunchRunReconciliation: true, contextualSecretStore: secrets)
        let router = AppCommandRouter(context: context)
        context.router = router
        let docker = BotComputerDockerCLI()
        var identities: [BotContextRuntimeIdentity] = []
        var runIDs: [AgentRunID] = []
        var threadIDs: [AgentThreadID] = []
        var cleanupConfirmed = true
        func cleanup() async {
            for runID in runIDs { context.coordinator.stopRun(runID) }
            for threadID in threadIDs {
                do { try await context.coordinator.stopAndAwaitTermination(threadId: threadID) }
                catch { cleanupConfirmed = false; XCTFail("Owned live run termination was not confirmed") }
            }
            let report = await Task.detached { BotContextGuestRecovery.reconcile(docker: docker, appSupport: support) }.value
            if !report.failures.isEmpty { cleanupConfirmed = false; XCTFail("Owned live runtime recovery failed") }
            let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil)
            for identity in identities {
                do {
                    try service.wipe(identity: identity)
                    let exists = try docker.containerExists(name: BotComputerGuestSpec.containerName(botID: identity.storageBotID))
                    let network = try docker.networkExists(name: BotComputerGuestSpec.networkName(botID: identity.storageBotID))
                    cleanupConfirmed = cleanupConfirmed && !exists && !network
                    XCTAssertFalse(exists)
                    XCTAssertFalse(network)
                } catch { cleanupConfirmed = false; XCTFail("Owned live Docker cleanup failed") }
            }
            if cleanupConfirmed { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        }
        do {
            _ = try docker.info()
            guard try docker.imageExists(tag: BotComputerGuestSpec.imageTag),
                  try docker.imageLabel(tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey) == BotComputerGuestSpec.recipeRevision else {
                throw XCTSkip("matching pre-existing guest image is required; probe never pulls or builds")
            }
            let path = root.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let workspace = try router.createWorkspace(name: "Live contextual admission", cwd: path.path)
            let hostID = context.liveActivityHostIdentity.serverId
            let parent = try context.botStore.create(name: "Live parent", title: "Live parent", description: "", handle: "live-parent", soul: "", provider: .distill, model: model)
            let peer = try context.botStore.create(name: "Live peer", title: "Live peer", description: "", handle: "live-peer", soul: "", provider: .distill, model: model)
            let parentGrant = try context.botStore.grantContext(hostID: hostID, botID: parent.id, context: .workspace(workspace.id), actions: [.read, .send, .configure, .files, .delegate], expectedRevision: 0)
            let peerGrant = try context.botStore.grantContext(hostID: hostID, botID: peer.id, context: parentGrant.context, actions: [.read, .send, .configure, .files], expectedRevision: 0)
            identities = try [parentGrant, peerGrant].map { try BotContextRuntimeIdentity(binding: $0) }
            try JSONSerialization.data(withJSONObject: ["ownedIDs": identities.map { $0.storageBotID.value.uuidString.lowercased() }]).write(to: root.appendingPathComponent("fixture-manifest.json"))
            for (identity, key) in zip(identities, [parentKey, childKey]) {
                try secrets.save(botID: identity.storageBotID, name: "OPENROUTER_API_KEY", value: key)
            }
            let thread = AgentThread(workspaceId: workspace.id, title: "Actual provider parent", provider: .distill, model: model, permissionMode: .fullAccess)
            _ = try context.botStore.createContextualConversation(BotConversation(botID: parent.id, title: thread.title, linkedAgentThreadID: thread.id), newThread: thread, hostID: hostID, context: parentGrant.context, policyRevision: parentGrant.policyRevision)
            threadIDs.append(thread.id)
            func prompt(_ marker: String) -> String {
                "This is an isolated lifecycle test. Use the shell tool to run exactly: printf ready > /home/remotecode/\(marker); sleep 45. Do not read other files, contact other services, or print credentials. Answer only after the command finishes."
            }
            let request = AgentRunRequest(threadId: thread.id, provider: .distill, model: model, cwd: workspace.cwd, prompt: prompt(".context-parent-ready"), permissionMode: .fullAccess)
            runIDs.append(request.runId)
            _ = try await context.startContextualRun(request)
            func waitForActualModelTool(_ index: Int, marker: String) async throws {
                let container = BotComputerGuestSpec.containerName(botID: identities[index].storageBotID)
                let deadline = Date().addingTimeInterval(60)
                while Date() < deadline {
                    if (try? docker.exec(name: container, command: ["test", "-f", "/home/remotecode/" + marker], user: "1000", detach: false)) != nil { return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTFail("Actual authenticated provider did not execute its owned readiness command")
                throw URLError(.timedOut)
            }
            try await waitForActualModelTool(0, marker: ".context-parent-ready")
            XCTAssertEqual(try context.runRepo.get(id: request.runId)?.status, .running)
            let childRunID = try await context.startContextualPeerRun(parentRunID: request.runId, peerBotID: peer.id, prompt: prompt(".context-child-ready"))
            runIDs.append(childRunID)
            let edge = try XCTUnwrap(context.botStore.contextDelegation(childRunID: childRunID))
            threadIDs.append(edge.childThreadID)
            XCTAssertEqual(edge.parentRunID, request.runId)
            XCTAssertEqual(edge.childPin.context, parentGrant.context)
            XCTAssertEqual(edge.childPin.botID, peer.id)
            XCTAssertEqual(try context.threadRepo.get(id: edge.childThreadID)?.executionTarget, .vm)
            try await waitForActualModelTool(1, marker: ".context-child-ready")
            _ = try await router.dispatchPairedBotRemote(method: "bot.context.revoke", params: [
                "client_request_id": .string(UUID().uuidString), "host_id": .string(hostID),
                "bot_id": .string(parent.id.value.uuidString), "context_key": .string(parentGrant.context.storageKey),
                "context_version": .number(1), "policy_revision": .number(Double(parentGrant.policyRevision)),
            ])
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let child = try context.runRepo.get(id: childRunID)
                let running = try docker.inspect(name: BotComputerGuestSpec.containerName(botID: identities[1].storageBotID)).running
                if child?.status != .pending && child?.status != .running && !running { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(try XCTUnwrap(context.botStore.contextDelegation(childRunID: childRunID)).closed)
            XCTAssertFalse(try context.botStore.authorizesContextDelegation(hostID: hostID, runID: childRunID, threadID: edge.childThreadID))
            XCTAssertFalse(try docker.inspect(name: BotComputerGuestSpec.containerName(botID: identities[1].storageBotID)).running)
            XCTAssertNotEqual(try context.runRepo.get(id: childRunID)?.status, .running)
            XCTAssertNotEqual(try context.runRepo.get(id: childRunID)?.status, .pending)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}
