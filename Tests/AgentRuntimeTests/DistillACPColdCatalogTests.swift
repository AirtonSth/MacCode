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

    func test_aModelTheMacsDistillDoesNotListKeepsTheRefreshAdvice() async throws {
        // WHY: on the Mac the picker and the run share one catalog, so
        // refreshing it is the right advice; pinned so the VM wording below
        // never leaks into Mac runs.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, _) = try writeHarness(root: root, models: ["chatgpt/gpt-6-luna"])
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        do {
            _ = try await client.newSession(cwd: root.path, modelId: "chatgpt/gpt-6.1-sol")
            XCTFail("a model the Mac's Distill does not list must not open a session")
        } catch {
            XCTAssertEqual(
                (error as? DistillACPError)?.description,
                "Selected Distill model 'chatgpt/gpt-6.1-sol' is not advertised. Refresh the model catalog and select one exact model.")
        }
    }

    func test_aModelTheGuestsDistillDoesNotListSaysItIsTheBotsLinuxVM_andNothingElseIsRun() async throws {
        // WHY: a guest thread's picker shows the Mac's catalog, so "refresh
        // the model catalog" sends the user in a circle; the catalog that
        // lacks the model is the Linux VM's. The exact match stays: no other
        // model and no Mac run is substituted.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The harness stands in for `docker exec … distill` (it ignores its argv).
        let (docker, log) = try writeHarness(root: root, models: ["chatgpt/gpt-6-luna"])
        let plan = DistillGuestLaunchPlan(
            runID: UUID().uuidString, dockerExecutable: docker.path, container: "c",
            guestCwd: "/home/remotecode", guestCommand: [], envFileURL: root.appendingPathComponent("x.env"),
            lease: nil, teardown: { _ in }, killGuest: {}, killGuestDetached: {}
        )
        let client = try DistillACPClient(guest: plan)
        defer { client.stop() }
        _ = try await client.initialize()
        do {
            _ = try await client.newSession(cwd: "/home/remotecode", modelId: "chatgpt/gpt-6.1-sol")
            XCTFail("a model the guest's Distill does not list must not open a session")
        } catch {
            XCTAssertEqual(
                (error as? DistillACPError)?.description,
                "The Distill in this bot's Linux VM does not list the model 'chatgpt/gpt-6.1-sol'. The model picker shows the Mac's catalog, which can list models the Linux VM does not. Select another model for this bot.")
        }
        XCTAssertEqual(try recorded(log).compactMap { $0["method"] as? String }, ["initialize", "_x.ai/models/list"])
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

    func test_guestRecoveryRefreshesBothSelectedModelsOnceBeforeOpeningSession() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: ["chatgpt/gpt-6.1-sol", "chatgpt/gpt-6-luna"], initialModels: [], catalogSequence: [[], ["chatgpt/gpt-6.1-sol", "chatgpt/gpt-6-luna"]])
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        let calls = RecoveryCallCount()
        client.guestCatalogRecovery = { await calls.increment(); return true }
        _ = try await client.initialize()
        _ = try await client.newSession(cwd: root.path, modelId: "chatgpt/gpt-6.1-sol", reasoningModel: "chatgpt/gpt-6-luna")
        let methods = try recorded(log).compactMap { $0["method"] as? String }
        let recoveryCount = await calls.value
        XCTAssertEqual(recoveryCount, 1, "one recovery must repair the shared catalog, not duplicate user task or substitute selection")
        XCTAssertEqual(methods.filter { $0 == "_x.ai/models/list" }.count, 2)
        XCTAssertEqual(methods.filter { $0 == "session/new" }.count, 1)
        XCTAssertEqual(methods.suffix(3), ["_x.ai/models/list", "session/new", DistillACPClient.workerModelSetMethod])
        let open = try XCTUnwrap(try recorded(log).first { $0["method"] as? String == "session/new" })
        XCTAssertEqual(((open["params"] as? [String: Any])?["_meta"] as? [String: Any])?["modelId"] as? String, "chatgpt/gpt-6.1-sol")
        let worker = try XCTUnwrap(try recorded(log).first { $0["method"] as? String == DistillACPClient.workerModelSetMethod })
        XCTAssertEqual((worker["params"] as? [String: Any])?["modelId"] as? String, "chatgpt/gpt-6-luna")
    }

    func test_guestRecoveryRunsWhenOnlyWorkerModelIsMissing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: ["chatgpt/gpt-6.1-sol", "chatgpt/gpt-6-luna"], initialModels: ["chatgpt/gpt-6.1-sol"], catalogSequence: [["chatgpt/gpt-6.1-sol"], ["chatgpt/gpt-6.1-sol", "chatgpt/gpt-6-luna"]])
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        let calls = RecoveryCallCount()
        client.guestCatalogRecovery = { await calls.increment(); return true }
        _ = try await client.initialize()
        _ = try await client.newSession(cwd: root.path, modelId: "chatgpt/gpt-6.1-sol", reasoningModel: "chatgpt/gpt-6-luna")
        let recoveryCount = await calls.value
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(try recorded(log).compactMap { $0["method"] as? String }.filter { $0 == "_x.ai/models/list" }.count, 2)
    }

    func test_guestRecoveryThatLeavesModelMissingDoesNotOpenSession() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: ["chatgpt/gpt-6.1-sol"], catalogSequence: [["chatgpt/gpt-6.1-sol"], ["chatgpt/gpt-6.1-sol"]])
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        let calls = RecoveryCallCount()
        client.guestCatalogRecovery = { await calls.increment(); return true }
        _ = try await client.initialize()
        do { _ = try await client.newSession(cwd: root.path, modelId: "chatgpt/gpt-6-luna"); XCTFail("successful recovery without selected model must not open a session") } catch { }
        let recoveryCount = await calls.value
        XCTAssertEqual(recoveryCount, 1)
        let methods = try recorded(log).compactMap { $0["method"] as? String }
        XCTAssertFalse(methods.contains("session/new"))
        XCTAssertFalse(methods.contains("session/prompt"))
    }

    func test_guestRecoveryDeclinedAndThrowingPreserveOriginalMissingModelErrorWithoutSession() async throws {
        for throwsError in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let (binary, log) = try writeHarness(root: root, models: ["chatgpt/gpt-6.1-sol"], catalogSequence: [["chatgpt/gpt-6.1-sol"], ["chatgpt/gpt-6.1-sol"]])
            let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
            defer { client.stop() }
            let calls = RecoveryCallCount()
            client.guestCatalogRecovery = { await calls.increment(); if throwsError { throw DistillACPError.unsupported("recovery failed") }; return false }
            _ = try await client.initialize()
            do { _ = try await client.newSession(cwd: root.path, modelId: "chatgpt/gpt-6-luna"); XCTFail("missing model must not create session after failed recovery") }
            catch { XCTAssertTrue((error as? DistillACPError)?.description.contains("not advertised") == true) }
            let recoveryCount = await calls.value
            XCTAssertEqual(recoveryCount, 1)
            let methods = try recorded(log).compactMap { $0["method"] as? String }
            XCTAssertFalse(methods.contains("session/new"))
            XCTAssertFalse(methods.contains("session/prompt"))
        }
    }

    func test_guestRecoveryCancellationThrowsCancellationErrorWithoutOpeningSession() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: ["chatgpt/gpt-6.1-sol"])
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        client.guestCatalogRecovery = { throw CancellationError() }
        _ = try await client.initialize()
        do { _ = try await client.newSession(cwd: root.path, modelId: "chatgpt/gpt-6-luna"); XCTFail("cancelled recovery must abort model selection") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(try recorded(log).compactMap { $0["method"] as? String }.contains("session/new"))
    }

    func test_ambiguousBareModelNeverInvokesGuestRecovery() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: ["alpha/gpt-6-luna", "beta/gpt-6-luna"])
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        let calls = RecoveryCallCount()
        client.guestCatalogRecovery = { await calls.increment(); return true }
        _ = try await client.initialize()
        do { _ = try await client.newSession(cwd: root.path, modelId: "gpt-6-luna"); XCTFail("ambiguous suffix must not trigger fallback") } catch { }
        let recoveryCount = await calls.value
        XCTAssertEqual(recoveryCount, 0, "ambiguous choice must not replace user's model selection")
        XCTAssertFalse(try recorded(log).compactMap { $0["method"] as? String }.contains("session/new"))
    }

    func test_guestRecoveryDoesNotRetryAfterSessionOpenError() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, log) = try writeHarness(root: root, models: ["chatgpt/gpt-6.1-sol"], sessionOpenError: true)
        let client = try DistillACPClient(binary: binary.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        let calls = RecoveryCallCount()
        client.guestCatalogRecovery = { await calls.increment(); return true }
        _ = try await client.initialize()
        do { _ = try await client.newSession(cwd: root.path, modelId: "chatgpt/gpt-6.1-sol"); XCTFail("provider session error must surface") } catch { }
        let recoveryCount = await calls.value
        XCTAssertEqual(recoveryCount, 0)
        XCTAssertEqual(try recorded(log).compactMap { $0["method"] as? String }.filter { $0 == "session/new" }.count, 1)
    }

    private actor RecoveryCallCount {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("distill-cold-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ProviderProcessOwnership.shared.configure(fileURL: root.appendingPathComponent("process-ownership.json"))
        return root
    }

    private func writeHarness(root: URL, models: [String]?, initialModels: [String]? = nil, catalogSequence: [[String]]? = nil, sessionOpenError: Bool = false) throws -> (URL, URL) {
        let log = root.appendingPathComponent("calls.jsonl")
        let binary = root.appendingPathComponent("fake-acp")
        let catalog = models.map { "[" + $0.map { "{\"modelId\":\"\($0)\",\"name\":\"\($0)\"}" }.joined(separator: ",") + "]" } ?? "null"
        let initial = initialModels ?? (models == nil ? nil : ["unrelated-default"])
        let initialJSON = initial.map { "[" + $0.map { "{\"modelId\":\"\($0)\",\"name\":\"\($0)\"}" }.joined(separator: ",") + "]" } ?? "null"
        let catalogSequenceJSON = try JSONSerialization.data(withJSONObject: (catalogSequence ?? []).map { $0.map { ["modelId": $0, "name": $0] } }).withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        let source = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        calls = pathlib.Path(\(String(reflecting: log.path)))
        catalog = json.loads(\(String(reflecting: catalog)))
        initial = json.loads(\(String(reflecting: initialJSON)))
        catalog_sequence = json.loads(\(String(reflecting: catalogSequenceJSON)))
        session_open_error = \(sessionOpenError ? "True" : "False")
        catalog_index = 0
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {})
            with calls.open("a") as f: f.write(json.dumps({"method": method, "params": params}) + "\\n")
            result = {}
            if method == "initialize":
                result = {"protocolVersion": 1, "agentCapabilities": {"loadSession": True, "sessionCapabilities": {"resume": True}, "promptCapabilities": {}}, "_meta": ({"modelState": {"availableModels": initial}} if initial is not None else {})}
            elif method == "_x.ai/models/list":
                if catalog_sequence:
                    current_catalog = catalog_sequence[min(catalog_index, len(catalog_sequence) - 1)]
                    catalog_index += 1
                else:
                    current_catalog = catalog
                result = {"result": {"availableModels": current_catalog or []}}
            elif method in ("session/new", "session/load"):
                if method == "session/new" and session_open_error:
                    print(json.dumps({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32000,"message":"session open failed"}}), flush=True)
                    continue
                model = (params.get("_meta") or {}).get("modelId")
                if catalog is not None and model and model not in [m["modelId"] for m in (current_catalog if method == "session/new" and catalog_sequence else catalog)]:
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
