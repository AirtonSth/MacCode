import XCTest
import CoreModel
@testable import AgentRuntime

/// Regression (audit F44): during SDK provisioning the progress
/// readabilityHandler consumes npm's combined stdout+stderr stream to feed
/// NpmInstallProgressParser. On a non-zero exit the failure text used to be
/// only `readDataToEndOfFile()` — i.e. the undelivered TAIL, which is
/// typically empty because the handler had already drained the pipe — so the
/// user saw 'Claude Agent SDK package install failed: ' with no diagnostic.
/// The streamed chunks must be buffered and included in the failure text.
final class ClaudeSDKBridgeNpmInstallFailureTests: XCTestCase {

    func test_installFailureText_includesOutputAlreadyConsumedByTheProgressHandler() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-npm-install-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Fake npm: emits the diagnostic early (so the progress handler
        // consumes it), then fails. The trailing sleep guarantees the handler
        // has drained the pipe BEFORE exit — the exact shape in which the
        // pre-fix tail-only read returned an empty failure text.
        let fakeNpm = tmp.appendingPathComponent("fake-npm")
        try """
        #!/bin/sh
        echo "npm http fetch GET 404 https://registry.npmjs.org/@anthropic-ai%2fclaude-agent-sdk"
        echo "npm error code E404"
        echo "npm error 404 Not Found - @anthropic-ai/claude-agent-sdk@9.9.9 is not in this registry." 1>&2
        sleep 0.2
        exit 1
        """.write(to: fakeNpm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeNpm.path)

        let progressEvents = LockedProgressLog()
        let (process, outputPipe, outputBuffer) = try ClaudeAgentSDKBridgeAdapter.makeNpmInstallProcess(
            in: tmp,
            packageSpec: "@anthropic-ai/claude-agent-sdk@9.9.9",
            onProgress: { progressEvents.record($0) },
            npmBinary: fakeNpm.path
        )
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1, "sanity: the fake npm must fail")

        // Prove the handler really consumed the diagnostic (the condition the
        // fix exists for) before the failure text is assembled.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              !(String(data: outputBuffer.value, encoding: .utf8) ?? "").contains("E404") {
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Mirror installSDKPackage's terminationHandler: handler off, then text.
        outputPipe.fileHandleForReading.readabilityHandler = nil
        let text = ClaudeAgentSDKBridgeAdapter.npmInstallFailureText(buffered: outputBuffer, outputPipe: outputPipe)

        XCTAssertTrue(text.contains("E404"),
                      "the failure text must carry npm's real error even though the progress handler consumed the stream; got: '\(text)'")
        XCTAssertTrue(text.contains("404 Not Found"),
                      "stderr lines share the combined pipe and must be preserved too; got: '\(text)'")
        XCTAssertTrue(progressEvents.stages().contains("fetching"),
                      "buffering must not break progress parsing — the 'http fetch' line still maps to the fetching stage")
    }
}

private final class LockedProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentRunEvent] = []

    func record(_ event: AgentRunEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    func stages() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap { event in
            guard case .event(.providerRuntime(let runtime)) = event,
                  runtime.method == "rc_provisioning",
                  let data = runtime.payloadJSON.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return payload["stage"] as? String
        }
    }
}
