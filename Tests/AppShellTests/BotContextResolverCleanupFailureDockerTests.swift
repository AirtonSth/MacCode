import AgentRuntime
import CoreModel
import Foundation
import Persistence
import SocketServer
import XCTest
@testable import AppShell

@MainActor
final class BotContextResolverCleanupFailureDockerTests: XCTestCase {
    func testResolverStopFailureKeepsRecoveryPendingAndRefusesPendingDelegation() async throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for real Docker resolver probe")
        }
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        guard try docker.imageExists(tag: BotComputerGuestSpec.imageTag),
              try docker.imageLabel(tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey) == BotComputerGuestSpec.recipeRevision else {
            throw XCTSkip("matching existing Docker image required; probe never builds or pulls")
        }
        let scratch = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]), isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let root = scratch.appendingPathComponent("resolver-descendants-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let database = root.appendingPathComponent("probe.sqlite")
        let dockerGate = DescendantCleanupDocker(real: docker)
        var identities: [BotContextRuntimeIdentity] = []
        var workers: [Task<Void, Never>] = []
        var observer: DescendantStageObserver? = nil
        var cleanupConfirmed = true
        var finishLiveResources: (() async -> Void)?
        let manifest = root.appendingPathComponent("fixture-manifest.json")
        try JSONSerialization.data(withJSONObject: ["ownedIDs": []]).write(to: manifest, options: .atomic)
        func cleanup() async {
            dockerGate.failChildStop = false
            observer?.releaseAll()
            for worker in workers { await worker.value }
            await finishLiveResources?()
            for identity in identities {
                do {
                    let name = BotComputerGuestSpec.containerName(botID: identity.storageBotID)
                    try docker.stop(name: name)
                    try BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil).wipe(identity: identity)
                    let containerExists = try docker.containerExists(name: name)
                    let networkExists = try docker.networkExists(name: BotComputerGuestSpec.networkName(botID: identity.storageBotID))
                    cleanupConfirmed = cleanupConfirmed && !containerExists && !networkExists
                    XCTAssertFalse(containerExists)
                    XCTAssertFalse(networkExists)
                } catch { cleanupConfirmed = false; XCTFail("Owned Docker cleanup failed; preserve manifest at \(manifest.path): \(error)") }
            }
            if cleanupConfirmed { try? FileManager.default.removeItem(at: root) }
        }
        do {
            let context = try AppContext(channel: .debug, dbPathOverride: database.path, appSupportOverride: support.path,
                privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: true,
                contextualSecretStore: InMemoryBotSecretStore(), guestDocker: dockerGate)
            context.router = AppCommandRouter(context: context)
            let host = context.liveActivityHostIdentity.serverId
            let workspacePath = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
            let workspace = try XCTUnwrap(context.router).createWorkspace(name: "Descendant probe", cwd: workspacePath.path)
            let parent = try context.botStore.create(name: "Parent", title: "Parent", description: "", handle: "parent-\(UUID().uuidString.prefix(8))", soul: "", provider: .distill, model: "test")
            let child = try context.botStore.create(name: "Child", title: "Child", description: "", handle: "child-\(UUID().uuidString.prefix(8))", soul: "", provider: .distill, model: "test")
            let grant = try context.botStore.grantContext(hostID: host, botID: parent.id, context: .workspace(workspace.id), actions: [.read, .send, .configure, .files, .delegate], expectedRevision: 0)
            let childGrant = try context.botStore.grantContext(hostID: host, botID: child.id, context: .workspace(workspace.id), actions: [.read, .send, .configure, .files], expectedRevision: 0)
            let unrelated = try context.botStore.create(name: "Unrelated", title: "Unrelated", description: "", handle: "unrelated-\(UUID().uuidString.prefix(8))", soul: "", provider: .distill, model: "test")
            let unrelatedGrant = try context.botStore.grantContext(hostID: host, botID: unrelated.id, context: .workspace(workspace.id), actions: [.read, .send, .configure, .files], expectedRevision: 0)
            identities = try [grant, childGrant, unrelatedGrant].map { try BotContextRuntimeIdentity(binding: $0) }
            dockerGate.childName = BotComputerGuestSpec.containerName(botID: identities[0].storageBotID)
            try JSONSerialization.data(withJSONObject: ["ownedIDs": identities.map { $0.storageBotID.value.uuidString.lowercased() }]).write(to: manifest, options: .atomic)
            let marker = root.appendingPathComponent("provider-marker")
            try Data("#!/bin/sh\necho ran > '\(root.appendingPathComponent("provider-ran").path)'\nexit 99\n".utf8).write(to: marker)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: marker.path)
            let observerInstance = DescendantStageObserver()
            observer = observerInstance
            context.coordinator.addObserver(observerInstance)
            defer { context.coordinator.removeObserver(observerInstance) }
            var requests: [AgentRunRequest] = []
            for (bot, binding) in [(parent, grant), (child, childGrant), (unrelated, unrelatedGrant)] {
                let thread = AgentThread(workspaceId: workspace.id, title: bot.title, provider: .distill, model: "test")
                _ = try context.botStore.createContextualConversation(BotConversation(botID: bot.id, title: thread.title, linkedAgentThreadID: thread.id), newThread: thread, hostID: host, context: binding.context, policyRevision: binding.policyRevision)
                requests.append(AgentRunRequest(threadId: thread.id, provider: .distill, model: "test", cwd: workspace.cwd, prompt: "synthetic descendant probe", providerBinary: marker.path))
            }
            for request in requests { observerInstance.arm(run: request.runId) }
            for request in requests {
                workers.append(Task { @MainActor in
                    do { _ = try await context.coordinator.startRun(request) } catch { }
                })
            }
            for request in requests {
                guard await observerInstance.waitUntilReady(run: request.runId, timeout: 90) else {
                    throw NSError(domain: "ResolverProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Real resolver did not reach preparingAgent"])
                }
            }
            XCTAssertEqual(try context.runRepo.get(id: requests[0].runId)?.status, .pending)
            XCTAssertThrowsError(try context.botStore.recordContextDelegation(hostID: host, parentRunID: requests[0].runId,
                childRunID: requests[1].runId, childThreadID: requests[1].threadId)) { error in
                guard case BotStoreError.notFound = error else { return XCTFail("Unexpected delegation refusal") }
            }
            XCTAssertNil(try context.botStore.contextDelegation(childRunID: requests[1].runId))
            func journal(_ index: Int) -> URL {
                DistillGuestEnvironment.runsDirectory(appSupport: support)
                    .appendingPathComponent(identities[index].storageBotID.value.uuidString.lowercased())
                    .appendingPathComponent(requests[index].runId.value.uuidString.lowercased() + ".context.json")
            }
            func env(_ index: Int) -> URL {
                journal(index).deletingLastPathComponent().appendingPathComponent(requests[index].runId.value.uuidString.lowercased() + ".env")
            }
            func config(_ index: Int) -> URL {
                BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: identities[index].storageBotID)
                    .appendingPathComponent(".distill-context-\(requests[index].runId.value.uuidString.lowercased())/config.toml")
            }
            func state(_ index: Int) throws -> BotContextGuestRecovery.Record.State {
                try JSONDecoder().decode(BotContextGuestRecovery.Record.self, from: Data(contentsOf: journal(index))).state
            }
            var gatewayRequests: [URLRequest] = []
            for index in requests.indices {
                let text = try String(contentsOf: config(index), encoding: .utf8)
                let line = try XCTUnwrap(text.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("url =") })
                let guestURL = try XCTUnwrap(line.split(separator: "\"").dropFirst().first)
                var components = try XCTUnwrap(URLComponents(string: String(guestURL)))
                components.host = "127.0.0.1"
                let contents = try String(contentsOf: env(index), encoding: .utf8)
                let tokenLine = try XCTUnwrap(contents.split(separator: "\n").first { $0.hasPrefix(DistillGuestConfig.gatewayTokenEnvironmentKey + "=") })
                var request = URLRequest(url: try XCTUnwrap(components.url))
                request.httpMethod = "POST"
                request.setValue("Bearer " + String(tokenLine.dropFirst(DistillGuestConfig.gatewayTokenEnvironmentKey.count + 1)), forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"bot_list_secrets","arguments":{}}}"#.utf8)
                request.timeoutInterval = 3
                gatewayRequests.append(request)
            }
            finishLiveResources = {
                for request in requests {
                    BotContextGuestResources.requestFinish(runID: request.runId, threadID: request.threadId,
                        store: context.botStore, appSupport: support)
                }
                let deadline = Date().addingTimeInterval(10)
                var closed = Set<Int>()
                while Date() < deadline && closed.count < gatewayRequests.count {
                    for index in gatewayRequests.indices where !closed.contains(index) {
                        var request = URLRequest(url: gatewayRequests[index].url!)
                        request.timeoutInterval = 1
                        do { _ = try await URLSession.shared.data(for: request) }
                        catch let error as URLError where error.code == .cannotConnectToHost { closed.insert(index) }
                        catch { }
                    }
                    if closed.count < gatewayRequests.count { try? await Task.sleep(for: .milliseconds(20)) }
                }
                if closed.count != gatewayRequests.count {
                    cleanupConfirmed = false
                    XCTFail("Owned resource gateways did not close after successful cleanup retry")
                }
            }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            func status(_ index: Int) async throws -> Int {
                let (_, response) = try await session.data(for: gatewayRequests[index])
                return try XCTUnwrap(response as? HTTPURLResponse).statusCode
            }
            for index in requests.indices {
                let before = try await status(index)
                XCTAssertEqual(before, 200)
            }
            let childConversationIDs = try context.botStore.listConversations(botID: child.id).map(\.id)
            var admission = gatewayRequests[0]
            admission.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "bot_ask_peer", "arguments": ["handle": child.handle, "prompt": "owned", "reply_mode": "consult"]]])
            let (admissionData, admissionResponse) = try await session.data(for: admission)
            XCTAssertEqual(try XCTUnwrap(admissionResponse as? HTTPURLResponse).statusCode, 200)
            let admissionJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: admissionData) as? [String: Any])
            let admissionError = try XCTUnwrap(admissionJSON["error"] as? [String: Any])
            XCTAssertEqual(admissionError["code"] as? Int, -32602)
            XCTAssertTrue(try XCTUnwrap(admissionError["message"] as? String).contains("not available"))
            XCTAssertEqual(try context.botStore.listConversations(botID: child.id).map(\.id), childConversationIDs)
            XCTAssertNil(try context.botStore.contextDelegation(childRunID: requests[1].runId))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("provider-ran").path))
            dockerGate.failChildStop = true
            context.coordinator.stopRun(requests[0].runId)
            observerInstance.release(run: requests[0].runId)
            await workers[0].value
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline && (dockerGate.failures == 0 || FileManager.default.fileExists(atPath: env(0).path)) {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertGreaterThan(dockerGate.failures, 0, "Stop must attempt physical runtime cleanup")
            XCTAssertNil(try context.botStore.contextDelegation(childRunID: requests[1].runId))
            XCTAssertEqual(try state(0), .pending, "Failed runtime stop must not claim completed cleanup")
            XCTAssertTrue(try docker.inspect(name: dockerGate.childName).running)
            for index in [0] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: env(index).path))
                do {
                    let denied = try await status(index)
                    XCTAssertEqual(denied, 401)
                } catch let error as URLError {
                    XCTAssertTrue([URLError.cannotConnectToHost, .networkConnectionLost].contains(error.code))
                }
            }
            let unrelatedStatus = try await status(2)
            XCTAssertEqual(unrelatedStatus, 200)
            XCTAssertTrue(try docker.inspect(name: BotComputerGuestSpec.containerName(botID: identities[2].storageBotID)).running)
            _ = try await XCTUnwrap(context.router).dispatchPairedBotRemote(method: "bot.context.revoke", params: [
                "client_request_id": .string(UUID().uuidString), "host_id": .string(host),
                "bot_id": .string(parent.id.value.uuidString), "context_key": .string(grant.context.storageKey),
                "context_version": .number(1), "policy_revision": .number(Double(grant.policyRevision)),
            ])
            XCTAssertFalse(try context.botStore.authorizes(hostID: host, botID: parent.id, context: grant.context, action: .send, policyRevision: grant.policyRevision))
            XCTAssertEqual(try state(0), .pending)
            let stillUnrelated = try await status(2)
            XCTAssertEqual(stillUnrelated, 200)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("provider-ran").path))
            // Launch recovery reconciles every scope; end unrelated preparation before invoking it.
            observerInstance.releaseAll()
            for worker in workers { await worker.value }
            let failedRecovery = await Task.detached {
                BotContextGuestRecovery.reconcile(docker: dockerGate, appSupport: support)
            }.value
            let failedScope = identities[0].storageBotID.value.uuidString.lowercased()
            XCTAssertNotNil(failedRecovery.failures[failedScope])
            XCTAssertEqual(try state(0), .pending)
            XCTAssertTrue(try docker.inspect(name: dockerGate.childName).running)
            dockerGate.failChildStop = false
            let recovered = await Task.detached {
                BotContextGuestRecovery.reconcile(docker: dockerGate, appSupport: support)
            }.value
            XCTAssertTrue(recovered.failures.isEmpty, "Recovery must report all unresolved cleanup")
            for index in [0] {
                XCTAssertEqual(try state(index), .ended)
                XCTAssertFalse(try docker.inspect(name: BotComputerGuestSpec.containerName(botID: identities[index].storageBotID)).running)
                XCTAssertFalse(FileManager.default.fileExists(atPath: env(index).path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: config(index).path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("provider-ran").path))

        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }
}

