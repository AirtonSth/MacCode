import XCTest
@testable import DistillCore

final class DistillRunModeTests: XCTestCase {
    private struct FixedRuntime: DistillRuntime {
        let output: String
        func distill(_ request: DistillRequest) async throws -> String { output }
    }

    func test_auditModeReportsWouldSaveWithoutReplacingOutputOrRecordingSavings() async throws {
        let input = String(repeating: "verbose output line\n", count: 80)
        let candidate = "short summary"
        let scheduler = DistillScheduler(runtime: FixedRuntime(output: candidate), maxConcurrentRequests: 1)
        let request = DistillRequest(
            mode: .commandOutput,
            input: input,
            provider: "claude",
            recordSavings: true,
            runMode: .audit
        )

        let response = try await scheduler.submit(request)

        XCTAssertEqual(response.output, input, "AUDIT is measure-only and must not replace provider-visible text")
        XCTAssertEqual(response.outputTokens, response.inputTokens)
        XCTAssertEqual(response.runMode, .audit)
        XCTAssertEqual(response.auditReport?.runMode, .audit)
        XCTAssertEqual(response.auditReport?.candidateOutputCharacters, candidate.count)
        XCTAssertGreaterThan(response.auditReport?.wouldSaveTokens ?? 0, 0)
        XCTAssertNil(DistillSavingsCalculator.record(for: request, response: response))
    }

    func test_simulateModeAlsoKeepsRawOutputWithDryRunReport() async throws {
        let input = String(repeating: "raw line\n", count: 80)
        let scheduler = DistillScheduler(runtime: FixedRuntime(output: "compressed"), maxConcurrentRequests: 1)
        let request = DistillRequest(mode: .longText, input: input, runMode: .simulate)

        let response = try await scheduler.submit(request)

        XCTAssertEqual(response.output, input)
        XCTAssertEqual(response.runMode, .simulate)
        XCTAssertEqual(response.auditReport?.runMode, .simulate)
        XCTAssertTrue(response.auditReport?.accepted == true)
    }

    func test_optimizeModeKeepsExistingReplacementAndSavingsBehavior() async throws {
        let input = String(repeating: "raw line\n", count: 80)
        let scheduler = DistillScheduler(runtime: FixedRuntime(output: "compressed"), maxConcurrentRequests: 1)
        let request = DistillRequest(
            mode: .commandOutput,
            input: input,
            provider: "claude",
            recordSavings: true,
            runMode: .optimize
        )

        let response = try await scheduler.submit(request)

        XCTAssertEqual(response.output, "compressed")
        XCTAssertEqual(response.runMode, .optimize)
        XCTAssertNil(response.auditReport)
        XCTAssertNotNil(DistillSavingsCalculator.record(for: request, response: response))
    }

    func test_requestDecodingDefaultsMissingRunModeToOptimize() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "mode": "longText",
          "priority": 1,
          "input": "payload",
          "maxOutputCharacters": 4000
        }
        """
        let request = try JSONDecoder().decode(DistillRequest.self, from: Data(json.utf8))

        XCTAssertNil(request.runMode)
        XCTAssertEqual(request.effectiveRunMode, .optimize)
    }
}
