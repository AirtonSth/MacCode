import XCTest
@testable import DistillCore

final class OpenAICompatibleDistillRuntimeTests: XCTestCase {
    func test_httpSuccessReturnsModelOutput() async throws {
        let runtime = OpenAICompatibleDistillRuntime(
            baseURL: URL(string: "http://127.0.0.1:9/v1")!,
            model: "test-model"
        ) { _, _, _, _ in
            "ERROR payment failed at Sources/Billing.swift:12"
        }
        let request = DistillRequest(
            mode: .naturalLanguage,
            input: "Please briefly explain that payment failed at Sources/Billing.swift:12 after retries."
        )
        let staged = try await runtime.distillStaged(request)
        XCTAssertEqual(staged.stage, .llmMLX)
        XCTAssertTrue(staged.output.contains("payment failed"))
        XCTAssertNotEqual(staged.output, request.input)
    }

    func test_httpFailureFailsOpenToOriginal() async throws {
        let runtime = OpenAICompatibleDistillRuntime(
            baseURL: URL(string: "http://127.0.0.1:9/v1")!,
            model: "test-model"
        ) { _, _, _, _ in
            nil
        }
        let request = DistillRequest(
            mode: .naturalLanguage,
            input: "Please briefly explain that payment failed after retries."
        )
        let staged = try await runtime.distillStaged(request)
        XCTAssertEqual(staged.output, request.input)
        XCTAssertEqual(staged.stage, .llmMLX)
    }

    func test_probeRejectsInvalidURLWithoutCallingGenerate() async {
        var called = false
        let outcome = await TokenSaverOpenAICompatibleProbe.run(
            baseURL: "not-a-url",
            model: "m",
            token: "",
            complete: { _, _, _, _ in
                called = true
                return "pong"
            }
        )
        XCTAssertFalse(called)
        XCTAssertEqual(outcome, .failed("Enter a URL like http://127.0.0.1:8000/v1"))
    }

    func test_probeSuccessReportsHostAndModel() async {
        let outcome = await TokenSaverOpenAICompatibleProbe.run(
            baseURL: "http://127.0.0.1:8000/v1",
            model: "samuelfaj--distill-1.7B-4bit-MLX",
            token: "",
            complete: { _, _, _, _ in "pong" }
        )
        XCTAssertEqual(
            outcome,
            .ok(model: "samuelfaj--distill-1.7B-4bit-MLX", host: "127.0.0.1", preview: "pong")
        )
        XCTAssertEqual(outcome.message, "Reached samuelfaj--distill-1.7B-4bit-MLX at 127.0.0.1")
    }

    func test_probeEmptyReplyIsActionableFailure() async {
        let outcome = await TokenSaverOpenAICompatibleProbe.run(
            baseURL: "http://127.0.0.1:8000/v1",
            model: "",
            token: "",
            complete: { _, _, _, _ in nil }
        )
        guard case .failed(let reason) = outcome else {
            return XCTFail("empty generate must fail the probe")
        }
        XCTAssertTrue(reason.contains("127.0.0.1"), reason)
        XCTAssertTrue(reason.contains("URL"), reason)
    }
}
