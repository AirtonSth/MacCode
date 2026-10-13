import Foundation
import XCTest
@testable import AgentRuntime

final class DistillACPColdCatalogTests: XCTestCase {
    func test_coldCatalogRefreshesBeforeMainAndWorkerSessionOpen() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: ["chatgpt/gpt-6.1-sol", "chatgpt/gpt-6-luna"])
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        let opened = try await client.newSession(cwd: root.path, modelId: "chatgpt/gpt-6.1-sol", reasoningModel: "chatgpt/gpt-6-luna")
        XCTAssertEqual(opened.sessionId, "catalog-session")
        let requests = try recorded(log)
        XCTAssertEqual(requests.map { $0["method"] as? String }, ["initialize", "_x.ai/models/list", "session/new", DistillACPClient.workerModelSetMethod])
        let open = try XCTUnwrap(requests.first { $0["method"] as? String == "session/new" })
        let meta = try XCTUnwrap((open["params"] as? [String: Any])?["_meta"] as? [String: Any])
        XCTAssertEqual(meta["modelId"] as? String, "chatgpt/gpt-6.1-sol")
        let worker = try XCTUnwrap(requests.first { $0["method"] as? String == DistillACPClient.workerModelSetMethod })
        XCTAssertEqual((worker["params"] as? [String: Any])?["modelId"] as? String, "chatgpt/gpt-6-luna")
    }

    func test_missingModelAfterRefreshDoesNotOpenSessionOrPrompt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: ["chatgpt/gpt-6.1-sol"])
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        do {
            _ = try await client.newSession(cwd: root.path, modelId: "chatgpt/gpt-6-luna")
            XCTFail("missing selected model must fail before session creation")
        } catch { }
        let methods = try recorded(log).compactMap { $0["method"] as? String }
        XCTAssertEqual(methods, ["initialize", "_x.ai/models/list"])
        XCTAssertFalse(methods.contains("session/new"))
        XCTAssertFalse(methods.contains("session/prompt"))
    }

    func test_ambiguousBareModelDoesNotSubstituteDefault() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: ["alpha/gpt-6-luna", "beta/gpt-6-luna"])
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        do {
            _ = try await client.newSession(cwd: root.path, modelId: "gpt-6-luna")
            XCTFail("ambiguous suffix must not select a default")
        } catch { }
        XCTAssertEqual(try recorded(log).compactMap { $0["method"] as? String }, ["initialize", "_x.ai/models/list"])
    }

    func test_exactQualifiedModelWinsAcrossSharedSuffix() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: ["alpha/gpt-6-luna", "beta/gpt-6-luna"])
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        _ = try await client.newSession(cwd: root.path, modelId: "beta/gpt-6-luna")
        let methods = try recorded(log).compactMap { $0["method"] as? String }
        XCTAssertEqual(methods, ["initialize", "_x.ai/models/list", "session/new", DistillACPClient.workerModelSetMethod])
        let open = try XCTUnwrap(try recorded(log).first { $0["method"] as? String == "session/new" })
        XCTAssertEqual(((open["params"] as? [String: Any])?["_meta"] as? [String: Any])?["modelId"] as? String, "beta/gpt-6-luna")
    }

    func test_legacyInitializeWithoutCatalogPreservesSessionProtocol() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: nil)
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        _ = try await client.newSession(cwd: root.path, modelId: "legacy-main", reasoningModel: "legacy-worker")
        let calls = try recorded(log)
        XCTAssertEqual(calls.compactMap { $0["method"] as? String }, ["initialize", "session/new", DistillACPClient.workerModelSetMethod])
        XCTAssertEqual(((calls[1]["params"] as? [String: Any])?["_meta"] as? [String: Any])?["modelId"] as? String, "legacy-main")
        XCTAssertEqual((calls[2]["params"] as? [String: Any])?["modelId"] as? String, "legacy-worker")
    }

    func test_advertisedEmptyCatalogDoesNotOpenAnImplicitDefaultSession() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: [], initialModels: [])
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        do {
            _ = try await client.newSession(cwd: root.path)
            XCTFail("An explicitly empty modern catalog must not silently choose another provider or model.")
        } catch { }
        XCTAssertEqual(try recorded(log).compactMap { $0["method"] as? String }, ["initialize", "_x.ai/models/list"])
    }

    func test_coldCatalogRefreshesBeforeLoadingAnExistingSession() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: ["chatgpt/gpt-6.1-sol", "chatgpt/gpt-6-luna"])
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        _ = try await client.loadSession(sessionId: "existing-session", cwd: root.path, modelId: "chatgpt/gpt-6.1-sol", reasoningModel: "chatgpt/gpt-6-luna")
        let calls = try recorded(log)
        XCTAssertEqual(calls.compactMap { $0["method"] as? String }, ["initialize", "_x.ai/models/list", "session/load", DistillACPClient.workerModelSetMethod])
        XCTAssertEqual(((calls[2]["params"] as? [String: Any])?["_meta"] as? [String: Any])?["modelId"] as? String, "chatgpt/gpt-6.1-sol")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distill-cold-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeHarness(root: URL, models: [String]?, initialModels: [String]? = nil) throws -> (URL, URL) {
        let log = root.appendingPathComponent("calls.jsonl")
        let binary = root.appendingPathComponent("fake-acp")
        let catalog = models.map { "[" + $0.map { "{\"modelId\":\"\($0)\",\"name\":\"\($0)\"}" }.joined(separator: ",") + "]" } ?? "null"
        let initial = initialModels ?? (models == nil ? nil : ["unrelated-default"])
        let initialJSON = initial.map { "[" + $0.map { "{\"modelId\":\"\($0)\",\"name\":\"\($0)\"}" }.joined(separator: ",") + "]" } ?? "null"
        let source = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        calls = pathlib.Path(\(String(reflecting: log.path)))
        catalog = json.loads(\(String(reflecting: catalog)))
        initial = json.loads(\(String(reflecting: initialJSON)))
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {})
            with calls.open("a") as f: f.write(json.dumps({"method": method, "params": params}) + "\\n")
            result = {}
            if method == "initialize":
                result = {"protocolVersion": 1, "agentCapabilities": {"loadSession": True, "sessionCapabilities": {"resume": True}, "promptCapabilities": {}}, "_meta": ({"modelState": {"availableModels": initial}} if initial is not None else {})}
            elif method == "_x.ai/models/list":
                result = {"result": {"availableModels": catalog or []}}
            elif method in ("session/new", "session/load"):
                model = (params.get("_meta") or {}).get("modelId")
                if catalog is not None and model and model not in [m["modelId"] for m in catalog]:
                    print(json.dumps({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32602,"message":"model not advertised"}}), flush=True)
                    continue
                result = {"sessionId":"catalog-session", "models":{"availableModels":[], "currentModelId":model}}
            elif method == "_x.ai/session/worker_model/set":
                result = {"modelId": params.get("modelId"), "effort":"auto", "source":"session"}
            if "id" in message:
                print(json.dumps({"jsonrpc":"2.0", "id":message["id"], "result":result}), flush=True)
        """
        try source.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return (binary, log)
    }

    private func recorded(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
}
