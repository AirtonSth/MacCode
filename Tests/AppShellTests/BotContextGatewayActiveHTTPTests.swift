import Foundation
import XCTest
import AgentRuntime
import CoreModel
import Persistence
@testable import AppShell

final class BotContextGatewayActiveHTTPTests: XCTestCase {
    func test_livePreparedContextRevocationClosesOnlyActiveA() throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for the real prepared gateway probe")
        }
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        guard try docker.imageExists(tag: BotComputerGuestSpec.imageTag),
              try docker.imageLabel(tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey) == BotComputerGuestSpec.recipeRevision else {
            XCTFail("The matching existing image is required; this probe never builds an image.")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("active-context-http-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspacePath = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Probe", title: "Probe", description: "", handle: "probe", soul: "", provider: .distill, model: "test")
        let host = "active-context-http"
        let workspace = Workspace.empty(name: "Probe", cwd: workspacePath.path)
        let contexts: [BotContext] = [.workspace(workspace.id), .general]
        let secrets = BlockingContextSecrets()
        let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil)
        var resources: [BotContextGuestResources] = []
        var identities: [BotContextRuntimeIdentity] = []
        var envURLs: [URL] = []
        defer {
            var cleaned = true
            for resource in resources { do { try resource.finish() } catch { cleaned = false; XCTFail("Resource cleanup failed: \(error)") } }
            for identity in identities {
                do {
                    try service.wipe(identity: identity)
                    XCTAssertFalse(try docker.containerExists(name: BotComputerGuestSpec.containerName(botID: identity.storageBotID)))
                    XCTAssertFalse(try docker.networkExists(name: BotComputerGuestSpec.networkName(botID: identity.storageBotID)))
                } catch { cleaned = false; XCTFail("Runtime cleanup failed: \(error)") }
            }
            if cleaned { do { try FileManager.default.removeItem(at: root) } catch { XCTFail("Fixture cleanup failed: \(error)") } }
        }
        let values = [UUID().uuidString, UUID().uuidString]
        for (index, context) in contexts.enumerated() {
            let binding = try store.grantContext(hostID: host, botID: bot.id, context: context, actions: [.read, .send, .configure, .files], expectedRevision: 0)
            let identity = try BotContextRuntimeIdentity(binding: binding)
            identities.append(identity)
            try secrets.save(botID: identity.storageBotID, name: "CONTEXT_MARKER", value: values[index])
            try secrets.save(botID: identity.storageBotID, name: "ONLY_\(index)", value: UUID().uuidString)
            let thread = AgentThread(workspaceId: index == 0 ? workspace.id : nil, title: "Context", provider: .distill, model: "test")
            let conversation = BotConversation(botID: bot.id, title: "Context", linkedAgentThreadID: thread.id)
            _ = try store.createContextualConversation(conversation, newThread: thread, hostID: host, context: context, policyRevision: binding.policyRevision)
            let request = AgentRunRequest(threadId: thread.id, provider: .distill, model: "test", cwd: index == 0 ? workspace.cwd : BotHome(appSupportDirectory: support, bot: bot).root.path, prompt: "probe", environment: ["CONTEXT_MARKER": "inherited", "ONLY_\(index)": "inherited", BotSecretEnvironment.secretNamesEnvironmentKey: "CONTEXT_MARKER,ONLY_\(index)"])
            resources.append(try BotContextGuestResources.prepare(request: request, hostID: host, store: store, threadRepo: AgentThreadRepository(db: db), service: service, appSupport: support, workspace: index == 0 ? workspace : nil, registeredWorkspaces: [workspace.cwd], secretStore: secrets))
        }
        envURLs = try resources.map { try XCTUnwrap($0.envFileURL) }
        try assertActiveContextHTTPRevocation(resources: resources, secrets: secrets, docker: docker, environmentFiles: envURLs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: envURLs[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: envURLs[1].path))
        try resources[1].finish()
        for resource in resources { try resource.finish(); try resource.finish() }
        for url in envURLs { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        print("Prepared context active HTTP revocation probe passed; resources cleaned: \(root.path)")
    }
}
