import XCTest
import CoreModel
@testable import AgentRuntime

final class ClaudeStreamingCLIAdapterTests: ProviderProcessTestCase {
    func test_agentSDKBridgeInvalidatedAcceptancePermitBlocksTurnBeforeWireWrite() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        let acceptanceMarker = tmp.appendingPathComponent("prompt-accepted")
        try """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const commandLog = process.argv[2];
        const acceptanceMarker = process.argv[3];
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const command = JSON.parse(line);
          fs.appendFileSync(commandLog, JSON.stringify(command) + '\\n');
          if (command.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-acceptance-session' });
          } else if (command.type === 'rc_turn') {
            fs.writeFileSync(acceptanceMarker, command.prompt);
          } else if (command.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let permit = AgentRunAcceptancePermit()
        permit.invalidate()
        let events = LockedAgentRunEventSink()

        do {
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .claude,
                model: "claude-haiku-4-5-20251001",
                cwd: tmp.path,
                prompt: "must not cross the SDK bridge",
                providerBinary: "/usr/bin/true",
                extraArgs: [commandLog.path, acceptanceMarker.path],
                acceptancePermit: permit
            )) { event in
                events.record(event)
            }
            XCTFail("suppression must win before the Claude SDK rc_turn write")
        } catch is AgentRunAcceptanceError {}

        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        XCTAssertTrue(commands.contains(#""type":"rc_configure""#),
                      "the fake SDK bridge must complete its deterministic initialization handshake")
        XCTAssertFalse(commands.contains(#""type":"rc_turn""#),
                       "a revoked permit must block the SDK writeTurn closure itself")
        XCTAssertFalse(FileManager.default.fileExists(atPath: acceptanceMarker.path),
                       "the fake SDK bridge must never accept the prompt")
        XCTAssertTrue(events.snapshot().isEmpty,
                      "a rejected SDK turn must emit no running or terminal lifecycle")
        adapter.stopAll()
    }

    func test_invalidatedAcceptancePermitBlocksClaudePromptBeforeWireWrite() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let script = tmp.appendingPathComponent("fake-claude")
        let marker = tmp.appendingPathComponent("prompt-written")
        try """
        #!/usr/bin/env python3
        import json, pathlib, sys
        marker = pathlib.Path("\(marker.path)")
        print(json.dumps({"type":"system","subtype":"init","session_id":"acceptance-session"}), flush=True)
        for line in sys.stdin:
            if line.strip():
                marker.write_text(line)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let permit = AgentRunAcceptancePermit()
        permit.invalidate()
        let events = EventSink()

