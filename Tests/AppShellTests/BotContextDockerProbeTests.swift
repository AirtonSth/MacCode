import XCTest
import CoreModel
import Persistence
@testable import AppShell

final class BotContextDockerProbeTests: XCTestCase {
    func test_liveContextualRuntimesSeparateFilesAndHomes() async throws {
        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            throw XCTSkip("set RC_LIVE_DOCKER=1 for the real contextual runtime probe")
        }
        let docker = BotComputerDockerCLI()
        _ = try docker.info()
        guard try docker.imageExists(tag: BotComputerGuestSpec.imageTag),
              try docker.imageLabel(tag: BotComputerGuestSpec.imageTag, key: BotComputerGuestSpec.recipeLabelKey) == BotComputerGuestSpec.recipeRevision else {
            XCTFail("The matching existing guest image is required; this probe never builds a shared image.")
            return
        }
        let originalImage = try docker.imageID(tag: BotComputerGuestSpec.imageTag)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-docker-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let pathA = root.appendingPathComponent("workspace-a", isDirectory: true)
        let pathB = root.appendingPathComponent("workspace-b", isDirectory: true)
        for path in [pathA, pathB] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let markerA = pathA.appendingPathComponent("marker.txt")
        let markerB = pathB.appendingPathComponent("marker.txt")
        try Data("A".utf8).write(to: markerA)
        try Data("B".utf8).write(to: markerB)
        let workspaceA = Workspace.empty(name: "Probe A", cwd: pathA.path)
        let workspaceB = Workspace.empty(name: "Probe B", cwd: pathB.path)
        let botID = BotID()
        let bindingA = BotContextBinding(hostID: "context-probe", botID: botID, context: .workspace(workspaceA.id), state: .active, policyRevision: 1, actions: [.read, .send, .files])
        let bindingB = BotContextBinding(hostID: "context-probe", botID: botID, context: .workspace(workspaceB.id), state: .active, policyRevision: 1, actions: [.read, .send, .files])
        let identityA = try BotContextRuntimeIdentity(binding: bindingA)
        let identityB = try BotContextRuntimeIdentity(binding: bindingB)
        let nameA = BotComputerGuestSpec.containerName(botID: identityA.storageBotID)
        let nameB = BotComputerGuestSpec.containerName(botID: identityB.storageBotID)
        let service = BotComputerGuestService(appSupport: support, docker: docker, recipeContext: nil, observeAttempts: 60, observeDelay: 0.5)
        print("Task-owned context runtimes: \(nameA), \(nameB); support: \(support.path)")
        defer {
            var clean = true
            for identity in [identityA, identityB] {
                do {
                    try service.wipe(identity: identity)
                    if try docker.containerExists(name: BotComputerGuestSpec.containerName(botID: identity.storageBotID)) {
                        clean = false
                        XCTFail("Task-owned runtime remains after cleanup")
                    }
                } catch { clean = false; XCTFail("Task-owned runtime cleanup failed: \(error)") }
            }
            if clean {
                do { try FileManager.default.removeItem(at: root) }
                catch { XCTFail("Task-owned fixture cleanup failed: \(error)") }
            }
        }
        func provision(_ binding: BotContextBinding, _ workspace: Workspace) throws -> (BotComputerGuestReady, Double) {
            let started = DispatchTime.now().uptimeNanoseconds
            let ready = try service.provision(contextBinding: binding, workspace: workspace, registeredWorkspaces: [workspaceA.cwd, workspaceB.cwd])
            return (ready, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        let (readyA, coldA) = try provision(bindingA, workspaceA)
        let (readyB, coldB) = try provision(bindingB, workspaceB)
        XCTAssertNotEqual(readyA.containerID, readyB.containerID)
        let observedA = try docker.inspect(name: nameA)
        let observedB = try docker.inspect(name: nameB)
        XCTAssertNotEqual(observedA.homeSource, observedB.homeSource)
        XCTAssertTrue(Set(observedA.networkNames).isDisjoint(with: observedB.networkNames))
        let networkProbe = #"""
        const net = require('node:net');
        const http = require('node:http');
        const os = require('node:os');
        const fs = require('node:fs');
        const cp = require('node:child_process');
        const dns = require('node:dns').promises;
        const timeout = 1000;

        function tcp(host, port) {
          return new Promise(resolve => {
            const socket = net.createConnection({ host, port, timeout });
            let done = false;
            const finish = status => {
              if (done) return;
              done = true;
              socket.destroy();
              resolve(status);
            };
            socket.once('connect', () => finish('connected'));
            socket.once('timeout', () => finish('unreachable'));
            socket.once('error', () => finish('unreachable'));
          });
        }

        function upgradeStatus(host, port, token) {
          return new Promise(resolve => {
            let connected = false;
            const finish = (status, errorCode = null) => resolve({ connected, status, errorCode });
            const request = http.request({
              host, port, agent: false,
              path: '/websockify?token=' + encodeURIComponent(token),
              headers: {
                Connection: 'Upgrade', Upgrade: 'websocket',
                'Sec-WebSocket-Version': '13',
                'Sec-WebSocket-Key': Buffer.from('0123456789abcdef').toString('base64'),
              },
            }, response => {
              finish(response.statusCode);
              response.destroy();
            });
            request.once('socket', socket => {
              connected = !socket.connecting;
              socket.once('connect', () => { connected = true; });
            });
            request.setTimeout(3000, () => request.destroy(Object.assign(Error(), { code: 'ETIMEDOUT' })));
            request.once('upgrade', (_response, socket) => { finish(101); socket.destroy(); });
            request.once('error', error => finish(null, error.code ?? 'unknown'));
            request.end();
          });
        }

        function probeWebSocket(host, port, token) {
          return new Promise(resolve => {
            let opened = false;
            let sawFrame = false;
            let settled = false;
            const socket = new WebSocket(
              `ws://${host}:${port}/websockify?token=${encodeURIComponent(token)}`,
            );
            socket.binaryType = 'arraybuffer';
            const finish = result => {
              if (settled) return;
              settled = true;
              socket.close();
              resolve(result);
            };
            const timer = setTimeout(() => finish({ state: 'timeout' }), 3000);
            socket.addEventListener('open', () => { opened = true; });
            socket.addEventListener('message', event => {
              sawFrame = true;
              const value = event.data instanceof ArrayBuffer
                ? Buffer.from(event.data).toString('ascii')
                : String(event.data);
              if (value.startsWith('RFB ')) finish({ state: 'rfb' });
              else finish({ state: 'unexpected-frame' });
            });
            socket.addEventListener('error', () => {
              clearTimeout(timer);
              finish({ state: opened ? 'closed-no-data' : 'handshake-failed' });
            });
            socket.addEventListener('close', event => {
              clearTimeout(timer);
              if (sawFrame) finish({ state: 'unexpected-frame', closeCode: event.code });
              else finish({ state: opened ? 'closed-no-data' : 'handshake-failed', closeCode: event.code });
            });
          });
        }

        (async () => {
          const token = process.env.REMOTECODE_VIEWER_TOKEN;
          if (!token) throw Error('token-missing');
          const ipv4 = Object.values(os.networkInterfaces()).flat().find(value =>
            value && value.family === 'IPv4' && !value.internal,
          )?.address;
          if (!ipv4) throw Error('ipv4-missing');
          const status = fs.readFileSync('/proc/self/status', 'utf8');
          const uid = Number(status.match(/^Uid:\s+(\d+)/m)?.[1]);
          const capEff = status.match(/^CapEff:\s+([0-9a-f]+)/mi)?.[1];
          const noNewPrivs = Number(status.match(/^NoNewPrivs:\s+(\d+)/m)?.[1]);
          const iptables = cp.spawnSync('iptables', ['-S'], { encoding: 'utf8' });
          const ambient = cp.spawnSync('setpriv', ['--inh-caps=+net_admin', '--ambient-caps=+net_admin', '/bin/true'], { encoding: 'utf8' });
          let markerWriteDenied = false;
          try { fs.writeFileSync('/run/remotecode-context-network-ready', 'probe'); }
          catch (error) { markerWriteDenied = ['EACCES', 'EPERM'].includes(error.code); }
          let dnsAvailable = false;
          try { dnsAvailable = (await Promise.race([dns.lookup('example.com'), new Promise((_, reject) => setTimeout(reject, 3000))])).address.length > 0; } catch {}
          const egress = await tcp('example.com', 443);
          const privilege = { uid, capEff, noNewPrivs, iptablesDenied: !iptables.error && Number.isInteger(iptables.status) && iptables.status !== 0, ambientDenied: !ambient.error && Number.isInteger(ambient.status) && ambient.status !== 0, markerWriteDenied, dnsAvailable, egress };
          for (const port of [5900, 9222]) {
            const deadline = Date.now() + 10000;
            let ready = false;
            while (Date.now() < deadline) {
              if (await tcp('127.0.0.1', port) === 'connected') {
                ready = true;
                break;
              }
              await new Promise(resolve => setTimeout(resolve, 200));
            }
            if (!ready) throw Error('own-listener-not-ready');
          }

          const mode = process.argv[1];
          const ownHttpValid = await upgradeStatus('127.0.0.1', 6080, token);
          const ownHttpInvalid = await upgradeStatus('127.0.0.1', 6080, 'invalid-context-probe');
          const ownWebSocket = await probeWebSocket('127.0.0.1', 6080, token);
          const ownInvalidAuth = await probeWebSocket('127.0.0.1', 6080, 'invalid-context-probe');
          if (mode === 'control') {
            console.log(JSON.stringify({ ownHttpValid, ownHttpInvalid, ownWebSocket, ownInvalidAuth, privilege }));
            process.exit(0);
          }
          const peerIPv4 = mode;
          const peerHostPort = Number(process.argv[2]);
          const peerTCP = [];
          for (const port of [5900, 6080, 9222]) {
            peerTCP.push({ port, status: await tcp(peerIPv4, port) });
          }
          const peerDirectHttp = await upgradeStatus(peerIPv4, 6080, token);
          const peerHostHttp = await upgradeStatus('host.docker.internal', peerHostPort, token);
          const peerDirectWebSocket = await probeWebSocket(peerIPv4, 6080, token);
          const peerWebSocket = await probeWebSocket('host.docker.internal', peerHostPort, token);
          console.log(JSON.stringify({ ipv4, peerTCP, peerDirectHttp, peerHostHttp, peerDirectWebSocket, peerWebSocket, privilege }));
          process.exit(0);
        })().catch(() => {
          console.log(JSON.stringify({ phase: 'node-probe', status: 'probe-error' }));
          process.exit(0);
        });
        """#
        func viewerTokenDigest(_ name: String) throws -> String {
            let output = try docker.exec(name: name, command: [
                "node", "-e",
                "process.stdout.write(require('node:crypto').createHash('sha256').update(process.env.REMOTECODE_VIEWER_TOKEN).digest('hex'))",
            ])
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tokenDigestA = try viewerTokenDigest(nameA)
        let tokenDigestB = try viewerTokenDigest(nameB)
        XCTAssertNotEqual(tokenDigestA, tokenDigestB)

        func handshakeDenied(_ value: Any?, allowUnreachable: Bool) -> Bool {
            guard let result = value as? [String: Any], let connected = result["connected"] as? Bool else { return false }
            if !connected { return allowUnreachable }
            if let status = result["status"] as? Int, (400..<500).contains(status) { return true }
            return result["errorCode"] as? String == "ECONNRESET"
        }
        func runNetworkProbe(name: String, mode: String, peerHostPort: Int? = nil) throws -> [String: Any] {
            let arguments = ["node", "-e", networkProbe, mode] + (peerHostPort.map { [String($0)] } ?? [])
            let output = try docker.exec(name: name, command: arguments)
            let result = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            print("Context network probe \(name): \(result)")
            guard let data = result.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("Network probe returned invalid semantic JSON")
                return [:]
            }
            guard let privilege = object["privilege"] as? [String: Any] else {
                XCTFail("Guest policy probe omitted semantic results")
                return object
            }
            XCTAssertEqual(privilege["uid"] as? Int, 1000)
            XCTAssertEqual(privilege["capEff"] as? String, "0000000000000000")
            XCTAssertEqual(privilege["noNewPrivs"] as? Int, 1)
            XCTAssertEqual(privilege["iptablesDenied"] as? Bool, true)
            XCTAssertEqual(privilege["ambientDenied"] as? Bool, true)
            XCTAssertEqual(privilege["markerWriteDenied"] as? Bool, true)
            XCTAssertEqual(privilege["dnsAvailable"] as? Bool, true)
            XCTAssertEqual(privilege["egress"] as? String, "connected")
            if mode == "control" {
                guard let ownWebSocket = object["ownWebSocket"] as? [String: Any],
                      let ownInvalidAuth = object["ownInvalidAuth"] as? [String: Any] else {
                    XCTFail("Control probe omitted WebSocket results")
                    return object
                }
                XCTAssertEqual((object["ownHttpValid"] as? [String: Any])?["status"] as? Int, 101)
                XCTAssertTrue(handshakeDenied(object["ownHttpInvalid"], allowUnreachable: false), "Invalid token must be rejected after TCP connects")
                XCTAssertEqual(ownWebSocket["state"] as? String, "rfb", "Own token must receive RFB data")
                XCTAssertTrue(["closed-no-data", "handshake-failed"].contains(ownInvalidAuth["state"] as? String ?? ""), "Invalid token must not receive a frame")
                return object
            }
            guard let peerTCP = object["peerTCP"] as? [[String: Any]],
                  let peerDirectWebSocket = object["peerDirectWebSocket"] as? [String: Any],
                  let peerWebSocket = object["peerWebSocket"] as? [String: Any] else {
                XCTFail("Cross-probe omitted semantic results")
                return object
            }
            XCTAssertEqual(peerTCP.map { $0["port"] as? Int }, [5900, 6080, 9222])
            XCTAssertTrue(peerTCP.allSatisfy { $0["status"] as? String == "unreachable" }, "Every peer TCP port, including published 6080, must be unreachable")
            XCTAssertEqual((object["peerDirectHttp"] as? [String: Any])?["connected"] as? Bool, false, "Peer direct viewer TCP must be unreachable")
            XCTAssertEqual((object["peerHostHttp"] as? [String: Any])?["connected"] as? Bool, false, "Peer host-published viewer TCP must be unreachable")
            XCTAssertTrue(handshakeDenied(object["peerDirectHttp"], allowUnreachable: true), "Peer direct viewer must not accept this context's token")
            XCTAssertTrue(handshakeDenied(object["peerHostHttp"], allowUnreachable: true), "Peer host viewer must not accept this context's token")
            for peer in [peerDirectWebSocket, peerWebSocket] {
                XCTAssertTrue(["unreachable", "closed-no-data", "handshake-failed"].contains(peer["state"] as? String ?? ""), "Peer viewer must not receive any frame")
            }
            return object
        }
        func guestIPv4(_ name: String) throws -> String {
            let output = try docker.exec(name: name, command: ["node", "-e", "const n=require('node:os').networkInterfaces();const x=Object.values(n).flat().find(i=>i&&i.family==='IPv4'&&!i.internal);if(!x)process.exit(1);process.stdout.write(x.address)"])
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ipv4A = try guestIPv4(nameA)
        let ipv4B = try guestIPv4(nameB)
        func assertNativeViewer(_ url: URL) async throws {
            var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            components.scheme = "ws"
            let viewerPath = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "path" })?.value)
            let pathParts = viewerPath.split(separator: "?", maxSplits: 1).map(String.init)
            guard pathParts.count == 2, pathParts[0] == "websockify", pathParts[1].hasPrefix("token=") else {
                XCTFail("Native viewer returned an invalid path"); return
            }
            components.path = "/" + pathParts[0]
            components.queryItems = [URLQueryItem(name: "token", value: String(pathParts[1].dropFirst("token=".count)))]
            let socketURL = try XCTUnwrap(components.url)
            let session = URLSession(configuration: .ephemeral)
            let task = session.webSocketTask(with: socketURL)
            task.resume()
            defer { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
            let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask { try await task.receive() }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    task.cancel(with: .goingAway, reason: nil)
                    throw URLError(.timedOut)
                }
                let value = try await group.next()!
                group.cancelAll()
                return value
            }
            guard case .data(let data) = message else { XCTFail("Native viewer did not receive binary RFB data"); return }
            XCTAssertTrue(data.starts(with: Data("RFB ".utf8)), "Native viewer did not receive RFB prefix")
        }
        for ready in [readyA, readyB] {
            do { try await assertNativeViewer(ready.screenURL) }
            catch { XCTFail("Native own viewer failed or timed out before RFB data") }
        }
        _ = try runNetworkProbe(name: nameA, mode: "control")
        _ = try runNetworkProbe(name: nameB, mode: "control")
        _ = try runNetworkProbe(name: nameA, mode: ipv4B, peerHostPort: observedB.hostPort)
        _ = try runNetworkProbe(name: nameB, mode: ipv4A, peerHostPort: observedA.hostPort)
        let gatewayPort = UInt16(observedB.hostPort)
        let gatewayLease = try service.installGatewayLease(identity: identityA, runID: AgentRunID(), port: gatewayPort)
        func assertLeaseTCP(_ lease: BotContextGatewayLease, connected: Bool, name: String) throws {
            let script = "const net=require('node:net');const s=net.createConnection({host:process.argv[1],port:Number(process.argv[2])});let done=false;function finish(value){if(done)return;done=true;s.destroy();process.stdout.write(value)}s.setTimeout(1000);s.once('connect',()=>finish('connected'));s.once('timeout',()=>finish('unreachable'));s.once('error',()=>finish('unreachable'));"
            let output = try docker.exec(name: name, command: ["node", "-e", script, lease.hostAddress, String(lease.port)], detach: false)
            XCTAssertEqual(String(decoding: output, as: UTF8.self), connected ? "connected" : "unreachable")
        }
        try assertLeaseTCP(gatewayLease, connected: true, name: nameA)
        let otherEndpoint = BotContextGatewayLease(identity: identityA, runID: gatewayLease.runID, hostAddress: gatewayLease.hostAddress, port: UInt16(observedA.hostPort))
        try assertLeaseTCP(otherEndpoint, connected: false, name: nameA)
        try assertLeaseTCP(otherEndpoint, connected: false, name: nameB)
        let wrongRunLease = BotContextGatewayLease(identity: identityA, runID: AgentRunID(), hostAddress: gatewayLease.hostAddress, port: gatewayLease.port)
        XCTAssertThrowsError(try service.revokeGatewayLease(wrongRunLease))
        XCTAssertTrue(try docker.inspect(name: nameA).running, "Wrong-run revoke must not stop guest A runtime")
        try assertLeaseTCP(gatewayLease, connected: true, name: nameA)
        try service.revokeGatewayLease(gatewayLease)
        let flowReadback = try docker.exec(name: nameA, command: ["conntrack", "-L", "-f", "ipv4", "-p", "tcp", "-d", gatewayLease.hostAddress, "--dport", String(gatewayLease.port)], user: "0", detach: false)
        XCTAssertTrue(String(decoding: flowReadback, as: UTF8.self).isEmpty, "Revoked lease must have no conntrack flow")
        try assertLeaseTCP(gatewayLease, connected: false, name: nameA)
        try service.revokeGatewayLease(gatewayLease)
        let homeMarker = BotComputerGuestSpec.guestUserHome + "/context-probe-marker"
        let verify = "test \"$(cat \"$1\")\" = \"$2\" && test ! -e \"$3\" && printf %s \"$2\" > \"$4\" && cat \"$4\""
        XCTAssertEqual(String(decoding: try docker.exec(name: nameA, command: ["sh", "-c", verify, "probe", markerA.path, "A", markerB.path, homeMarker]), as: UTF8.self), "A")
        XCTAssertEqual(String(decoding: try docker.exec(name: nameB, command: ["sh", "-c", verify, "probe", markerB.path, "B", markerA.path, homeMarker]), as: UTF8.self), "B")
        for (name, expected) in [(nameA, "A"), (nameB, "B")] {
            XCTAssertEqual(String(decoding: try docker.exec(name: name, command: ["cat", homeMarker]), as: UTF8.self), expected)
            _ = try docker.exec(name: name, command: ["sh", "-c", "test ! -e \"$1/.distill/accounts\" && test ! -e \"$1/.distill/claude-auth.json\" && test ! -e \"$1/.distill/codex-auth.json\" && test ! -e \"$1/.distill/auth.json\"", "probe", BotComputerGuestSpec.guestUserHome])
        }
        var warmMilliseconds: [Double] = []
        for _ in 0..<5 {
            let (ready, elapsed) = try provision(bindingA, workspaceA)
            XCTAssertEqual(ready.containerID, readyA.containerID)
            warmMilliseconds.append(elapsed)
        }
        print("Context runtime cold milliseconds: A=\(coldA), B=\(coldB); warm A milliseconds: \(warmMilliseconds)")
        print(String(decoding: try docker.run(["stats", "--no-stream", "--format", "{{json .}}", nameA, nameB]), as: UTF8.self))
        XCTAssertEqual(try docker.imageID(tag: BotComputerGuestSpec.imageTag), originalImage)
        XCTAssertEqual(readyA.pngMagic, "89504e47")
        XCTAssertEqual(readyB.pngMagic, "89504e47")
        if let directory = ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_CAPTURE_DIR"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try readyA.capturedPNG.write(to: output.appendingPathComponent("context-runtime-a.png"))
            try readyB.capturedPNG.write(to: output.appendingPathComponent("context-runtime-b.png"))
        }
    }
}
