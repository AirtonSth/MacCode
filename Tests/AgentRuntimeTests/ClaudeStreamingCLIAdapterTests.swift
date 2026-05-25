import XCTest
import CoreModel
@testable import AgentRuntime

final class ClaudeStreamingCLIAdapterTests: XCTestCase {
    func test_adapterSendsMultipleTurnsThroughOneStreamingProcess() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        let counter = tmp.appendingPathComponent("turn-count.txt")
        try """
        #!/usr/bin/env python3
        import json, pathlib, sys
        counter = pathlib.Path(sys.argv[sys.argv.index("--counter-path") + 1])
        session = "claude-stream-session-1"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        turn = 0
        for line in sys.stdin:
            if not line.strip():
                continue
            turn += 1
            counter.write_text(str(turn))
            prompt = json.loads(line)["message"]["content"][0]["text"]
            answer = "STREAM_REPLY_" + str(turn)
            print(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"text","text":prompt}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":answer}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":answer,"session_id":session}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        let first = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "first",
            extraArgs: ["--counter-path", counter.path]
        )) { event in
            Task { await first.record(event) }
        }
        try await waitForFinish(in: first, expected: "STREAM_REPLY_1")

        let second = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "second",
            providerThreadId: "claude-stream-session-1",
            extraArgs: ["--counter-path", counter.path]
        )) { event in
            Task { await second.record(event) }
        }
        try await waitForFinish(in: second, expected: "STREAM_REPLY_2")

        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8), "2",
                       "Claude streaming adapter must keep one process alive and feed the second turn over stdin")
        XCTAssertEqual(adapter.listSessions().first?.providerThreadId, "claude-stream-session-1")
        XCTAssertEqual(try adapter.readThread(threadId: threadId).compactMap(Self.completedTurnId).count, 2,
                       "readThread must expose both completed turns from the durable streaming session")
        try adapter.stopSession(threadId: threadId)
    }

    func test_recoverableRateLimitTelemetryDoesNotFailSuccessfulStreamingTurn() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-rate-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys
        print(json.dumps({"type":"system","subtype":"init","session_id":"rate-limit-session"}), flush=True)
        for line in sys.stdin:
            if not line.strip():
                continue
            print(json.dumps({"type":"rate_limit_event","limit_type":"requests","reset_at":"2026-05-24T22:00:00Z"}), flush=True)
            print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":"1 2 3 4 5 6 7 8 9 10","session_id":"rate-limit-session"}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "count to 10"
        )) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "1 2 3 4 5 6 7 8 9 10")

        let events = await sink.snapshot()
        XCTAssertTrue(events.contains {
            if case .event(.itemStarted(let item)) = $0 {
                return item.type == .tool && item.summary == "Claude rate limit" && item.body.contains("requests")
            }
            return false
        }, "Claude rate-limit telemetry must stay visible without becoming an agent error")
        XCTAssertFalse(events.contains {
            if case .event(.error(let message, _)) = $0 {
                return message.contains("requests")
            }
            return false
        }, "Claude rate-limit telemetry must not publish agent.run.error when the turn succeeds")
        XCTAssertFalse(events.contains {
            if case .finished(.failed, _, _) = $0 { return true }
            return false
        }, "a successful Claude result must not be marked failed only because recoverable rate-limit telemetry arrived first")
        try adapter.stopSession(threadId: threadId)
    }

    func test_rollbackThreadPrunesStreamingReadableHistoryAndSessionSnapshot() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys
        session = "claude-stream-session-rollback"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        turn = 0
        for line in sys.stdin:
            if not line.strip():
                continue
            turn += 1
            answer = "ROLLBACK_REPLY_" + str(turn)
            print(json.dumps({"type":"assistant","message":{"id":"rollback-turn-" + str(turn),"content":[{"type":"text","text":answer}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":answer,"session_id":session}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        for index in 1...2 {
            let sink = EventSink()
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: threadId,
                provider: .claude,
                model: "claude-haiku-4-5-20251001",
                cwd: tmp.path,
                prompt: "turn \(index)",
                providerThreadId: "claude-stream-session-rollback"
            )) { event in
                Task { await sink.record(event) }
            }
            try await waitForFinish(in: sink, expected: "ROLLBACK_REPLY_\(index)")
        }

        let completedBefore = try adapter.readThread(threadId: threadId).compactMap(Self.completedTurnId)
        XCTAssertEqual(completedBefore.count, 2)
        let restoredTurnId = try XCTUnwrap(completedBefore.first)

        let rollbackSink = EventSink()
        try adapter.streamEvents(threadId: threadId) { event in
            Task { await rollbackSink.record(event) }
        }
        try adapter.rollbackThread(threadId: threadId, toTurnId: restoredTurnId)

        let readable = try adapter.readThread(threadId: threadId)
        XCTAssertEqual(readable.compactMap(Self.completedTurnId), [restoredTurnId],
                       "Claude streaming rollback must prune abandoned later turns from readable history")
        XCTAssertFalse(readable.contains {
            if case .itemDelta(_, let body, _, _) = $0 { return body?.contains("ROLLBACK_REPLY_2") == true }
            return false
        }, "Claude checkpoint/revert must not leave newer abandoned assistant text in readThread")
        let payload = try await waitForSessionSnapshot(in: rollbackSink, reason: "thread_rolled_back")
        XCTAssertEqual(payload["lastCompletedTurnId"] as? String, restoredTurnId,
                       "Claude rollback snapshots must report the restored last turn, not the abandoned newer turn")
        XCTAssertEqual(payload["turnCount"] as? Int, 1,
                       "Claude rollback snapshots must prune internal completed-turn count so recovery cannot resume from an abandoned turn")

        try adapter.stopSession(threadId: threadId)
    }

    func test_recoverSessionStartsResumedStreamingProcessForNextTurn() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        let argv = tmp.appendingPathComponent("argv.txt")
        let counter = tmp.appendingPathComponent("turn-count.txt")
        try """
        #!/usr/bin/env python3
        import json, pathlib, sys
        pathlib.Path(sys.argv[sys.argv.index("--argv-path") + 1]).write_text("\\n".join(sys.argv[1:]))
        counter = pathlib.Path(sys.argv[sys.argv.index("--counter-path") + 1])
        session = "claude-stream-session-recovered"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        turn = 0
        for line in sys.stdin:
            if not line.strip():
                continue
            turn += 1
            counter.write_text(str(turn))
            prompt = json.loads(line)["message"]["content"][0]["text"]
            answer = "RECOVERED_REPLY_" + str(turn)
            print(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"text","text":prompt}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":answer}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":answer,"session_id":session}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        let providerThreadId = "claude-stream-session-recovered"
        try adapter.recoverSession(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "",
            providerThreadId: providerThreadId,
            extraArgs: ["--argv-path", argv.path, "--counter-path", counter.path]
        )) { _ in }

        XCTAssertTrue(adapter.hasSession(threadId: threadId),
                      "restart recovery must create the resumed streaming process before the next turn")
        XCTAssertEqual(adapter.listSessions().first?.providerThreadId, providerThreadId)

        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "after restart"
        )) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "RECOVERED_REPLY_1")

        let recoveredArgs = try String(contentsOf: argv, encoding: .utf8)
        XCTAssertTrue(recoveredArgs.contains("--resume\n\(providerThreadId)"),
                      "recovered Claude streaming sessions must resume the provider session instead of starting fresh")
        XCTAssertFalse(recoveredArgs.contains("--session-id"),
                       "recovery must not request a new Claude session id")
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8), "1")
        try adapter.stopSession(threadId: threadId)
    }

    func test_recoverSessionSeedsReadThreadFromClaudeTranscriptAfterRestart() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-transcript-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json
        import time
        print(json.dumps({"type":"system","subtype":"init","session_id":"claude-transcript-session-1"}), flush=True)
        while True:
            time.sleep(0.1)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let project = home.appendingPathComponent(".claude/projects/-tmp-rc2", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let providerThreadId = "claude-transcript-session-1"
        try """
        {"type":"queue-operation","operation":"enqueue","timestamp":"2026-05-23T20:09:07.715Z","sessionId":"\(providerThreadId)"}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"prompt before restart"}]},"uuid":"user-1","timestamp":"2026-05-23T20:09:09.755Z","sessionId":"\(providerThreadId)"}
        {"message":{"model":"claude-haiku-4-5-20251001","id":"msg-before-restart","type":"message","role":"assistant","content":[{"type":"text","text":"TRANSCRIPT_BEFORE_RESTART"}]},"type":"assistant","uuid":"assistant-1","timestamp":"2026-05-23T20:09:12.063Z","sessionId":"\(providerThreadId)"}
        """.write(to: project.appendingPathComponent(providerThreadId + ".jsonl"), atomically: true, encoding: .utf8)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        try adapter.recoverSession(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "",
            providerThreadId: providerThreadId,
            environment: ["HOME": home.path]
        )) { _ in }

        let readable = try adapter.readThread(threadId: threadId)
        XCTAssertTrue(readable.contains {
            if case .itemDelta(_, let body, _, _) = $0 { return body == "TRANSCRIPT_BEFORE_RESTART" }
            return false
        }, "readThread after app restart must recover visible Claude history from the provider transcript, not only live in-memory events")
        XCTAssertTrue(readable.contains {
            if case .turnCompleted(let turnId, let final) = $0 {
                return turnId == "msg-before-restart" && final == "TRANSCRIPT_BEFORE_RESTART"
            }
            return false
        }, "Claude transcript recovery must produce completed turns so reconnecting clients can rebuild timeline state")

        try adapter.stopSession(threadId: threadId)
    }

    func test_streamingAdapterEmitsClaudeResumeStateSnapshots() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-resume-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys
        session = "claude-stream-session-snapshot"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        for line in sys.stdin:
            if not line.strip():
                continue
            prompt = json.loads(line)["message"]["content"][0]["text"]
            print(json.dumps({"type":"message_start","message":{"id":"assistant-uuid-1"}}), flush=True)
            print(json.dumps({"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"echo hi"}}}), flush=True)
            print(json.dumps({"type":"content_block_stop","index":0}), flush=True)
            print(json.dumps({"type":"assistant","message":{"uuid":"assistant-uuid-2","content":[{"type":"text","text":"SNAPSHOT_" + prompt}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":"SNAPSHOT_" + prompt,"session_id":session}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        let request = AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "resume-state"
        )
        _ = try await adapter.sendTurn(request) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "SNAPSHOT_\(request.providerPrompt)")

        let payload = try await waitForSessionSnapshot(in: sink, reason: "turn_completed")
        XCTAssertEqual(payload["providerThreadId"] as? String, "claude-stream-session-snapshot")
        XCTAssertEqual(payload["resumeSessionAt"] as? String, "assistant-uuid-2")
        XCTAssertEqual(payload["lastCompletedTurnId"] as? String, "assistant-uuid-1")
        XCTAssertEqual(payload["turnCount"] as? Int, 1)
        XCTAssertEqual(payload["inFlightToolIds"] as? [String], [],
                       "completed Claude turns must clear in-flight tool state before restart recovery snapshots are persisted")
        try adapter.stopSession(threadId: threadId)
    }

    func test_modelSwitchRestartsStreamingProcessWithResumeCursor() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-model-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        let argv = tmp.appendingPathComponent("argv.txt")
        let processCount = tmp.appendingPathComponent("process-count.txt")
        try """
        #!/usr/bin/env python3
        import json, pathlib, sys
        argv = pathlib.Path(sys.argv[sys.argv.index("--argv-path") + 1])
        count_path = pathlib.Path(sys.argv[sys.argv.index("--process-count-path") + 1])
        count = int(count_path.read_text() or "0") if count_path.exists() else 0
        count += 1
        count_path.write_text(str(count))
        argv.open("a").write("PROCESS_%d\\n%s\\n" % (count, "\\n".join(sys.argv[1:])))
        model = sys.argv[sys.argv.index("--model") + 1]
        session = "claude-stream-session-switch"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        turn = 0
        for line in sys.stdin:
            if not line.strip():
                continue
            turn += 1
            prompt = json.loads(line)["message"]["content"][0]["text"]
            answer = "MODEL_" + model + "_TURN_" + str(turn)
            print(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"text","text":prompt}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":answer}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":answer,"session_id":session}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        let first = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "first",
            extraArgs: ["--argv-path", argv.path, "--process-count-path", processCount.path]
        )) { event in
            Task { await first.record(event) }
        }
        try await waitForFinish(in: first, expected: "MODEL_claude-haiku-4-5-20251001_TURN_1")

        let second = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-opus-4-7",
            cwd: tmp.path,
            prompt: "second",
            extraArgs: ["--argv-path", argv.path, "--process-count-path", processCount.path]
        )) { event in
            Task { await second.record(event) }
        }
        try await waitForFinish(in: second, expected: "MODEL_claude-opus-4-7_TURN_1")

        let invocations = try String(contentsOf: argv, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: processCount, encoding: .utf8), "2",
                       "changing Claude model between turns should restart the stream process instead of mixing models inside one CLI process")
        XCTAssertTrue(invocations.contains("--resume\nclaude-stream-session-switch"),
                      "model switching must keep the Claude conversation by resuming the existing provider session")
        XCTAssertTrue(invocations.contains("--model\nclaude-opus-4-7"),
                      "the restarted Claude stream must use the newly selected model")
        XCTAssertEqual(adapter.listSessions().first?.providerThreadId, "claude-stream-session-switch")
        try adapter.stopSession(threadId: threadId)
    }

    func test_runtimeModeSwitchRestartsStreamingProcessWithResumeCursor() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-runtime-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        let argv = tmp.appendingPathComponent("argv.txt")
        let processCount = tmp.appendingPathComponent("process-count.txt")
        try """
        #!/usr/bin/env python3
        import json, pathlib, sys
        argv = pathlib.Path(sys.argv[sys.argv.index("--argv-path") + 1])
        count_path = pathlib.Path(sys.argv[sys.argv.index("--process-count-path") + 1])
        count = int(count_path.read_text() or "0") if count_path.exists() else 0
        count += 1
        count_path.write_text(str(count))
        argv.open("a").write("PROCESS_%d\\n%s\\n" % (count, "\\n".join(sys.argv[1:])))
        mode = sys.argv[sys.argv.index("--permission-mode") + 1]
        session = "claude-stream-session-runtime-switch"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        for line in sys.stdin:
            if not line.strip():
                continue
            prompt = json.loads(line)["message"]["content"][0]["text"]
            answer = "MODE_" + mode
            print(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"text","text":prompt}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":answer}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":answer,"session_id":session}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        let first = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "first",
            permissionMode: .supervised,
            interactionMode: .default,
            extraArgs: ["--argv-path", argv.path, "--process-count-path", processCount.path]
        )) { event in
            Task { await first.record(event) }
        }
        try await waitForFinish(in: first, expected: "MODE_default")

        let second = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "second",
            permissionMode: .supervised,
            interactionMode: .plan,
            extraArgs: ["--argv-path", argv.path, "--process-count-path", processCount.path]
        )) { event in
            Task { await second.record(event) }
        }
        try await waitForFinish(in: second, expected: "MODE_plan")

        let invocations = try String(contentsOf: argv, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: processCount, encoding: .utf8), "2",
                       "changing Claude interaction or permission mode between turns must restart the CLI stream so new --permission-mode flags apply")
        XCTAssertTrue(invocations.contains("--resume\nclaude-stream-session-runtime-switch"),
                      "runtime mode switching must keep the Claude conversation by resuming the existing provider session")
        XCTAssertTrue(invocations.contains("--permission-mode\nplan"),
                      "the restarted Claude stream must use the newly selected Plan Mode permission flag")
        XCTAssertEqual(adapter.listSessions().first?.providerThreadId, "claude-stream-session-runtime-switch")
        try adapter.stopSession(threadId: threadId)
    }

    func test_streamingAdapterAnswersClaudeUserInputOverStdin() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-user-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys
        session = "claude-stream-session-input"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        first = sys.stdin.readline()
        if first.strip():
            print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","id":"ask-1","name":"AskUserQuestion","input":{"question":"Pick a color","options":["blue","green"]}}]},"session_id":session}), flush=True)
        answer_line = sys.stdin.readline()
        answer = json.loads(answer_line)["message"]["content"][0]["text"]
        final = "ANSWERED_" + answer
        print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":final}]},"session_id":session}), flush=True)
        print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":final,"session_id":session}), flush=True)
        for _ in sys.stdin:
            pass
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "ask me"
        )) { event in
            Task { await sink.record(event) }
        }

        try await waitForUserInput(in: sink, requestId: "ask-1")
        try adapter.respondToUserInput(threadId: threadId, requestId: "ask-1", text: "blue")
        try await waitForFinish(in: sink, expected: "ANSWERED_blue")

        let readable = try adapter.readThread(threadId: threadId)
        XCTAssertTrue(readable.contains {
            if case .userInputResolved(let requestId, let answer) = $0 {
                return requestId == "ask-1" && answer == "blue"
            }
            return false
        }, "Claude user input answers must be preserved in readable history so reconnecting clients do not lose the resolved prompt")
        try adapter.stopSession(threadId: threadId)
    }

    func test_streamingAdapterAnswersClaudeSdkPermissionRequestOverStdin() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-permission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        let responsePath = tmp.appendingPathComponent("permission-response.json")
        try """
        #!/usr/bin/env python3
        import json, pathlib, sys
        response_path = pathlib.Path(sys.argv[sys.argv.index("--response-path") + 1])
        session = "claude-stream-session-permission"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        first = sys.stdin.readline()
        if first.strip():
            print(json.dumps({"type":"message_start","message":{"id":"turn-permission"}}), flush=True)
            print(json.dumps({"type":"canUseTool/request","request_id":"perm-1","tool_name":"Bash","input":{"command":"swift test"}}), flush=True)
        response_line = sys.stdin.readline()
        response_path.write_text(response_line)
        decision = json.loads(response_line)["decision"]
        print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"PERMISSION_" + decision}]},"session_id":session}), flush=True)
        print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":"PERMISSION_" + decision,"session_id":session}), flush=True)
        for _ in sys.stdin:
            pass
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "needs permission",
            extraArgs: ["--response-path", responsePath.path]
        )) { event in
            Task { await sink.record(event) }
        }

        try await waitForRequest(in: sink, requestId: "perm-1")
        try adapter.respondToRequest(threadId: threadId, requestId: "perm-1", response: .approveForSession)
        try await waitForRequestResolution(in: sink, requestId: "perm-1", state: .approved)
        try await waitForFinish(in: sink, expected: "PERMISSION_approveForSession")

        let response = try String(contentsOf: responsePath, encoding: .utf8)
        XCTAssertTrue(response.contains(#""type": "permission_response""#) || response.contains(#""type":"permission_response""#))
        XCTAssertTrue(response.contains(#""request_id": "perm-1""#) || response.contains(#""request_id":"perm-1""#))
        XCTAssertTrue(response.contains("approveForSession"),
                      "Claude SDK-shaped permission approvals must be written back to the live provider stream")
        try adapter.stopSession(threadId: threadId)
    }

    func test_stopSessionResolvesPendingClaudeUserInputAsCancelled() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-user-input-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys, time
        session = "claude-stream-session-input-stop"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        first = sys.stdin.readline()
        if first.strip():
            print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","id":"ask-stop","name":"AskUserQuestion","input":{"question":"Continue?","options":["yes","no"]}}]},"session_id":session}), flush=True)
        while True:
            time.sleep(0.1)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "ask then stop"
        )) { event in
            Task { await sink.record(event) }
        }

        try await waitForUserInput(in: sink, requestId: "ask-stop")
        try adapter.stopSession(threadId: threadId)
        try await waitForUserInputResolution(in: sink, requestId: "ask-stop")

        let events = await sink.snapshot()
        XCTAssertTrue(events.contains {
            if case .event(.userInputResolved(let requestId, let answer)) = $0 {
                return requestId == "ask-stop" && answer == nil
            }
            return false
        }, "stopping Claude while it is waiting for user input must clear the pending callback instead of leaving a dead question")
    }

    func test_stopSessionResolvesPendingClaudePermissionAsCancelled() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-permission-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys, time
        session = "claude-stream-session-permission-stop"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        first = sys.stdin.readline()
        if first.strip():
            print(json.dumps({"type":"message_start","message":{"id":"turn-stop"}}), flush=True)
            print(json.dumps({"type":"canUseTool/request","request_id":"perm-stop","tool_name":"Bash","input":{"command":"sleep 10"}}), flush=True)
        while True:
            time.sleep(0.1)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "ask then stop"
        )) { event in
            Task { await sink.record(event) }
        }

        try await waitForRequest(in: sink, requestId: "perm-stop")
        try adapter.stopSession(threadId: threadId)
        try await waitForRequestResolution(in: sink, requestId: "perm-stop", state: .cancelled)
    }

    func test_streamingAdapterKeepsReadableThreadHistoryBoundedForLongSessions() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys
        session = "claude-stream-session-retention"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        turn = 0
        for line in sys.stdin:
            if not line.strip():
                continue
            turn += 1
            prompt = json.loads(line)["message"]["content"][0]["text"]
            answer = "RETENTION_REPLY_" + str(turn)
            print(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"text","text":prompt}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":answer}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":answer,"session_id":session}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path, maxReadableEvents: 5)
        let threadId = AgentThreadID()

        for (index, prompt) in ["one", "two", "three", "four"].enumerated() {
            let sink = EventSink()
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: threadId,
                provider: .claude,
                model: "claude-haiku-4-5-20251001",
                cwd: tmp.path,
                prompt: prompt,
                providerThreadId: "claude-stream-session-retention"
            )) { event in
                Task { await sink.record(event) }
            }
            try await waitForFinish(in: sink, expected: "RETENTION_REPLY_\(index + 1)")
        }

        let readable = try adapter.readThread(threadId: threadId)
        XCTAssertLessThanOrEqual(readable.count, 5,
                                 "Claude streaming readable snapshots must be bounded so long sessions do not retain every stream-json event in memory")
        XCTAssertTrue(readable.contains {
            if case .itemDelta(_, let body, _, _) = $0 { return body?.contains("RETENTION_REPLY_4") == true }
            return false
        }, "retention must preserve the newest completed streaming turn output")
        XCTAssertFalse(readable.contains {
            if case .itemDelta(_, let body, _, _) = $0 { return body?.contains("RETENTION_REPLY_1") == true }
            return false
        }, "retention should prune oldest Claude streaming output once the readable window is full")

        try adapter.stopSession(threadId: threadId)
    }

    func test_agentSDKBridgeAdapterUsesOneBridgeAndNativeRuntimeSwitchControls() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const log = process.argv[2];
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        let turn = 0;
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        function record(obj) { fs.appendFileSync(log, JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          record(cmd);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-session-1', model: cmd.model, permissionMode: cmd.permission_mode });
          } else if (cmd.type === 'rc_set_model') {
            write({ type: 'system', subtype: 'rc_model_set', session_id: 'sdk-session-1', model: cmd.model });
          } else if (cmd.type === 'rc_set_permission') {
            write({ type: 'system', subtype: 'rc_permission_set', session_id: 'sdk-session-1', permissionMode: cmd.permission_mode });
          } else if (cmd.type === 'rc_turn') {
            turn += 1;
            const answer = 'SDK_REPLY_' + turn;
            write({ type: 'assistant', message: { id: 'sdk-turn-' + turn, content: [{ type: 'text', text: answer }] }, session_id: 'sdk-session-1' });
            write({ type: 'result', subtype: 'success', is_error: false, result: answer, session_id: 'sdk-session-1' });
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let first = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "first",
            attachments: [AgentAttachment(path: tmp.appendingPathComponent("note.txt").path, displayName: "note.txt", kind: .file, mimeType: "text/plain")],
            extraArgs: [commandLog.path]
        )) { event in
            Task { await first.record(event) }
        }
        try await waitForFinish(in: first, expected: "SDK_REPLY_1")

        let second = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-sonnet-4-6",
            cwd: tmp.path,
            prompt: "second",
            providerThreadId: "sdk-session-1",
            permissionMode: .fullAccess,
            interactionMode: .plan,
            extraArgs: [commandLog.path]
        )) { event in
            Task { await second.record(event) }
        }
        try await waitForFinish(in: second, expected: "SDK_REPLY_2")

        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        XCTAssertEqual(commands.components(separatedBy: "\"type\":\"rc_configure\"").count - 1, 1,
                       "SDK bridge adapter should keep one SDK query session instead of spawning one process per turn")
        XCTAssertTrue(commands.contains(#""type":"rc_set_model""#),
                      "Claude SDK bridge must use native setModel control when the model changes mid-session")
        XCTAssertTrue(commands.contains(#""type":"rc_set_permission""#),
                      "Claude SDK bridge must use native setPermissionMode control when interaction or permission mode changes")
        XCTAssertTrue(commands.contains(#""attachments":[{"#) && commands.contains(#""path":"#) && commands.contains("note.txt"),
                      "Claude SDK bridge must send structured attachment metadata to the SDK bridge instead of flattening attachments into the prompt")
        XCTAssertEqual(adapter.listSessions().first?.providerThreadId, "sdk-session-1")
        XCTAssertEqual(try adapter.readThread(threadId: threadId).compactMap(Self.completedTurnId).count, 2)
        try adapter.stopSession(threadId: threadId)
    }

    func test_agentSDKBridgeRecoverableRateLimitTelemetryDoesNotFailSuccessfulTurn() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-rate-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        try """
        import readline from 'node:readline';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-rate-limit-session' });
          } else if (cmd.type === 'rc_turn') {
            write({ type: 'rate_limit_event', limit_type: 'requests', reset_at: '2026-05-24T22:00:00Z' });
            write({ type: 'result', subtype: 'success', is_error: false, result: 'SDK_RATE_LIMIT_OK', session_id: 'sdk-rate-limit-session' });
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "rate limit"
        )) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "SDK_RATE_LIMIT_OK")

        let events = await sink.snapshot()
        XCTAssertTrue(events.contains {
            if case .event(.itemStarted(let item)) = $0 {
                return item.type == .tool && item.summary == "Claude rate limit" && item.body.contains("requests")
            }
            return false
        }, "Claude SDK rate-limit telemetry must stay visible without becoming an agent error")
        XCTAssertFalse(events.contains {
            if case .event(.error(let message, _)) = $0 {
                return message.contains("requests")
            }
            return false
        }, "Claude SDK rate-limit telemetry must not publish agent.run.error when the turn succeeds")
        XCTAssertFalse(events.contains {
            if case .finished(.failed, _, _) = $0 { return true }
            return false
        }, "a successful Claude SDK result must not be marked failed only because recoverable rate-limit telemetry arrived first")
        try adapter.stopSession(threadId: threadId)
    }

    func test_agentSDKBridgeAdapterRollbackRestartsWithResumeSessionAt() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const log = process.argv[2];
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        let turn = 0;
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        function record(obj) { fs.appendFileSync(log, JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          record(cmd);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: cmd.provider_thread_id || 'sdk-rollback-session' });
          } else if (cmd.type === 'rc_turn') {
            turn += 1;
            const turnId = 'sdk-turn-' + turn;
            const resumeAt = 'assistant-uuid-' + turn;
            const answer = 'SDK_ROLLBACK_' + turn;
            write({ type: 'message_start', message: { id: turnId }, session_id: 'sdk-rollback-session' });
            write({ type: 'claude.session.snapshot', providerThreadId: 'sdk-rollback-session', resume: 'sdk-rollback-session', resumeSessionAt: resumeAt, lastCompletedTurnId: turnId, turnCount: turn, model: 'claude-haiku-4-5-20251001' });
            write({ type: 'assistant', message: { id: turnId, content: [{ type: 'text', text: answer }] }, session_id: 'sdk-rollback-session' });
            write({ type: 'result', subtype: 'success', is_error: false, result: answer, session_id: 'sdk-rollback-session' });
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let first = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "first",
            extraArgs: [commandLog.path]
        )) { event in
            Task { await first.record(event) }
        }
        try await waitForFinish(in: first, expected: "SDK_ROLLBACK_1")

        let second = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "second",
            providerThreadId: "sdk-rollback-session",
            extraArgs: [commandLog.path]
        )) { event in
            Task { await second.record(event) }
        }
        try await waitForFinish(in: second, expected: "SDK_ROLLBACK_2")

        try adapter.rollbackThread(threadId: threadId, toTurnId: "sdk-turn-1")
        XCTAssertEqual(try adapter.readThread(threadId: threadId).compactMap(Self.completedTurnId), ["sdk-turn-1"],
                       "SDK rollback should prune local readable history to the restored provider turn")

        let third = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "after rollback",
            providerThreadId: "sdk-rollback-session",
            extraArgs: [commandLog.path]
        )) { event in
            Task { await third.record(event) }
        }
        try await waitForFinish(in: third, expected: "SDK_ROLLBACK_1")

        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        XCTAssertEqual(commands.components(separatedBy: "\"type\":\"rc_configure\"").count - 1, 2,
                       "SDK rollback should restart the bridge so resumeSessionAt can be applied before the next turn")
        XCTAssertTrue(commands.contains(#""provider_thread_id":"sdk-rollback-session""#),
                      "SDK rollback follow-up must keep the provider session cursor")
        XCTAssertTrue(commands.contains(#""resume_session_at":"assistant-uuid-1""#),
                      "SDK rollback follow-up must configure the SDK resumeSessionAt cursor from the restored turn snapshot")
        try adapter.stopSession(threadId: threadId)
    }

    func test_agentSDKBridgeAdapterBridgesPermissionResponses() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-permission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const log = process.argv[2];
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        function record(obj) { fs.appendFileSync(log, JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          record(cmd);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-perm-session' });
          } else if (cmd.type === 'rc_turn') {
            write({ type: 'permission_request', request_id: 'sdk-perm-1', tool_name: 'Bash', tool_input: { command: 'swift test' }, session_id: 'sdk-perm-session' });
          } else if (cmd.type === 'permission_response') {
            write({ type: 'permission_decision', request_id: cmd.request_id, decision: cmd.decision, session_id: 'sdk-perm-session' });
            write({ type: 'assistant', message: { id: 'sdk-perm-turn', content: [{ type: 'text', text: 'SDK_PERMISSION_OK' }] }, session_id: 'sdk-perm-session' });
            write({ type: 'result', subtype: 'success', is_error: false, result: 'SDK_PERMISSION_OK', session_id: 'sdk-perm-session' });
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "needs permission",
            extraArgs: [commandLog.path]
        )) { event in
            Task { await sink.record(event) }
        }

        try await waitForRequest(in: sink, requestId: "sdk-perm-1")
        try adapter.respondToRequest(threadId: threadId, requestId: "sdk-perm-1", response: .approveForSession)
        try await waitForRequestResolution(in: sink, requestId: "sdk-perm-1", state: .approved)
        try await waitForFinish(in: sink, expected: "SDK_PERMISSION_OK")

        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        XCTAssertTrue(commands.contains(#""type":"permission_response""#),
                      "SDK bridge adapter must return approval decisions through the SDK permission response channel")
        XCTAssertTrue(commands.contains(#""decision":"approve_for_session""#),
                      "provider-native SDK approvals must preserve approve-for-session semantics")
        try adapter.stopSession(threadId: threadId)
    }

    func test_agentSDKBridgeAdapterAnswersNativeUserInputCallback() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-user-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const log = process.argv[2];
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        function record(obj) { fs.appendFileSync(log, JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          record(cmd);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-input-session' });
          } else if (cmd.type === 'rc_turn') {
            write({ type: 'user_input_request', request_id: 'sdk-input-1', prompt: 'Pick color', options: ['blue', 'green'], session_id: 'sdk-input-session' });
          } else if (cmd.type === 'user_input_response') {
            write({ type: 'user_input_response', request_id: cmd.request_id, text: cmd.text, session_id: 'sdk-input-session' });
            write({ type: 'assistant', message: { id: 'sdk-input-turn', content: [{ type: 'text', text: 'SDK_INPUT_' + cmd.text }] }, session_id: 'sdk-input-session' });
            write({ type: 'result', subtype: 'success', is_error: false, result: 'SDK_INPUT_' + cmd.text, session_id: 'sdk-input-session' });
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "needs native input",
            extraArgs: [commandLog.path]
        )) { event in
            Task { await sink.record(event) }
        }

        try await waitForUserInput(in: sink, requestId: "sdk-input-1")
        try adapter.respondToUserInput(threadId: threadId, requestId: "sdk-input-1", text: "blue")
        try await waitForUserInputResolution(in: sink, requestId: "sdk-input-1")
        try await waitForFinish(in: sink, expected: "SDK_INPUT_blue")

        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        XCTAssertTrue(commands.contains(#""type":"user_input_response""#),
                      "SDK bridge adapter must answer native SDK elicitation through the callback response channel")
        XCTAssertTrue(commands.contains(#""text":"blue""#),
                      "SDK native user-input callbacks must preserve the answer text")
        XCTAssertEqual(commands.components(separatedBy: "\"type\":\"rc_turn\"").count - 1, 1,
                       "SDK native user-input callbacks should not start a second provider turn")
        try adapter.stopSession(threadId: threadId)
    }

    func test_agentSDKBridgeAdapterStopSettlesPendingCallbacks() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-stop-callback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        try """
        import readline from 'node:readline';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-stop-session' });
          } else if (cmd.type === 'rc_turn') {
            write({ type: 'permission_request', request_id: 'sdk-stop-perm', tool_name: 'Bash', tool_input: { command: 'sleep 10' }, session_id: 'sdk-stop-session' });
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "ask then stop"
        )) { event in
            Task { await sink.record(event) }
        }

        try await waitForRequest(in: sink, requestId: "sdk-stop-perm")
        try adapter.stopSession(threadId: threadId)
        try await waitForRequestResolution(in: sink, requestId: "sdk-stop-perm", state: .cancelled)
    }

    func test_agentSDKBridgeAdapterProvisionsSDKRuntimeBeforeLaunchingDefaultBridge() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-provision-\(UUID().uuidString)", isDirectory: true)
        let bin = tmp.appendingPathComponent("bin", isDirectory: true)
        let cache = tmp.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("ClaudeAgentSDKBridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        let npmLog = tmp.appendingPathComponent("npm.jsonl")
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf '{"argv":%s,"cwd":"%s"}\\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")" "$PWD" >> "\(npmLog.path)"
        mkdir -p node_modules/@anthropic-ai/claude-agent-sdk
        printf '{"name":"@anthropic-ai/claude-agent-sdk"}\\n' > node_modules/@anthropic-ai/claude-agent-sdk/package.json
        """.write(to: bin.appendingPathComponent("npm"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("npm").path)
        try """
        import fs from 'node:fs';
        import readline from 'node:readline';
        // @anthropic-ai/claude-agent-sdk marks this as the default SDK bridge source.
        const log = process.argv[2];
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        function record(obj) { fs.appendFileSync(log, JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          record({ ...cmd, launched_from: process.argv[1] });
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-provision-session' });
          } else if (cmd.type === 'rc_turn') {
            write({ type: 'assistant', message: { id: 'sdk-provision-turn', content: [{ type: 'text', text: 'SDK_PROVISION_OK' }] }, session_id: 'sdk-provision-session' });
            write({ type: 'result', subtype: 'success', is_error: false, result: 'SDK_PROVISION_OK', session_id: 'sdk-provision-session' });
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let oldPath = getenv("PATH").map { String(cString: $0) }
        let oldCache = getenv("RC_CLAUDE_AGENT_SDK_CACHE").map { String(cString: $0) }
        let oldPackage = getenv("RC_CLAUDE_AGENT_SDK_PACKAGE").map { String(cString: $0) }
        setenv("PATH", "\(bin.path):\(oldPath ?? "")", 1)
        setenv("RC_CLAUDE_AGENT_SDK_CACHE", cache.path, 1)
        setenv("RC_CLAUDE_AGENT_SDK_PACKAGE", "@anthropic-ai/claude-agent-sdk@9.9.9-test", 1)
        defer {
            if let oldPath { setenv("PATH", oldPath, 1) } else { unsetenv("PATH") }
            if let oldCache { setenv("RC_CLAUDE_AGENT_SDK_CACHE", oldCache, 1) } else { unsetenv("RC_CLAUDE_AGENT_SDK_CACHE") }
            if let oldPackage { setenv("RC_CLAUDE_AGENT_SDK_PACKAGE", oldPackage, 1) } else { unsetenv("RC_CLAUDE_AGENT_SDK_PACKAGE") }
        }

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "prove provision",
            extraArgs: [commandLog.path]
        )) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "SDK_PROVISION_OK")

        let npmCommands = try String(contentsOf: npmLog, encoding: .utf8)
        XCTAssertTrue(npmCommands.contains(#""install""#) && npmCommands.contains("@anthropic-ai/claude-agent-sdk@9.9.9-test"),
                      "default SDK bridge startup must install the SDK package when the app bundle does not contain node_modules")
        let cachedPackage = cache.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk/package.json")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: cachedPackage.path),
                      "SDK provisioning must leave the package in the runtime cache used by the launched bridge")
        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        XCTAssertTrue(commands.contains(cache.appendingPathComponent("ClaudeAgentSDKBridge.mjs").path),
                      "adapter must launch the cached bridge after provisioning dependencies")
        try adapter.stopSession(threadId: threadId)
    }

    private func waitForFinish(in sink: EventSink, expected: String) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let events = await sink.snapshot()
            if events.contains(where: {
                if case .finished(.completed, let final, _) = $0 { return final == expected }
                return false
            }) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(expected)")
    }

    private func waitForUserInput(in sink: EventSink, requestId: String) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let events = await sink.snapshot()
            if events.contains(where: {
                if case .event(.userInputRequested(let request)) = $0 { return request.id == requestId }
                return false
            }) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for user input \(requestId)")
    }

    private func waitForRequest(in sink: EventSink, requestId: String) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let events = await sink.snapshot()
            if events.contains(where: {
                if case .event(.requestOpened(let request)) = $0 { return request.id == requestId }
                return false
            }) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for request \(requestId)")
    }

    private func waitForRequestResolution(in sink: EventSink, requestId: String, state: AssistantRequestState) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let events = await sink.snapshot()
            if events.contains(where: {
                if case .event(.requestResolved(let resolvedId, let resolvedState)) = $0 {
                    return resolvedId == requestId && resolvedState == state
                }
                return false
            }) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for request resolution \(requestId)")
    }

    private func waitForUserInputResolution(in sink: EventSink, requestId: String) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let events = await sink.snapshot()
            if events.contains(where: {
                if case .event(.userInputResolved(let resolvedId, _)) = $0 { return resolvedId == requestId }
                return false
            }) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for user input resolution \(requestId)")
    }

    private func waitForSessionSnapshot(in sink: EventSink, reason: String) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            for event in await sink.snapshot() {
                if case .event(.providerRuntime(let runtime)) = event,
                   runtime.method == "claude.session.snapshot",
                   let data = runtime.payloadJSON.data(using: .utf8),
                   let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   payload["reason"] as? String == reason {
                    return payload
                }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for Claude session snapshot \(reason)")
        return [:]
    }

    private static func completedTurnId(_ event: AssistantEvent) -> String? {
        if case .turnCompleted(let turnId, _) = event { return turnId }
        return nil
    }
}

private actor EventSink {
    private var events: [AgentRunEvent] = []
    func record(_ event: AgentRunEvent) { events.append(event) }
    func snapshot() -> [AgentRunEvent] { events }
}
