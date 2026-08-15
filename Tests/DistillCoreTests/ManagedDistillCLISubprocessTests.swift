import Darwin
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

        // Codex and Grok use the global PATH wrapper rather than Claude's
        // PostToolUse hook. They still must discover an isolated workspace's
        // lease from the shared app-support contract alone.
        for provider in ["codex", "grok"] {
            var providerEnvironment = liveEnvironment
            providerEnvironment.removeValue(forKey: "REMOTE_CODE_DISTILL_STATE_PATH")
            providerEnvironment["REMOTE_CODE_AGENT_PROVIDER"] = provider
            let providerResult = try runProcess(
                binary,
                ["cli", "Did the build pass? Return PASS or FAIL only."],
                env: providerEnvironment,
                stdin: "build passed\n0 failures"
            )
            XCTAssertEqual(providerResult.code, 0, "\(provider) app-support lease lookup")
            XCTAssertTrue(
                providerResult.out.contains("PASS"),
                "\(provider) must reach Distill without a Claude-only state override; got: \(providerResult.out)"
            )
        }

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

    func test_realWrapper_claudeTaskCapture_preservesExactOriginalWithAndWithoutTerminalLF() async throws {
        // WHY: Claude 2.1.x captures top-level Bash stdout in a regular task
        // output file, so the old pipe-only terminal detector passed through raw
        // output and the later PostToolUse hook stored Claude's LF-trimmed text.
        // Exercise the built wrapper against that real capture topology and prove
        // retrieve returns the exact pre-Claude bytes in both termination cases.
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claude-wrapper-byte-exact-\(UUID().uuidString)", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let managedBin = root.appendingPathComponent("managed", isDirectory: true)
        let realBin = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let wrapper = managedBin.appendingPathComponent("swift")
        try FileManager.default.createSymbolicLink(at: wrapper, withDestinationURL: binary)
        let realSwift = realBin.appendingPathComponent("swift")
        try Data("#!/bin/sh\n/usr/bin/printf %s \"$RC_WRAP_FIXTURE\"\n".utf8).write(to: realSwift)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realSwift.path)

        let config = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: supportURL.path)
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: config,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore()
        )
        let ready = try await server.start()
        defer { server.stop() }

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: supportURL.path).run()
        SettingsStore(db: db).update { $0.tokenSaverEnabled = true }
        try SettingsRepository(db: db).set(
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
        try JSONSerialization.data(withJSONObject: [
            "base_url": ready.baseURL,
            "auth_token": "tok",
            "pid": ready.pid,
        ]).write(to: stateURL, options: .atomic)

        let workspaceCaptureID = "-wrapper-byte-exact-\(UUID().uuidString)"
        let sessionID = UUID().uuidString
        let captureDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("claude-\(getuid())", isDirectory: true)
            .appendingPathComponent(workspaceCaptureID, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(
                at: captureDirectory
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
            )
        }

        let baseEnvironment = [
            "PATH": "\(managedBin.path):\(realBin.path):/usr/bin:/bin",
            "REMOTE_CODE_DISTILL_STATE_PATH": stateURL.path,
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": supportURL.path,
            "REMOTE_CODE_AGENT_PROVIDER": "claude",
            "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace-wrapper",
            "RC_TOKEN_SAVER_PROJECT_ID": "project-wrapper",
            "RC_TOKEN_SAVER_THREAD_ID": "thread-wrapper",
            "RC_TOKEN_SAVER_ATTEMPT_ID": "attempt-wrapper",
        ]

        for hasTerminalLF in [false, true] {
            let mode = hasTerminalLF ? "with-lf" : "without-lf"
            var original = (1...320)
                .map { "diagnostic mode=\(mode) line=\($0) repeated local-only test output" }
                .joined(separator: "\n")
            original += "\nFINAL_SENTINEL mode=\(mode) count=320"
            if hasTerminalLF { original += "\n" }

            let captureURL = captureDirectory.appendingPathComponent("task-\(mode).output")
            FileManager.default.createFile(atPath: captureURL.path, contents: nil)
            let captureHandle = try FileHandle(forWritingTo: captureURL)
            let process = Process()
            process.executableURL = wrapper
            var environment = ProcessInfo.processInfo.environment
            baseEnvironment.forEach { environment[$0.key] = $0.value }
            environment["RC_WRAP_FIXTURE"] = original
            process.environment = environment
            process.standardOutput = captureHandle
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            try captureHandle.close()
            XCTAssertEqual(process.terminationStatus, 0)

            let emitted = try Data(contentsOf: captureURL)
            let emittedText = String(decoding: emitted, as: UTF8.self)
            XCTAssertLessThan(emitted.count, Data(original.utf8).count)
            let handle = try XCTUnwrap(Self.recoveryHandle(in: emittedText))
            let retrieved = try runProcessData(
                binary,
                ["cli", "retrieve", handle],
                env: baseEnvironment,
                stdin: Data()
            )
            XCTAssertEqual(retrieved.code, 0)
            XCTAssertEqual(
                retrieved.out,
                Data(original.utf8),
                "wrapper recovery must preserve the real terminal-LF state for \(mode)"
            )
        }
    }

    private static func recoveryHandle(in output: String) -> String? {
        guard let marker = output.range(of: "[[rc:", options: .backwards),
              let end = output.range(of: "]]", range: marker.upperBound..<output.endIndex) else {
            return nil
        }
        return String(output[marker.upperBound..<end.lowerBound])
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

    private func runProcessData(
        _ url: URL,
        _ args: [String],
        env: [String: String],
        stdin: Data
    ) throws -> (out: Data, code: Int32) {
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
        inPipe.fileHandleForWriting.write(stdin)
        inPipe.fileHandleForWriting.closeFile()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }
}
