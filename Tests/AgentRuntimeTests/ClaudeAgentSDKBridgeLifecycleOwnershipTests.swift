import XCTest
import CoreModel
@testable import AgentRuntime

/// Generation-safe lifecycle ownership for the Claude Agent SDK bridge when the
/// raw stream can emit the same task/result records as the CLI (bridge
/// `emit(message)` pass-through).
final class ClaudeAgentSDKBridgeLifecycleOwnershipTests: ProviderProcessTestCase {

    /// Cancel A / start B / grace-fire must not let run A's timer kill run B.
    func test_interruptGrace_doesNotKillNewerRunGeneration() async throws {
        try skipUnlessLegacyClaudeIsSelectable()
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-interrupt-gen")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        try """
        import readline from 'node:readline';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        let turn = 0;
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-interrupt-gen' });
          } else if (cmd.type === 'rc_interrupt') {
            write({ type: 'assistant', message: { content: [{ type: 'text', text: 'A_INTERRUPTED' }] }, session_id: 'sdk-interrupt-gen' });
            write({ type: 'result', subtype: 'success', is_error: false, result: 'A_INTERRUPTED', session_id: 'sdk-interrupt-gen' });
          } else if (cmd.type === 'rc_turn') {
            turn += 1;
            if (turn === 1) {
              // Hang until interrupt; late A must not matter after B starts.
              await new Promise((r) => setTimeout(r, 2000));
              write({ type: 'assistant', message: { content: [{ type: 'text', text: 'A_LATE' }] }, session_id: 'sdk-interrupt-gen' });
              write({ type: 'result', subtype: 'success', is_error: false, result: 'A_LATE', session_id: 'sdk-interrupt-gen' });
            } else {
              write({ type: 'assistant', message: { content: [{ type: 'text', text: 'B_ANSWER' }] }, session_id: 'sdk-interrupt-gen' });
              write({ type: 'result', subtype: 'success', is_error: false, result: 'B_ANSWER', session_id: 'sdk-interrupt-gen' });
            }
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """.write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(
            bridgeScriptPath: bridge.path,
            interruptGracePeriod: 0.45
        )
        let threadId = AgentThreadID()
        let sinkA = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            runId: AgentRunID(),
            threadId: threadId,
            provider: .claude,
            model: "sonnet",
            cwd: tmp.path,
            prompt: "turn-a"
        )) { event in
            Task { await sinkA.record(event) }
        }

        try? await Task.sleep(nanoseconds: 80_000_000)
        try adapter.interruptTurn(threadId: threadId)

        let settleDeadline = Date().addingTimeInterval(2)
        while Date() < settleDeadline {
            let finished = await sinkA.snapshot().contains {
                if case .finished = $0 { return true }
                return false
            }
            if finished { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let sinkB = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            runId: AgentRunID(),
            threadId: threadId,
            provider: .claude,
            model: "sonnet",
            cwd: tmp.path,
            prompt: "turn-b",
            providerThreadId: "sdk-interrupt-gen"
        )) { event in
            Task { await sinkB.record(event) }
        }

        try? await Task.sleep(nanoseconds: 550_000_000)
        let bDeadline = Date().addingTimeInterval(3)
        var bFinished: (AgentRunStatus, String?)?
        while Date() < bDeadline {
            let pairs: [(AgentRunStatus, String?)] = await sinkB.snapshot().compactMap {
                if case .finished(let status, let final, _) = $0 { return (status, final) }
                return nil
            }
            if let first = pairs.first {
                bFinished = first
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(bFinished?.0, .completed,
                       "run A's interrupt grace must not kill run B")
        XCTAssertEqual(bFinished?.1, "B_ANSWER")
        try? adapter.stopSession(threadId: threadId)
    }

    /// When the bridge emits CLI-shaped task lifecycle records, early result
    /// defers; empty snapshot alone does not finish; later foreground result does.
    func test_backgroundTaskLifecycleOwnershipMatchesCLI() async throws {
        try skipUnlessLegacyClaudeIsSelectable()
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-bg-lifecycle")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        try """
        import readline from 'node:readline';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-bg' });
          } else if (cmd.type === 'rc_turn') {
            write({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'sleep 30', run_in_background: true } }] }, session_id: 'sdk-bg' });
            write({ type: 'system', subtype: 'background_tasks_changed', tasks: [{ task_id: 'T1', task_type: 'local_bash' }], session_id: 'sdk-bg' });
            write({ type: 'system', subtype: 'task_started', task_id: 'T1', task_type: 'local_bash', session_id: 'sdk-bg' });
            write({ type: 'assistant', message: { content: [{ type: 'text', text: 'PREMATURE_STANDING_BY' }] }, session_id: 'sdk-bg' });
            write({ type: 'result', subtype: 'success', is_error: false, result: 'PREMATURE_STANDING_BY', session_id: 'sdk-bg' });
            await sleep(150);
            write({ type: 'system', subtype: 'background_tasks_changed', tasks: [], session_id: 'sdk-bg' });
            await sleep(250);
            write({ type: 'assistant', message: { content: [{ type: 'text', text: 'REAL_ANSWER_AFTER_BG' }] }, session_id: 'sdk-bg' });
            write({ type: 'result', subtype: 'success', is_error: false, result: 'REAL_ANSWER_AFTER_BG', session_id: 'sdk-bg' });
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
            model: "sonnet",
            cwd: tmp.path,
            prompt: "bg"
        )) { event in
            Task { await sink.record(event) }
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        let mid = await sink.snapshot()
        XCTAssertEqual(Self.finishedPairs(mid).count, 0,
                       "empty task snapshot alone must not complete a deferred SDK run")

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let finishes = Self.finishedPairs(await sink.snapshot())
            if finishes.count == 1 { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let finishes = Self.finishedPairs(await sink.snapshot())
        XCTAssertEqual(finishes.count, 1)
        XCTAssertEqual(finishes.first?.1, "REAL_ANSWER_AFTER_BG")
        XCTAssertFalse(finishes.contains { $0.1 == "PREMATURE_STANDING_BY" })
        try? adapter.stopSession(threadId: threadId)
    }

    /// Ambient task_notification + zero-token result without assistant ownership
    /// must not green-finish the run.
    func test_ambientTaskNotificationResultDoesNotOwnLifecycle() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-ambient")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        try """
        import readline from 'node:readline';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-ambient' });
          } else if (cmd.type === 'rc_turn') {
            write({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 'x', content: 'stale' }] }, session_id: 'sdk-ambient' });
            write({ type: 'system', subtype: 'task_notification', task_id: 'T-ambient', status: 'completed', session_id: 'sdk-ambient' });
            write({ type: 'result', subtype: 'success', is_error: false, result: '', usage: { input_tokens: 0, output_tokens: 0 }, origin: { kind: 'task-notification' }, session_id: 'sdk-ambient' });
            await sleep(200);
            write({ type: 'assistant', message: { content: [{ type: 'text', text: 'REAL_FOREGROUND_ANSWER' }] }, session_id: 'sdk-ambient' });
            write({ type: 'result', subtype: 'success', is_error: false, result: 'REAL_FOREGROUND_ANSWER', session_id: 'sdk-ambient' });
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
            model: "sonnet",
            cwd: tmp.path,
            prompt: "continue"
        )) { event in
            Task { await sink.record(event) }
        }

        try? await Task.sleep(nanoseconds: 120_000_000)
        let earlySnapshot = await sink.snapshot()
        XCTAssertEqual(Self.finishedPairs(earlySnapshot).count, 0)

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if Self.finishedPairs(await sink.snapshot()).contains(where: { $0.1 == "REAL_FOREGROUND_ANSWER" }) {
                break
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let finishes = Self.finishedPairs(await sink.snapshot())
        XCTAssertEqual(finishes.count, 1)
        XCTAssertEqual(finishes.first?.1, "REAL_FOREGROUND_ANSWER")
        try? adapter.stopSession(threadId: threadId)
    }

    private static func finishedPairs(_ events: [AgentRunEvent]) -> [(AgentRunStatus, String?)] {
        events.compactMap {
            if case .finished(let status, let final, _) = $0 { return (status, final) }
            return nil
        }
    }

    private static func makeTempDir(prefix: String) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }
}

private actor EventSink {
    private var events: [AgentRunEvent] = []
    func record(_ event: AgentRunEvent) { events.append(event) }
    func snapshot() -> [AgentRunEvent] { events }
}
