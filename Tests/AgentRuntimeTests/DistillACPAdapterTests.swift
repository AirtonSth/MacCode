import Foundation
import XCTest
import CoreModel
@testable import AgentRuntime

final class DistillACPAdapterTests: ProviderProcessTestCase {
    func test_emptyMainModelIsRejectedBeforeACPStarts_becauseDistillMustNotUseAccountDefault() async throws {
        let adapter = DistillACPAdapter(binaryNameOverride: "/missing/distill-agent")
        do {
            _ = try await adapter.startSession(
                AgentRunRequest(
                    threadId: AgentThreadID(),
                    provider: .distill,
                    model: "  ",
                    cwd: "/tmp",
                    prompt: "Do work"
                ),
                onEvent: { _ in }
            )
            XCTFail("An empty Main model must not fall back to the account default")
        } catch let error as AgentProviderAdapterError {
            guard case .unsupported(let message) = error else {
                return XCTFail("expected an explicit model-selection refusal, got \(error)")
            }
            XCTAssertEqual(message, "Select an explicit Distill Main model before running.")
        }
    }

    func test_discoverySkipsReasoningExtensionWhenOlderPeerOmitsCapability() async throws {
        // WHY: model discovery must preserve a valid catalog from older Distill ACP peers that do not implement the optional Reasoning selector.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-acp-old-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let requestsURL = root.appendingPathComponent("requests.jsonl")
        let harnessURL = root.appendingPathComponent("distill-agent")
        let harness = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        requests = pathlib.Path(\(String(reflecting: requestsURL.path)))
        def record(value):
            with requests.open("a") as output:
                output.write(json.dumps(value) + "\\n")
        def send(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {})
            record({"method":method})
            if method == "initialize":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"protocolVersion":1,"agentCapabilities":{"loadSession":True,"sessionCapabilities":{"resume":True},"promptCapabilities":{}}}})
            elif method == "session/new":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"sessionId":"old-distill-session","models":{"availableModels":[{"modelId":"live-distill-model","name":"Live Distill Model"}],"currentModelId":"live-distill-model"}}})
            elif method == "_x.ai/session/worker_model/set":
                send({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32601,"message":"method not found"}})
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)
        let result = await DistillACPAdapter(
            binaryNameOverride: harnessURL.path,
            discoveryCwd: root.path
        ).discoveryResult()

        XCTAssertFalse(result.isFallback, "an old peer's live model catalog must survive optional-extension absence")
        XCTAssertEqual(result.models.map(\.id), ["live-distill-model"])
        let methods = try String(contentsOf: requestsURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
            .compactMap { $0["method"] }
        XCTAssertFalse(methods.contains("_x.ai/session/worker_model/set"),
                       "discovery must not call an extension the peer did not advertise")
    }

    private func writeWorkerHarness(root: URL, initializeCapabilities: String, workerResult: String) throws -> (harness: URL, requests: URL) {
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
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"protocolVersion":1,"agentCapabilities":\(initializeCapabilities)}})
            elif method == "session/new":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"sessionId":"worker-session","models":{"currentModelId":"main"}}})
            elif method == "session/set_model":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"_meta":{"model":params.get("modelId"),"contextWindow":1000}}})
            elif method == "_x.ai/session/worker_model/set":
                send({"jsonrpc":"2.0", "id":message["id"], "result":\(workerResult)})
            elif method in ("session/set_mode", "session/set_config_option"):
                send({"jsonrpc":"2.0", "id":message["id"], "result":{}})
            elif method == "session/prompt":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"stopReason":"end_turn"}})
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)
        return (harnessURL, requestsURL)
    }

    private func recordedRequests(_ url: URL) throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return try text.split(whereSeparator: \.isNewline)
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func makeTempRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func test_initializeParsesSessionWorkerModelCapability() async throws {
        // WHY: the Worker selector must only be used when the harness advertises per-session support.
        for advertised in [true, false] {
            let root = try makeTempRoot("distill-acp-worker-cap")
            defer { try? FileManager.default.removeItem(at: root) }
            let flag = advertised ? "True" : "False"
            let (harness, _) = try writeWorkerHarness(
                root: root,
                initializeCapabilities: "{\"_meta\":{\"x.ai/capabilities\":{\"sessionWorkerModel\":\(flag),\"sessionReasoningModel\":True}}}",
                workerResult: "{}"
            )
            let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
            defer { client.stop() }
            let initialized = try await client.initialize()
            XCTAssertEqual(initialized.sessionWorkerModel, advertised)
        }
    }

    func test_workerSetSendsWireParamsAndValidatesResponse() async throws {
        // WHY: the app must never claim a Worker model the harness did not confirm.
        let root = try makeTempRoot("distill-acp-worker-wire")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{\"_meta\":{\"x.ai/capabilities\":{\"sessionWorkerModel\":True}}}",
            workerResult: "{\"modelId\":params.get(\"modelId\") or None,\"effort\":params.get(\"effort\") or \"auto\",\"source\":\"session\"}"
        )
        let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        let fixed = try await client.setReasoningModel(sessionId: "s", modelId: "grok-4.5", effortSelection: .fixed(.high))
        XCTAssertEqual(fixed.modelId, "grok-4.5")
        XCTAssertEqual(fixed.effort, .high)
        XCTAssertFalse(fixed.isAutomatic)
        let auto = try await client.setReasoningModel(sessionId: "s", modelId: "grok-4.5", effortSelection: .automatic)
        XCTAssertTrue(auto.isAutomatic)
        let off = try await client.setReasoningModel(sessionId: "s", modelId: nil)
        XCTAssertNil(off.modelId)
        let params = try recordedRequests(requestsURL)
            .filter { $0["method"] as? String == DistillACPClient.workerModelSetMethod }
            .compactMap { $0["params"] as? [String: Any] }
        XCTAssertEqual(params.map { $0["modelId"] as? String }, ["grok-4.5", "grok-4.5", ""])
        XCTAssertEqual(params[0]["effort"] as? String, "high")
        XCTAssertEqual(params[1]["effort"] as? String, "auto")
        XCTAssertTrue(params[2]["effort"] is NSNull, "Off inherits effort from the Distill config")
    }

    func test_workerSetRejectsMismatchedResponse() async throws {
        let root = try makeTempRoot("distill-acp-worker-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, _) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{\"_meta\":{\"x.ai/capabilities\":{\"sessionWorkerModel\":True}}}",
            workerResult: "{\"modelId\":\"other\",\"effort\":\"auto\",\"source\":\"config\"}"
        )
        let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        do {
            _ = try await client.setReasoningModel(sessionId: "s", modelId: "grok-4.5")
            XCTFail("A different Worker model in the response must be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("did not confirm the requested Worker model"))
        }
        let root2 = try makeTempRoot("distill-acp-worker-mismatch-effort")
        defer { try? FileManager.default.removeItem(at: root2) }
        let (harness2, _) = try writeWorkerHarness(
            root: root2,
            initializeCapabilities: "{\"_meta\":{\"x.ai/capabilities\":{\"sessionWorkerModel\":True}}}",
            workerResult: "{\"modelId\":params.get(\"modelId\"),\"effort\":\"low\",\"source\":\"session\"}"
        )
        let client2 = try DistillACPClient(binary: harness2.path, cwd: root2.path, tagProcess: false)
        defer { client2.stop() }
        _ = try await client2.initialize()
        do {
            _ = try await client2.setReasoningModel(sessionId: "s", modelId: "grok-4.6", effortSelection: .fixed(.high))
            XCTFail("A different Worker effort in the response must be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("did not confirm the requested Worker-model effort"), "\(error)")
        }
    }

    func test_setModelAcceptsDistill2024MinimalResponseForFixedAndAutoEffort() async throws {
        // WHY: Distill 2.0.24 answers set_model with only {model, contextWindow}; Auto main effort must not need extra acks.
        let root = try makeTempRoot("distill-acp-setmodel-2024")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{}",
            workerResult: "{}"
        )
        let client = try DistillACPClient(binary: harness.path, cwd: root.path, tagProcess: false)
        defer { client.stop() }
        _ = try await client.initialize()
        let auto = try await client.newSession(cwd: root.path, modelId: "grok-4.6", mainEffortSelection: .automatic)
        XCTAssertEqual(auto.appliedMainModelId, "grok-4.6")
        XCTAssertEqual(auto.appliedMainEffortSelection, .automatic)
        let fixed = try await client.setModel(sessionId: "worker-session", modelId: "grok-4.6", reasoningEffort: .high)
        XCTAssertEqual(fixed.canonicalModelId, "grok-4.6")
        XCTAssertEqual(fixed.effort, .high)
        let setModels = try recordedRequests(requestsURL).filter { $0["method"] as? String == "session/set_model" }
        let meta = try XCTUnwrap((setModels.first?["params"] as? [String: Any])?["_meta"] as? [String: Any])
        XCTAssertEqual(meta["reasoningEffortAuto"] as? Bool, true)
    }

    func test_adapterNeverCallsWorkerMethodOrThrowsWhenPeerDoesNotAdvertiseIt() async throws {
        // WHY: older Distill builds inherit Worker from config; a selected Worker model must not block or fail the session.
        let root = try makeTempRoot("distill-acp-worker-unsupported")
        defer { try? FileManager.default.removeItem(at: root) }
        let (harness, requestsURL) = try writeWorkerHarness(
            root: root,
            initializeCapabilities: "{}",
            workerResult: "{}"
        )
        let adapter = DistillACPAdapter(binaryNameOverride: harness.path)
        defer { adapter.stopAll() }
        let events = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(
            AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .distill,
                model: "grok-4.6",
                cwd: root.path,
                prompt: "Go",
                reasoningModel: "grok-4.5",
                distillMainEffortSelection: .automatic,
                distillReasoningEffortSelection: .fixed(.high)
            )
        ) { events.append($0) }
        _ = try await events.waitForFinish()
        let methods = try recordedRequests(requestsURL).compactMap { $0["method"] as? String }
        XCTAssertFalse(methods.contains(DistillACPClient.workerModelSetMethod))
        XCTAssertTrue(methods.contains("session/set_model"), "Auto main effort binds through set_model without a capability flag")
    }

    func test_selectedModelRunsTurnsAndResumesOnTheSameACPThread() async throws {
        // WHY: provider selection must reach the harness, and follow-up turns must
        // reuse its session rather than starting a disconnected conversation.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-acp-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let requestsURL = root.appendingPathComponent("requests.jsonl")
        let harnessURL = root.appendingPathComponent("distill-agent")
        let harness = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        requests = pathlib.Path(\(String(reflecting: requestsURL.path)))
        count = 0
        state = {"main": None, "reasoning": None}
        def record(value):
            with requests.open("a") as output:
                output.write(json.dumps(value) + "\\n")
        def prompt_text(blocks):
            if isinstance(blocks, str): return blocks
            if isinstance(blocks, dict): return blocks.get("text", "")
            if isinstance(blocks, list): return " ".join(prompt_text(block) for block in blocks)
            return ""
        def send(value):
            print(json.dumps(value), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            if method == "initialize":
                send({"jsonrpc":"2.0", "id":message["id"], "result":{
                    "protocolVersion":1,
                    "agentCapabilities":{"loadSession":True,"sessionCapabilities":{"resume":True},"promptCapabilities":{},"_meta":{"x.ai/capabilities":{"sessionWorkerModel":True}}}
                }})
            elif method == "session/new":
                params = message.get("params", {})
                meta = params.get("_meta", {})
                state["main"] = meta.get("modelId")
                record({"method":method,"modelId":state["main"]})
                send({"jsonrpc":"2.0", "id":message["id"], "result":{
                    "sessionId":"distill-session-1",
                    "models":{"availableModels":[{"modelId":"gpt-6-luna","name":"GPT-6 Luna"}],"currentModelId":"gpt-6-luna"}
                }})
            elif method == "_x.ai/session/worker_model/set":
                params = message.get("params", {})
                reasoning_model = params.get("modelId") or None
                record({"method":method,"sessionId":params.get("sessionId"),"reasoningModelId":params.get("modelId"),"effort":params.get("effort")})
                if reasoning_model is not None and reasoning_model == state["main"]:
                    send({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32602,"message":"Reasoning model must differ from the Main model"}})
                else:
                    state["reasoning"] = reasoning_model
                    send({"jsonrpc":"2.0", "id":message["id"], "result":{"modelId":reasoning_model,"effort":params.get("effort") or "auto","source":"session"}})
            elif method == "session/set_model":
                params = message.get("params", {})
                next_main = params.get("modelId")
                record({"method":method,"modelId":next_main})
                if next_main is not None and next_main == state["reasoning"]:
                    send({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32602,"message":"Main model must differ from the Reasoning model"}})
                else:
                    state["main"] = next_main
                    send({"jsonrpc":"2.0", "id":message["id"], "result":{"meta":{"model":next_main,"canonicalModelId":next_main}}})
            elif method in ("session/set_mode", "session/set_config_option"):
                send({"jsonrpc":"2.0", "id":message["id"], "result":{}})
            elif method == "session/prompt":
                count += 1
                params = message.get("params", {})
                text = prompt_text(params.get("prompt", []))
                record({"method":method,"sessionId":params.get("sessionId"),"firstRequestPresent":"First request" in text,"followUpPresent":"Follow-up request" in text})
                send({"jsonrpc":"2.0", "method":"session/update", "params":{
                    "sessionId":"distill-session-1",
                    "update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Distill reply " + str(count)}}
                }})
                send({"jsonrpc":"2.0", "id":message["id"], "result":{"stopReason":"end_turn"}})
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)

        let adapter = DistillACPAdapter(binaryNameOverride: harnessURL.path)
        defer { adapter.stopAll() }
        let threadID = AgentThreadID()
        let request = AgentRunRequest(
            threadId: threadID,
            provider: .distill,
            model: "gpt-6-luna",
            cwd: root.path,
            prompt: "First request",
            reasoningModel: "grok-4.5"
        )
        let first = DistillACPAdapterEventBox()
        _ = try await adapter.startSession(request) { first.append($0) }
        let firstFinished = try await first.waitForFinish()
        XCTAssertEqual(firstFinished.providerThreadId, "distill-session-1")
        XCTAssertEqual(firstFinished.finalMessage, "Distill reply 1")

        let second = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(
            AgentRunRequest(
                threadId: threadID,
                provider: .distill,
                model: "gpt-6-luna",
                cwd: root.path,
                prompt: "Follow-up request",
                providerThreadId: firstFinished.providerThreadId,
                reasoningModel: "grok-4.6"
            )
        ) { second.append($0) }
        let secondFinished = try await second.waitForFinish()
        XCTAssertEqual(secondFinished.providerThreadId, "distill-session-1")
        XCTAssertEqual(secondFinished.finalMessage, "Distill reply 2")
        let third = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(
            AgentRunRequest(
                threadId: threadID,
                provider: .distill,
                model: "grok-4.6",
                cwd: root.path,
                prompt: "Third request swaps Main and Reasoning",
                providerThreadId: secondFinished.providerThreadId,
                reasoningModel: "gpt-6-luna"
            )
        ) { third.append($0) }
        let thirdFinished = try await third.waitForFinish()
        XCTAssertEqual(thirdFinished.finalMessage, "Distill reply 3")
        let fourth = DistillACPAdapterEventBox()
        _ = try await adapter.sendTurn(
            AgentRunRequest(
                threadId: threadID,
                provider: .distill,
                model: "grok-4.6",
                cwd: root.path,
                prompt: "Fourth request disables Reasoning",
                providerThreadId: thirdFinished.providerThreadId,
                reasoningModel: nil
            )
        ) { fourth.append($0) }
        let fourthFinished = try await fourth.waitForFinish()
        XCTAssertEqual(fourthFinished.finalMessage, "Distill reply 4")

        let requests = try String(contentsOf: requestsURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let sessionOpen = try XCTUnwrap(requests.first { $0["method"] as? String == "session/new" })
        XCTAssertEqual(sessionOpen["modelId"] as? String, "gpt-6-luna",
                       "the selected Distill main model must reach session/new")
        let reasoningSelections = requests.filter { $0["method"] as? String == "_x.ai/session/worker_model/set" }
        XCTAssertEqual(reasoningSelections.map { $0["reasoningModelId"] as? String }, ["grok-4.5", "grok-4.6", "", "gpt-6-luna", ""],
                       "a crossed swap must clear Reasoning, change Main, apply the new Reasoning model, and then support Off")
        XCTAssertEqual(reasoningSelections.map { $0["sessionId"] as? String }, Array(repeating: "distill-session-1", count: 5))
        let crossSwapMainIndex = try XCTUnwrap(requests.firstIndex { $0["method"] as? String == "session/set_model" && $0["modelId"] as? String == "grok-4.6" })
        let crossSwapReasoningIndex = try XCTUnwrap(requests.firstIndex { $0["method"] as? String == "_x.ai/session/worker_model/set" && $0["reasoningModelId"] as? String == "gpt-6-luna" })
        XCTAssertLessThan(crossSwapMainIndex, crossSwapReasoningIndex,
                          "when the new Reasoning model equals the currently active Main model, switch Main first")
        let prompts = requests.filter { $0["method"] as? String == "session/prompt" }
        XCTAssertEqual(prompts.count, 4, "all user turns must use the selected Distill session")
        XCTAssertEqual(prompts.map { $0["sessionId"] as? String }, Array(repeating: "distill-session-1", count: 4))
        XCTAssertEqual(prompts.map { $0["firstRequestPresent"] as? Bool }, [true, false, false, false])
        XCTAssertEqual(prompts.map { $0["followUpPresent"] as? Bool }, [false, true, false, false])
        XCTAssertTrue(second.assistantText.contains("Distill reply 2"))
        XCTAssertTrue(third.assistantText.contains("Distill reply 3"))
        XCTAssertTrue(fourth.assistantText.contains("Distill reply 4"))
        let history = try await adapter.readThread(threadId: threadID)
        XCTAssertTrue(history.contains {
            if case .itemDelta(_, let body, _, _) = $0 { return body == "Distill reply 1" || body == "Distill reply 2" }
            return false
        }, "the resumed ACP session must retain its readable conversation history")
    }
}

private final class DistillACPAdapterEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentRunEvent] = []

    func append(_ event: AgentRunEvent) {
        lock.lock(); defer { lock.unlock() }
        values.append(event)
    }

    var assistantText: String {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { event in
            guard case .event(.itemDelta(_, let body, _, _)) = event else { return nil }
            return body
        }.joined()
    }

    private func finishResult() -> (status: AgentRunStatus, finalMessage: String?, providerThreadId: String?)? {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { event -> (AgentRunStatus, String?, String?)? in
            guard case .finished(let status, let finalMessage, let providerThreadId) = event else { return nil }
            return (status, finalMessage, providerThreadId)
        }.first
    }

    func waitForFinish(timeout: TimeInterval = 5) async throws -> (status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = finishResult() { return result }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw DistillACPAdapterTestError.timedOut
    }
}

private enum DistillACPAdapterTestError: Error {
    case timedOut
}
