import Foundation
import XCTest
import CoreModel
@testable import AppShell

final class BlockingContextSecrets: BotSecretStore, @unchecked Sendable {
    private let backing = InMemoryBotSecretStore()
    private let lock = NSLock()
    private var gates: [BotID: (entered: DispatchSemaphore, release: DispatchSemaphore, returned: DispatchSemaphore)] = [:]
    private var armed = Set<BotID>()

    func save(botID: BotID, name: String, value: String) throws { try backing.save(botID: botID, name: name, value: value) }
    func load(botID: BotID, name: String) throws -> String? { try backing.load(botID: botID, name: name) }
    func delete(botID: BotID, name: String) throws { try backing.delete(botID: botID, name: name) }
    func deleteAll(botID: BotID) throws { try backing.deleteAll(botID: botID) }

    func arm(_ botIDs: [BotID]) {
        lock.lock(); defer { lock.unlock() }
        for id in botIDs {
            gates[id] = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
            armed.insert(id)
        }
    }

    func waitUntilListed(_ botID: BotID, timeout: DispatchTime) -> DispatchTimeoutResult {
        lock.lock(); let gate = gates[botID]?.entered; lock.unlock()
        return gate?.wait(timeout: timeout) ?? .timedOut
    }

    func waitUntilReturned(_ botID: BotID, timeout: DispatchTime) -> DispatchTimeoutResult {
        lock.lock(); let gate = gates[botID]?.returned; lock.unlock()
        return gate?.wait(timeout: timeout) ?? .timedOut
    }

    func release(_ botID: BotID) {
        lock.lock(); let gate = gates[botID]?.release; lock.unlock()
        gate?.signal()
    }

    func list(botID: BotID) throws -> [BotSecretMetadata] {
        let gate: (entered: DispatchSemaphore, release: DispatchSemaphore, returned: DispatchSemaphore)? = lock.withLock {
            guard armed.remove(botID) != nil else { return nil }
            return gates[botID]
        }
        if let gate {
            gate.entered.signal()
            guard gate.release.wait(timeout: .now() + 15) == .success else { throw ProbeFailure.blockExpired }
        }
        defer { gate?.returned.signal() }
        return try backing.list(botID: botID)
    }
}

private final class HTTPProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Data, Error>?
    private var receivedAt: UInt64?
    private let done = DispatchSemaphore(value: 0)

    func set(_ result: Result<Data, Error>) { lock.lock(); stored = result; receivedAt = DispatchTime.now().uptimeNanoseconds; lock.unlock(); done.signal() }
    func receiptTime() -> UInt64? { lock.lock(); defer { lock.unlock() }; return receivedAt }
    func wait(_ timeout: DispatchTime) -> DispatchTimeoutResult { done.wait(timeout: timeout) }
    func value() -> Result<Data, Error>? { lock.lock(); defer { lock.unlock() }; return stored }
}

