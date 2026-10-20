import AgentRuntime
import CoreModel
import Foundation
import Persistence
import SocketServer
import XCTest
@testable import AppShell

@MainActor
final class BotContextInternalAdmissionTests: XCTestCase {
    private let fixtureModel = "openrouter/provider/model"

    private func scratchRoot() throws -> URL {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"], "RC_CONTEXT_PROBE_ROOT must name invocation-owned scratch")
        let parent = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("InternalAdmission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func context(root: URL, secrets: any BotSecretStore = InMemoryBotSecretStore()) throws -> AppContext {
        let context = try AppContext(channel: .debug, dbPathOverride: root.appendingPathComponent("context.sqlite").path,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path,
            privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: true,
            contextualSecretStore: secrets)
        context.router = AppCommandRouter(context: context)
        return context
    }

    func testMissingScopedKeyAndUnsupportedModelRejectBeforeRunCreation() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try context(root: root)
        defer { withExtendedLifetime(context) {} }
        let host = context.liveActivityHostIdentity.serverId
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let workspace = try XCTUnwrap(context.router).createWorkspace(name: "Admission", cwd: workspaceRoot.path)
        let bot = try context.botStore.create(name: "Admission", title: "Admission", description: "", handle: "admission", soul: "", provider: .distill, model: fixtureModel)
        let grant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .workspace(workspace.id), actions: [.read, .send, .configure, .files], expectedRevision: 0)
        let storageID = try BotContextRuntimeIdentity(binding: grant).storageBotID

        func makeThread(model: String) throws -> AgentThread {
            let thread = AgentThread(workspaceId: workspace.id, title: "Admission", provider: .distill, model: model, permissionMode: .supervised)
            try context.botStore.createContextualConversation(BotConversation(botID: bot.id, title: thread.title, linkedAgentThreadID: thread.id), newThread: thread, hostID: host, context: grant.context, policyRevision: grant.policyRevision)
            return thread
        }

        let missingThread = try makeThread(model: fixtureModel)
        let missingKey = AgentRunRequest(threadId: missingThread.id, provider: .distill, model: fixtureModel, cwd: workspace.cwd, prompt: "must refuse")
        let pin = try XCTUnwrap(context.botStore.conversationContextPin(linkedTo: missingThread.id))
        XCTAssertTrue(BotContextRunAdmissions.authorizes(pin: pin, threadID: missingThread.id,
            runID: missingKey.runId, parentRunID: nil, hostID: host, store: context.botStore,
            threadRepo: context.threadRepo, runRepo: context.runRepo), "Explicit canonical grants must pass before the missing-key refusal")
        do { _ = try await context.startContextualRun(missingKey); XCTFail("Missing scoped provider key must refuse") } catch { }
        XCTAssertNil(try context.runRepo.get(id: missingKey.runId))

        try context.contextualSecretStore.save(botID: storageID, name: "OPENROUTER_API_KEY", value: "test-only-invalid")
        let unsupportedModel = "unsupported/model"
        let unsupportedThread = try makeThread(model: unsupportedModel)
        let unsupported = AgentRunRequest(threadId: unsupportedThread.id, provider: .distill, model: unsupportedModel, cwd: workspace.cwd, prompt: "must refuse")
        do { _ = try await context.startContextualRun(unsupported); XCTFail("Unsupported model must refuse") } catch { }
        XCTAssertNil(try context.runRepo.get(id: unsupported.runId))

