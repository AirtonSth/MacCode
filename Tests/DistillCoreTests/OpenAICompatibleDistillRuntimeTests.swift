import XCTest
@testable import DistillCore

final class OpenAICompatibleDistillRuntimeTests: XCTestCase {
    private actor SequencedReplies {
        private var replies: [String?]
        private(set) var callCount = 0

        init(_ replies: [String?]) {
            self.replies = replies
        }

        func next() -> String? {
            callCount += 1
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }

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
        XCTAssertEqual(staged.stage, .apiExternal)
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
        XCTAssertEqual(staged.stage, .apiExternal)
    }

    func test_schedulerRetriesAfterExternalAPIFailOpenInsteadOfCachingOriginal() async throws {
        // WHY: caching a byte-exact API fail-open masks recovery until the TTL
        // expires, so a transient first failure must not suppress the next call.
        let replies = SequencedReplies([
            nil,
            "Payment failed after retries; inspect Sources/Billing.swift:12."
        ])
        let runtime = OpenAICompatibleDistillRuntime(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model"
        ) { _, _, _, _ in
            await replies.next()
        }
        let scheduler = DistillScheduler(
            runtime: runtime,
            maxConcurrentRequests: 1,
            resultCacheTTLSeconds: 60,
            resultCacheCapacity: 8
        )
        let input = "Please explain the payment failure after retries at Sources/Billing.swift:12." +
            String(repeating: " Preserve every diagnostic detail.", count: 12)
        let request = DistillRequest(
            mode: .naturalLanguage,
            input: input,
            maxOutputCharacters: 128
        )

        let first = try await scheduler.submit(request)
        let second = try await scheduler.submit(request)

        XCTAssertEqual(first.output, request.input)
        XCTAssertEqual(first.routeStage, .apiExternal)
        XCTAssertNotEqual(second.output, request.input)
        XCTAssertEqual(second.routeStage, .apiExternal)
        let callCount = await replies.callCount
        XCTAssertEqual(callCount, 2)
    }

    func test_schedulerStillCachesUsefulExternalAPIOutput() async throws {
        let useful = "Payment failed after retries; inspect Sources/Billing.swift:12. " +
            String(repeating: "Keep this useful API detail. ", count: 12)
        let replies = SequencedReplies([
            useful,
            "unexpected second transport call"
        ])
        let runtime = OpenAICompatibleDistillRuntime(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model"
        ) { _, _, _, _ in
            await replies.next()
        }
        let scheduler = DistillScheduler(
            runtime: runtime,
            maxConcurrentRequests: 1,
            resultCacheTTLSeconds: 60,
            resultCacheCapacity: 8
        )
        let request = DistillRequest(
            mode: .naturalLanguage,
            input: "Please explain the payment failure after retries at Sources/Billing.swift:12.",
            maxOutputCharacters: 128
        )

        let first = try await scheduler.submit(request)
        let second = try await scheduler.submit(request)

        XCTAssertEqual(first.output, String(useful.prefix(request.maxOutputCharacters)))
        XCTAssertEqual(second.output, first.output)
        XCTAssertEqual(second.routeStage, .apiExternal)
        let callCount = await replies.callCount
        XCTAssertEqual(callCount, 1)
    }

    func test_warmupFailsLoudWhenAPIIsUnreachableUnauthorizedOrMalformed() async {
        let runtime = OpenAICompatibleDistillRuntime(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "bad-or-unreachable-model"
        ) { _, _, _, _ in nil }

        do {
            try await runtime.warmup()
            XCTFail("API helper must not publish ready after an unusable warmup response")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleDistillRuntimeError, .warmupFailed)
        }
    }

    func test_requestFailureStillFailsOpenAndReportsTypedFallback() async throws {
        actor Reasons {
            var values: [OpenAICompatibleFallbackReason] = []
            func append(_ value: OpenAICompatibleFallbackReason) { values.append(value) }
            func snapshot() -> [OpenAICompatibleFallbackReason] { values }
        }
        let reasons = Reasons()
        let runtime = OpenAICompatibleDistillRuntime(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "model",
            complete: { _, _, _, _ in nil },
            onFallback: { await reasons.append($0) }
        )
        let request = DistillRequest(mode: .naturalLanguage, input: "Preserve this original on API failure.")

        let staged = try await runtime.distillStaged(request)

        XCTAssertEqual(staged.output, request.input)
        XCTAssertEqual(staged.stage, .apiExternal)
        let recordedReasons = await reasons.snapshot()
        XCTAssertEqual(recordedReasons, [.requestFailed])
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

    func test_probeRejectsEmptyModelBeforeCallingGenerate() async {
        var called = false
        let outcome = await TokenSaverOpenAICompatibleProbe.run(
            baseURL: "http://127.0.0.1:8000/v1",
            model: "   ",
            token: "",
            complete: { _, _, _, _ in
                called = true
                return "pong"
            }
        )
        XCTAssertFalse(called)
        XCTAssertEqual(outcome, .failed("Enter the API model id used by your OpenAI-compatible server"))
    }

    func test_probeEmptyReplyIsActionableFailure() async {
        let outcome = await TokenSaverOpenAICompatibleProbe.run(
            baseURL: "http://127.0.0.1:8000/v1",
            model: "m",
            token: "",
            complete: { _, _, _, _ in nil }
        )
        guard case .failed(let reason) = outcome else {
            return XCTFail("empty generate must fail the probe")
        }
        XCTAssertTrue(reason.contains("127.0.0.1"), reason)
        XCTAssertTrue(reason.contains("URL"), reason)
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("local server"), reason)
    }
}
