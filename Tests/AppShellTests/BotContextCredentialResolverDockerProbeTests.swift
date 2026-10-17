import AgentRuntime
import CoreModel
import CryptoKit
import Foundation
import Persistence
import SocketServer
import XCTest

@testable import AppShell

@MainActor
final class BotContextCredentialResolverDockerProbeTests: XCTestCase {
  func test_liveResolverStagesRealKeychainCredentialsByContext() async throws {
    guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
      throw XCTSkip("set RC_LIVE_DOCKER=1 for the real contextual credential Docker probe")
    }
    let realDocker = BotComputerDockerCLI()
    _ = try realDocker.info()
    guard try realDocker.imageExists(tag: BotComputerGuestSpec.imageTag),
      try realDocker.imageLabel(
        tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey)
        == BotComputerGuestSpec.recipeRevision
    else {
      throw XCTSkip("matching existing Docker image unavailable; probe never builds or pulls")
    }

    let scratch = URL(
      fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]),
      isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let root = scratch.appendingPathComponent(
      "credential-resolver-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int, 0o700)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let serviceName = "io.remotecode.test.\(UUID().uuidString)"
    let keychain = BotKeychainSecretStore(service: serviceName)
    let manifest = root.appendingPathComponent("fixture-manifest.json")
    try JSONSerialization.data(
      withJSONObject: ["service": serviceName, "ownedIDs": []], options: [.sortedKeys]
    ).write(to: manifest, options: .atomic)
    let hostOnly = UUID().uuidString + UUID().uuidString
    let canaryA = UUID().uuidString + UUID().uuidString
    let canaryB = UUID().uuidString + UUID().uuidString
    let markerA = UUID().uuidString + UUID().uuidString
    let markerB = UUID().uuidString + UUID().uuidString
    var ownedIDs: [BotID] = []
    var ownedIdentities: [BotContextRuntimeIdentity] = []
    var workers: [Task<Void, Never>] = []
    var released: [DispatchSemaphore] = []
    var cleanupConfirmed = false
    func cleanup() async {
      for semaphore in released { semaphore.signal() }
      for task in workers { await task.value }
      var runtimeCleanupConfirmed = true
      let service = BotComputerGuestService(
        appSupport: support, docker: realDocker, recipeContext: nil)
      for identity in ownedIdentities {
        do {
          try service.wipe(identity: identity)
          let containerPresent = try realDocker.containerExists(
            name: BotComputerGuestSpec.containerName(botID: identity.storageBotID))
          let networkPresent = try realDocker.networkExists(
            name: BotComputerGuestSpec.networkName(botID: identity.storageBotID))
          if containerPresent || networkPresent {
            runtimeCleanupConfirmed = false
            XCTFail("Owned runtime remains after cleanup")
          }
        } catch {
          runtimeCleanupConfirmed = false
          XCTFail("Owned runtime cleanup failed: \(error)")
        }
      }
      do {
        for id in ownedIDs {
          try keychain.deleteAll(botID: id)
          XCTAssertTrue(try keychain.list(botID: id).isEmpty)
          XCTAssertNil(try keychain.load(botID: id, name: "CONTEXT_MARKER"))
        }
        cleanupConfirmed = runtimeCleanupConfirmed
      } catch {
        XCTFail(
          "Owned Keychain cleanup was not confirmed; manifest retained at \(manifest.path): \(error)"
        )
      }
      if cleanupConfirmed {
        do { try FileManager.default.removeItem(at: root) } catch {
          XCTFail("Fixture root cleanup failed: \(error)")
        }
      }
    }

    do {
      let ctx = try AppContext(
        channel: .debug, dbPathOverride: root.appendingPathComponent("probe.sqlite").path,
        appSupportOverride: support.path, privateAccountAPI: SilentWakeRecordingAPI(),
        performLaunchRunReconciliation: true, contextualSecretStore: keychain)
      let router = AppCommandRouter(context: ctx)
      ctx.router = router
      let host = ctx.liveActivityHostIdentity.serverId
      let workspacePaths = ["a", "b"].map {
        root.appendingPathComponent("workspace-\($0)", isDirectory: true)
      }
      for path in workspacePaths {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
      }
      let workspaceA = try router.createWorkspace(name: "Credential A", cwd: workspacePaths[0].path)
      let workspaceB = try router.createWorkspace(name: "Credential B", cwd: workspacePaths[1].path)
      let bot = try ctx.botStore.create(
        name: "Credential probe", title: "Credential probe", description: "",
        handle: "credential-\(UUID().uuidString.prefix(8))", soul: "", provider: .distill,
        model: "test")
      let grants = try [workspaceA, workspaceB].map { workspace in
        try ctx.botStore.grantContext(
          hostID: host, botID: bot.id, context: .workspace(workspace.id),
          actions: [.read, .send, .configure, .files], expectedRevision: 0)
      }
      let identities = try grants.map { try BotContextRuntimeIdentity(binding: $0) }
      ownedIDs = identities.map(\.storageBotID) + [bot.id]
      ownedIdentities = identities
      try JSONSerialization.data(
        withJSONObject: [
          "service": serviceName, "ownedIDs": ownedIDs.map { $0.value.uuidString.lowercased() },
        ], options: [.sortedKeys]
      ).write(to: manifest, options: .atomic)
      try keychain.save(botID: identities[0].storageBotID, name: "CONTEXT_MARKER", value: markerA)
      try keychain.save(botID: identities[0].storageBotID, name: "A_ONLY", value: canaryA)
      try keychain.save(botID: identities[1].storageBotID, name: "CONTEXT_MARKER", value: markerB)
      try keychain.save(botID: identities[1].storageBotID, name: "B_ONLY", value: canaryB)
      try keychain.save(botID: bot.id, name: "HOST_ONLY", value: hostOnly)

      let markerExecutable = root.appendingPathComponent("provider-marker")
      let providerInvoked = root.appendingPathComponent("provider-was-run")
      try Data("#!/bin/sh\nprintf invoked > '\(providerInvoked.path)'\nexit 99\n".utf8).write(
        to: markerExecutable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: markerExecutable.path)
      let observer = CredentialStageObserver()
      ctx.coordinator.addObserver(observer)
      defer { ctx.coordinator.removeObserver(observer) }
      var requests: [AgentRunRequest] = []
      for (index, workspace) in [workspaceA, workspaceB].enumerated() {
        let thread = AgentThread(
          workspaceId: workspace.id, title: "Credential stage", provider: .distill, model: "test")
        _ = try ctx.botStore.createContextualConversation(
          BotConversation(botID: bot.id, title: thread.title, linkedAgentThreadID: thread.id),
          newThread: thread, hostID: host, context: grants[index].context,
          policyRevision: grants[index].policyRevision)
        requests.append(
          AgentRunRequest(
            threadId: thread.id, provider: .distill, model: "test", cwd: workspace.cwd,
            prompt: "synthetic credential isolation probe", providerBinary: markerExecutable.path,
            environment: [
              "HOST_ONLY": hostOnly, "A_ONLY": hostOnly, "B_ONLY": hostOnly,
              BotSecretEnvironment.secretNamesEnvironmentKey: "HOST_ONLY,A_ONLY,B_ONLY",
            ]))
      }
      let barriers = requests.map { request -> DispatchSemaphore in
        let semaphore = DispatchSemaphore(value: 0)
        released.append(semaphore)
        observer.arm(run: request.runId, release: semaphore)
        return semaphore
      }
      for request in requests {
        let runID = request.runId
        workers.append(
          Task { @MainActor in
            do {
              _ = try await ctx.coordinator.startRun(request)
              XCTFail("Mandatory model gate must refuse contextual execution")
            } catch {
              XCTAssertTrue(
                String(describing: error).localizedCaseInsensitiveContains("context")
                  || String(describing: error).localizedCaseInsensitiveContains("model"),
                "Unexpected refusal: \(error)")
            }
            XCTAssertEqual(try? ctx.runRepo.get(id: runID)?.status, .failed)
          })
      }
      var allReady = true
      for request in requests {
        let ready = await observer.waitUntilReady(run: request.runId, timeout: 90)
        allReady = allReady && ready
      }
      if !allReady {
        for barrier in barriers { barrier.signal() }
        for task in workers { await task.value }
        XCTFail("Real resolver did not reach preparingAgent; check Docker guest readiness")
        throw NSError(domain: "CredentialProbe", code: 1)
      }
      let runDirectory = DistillGuestEnvironment.runsDirectory(appSupport: support)
      func envFile(_ contextIndex: Int, runIndex: Int? = nil) throws -> URL {
        let runID = requests[runIndex ?? contextIndex].runId.value.uuidString.lowercased()
        return runDirectory.appendingPathComponent(
          identities[contextIndex].storageBotID.value.uuidString.lowercased(), isDirectory: true
        ).appendingPathComponent(runID + ".env")
      }
      let client = #"""
        const fs=require('node:fs'),http=require('node:http'),path=require('node:path'),crypto=require('node:crypto');
        const config=fs.readFileSync(path.join(process.env.DISTILL_HOME,'config.toml'),'utf8');
        const block=config.split('[mcp_servers.').find(s=>s.includes('bearer_token_env_var'));
        const url=new URL(block.match(/url\s*=\s*"([^"]+)"/)[1]);
        const key=block.match(/bearer_token_env_var\s*=\s*"([^"]+)"/)[1], token=process.env[key];
        const body=JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'bot_list_secrets',arguments:{}}});
        const r=http.request(url,{method:'POST',headers:{authorization:'Bearer '+token,'content-type':'application/json','content-length':Buffer.byteLength(body)}},res=>{let d='';res.on('data',c=>d+=c);res.on('end',()=>{let names=[];if(res.statusCode===200)names=JSON.parse(JSON.parse(d).result.content[0].text).secrets;process.stdout.write(JSON.stringify({status:res.statusCode,names,hash:crypto.createHash('sha256').update(process.env.CONTEXT_MARKER||'').digest('hex'),tokenInConfig:config.includes(token),canaries:['HOST_ONLY','A_ONLY','B_ONLY'].filter(k=>process.env[k])}));});});r.setTimeout(5000,()=>r.destroy(Error('timeout')));r.on('error',()=>process.exit(2));r.end(body);
        """#
      func probe(_ contextIndex: Int, runIndex: Int? = nil, envOverride: URL? = nil) throws
        -> [String: Any]
      {
        let env = try envOverride ?? envFile(contextIndex, runIndex: runIndex)
        let output = try realDocker.run([
          "exec", "--env-file", env.path,
          BotComputerGuestSpec.containerName(botID: identities[contextIndex].storageBotID), "node",
          "-e", client,
        ])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
      }
      for i in 0..<2 {
        let result = try probe(i)
        XCTAssertEqual(result["status"] as? Int, 200)
        XCTAssertEqual(
          (result["names"] as? [String])?.sorted(),
          ["CONTEXT_MARKER", i == 0 ? "A_ONLY" : "B_ONLY"].sorted())
        XCTAssertEqual(
          result["hash"] as? String,
          SHA256.hash(data: Data((i == 0 ? markerA : markerB).utf8)).map {
            String(format: "%02x", $0)
          }.joined())
        XCTAssertEqual(result["tokenInConfig"] as? Bool, false)
        XCTAssertEqual(result["canaries"] as? [String], [i == 0 ? "A_ONLY" : "B_ONLY"])
        XCTAssertEqual(
          try FileManager.default.attributesOfItem(atPath: envFile(i).path)[.posixPermissions]
            as? Int, 0o600)
        let config = try String(
          contentsOf: BotComputerGuestSpec.guestHomeURL(
            appSupport: support, botID: identities[i].storageBotID
          ).appendingPathComponent(
            ".distill-context-\(requests[i].runId.value.uuidString.lowercased())/config.toml"),
          encoding: .utf8)
        for value in [hostOnly, canaryA, canaryB, markerA, markerB] {
          XCTAssertFalse(config.contains(value))
        }
      }
      func bearer(_ env: URL) throws -> String {
        let line = try XCTUnwrap(
          String(contentsOf: env, encoding: .utf8).split(separator: "\n").first {
            $0.hasPrefix(DistillGuestConfig.gatewayTokenEnvironmentKey + "=")
          })
        return String(line.dropFirst(DistillGuestConfig.gatewayTokenEnvironmentKey.count + 1))
      }
      let a1Env = try envFile(0)
      let a1Bearer = try bearer(a1Env)
      let a1BearerFile = root.appendingPathComponent("a1-bearer.private")
      try Data((a1Bearer + "\n").utf8).write(to: a1BearerFile, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: a1BearerFile.path)

      barriers[0].signal()
      await workers[0].value
      try keychain.save(
        botID: identities[0].storageBotID, name: "CONTEXT_MARKER",
        value: UUID().uuidString + UUID().uuidString)
      let markerA2 = try XCTUnwrap(
        keychain.load(botID: identities[0].storageBotID, name: "CONTEXT_MARKER"))
      let a2Thread = AgentThread(
        workspaceId: workspaceA.id, title: "Credential stage A2", provider: .distill, model: "test")
      _ = try ctx.botStore.createContextualConversation(
        BotConversation(botID: bot.id, title: a2Thread.title, linkedAgentThreadID: a2Thread.id),
        newThread: a2Thread, hostID: host, context: grants[0].context,
        policyRevision: grants[0].policyRevision)
      let a2Request = AgentRunRequest(
        threadId: a2Thread.id, provider: .distill, model: "test", cwd: workspaceA.cwd,
        prompt: "synthetic rotated credential probe", providerBinary: markerExecutable.path,
        environment: [
          "HOST_ONLY": hostOnly, "A_ONLY": hostOnly, "B_ONLY": hostOnly,
          BotSecretEnvironment.secretNamesEnvironmentKey: "HOST_ONLY,A_ONLY,B_ONLY",
        ])
      requests.append(a2Request)
      let a2Barrier = DispatchSemaphore(value: 0)
      released.append(a2Barrier)
      observer.arm(run: a2Request.runId, release: a2Barrier)
      let a2RunID = a2Request.runId
      workers.append(
        Task { @MainActor in
          do {
            _ = try await ctx.coordinator.startRun(a2Request)
            XCTFail("Mandatory model gate must refuse contextual execution")
          } catch {
            XCTAssertTrue(
              String(describing: error).localizedCaseInsensitiveContains("context")
                || String(describing: error).localizedCaseInsensitiveContains("model")
                || String(describing: error).localizedCaseInsensitiveContains("cancel"),
              "Unexpected refusal: \(error)")
          }
          let status = try? ctx.runRepo.get(id: a2RunID)?.status
          XCTAssertTrue(status == .failed || status == .cancelled)
        })
      let a2Ready = await observer.waitUntilReady(run: a2Request.runId, timeout: 90)
      XCTAssertTrue(a2Ready, "Rotated A run must stage through the same resolver")
      XCTAssertFalse(FileManager.default.fileExists(atPath: providerInvoked.path))
      let a2Env = try envFile(0, runIndex: 2)
      let a2Bearer = try bearer(a2Env)
      XCTAssertTrue(a2Bearer != a1Bearer, "Rotated gateway must issue a fresh bearer")
      let a2Hash = SHA256.hash(data: Data(markerA2.utf8)).map { String(format: "%02x", $0) }
        .joined()
      let a2Result = try probe(0, runIndex: 2)
      XCTAssertEqual(a2Result["status"] as? Int, 200)
      XCTAssertEqual(a2Result["hash"] as? String, a2Hash)
      XCTAssertEqual(
        (a2Result["names"] as? [String])?.sorted(), ["CONTEXT_MARKER", "A_ONLY"].sorted())
      let a2ConfigPath = BotComputerGuestSpec.guestHomeURL(
        appSupport: support, botID: identities[0].storageBotID
      ).appendingPathComponent(
        ".distill-context-\(a2Request.runId.value.uuidString.lowercased())/config.toml")
      let a2Config = try String(contentsOf: a2ConfigPath, encoding: .utf8)
      let a2GatewayURL = try XCTUnwrap(
        a2Config.split(separator: "\n").first {
          $0.trimmingCharacters(in: .whitespaces).hasPrefix("url =")
        }
        .flatMap { line -> String? in
          let text = String(line)
          guard let start = text.firstIndex(of: "\""),
            let end = text[text.index(after: start)...].firstIndex(of: "\"")
          else { return nil }
          return String(text[text.index(after: start)..<end])
        }.flatMap(URL.init(string:))
      )
      let a2GatewayPort = try XCTUnwrap(a2GatewayURL.port)
      var localA2Gateway = try XCTUnwrap(URLComponents(url: a2GatewayURL, resolvingAgainstBaseURL: false))
      localA2Gateway.host = "127.0.0.1"
      localA2Gateway.port = a2GatewayPort
      let localA2GatewayURL = try XCTUnwrap(localA2Gateway.url)
      let ownGatewayStatus = try await gatewayStatus(url: localA2GatewayURL, bearer: a2Bearer)
      XCTAssertEqual(ownGatewayStatus, 200)
      for value in [hostOnly, canaryA, canaryB, markerA, markerB, markerA2, a1Bearer, a2Bearer] {
        XCTAssertFalse(a2Config.contains(value))
      }

      func gatewayStatus(url: URL, bearer: String) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
          "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"bot_list_secrets\",\"arguments\":{}}}"
            .utf8)
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(response as? HTTPURLResponse).statusCode
      }

      func gatewayStatusAfterRevoke(url: URL, bearer: String) async -> String {
        do { return "http-\(try await gatewayStatus(url: url, bearer: bearer))" }
        catch let error as URLError where error.code == .cannotConnectToHost { return "connection-refused" }
        catch { return "error-\(type(of: error))" }
      }

      func envUsingBearer(_ source: URL, bearer: String, name: String) throws -> URL {
        var contents = try String(contentsOf: source, encoding: .utf8)
        let prefix = DistillGuestConfig.gatewayTokenEnvironmentKey + "="
        guard
          let range = contents.range(
            of: "(?m)^\\Q\(prefix)\\E[^\\r\\n]*", options: .regularExpression)
        else { throw NSError(domain: "CredentialProbe", code: 2) }
        contents.replaceSubrange(range, with: prefix + bearer)
        let destination = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
      }
      let oldAOnA2 = try envUsingBearer(a2Env, bearer: a1Bearer, name: "a1-on-a2.env")
      XCTAssertEqual(try probe(0, runIndex: 2, envOverride: oldAOnA2)["status"] as? Int, 401)
      let a2OnB = try envUsingBearer(envFile(1), bearer: a2Bearer, name: "a2-on-b.env")
      XCTAssertEqual(try probe(1, envOverride: a2OnB)["status"] as? Int, 401)
      let bOnA2 = try envUsingBearer(a2Env, bearer: try bearer(envFile(1)), name: "b-on-a2.env")
      XCTAssertEqual(try probe(0, runIndex: 2, envOverride: bOnA2)["status"] as? Int, 401)
      let a1OnB = try envUsingBearer(envFile(1), bearer: a1Bearer, name: "a1-on-b.env")
      XCTAssertEqual(try probe(1, envOverride: a1OnB)["status"] as? Int, 401)

      _ = try await router.dispatchPairedBotRemote(
        method: "bot.context.revoke",
        params: [
          "client_request_id": .string(UUID().uuidString),
          "host_id": .string(host),
          "bot_id": .string(bot.id.value.uuidString),
          "context_key": .string(grants[0].context.storageKey),
          "context_version": .number(1),
          "policy_revision": .number(Double(grants[0].policyRevision)),
        ])
      let removalDeadline = Date().addingTimeInterval(30)
      let aGuest = BotComputerGuestSpec.containerName(botID: identities[0].storageBotID)
      let aConfig = BotComputerGuestSpec.guestHomeURL(
        appSupport: support, botID: identities[0].storageBotID
      ).appendingPathComponent(
        ".distill-context-\(a2Request.runId.value.uuidString.lowercased())/config.toml")
      var removed = false
      while Date() < removalDeadline {
        let envGone = !FileManager.default.fileExists(atPath: a2Env.path)
        let configGone = !FileManager.default.fileExists(atPath: aConfig.path)
        let stopped = !(try realDocker.inspect(name: aGuest).running)
        if envGone && configGone && stopped {
          removed = true
          break
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      XCTAssertTrue(removed, "Revocation must remove A2 private runtime files and stop A guest")
      XCTAssertFalse(FileManager.default.fileExists(atPath: providerInvoked.path))
      let postRevokeA2Status = await gatewayStatusAfterRevoke(url: localA2GatewayURL, bearer: a2Bearer)
      XCTAssertTrue(
        postRevokeA2Status == "http-401" || postRevokeA2Status == "connection-refused",
        "Revoked A2 bearer must fail on its own gateway, got \(postRevokeA2Status)")
      XCTAssertEqual(
        try probe(1)["status"] as? Int, 200, "B guest must stay usable after A revocation")
      for semaphore in released { semaphore.signal() }
      for task in workers { await task.value }
      XCTAssertFalse(FileManager.default.fileExists(atPath: providerInvoked.path))
      XCTAssertEqual(
        try FileManager.default.attributesOfItem(atPath: a1BearerFile.path)[.posixPermissions]
          as? Int, 0o600)
      for value in [hostOnly, canaryA, canaryB, markerA, markerB, markerA2, a1Bearer, a2Bearer] {
        XCTAssertFalse(
          observer.payloads.contains { $0.contains(value) },
          "Observer event leaked a private credential")
      }
      let legacyHome = BotComputerGuestSpec.guestHomeURL(appSupport: support, botID: bot.id)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: legacyHome.path),
        "No legacy per-bot runtime may contain HOST_ONLY")
      XCTAssertTrue(try ctx.runRepo.listActive().isEmpty)
      await cleanup()
    } catch {
      await cleanup()
      throw error
    }
  }
}

private final class CredentialStageObserver: AgentRunObserver, @unchecked Sendable {
  private let lock = NSLock()
  private var barriers: [AgentRunID: DispatchSemaphore] = [:]
  private var ready: Set<AgentRunID> = []
  private var receivedPayloads: [String] = []
  var payloads: [String] {
    lock.lock()
    defer { lock.unlock() }
    return receivedPayloads
  }
  func arm(run: AgentRunID, release: DispatchSemaphore) {
    lock.lock()
    barriers[run] = release
    lock.unlock()
  }
  func waitUntilReady(run: AgentRunID, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      lock.lock()
      let found = ready.contains(run)
      lock.unlock()
      if found { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
  func runCoordinator(
    _ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID,
    threadId: AgentThreadID
  ) {
    guard case .providerRuntime(let runtime) = event else { return }
    lock.lock()
    receivedPayloads.append(runtime.payloadJSON)
    let isReady =
      runtime.method == DistillGuestStage.runtimeMethod
      && (try? JSONDecoder().decode([String: String].self, from: Data(runtime.payloadJSON.utf8))[
        "stage"]) == DistillGuestStage.preparingAgent.rawValue
    if isReady { ready.insert(run) }
    let barrier = isReady ? barriers[run] : nil
    lock.unlock()
    guard isReady else { return }
    _ = barrier?.wait(timeout: .now() + 90)
  }
  func runCoordinator(
    _ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID,
    status: AgentRunStatus, finalMessage: String?, providerThreadId: String?
  ) {}
  func runCoordinator(
    _ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID,
    threadId: AgentThreadID
  ) {}
}