final class DescendantCleanupDocker: BotComputerDockerClienting, @unchecked Sendable {
    let real: BotComputerDockerCLI
    private let lock = NSLock()
    private var shouldFail = false
    private var failureCount = 0
    var childName = ""
    var failures: Int { lock.withLock { failureCount } }
    init(real: BotComputerDockerCLI) { self.real = real }
    var failChildStop: Bool { get { lock.withLock { shouldFail } } set { lock.withLock { shouldFail = newValue } } }
    func info() throws -> String { try real.info() }
    func imageExists(tag: String) throws -> Bool { try real.imageExists(tag: tag) }
    func imageLabel(tag: String, key: String) throws -> String { try real.imageLabel(tag: tag, key: key) }
    func imageID(tag: String) throws -> String { try real.imageID(tag: tag) }
    func imageStates(tags: [String]) throws -> [String: BotComputerImageState] { try real.imageStates(tags: tags) }
    func build(context: URL, tag: String) throws { try real.build(context: context, tag: tag) }
    func create(options: BotComputerContainerCreateOptions) throws -> String { try real.create(options: options) }
    func start(name: String) throws { try real.start(name: name) }
    func stop(name: String) throws {
        let fail = lock.withLock { () -> Bool in
            guard shouldFail && name == childName else { return false }
            failureCount += 1
            return true
        }
        if fail { throw BotComputerDockerError.provisioningFailed }
        try real.stop(name: name)
    }
    func inspect(name: String) throws -> BotComputerContainerInspect { try real.inspect(name: name) }
    func containerExists(name: String) throws -> Bool { try real.containerExists(name: name) }
    func exec(name: String, command: [String], user: String?, detach: Bool, workdir: String?, environment: [String: String]) throws -> Data { try real.exec(name: name, command: command, user: user, detach: detach, workdir: workdir, environment: environment) }
    func rename(from: String, to: String) throws { try real.rename(from: from, to: to) }
    func ensureNetwork(name: String) throws { try real.ensureNetwork(name: name) }
    func removeNetwork(name: String) throws { try real.removeNetwork(name: name) }
    func networkExists(name: String) throws -> Bool { try real.networkExists(name: name) }
    func remove(name: String) throws { try real.remove(name: name) }
    func removeMatching(namePrefix: String) throws { try real.removeMatching(namePrefix: namePrefix) }
    func top(name: String) throws -> String { try real.top(name: name) }
}

private final class DescendantStageObserver: AgentRunObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [AgentRunID: DispatchSemaphore] = [:]
    private var ready: Set<AgentRunID> = []
    func arm(run: AgentRunID) { lock.withLock { gates[run] = DispatchSemaphore(value: 0) } }
    func release(run: AgentRunID) { lock.withLock { gates[run]?.signal() } }
    func releaseAll() { lock.withLock { gates.values.forEach { $0.signal() } } }
    func waitUntilReady(run: AgentRunID, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if lock.withLock({ ready.contains(run) }) { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return false
    }
    func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {
        guard case .providerRuntime(let runtime) = event, runtime.method == DistillGuestStage.runtimeMethod,
              (try? JSONDecoder().decode([String: String].self, from: Data(runtime.payloadJSON.utf8))["stage"]) == DistillGuestStage.preparingAgent.rawValue else { return }
        let semaphore = lock.withLock { ready.insert(run); return gates[run] }
        _ = semaphore?.wait(timeout: .now() + 90)
    }
    func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {}
    func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {}
}