        do {
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .claude,
                model: "claude-haiku-4-5-20251001",
                cwd: tmp.path,
                prompt: "must not cross stdin",
                acceptancePermit: permit
            )) { event in
                Task { await events.record(event) }
            }
            XCTFail("suppression must win before the Claude stdin write")
        } catch is AgentRunAcceptanceError {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let recorded = await events.snapshot()
        XCTAssertFalse(recorded.contains {
            if case .status(.running) = $0 { return true }
            return false
        })
        adapter.stopAll()
    }

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
        let streamingReadTurns = try await adapter.readThread(threadId: threadId).compactMap(Self.completedTurnId)
        XCTAssertEqual(streamingReadTurns.count, 2,
                       "readThread must expose both completed turns from the durable streaming session")
        try adapter.stopSession(threadId: threadId)
    }

    /// WHY: the host instruction is installed at Claude process creation.  A
    /// persistent streaming process must not receive a later turn under the
    /// previous host policy; changing the typed host identity requires a
    /// resume/respawn with the new system prompt.
    func test_changedTrustedHostInstructionRespawnsStreamingSession() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-host-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let script = tmp.appendingPathComponent("fake-claude")
        let spawnLog = tmp.appendingPathComponent("spawn-args.log")
        try """
        #!/usr/bin/env python3
        import json, pathlib, sys
        log = pathlib.Path(sys.argv[sys.argv.index("--spawn-log") + 1])
        with log.open("a") as f:
            f.write("SPAWN " + " ".join(sys.argv[1:]) + "\\n")
        spawn = sum(1 for line in log.read_text().splitlines() if line.startswith("SPAWN "))
        session = "claude-host-switch-session"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        for line in sys.stdin:
            if not line.strip():
                continue
            answer = "HOST_SWITCH_REPLY_" + str(spawn)
            print(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"text","text":"prompt"}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"assistant","message":{"id":"host-switch-turn-" + str(spawn),"role":"assistant","content":[{"type":"text","text":answer}]},"session_id":session}), flush=True)
            print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":answer,"session_id":session}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        let first = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .claude, model: "claude-haiku-4-5-20251001",
            cwd: tmp.path, prompt: "first",
            trustedHostInstruction: AgentTrustedHostInstruction(text: "HOST_POLICY_A"),
            extraArgs: ["--spawn-log", spawnLog.path]
        )) { event in Task { await first.record(event) } }
        try await waitForFinish(in: first, expected: "HOST_SWITCH_REPLY_1")

        let second = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .claude, model: "claude-haiku-4-5-20251001",
            cwd: tmp.path, prompt: "second",
            trustedHostInstruction: AgentTrustedHostInstruction(text: "HOST_POLICY_B"),
            providerThreadId: "claude-host-switch-session",
            extraArgs: ["--spawn-log", spawnLog.path]
        )) { event in Task { await second.record(event) } }
        try await waitForFinish(in: second, expected: "HOST_SWITCH_REPLY_2")

        let launches = try String(contentsOf: spawnLog, encoding: .utf8)
        XCTAssertEqual(launches.components(separatedBy: "SPAWN ").count - 1, 2,
                       "changing typed host identity must respawn the streaming Claude process")
        XCTAssertTrue(launches.contains("HOST_POLICY_A"))
        XCTAssertTrue(launches.contains("HOST_POLICY_B"))
        try adapter.stopSession(threadId: threadId)
    }

    func test_streamingCLIAdapterFinalizesAssistantTextWhenProcessExitsWithoutResult() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-finalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys
        session = "stream-finalize-session"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        for line in sys.stdin:
            if not line.strip():
                continue
            print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"STREAM_ONLY_FINAL"}]},"session_id":session}), flush=True)
            sys.exit(0)
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

        try await waitForFinish(in: sink, expected: "STREAM_ONLY_FINAL")
        let events = await sink.snapshot()
        XCTAssertTrue(Self.assistantTexts(in: events).contains("STREAM_ONLY_FINAL"),
                      "Claude streaming adapter must finalize buffered assistant text on EOF so the user sees a response even when result is missing")
    }

    func test_streamingCLIUnexpectedProcessExitIsFailureNotCancellation() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-streaming-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, os, signal, sys
        print(json.dumps({"type":"system","subtype":"init","session_id":"stream-crash-session"}), flush=True)
        for line in sys.stdin:
            if line.strip():
                os.kill(os.getpid(), signal.SIGABRT)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: AgentThreadID(), provider: .claude,
            model: "claude-haiku-4-5-20251001", cwd: tmp.path, prompt: "crash"
        )) { event in Task { await sink.record(event) } }

        let deadline = Date().addingTimeInterval(3)
        var status: AgentRunStatus?
        while Date() < deadline && status == nil {
            status = await sink.snapshot().compactMap { event -> AgentRunStatus? in
                if case .finished(let value, _, _) = event { return value }
                return nil
            }.first
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(status, .failed,
                       "an unexpected Claude CLI exit is a provider failure; only an explicit interrupt may finish as cancelled")
        let errors = await sink.snapshot().compactMap { event -> String? in
            if case .error(let message) = event { return message }
            return nil
        }
        XCTAssertTrue(errors.contains { $0.localizedCaseInsensitiveContains("crashed with signal 6") },
                      "SIGABRT must leave an actionable crash diagnostic for Retry; errors=\(errors)")
    }

    func test_agentSDKHandleCancelWritesInterruptBeforeHardClose() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-cancel-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let log = tmp.appendingPathComponent("commands.jsonl")
        try """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const log = process.argv[2];
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          fs.appendFileSync(log, JSON.stringify(cmd) + '\\n');
          if (cmd.type === 'rc_configure') process.stdout.write(JSON.stringify({ type: 'system', subtype: 'init', session_id: 'cancel-order' }) + '\\n');
          if (cmd.type === 'rc_close') process.exit(0);
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path, interruptGracePeriod: 0.05)
        let threadId = AgentThreadID()
        let handle = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .claude,
            model: "claude-haiku-4-5-20251001", cwd: tmp.path, prompt: "wait",
            extraArgs: [log.path]
        )) { _ in }
        let readyDeadline = Date().addingTimeInterval(3)
        var preCancelCommands = ""
        while Date() < readyDeadline {
            preCancelCommands = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if preCancelCommands.contains(#""type":"rc_turn""#) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(preCancelCommands.contains(#""type":"rc_turn""#),
                      "the fake bridge must be reading commands before cancellation ordering is measured")
        handle.cancel()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && adapter.hasSession(threadId: threadId) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        var commands = ""
        let closeDeadline = Date().addingTimeInterval(3)
        while Date() < closeDeadline {
            commands = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if commands.contains(#""type":"rc_close""#) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let interrupt = try XCTUnwrap(commands.range(of: #""type":"rc_interrupt""#))
        let close = try XCTUnwrap(commands.range(of: #""type":"rc_close""#))
        XCTAssertLessThan(interrupt.lowerBound, close.lowerBound,
                          "cancel must ask the SDK query to interrupt before the grace timeout hard-closes its bridge")
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

        let completedBefore = try await adapter.readThread(threadId: threadId).compactMap(Self.completedTurnId)
        XCTAssertEqual(completedBefore.count, 2)
        let restoredTurnId = try XCTUnwrap(completedBefore.first)

        let rollbackSink = EventSink()
        try adapter.streamEvents(threadId: threadId) { event in
            Task { await rollbackSink.record(event) }
        }
        try await adapter.rollbackThread(threadId: threadId, toTurnId: restoredTurnId)

        let readable = try await adapter.readThread(threadId: threadId)
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
        try await adapter.recoverSession(AgentRunRequest(
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
        try await adapter.recoverSession(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "",
            providerThreadId: providerThreadId,
            environment: ["HOME": home.path]
        )) { _ in }

        let readable = try await adapter.readThread(threadId: threadId)
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

        let readable = try await adapter.readThread(threadId: threadId)
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
        payload = json.loads(response_line)
        assert payload.get("type") == "control_response", payload
        behavior = payload["response"]["response"]["behavior"]
        print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"PERMISSION_" + behavior}]},"session_id":session}), flush=True)
        print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":"PERMISSION_" + behavior,"session_id":session}), flush=True)
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
        try await adapter.respondToRequest(threadId: threadId, requestId: "perm-1", response: .approveForSession)
        try await waitForRequestResolution(in: sink, requestId: "perm-1", state: .approved)
        try await waitForFinish(in: sink, expected: "PERMISSION_allow")

        let response = try String(contentsOf: responsePath, encoding: .utf8)
        let responseObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(response.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String: Any]
        )
        XCTAssertEqual(responseObject["type"] as? String, "control_response",
                       "CLI stream-json approvals must use control_response, not invented permission_response")
        let envelope = try XCTUnwrap(responseObject["response"] as? [String: Any])
        XCTAssertEqual(envelope["subtype"] as? String, "success")
        XCTAssertEqual(envelope["request_id"] as? String, "perm-1")
        let permissionResult = try XCTUnwrap(envelope["response"] as? [String: Any])
        XCTAssertEqual(permissionResult["behavior"] as? String, "allow",
                       "approve/approveForSession map to PermissionResult behavior allow")
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

        let readable = try await adapter.readThread(threadId: threadId)
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
            providerBinary: "/usr/bin/true",
            extraArgs: [commandLog.path]
        )) { event in
            Task { await first.record(event) }
        }
        try await waitForFinish(in: first, expected: "SDK_REPLY_1")

        for mimeType in ["image/png", "image/jpeg", "image/gif", "image/webp"] {
            XCTAssertNoThrow(try ClaudeAgentSDKBridgeAdapter.validateAttachments([
                AgentAttachment(path: tmp.appendingPathComponent("supported-image").path, kind: .image, mimeType: mimeType)
            ]), "the Claude SDK contract explicitly accepts \(mimeType)")
        }
        for mimeType in ["image/heic", "image/bmp", "image/tiff", "image/avif"] {
            do {
                _ = try await adapter.sendTurn(AgentRunRequest(
                    threadId: threadId,
                    provider: .claude,
                    model: "claude-haiku-4-5-20251001",
                    cwd: tmp.path,
                    prompt: "must be rejected before reaching the warm session",
                    attachments: [AgentAttachment(path: tmp.appendingPathComponent("unsupported-image").path, kind: .image, mimeType: mimeType)],
                    providerThreadId: "sdk-session-1",
                    providerBinary: "/usr/bin/true",
                    extraArgs: [commandLog.path]
                )) { _ in }
                XCTFail("unsupported Claude image MIME \(mimeType) must fail before writing to the bridge")
            } catch let AgentProviderAdapterError.unsupported(message) {
                XCTAssertTrue(message.contains(mimeType))
            }
            XCTAssertTrue(adapter.hasSession(threadId: threadId),
                          "rejecting \(mimeType) must not destroy the existing warm Claude session")
            XCTAssertEqual(adapter.listSessions().first?.providerThreadId, "sdk-session-1")
        }

        let second = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-sonnet-4-6",
            cwd: tmp.path,
            prompt: "second",
            attachments: [AgentAttachment(path: tmp.appendingPathComponent("accepted.png").path, kind: .image, mimeType: "image/png")],
            providerThreadId: "sdk-session-1",
            permissionMode: .fullAccess,
            interactionMode: .plan,
            providerBinary: "/usr/bin/true",
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
        XCTAssertTrue(commands.contains(#""claude_executable_path":"/usr/bin/true""#),
                      "the SDK bridge must run the exact provider binary selected by the app instead of a second hidden Claude runtime")
        XCTAssertEqual(adapter.listSessions().first?.providerThreadId, "sdk-session-1")
        let sdkReadTurns = try await adapter.readThread(threadId: threadId).compactMap(Self.completedTurnId)
        XCTAssertEqual(sdkReadTurns.count, 2)
        try adapter.stopSession(threadId: threadId)
    }

    /// WHY: the SDK bridge's system prompt is fixed when the query session is
    /// created.  Consecutive turns with a changed typed host must create a
    /// resumed bridge session rather than silently retaining the old host.
    func test_agentSDKBridgeChangedTrustedHostInstructionRespawnsSession() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-host-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const log = process.argv[2];
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        let turn = 0;
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          fs.appendFileSync(log, JSON.stringify(cmd) + '\\n');
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-host-switch-session' });
          } else if (cmd.type === 'rc_turn') {
            turn += 1;
            const answer = 'SDK_HOST_SWITCH_REPLY_' + ((fs.readFileSync(log, 'utf8').match(/\"type\":\"rc_configure\"/g) || []).length);
            write({ type: 'assistant', message: { id: 'sdk-host-switch-turn-' + turn, role: 'assistant', content: [{ type: 'text', text: answer }] }, session_id: 'sdk-host-switch-session' });
            write({ type: 'result', subtype: 'success', is_error: false, result: answer, session_id: 'sdk-host-switch-session' });
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let first = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .claude, model: "claude-haiku-4-5-20251001",
            cwd: tmp.path, prompt: "first",
            trustedHostInstruction: AgentTrustedHostInstruction(text: "SDK_HOST_POLICY_A"),
            providerBinary: "/usr/bin/true", extraArgs: [commandLog.path]
        )) { event in Task { await first.record(event) } }
        try await waitForFinish(in: first, expected: "SDK_HOST_SWITCH_REPLY_1")

        let second = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId, provider: .claude, model: "claude-haiku-4-5-20251001",
            cwd: tmp.path, prompt: "second",
            trustedHostInstruction: AgentTrustedHostInstruction(text: "SDK_HOST_POLICY_B"),
            providerThreadId: "sdk-host-switch-session",
            providerBinary: "/usr/bin/true", extraArgs: [commandLog.path]
        )) { event in Task { await second.record(event) } }
        try await waitForFinish(in: second, expected: "SDK_HOST_SWITCH_REPLY_2")

        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        XCTAssertEqual(commands.components(separatedBy: "\"type\":\"rc_configure\"").count - 1, 2,
                       "changing typed host identity must respawn the SDK bridge query")
        XCTAssertTrue(commands.contains("SDK_HOST_POLICY_A"))
        XCTAssertTrue(commands.contains("SDK_HOST_POLICY_B"))
        try adapter.stopSession(threadId: threadId)
    }

    func test_agentSDKBridgeAdapterSendsDistillSystemPromptOnlyWhenTokenSaverHintSet() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-distill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        try """
        import fs from 'node:fs';
        import readline from 'node:readline';
        const log = process.argv[2];
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          if (cmd.type === 'rc_configure') {
            fs.appendFileSync(log, JSON.stringify(cmd) + '\\n');
            write({ type: 'system', subtype: 'init', session_id: 'distill-session' });
          } else if (cmd.type === 'rc_turn') {
            write({ type: 'result', subtype: 'success', is_error: false, result: 'OK', session_id: 'distill-session' });
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        func configureCommand(tokenSaverOn: Bool) async throws -> String {
            let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
            let log = tmp.appendingPathComponent("cfg-\(tokenSaverOn).jsonl")
            FileManager.default.createFile(atPath: log.path, contents: Data())
            let sink = EventSink()
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: AgentThreadID(),
                provider: .claude,
                model: "claude-haiku-4-5-20251001",
                cwd: tmp.path,
                prompt: "hi",
                environment: tokenSaverOn ? ["RC_TOKEN_SAVER_DISTILL_HINT": "1"] : [:],
                extraArgs: [log.path]
            )) { event in Task { await sink.record(event) } }
            try await waitForFinish(in: sink, expected: "OK")
            try? adapter.stopSession(threadId: adapter.listSessions().first!.threadId)
            return try String(contentsOf: log, encoding: .utf8)
        }

        let on = try await configureCommand(tokenSaverOn: true)
        XCTAssertTrue(on.contains("\"system_prompt\""),
                      "rc_configure must send a system prompt")
        XCTAssertTrue(on.contains("Background-await protocol"),
                      "the system prompt must always carry the background-await self-declaration rule")
        // WHY both sides: Token Saver must require canonical v1 provider text
        // and ordinary-command compression while preserving the byte-exact
        // exception. Legacy v0/SR1 is named only as forbidden output, never as
        // an advertised wire option.
        XCTAssertTrue(on.contains("Use canonical **@sr2 v1** Opaque Agent IR"),
                      "Token Saver on: every provider-authored text item uses canonical SR2 v1")
        XCTAssertTrue(on.contains("MANDATORY default-pipe:"),
                      "Token Saver on: ordinary non-TUI, non-exact shell output must use Distill")
        XCTAssertTrue(on.contains("NEVER pipe `| distill` only for exact-output"),
                      "Token Saver on: byte-exact commands remain outside Distill")
        XCTAssertTrue(on.contains("Never emit legacy @sr2 v0 or SR1"),
                      "legacy v0/SR1 is prohibited rather than advertised")
        XCTAssertFalse(on.contains("S=state"),
                       "the canonical v1 prompt must not advertise legacy SR1 field aliases")
        XCTAssertTrue(
            on.contains("\"outputStyle\":\"\(ClaudeRunner.sr2OutputStyleName)\"")
                || on.contains("\"outputStyle\": \"\(ClaudeRunner.sr2OutputStyleName)\""),
            "SDK rc_configure must set the SR2 output style when Token Saver is on: \(on)"
        )

        let off = try await configureCommand(tokenSaverOn: false)
        // Background-await stays; Distill is paid (Token Saver only).
        XCTAssertTrue(off.contains("\"system_prompt\""),
                      "the background-await rule must be sent even with Token Saver off")
        XCTAssertTrue(off.contains("Background-await protocol"),
                      "the background-await self-declaration rule must be present regardless of Token Saver")
        XCTAssertFalse(off.contains("pipe EVERY pipable, output-producing shell/tool call"),
                       "Token Saver off must not inject Distill pipe rules")
        XCTAssertFalse(off.contains("| distill"),
                       "Token Saver off must not inject Distill pipe rules")
    }

    func test_claudeSystemPrompt_backgroundAwaitAlways_distillOnlyWithTokenSaver() {
        // Background-await always; Distill only when Token Saver hint is present.
        let emptyEnv = ClaudeAgentSDKBridgeAdapter.claudeSystemPrompt(environment: [:])
        XCTAssertTrue(emptyEnv.contains(BackgroundAwaitContinuation.awaitingMarker),
                      "the background-await rule must be present on every Claude call")
        XCTAssertFalse(emptyEnv.contains("| distill"),
                       "Token Saver off must not inject Distill")
        XCTAssertFalse(emptyEnv.contains(TokenSaverProviderSafetyABI.block),
                       "Token Saver off must not inject safety ABI")

        let on = ClaudeAgentSDKBridgeAdapter.claudeSystemPrompt(environment: ["RC_TOKEN_SAVER_DISTILL_HINT": "1"])
        XCTAssertTrue(on.contains(BackgroundAwaitContinuation.awaitingMarker),
                      "the background-await rule must remain present with Token Saver on")
        XCTAssertTrue(on.contains("| distill"),
                      "Token Saver hint carries the distill piping rule")
        XCTAssertEqual(on.components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1, 1,
                       "Claude receives the versioned Token Saver safety ABI exactly once")
        XCTAssertEqual(
            (AgentSkillInstaller.distillAgentInstructionsTemplate + "\n\n" + on)
                .components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1,
            1,
            "Claude SDK effective disk plus runtime context receives the safety ABI exactly once"
        )
        XCTAssertEqual(emptyEnv.components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1, 0,
                       "Token Saver off must not inject the safety ABI")
    }

    func test_agentSDKBridgeAdapterFinalizesAssistantTextWhenBridgeExitsWithoutResult() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-finalize-\(UUID().uuidString)", isDirectory: true)
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
            write({ type: 'system', subtype: 'init', session_id: 'sdk-finalize-session' });
          } else if (cmd.type === 'rc_turn') {
            write({ type: 'assistant', message: { content: [{ type: 'text', text: 'SDK_ONLY_FINAL' }] }, session_id: 'sdk-finalize-session' });
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
            prompt: "count to 10"
        )) { event in
            Task { await sink.record(event) }
        }

        try await waitForFinish(in: sink, expected: "SDK_ONLY_FINAL")
        let events = await sink.snapshot()
        XCTAssertTrue(Self.assistantTexts(in: events).contains("SDK_ONLY_FINAL"),
                      "Claude SDK bridge must finalize buffered assistant text on EOF so a bridge exit cannot drop the response")
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

        try await adapter.rollbackThread(threadId: threadId, toTurnId: "sdk-turn-1")
        let sdkRolledBackTurns = try await adapter.readThread(threadId: threadId).compactMap(Self.completedTurnId)
        XCTAssertEqual(sdkRolledBackTurns, ["sdk-turn-1"],
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
        try await adapter.respondToRequest(threadId: threadId, requestId: "sdk-perm-1", response: .approveForSession)
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
        try adapter.respondToUserInput(
            threadId: threadId,
            requestId: "sdk-input-1",
            verbatimText: "blue",
            outboundText: "COMPRESSED-blue"
        )
        try await waitForUserInputResolution(in: sink, requestId: "sdk-input-1")
        try await waitForFinish(in: sink, expected: "SDK_INPUT_blue")

        let commands = try String(contentsOf: commandLog, encoding: .utf8)
        XCTAssertTrue(commands.contains(#""type":"user_input_response""#),
                      "SDK bridge adapter must answer native SDK elicitation through the callback response channel")
        XCTAssertTrue(commands.contains(#""text":"blue""#),
                      "SDK native user-input callbacks must preserve the answer text")
        XCTAssertFalse(commands.contains("COMPRESSED-blue"),
                       "SDK native user-input callbacks are structured answers and must not use compressed outbound text")
        XCTAssertEqual(commands.components(separatedBy: "\"type\":\"rc_turn\"").count - 1, 1,
                       "SDK native user-input callbacks should not start a second provider turn")
        try adapter.stopSession(threadId: threadId)
    }

    func test_agentSDKBridgeAdapterCancelsQuestionWithoutStoppingSession() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-cancel-input-\(UUID().uuidString)", isDirectory: true)
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
          const cmd = JSON.parse(line); record(cmd);
          if (cmd.type === 'rc_configure') write({ type: 'system', subtype: 'init', session_id: 'sdk-cancel-session' });
          else if (cmd.type === 'rc_turn') write({ type: 'user_input_request', request_id: 'sdk-cancel-input', prompt: 'Choose', options: ['a'], session_id: 'sdk-cancel-session' });
          else if (cmd.type === 'rc_interrupt') write({ type: 'result', subtype: 'success', is_error: false, result: 'cancelled question', session_id: 'sdk-cancel-session' });
          else if (cmd.type === 'rc_close') process.exit(0);
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
        )) { event in Task { await sink.record(event) } }

        try await waitForUserInput(in: sink, requestId: "sdk-cancel-input")
        try adapter.cancelUserInput(threadId: threadId, requestId: "sdk-cancel-input")
        try await waitForUserInputResolution(in: sink, requestId: "sdk-cancel-input")

        XCTAssertTrue(adapter.hasSession(threadId: threadId),
                      "AskUser cancellation must leave the warm Claude SDK session registered")
        var commands = ""
        let commandDeadline = Date().addingTimeInterval(2)
        repeat {
            commands = (try? String(contentsOf: commandLog, encoding: .utf8)) ?? ""
            if commands.contains(#""type":"user_input_cancel""#) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < commandDeadline
        XCTAssertTrue(commands.contains(#""type":"user_input_cancel""#),
                      "the bridge must cancel only the matching pending AskUser callback")
        XCTAssertTrue(commands.contains(#""request_id":"sdk-cancel-input""#),
                      "request-scoped cancellation must preserve the exact AskUser request identity")
        XCTAssertFalse(commands.contains(#""type":"rc_interrupt""#),
                       "question cancellation must not interrupt the whole provider turn")
        XCTAssertFalse(commands.contains(#""type":"rc_close""#),
                       "question cancellation must not close the provider session")
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
        // Honor the hardened completeness contract (runtimeTreeComplete): create a
        // versioned package.json for EVERY installed spec, plus the native
        // `claude` executable for the platform package. A bare SDK stub is
        // rejected as an incomplete tree.
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf '{"argv":%s,"cwd":"%s"}\\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")" "$PWD" >> "\(npmLog.path)"
        # Only `install` provisions the tree. `npm view` (peer-range resolution)
        # is a no-op so the adapter falls back to its default pinned peers and
        # never creates node_modules in the caller's cwd.
        [ "${1:-}" = "install" ] || exit 0
        for arg in "$@"; do
          case "$arg" in -*|install) continue;; esac
          name="${arg%@*}"
          version="${arg##*@}"
          [ -z "$name" ] && continue
          mkdir -p "node_modules/$name"
          printf '{"name":"%s","version":"%s"}\\n' "$name" "$version" > "node_modules/$name/package.json"
          case "$name" in *claude-agent-sdk-*) printf '#!/bin/sh\\n' > "node_modules/$name/claude"; chmod +x "node_modules/$name/claude";; esac
        done
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

    func test_agentSDKBridgeSourceEnablesPartialAssistantSnapshots() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridge = packageRoot.appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs")
        let source = try String(contentsOf: bridge, encoding: .utf8)

        XCTAssertTrue(source.contains("includePartialMessages: true"),
                      "Claude must stream partial SDK messages so the Agent App shows progress before the final response")
        XCTAssertFalse(source.contains("includePartialMessages: false"),
                       "disabling partial messages regresses live streaming to final-message-only output")
    }

    func test_agentSDKBridgeSourcePreservesApprovedToolInputAndUsesConfiguredRuntime() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridge = packageRoot.appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs")
        let source = try String(contentsOf: bridge, encoding: .utf8)

        XCTAssertTrue(source.contains("pendingPermissions.set(requestId, { resolve, input") ,
                      "permission callbacks must retain the provider's original tool input")
        XCTAssertTrue(source.contains("updatedInput: command.updated_input || pending.input"),
                      "approval without an override must deep-preserve the provider tool input")
        XCTAssertTrue(source.contains("pathToClaudeCodeExecutable: current.claudeExecutablePath"),
                      "the SDK query must execute the same configured Claude runtime selected by the app")
    }

    func test_agentSDKBridgeRejectsUnsupportedImageBeforeStartingTurn() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-unsupported-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        try """
        import readline from 'node:readline';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        for await (const line of rl) {
          const cmd = JSON.parse(line);
          if (cmd.type === 'rc_close') process.exit(0);
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        do {
            _ = try await adapter.sendTurn(AgentRunRequest(
                threadId: threadId,
                provider: .claude,
                model: "claude-haiku-4-5-20251001",
                cwd: tmp.path,
                prompt: "inspect",
                attachments: [AgentAttachment(path: "/tmp/image.svg", kind: .image, mimeType: "image/svg+xml")]
            )) { _ in }
            XCTFail("unsupported Claude image MIME must be rejected before the bridge query starts")
        } catch let AgentProviderAdapterError.unsupported(message) {
            XCTAssertTrue(message.contains("image/svg+xml"))
        }
        XCTAssertFalse(adapter.hasSession(threadId: threadId),
                       "attachment validation failure must not leave a registered half-started session")
    }

    func test_agentSDKBridgeSourceWiresPostToolUseTokenSaverHook() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridge = packageRoot.appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs")
        let source = try String(contentsOf: bridge, encoding: .utf8)

        XCTAssertTrue(source.contains("hooks: tokenSaverHooks()"),
                      "I2: SDK query options must register the PostToolUse hook so tool_result bytes can be replaced before provider context replay")
        XCTAssertTrue(source.contains("updatedMCPToolOutput"),
                      "I2: PostToolUse must use the SDK replacement field, not only additionalContext, otherwise raw tool output still reaches the next request")
        XCTAssertTrue(source.contains("RC_TOKEN_SAVER_POST_TOOL_USE"),
                      "I2: hook must stay opt-in/default-off until Token Saver enables it")
        XCTAssertTrue(source.contains("TOKEN_SAVER_STORE_MIN_BYTES = 2048"),
                      "I2: hooked tool output lane lowers reversible store floor from 8192 to 2048 bytes")
    }

    // The SDK bridge has no developer_instructions channel like Codex, so the Token Saver
    // distill rules (pipe `| distill` + speak distill language) must ride in the SDK
    // `systemPrompt`. The host sends it as `system_prompt` on rc_configure; the bridge relays
    // it into the query options. Locks both ends of that wiring.
    func test_agentSDKBridgeSourceWiresTokenSaverSystemPrompt() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridge = packageRoot.appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs")
        let source = try String(contentsOf: bridge, encoding: .utf8)

        XCTAssertTrue(source.contains("systemPrompt: current.systemPrompt"),
                      "SDK query options must pass the host-provided distill system prompt so Claude pipes `| distill` and speaks distill language")
        XCTAssertTrue(source.contains("systemPrompt: command.system_prompt || undefined"),
                      "rc_configure must relay the host `system_prompt` into session state (undefined keeps the SDK default empty prompt when Token Saver is off)")
    }

    // The Claude PostToolUse fallback must distill EVERY tool (no 4-tool
    // allowlist) once output passes its hook threshold, excluding only the
    // exact-byte file tools, Skill content, and Bash output already owned by an
    // explicit Distill invocation.
    func test_agentSDKBridgeTokenSaverCompressesAllToolsAbovePolicyThreshold() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridge = packageRoot.appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs")
        let source = try String(contentsOf: bridge, encoding: .utf8)

        XCTAssertTrue(source.contains("TOKEN_SAVER_MIN_BYTES = 1024"),
                      "threshold must match the distill policy (~1KB), not the prior 2048 that skipped 1-2KB output")
        XCTAssertTrue(source.contains("TOKEN_SAVER_MIN_LINES = 10"),
                      "threshold must match the distill policy (~10 lines), not the prior 30 that skipped 10-30 line output")
        XCTAssertTrue(source.contains("TOKEN_SAVER_DEFAULT_PROFILE"),
                      "unlisted tools must fall back to a compressing default profile, not passthrough")
        XCTAssertTrue(source.contains("TOKEN_SAVER_PROFILES.get(normalized) || TOKEN_SAVER_DEFAULT_PROFILE"),
                      "the decision must default every tool to compression instead of a 4-tool allowlist")
        XCTAssertFalse(source.contains("'not_allowlisted'"),
                       "there must be no allowlist gate — every non-excluded tool compresses")
        // The AND guard is correct De Morgan ("skip only when BOTH dimensions are
        // small"); it must remain AND so output compresses when EITHER threshold trips.
        XCTAssertTrue(source.contains("<= TOKEN_SAVER_MIN_BYTES && lineCount(output) <= TOKEN_SAVER_MIN_LINES"),
                      "skip guard must stay AND so a >1KB OR >10-line output is compressed")
        XCTAssertTrue(source.contains("TOKEN_SAVER_EXCLUDED_TOOLS = new Set(['edit', 'write', 'multiedit', 'notebookedit', 'skill'])"),
                      "edit/write/skill stay exempt; Read/Grep compress for Token Saver coverage")
        XCTAssertTrue(source.contains("skill_content"),
                      "Skill exclusion must use a dedicated skip reason so PostToolUse never compresses skill bodies")
        XCTAssertTrue(source.contains("TOKEN_SAVER_EXACT_OUTPUT_BASH"),
                      "Bash must skip exact-output shell tools (rg/grep/sed/...) per AGENTS.md")
        XCTAssertTrue(source.contains("isExactOutputBashCommand"),
                      "Bash exact-output detection must inspect command segments, not only the first token")
        XCTAssertTrue(source.contains("updatedToolOutput"),
                      "PostToolUse must use updatedToolOutput so built-in tools actually receive compressed output")
    }

    /// Behavioral pin: Skill tool output must bypass PostToolUse Distill even when
    /// the payload is large enough that ordinary tools would compress.
    func test_agentSDKBridgeTokenSaverSkipsSkillToolOutputRegardlessOfSize() throws {
        let node = try XCTUnwrap(
            ProcessLocator.resolve("node"),
            "node is required for the bridge decision contract test"
        )
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridge = packageRoot.appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs")
        let source = try String(contentsOf: bridge, encoding: .utf8)

        // WHY: run the same decision function the bridge uses against a large skill
        // fixture so we prove exclusion is behavioral, not just a string pin.
        // Concatenate (no JS template literal) so bridge source with special chars
        // cannot break Function construction.
        let harness = """
        import { readFileSync } from 'fs';
        // argv[0]=node argv[1]=this harness argv[2]=bridge path
        const src = readFileSync(process.argv[2], 'utf8');
        const start = src.indexOf('const TOKEN_SAVER_MIN_BYTES');
        const end = src.indexOf('function tokenSaverContractQuestion');
        if (start < 0 || end < 0) throw new Error('helper slice not found: ' + start + '/' + end);
        const slice = src.slice(start, end);
        const mod = new Function(slice + '; return { tokenSaverToolDecision, TOKEN_SAVER_EXCLUDED_TOOLS };')();
        const largeSkill = 'SKILL_FIXTURE_BEGIN\\n' + ('x'.repeat(8000)) + '\\nSKILL_FIXTURE_END';
        const skill = mod.tokenSaverToolDecision('Skill', { skill: 'remote-code-orchestrate' }, largeSkill);
        const ordinary = mod.tokenSaverToolDecision('Bash', { command: 'swift test' }, largeSkill);
        const exact = mod.tokenSaverToolDecision('Bash', { command: 'rg -n foo Sources' }, largeSkill);
        console.log(JSON.stringify({
          skillShouldCompress: skill.shouldCompress,
          skillSkipReason: skill.skipReason,
          ordinaryShouldCompress: ordinary.shouldCompress,
          exactShouldCompress: exact.shouldCompress,
          exactSkipReason: exact.skipReason,
          skillExcluded: mod.TOKEN_SAVER_EXCLUDED_TOOLS.has('skill'),
          skillLen: largeSkill.length,
        }));
        """
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-skill-distill-decision-\(UUID().uuidString).mjs")
        try harness.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [tmp.path, bridge.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "node harness failed: \(out)")
        guard let data = out.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("expected JSON decision payload, got: \(out)")
        }
        XCTAssertEqual(json["skillShouldCompress"] as? Bool, false,
                       "Skill tool output must never enter Distill PostToolUse compression")
        XCTAssertEqual(json["skillSkipReason"] as? String, "skill_content")
        XCTAssertEqual(json["ordinaryShouldCompress"] as? Bool, true,
                       "ordinary large Bash output remains Distill-eligible")
        XCTAssertEqual(json["exactShouldCompress"] as? Bool, false,
                       "exact-output Bash (rg) stays excluded")
        XCTAssertEqual(json["skillExcluded"] as? Bool, true)
        XCTAssertGreaterThan(json["skillLen"] as? Int ?? 0, 6000,
                             "fixture must exceed presentation truncation limit to prove completeness path")
        // Ensure the harness is grounded in the live bridge (no silent fallback).
        XCTAssertTrue(source.contains("'skill'"), "bridge source must list skill exclusion")
    }

    /// Behavioral pin: an explicit Distill shell segment owns compression, so
    /// Claude's PostToolUse fallback must never compress that output a second time.
    func test_agentSDKBridgeTokenSaverSkipsExplicitDistillBashOutputExactlyOnce() throws {
        let node = try XCTUnwrap(
            ProcessLocator.resolve("node"),
            "node is required for the bridge decision contract test"
        )
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridge = packageRoot.appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs")

        let harness = """
        import { readFileSync } from 'fs';
        const src = readFileSync(process.argv[2], 'utf8');
        const start = src.indexOf('const TOKEN_SAVER_MIN_BYTES');
        const end = src.indexOf('function tokenSaverContractQuestion');
        if (start < 0 || end < 0) throw new Error('helper slice not found: ' + start + '/' + end);
        const slice = src.slice(start, end);
        const mod = new Function(slice + '; return { tokenSaverToolDecision };')();
        const large = 'OUTPUT_BEGIN\\n' + ('x'.repeat(8000)) + '\\nOUTPUT_END';
        const decide = (command) => mod.tokenSaverToolDecision('Bash', { command }, large);
        console.log(JSON.stringify({
          pipe: decide("swift test 2>&1 | distill 'test failures'"),
          retrieve: decide('distill retrieve handle'),
          absolute: decide('/opt/remotecode/bin/distill retrieve handle'),
          commandPrefix: decide("command /opt/remotecode/bin/distill 'summary'"),
          envPrefix: decide("env RC_EXPLICIT=1 /opt/remotecode/bin/distill 'summary'"),
          quoted: decide("echo 'literal | distill remains text'"),
          ordinary: decide('swift test --filter FeatureTests'),
        }));
        """
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-explicit-distill-decision-\(UUID().uuidString).mjs")
        try harness.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [tmp.path, bridge.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "node harness failed: \(out)")
        let data = try XCTUnwrap(out.data(using: .utf8))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        for key in ["pipe", "retrieve", "absolute", "commandPrefix", "envPrefix"] {
            let decision = try XCTUnwrap(json[key] as? [String: Any], "missing \(key) decision")
            XCTAssertEqual(decision["shouldCompress"] as? Bool, false, "\(key) must stay single-pass")
            XCTAssertEqual(decision["skipReason"] as? String, "explicit_distill_pipeline")
        }
        let quoted = try XCTUnwrap(json["quoted"] as? [String: Any])
        XCTAssertEqual(quoted["shouldCompress"] as? Bool, false,
                       "the lightweight JS splitter may conservatively protect quoted | distill text")
        XCTAssertEqual(quoted["skipReason"] as? String, "explicit_distill_pipeline")
        let ordinary = try XCTUnwrap(json["ordinary"] as? [String: Any])
        XCTAssertEqual(ordinary["shouldCompress"] as? Bool, true,
                       "ordinary noisy Swift output must remain PostToolUse-eligible")
        XCTAssertTrue(ordinary["skipReason"] is NSNull)

        let swiftPolicy = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/DistillCore/ToolOutputCompressionPolicy.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(swiftPolicy.contains(#"case explicitDistillPipeline = "explicit_distill_pipeline""#))
        let bridgeSource = try String(contentsOf: bridge, encoding: .utf8)
        XCTAssertTrue(bridgeSource.contains("skipReason = 'explicit_distill_pipeline'"),
                      "Swift and JS must publish the same content-free single-pass reason")
    }

    func test_agentSDKBridgeRecoversRawNewlineSplitPromptCommand() throws {
        guard let node = ProcessLocator.resolve("node") else {
            throw XCTSkip("node not available")
        }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-bridge-raw-newline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let bridge = tmp.appendingPathComponent("ClaudeAgentSDKBridge.mjs")
        try FileManager.default.copyItem(
            at: packageRoot.appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs"),
            to: bridge
        )

        let sdkModule = tmp.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk", isDirectory: true)
        try FileManager.default.createDirectory(at: sdkModule, withIntermediateDirectories: true)
        try #"{"type":"module","main":"index.js","version":"0.3.157"}"#.write(to: sdkModule.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try """
        export function createSdkMcpServer() {
          return { instance: { server: {} } };
        }
        export function tool(name, description, schema, handler) {
          return { name, description, schema, handler };
        }
        export function query({ prompt }) {
          return (async function*() {
            const iterator = prompt[Symbol.asyncIterator]();
            const next = await iterator.next();
            if (next.done) return;
            const text = next.value?.message?.content?.[0]?.text || '';
            const marker = text.includes('line one\\n\\nline three') ? 'BRIDGE_RAW_NEWLINE_OK' : 'BRIDGE_RAW_NEWLINE_MISSING';
            yield { type: 'system', subtype: 'init', session_id: 'fake-sdk-session' };
            yield { type: 'assistant', message: { id: 'fake-turn', content: [{ type: 'text', text: marker }] }, session_id: 'fake-sdk-session' };
            yield { type: 'result', subtype: 'success', is_error: false, result: marker, session_id: 'fake-sdk-session' };
          })();
        }
        """.write(to: sdkModule.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let zodModule = tmp.appendingPathComponent("node_modules/zod", isDirectory: true)
        try FileManager.default.createDirectory(at: zodModule, withIntermediateDirectories: true)
        try #"{"type":"module","main":"index.js"}"#.write(to: zodModule.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "export const z = {};\n".write(to: zodModule.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [bridge.path]
        process.currentDirectoryURL = tmp
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let configure = #"{"type":"rc_configure","bridge_protocol_version":\#(ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion),"expected_sdk_version":"0.3.157","session_id":"split-session"}"# + "\n"
        stdin.fileHandleForWriting.write(Data(configure.utf8))
        let splitCommand = """
        {"type":"rc_turn","prompt":"line one

        line three","session_id":"split-session"}
        """
        stdin.fileHandleForWriting.write(Data(splitCommand.utf8))
        stdin.fileHandleForWriting.closeFile()

        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "raw newline prompt command must not crash the bridge; stderr: \(err)")
        XCTAssertTrue(out.contains("BRIDGE_RAW_NEWLINE_OK"),
                      "bridge must recover a prompt JSON command split by a raw newline inside the prompt string")
        XCTAssertFalse(err.contains("SyntaxError: Unterminated string"),
                       "the bridge must not leak the JSON.parse stack shown in the Agent App screenshot")
    }

    // The Claude AskUserQuestion tool reaches the bridge through the SDK
    // `canUseTool` callback even in bypassPermissions/full-access mode. The
    // screenshot bug showed it rendered as a "Provider approval" card with raw
    // JSON and Approve/Approve Session buttons. The bridge must instead route it as
    // a structured `user_input_request` (no approval), and return the user's choice
    // to the model as the canUseTool `{ behavior: 'allow', updatedInput: { answers } }`
    // permission result.
    func test_agentSDKBridgeRoutesAskUserQuestionAsStructuredUserInput() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let session = try AskUserQuestionBridgeSession(node: node, packageRoot: AskUserQuestionBridgeSession.packageRoot())

        try session.send(["type": "rc_configure", "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion, "expected_sdk_version": "0.3.157", "permission_mode": "full_access", "session_id": "fake-aq"])
        try session.send(["type": "rc_turn", "prompt": "decide the path"])

        XCTAssertTrue(session.waitFor("\"type\":\"user_input_request\""),
                      "AskUserQuestion must surface as a user_input_request card, not block silently")
        try session.send(["type": "user_input_response", "request_id": "ask-real-1", "text": #"{"Which path?":"Run"}"#])
        let sawResult = session.waitFor("ASK_RESULT:")
        let err = session.finish()
        let out = session.output

        XCTAssertTrue(sawResult, "the bridge must resolve the AskUserQuestion canUseTool promise once answered; stderr: \(err)")
        XCTAssertTrue(out.contains("\"type\":\"user_input_request\""),
                      "Bug 1/2: AskUserQuestion must render as a structured question card")
        XCTAssertFalse(out.contains("\"type\":\"permission_request\""),
                       "Bug 3: AskUserQuestion in full access must NOT request tool approval (no Approve/Approve Session)")
        XCTAssertTrue(out.contains("\"ask_user_question\":true"),
                      "the user_input_request must be tagged so the UI renders the structured AskUserQuestion picker")
        XCTAssertTrue(out.contains("Which path?") && out.contains("Plan") && out.contains("Run"),
                      "Bug 1: the question text and option labels must be carried through, not raw-JSON-only")
        // The canUseTool result returned to the model must allow the tool and carry
        // the answer keyed by question text. The result is JSON nested inside the
        // assistant message text, so the inner quotes are escaped in raw stdout.
        XCTAssertTrue(out.contains(#"\"behavior\":\"allow\""#),
                      "answering AskUserQuestion must allow the tool to proceed")
        XCTAssertTrue(out.contains(#"\"answers\":{\"Which path?\":\"Run\"}"#),
                      "the user's selection must be returned to the model in updatedInput.answers, keyed by question text")
        XCTAssertEqual(session.process.terminationStatus, 0, "bridge must exit cleanly; stderr: \(err)")
    }

    // Interrupting while an AskUserQuestion is pending must NOT leave the SDK
    // async generator awaiting an answer forever — the bridge denies the pending
    // canUseTool so the turn can unwind.
    func test_agentSDKBridgeInterruptDeniesPendingAskUserQuestion() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let session = try AskUserQuestionBridgeSession(node: node, packageRoot: AskUserQuestionBridgeSession.packageRoot())

        try session.send(["type": "rc_configure", "bridge_protocol_version": ClaudeAgentSDKBridgeAdapter.bridgeProtocolVersion, "expected_sdk_version": "0.3.157", "permission_mode": "full_access", "session_id": "fake-aq"])
        try session.send(["type": "rc_turn", "prompt": "decide the path"])
        XCTAssertTrue(session.waitFor("\"type\":\"user_input_request\""),
                      "the question must be pending before we interrupt")
        try session.send(["type": "rc_interrupt"])
        let resolved = session.waitFor("ASK_RESULT:")
        let err = session.finish()
        let out = session.output

        XCTAssertTrue(resolved,
                      "interrupt must settle the pending AskUserQuestion canUseTool promise instead of hanging; stderr: \(err)")
        XCTAssertTrue(out.contains(#"\"behavior\":\"deny\""#),
                      "an interrupted AskUserQuestion must be denied so the tool does not silently proceed")
        XCTAssertTrue(out.contains(#"\"interrupt\":true"#),
                      "the deny must interrupt the turn rather than just rejecting one tool call")
        XCTAssertEqual(session.process.terminationStatus, 0, "bridge must exit cleanly after interrupt; stderr: \(err)")
    }

    func test_agentSDKPackageSpecRefreshesStalePinnedCache() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-version-\(UUID().uuidString)", isDirectory: true)
        let packageJSON = tmp.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk/package.json")
        try FileManager.default.createDirectory(at: packageJSON.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"name":"@anthropic-ai/claude-agent-sdk","version":"0.3.150"}"#
            .write(to: packageJSON, atomically: true, encoding: .utf8)

        XCTAssertEqual(ClaudeAgentSDKBridgeAdapter.defaultSDKPackageSpec, "@anthropic-ai/claude-agent-sdk@0.3.157")
        XCTAssertFalse(ClaudeAgentSDKBridgeAdapter.installedSDKPackage(at: packageJSON, matches: ClaudeAgentSDKBridgeAdapter.defaultSDKPackageSpec),
                       "an old cached Claude SDK must be reinstalled instead of keeping the pre-fix package that can fail thinking-block continuations")

        try #"{"name":"@anthropic-ai/claude-agent-sdk","version":"0.3.157"}"#
            .write(to: packageJSON, atomically: true, encoding: .utf8)
        XCTAssertTrue(ClaudeAgentSDKBridgeAdapter.installedSDKPackage(at: packageJSON, matches: ClaudeAgentSDKBridgeAdapter.defaultSDKPackageSpec))
    }

    // MARK: - CLAUDE-BG-LIFECYCLE (background tasks + async subagents)

    /// Writes a fake `claude` that replays the REAL wire sequence captured from
    /// `claude --print --input-format stream-json --output-format stream-json`
    /// (CLI 2.1.219) when a turn ends while async work is still running: the CLI
    /// emits a premature `result`, later reports the task list empty, RESUMES the
    /// agent on its own, and emits a second `result` carrying the real answer.
    ///
    /// `taskType` is `local_bash` for a background shell and `local_agent` for an
    /// async subagent — the two cases users hit. `neverCompletes` drops the
    /// idle snapshot + resumed turn to model a background job that never returns.
    private func writeBackgroundLifecycleFakeClaude(
        at script: URL,
        taskType: String,
        neverCompletes: Bool = false
    ) throws {
        // Built line-by-line with explicit indentation: interpolating an indented
        // multi-line chunk into a Python loop body silently produces invalid
        // indentation (the script then dies and the test measures the wrong thing).
        let body = "    "
        var lines: [String] = [
            "#!/usr/bin/env python3",
            "import json, sys, time",
            "S = \"claude-bg-session\"",
            "def e(o):",
            "    print(json.dumps(o), flush=True)",
            "e({\"type\":\"system\",\"subtype\":\"init\",\"session_id\":S})",
            "for line in sys.stdin:",
            body + "if not line.strip():",
            body + "    continue",
            // turn 1: dispatch async work, then end the turn early (the CLI's real behaviour)
            body + "e({\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_bg\",\"name\":\"Bash\",\"input\":{\"command\":\"sleep 30\",\"run_in_background\":True}}]},\"session_id\":S})",
            body + "e({\"type\":\"system\",\"subtype\":\"background_tasks_changed\",\"tasks\":[{\"task_id\":\"T1\",\"task_type\":\"\(taskType)\",\"description\":\"work\"}],\"session_id\":S})",
            body + "e({\"type\":\"system\",\"subtype\":\"task_started\",\"task_id\":\"T1\",\"task_type\":\"\(taskType)\",\"session_id\":S})",
            body + "e({\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"PREMATURE_STANDING_BY\"}]},\"session_id\":S})",
            body + "e({\"type\":\"result\",\"subtype\":\"success\",\"is_error\":False,\"result\":\"PREMATURE_STANDING_BY\",\"session_id\":S})",
        ]
        if !neverCompletes {
            lines += [
                body + "time.sleep(0.25)",
                // provider goes idle, then resumes the agent on its own
                body + "e({\"type\":\"system\",\"subtype\":\"background_tasks_changed\",\"tasks\":[],\"session_id\":S})",
                body + "e({\"type\":\"system\",\"subtype\":\"task_updated\",\"task_id\":\"T1\",\"patch\":{\"status\":\"completed\"},\"session_id\":S})",
                body + "e({\"type\":\"system\",\"subtype\":\"task_notification\",\"task_id\":\"T1\",\"status\":\"completed\",\"session_id\":S})",
                body + "e({\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"REAL_ANSWER_AFTER_BG\"}]},\"session_id\":S})",
                body + "e({\"type\":\"result\",\"subtype\":\"success\",\"is_error\":False,\"result\":\"REAL_ANSWER_AFTER_BG\",\"session_id\":S})",
            ]
        }
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    private func runBackgroundLifecycleTurn(
        taskType: String,
        neverCompletes: Bool = false,
        inactivityTimeout: TimeInterval = 900
    ) async throws -> [AgentRunEvent] {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try writeBackgroundLifecycleFakeClaude(at: script, taskType: taskType, neverCompletes: neverCompletes)

        let adapter = ClaudeStreamingCLIAdapter(
            binaryNameOverride: script.path,
            deferredFinishInactivityTimeout: inactivityTimeout
        )
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "launch background work"
        )) { event in
            Task { await sink.record(event) }
        }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let finished = await sink.snapshot().contains { if case .finished = $0 { return true }; return false }
            if finished { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        // Settle briefly so a (wrong) second terminal would be observed too.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let events = await sink.snapshot()
        try? adapter.stopSession(threadId: threadId)
        return events
    }

    private static func finishedPairs(_ events: [AgentRunEvent]) -> [(AgentRunStatus, String?)] {
        events.compactMap {
            if case .finished(let status, let final, _) = $0 { return (status, final) }
            return nil
        }
    }

    func test_backgroundTaskDoesNotEndThreadUntilProviderIsIdle() async throws {
        // THE REPORTED BUG: the agent launched a background shell and ended its
        // turn; the app took that first `result` as terminal, reported the thread
        // as completed (so it read as finished and invited a new message) and threw
        // away the real answer the CLI streamed after the task finished.
        let events = try await runBackgroundLifecycleTurn(taskType: "local_bash")
        let finishes = Self.finishedPairs(events)

        XCTAssertEqual(finishes.count, 1,
                       "a run that left a background task running must produce exactly ONE terminal event, not one per provider `result`")
        XCTAssertEqual(finishes.first?.1, "REAL_ANSWER_AFTER_BG",
                       "the terminal must carry the answer the agent gave AFTER the background task completed — finishing on the premature `result` is what made the thread read as done while work was still running")
        XCTAssertFalse(finishes.contains { $0.1 == "PREMATURE_STANDING_BY" },
                       "the premature `result` emitted while background_tasks_changed still listed a task must never terminate the run")
    }

    func test_asyncSubagentDoesNotEndThreadUntilProviderIsIdle() async throws {
        // Same defect for the other case the user hit: an async subagent (the CLI
        // reports it as task_type `local_agent` and keeps streaming the subagent's
        // own work after the parent turn's `result`).
        let events = try await runBackgroundLifecycleTurn(taskType: "local_agent")
        let finishes = Self.finishedPairs(events)

        XCTAssertEqual(finishes.count, 1,
                       "dispatching an async subagent must not make the run terminal until the subagent is done")
        XCTAssertEqual(finishes.first?.1, "REAL_ANSWER_AFTER_BG",
                       "the run must finish on the parent turn that follows the subagent's completion, carrying its real answer")
    }

    func test_deferredFinishStillReachesTerminalWhenBackgroundWorkNeverCompletes() async throws {
        // Liveness bound (Codex advisory): withholding the finish must never let a
        // run hang non-terminal forever. If the provider never reports idle, the
        // watchdog releases the withheld finish so the thread still settles (and
        // the awaiting-banner fallback can drive it), instead of spinning as
        // "working" with no way out.
        let events = try await runBackgroundLifecycleTurn(
            taskType: "local_bash",
            neverCompletes: true,
            inactivityTimeout: 0.3
        )
        let finishes = Self.finishedPairs(events)

        XCTAssertEqual(finishes.count, 1,
                       "the inactivity watchdog must emit exactly one terminal when the provider never goes idle")
        XCTAssertEqual(finishes.first?.1, "PREMATURE_STANDING_BY",
                       "with no resumed turn to supersede it, the withheld finish is what settles the run")
    }

    func test_selfDeclaredRCAwaitingDoesNotDeferFinishWhileStickyBackgroundTasks() async throws {
        // WHY: field Elephant Task 1 2026-08-06 — model ended with
        // `[[RC_AWAITING]]\n## Done — PR #2402` while CLI still listed sticky
        // local_bash CI waiters. Deferral withheld `.finished`, so auto-nudge
        // and Continue (both need `.completed`) never ran — Working forever.
        // Self-declared marker is the "nudge me" contract: finish promptly.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-rc-await-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        let marker = "[[RC_AWAITING]]"
        let final = "\(marker)\\n\\n## Done — PR #2402, Linear updated."
        try """
        #!/usr/bin/env python3
        import json, sys, time
        S = "claude-rc-await-session"
        def e(o):
            print(json.dumps(o), flush=True)
        e({"type":"system","subtype":"init","session_id":S})
        for line in sys.stdin:
            if not line.strip():
                continue
            e({"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b93ce913v","task_type":"local_bash","description":"Wait for CI"}],"session_id":S})
            e({"type":"assistant","message":{"content":[{"type":"text","text":"\(final)"}]},"session_id":S})
            e({"type":"result","subtype":"success","is_error":False,"result":"\(final)","session_id":S})
            # Sticky tasks never clear — must still finish promptly (not wait 900s).
            time.sleep(2)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(
            binaryNameOverride: script.path,
            deferredFinishInactivityTimeout: 30 // would hang the test if we wrongly deferred
        )
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "finish with marker"
        )) { event in
            Task { await sink.record(event) }
        }
        let deadline = Date().addingTimeInterval(2)
        var finishes: [(AgentRunStatus, String?)] = []
        while Date() < deadline {
            finishes = Self.finishedPairs(await sink.snapshot())
            if !finishes.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(finishes.count, 1,
                       "[[RC_AWAITING]] final must not defer while sticky bg tasks remain")
        XCTAssertEqual(finishes.first?.0, .completed)
        XCTAssertTrue(
            (finishes.first?.1 ?? "").contains(marker),
            "terminal final must preserve the marker for auto-nudge / Continue"
        )
        XCTAssertTrue(
            (finishes.first?.1 ?? "").contains("Done — PR #2402"),
            "terminal must carry the Done body, not drop it"
        )
        try? adapter.stopSession(threadId: threadId)
    }

    func test_deferredFinishDoesNotForceTerminalWhileStreamProgressContinues() async throws {
        // WHY: real bg lifecycle progress must re-arm inactivity so long nested
        // work is not force-finished. Generic status heartbeats must NOT re-arm
        // (see test_deferredFinishStatusHeartbeatsDoNotReArmInactivity).
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-no-absmax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys, time
        S = "claude-no-absmax-session"
        def e(o):
            print(json.dumps(o), flush=True)
        e({"type":"system","subtype":"init","session_id":S})
        for line in sys.stdin:
            if not line.strip():
                continue
            e({"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"T1","task_type":"local_bash"}],"session_id":S})
            e({"type":"assistant","message":{"content":[{"type":"text","text":"DONE_PREMATURE"}]},"session_id":S})
            e({"type":"result","subtype":"success","is_error":False,"result":"DONE_PREMATURE","session_id":S})
            # Real bg lifecycle progress longer than a short inactivity window.
            for i in range(12):
                time.sleep(0.08)
                e({"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"T1","task_type":"local_bash","status":"running"}],"session_id":S})
            # Quiet: inactivity may flush after this.
            time.sleep(2)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(
            binaryNameOverride: script.path,
            deferredFinishInactivityTimeout: 0.3,
            deferredFinishPostIdleTimeout: 30
        )
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "bg hang"
        )) { event in
            Task { await sink.record(event) }
        }
        // During progress window (~1s), finish must not have been forced.
        try? await Task.sleep(nanoseconds: 700_000_000)
        var finishes = Self.finishedPairs(await sink.snapshot())
        XCTAssertEqual(finishes.count, 0,
                       "bg lifecycle progress must re-arm inactivity — no absolute max force-finish")

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            finishes = Self.finishedPairs(await sink.snapshot())
            if !finishes.isEmpty { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(finishes.count, 1,
                       "true quiet after progress still flushes via inactivity")
        XCTAssertEqual(finishes.first?.1, "DONE_PREMATURE")
        try? adapter.stopSession(threadId: threadId)
    }

    func test_deferredFinishStatusHeartbeatsDoNotReArmInactivity() async throws {
        // WHY: sticky pending + system/status keepalives used to re-arm forever
        // (97m Working). Heartbeats must not postpone inactivity flush.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-hb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys, time
        S = "claude-hb-session"
        def e(o):
            print(json.dumps(o), flush=True)
        e({"type":"system","subtype":"init","session_id":S})
        for line in sys.stdin:
            if not line.strip():
                continue
            e({"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"T1","task_type":"local_bash"}],"session_id":S})
            e({"type":"assistant","message":{"content":[{"type":"text","text":"STANDING_BY"}]},"session_id":S})
            e({"type":"result","subtype":"success","is_error":False,"result":"STANDING_BY","session_id":S})
            for i in range(40):
                time.sleep(0.05)
                e({"type":"system","subtype":"status","session_id":S,"message":f"heartbeat {i}"})
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(
            binaryNameOverride: script.path,
            deferredFinishInactivityTimeout: 0.35,
            deferredFinishPostIdleTimeout: 30
        )
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "sticky bg + heartbeats"
        )) { event in
            Task { await sink.record(event) }
        }
        let deadline = Date().addingTimeInterval(3)
        var finishes: [(AgentRunStatus, String?)] = []
        while Date() < deadline {
            finishes = Self.finishedPairs(await sink.snapshot())
            if !finishes.isEmpty { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(finishes.count, 1,
                       "status heartbeats must not re-arm inactivity — quiet flush must settle Working")
        XCTAssertEqual(finishes.first?.1, "STANDING_BY")
        try? adapter.stopSession(threadId: threadId)
    }

    func test_deferredFinishFlushesSoonAfterPendingBecomesIdleWithoutResumeResult() async throws {
        // WHY: CLI sometimes clears background_tasks without a follow-up result.
        // Post-idle short timeout must end Working instead of waiting full 900s.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-postidle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys, time
        S = "claude-postidle-session"
        def e(o):
            print(json.dumps(o), flush=True)
        e({"type":"system","subtype":"init","session_id":S})
        for line in sys.stdin:
            if not line.strip():
                continue
            e({"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"T1","task_type":"local_bash"}],"session_id":S})
            e({"type":"assistant","message":{"content":[{"type":"text","text":"STANDING_BY"}]},"session_id":S})
            e({"type":"result","subtype":"success","is_error":False,"result":"STANDING_BY","session_id":S})
            time.sleep(0.1)
            e({"type":"system","subtype":"background_tasks_changed","tasks":[],"session_id":S})
            # No second result — post-idle flush must settle the run.
            time.sleep(2)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(
            binaryNameOverride: script.path,
            deferredFinishInactivityTimeout: 30,
            deferredFinishPostIdleTimeout: 0.25
        )
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "bg then idle"
        )) { event in
            Task { await sink.record(event) }
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let finished = await sink.snapshot().contains { if case .finished = $0 { return true }; return false }
            if finished { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let finishes = Self.finishedPairs(await sink.snapshot())
        XCTAssertEqual(finishes.count, 1,
                       "empty pending without resume result must flush deferred finish quickly")
        XCTAssertEqual(finishes.first?.1, "STANDING_BY")
        try? adapter.stopSession(threadId: threadId)
    }

    func test_turnWithoutBackgroundWorkFinishesImmediately() async throws {
        // Regression guard for the deferral gate: an ordinary turn (no background
        // task ever reported) must still finish on its first `result` — the fix
        // must not delay or double-emit the terminal for normal runs.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-nobg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys
        S = "claude-nobg-session"
        def e(o):
            print(json.dumps(o), flush=True)
        e({"type":"system","subtype":"init","session_id":S})
        for line in sys.stdin:
            if not line.strip():
                continue
            e({"type":"assistant","message":{"content":[{"type":"text","text":"PLAIN_ANSWER"}]},"session_id":S})
            e({"type":"result","subtype":"success","is_error":False,"result":"PLAIN_ANSWER","session_id":S})
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
            prompt: "plain"
        )) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "PLAIN_ANSWER")
        let plainEvents = await sink.snapshot()
        XCTAssertEqual(Self.finishedPairs(plainEvents).count, 1,
                       "a turn with no background work must emit exactly one terminal, unchanged by the deferral gate")
        try adapter.stopSession(threadId: threadId)
    }

    // MARK: - Shell-detached workers (CLI-unowned; stamp [[RC_AWAITING]], do not defer)

    /// Real incident shape: foreground Bash tool_use (NO `run_in_background`)
    /// shell-detaches workers with `... & PID=$!`. CLI never emits
    /// `background_tasks_changed` / `task_started`. Without the adapter stamp the
    /// run finishes green while workers still run.
    func test_shellDetachedForegroundBash_stampsAwaitingMarkerOnCompletedTurn() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-detach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")
        // Command shape captured from run 2D47AD8B (foreground Bash + shell &; no run_in_background).
        try #"""
        #!/usr/bin/env python3
        import json, sys
        S = "claude-detach-session"
        def e(o):
            print(json.dumps(o), flush=True)
        e({"type":"system","subtype":"init","session_id":S})
        for line in sys.stdin:
            if not line.strip():
                continue
            cmd = "grok --prompt-file /tmp/w2-c02.txt --output-format json > /tmp/w2-c02-result.json 2>&1 &\nPID_C02=$!\necho started"
            e({"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_detach","name":"Bash","input":{"command":cmd,"description":"launch workers"}}]},"session_id":S})
            e({"type":"assistant","message":{"content":[{"type":"text","text":"Workers launched; keeping polling active."}]},"session_id":S})
            e({"type":"result","subtype":"success","is_error":False,"result":"Workers launched; keeping polling active.","session_id":S})
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "fan out workers"
        )) { event in
            Task { await sink.record(event) }
        }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let finished = await sink.snapshot().contains { if case .finished = $0 { return true }; return false }
            if finished { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await sink.snapshot()
        let finishes = Self.finishedPairs(events)
        let marker = BackgroundAwaitContinuation.awaitingMarker

        XCTAssertEqual(finishes.count, 1,
                       "shell-detached work must NOT defer: exactly one terminal (CLI never auto-resumes these)")
        XCTAssertEqual(finishes.first?.0, .completed)
        XCTAssertTrue(finishes.first?.1?.contains(marker) == true,
                      "finished.finalMessage must carry [[RC_AWAITING]] so the coordinator auto-nudge fires; got \(finishes.first?.1 ?? "nil")")

        let turnFinals = events.compactMap { event -> String? in
            if case .event(.turnCompleted(_, let msg)) = event { return msg }
            return nil
        }
        XCTAssertTrue(turnFinals.contains(where: { $0.contains(marker) }),
                      "persisted turnCompleted finalMessage must also carry the marker (UI pill/banner reload source); got \(turnFinals)")
        try? adapter.stopSession(threadId: threadId)
    }

    /// Ordinary foreground Bash that does not detach — and a detaching command
    /// that ends with `wait` — must not be stamped.
    func test_nonDetachingBash_andWaitBuiltin_doNotStampAwaitingMarker() async throws {
        let cases: [(name: String, command: String)] = [
            ("no_detach", "swift build && echo ok"),
            ("wait_after_detach", "sleep 30 & wait"),
        ]
        for testCase in cases {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rc2-claude-nodetach-\(testCase.name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let script = tmp.appendingPathComponent("fake-claude")
            let escaped = testCase.command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            try """
            #!/usr/bin/env python3
            import json, sys
            S = "claude-nodetach-\(testCase.name)"
            def e(o):
                print(json.dumps(o), flush=True)
            e({"type":"system","subtype":"init","session_id":S})
            for line in sys.stdin:
                if not line.strip():
                    continue
                e({"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_x","name":"Bash","input":{"command":"\(escaped)"}}]},"session_id":S})
                e({"type":"assistant","message":{"content":[{"type":"text","text":"DONE_\(testCase.name)"}]},"session_id":S})
                e({"type":"result","subtype":"success","is_error":False,"result":"DONE_\(testCase.name)","session_id":S})
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
                prompt: testCase.name
            )) { event in
                Task { await sink.record(event) }
            }
            try await waitForFinish(in: sink, expected: "DONE_\(testCase.name)")
            let events = await sink.snapshot()
            let finishes = Self.finishedPairs(events)
            XCTAssertEqual(finishes.count, 1, "\(testCase.name): exactly one finished")
            XCTAssertEqual(finishes.first?.1, "DONE_\(testCase.name)",
                           "\(testCase.name): must not stamp [[RC_AWAITING]] on non-detaching / wait-blocked Bash")
            try? adapter.stopSession(threadId: threadId)
        }
    }

    func test_bashCommandDetachesShellWork_classifier() {
        // Pure string cases for the detach detector used by trackDetachedShellSpawn.
        XCTAssertTrue(ClaudeStreamingCLIAdapter.bashCommandDetachesShellWork("cmd &"),
                      "trailing & backgrounds")
        XCTAssertTrue(ClaudeStreamingCLIAdapter.bashCommandDetachesShellWork("cmd &\nPID=$!"),
                      "background + capture PID")
        XCTAssertTrue(ClaudeStreamingCLIAdapter.bashCommandDetachesShellWork("nohup cmd &"),
                      "nohup detaches")
        XCTAssertTrue(ClaudeStreamingCLIAdapter.bashCommandDetachesShellWork("cmd 2>&1 &"),
                      "redirect then background &")
        XCTAssertFalse(ClaudeStreamingCLIAdapter.bashCommandDetachesShellWork("a && b"),
                       "&& is not background")
        XCTAssertFalse(ClaudeStreamingCLIAdapter.bashCommandDetachesShellWork("cmd > f 2>&1"),
                       "2>&1 alone is not background")
        XCTAssertFalse(ClaudeStreamingCLIAdapter.bashCommandDetachesShellWork("cmd & wait"),
                       "wait means the shell blocked on children")
        XCTAssertFalse(ClaudeStreamingCLIAdapter.bashCommandDetachesShellWork("ls -la"),
                       "plain foreground command")
    }

    // MARK: - CLAUDE-AMBIENT-TASK-RESULT (orphan task_notification empty run)

    /// WHY: Elephant Task 1 resume after a long CI wait failed twice with
    /// "Claude run completed without producing an assistant response". Wire:
    /// resume dumps orphaned task_notifications → result origin=task-notification
    /// num_turns=0 empty → process exits without processing the user prompt.
    /// Adapter must ignore ambient ownership and re-drive the prompt once.
    func test_ambientTaskNotificationExit_retriesPromptOnceAndCompletes() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-ambient-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let script = tmp.appendingPathComponent("fake-claude")
        let launchCount = tmp.appendingPathComponent("launch-count.txt")
        try """
        #!/usr/bin/env python3
        import json, pathlib, sys
        counter = pathlib.Path("\(launchCount.path)")
        n = int(counter.read_text()) if counter.exists() else 0
        n += 1
        counter.write_text(str(n))
        session = "ambient-retry-session"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        if n == 1:
            # First process: orphan dump then ambient result, then exit (mirrors live CLI).
            print(json.dumps({
                "type":"system","subtype":"task_notification","task_id":"orphan-1",
                "status":"stopped",
                "summary":"Orphaned by a previous Claude Code process exit and reported in an aggregate summary.",
                "session_id":session
            }), flush=True)
            for line in sys.stdin:
                if not line.strip():
                    continue
                print(json.dumps({
                    "type":"result","subtype":"success","is_error":False,"result":"",
                    "num_turns":0,"origin":{"kind":"task-notification"},
                    "session_id":session,
                    "usage":{"input_tokens":0,"output_tokens":0}
                }), flush=True)
                sys.exit(0)
        else:
            # Second process (retry): real answer for the re-driven prompt.
            for line in sys.stdin:
                if not line.strip():
                    continue
                print(json.dumps({
                    "type":"assistant",
                    "message":{"content":[{"type":"text","text":"AMBIENT_RETRY_OK"}]},
                    "session_id":session
                }), flush=True)
                print(json.dumps({
                    "type":"result","subtype":"success","is_error":False,
                    "result":"AMBIENT_RETRY_OK","session_id":session
                }), flush=True)
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
            prompt: "Did you finish?",
            providerThreadId: "ambient-retry-session"
        )) { event in
            Task { await sink.record(event) }
        }

        try await waitForFinish(in: sink, expected: "AMBIENT_RETRY_OK", timeout: 6)
        let launches = Int((try? String(contentsOf: launchCount, encoding: .utf8)) ?? "0") ?? 0
        XCTAssertEqual(launches, 2,
                       "ambient-only exit must re-spawn the CLI once with the same prompt")
        let events = await sink.snapshot()
        let finishes = events.compactMap { event -> (AgentRunStatus, String?)? in
            if case .finished(let status, let final, _) = event { return (status, final) }
            return nil
        }
        XCTAssertEqual(finishes.count, 1, "exactly one terminal finish for the logical turn")
        XCTAssertEqual(finishes.first?.0, .completed)
        XCTAssertEqual(finishes.first?.1, "AMBIENT_RETRY_OK")
        let sawRetryDiagnostic = events.contains {
            if case .event(.providerRuntime(let runtime)) = $0 {
                return runtime.method == "claude.session.ambient_task_retry"
            }
            return false
        }
        XCTAssertTrue(sawRetryDiagnostic,
                      "stream must surface ambient_task_retry so operators can see the respawn")
        try? adapter.stopSession(threadId: threadId)
    }

    /// Ambient result followed by a real answer in the SAME process must not
    /// finish early (SDK/bridge lifecycle ownership parity).
    func test_ambientTaskNotificationResult_sameProcessDoesNotFinishEarly() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-ambient-same-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/env python3
        import json, sys, time
        session = "ambient-same-session"
        print(json.dumps({"type":"system","subtype":"init","session_id":session}), flush=True)
        for line in sys.stdin:
            if not line.strip():
                continue
            print(json.dumps({
                "type":"system","subtype":"task_notification","task_id":"T-ambient",
                "status":"completed","session_id":session
            }), flush=True)
            print(json.dumps({
                "type":"result","subtype":"success","is_error":False,"result":"",
                "num_turns":0,"origin":{"kind":"task-notification"},
                "session_id":session,
                "usage":{"input_tokens":0,"output_tokens":0}
            }), flush=True)
            time.sleep(0.15)
            print(json.dumps({
                "type":"assistant",
                "message":{"content":[{"type":"text","text":"SAME_PROCESS_OK"}]},
                "session_id":session
            }), flush=True)
            print(json.dumps({
                "type":"result","subtype":"success","is_error":False,
                "result":"SAME_PROCESS_OK","session_id":session
            }), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "continue"
        )) { event in
            Task { await sink.record(event) }
        }

        try? await Task.sleep(nanoseconds: 80_000_000)
        let early = await sink.snapshot()
        let earlyFinishes = early.filter {
            if case .finished = $0 { return true }
            return false
        }
        XCTAssertEqual(earlyFinishes.count, 0,
                       "ambient task-notification result alone must not finish the run")

        try await waitForFinish(in: sink, expected: "SAME_PROCESS_OK", timeout: 4)
        let finishes = await sink.snapshot().compactMap { event -> String? in
            if case .finished(.completed, let final, _) = event { return final }
            return nil
        }
        XCTAssertEqual(finishes, ["SAME_PROCESS_OK"])
        adapter.stopAll()
    }

    private func waitForFinish(in sink: EventSink, expected: String) async throws {
        try await waitForFinish(in: sink, expected: expected, timeout: 3)
    }

    private func waitForFinish(in sink: EventSink, expected: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
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

    private static func assistantTexts(in events: [AssistantEvent]) -> [String] {
        events.compactMap {
            if case .itemDelta(_, let body, _, _) = $0 { return body }
            return nil
        }
    }

    private static func assistantTexts(in events: [AgentRunEvent]) -> [String] {
        events.compactMap {
            if case .event(.itemDelta(_, let body, _, _)) = $0 { return body }
            return nil
        }
    }
}

