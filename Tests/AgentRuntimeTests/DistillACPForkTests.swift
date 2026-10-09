import Foundation
import XCTest
import CoreModel
@testable import AgentRuntime

/// Fork/side provider contract tests against the fake ACP harness: deterministic
/// child id from the coordinator idempotency key, the exact `x.ai/session/fork`
/// wire params, and idempotent `x.ai/session/delete` compensation.
final class DistillACPForkTests: ProviderProcessTestCase {
    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-acp-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// WHY: same coordinator idempotency key must always map to the same child session id, so a
    /// retried fork converges instead of creating a second orphan session.
    func test_deterministicChildId_isStableAndDistinct() {
        let a = DistillACPAdapter.deterministicForkChildId(idempotencyKey: "remotecode-thread-fork:child-1")
        let again = DistillACPAdapter.deterministicForkChildId(idempotencyKey: "remotecode-thread-fork:child-1")
        let b = DistillACPAdapter.deterministicForkChildId(idempotencyKey: "remotecode-thread-fork:child-2")
        XCTAssertEqual(a, again)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 36, "must be a plain UUID string Distill accepts as a session id")
        // Version-5 marker nibble.
        XCTAssertEqual(Array(a)[14], "5")
    }

    func test_forkSafety_advertisesDurableForkOnceCompensationIsReal() {
        let adapter = DistillACPAdapter(binaryNameOverride: "/missing/distill-agent")
        XCTAssertTrue(adapter.forkSafety.supportsDurableFork)
        XCTAssertTrue(adapter.forkSafety(threadId: AgentThreadID()).supportsDurableFork)
    }

    func test_forkThread_sendsDeterministicNewSessionId_andReturnsChild() async throws {
        let root = try makeRoot("fork")
        defer { try? FileManager.default.removeItem(at: root) }
        let requestsURL = root.appendingPathComponent("requests.jsonl")
        let harnessURL = root.appendingPathComponent("distill-agent")
        let harness = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        requests = pathlib.Path(\(String(reflecting: requestsURL.path)))
        def send(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {})
            with requests.open("a") as output: output.write(json.dumps({"method":method,"params":params}) + "\\n")
            if method == "initialize":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"protocolVersion":1,"agentCapabilities":{"loadSession":True}}})
            elif method == "session/new":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"sessionId":"sess-src","models":{"currentModelId":"m1"}}})
            elif method == "session/prompt":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"stopReason":"end_turn"}})
            elif method in ("session/set_mode", "session/set_config_option"):
                send({"jsonrpc":"2.0", "id":message["id"], "result":{}})
            elif method == "x.ai/session/fork":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"newSessionId":params.get("newSessionId")}})
            elif method == "x.ai/session/delete":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"success":True}})
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)
        let adapter = DistillACPAdapter(binaryNameOverride: harnessURL.path)
        defer { adapter.stopAll() }

        let sourceThreadId = AgentThreadID()
        _ = try await adapter.startSession(
            AgentRunRequest(threadId: sourceThreadId, provider: .distill, model: "m1", cwd: root.path, prompt: "Go")
        ) { _ in }

        let childThreadId = AgentThreadID()
        let key = "remotecode-thread-fork:\(childThreadId.value.uuidString.lowercased())"
        let expectedChild = DistillACPAdapter.deterministicForkChildId(idempotencyKey: key)
        let child = try await adapter.forkThread(AgentProviderForkRequest(
            sourceThreadId: sourceThreadId,
            childThreadId: childThreadId,
            idempotencyKey: key,
            workingDirectory: root.path,
            sourceProviderThreadId: "sess-src"
        ))
        XCTAssertEqual(child, expectedChild)

        let forks = try requests(requestsURL).filter { $0.method == "x.ai/session/fork" }
        let params = try XCTUnwrap(forks.last?.params)
        XCTAssertEqual(params["sourceSessionId"] as? String, "sess-src")
        XCTAssertEqual(params["newSessionId"] as? String, expectedChild)
        XCTAssertEqual(params["sessionKind"] as? String, "fork")

        // Compensation is idempotent and issues the provider delete.
        try await adapter.compensateFork(AgentProviderForkRequest(
            sourceThreadId: sourceThreadId,
            childThreadId: childThreadId,
            idempotencyKey: key,
            workingDirectory: root.path,
            sourceProviderThreadId: "sess-src"
        ), providerChildThreadId: child)
        let deletes = try requests(requestsURL).filter { $0.method == "x.ai/session/delete" }
        XCTAssertEqual((deletes.last?.params)?["sessionId"] as? String, child)
    }

    private struct Recorded { let method: String; let params: [String: Any] }
    private func requests(_ url: URL) throws -> [Recorded] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Recorded? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let method = object["method"] as? String else { return nil }
                return Recorded(method: method, params: object["params"] as? [String: Any] ?? [:])
            }
    }
}
