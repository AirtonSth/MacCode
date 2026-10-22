import XCTest
import CoreModel
@testable import AgentRuntime

final class DistillACPOperationTests: XCTestCase {
    private final class Statuses: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[String: Any]] = []
        func append(_ value: Any?) { lock.withLock { if let value = value as? [String: Any] { values.append(value) } } }
        var snapshot: [[String: Any]] { lock.withLock { values } }
    }

    private func fixture(_ mode: String) throws -> (DistillACPClient, URL, Statuses) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distill-status-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("distill")
        try #"""
        #!/usr/bin/env python3
        import sys, json, threading, time, os
        mode = os.environ['RC_STATUS_TEST_MODE']
        output = threading.Lock()
        active = {}
        def send(value):
            with output:
                print(json.dumps(value), flush=True)
        def reply(req, value):
            send({'jsonrpc':'2.0','id':req['id'],'result':value})
        def complete(req, value, delay):
            time.sleep(delay)
            reply(req, value)
            active.pop(req['params']['_meta']['remotecode/operationId'], None)
        for line in sys.stdin:
            req = json.loads(line)
            method, params = req.get('method'), req.get('params', {})
            if method == 'initialize':
                reply(req, {'protocolVersion':1,'_meta':{'remotecode/operationStatusV1':True,'remotecode/readyRequired':True}})
            elif method in ('_remotecode/ready','session/prompt'):
                op = params['_meta']['remotecode/operationId']
                active[op] = (req, time.monotonic())
                if mode == 'exit' and method == '_remotecode/ready':
                    print('fixture process stopped', file=sys.stderr, flush=True)
                    sys.exit(23)
                if mode == 'blocked':
                    continue
                result = {'protocolVersion':1,'agentCapabilities':{'loadSession':True}} if method == '_remotecode/ready' else {'stopReason':'end_turn'}
                threading.Thread(target=complete, args=(req,result,2.2 if method == '_remotecode/ready' else 0.6), daemon=True).start()
            elif method == '_remotecode/status':
                if mode == 'blocked':
                    continue
                op = params['operationId']
                if op not in active:
                    reply(req, {'operationId':op,'state':'finished'})
                    continue
                original, start = active[op]
                prompt = original['method'] == 'session/prompt'
                age = int((time.monotonic() - start) * 1000) + (700000 if prompt else 0)
                status = {'operationId':op,'sessionId':original['params'].get('sessionId'),'state':'running',
                          'phase':'executing_tool' if prompt else 'loading_configuration',
                          'sequence':1,'lastProgressAgeMs':age,'phaseElapsedMs':age}
                if prompt:
                    wrong = dict(status, sessionId='another-conversation', phase='waiting_authorization')
                    send({'jsonrpc':'2.0','method':'_remotecode/operation','params':wrong})
                reply(req, status)
            elif method == 'session/cancel':
                for op, (original, start) in list(active.items()):
                    if original['params'].get('sessionId') == params['sessionId']:
                        reply(original, {'stopReason':'cancelled'})
                        active.pop(op, None)
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let statuses = Statuses()
        let client = try DistillACPClient(binary: binary.path, cwd: root.path,
            environment: ["RC_STATUS_TEST_MODE": mode], tagProcess: false,
            notificationHandler: { method, payload in
                if method == DistillACPClient.operationMethod { statuses.append(payload) }
            })
        client.operationPollInterval = 0.02
        client.operationResponseTimeout = 0.15
        return (client, root, statuses)
    }

    func test_slowReadinessUsesEvidenceBeyondTheOldDeadline() async throws {
        let (client, root, statuses) = try fixture("slow")
        defer { client.stop(); try? FileManager.default.removeItem(at: root) }
        let result = try await client.initialize(timeout: 2)
        XCTAssertTrue(result.loadSession, "full capabilities arrive only after readiness")
        XCTAssertTrue(client.supportsOperationStatus)
        XCTAssertGreaterThan(statuses.snapshot.count, 1)
        XCTAssertTrue(statuses.snapshot.allSatisfy { $0["sequence"] as? Int == 1 }, "heartbeats are not progress")
    }

    func test_silentToolIsMarkedStalledAndOnlyThePromptResponseCompletesIt() async throws {
        let (client, root, statuses) = try fixture("slow")
        defer { client.stop(); try? FileManager.default.removeItem(at: root) }
        let capabilities = try await client.initialize(timeout: 2)
        let started = Date()
        let result = try await client.prompt(sessionId: "conversation", request: AgentRunRequest(
            threadId: AgentThreadID(), provider: .distill, model: "auto", cwd: root.path, prompt: "Go"
        ), capabilities: capabilities, writePermit: AgentRunAcceptancePermit(), beforeWrite: {}, onAccepted: {})
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(result["stopReason"] as? String, "end_turn")
        let tool = statuses.snapshot.filter { $0["phase"] as? String == "executing_tool" }
        XCTAssertFalse(tool.isEmpty)
        XCTAssertTrue(tool.allSatisfy { $0["stalled"] as? Bool == true })
        XCTAssertFalse(statuses.snapshot.contains { $0["sessionId"] as? String == "another-conversation" })
    }

    func test_blockedACPDispatcherFailsThePendingOperation() async throws {
        let (client, root, _) = try fixture("blocked")
        defer { client.stop(); try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await client.initialize(timeout: 2)
            XCTFail("a blocked dispatcher must not look healthy")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stopped responding"), "\(error)")
        }
    }

    func test_processExitKeepsItsOwnDiagnostic() async throws {
        let (client, root, _) = try fixture("exit")
        defer { client.stop(); try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await client.initialize(timeout: 2)
            XCTFail("exit is not readiness")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("23"), "\(error)")
        }
    }
}
