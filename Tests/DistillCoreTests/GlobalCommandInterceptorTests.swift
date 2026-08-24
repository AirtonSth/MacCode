import CryptoKit
import XCTest
import CoreModel
@testable import DistillCore

final class GlobalCommandInterceptorTests: XCTestCase {
    private let noEnvironment: [String: String] = [:]

    func test_globalInterceptor_admitsArbitraryCommandNamesThroughTheSharedPolicy() {
        // WHY: an admitted provider must not lose Distill coverage merely because a
        // command is absent from RemoteCode's historical wrapper catalog.
        let command = "/opt/acme/bin/release-report"

        XCTAssertTrue(CommandWrapPolicy.isWrapped(command))
        XCTAssertNil(
            CommandWrapPolicy.passthroughReason(
                command: command,
                args: ["--summary"],
                environment: noEnvironment
            )
        )
        XCTAssertEqual(
            CommandWrapPolicy.decide(
                command: command,
                isTerminalToAgent: true,
                outputIsValidUTF8: true,
                byteCount: 4_000,
                lineCount: 80,
                environment: noEnvironment
            ),
            .compress
        )
    }

    func test_globalInterceptor_preservesExactOutputAndFailOpenSafetyBoundaries() {
        // WHY: widening admission must not make source slices, matches, binary
        // output, pipelines, or disabled Token Saver turns lossy.
        for exact in ["rg", "grep", "sed", "cat", "jq"] {
            XCTAssertTrue(CommandWrapPolicy.isWrapped(exact), "(exact) must enter the global interceptor")
            XCTAssertEqual(
                CommandWrapPolicy.passthroughReason(
                    command: exact,
                    args: [],
                    environment: noEnvironment
                ),
                "exact_output_command",
                "(exact) must preserve its complete stdout"
            )
        }

        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(
                command: "release-report",
                args: [],
                environment: ["REMOTE_CODE_WRAP_DISABLE": "1"]
            ),
            "disabled"
        )
        XCTAssertEqual(
            CommandWrapPolicy.decide(
                command: "release-report",
                isTerminalToAgent: false,
                outputIsValidUTF8: true,
                byteCount: 4_000,
                lineCount: 80,
                environment: noEnvironment
            ),
            .passthrough(reason: "not_terminal")
        )
        XCTAssertEqual(
            CommandWrapPolicy.decide(
                command: "release-report",
                isTerminalToAgent: true,
                outputIsValidUTF8: false,
                byteCount: 4_000,
                lineCount: 80,
                environment: noEnvironment
            ),
            .passthrough(reason: "binary_output")
        )
    }

    func test_globalInterceptor_argvWrapsArbitraryCommandsAndKeepsPipelineStreamsSeparate() {
        // WHY: Token Saver on every provider depends on the Distill sidecar
        // classifying PATH wrappers as wrap, not HTTP. Pipelines must inherit
        // streams so `swift test | grep` never sees mixed stderr.
        XCTAssertEqual(
            DistillServiceLaunch.argvMode(
                programName: "workspace-report",
                arguments: ["--summary"]
            ),
            .wrap(command: "workspace-report", arguments: ["--summary"])
        )
        XCTAssertEqual(
            DistillServiceLaunch.argvMode(programName: "swift", arguments: ["test"]),
            .wrap(command: "swift", arguments: ["test"])
        )
        XCTAssertEqual(
            DistillServiceLaunch.argvMode(programName: "rg", arguments: ["pattern"]),
            .wrap(command: "rg", arguments: ["pattern"])
        )
        XCTAssertEqual(
            DistillServiceLaunch.argvMode(
                programName: "node",
                arguments: ["/opt/homebrew/bin/codex", "app-server"]
            ),
            .passthrough,
            "shebang interpreters must not become Distill HTTP or wrap"
        )

        XCTAssertEqual(
            CommandWrapPolicy.childStreams(
                command: "swift",
                args: ["test"],
                environment: noEnvironment,
                isTerminalToAgent: false
            ),
            .inheritAll,
            "mid-pipeline wrap must inherit stdout/stderr"
        )
        XCTAssertEqual(
            CommandWrapPolicy.childStreams(
                command: "swift",
                args: ["test"],
                environment: noEnvironment,
                isTerminalToAgent: true
            ),
            .captureSeparateStdoutAndStderr
        )

        let stdout = Data("ok\n".utf8)
        let stderr = Data("error: File.swift:1\n".utf8)
        let pipeline = CommandWrapPolicy.decide(
            command: "swift",
            isTerminalToAgent: false,
            outputIsValidUTF8: true,
            byteCount: 4_000,
            lineCount: 80,
            environment: noEnvironment
        )
        XCTAssertEqual(pipeline, .passthrough(reason: "not_terminal"))
        switch CommandWrapPolicy.capturedDelivery(action: pipeline, stdout: stdout, stderr: stderr) {
        case .passthrough(let out, let err):
            XCTAssertEqual(out, stdout)
            XCTAssertEqual(err, stderr)
        case .distill:
            XCTFail("pipeline interceptor must not Distill mixed streams")
        }
    }

    func test_globalInterceptor_emitsAppliedReceiptOnlyForNetShrunkProviderVisibleOutput() async throws {
        // WHY: the interceptor's success receipt is the provider-visible proof that
        // bytes changed; a transport response alone is not an applied Distill claim.
        let raw = Data((1...40).map {
            "build step \($0): compiler completed with artifact checksum \($0 * 17)\n"
        }.joined().utf8)
        let key = Data(repeating: 0x37, count: 32)
        let rootRunID = "123e4567-e89b-12d3-a456-426614174000"
        let response = try JSONEncoder().encode(
            DistillResponse(
                requestID: UUID(),
                output: "summary: build completed\n",
                inputCharacters: raw.count,
                originalHandle: "global-recovery-handle",
                routeStage: .deterministic
            )
        )
        let cli = ManagedDistillCLI(
            arguments: ["summarize the command output"],
            stdin: raw,
            state: .init(baseURL: "http://127.0.0.1:9", authToken: "token", receiptKey: key),
            rootRunID: rootRunID,
            provider: "codex"
        ) { _ in
            (response, 200)
        }

        let result = await cli.runResult()
        let emitted = String(decoding: result.stdout, as: UTF8.self)
        let marker = try XCTUnwrap(DistillAppliedReceipt.parseTrailingV2Marker(in: result.stdout))
        let prefix = result.stdout.prefix(marker.markerByteRange.lowerBound)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(emitted.contains("[[rc:global-recovery-handle]]"))
        XCTAssertTrue(DistillAppliedReceipt.containsMarker(emitted))
        XCTAssertLessThan(result.stdout.count, raw.count)
        XCTAssertTrue(
            DistillAppliedReceipt.verify(
                marker,
                rootRunID: rootRunID,
                payloadByteCount: prefix.count,
                payloadSHA256: Data(SHA256.hash(data: prefix)),
                key: key
            )
        )
    }
}
