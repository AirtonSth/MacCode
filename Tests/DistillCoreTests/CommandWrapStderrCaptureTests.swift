import XCTest
@testable import DistillCore

final class CommandWrapStderrCaptureTests: XCTestCase {
    private let noEnv: [String: String] = [:]

    func test_compressPathCapturesCombinedStdoutAndStderr() {
        // WHY: compiler/test tools write diagnostics to stderr. Compress-eligible
        // wraps must capture both streams on one Distill input or Token Saver never
        // sees the failure.
        for command in ["swift", "npm", "pytest"] {
            XCTAssertNil(
                CommandWrapPolicy.passthroughReason(command: command, args: [], environment: noEnv),
                "\(command) must stay compress-eligible"
            )
            XCTAssertEqual(
                CommandWrapPolicy.childStreams(command: command, args: [], environment: noEnv),
                .captureCombinedStdoutAndStderr,
                "\(command) must capture combined stdout+stderr"
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
                CommandWrapPolicy.childStreams(command: command, args: ["pattern"], environment: noEnv),
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
                CommandWrapPolicy.childStreams(command: command, args: args, environment: noEnv),
                .inheritAll
            )
        }

        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "git", args: ["diff"], environment: noEnv),
            "exact_patch_output"
        )
        XCTAssertEqual(
            CommandWrapPolicy.childStreams(command: "git", args: ["diff"], environment: noEnv),
            .inheritAll
        )

        let disabled: [String: String] = ["REMOTE_CODE_WRAP_DISABLE": "1"]
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "swift", args: ["test"], environment: disabled),
            "disabled"
        )
        XCTAssertEqual(
            CommandWrapPolicy.childStreams(command: "swift", args: ["test"], environment: disabled),
            .inheritAll
        )
    }

    func test_wrapRunnerSourceBindsStderrToCapturePipe() throws {
        // WHY: policy alone cannot Distill stderr-only diagnostics; the runner must
        // bind both child streams to the same capture pipe on the compress path.
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
            source.contains("standardError = outPipe"),
            "compress capture path must assign standardError to the capture pipe (outPipe)"
        )
        XCTAssertTrue(
            source.contains("standardOutput = outPipe"),
            "compress capture path must bind stdout to the same capture pipe as stderr"
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
