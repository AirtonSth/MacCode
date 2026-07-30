import XCTest
import CoreModel
import Persistence
@testable import DistillCore

/// End-to-end proof of the NATIVE CLI: runs the actually-built RemoteCodeDistillService
/// binary in `cli` mode as a subprocess against a live in-process sidecar. Proves both
/// the success path and the fail-open (no-data-loss) contract on the real artifact.
final class ManagedDistillCLISubprocessTests: XCTestCase {
    private func builtBinary() -> URL? {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            ".build/debug/RemoteCodeDistillService",
            ".build/arm64-apple-macosx/debug/RemoteCodeDistillService",
            ".build/x86_64-apple-macosx/debug/RemoteCodeDistillService",
        ].map { URL(fileURLWithPath: cwd).appendingPathComponent($0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func test_realCLIBinary_compressesViaSidecar_andFailsOpen() async throws {
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let config = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: NSTemporaryDirectory())
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: config,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore()
        )
        let ready = try await server.start()
        defer { server.stop() }

        let supportURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("managed-distill-live-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: supportURL.path).run()
        let settings = SettingsStore(db: db)
        settings.update { $0.tokenSaverEnabled = true }
        let settingsRepository = SettingsRepository(db: db)
        try settingsRepository.set(
            "private.account.session",
            #"{"user":{"subscribed":true}}"#
        )
        let stateURL = supportURL
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stateJSON: [String: Any] = [
            "base_url": ready.baseURL,
            "auth_token": "tok",
            "pid": ready.pid,
        ]
        try JSONSerialization.data(withJSONObject: stateJSON).write(to: stateURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let liveEnvironment = [
            "REMOTE_CODE_DISTILL_STATE_PATH": stateURL.path,
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": supportURL.path,
            "REMOTE_CODE_AGENT_PROVIDER": "codex",
            "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace-subprocess",
            "RC_TOKEN_SAVER_PROJECT_ID": "project-subprocess",
            "RC_TOKEN_SAVER_THREAD_ID": "thread-subprocess",
            "RC_TOKEN_SAVER_ATTEMPT_ID": "attempt-subprocess"
        ]

        // Success: real binary compresses live tool output through the sidecar.
        let ok = try runProcess(
            binary,
            ["cli", "Did the build pass? Return PASS or FAIL only."],
            env: liveEnvironment,
            stdin: "build passed\n0 failures"
        )
        XCTAssertEqual(ok.code, 0)
        XCTAssertTrue(ok.out.contains("PASS"), "real CLI binary compressed via the live sidecar; got: \(ok.out)")

        // A stale env + state + installed symlink cannot override the live paid
        // setting. No request reaches the still-running sidecar.
        settings.update { $0.tokenSaverEnabled = false }
        let staleSymlink = supportURL.appendingPathComponent("stale-distill-link")
        try FileManager.default.createSymbolicLink(at: staleSymlink, withDestinationURL: binary)
        let off = try runProcess(
            staleSymlink,
            ["cli", "compress this"],
            env: liveEnvironment,
            stdin: "OFF BYTES MUST SURVIVE"
        )
        XCTAssertEqual(off.code, 0)
        XCTAssertEqual(off.out, "OFF BYTES MUST SURVIVE")

        // Entitlement is part of live admission, not merely the user's toggle.
        settings.update { $0.tokenSaverEnabled = true }
        try settingsRepository.set(
            "private.account.session",
            #"{"user":{"subscribed":false}}"#
        )
        let unsubscribed = try runProcess(
            binary,
            ["cli", "compress this"],
            env: liveEnvironment,
            stdin: "UNSUBSCRIBED BYTES MUST SURVIVE"
        )
        XCTAssertEqual(unsubscribed.code, 0)
        XCTAssertEqual(unsubscribed.out, "UNSUBSCRIBED BYTES MUST SURVIVE")

        // Teardown removes the live lease before the sidecar exits. Even with
        // enabled+subscribed DB state and stale inherited env, the CLI stays raw.
        try settingsRepository.set(
            "private.account.session",
            #"{"user":{"subscribed":true}}"#
        )
        try FileManager.default.removeItem(at: stateURL)
        let teardown = try runProcess(
            binary,
            ["cli", "compress this"],
            env: liveEnvironment,
            stdin: "TEARDOWN BYTES MUST SURVIVE"
        )
        XCTAssertEqual(teardown.code, 0)
        XCTAssertEqual(teardown.out, "TEARDOWN BYTES MUST SURVIVE")

        // Fail-open: point at a non-existent state file (no service) => exact
        // raw stdin, exit 0. This is the data-loss bug the Python CLI had.
        let failOpen = try runProcess(
            binary,
            ["cli", "compress this"],
            env: [
                "REMOTE_CODE_DISTILL_STATE_PATH": "/nonexistent/\(UUID().uuidString).json",
                "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": supportURL.path,
            ],
            stdin: "RAW DATA MUST SURVIVE"
        )
        XCTAssertEqual(failOpen.code, 0, "fail-open exits 0")
        XCTAssertEqual(failOpen.out, "RAW DATA MUST SURVIVE", "no service => raw stdin echoed verbatim, never lost")
    }

    private func runProcess(_ url: URL, _ args: [String], env: [String: String], stdin: String) throws -> (out: String, code: Int32) {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        process.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try process.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        inPipe.fileHandleForWriting.closeFile()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}
