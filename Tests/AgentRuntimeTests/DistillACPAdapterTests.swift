import Foundation
import XCTest
import CoreModel
@testable import AgentRuntime

final class DistillACPAdapterTests: ProviderProcessTestCase {
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
                    "agentCapabilities":{"loadSession":True,"sessionCapabilities":{"resume":True},"promptCapabilities":{},"_meta":{"x.ai/capabilities":{"sessionReasoningModel":True}}}
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
            elif method == "x.ai/session/reasoning_model/set":
                params = message.get("params", {})
                reasoning_model = params.get("modelId") or None
                record({"method":method,"sessionId":params.get("sessionId"),"reasoningModelId":params.get("modelId")})
                if reasoning_model is not None and reasoning_model == state["main"]:
                    send({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32602,"message":"Reasoning model must differ from the Main model"}})
                else:
                    state["reasoning"] = reasoning_model
                    send({"jsonrpc":"2.0", "id":message["id"], "result":{}})
            elif method == "session/set_model":
                params = message.get("params", {})
                next_main = params.get("modelId")
                record({"method":method,"modelId":next_main})
                if next_main is not None and next_main == state["reasoning"]:
                    send({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32602,"message":"Main model must differ from the Reasoning model"}})
                else:
                    state["main"] = next_main
                    send({"jsonrpc":"2.0", "id":message["id"], "result":{}})
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
        let reasoningSelections = requests.filter { $0["method"] as? String == "x.ai/session/reasoning_model/set" }
        XCTAssertEqual(reasoningSelections.map { $0["reasoningModelId"] as? String }, ["grok-4.5", "grok-4.6", "", "gpt-6-luna", ""],
                       "a crossed swap must clear Reasoning, change Main, apply the new Reasoning model, and then support Off")
        XCTAssertEqual(reasoningSelections.map { $0["sessionId"] as? String }, Array(repeating: "distill-session-1", count: 5))
        let crossSwapMainIndex = try XCTUnwrap(requests.firstIndex { $0["method"] as? String == "session/set_model" && $0["modelId"] as? String == "grok-4.6" })
        let crossSwapReasoningIndex = try XCTUnwrap(requests.firstIndex { $0["method"] as? String == "x.ai/session/reasoning_model/set" && $0["reasoningModelId"] as? String == "gpt-6-luna" })
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
