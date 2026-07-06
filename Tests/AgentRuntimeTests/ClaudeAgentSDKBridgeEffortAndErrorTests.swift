import XCTest
import CoreModel
@testable import AgentRuntime

/// Regression tests for two Agent SDK bridge gaps:
///
/// 1. Effort/ultracode plumbing (audit F0/F7): the SDK bridge is the DEFAULT
///    live Claude adapter, so if `rc_configure` drops `effort`/`settings` the
///    entire effort picker (and the whole Ultracode feature) is a silent no-op,
///    and since the SDK query has no live effort control a mid-thread effort
///    change must respawn the bridge session with resume.
/// 2. `sdk_error` termination (audit F2/F16): the bridge's query loop emits
///    `sdk_error` as its ONLY failure path. If it is dropped, no
///    `result`/`turnCompleted` ever arrives, the adapter never emits
///    `.finished`, and the run shows 'running' forever with no error text.
final class ClaudeAgentSDKBridgeEffortAndErrorTests: XCTestCase {

    // MARK: - ClaudeParser sdk_error (F2)

    // WHY: sdk_error means the SDK query died mid-turn — no `result` will follow.
    // The parser must both surface the error AND complete the active turn so the
    // adapter's turnCompleted teardown emits .finished(.failed) instead of
    // leaving the run stuck in 'running' until the user guesses to press Stop.
    func test_parser_sdkErrorMidTurn_emitsTerminalErrorAndCompletesTheActiveTurn() {
        let parser = ClaudeParser()
        _ = parser.parseLine(#"{"type":"system","subtype":"init","session_id":"s1"}"#)
        let turnEvents = parser.parseLine(#"{"type":"assistant","message":{"content":[{"type":"text","text":"partial answer"}]},"session_id":"s1"}"#)
        let turnId = turnEvents.compactMap { event -> String? in
            if case .turnStarted(let id) = event { return id }
            return nil
        }.first
        XCTAssertNotNil(turnId, "sanity: the assistant message must have opened a turn")

        let events = parser.parseLine(#"{"type":"sdk_error","message":"spawn claude ENOENT"}"#)

        let errors = events.compactMap { event -> (message: String, recoverable: Bool)? in
            if case .error(let message, let recoverable) = event { return (message, recoverable) }
            return nil
        }
        XCTAssertEqual(errors.first?.message, "spawn claude ENOENT",
                       "the bridge's error text must reach the timeline so the user sees WHY the run died")
        XCTAssertEqual(errors.first?.recoverable, false,
                       "sdk_error is terminal — a recoverable error would render a Retry that cannot work")

        let completed = events.compactMap { event -> String? in
            if case .turnCompleted(let id, _) = event { return id }
            return nil
        }
        XCTAssertEqual(completed, [turnId!],
                       "sdk_error must complete the ACTIVE turn: without turnCompleted the adapter never emits .finished and the run hangs in 'running'")
    }

    // WHY: the query can also die before any turn event was emitted (e.g. the
    // inner CLI spawn fails instantly). The run is already in-flight on the
    // Swift side, so the parser must synthesize a turn and complete it —
    // otherwise inFlightRunId is never cleared.
    func test_parser_sdkErrorWithoutActiveTurn_synthesizesAndCompletesATurn() {
        let parser = ClaudeParser()
        let events = parser.parseLine(#"{"type":"sdk_error","message":"Claude Code process exited with code 1"}"#)

        XCTAssertTrue(events.contains { event in
            if case .error(_, let recoverable) = event { return !recoverable }
            return false
        }, "the failure must surface as a terminal error even when no turn had started")
        XCTAssertTrue(events.contains { event in
            if case .turnStarted = event { return true }
            return false
        }, "a turn must be synthesized so the failure has a home in the transcript")
        XCTAssertTrue(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "the synthesized turn must complete so the adapter can finish the run as failed")
    }

    // MARK: - Adapter: rc_configure carries effort + settings (F0)

    // WHY: the SDK bridge is the production-default Claude adapter. If
    // rc_configure omits effort/settings, picking Ultracode (or any effort)
    // silently runs at the CLI default with no Workflow tool — the canonical
    // ClaudeRunner mapping (ultracode → xhigh + ultracode/enableWorkflows
    // settings) must reach the bridge verbatim.
    func test_rcConfigureCarriesUltracodeEffortAndSettings() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-effort-configure")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try Self.loggingFakeBridgeSource(sessionId: "sdk-effort-session").write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "first",
            reasoningEffort: .ultracode,
            extraArgs: [commandLog.path]
        )) { event in
            Task { await sink.record(event) }
        }
        try await waitForFinish(in: sink, expected: "DONE_1")
        defer { try? adapter.stopSession(threadId: threadId) }

        let configures = try Self.loggedCommands(at: commandLog, ofType: "rc_configure")
        XCTAssertEqual(configures.count, 1)
        XCTAssertEqual(configures.first?["effort"] as? String, "xhigh",
                       "ultracode must map to --effort xhigh on the SDK bridge exactly like ClaudeRunner.effortArgs does for the CLI")
        XCTAssertEqual(configures.first?["settings"] as? String, ClaudeRunner.ultracodeSettingsJSON,
                       "ultracode must carry the enableWorkflows settings payload — without it the Workflow tool is never exposed")
    }

    // MARK: - Adapter: effort change is a runtime switch (F7)

    // WHY: the SDK query has no live effort control (unlike rc_set_model /
    // rc_set_permission), so bumping Medium→Ultracode mid-thread must respawn
    // the bridge with the previous session id as the resume cursor — otherwise
    // the change is silently ignored for the rest of the session.
    func test_effortChangeRespawnsBridgeWithResume() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-effort-switch")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        let commandLog = tmp.appendingPathComponent("commands.jsonl")
        try Self.loggingFakeBridgeSource(sessionId: "sdk-effort-session").write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let first = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "first",
            reasoningEffort: .medium,
            extraArgs: [commandLog.path]
        )) { event in
            Task { await first.record(event) }
        }
        try await waitForFinish(in: first, expected: "DONE_1")

        // NOTE: no providerThreadId on the request — the adapter must stash the
        // live session id itself so the respawned bridge resumes the conversation.
        let second = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "second",
            reasoningEffort: .ultracode,
            extraArgs: [commandLog.path]
        )) { event in
            Task { await second.record(event) }
        }
        // A RESPAWNED bridge restarts its per-process turn counter at 1; a
        // (wrongly) reused bridge would answer DONE_2 and this wait would fail.
        try await waitForFinish(in: second, expected: "DONE_1")
        defer { try? adapter.stopSession(threadId: threadId) }

        let configures = try Self.loggedCommands(at: commandLog, ofType: "rc_configure")
        XCTAssertEqual(configures.count, 2,
                       "an effort change must respawn the bridge session (one rc_configure per spawn) — the SDK has no live effort control")
        XCTAssertEqual(configures.first?["effort"] as? String, "medium",
                       "the effort flag is never omitted: nil/medium map to 'medium', mirroring ClaudeRunner")
        XCTAssertEqual(configures.last?["effort"] as? String, "xhigh")
        XCTAssertEqual(configures.last?["settings"] as? String, ClaudeRunner.ultracodeSettingsJSON)
        XCTAssertEqual(configures.last?["provider_thread_id"] as? String, "sdk-effort-session",
                       "the respawned session must resume the previous provider thread so no conversation context is lost")
    }

    // MARK: - Adapter: sdk_error finishes the run as failed (F16)

    // WHY: when the bridge reports sdk_error the node process stays alive and no
    // result ever follows. The adapter must emit .finished(.failed) (clearing the
    // in-flight run) and surface the error — the pre-fix behavior left the thread
    // badge on 'running' forever with no explanation.
    func test_sdkErrorFailsTheRunInsteadOfHangingRunning() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-error-terminal")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        try """
        import readline from 'node:readline';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'sdk-error-session' });
          } else if (cmd.type === 'rc_turn') {
            write({ type: 'sdk_error', message: 'SDK exploded: spawn claude ENOENT' });
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
            prompt: "boom"
        )) { event in
            Task { await sink.record(event) }
        }
        defer { try? adapter.stopSession(threadId: threadId) }

        let deadline = Date().addingTimeInterval(3)
        var finishedStatus: AgentRunStatus?
        while Date() < deadline {
            let events = await sink.snapshot()
            if let status = events.compactMap({ event -> AgentRunStatus? in
                if case .finished(let status, _, _) = event { return status }
                return nil
            }).first {
                finishedStatus = status
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(finishedStatus, .failed,
                       "sdk_error must terminate the run as failed — without .finished the thread stays 'running' forever and queued messages never drain")

        let events = await sink.snapshot()
        XCTAssertTrue(events.contains { event in
            if case .event(.error(let message, let recoverable)) = event {
                return message.contains("SDK exploded") && !recoverable
            }
            return false
        }, "the sdk_error message must surface as a visible terminal error so the user sees why the run died")
    }

    // MARK: - Real bridge .mjs with a fake SDK (F0 + F16 bridge side)

    // WHY: the bridge must forward the host's effort and settings into the SDK
    // query options — storing them in rc_configure alone changes nothing if
    // query() never sees them.
    func test_bridgeForwardsEffortAndSettingsIntoQueryOptions() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let session = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query({ prompt, options }) {
          return (async function*() {
            const iterator = prompt[Symbol.asyncIterator]();
            await iterator.next();
            yield { type: 'assistant', message: { id: 'opt-1', content: [{ type: 'text', text: 'OPTIONS:' + JSON.stringify({ effort: options.effort ?? null, settings: options.settings ?? null }) }] }, session_id: 'fake-effort' };
            yield { type: 'result', subtype: 'success', is_error: false, result: 'done', session_id: 'fake-effort' };
          })();
        }
        """)
        defer { _ = session.finish() }

        try session.send([
            "type": "rc_configure",
            "cwd": NSTemporaryDirectory(),
            "model": "claude-haiku-4-5-20251001",
            "permission_mode": "supervised",
            "interaction_mode": "default",
            "provider_thread_id": "",
            "session_id": UUID().uuidString,
            "environment": [:],
            "effort": "xhigh",
            "settings": ClaudeRunner.ultracodeSettingsJSON
        ])
        try session.send(["type": "rc_turn", "prompt": "go"])

        XCTAssertTrue(session.waitFor("OPTIONS:"), "fake SDK never ran — bridge did not start the query. stderr: \(session.stderrText())")
        XCTAssertTrue(session.output.contains(#"\"effort\":\"xhigh\""#),
                      "query options must carry the effort from rc_configure — otherwise the effort picker is a no-op on the default adapter")
        XCTAssertTrue(session.output.contains("ultracode") && session.output.contains("enableWorkflows"),
                      "query options must carry the ultracode settings payload from rc_configure")
    }

    // WHY: after the query loop dies the bridge previously kept the dead
    // iterator as activeQuery, so every later rc_turn queued a prompt nothing
    // would ever consume. The bridge must reset its stream state so the thread
    // is recoverable after the host surfaces the failure.
    func test_bridgeRestartsQueryAfterSDKError() throws {
        guard let node = ProcessLocator.resolve("node") else { throw XCTSkip("node not available") }
        let session = try RealBridgeHarness(node: node, fakeSDKIndexJS: """
        let calls = 0;
        export function createSdkMcpServer() { return { instance: { server: {} } }; }
        export function tool(name, description, schema, handler) { return { name, description, schema, handler }; }
        export function query({ prompt, options }) {
          calls += 1;
          const n = calls;
          return (async function*() {
            const iterator = prompt[Symbol.asyncIterator]();
            await iterator.next();
            if (n === 1) { throw new Error('QUERY_DIED'); }
            yield { type: 'result', subtype: 'success', is_error: false, result: 'RECOVERED_' + n, session_id: 'fake-recover' };
          })();
        }
        """)
        defer { _ = session.finish() }

        try session.send([
            "type": "rc_configure",
            "cwd": NSTemporaryDirectory(),
            "model": "claude-haiku-4-5-20251001",
            "permission_mode": "supervised",
            "interaction_mode": "default",
            "provider_thread_id": "",
            "session_id": UUID().uuidString,
            "environment": [:]
        ])
        try session.send(["type": "rc_turn", "prompt": "one"])
        XCTAssertTrue(session.waitFor("QUERY_DIED"),
                      "the query failure must be emitted as sdk_error. stderr: \(session.stderrText())")
        XCTAssertTrue(session.output.contains(#""type":"sdk_error""#))

        try session.send(["type": "rc_turn", "prompt": "two"])
        XCTAssertTrue(session.waitFor("RECOVERED_2"),
                      "after sdk_error the bridge must start a FRESH query on the next rc_turn — a dead activeQuery would swallow the prompt forever. stderr: \(session.stderrText())")
    }

    // MARK: - Helpers

    private static func makeTempDir(prefix: String) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Fake bridge that appends every host command to argv[2] and answers
    /// rc_turn with init + result. The result counter is PER PROCESS, so a
    /// respawned bridge answers 'DONE_1' again while a reused one answers
    /// 'DONE_2' — letting tests distinguish reuse from respawn by reply text.
    private static func loggingFakeBridgeSource(sessionId: String) -> String {
        """
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
            write({ type: 'system', subtype: 'init', session_id: '\(sessionId)' });
          } else if (cmd.type === 'rc_turn') {
            turn += 1;
            write({ type: 'result', subtype: 'success', is_error: false, result: 'DONE_' + turn, session_id: '\(sessionId)' });
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """
    }

    private static func loggedCommands(at url: URL, ofType type: String) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return object
            }
            .filter { ($0["type"] as? String) == type }
    }

    private func waitForFinish(in sink: EventSink, expected: String) async throws {
        let deadline = Date().addingTimeInterval(5)
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
}

private actor EventSink {
    private var events: [AgentRunEvent] = []
    func record(_ event: AgentRunEvent) { events.append(event) }
    func snapshot() -> [AgentRunEvent] { events }
}

private final class LockedTextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    func append(_ text: String) { lock.lock(); storage += text; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Runs the REAL Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs under node with a
/// fake `@anthropic-ai/claude-agent-sdk` module so tests can drive the bridge's
/// query()/options plumbing end to end (same pattern as the AskUserQuestion
/// bridge harness in ClaudeStreamingCLIAdapterTests).
private final class RealBridgeHarness {
    let process: Process
    private let stdin: Pipe
    private let buffer = LockedTextBuffer()
    private let stderrBuffer = LockedTextBuffer()
    private let reader: Thread
    private let stderrReader: Thread

    init(node: String, fakeSDKIndexJS: String) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-sdk-bridge-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let bridge = tmp.appendingPathComponent("ClaudeAgentSDKBridge.mjs")
        try FileManager.default.copyItem(
            at: Self.packageRoot().appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs"),
            to: bridge
        )
        let sdkModule = tmp.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk", isDirectory: true)
        try FileManager.default.createDirectory(at: sdkModule, withIntermediateDirectories: true)
        try #"{"type":"module","main":"index.js"}"#.write(to: sdkModule.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try fakeSDKIndexJS.write(to: sdkModule.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
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
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let buffer = self.buffer
        let readerHandle = stdout.fileHandleForReading
        reader = Thread {
            while true {
                let chunk = readerHandle.availableData
                if chunk.isEmpty { break }
                buffer.append(String(decoding: chunk, as: UTF8.self))
            }
        }
        let stderrBuffer = self.stderrBuffer
        let stderrHandle = stderr.fileHandleForReading
        stderrReader = Thread {
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }
                stderrBuffer.append(String(decoding: chunk, as: UTF8.self))
            }
        }
        reader.stackSize = 1 << 20
        reader.start()
        stderrReader.stackSize = 1 << 20
        stderrReader.start()
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

    func stderrText() -> String { stderrBuffer.value }

    /// Closes stdin and waits for exit.
    func finish() -> Bool {
        try? send(["type": "rc_close"])
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        reader.cancel()
        stderrReader.cancel()
        return process.terminationStatus == 0
    }

    static func packageRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
