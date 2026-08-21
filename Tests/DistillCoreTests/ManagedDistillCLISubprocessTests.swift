import Darwin
import XCTest
import CoreModel
import Persistence
@testable import DistillCore

/// End-to-end proof of the native CLI and PATH wrapper: runs the actually-built
/// RemoteCodeDistillService against a live in-process sidecar. Proves both the
/// success path and the fail-open (no-data-loss) contract on the real artifact.
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

    func test_crossProvider_realCLIAndWrapperInvocationMatrix_receiptsOnlyForNetShrink() async throws {
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("managed-distill-matrix-\(UUID().uuidString)", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let managedBin = root.appendingPathComponent("managed", isDirectory: true)
        let realBin = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let distill = managedBin.appendingPathComponent("distill")
        try FileManager.default.createSymbolicLink(at: distill, withDestinationURL: binary)
        let wrapper = managedBin.appendingPathComponent("swift")
        try FileManager.default.createSymbolicLink(at: wrapper, withDestinationURL: binary)
        let realSwift = realBin.appendingPathComponent("swift")
        try Data("#!/bin/sh\nexec /bin/cat \"$RC_WRAP_FIXTURE_PATH\"\n".utf8).write(to: realSwift)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realSwift.path)

        // WHY: the applied receipt and recovery handle are part of provider-visible
        // output. A tiny PASS fixture no longer represents a real net saving.
        let fixtureText = (1...320)
            .map { "build passed stage=\($0) tests=48 failures=0 repeated local-only diagnostic output" }
            .joined(separator: "\n") + "\n"
        let fixture = Data(fixtureText.utf8)
        let fixtureURL = root.appendingPathComponent("build.log")
        try fixture.write(to: fixtureURL)

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

        let baseEnvironment = [
            "REMOTE_CODE_DISTILL_STATE_PATH": stateURL.path,
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": supportURL.path,
            "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace-subprocess",
            "RC_TOKEN_SAVER_PROJECT_ID": "project-subprocess",
            "RC_TOKEN_SAVER_THREAD_ID": "thread-subprocess",
            "RC_TOKEN_SAVER_ATTEMPT_ID": "attempt-subprocess",
            "RC_WRAP_FIXTURE_PATH": fixtureURL.path,
            "PATH": "\(managedBin.path):\(realBin.path):/usr/bin:/bin",
        ]
        let prompt = "Did the build pass? Return PASS or FAIL only."
        let shell = URL(fileURLWithPath: "/bin/sh")

        for provider in ["claude", "codex", "grok"] {
            var environment = baseEnvironment
            environment["REMOTE_CODE_AGENT_PROVIDER"] = provider

            // Actual direct CLI dispatch: argv[0] is the `distill` symlink, with
            // no synthetic leading `cli` argument.
            let direct = try runProcessData(
                distill,
                [prompt],
                env: environment,
                stdin: fixture
            )
            assertSingleAppliedReceiptAndNetShrink(direct, original: fixture, context: "\(provider) direct distill symlink")

            // Actual shell topology requested by the product contract: Distill is
            // the final pipe stage and receives the fixture through stdin.
            let finalPipe = try runProcessData(
                shell,
                ["-c", #"cat "$1" | distill "$2""#, "sh", fixtureURL.path, prompt],
                env: environment,
                stdin: Data()
            )
            assertSingleAppliedReceiptAndNetShrink(finalPipe, original: fixture, context: "\(provider) cat fixture | distill")

            // The shell must resolve the compressible command through the managed
            // PATH symlink; only the fake real `swift` executable owns the fixture.
            let globalWrapper = try runProcessData(
                shell,
                ["-c", "swift"],
                env: environment,
                removingEnv: ["REMOTE_CODE_DISTILL_STATE_PATH"],
                stdin: Data()
            )
            assertSingleAppliedReceiptAndNetShrink(globalWrapper, original: fixture, context: "\(provider) global PATH wrapper")

            // Explicit Distill remains opt-in even when the shell backgrounds the
            // pipeline and redirects its final output to a regular user file.
            let backgroundURL = root.appendingPathComponent("explicit-background-\(provider).txt")
            let background = try runProcessData(
                shell,
                [
                    "-c", #"cat "$1" | distill "$2" > "$3" & wait"#,
                    "sh", fixtureURL.path, prompt, backgroundURL.path,
                ],
                env: environment,
                stdin: Data()
            )
            let backgroundOutput = try Data(contentsOf: backgroundURL)
            assertSingleAppliedReceiptAndNetShrink(
                (backgroundOutput, background.code),
                original: fixture,
                context: "\(provider) explicit background redirect"
            )

            // A transparent global wrapper cannot reinterpret an ordinary user
            // redirect as provider transport, including when provider=claude.
            let redirectURL = root.appendingPathComponent("wrapper-user-redirect-\(provider).txt")
            let redirect = try runProcessData(
                shell,
                ["-c", #"swift > "$1""#, "sh", redirectURL.path],
                env: environment,
                removingEnv: ["REMOTE_CODE_DISTILL_STATE_PATH"],
                stdin: Data()
            )
            XCTAssertEqual(redirect.code, 0, "\(provider) ordinary wrapper redirect")
            assertByteExactWithoutAppliedReceipt(
                try Data(contentsOf: redirectURL),
                original: fixture,
                context: "\(provider) ordinary wrapper redirect"
            )
        }

        // A stale env + state + installed symlink cannot override the live paid
        // setting. No request reaches the still-running sidecar.
        settings.update { $0.tokenSaverEnabled = false }
        for provider in ["claude", "codex", "grok"] {
            var environment = baseEnvironment
            environment["REMOTE_CODE_AGENT_PROVIDER"] = provider
            let off = try runProcessData(distill, [prompt], env: environment, stdin: fixture)
            XCTAssertEqual(off.code, 0, "\(provider) Token Saver Off")
            assertByteExactWithoutAppliedReceipt(off.out, original: fixture, context: "\(provider) Token Saver Off")
        }

        // Entitlement is part of live admission, not merely the user's toggle.
        settings.update { $0.tokenSaverEnabled = true }
        try settingsRepository.set(
            "private.account.session",
            #"{"user":{"subscribed":false}}"#
        )
        for provider in ["claude", "codex", "grok"] {
            var environment = baseEnvironment
            environment["REMOTE_CODE_AGENT_PROVIDER"] = provider
            let unsubscribed = try runProcessData(distill, [prompt], env: environment, stdin: fixture)
            XCTAssertEqual(unsubscribed.code, 0, "\(provider) unsubscribed")
            assertByteExactWithoutAppliedReceipt(unsubscribed.out, original: fixture, context: "\(provider) unsubscribed")
        }

        // Teardown removes the live lease before the sidecar exits. Even with
        // enabled+subscribed DB state and stale inherited env, the CLI stays raw.
        try settingsRepository.set(
            "private.account.session",
            #"{"user":{"subscribed":true}}"#
        )
        try FileManager.default.removeItem(at: stateURL)
        for provider in ["claude", "codex", "grok"] {
            var environment = baseEnvironment
            environment["REMOTE_CODE_AGENT_PROVIDER"] = provider
            let teardown = try runProcessData(distill, [prompt], env: environment, stdin: fixture)
            XCTAssertEqual(teardown.code, 0, "\(provider) lease teardown")
            assertByteExactWithoutAppliedReceipt(teardown.out, original: fixture, context: "\(provider) lease teardown")
        }

        // Fail-open: point at a non-existent state file (no service) => exact
        // raw stdin, exit 0. This is the data-loss bug the Python CLI had.
        for provider in ["claude", "codex", "grok"] {
            let failOpen = try runProcessData(
                distill,
                [prompt],
                env: [
                    "REMOTE_CODE_AGENT_PROVIDER": provider,
                    "REMOTE_CODE_DISTILL_STATE_PATH": "/nonexistent/\(UUID().uuidString).json",
                    "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": supportURL.path,
                ],
                stdin: fixture
            )
            XCTAssertEqual(failOpen.code, 0, "\(provider) fail-open exits 0")
            assertByteExactWithoutAppliedReceipt(
                failOpen.out,
                original: fixture,
                context: "\(provider) missing service"
            )
        }
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

    private static let strictAppliedReceiptLineRegex = try! NSRegularExpression(
        pattern: #"(?m)^\[\[rcd:v1\.[A-Za-z0-9_-]{22}\]\]\r?$"#
    )

    private func assertSingleAppliedReceiptAndNetShrink(
        _ result: (out: Data, code: Int32),
        original: Data,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let emitted = String(decoding: result.out, as: UTF8.self)
        let range = NSRange(emitted.startIndex..<emitted.endIndex, in: emitted)
        XCTAssertEqual(result.code, 0, "\(context) exit", file: file, line: line)
        XCTAssertTrue(
            DistillAppliedReceipt.containsMarker(emitted),
            "\(context) must end in one strict applied receipt; got: \(emitted)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            Self.strictAppliedReceiptLineRegex.numberOfMatches(in: emitted, range: range),
            1,
            "\(context) must emit exactly one strict applied receipt",
            file: file,
            line: line
        )
        XCTAssertTrue(
            DistillAppliedReceipt.strip(emitted).lowercased().contains("pass"),
            "\(context) must preserve the fixture's passing verdict, not emit receipt-only output",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            result.out.count,
            original.count,
            "\(context) must shrink after receipt and recovery metadata",
            file: file,
            line: line
        )
        XCTAssertNotEqual(result.out, original, "\(context) must replace bytes", file: file, line: line)
    }

    private func assertByteExactWithoutAppliedReceipt(
        _ output: Data,
        original: Data,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let emitted = String(decoding: output, as: UTF8.self)
        let range = NSRange(emitted.startIndex..<emitted.endIndex, in: emitted)
        XCTAssertEqual(output, original, "\(context) must remain byte-exact", file: file, line: line)
        XCTAssertFalse(
            DistillAppliedReceipt.containsMarker(emitted),
            "\(context) must not claim applied distillation",
            file: file,
            line: line
        )
        XCTAssertEqual(
            Self.strictAppliedReceiptLineRegex.numberOfMatches(in: emitted, range: range),
            0,
            "\(context) must contain no strict applied receipt",
            file: file,
            line: line
        )
    }

    private func runProcessData(
        _ url: URL,
        _ args: [String],
        env: [String: String],
        removingEnv: Set<String> = [],
        stdin: Data
    ) throws -> (out: Data, code: Int32) {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        for key in removingEnv { environment.removeValue(forKey: key) }
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
