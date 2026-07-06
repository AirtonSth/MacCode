import XCTest
import CoreModel
@testable import AgentRuntime

/// Regression tests for the Agent SDK bridge's stderr handling:
///
/// 1. Classification (audit F24): the bridge is a Node process, and Node prints
///    Deprecation warnings to stderr during perfectly healthy runs. Pre-fix the
///    adapter emitted EVERY non-empty stderr chunk as a fatal red
///    '[claude sdk stderr]' error, so a succeeding run showed a failure banner.
///    Stderr must pass the same ProviderStderrClassifier gate the streaming CLI
///    adapter uses.
/// 2. Exit-tail drain (audit F43): a bridge that dies instantly writes the only
///    explanation (auth error, missing module) to stderr; nil-ing the
///    readabilityHandler at termination does not wait for an in-flight callback,
///    so the bytes could sit undrained in the pipe and the failure reason was
///    lost. finishTerminated must drain the stderr tail like it drains stdout.
final class ClaudeSDKBridgeStderrTests: XCTestCase {

    // WHY: benign Node runtime noise must never render as a fatal agent error
    // during a run that is succeeding.
    func test_nodeDeprecationWarningOnStderr_isNotSurfacedAsAFatalError() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-stderr-noise")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        try Self.bridgeSource(onTurn: """
            process.stderr.write('(node:123) [DEP0040] DeprecationWarning: The punycode module is deprecated\\n', () => {
              write({ type: 'result', subtype: 'success', is_error: false, result: 'DONE', session_id: 'stderr-noise' });
            });
        """).write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = LockedEventSink()
        _ = try await adapter.sendTurn(Self.request(threadId: threadId, cwd: tmp.path)) { sink.record($0) }
        defer { try? adapter.stopSession(threadId: threadId) }

        try await Self.waitUntil("run finished") { sink.finishedStatus() != nil }
        // Give the async stderr readabilityHandler time to deliver the noise.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(sink.finishedStatus(), .completed, "sanity: the run itself succeeded")
        XCTAssertTrue(sink.errorMessages().isEmpty,
                      "a DeprecationWarning on the Node bridge's stderr must NOT become a fatal '[claude sdk stderr]' error banner; got: \(sink.errorMessages())")
        XCTAssertFalse(sink.hasStderrRuntimeEvent(containing: "DeprecationWarning"),
                       "filtered stderr noise must not be recorded as a stderr.fatal runtime event either")
    }

    // WHY: real stderr failures must still surface (the classifier gate must
    // not swallow everything), and when the process dies right after writing
    // them the exit-path drain is the only delivery guarantee.
    func test_bridgeDiesAfterStderrError_theReasonStillSurfacesAndTheRunFinishes() async throws {
        guard ProcessLocator.resolve("node") != nil else { throw XCTSkip("node not available") }
        let tmp = try Self.makeTempDir(prefix: "rc2-sdk-stderr-fatal")
        let bridge = tmp.appendingPathComponent("fake-sdk-bridge.mjs")
        try Self.bridgeSource(onTurn: """
            process.stderr.write('Error: Invalid API key. Please run /login\\n', () => process.exit(1));
        """).write(to: bridge, atomically: true, encoding: .utf8)

        let adapter = ClaudeAgentSDKBridgeAdapter(bridgeScriptPath: bridge.path)
        let threadId = AgentThreadID()
        let sink = LockedEventSink()
        _ = try await adapter.sendTurn(Self.request(threadId: threadId, cwd: tmp.path)) { sink.record($0) }
        defer { try? adapter.stopSession(threadId: threadId) }

        try await Self.waitUntil("stderr failure reason surfaced") {
            sink.errorMessages().contains { $0.contains("[claude sdk stderr]") && $0.contains("Invalid API key") }
        }
        try await Self.waitUntil("run finished") { sink.finishedStatus() != nil }
    }

    // MARK: - Helpers

    private static func request(threadId: AgentThreadID, cwd: String) -> AgentRunRequest {
        AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: cwd,
            prompt: "go"
        )
    }

    /// Fake bridge: init on rc_configure, injected behaviour on rc_turn.
    private static func bridgeSource(onTurn: String) -> String {
        """
        import readline from 'node:readline';
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        function write(obj) { process.stdout.write(JSON.stringify(obj) + '\\n'); }
        for await (const line of rl) {
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          if (cmd.type === 'rc_configure') {
            write({ type: 'system', subtype: 'init', session_id: 'stderr-session' });
          } else if (cmd.type === 'rc_turn') {
            \(onTurn)
          } else if (cmd.type === 'rc_close') {
            process.exit(0);
          }
        }
        """
    }

    private static func makeTempDir(prefix: String) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private static func waitUntil(_ what: String, timeout: TimeInterval = 5, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }
}

/// Synchronous locked sink: events are recorded on the emitting thread so the
/// wait loops observe them without Task-scheduling lag.
private final class LockedEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentRunEvent] = []

    func record(_ event: AgentRunEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    private func snapshot() -> [AgentRunEvent] {
        lock.lock(); defer { lock.unlock() }; return events
    }

    func finishedStatus() -> AgentRunStatus? {
        for event in snapshot() {
            if case .finished(let status, _, _) = event { return status }
        }
        return nil
    }

    func errorMessages() -> [String] {
        snapshot().compactMap { event in
            if case .error(let message) = event { return message }
            return nil
        }
    }

    func hasStderrRuntimeEvent(containing needle: String) -> Bool {
        snapshot().contains { event in
            if case .event(.providerRuntime(let runtime)) = event {
                return runtime.source == "claude.agent-sdk.stderr" && runtime.payloadJSON.contains(needle)
            }
            return false
        }
    }
}
