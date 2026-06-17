import XCTest
@testable import DistillCore

private actor DistillCompressorSavingsBox {
    private var records: [DistillSavingsRecord] = []
    func append(_ record: DistillSavingsRecord) { records.append(record) }
    func snapshot() -> [DistillSavingsRecord] { records }
}

final class DistillCompressorTests: XCTestCase {
    func test_libraryCompressUsesStableInProcessAPI() async throws {
        let input = """
        {
          "status": "ok",
          "items": [1, 2, 3]
        }
        """
        let compressor = DistillCompressor(runtime: LocalDistillRuntime())

        let response = try await compressor.compress(input, mode: .longText)

        XCTAssertLessThan(response.output.count, input.count)
        XCTAssertEqual(response.runMode, .optimize)
        XCTAssertNil(response.auditReport)
    }

    func test_libraryCompressRecordsSavingsWhenReportWriterIsInjected() async throws {
        let input = """
        {
          "status": "ok",
          "items": [1, 2, 3, 4, 5],
          "message": "verbose payload that should be structurally compressed"
        }
        """
        let records = DistillCompressorSavingsBox()
        let compressor = DistillCompressor(
            runtime: LocalDistillRuntime(),
            savingsRecorder: { record in await records.append(record) }
        )

        let response = try await compressor.compress(input, mode: .longText, provider: "codex")
        let captured = await records.snapshot()

        let record = try XCTUnwrap(captured.first, "library compression must expose a savings record to the report writer")
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(record.provider, "codex")
        XCTAssertEqual(record.mode, "longText (deterministic)",
                       "the report row must include the compression engine that produced the saving")
        XCTAssertEqual(record.inputTokens, response.inputTokens)
        XCTAssertEqual(record.outputTokens, response.outputTokens)
        XCTAssertEqual(record.savedTokens, response.savedTokens)
        XCTAssertGreaterThan(record.savedTokens, 0)
    }

    func test_libraryCompressSupportsSimulateWithoutReplacingRawInput() async throws {
        let input = String(repeating: "verbose line\n", count: 80)
        let compressor = DistillCompressor(runtime: LocalDistillRuntime())

        let response = try await compressor.compress(input, mode: .longText, runMode: .simulate)

        XCTAssertEqual(response.output, input)
        XCTAssertEqual(response.runMode, .simulate)
        XCTAssertNotNil(response.auditReport)
    }

    func test_libraryCompressDoesNotRecordSavingsForSimulationRuns() async throws {
        let records = DistillCompressorSavingsBox()
        let compressor = DistillCompressor(
            runtime: LocalDistillRuntime(),
            savingsRecorder: { record in await records.append(record) }
        )

        _ = try await compressor.compress(
            String(repeating: "verbose line\n", count: 80),
            mode: .longText,
            provider: "claude",
            runMode: .simulate
        )

        let captured = await records.snapshot()
        XCTAssertTrue(captured.isEmpty,
                      "simulation/audit compression must not inflate the real Token Saver report")
    }

    func test_deployPolicyAllowsLibraryAndRetrieveOnlyMCP() {
        XCTAssertTrue(DistillDeployPolicy.decision(for: .library).allowed)
        XCTAssertTrue(DistillDeployPolicy.decision(for: .mcpRetrieveOnly).allowed)
    }

    func test_deployPolicyRejectsReverseProxyAndMCPCompress() {
        let cliWrap = DistillDeployPolicy.decision(for: .cliWrap)
        XCTAssertFalse(cliWrap.allowed)
        XCTAssertTrue(cliWrap.reason.contains("evaluation"))

        let proxy = DistillDeployPolicy.decision(for: .reverseProxy)
        XCTAssertFalse(proxy.allowed)
        XCTAssertTrue(proxy.reason.contains("cache"))

        let mcpCompress = DistillDeployPolicy.decision(for: .mcpCompress)
        XCTAssertFalse(mcpCompress.allowed)
        XCTAssertTrue(mcpCompress.reason.contains("retrieve-only"))
    }

    func test_noProviderBaseURLEnvironmentOverrideIsConfigured() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" || $0.pathExtension == "mjs" } ?? []

        let matches = try files.filter { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            return text.contains("ANTHROPIC_BASE_URL")
        }

        XCTAssertEqual(matches, [], "B6 is detection-only: Token Saver must not redirect providers through ANTHROPIC_BASE_URL")
    }
}