func assertActiveContextHTTPRevocation(
    resources: [BotContextGuestResources],
    secrets: BlockingContextSecrets,
    docker: BotComputerDockerCLI,
    environmentFiles: [URL]
) throws {
    guard resources.count == 2, environmentFiles.count == 2 else { throw ProbeFailure.invalidFixture }
    let ids = resources.map { $0.identity.storageBotID }
    let forbiddenValues = try secrets.list(botID: ids[0]).compactMap { try secrets.load(botID: ids[0], name: $0.name) }
    secrets.arm(ids)
    defer { ids.forEach(secrets.release) }
    let script = #"""
    const fs=require('node:fs'),http=require('node:http'),path=require('node:path');
    const c=fs.readFileSync(path.join(process.env.DISTILL_HOME,'config.toml'),'utf8');
    const b=c.split('[mcp_servers.').find(x=>x.includes('bearer_token_env_var'));
    if(!b)throw Error('configured-gateway-missing');
    const url=new URL(b.match(/url\s*=\s*"([^"]+)"/)[1]);
    const key=b.match(/bearer_token_env_var\s*=\s*"([^"]+)"/)[1],token=process.env[key];
    if(!token)throw Error('configured-bearer-missing');
    const marker=path.join(path.dirname(process.env.DISTILL_HOME),'.active-http-revoke-started');
    const body=JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'bot_list_secrets',arguments:{}}});
    let ended=false,data='';
    function emit(result){if(ended)return;ended=true;result.afterRevokeRequested=fs.existsSync(marker);process.stdout.write(JSON.stringify(result));}
    const req=http.request(url,{method:'POST',headers:{authorization:'Bearer '+token,'content-type':'application/json','content-length':Buffer.byteLength(body)}},res=>{
      res.setEncoding('utf8');res.on('data',x=>data+=x);
      res.on('end',()=>emit({kind:'response',status:res.statusCode,body:data}));
      res.on('aborted',()=>emit({kind:'error',error:'aborted',body:data}));
      res.on('error',e=>emit({kind:'error',error:e.code||'response-error',body:data}));
    });
    req.setTimeout(5000,()=>{emit({kind:'timeout',body:data});req.destroy();});
    req.on('error',e=>emit({kind:'error',error:e.code||'transport',body:data}));
    req.on('close',()=>emit({kind:'error',error:'closed',body:data}));req.end(body);
    """#
    let results = [HTTPProbeResult(), HTTPProbeResult()]
    for i in 0..<2 {
        let result = results[i], resource = resources[i], env = environmentFiles[i]
        DispatchQueue.global().async {
            do { result.set(.success(try docker.run(["exec", "--env-file", env.path, resource.container, "node", "-e", script]))) }
            catch { result.set(.failure(error)) }
        }
    }
    do {
        for id in ids {
            guard secrets.waitUntilListed(id, timeout: .now() + 5) == .success else { throw ProbeFailure.listNotEntered }
        }
        guard results[0].wait(.now() + 0.1) == .timedOut else { throw ProbeFailure.clientNotBlocked }
        let marker = try XCTUnwrap(resources[0].configDirectory).deletingLastPathComponent().appendingPathComponent(".active-http-revoke-started")
        try Data("requested".utf8).write(to: marker, options: .atomic)
        let finishStarted = DispatchTime.now().uptimeNanoseconds
        try resources[0].finish()
        guard results[0].wait(.now() + 3) == .success else { throw ProbeFailure.clientDidNotTerminate }
        let a = try output(results[0])
        guard a["afterRevokeRequested"] as? Bool == true,
              (results[0].receiptTime() ?? 0) >= finishStarted else { throw ProbeFailure.invalidAResponse }
        guard a["kind"] as? String != "timeout" else { throw ProbeFailure.clientTimedOut }
        let aBody = a["body"] as? String ?? ""
        guard !aBody.contains("CONTEXT_MARKER"), !aBody.contains("ONLY_0"), !forbiddenValues.contains(where: aBody.contains) else { throw ProbeFailure.secretLeaked }
        if a["kind"] as? String == "response" {
            let reply = try JSONSerialization.jsonObject(with: Data(aBody.utf8)) as? [String: Any]
            guard (reply?["error"] as? [String: Any])?["code"] as? Int == -32000,
                  reply?["result"] == nil else { throw ProbeFailure.invalidAResponse }
        } else {
            guard a["kind"] as? String == "error" else { throw ProbeFailure.invalidAResponse }
        }
        guard results[1].wait(.now() + 0.1) == .timedOut else { throw ProbeFailure.clientNotBlocked }
        secrets.release(ids[1])
        guard results[1].wait(.now() + 3) == .success else { throw ProbeFailure.clientDidNotTerminate }
        let b = try output(results[1])
        guard b["kind"] as? String == "response", b["status"] as? Int == 200,
              let body = b["body"] as? String,
              let data = body.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let secretsJSON = text.data(using: .utf8),
              let listing = try JSONSerialization.jsonObject(with: secretsJSON) as? [String: Any],
              (listing["secrets"] as? [String])?.sorted() == ["CONTEXT_MARKER", "ONLY_1"] else { throw ProbeFailure.invalidBResponse }
        secrets.release(ids[0])
        guard secrets.waitUntilReturned(ids[0], timeout: .now() + 3) == .success else { throw ProbeFailure.blockExpired }
    } catch {
        ids.forEach(secrets.release)
        _ = results[0].wait(.now() + 6)
        _ = results[1].wait(.now() + 6)
        throw error
    }
}

private func output(_ result: HTTPProbeResult) throws -> [String: Any] {
    guard case .success(let data)? = result.value(),
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProbeFailure.invalidOutput }
    return value
}

private enum ProbeFailure: Error {
    case invalidFixture, listNotEntered, clientDidNotTerminate, clientTimedOut, secretLeaked
    case clientNotBlocked, invalidAResponse, invalidBResponse, invalidOutput, blockExpired
}
