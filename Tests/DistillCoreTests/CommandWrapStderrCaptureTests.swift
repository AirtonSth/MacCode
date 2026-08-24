import XCTest
@testable import DistillCore

final class CommandWrapStderrCaptureTests: XCTestCase {
    private let noEnv: [String: String] = [:]

    func test_compressPathCapturesCombinedStdoutAndStderr() {
        // WHY: compiler/test tools write diagnostics to stderr. Terminal
        // compress-eligible wraps capture both streams independently so Distill
        // can join them only after decide() returns compress.
        for command in ["swift", "npm", "pytest"] {
            XCTAssertNil(
                CommandWrapPolicy.passthroughReason(command: command, args: [], environment: noEnv),
                "\(command) must stay compress-eligible"
            )
            XCTAssertEqual(
                CommandWrapPolicy.childStreams(
                    command: command,
                    args: [],
                    environment: noEnv,
                    isTerminalToAgent: true
                ),
                .captureSeparateStdoutAndStderr,
                "\(command) terminal wrap must capture stdout and stderr independently"
            )
        }
    }

    func test_exactOutputAndDisabledInheritAllStreams() {
        // WHY: exact-output families and wrap-disable must keep stdin/stdout/stderr
        // inherited so agents still get full line lists, blob dumps, and patches.
        for command in ["rg", "grep", "cat", "sed", "jq"] {
            XCTAssertEqual(
                CommandWrapPolicy.passthroughReason(command: command, args: ["pattern"], environment: noEnv),
                "exact_output_command",
                "\(command) must remain exact-output"
            )
            XCTAssertEqual(
                CommandWrapPolicy.childStreams(
                    command: command,
                    args: ["pattern"],
                    environment: noEnv,
                    isTerminalToAgent: true
                ),
                .inheritAll,
                "\(command) must inherit all streams"
            )
        }

        let exactGit: [(String, [String])] = [
            ("git", ["show", "HEAD:file"]),
            ("git", ["grep", "foo"]),
            ("git", ["blame", "file"]),
        ]
        for (command, args) in exactGit {
            XCTAssertEqual(
                CommandWrapPolicy.passthroughReason(command: command, args: args, environment: noEnv),
                "exact_output_subcommand",
                "git \(args.joined(separator: " ")) must remain exact-output"
            )
            XCTAssertEqual(
                CommandWrapPolicy.childStreams(
                    command: command,
                    args: args,
                    environment: noEnv,
                    isTerminalToAgent: true
                ),
                .inheritAll
            )
        }

        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "git", args: ["diff"], environment: noEnv),
            "exact_patch_output"
        )
        XCTAssertEqual(
            CommandWrapPolicy.childStreams(
                command: "git",
                args: ["diff"],
                environment: noEnv,
                isTerminalToAgent: true
            ),
            .inheritAll
        )

        let disabled: [String: String] = ["REMOTE_CODE_WRAP_DISABLE": "1"]
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "swift", args: ["test"], environment: disabled),
            "disabled"
        )
        XCTAssertEqual(
            CommandWrapPolicy.childStreams(
                command: "swift",
                args: ["test"],
                environment: disabled,
                isTerminalToAgent: true
            ),
            .inheritAll
        )
    }

    func test_notTerminalAndBelowThresholdKeepStdoutAndStderrSeparate() {
        // WHY: `swift test | grep FAIL` is a wrap of swift that is not
        // terminal-to-agent. Mixing captured stderr into stdout would make grep
        // see compiler diagnostics. below_threshold and binary passthrough have
        // the same stream-identity contract after independent capture.
        let stdout = Data("ok\nPASS\n".utf8)
        let stderr = Data("warning: File.swift:12: unused; test must not mix\n".utf8)
        XCTAssertNotEqual(stdout, stderr)

        XCTAssertEqual(
            CommandWrapPolicy.childStreams(
                command: "swift",
                args: ["test"],
                environment: noEnv,
                isTerminalToAgent: false
            ),
            .inheritAll,
            "mid-pipeline wrap must inherit streams so grep sees stdout only"
        )

        let notTerminal = CommandWrapPolicy.decide(
            command: "swift",
            isTerminalToAgent: false,
            outputIsValidUTF8: true,
            byteCount: 4_000,
            lineCount: 80,
            environment: noEnv
        )
        XCTAssertEqual(notTerminal, .passthrough(reason: "not_terminal"))
        switch CommandWrapPolicy.capturedDelivery(action: notTerminal, stdout: stdout, stderr: stderr) {
        case .passthrough(let out, let err):
            XCTAssertEqual(out, stdout)
            XCTAssertEqual(err, stderr)
        case .distill:
            XCTFail("not_terminal must not Distill mixed stdout+stderr")
        }

        let smallCombined = CommandWrapPolicy.combinedDistillInput(stdout: stdout, stderr: stderr)
        XCTAssertLessThanOrEqual(smallCombined.count, CommandWrapPolicy.defaultMinBytes)
        let below = CommandWrapPolicy.decide(
            command: "swift",
            isTerminalToAgent: true,
            outputIsValidUTF8: true,
            byteCount: smallCombined.count,
            lineCount: 2,
            environment: noEnv
        )
        XCTAssertEqual(below, .passthrough(reason: "below_threshold"))
        switch CommandWrapPolicy.capturedDelivery(action: below, stdout: stdout, stderr: stderr) {
        case .passthrough(let out, let err):
            XCTAssertEqual(out, stdout)
            XCTAssertEqual(err, stderr)
        case .distill:
            XCTFail("below_threshold must emit original stdout and stderr separately")
        }

        let binary = CommandWrapPolicy.decide(
            command: "swift",
            isTerminalToAgent: true,
            outputIsValidUTF8: false,
            byteCount: 4_000,
            lineCount: 80,
            environment: noEnv
        )
        XCTAssertEqual(binary, .passthrough(reason: "binary_output"))
        switch CommandWrapPolicy.capturedDelivery(action: binary, stdout: stdout, stderr: stderr) {
        case .passthrough(let out, let err):
            XCTAssertEqual(out, stdout)
            XCTAssertEqual(err, stderr)
        case .distill:
            XCTFail("binary_output must emit original stdout and stderr separately")
        }
    }

    func test_compressActionDistillsCombinedStdoutAndStderr() {
        // WHY: only the admitted compress action may join streams into Distill
        // input. Unique tokens from each stream must both be present.
        let stdout = Data(String(repeating: "STDOUT_MARK build ok\n", count: 80).utf8)
        let stderr = Data("STDERR_MARK error: File.swift:12: value is not used\n".utf8)
        let combined = CommandWrapPolicy.combinedDistillInput(stdout: stdout, stderr: stderr)
        XCTAssertGreaterThan(combined.count, CommandWrapPolicy.defaultMinBytes)
        let action = CommandWrapPolicy.decide(
            command: "swift",
            isTerminalToAgent: true,
            outputIsValidUTF8: true,
            byteCount: combined.count,
            lineCount: 80,
            environment: noEnv
        )
        XCTAssertEqual(action, .compress)
        switch CommandWrapPolicy.capturedDelivery(action: action, stdout: stdout, stderr: stderr) {
        case .distill(let payload):
            XCTAssertEqual(payload, combined)
            let text = String(data: payload, encoding: .utf8)
            XCTAssertNotNil(text)
            XCTAssertTrue(text?.contains("STDOUT_MARK") == true)
            XCTAssertTrue(text?.contains("STDERR_MARK") == true)
        case .passthrough:
            XCTFail("terminal compress-eligible output must Distill joined streams")
        }
    }

    func test_wrapRunnerSourceBindsStderrToCapturePipe() throws {
        // WHY: CommandWrapRunner is an executable-only type; DistillCoreTests
        // cannot spawn it. The runner must still call the shipped policy:
        // independent pipes, capturedDelivery, STDERR on passthrough.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runnerURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("RemoteCodeDistillService")
            .appendingPathComponent("CommandWrapRunner.swift")
        let source = try String(contentsOf: runnerURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("CommandWrapPolicy.childStreams"),
            "CommandWrapRunner must call CommandWrapPolicy.childStreams rather than duplicating passthrough logic"
        )
        XCTAssertTrue(
            source.contains("isTerminalToAgent:"),
            "childStreams must receive WrapPipeInspector.isTerminalToAgent so pipelines inherit"
        )
        XCTAssertTrue(
            source.contains("let outPipe = Pipe()"),
            "compress capture path must have a stdout pipe"
        )
        XCTAssertTrue(
            source.contains("let errPipe = Pipe()"),
            "compress capture path must capture stderr on a separate pipe"
        )
        XCTAssertTrue(
            source.contains("process.standardOutput = outPipe"),
            "stdout must bind to outPipe"
        )
        XCTAssertTrue(
            source.contains("process.standardError = errPipe"),
            "stderr must bind to errPipe, not outPipe"
        )
        XCTAssertFalse(
            source.contains("standardError = outPipe"),
            "stderr must not share the stdout capture pipe (that mixed streams into pipelines)"
        )
        XCTAssertTrue(
            source.contains("CommandWrapPolicy.capturedDelivery"),
            "runner must Distill joined bytes only through capturedDelivery"
        )
        XCTAssertTrue(
            source.contains("STDERR_FILENO"),
            "passthrough must write original stderr to STDERR_FILENO"
        )
        XCTAssertTrue(
            source.contains("runInheritingAllStreams"),
            "passthrough path must still inherit all streams"
        )
    }

    func test_stderrDiagnosticsAreDistilledWhenAdmitted() async throws {
        // WHY: stderr-shaped compiler/test diagnostics that miss lossless/BERT
        // must still enter Distill once wrap capture has admitted them.
        let diagnostics = Self.stderrShapedDiagnostics()
        XCTAssertGreaterThan(diagnostics.utf8.count, CommandWrapPolicy.defaultMinBytes)
        XCTAssertGreaterThan(
            diagnostics.split(whereSeparator: \.isNewline).count,
            CommandWrapPolicy.defaultMinLines
        )
        XCTAssertTrue(diagnostics.contains("error"))
        XCTAssertTrue(diagnostics.contains("File.swift:12"))
        XCTAssertTrue(diagnostics.contains("not") || diagnostics.contains("failed"))

        let request = DistillRequest(mode: .commandOutput, input: diagnostics)
        XCTAssertNil(
            MLXDistillRuntime.deterministicCommandOutput(for: request),
            "fixture must miss deterministic intent extraction"
        )
        XCTAssertNil(
            DistillContentRouter().route(diagnostics, options: .losslessOnly),
            "fixture must miss lossless crushers so Distill is the admitted path"
        )

        let inner = StderrDiagnosticsRuntime()
        let runtime = EncoderFirstRuntime(wrapping: inner, encoderLane: nil)
        let output = try await runtime.distill(request)
        let invocations = await inner.invocations

        XCTAssertGreaterThanOrEqual(invocations, 1, "admitted stderr-shaped text must enter Distill")
        XCTAssertLessThanOrEqual(
            output.utf8.count,
            diagnostics.utf8.count,
            "Distill may shrink or fail open to the original"
        )
        XCTAssertTrue(output.contains("File.swift:12"), "file:line must survive Distill")
        XCTAssertTrue(
            output.localizedCaseInsensitiveContains("error")
                && (output.localizedCaseInsensitiveContains("not")
                    || output.localizedCaseInsensitiveContains("failed")),
            "salient diagnostic words must survive Distill"
        )
    }

    private static func stderrShapedDiagnostics() -> String {
        var lines: [String] = [
            "error: cannot find 'token' in scope",
            "File.swift:12:5: error: value of type 'Store' has no member 'load'; did you mean 'reload'?",
            "XCTAssertEqual failed: (\"yes\") is not (\"no\")",
            "test_login failed: expected session, not nil",
        ]
        for index in 0..<24 {
            lines.append(
                "padding unused context line \(index) " + String(repeating: "x", count: 48)
            )
        }
        return lines.joined(separator: "\n")
    }
}

/// Stand-in for the local LLM: shrinks while keeping file:line and salient words.
private actor StderrDiagnosticsRuntime: DistillRuntime {
    private(set) var invocations = 0

    func distill(_ request: DistillRequest) async throws -> String {
        invocations += 1
        let kept = request.input.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let text = String(line)
            return text.contains("File.swift:12")
                || text.localizedCaseInsensitiveContains("error")
                || text.localizedCaseInsensitiveContains("failed")
                || text.localizedCaseInsensitiveContains(" is not ")
        }
        let shrunk = kept.joined(separator: "\n")
        return shrunk.utf8.count < request.input.utf8.count ? shrunk : request.input
    }
}