private actor EventSink {
    private var events: [AgentRunEvent] = []
    func record(_ event: AgentRunEvent) { events.append(event) }
    func snapshot() -> [AgentRunEvent] { events }
}

private final class LockedAgentRunEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentRunEvent] = []

    func record(_ event: AgentRunEvent) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [AgentRunEvent] {
        lock.withLock { events }
    }
}

/// Thread-safe accumulator for draining a child process's stdout off the main
/// thread while the test polls for markers.
private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ text: String) { lock.lock(); storage += text; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Runs the real ClaudeAgentSDKBridge.mjs node process with a fake
/// `@anthropic-ai/claude-agent-sdk` whose `query()` drives the bridge's
/// `canUseTool` callback for AskUserQuestion and echoes the returned permission
/// result as an `ASK_RESULT:<json>` assistant message. Lets tests assert the
/// AskUserQuestion routing + answer/cancel round-trip end to end.
private final class AskUserQuestionBridgeSession {
    let process: Process
    private let stdin: Pipe
    private let buffer = LockedString()
    private let stderrPipe = Pipe()
    private let reader: Thread

    init(node: String, packageRoot: URL) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-bridge-ask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("ClaudeAgentSDKBridge.mjs")
        try FileManager.default.copyItem(
            at: packageRoot.appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs"),
            to: bridge
        )
        let sdkModule = tmp.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk", isDirectory: true)
        try FileManager.default.createDirectory(at: sdkModule, withIntermediateDirectories: true)
        try #"{"type":"module","main":"index.js","version":"0.3.157"}"#.write(to: sdkModule.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try """
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query({ prompt, options }) {
          return (async function*() {
            yield { type: 'system', subtype: 'init', session_id: 'fake-aq' };
            const iterator = prompt[Symbol.asyncIterator]();
            await iterator.next();
            const input = { questions: [{ question: 'Which path?', header: 'Path', options: [{ label: 'Plan', description: 'Plan first' }, { label: 'Run', description: 'Run now' }], multiSelect: false }] };
            const result = await options.canUseTool('AskUserQuestion', input, { toolUseID: 'ask-real-1' });
            yield { type: 'assistant', message: { id: 'aq-turn', content: [{ type: 'text', text: 'ASK_RESULT:' + JSON.stringify(result) }] }, session_id: 'fake-aq' };
            yield { type: 'result', subtype: 'success', is_error: false, result: 'done', session_id: 'fake-aq' };
          })();
        }
        """.write(to: sdkModule.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        let zodModule = tmp.appendingPathComponent("node_modules/zod", isDirectory: true)
        try FileManager.default.createDirectory(at: zodModule, withIntermediateDirectories: true)
        try #"{"type":"module","main":"index.js"}"#.write(to: zodModule.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "export const z = {};\n".write(to: zodModule.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [bridge.path]
        process.currentDirectoryURL = tmp
        stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderrPipe
        let buffer = self.buffer
        let readerHandle = stdout.fileHandleForReading
        reader = Thread {
            while true {
                let chunk = readerHandle.availableData
                if chunk.isEmpty { break }
                buffer.append(String(decoding: chunk, as: UTF8.self))
            }
        }
        reader.stackSize = 1 << 20
        reader.start()
        try process.run()
    }

    func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        stdin.fileHandleForWriting.write(data)
        stdin.fileHandleForWriting.write(Data("\n".utf8))
    }

    @discardableResult
    func waitFor(_ marker: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if buffer.value.contains(marker) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    var output: String { buffer.value }

    /// Closes stdin, waits for exit, returns stderr text.
    func finish() -> String {
        try? send(["type": "rc_close"])
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        reader.cancel()
        return String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    static func packageRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
