import CryptoKit
import Foundation
import XCTest
import AgentRuntime
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

final class BotContextGatewayDockerProbeTests: XCTestCase {
    func test_livePreparedContextGatewayScopesSecretsInsideDocker() throws {
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-gateway-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspacePath = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Probe", title: "Probe", description: "", handle: "probe", soul: "", provider: .distill, model: "test")
        let host = "context-gateway-probe"
        let workspace = Workspace.empty(name: "Probe", cwd: workspacePath.path)
        let contexts: [BotContext] = [.workspace(workspace.id), .general]
        let secrets = InMemoryBotSecretStore()
        let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil)
        var resources: [BotContextGuestResources] = []
        var identities: [BotContextRuntimeIdentity] = []
        var requests: [AgentRunRequest] = []
        defer {
            var cleaned = true
            for resource in resources {
                do { try resource.finish() } catch { cleaned = false; XCTFail("Resource cleanup failed: \(error)") }
            }
            for identity in identities {
                do {
                    try service.wipe(identity: identity)
                    XCTAssertFalse(try docker.containerExists(name: BotComputerGuestSpec.containerName(botID: identity.storageBotID)))
                    XCTAssertFalse(try docker.networkExists(name: BotComputerGuestSpec.networkName(botID: identity.storageBotID)))
                } catch { cleaned = false; XCTFail("Runtime cleanup failed: \(error)") }
            }
            if cleaned {
                do { try FileManager.default.removeItem(at: root) }
                catch { XCTFail("Fixture cleanup failed: \(error)") }
            }
        }
        let values = [UUID().uuidString, UUID().uuidString]
        try secrets.save(botID: bot.id, name: "GLOBAL_CANARY", value: "global-only")
        let sharedRun = AgentRunID()
        for (index, context) in contexts.enumerated() {
            let binding = try store.grantContext(hostID: host, botID: bot.id, context: context, actions: [.read, .send, .configure, .files], expectedRevision: 0)
            let identity = try BotContextRuntimeIdentity(binding: binding)
            identities.append(identity)
            try secrets.save(botID: identity.storageBotID, name: "CONTEXT_MARKER", value: values[index])
            try secrets.save(botID: identity.storageBotID, name: "ONLY_\(index)", value: "synthetic")
            let thread = AgentThread(workspaceId: index == 0 ? workspace.id : nil, title: "Context", provider: .distill, model: "test")
            let conversation = BotConversation(botID: bot.id, title: "Context", linkedAgentThreadID: thread.id)
            _ = try store.createContextualConversation(conversation, newThread: thread, hostID: host, context: context, policyRevision: binding.policyRevision)
            let request = AgentRunRequest(runId: sharedRun, threadId: thread.id, provider: .distill, model: "test", cwd: index == 0 ? workspace.cwd : BotHome(appSupportDirectory: support, bot: bot).root.path, prompt: "probe", environment: [
                "CONTEXT_MARKER": "inherited", "GLOBAL_CANARY": "inherited", "DISTILL_HOME": "/foreign",
                BotSecretEnvironment.secretNamesEnvironmentKey: "CONTEXT_MARKER,GLOBAL_CANARY",
            ])
            requests.append(request)
            resources.append(try BotContextGuestResources.prepare(request: request, hostID: host, store: store, threadRepo: AgentThreadRepository(db: db), service: service, appSupport: support, workspace: index == 0 ? workspace : nil, registeredWorkspaces: [workspace.cwd], secretStore: secrets))
        }
        let envURLs = try resources.map { try XCTUnwrap($0.envFileURL) }
        XCTAssertNotEqual(envURLs[0], envURLs[1], "Identical run IDs must not overwrite another context's credentials")
        let client = #"""
        const fs=require('node:fs'),http=require('node:http'),path=require('node:path'),crypto=require('node:crypto');
        const config=fs.readFileSync(path.join(process.env.DISTILL_HOME,'config.toml'),'utf8');
        const block=config.split('[mcp_servers.').find(section=>section.includes('bearer_token_env_var'));
        if(!block)throw Error('configured-gateway-missing');
        const url=new URL(block.match(/url\s*=\s*"([^"]+)"/)[1]);
        const tokenName=block.match(/bearer_token_env_var\s*=\s*"([^"]+)"/)[1];
        const token=process.env[tokenName];if(!token)throw Error('configured-bearer-missing');
        const body=JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'bot_list_secrets',arguments:{}}});
        const request=http.request(url,{method:'POST',headers:{authorization:'Bearer '+token,'content-type':'application/json','content-length':Buffer.byteLength(body)}},response=>{
          let data='';response.setEncoding('utf8');response.on('data',chunk=>data+=chunk);response.on('end',()=>{
            let names=[];if(response.statusCode===200){const result=JSON.parse(data);names=JSON.parse(result.result.content[0].text).secrets;}
            process.stdout.write(JSON.stringify({status:response.statusCode,names,hash:crypto.createHash('sha256').update(process.env.CONTEXT_MARKER||'').digest('hex'),global:!!process.env.GLOBAL_CANARY,tokenInConfig:config.includes(token)}));
          });
        });request.setTimeout(5000,()=>request.destroy(Error('timeout')));request.on('error',()=>process.exit(2));request.end(body);
        """#
        func invoke(_ index: Int, env: URL) throws -> [String: Any] {
            let output = try docker.run(["exec", "--env-file", env.path, resources[index].container, "node", "-e", client])
            return try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        }
        for index in 0..<2 {
            let response = try invoke(index, env: envURLs[index])
            XCTAssertEqual(response["status"] as? Int, 200)
            XCTAssertEqual((response["names"] as? [String])?.sorted(), ["CONTEXT_MARKER", "ONLY_\(index)"])
            XCTAssertEqual(response["hash"] as? String, SHA256.hash(data: Data(values[index].utf8)).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(response["global"] as? Bool, false)
            XCTAssertEqual(response["tokenInConfig"] as? Bool, false)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: envURLs[index].path)[.posixPermissions] as? Int, 0o600)
            let config = try String(contentsOf: try XCTUnwrap(resources[index].configDirectory).appendingPathComponent("config.toml"), encoding: .utf8)
            XCTAssertFalse(config.contains(values[index]))
        }
        func environment(_ url: URL) throws -> [String: String] {
            let contents = try String(contentsOf: url, encoding: .utf8)
            return Dictionary(uniqueKeysWithValues: contents.split(separator: "\n").map {
                let parts = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(parts[0]), String(parts[1]))
            })
        }
        var crossed = try environment(envURLs[0])
        crossed[DistillGuestConfig.gatewayTokenEnvironmentKey] = try environment(envURLs[1])[DistillGuestConfig.gatewayTokenEnvironmentKey]
        let crossEnv = try DistillGuestEnvironment.writeEnvFile(crossed, runID: UUID().uuidString.lowercased(), directory: root.appendingPathComponent("cross", isDirectory: true))
        XCTAssertEqual(try invoke(0, env: crossEnv)["status"] as? Int, 401)
        _ = try store.revokeContext(hostID: host, botID: bot.id, context: contexts[0], expectedRevision: 1)
        XCTAssertEqual(try invoke(0, env: envURLs[0])["status"] as? Int, 401)
        XCTAssertEqual(try invoke(1, env: envURLs[1])["status"] as? Int, 200)
        try resources[1].finish()
        try assertContextCleanupDoesNotWaitForOtherPreparation(preparedA: resources[0], requestB: AgentRunRequest(threadId: requests[1].threadId, provider: .distill, model: "test", cwd: requests[1].cwd, prompt: "fresh probe", environment: requests[1].environment), hostID: host, store: store, threadRepo: AgentThreadRepository(db: db), appSupport: support, secretStore: secrets)
        for resource in resources { try resource.finish(); try resource.finish() }
        for url in envURLs { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        print("Prepared context gateway HTTP/authentication probe passed; resources cleaned: \(root.path)")
    }
}
