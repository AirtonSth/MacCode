import CryptoKit
import Foundation
import XCTest
import AgentRuntime
import CoreModel
import Persistence
@testable import AppShell

@MainActor
final class BotContextDelegationDockerProbeTests: XCTestCase {
    func test_sameContextResourceDelegationThroughRealDocker() async throws {
        try await run_sameContextResourceDelegationThroughRealDocker(injectChildStopFailure: false)
    }

    func test_sameContextResourceDelegationStopFailureThroughRealDocker() async throws {
        try await run_sameContextResourceDelegationThroughRealDocker(injectChildStopFailure: true)
    }

    private func run_sameContextResourceDelegationThroughRealDocker(injectChildStopFailure: Bool) async throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for the real Docker delegation probe")
        }
        let realDocker = BotComputerDockerCLI()
        _ = try realDocker.info()
        XCTAssertTrue(try realDocker.imageExists(tag: BotComputerGuestSpec.imageTag))
        XCTAssertEqual(try realDocker.imageLabel(tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey), BotComputerGuestSpec.recipeRevision)
        let probeRoot = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]), isDirectory: true)
        let root = probeRoot.appendingPathComponent("delegation-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cleanupConfirmed = true
        defer {
            if cleanupConfirmed {
                do { try FileManager.default.removeItem(at: root) }
                catch { XCTFail("Fixture cleanup failed: \(error)") }
            }
        }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let database = root.appendingPathComponent("probe.sqlite")
        let ctx = try AppContext(channel: .debug, dbPathOverride: database.path, appSupportOverride: support.path, privateAccountAPI: SilentWakeRecordingAPI(), performLaunchRunReconciliation: false)
        ctx.router = AppCommandRouter(context: ctx)
        let store = ctx.botStore
        let host = ctx.liveActivityHostIdentity.serverId
        let workspacePath = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        let workspace = try XCTUnwrap(ctx.router).createWorkspace(name: "Delegation A", cwd: workspacePath.path)
        let contextA = BotContext.workspace(workspace.id)
        let parentBot = try store.create(name: "Parent", title: "Parent", description: "", handle: "parent", soul: "", provider: .distill, model: "test")
        let childBot = try store.create(name: "Child", title: "Child", description: "", handle: "child", soul: "", provider: .distill, model: "test")
        let parentGrant = try store.grantContext(hostID: host, botID: parentBot.id, context: contextA, actions: [.read, .send, .configure, .files, .delegate], expectedRevision: 0)
        let childGrant = try store.grantContext(hostID: host, botID: childBot.id, context: contextA, actions: [.read, .send, .configure, .files], expectedRevision: 0)
        let generalGrant = try store.grantContext(hostID: host, botID: childBot.id, context: .general, actions: [.read, .send, .configure], expectedRevision: 0)
        let identities = try [parentGrant, childGrant, generalGrant].map { try BotContextRuntimeIdentity(binding: $0) }
        let secrets = InMemoryBotSecretStore()
        let markers = (0..<3).map { _ in UUID().uuidString }
        let names = ["ONLY_PARENT", "ONLY_A", "ONLY_B"]
        for index in identities.indices {
            try secrets.save(botID: identities[index].storageBotID, name: "CONTEXT_MARKER", value: markers[index])
            try secrets.save(botID: identities[index].storageBotID, name: names[index], value: "synthetic")
        }
        let docker = DescendantCleanupDocker(real: realDocker)
        let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil)
        var resources: [BotContextGuestResources] = []
        var heartbeats: [BotGuestLeaseHeartbeat] = []
        defer {
            docker.failChildStop = false
            for heartbeat in heartbeats { heartbeat.stop() }
            for resource in resources {
                do { try resource.finish() } catch { cleanupConfirmed = false; XCTFail("Resource cleanup failed: \(error)") }
            }
            for identity in identities {
                do {
                    try service.wipe(identity: identity)
                    let containerExists = try docker.containerExists(name: BotComputerGuestSpec.containerName(botID: identity.storageBotID))
                    let networkExists = try docker.networkExists(name: BotComputerGuestSpec.networkName(botID: identity.storageBotID))
                    cleanupConfirmed = cleanupConfirmed && !containerExists && !networkExists
                    XCTAssertFalse(containerExists)
                    XCTAssertFalse(networkExists)
                } catch { cleanupConfirmed = false; XCTFail("Runtime cleanup failed: \(error)") }
            }
        }
        func request(bot: BotDefinition, binding: BotContextBinding) throws -> AgentRunRequest {
            let thread = AgentThread(workspaceId: binding.context == .general ? nil : workspace.id, title: "Probe", provider: .distill, model: "test")
            _ = try store.createContextualConversation(BotConversation(botID: bot.id, title: "Probe", linkedAgentThreadID: thread.id), newThread: thread, hostID: host, context: binding.context, policyRevision: binding.policyRevision)
            let run = AgentRun(threadId: thread.id, provider: .distill, model: "test", status: .running)
            try ctx.runRepo.upsert(run)
            return AgentRunRequest(runId: run.id, threadId: thread.id, provider: .distill, model: "test", cwd: binding.context == .general ? BotHome(appSupportDirectory: support, bot: bot).root.path : workspace.cwd, prompt: "synthetic resource probe")
        }
        let parentRequest = try request(bot: parentBot, binding: parentGrant)
        let childRequest = try request(bot: childBot, binding: childGrant)
        let generalRequest = try request(bot: childBot, binding: generalGrant)
        func prepare(_ request: AgentRunRequest, workspace: Workspace?, parent: AgentRunID? = nil) throws -> BotContextGuestResources {
            try BotContextGuestResources.prepare(request: request, hostID: host, store: store, threadRepo: ctx.threadRepo, service: service, appSupport: support, workspace: workspace, registeredWorkspaces: [workspacePath.path], secretStore: secrets, parentRunID: parent)
        }
        resources.append(try prepare(parentRequest, workspace: workspace))
        resources.append(try prepare(childRequest, workspace: workspace, parent: parentRequest.runId))
        XCTAssertFalse(try XCTUnwrap(store.contextDelegation(childRunID: childRequest.runId)).closed)
        // Cross-context refusal must occur before B has a live resource slot.
        XCTAssertThrowsError(try prepare(generalRequest, workspace: nil, parent: parentRequest.runId))
        XCTAssertNil(try store.contextDelegation(childRunID: generalRequest.runId))
        XCTAssertFalse(try docker.containerExists(name: BotComputerGuestSpec.containerName(botID: identities[2].storageBotID)))
        resources.append(try prepare(generalRequest, workspace: nil))
        let envFiles = try resources.map { try XCTUnwrap($0.envFileURL) }
        let client = #"""
        const fs=require('node:fs'),http=require('node:http'),path=require('node:path'),crypto=require('node:crypto');
        const config=fs.readFileSync(path.join(process.env.DISTILL_HOME,'config.toml'),'utf8');
        const block=config.split('[mcp_servers.').find(s=>s.includes('bearer_token_env_var'));
        const url=new URL(block.match(/url\s*=\s*"([^"]+)"/)[1]);
        const token=process.env[block.match(/bearer_token_env_var\s*=\s*"([^"]+)"/)[1]];
        const body=JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'bot_list_secrets',arguments:{}}});
        const req=http.request(url,{method:'POST',headers:{authorization:'Bearer '+token,'content-type':'application/json','content-length':Buffer.byteLength(body)}},res=>{
          let data='';res.on('data',c=>data+=c);res.on('end',()=>{
            let names=[];if(res.statusCode===200)names=JSON.parse(JSON.parse(data).result.content[0].text).secrets;
            process.stdout.write(JSON.stringify({status:res.statusCode,names,hash:crypto.createHash('sha256').update(process.env.CONTEXT_MARKER||'').digest('hex')}));
          });
        });req.setTimeout(5000,()=>req.destroy(Error('timeout')));req.on('error',()=>process.exit(2));req.end(body);
        """#
        func invoke(_ index: Int) throws -> [String: Any] {
            let data = try realDocker.run(["exec", "--env-file", envFiles[index].path, resources[index].container, "node", "-e", client])
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        for index in [1, 2] {
            let result = try invoke(index)
            XCTAssertEqual(result["status"] as? Int, 200)
            XCTAssertEqual((result["names"] as? [String])?.sorted(), ["CONTEXT_MARKER", names[index]].sorted())
            XCTAssertEqual(result["hash"] as? String, SHA256.hash(data: Data(markers[index].utf8)).map { String(format: "%02x", $0) }.joined())
        }
        let config = try String(contentsOf: try XCTUnwrap(resources[1].configDirectory).appendingPathComponent("config.toml"), encoding: .utf8)
        let urlLine = try XCTUnwrap(config.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("url =") })
        let guestURL = try XCTUnwrap(urlLine.split(separator: "\"").dropFirst().first)
        var hostURL = try XCTUnwrap(URLComponents(string: String(guestURL)))
        hostURL.host = "127.0.0.1"
        let environment = try String(contentsOf: envFiles[1], encoding: .utf8)
        let tokenLine = try XCTUnwrap(environment.split(separator: "\n").first { $0.hasPrefix(DistillGuestConfig.gatewayTokenEnvironmentKey + "=") })
        let token = String(tokenLine.dropFirst(DistillGuestConfig.gatewayTokenEnvironmentKey.count + 1))
        var httpRequest = URLRequest(url: try XCTUnwrap(hostURL.url))
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"bot_list_secrets","arguments":{}}}"#.utf8)
        httpRequest.timeoutInterval = 3
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, beforeResponse) = try await session.data(for: httpRequest)
        XCTAssertEqual((beforeResponse as? HTTPURLResponse)?.statusCode, 200)
        let sentinel = #"const fs=require('fs');fs.writeFileSync('/home/remotecode/.delegation-probe.pid',String(process.pid));setInterval(()=>fs.writeFileSync('/home/remotecode/.delegation-probe-pulse',String(Date.now())),100);"#
        for index in [1, 2] {
            let resource = resources[index]
            if injectChildStopFailure, index == 1 { docker.childName = resource.container; docker.failChildStop = true }
            heartbeats.append(try BotGuestLeaseHeartbeat(guestHome: BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: resource.identity.storageBotID), runID: resource.runID.value.uuidString.lowercased()))
            _ = try realDocker.run(["exec", "--env-file", envFiles[index].path, "-d", resource.container, BotComputerGuestSpec.runAgentPath, resource.runID.value.uuidString.lowercased(), "--", "node", "-e", sentinel])
            _ = try realDocker.run(["exec", resource.container, "sh", "-c", "for i in 1 2 3 4 5 6 7 8 9 10; do if test -f /home/remotecode/.delegation-probe.pid && kill -0 $(cat /home/remotecode/.delegation-probe.pid); then exit 0; fi; sleep 0.1; done; exit 1"])
        }
        let authority = try XCTUnwrap(ctx.router?.botRoutineAuthority)
        let result = try authority.dispatch(method: "bot.context.revoke", params: [
            "client_request_id": UUID().uuidString, "host_id": host, "bot_id": parentBot.id.value.uuidString,
            "context_key": contextA.storageKey, "context_version": 1, "policy_revision": parentGrant.policyRevision,
        ])
        XCTAssertEqual((result["readback"] as? [String: Any])?["run_cancellation_requested"] as? Bool, true)
        XCTAssertFalse(try store.authorizesContextDelegation(hostID: host, runID: childRequest.runId, threadID: childRequest.threadId))
        do {
            let (data, response) = try await session.data(for: httpRequest)
            XCTAssertNotEqual((response as? HTTPURLResponse)?.statusCode, 200, "Revoked ancestor must deny new child tool actions: \(String(decoding: data, as: UTF8.self))")
        } catch let error as URLError {
            XCTAssertTrue([URLError.cannotConnectToHost, .networkConnectionLost].contains(error.code), "Unexpected post-revoke transport error: \(error)")
        }
        XCTAssertThrowsError(try prepare(AgentRunRequest(threadId: childRequest.threadId, provider: .distill, model: "test", cwd: workspace.cwd, prompt: "revoked descendant"), workspace: workspace, parent: parentRequest.runId))
        let journal = DistillGuestEnvironment.runsDirectory(appSupport: support)
            .appendingPathComponent(identities[1].storageBotID.value.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(childRequest.runId.value.uuidString.lowercased() + ".context.json")
        let deadline = Date().addingTimeInterval(15)
        var childEnded = false
        if injectChildStopFailure {
            while Date() < deadline && (docker.failures == 0 || (try? JSONDecoder().decode(BotContextGuestRecovery.Record.self, from: Data(contentsOf: journal)).state) != .pending) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertGreaterThan(docker.failures, 0)
            XCTAssertEqual(try JSONDecoder().decode(BotContextGuestRecovery.Record.self, from: Data(contentsOf: journal)).state, .pending)
            XCTAssertTrue(try realDocker.inspect(name: resources[1].container).running)
            XCTAssertFalse(FileManager.default.fileExists(atPath: envFiles[1].path))
            XCTAssertFalse(try store.authorizesContextDelegation(hostID: host, runID: childRequest.runId, threadID: childRequest.threadId))
            XCTAssertTrue(try XCTUnwrap(store.contextDelegation(childRunID: childRequest.runId)).closed)
            XCTAssertTrue(try realDocker.inspect(name: resources[2].container).running)
            XCTAssertEqual(try invoke(2)["status"] as? Int, 200)
            docker.failChildStop = false
            try resources[0].cancel()
        }
        while Date() < deadline {
            let record = try JSONDecoder().decode(BotContextGuestRecovery.Record.self, from: Data(contentsOf: journal))
            let childRunning = try realDocker.inspect(name: resources[1].container).running
            if record.state == .ended && !childRunning {
                childEnded = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(childEnded, "Ancestor revocation must stop and finish the child, not only close its authority")
        XCTAssertFalse(FileManager.default.fileExists(atPath: envFiles[1].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(resources[1].configDirectory).path))
        XCTAssertTrue(try realDocker.inspect(name: resources[2].container).running)
        _ = try realDocker.run(["exec", resources[2].container, "sh", "-c", "kill -0 $(cat /home/remotecode/.delegation-probe.pid)"])
        let pulseBefore = try realDocker.run(["exec", resources[2].container, "cat", "/home/remotecode/.delegation-probe-pulse"])
        try await Task.sleep(nanoseconds: 250_000_000)
        let pulseAfter = try realDocker.run(["exec", resources[2].container, "cat", "/home/remotecode/.delegation-probe-pulse"])
        XCTAssertNotEqual(pulseBefore, pulseAfter, "B must keep executing after ancestor A is revoked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: envFiles[2].path))
        XCTAssertEqual(try invoke(2)["status"] as? Int, 200)
        XCTAssertEqual(try invoke(2)["hash"] as? String, SHA256.hash(data: Data(markers[2].utf8)).map { String(format: "%02x", $0) }.joined())
        let reopenedDB = try SQLiteDB(path: database.path)
        try Schema.migrate(reopenedDB)
        let reopened = BotStore(db: reopenedDB)
        XCTAssertTrue(try XCTUnwrap(reopened.contextDelegation(childRunID: childRequest.runId)).closed)
        XCTAssertFalse(try reopened.authorizesContextDelegation(hostID: host, runID: childRequest.runId, threadID: childRequest.threadId))
        XCTAssertTrue(try reopened.authorizes(hostID: host, botID: childBot.id, context: .general, action: .send, policyRevision: generalGrant.policyRevision))
        XCTAssertTrue(try reopened.authorizesContextDelegation(hostID: host, runID: generalRequest.runId, threadID: generalRequest.threadId))
    }
}