        let customBinary = AgentRunRequest(threadId: missingThread.id, provider: .distill, model: fixtureModel, cwd: workspace.cwd, prompt: "must refuse", providerBinary: root.appendingPathComponent("custom-provider").path)
        do { _ = try await context.startContextualRun(customBinary); XCTFail("Caller provider binary must refuse") } catch { }
        XCTAssertNil(try context.runRepo.get(id: customBinary.runId))
        var storedSession = try XCTUnwrap(context.threadRepo.get(id: missingThread.id))
        storedSession.providerThreadId = "existing-session"
        try context.threadRepo.upsert(storedSession)
        let existingSession = AgentRunRequest(threadId: missingThread.id, provider: .distill, model: fixtureModel, cwd: workspace.cwd, prompt: "must refuse")
        do { _ = try await context.startContextualRun(existingSession); XCTFail("An unbound stored provider cursor must refuse before admission") }
        catch let error as DistillGuestLaunchError {
            XCTAssertEqual(error, .unavailable("The contextual provider session cannot be resumed safely."))
        }
        XCTAssertNil(try context.runRepo.get(id: existingSession.runId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: BotComputerGuestSpec.guestHomeRoot(appSupport: root.appendingPathComponent("support", isDirectory: true)).path))
    }

    func testPeerWithoutRunningParentRefusesWithoutCreatingConversation() async throws {
        let root = try scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try context(root: root)
        defer { withExtendedLifetime(context) {} }
        let host = context.liveActivityHostIdentity.serverId
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let workspace = try XCTUnwrap(context.router).createWorkspace(name: "Peer admission", cwd: workspaceRoot.path)
        let parent = try context.botStore.create(name: "Parent", title: "Parent", description: "", handle: "parent", soul: "", provider: .distill, model: fixtureModel)
        let peer = try context.botStore.create(name: "Peer", title: "Peer", description: "", handle: "peer", soul: "", provider: .distill, model: fixtureModel)
        let binding = try context.botStore.grantContext(hostID: host, botID: parent.id, context: .workspace(workspace.id), actions: [.read, .send, .configure, .files, .delegate], expectedRevision: 0)
        _ = try context.botStore.grantContext(hostID: host, botID: peer.id, context: .workspace(workspace.id), actions: [.read, .send, .configure, .files], expectedRevision: 0)
        let parentThread = AgentThread(workspaceId: workspace.id, title: "Parent", provider: .distill, model: fixtureModel)
        try context.botStore.createContextualConversation(BotConversation(botID: parent.id, title: parentThread.title, linkedAgentThreadID: parentThread.id), newThread: parentThread, hostID: host, context: binding.context, policyRevision: binding.policyRevision)
        let parentRun = AgentRunRequest(threadId: parentThread.id, provider: .distill, model: fixtureModel, cwd: workspace.cwd, prompt: "not running")

        do { _ = try await context.startContextualPeerRun(parentRunID: parentRun.runId, peerBotID: peer.id, prompt: "must refuse"); XCTFail("Peer run must require an actually running parent") } catch { }
        XCTAssertTrue(try context.botStore.listConversations(botID: peer.id).isEmpty)
    }

    func testScopedProviderConfigurationKeepsKeyOutOfTOMLAndShell() throws {
        let config = try BotContextRunAdmissions.configuration(model: fixtureModel)
        XCTAssertTrue(config.contains("[model.\"openrouter/provider/model\"]"))
        XCTAssertFalse(config.contains("\\/"), "JSON slash escapes are not valid TOML escapes")
        let rendered = DistillGuestConfig.render(hostConfig: config, gatewayPort: 12345,
            hostEnvironment: ["OPENROUTER_API_KEY": "owned-config-check"])
        XCTAssertNil(rendered.droppedModels[fixtureModel])
        XCTAssertFalse(rendered.toml.contains("owned-config-check"))
        XCTAssertTrue(rendered.toml.contains("exclude = [\"OPENROUTER_API_KEY\", \"RC_GUEST_GATEWAY_TOKEN\"]"))
    }

    func testAdmissionValidationCanDiscardSameRunWithoutDeadlock() async throws {
        let registry = BotContextRunAdmissions()
        let permit = AgentRunAcceptancePermit()
        let runID = AgentRunID()
        let threadID = AgentThreadID()
        let admission = BotContextRunAdmissions.Admission(runID: runID, threadID: threadID,
            pin: BotConversationContextPin(conversationID: BotConversationID(), hostID: "host", botID: BotID(), context: .general, policyRevision: 1),
            parentRunID: nil, model: fixtureModel, cwd: "/tmp", permit: permit, providerConfiguration: "",
            validates: { registry.discard(runID: runID); return true })
        try registry.register(admission)
        let request = AgentRunRequest(runId: runID, threadId: threadID, provider: .distill, model: fixtureModel, cwd: "/tmp", prompt: "test", acceptancePermit: permit)
        let completed = expectation(description: "consume validation can discard same run")
        DispatchQueue.global().async {
            XCTAssertNotNil(try? registry.consume(request))
            XCTAssertNil(try? registry.consume(request), "Consumed admission must not replay")
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
    }

    func testAdmissionRegistryConsumesOnceOnlyForExactPermit() throws {
        let registry = BotContextRunAdmissions()
        let permit = AgentRunAcceptancePermit()
        let runID = AgentRunID()
        let threadID = AgentThreadID()
        let admission = BotContextRunAdmissions.Admission(runID: runID, threadID: threadID,
            pin: BotConversationContextPin(conversationID: BotConversationID(), hostID: "host", botID: BotID(), context: .general, policyRevision: 1),
            parentRunID: nil, model: fixtureModel, cwd: "/tmp", permit: permit, providerConfiguration: "",
            validates: { true })
        try registry.register(admission)
        var request = AgentRunRequest(runId: runID, threadId: threadID, provider: .distill, model: fixtureModel, cwd: "/tmp", prompt: "test")
        XCTAssertThrowsError(try registry.consume(request), "A different permit must not consume admission")
        request.acceptancePermit = permit
        XCTAssertNotNil(try registry.consume(request))
        XCTAssertNil(try registry.consume(request), "Admission must be one-use")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(encoded["acceptancePermit"])
    }
}
