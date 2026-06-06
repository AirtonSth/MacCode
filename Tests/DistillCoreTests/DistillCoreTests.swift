import XCTest
@testable import DistillCore

final class DistillCoreTests: XCTestCase {
    private actor BlockingRuntime: DistillRuntime {
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func distill(_ request: DistillRequest) async throws -> String {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
            return "S \(request.input)"
        }

        func releaseAll() {
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
        }

        var pendingCount: Int {
            continuations.count
        }
    }

    func test_schedulerRejectsEmptyInputBeforeRuntimeStarts() async throws {
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 1)

        do {
            _ = try await scheduler.submit(DistillRequest(mode: .longText, input: "   "))
            XCTFail("empty input must fail before the model/runtime receives work")
        } catch DistillError.emptyInput {
            let active = await scheduler.activeRequestCount
            XCTAssertEqual(active, 0)
        }
    }

    func test_schedulerEnforcesBoundedConcurrentRequests() async throws {
        let runtime = BlockingRuntime()
        let scheduler = DistillScheduler(runtime: runtime, maxConcurrentRequests: 1)
        let firstStarted = expectation(description: "first request admitted")

        let first = Task {
            firstStarted.fulfill()
            return try await scheduler.submit(DistillRequest(mode: .commandOutput, input: "one"))
        }
        await fulfillment(of: [firstStarted], timeout: 1.0)
        while await scheduler.activeRequestCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        do {
            _ = try await scheduler.submit(DistillRequest(mode: .commandOutput, input: "two"))
            XCTFail("a full scheduler must fail loudly instead of growing unbounded work")
        } catch DistillError.queueFull {
            let active = await scheduler.activeRequestCount
            XCTAssertEqual(active, 1)
        }

        await runtime.releaseAll()
        let response = try await first.value
        XCTAssertEqual(response.output, "S one")
        let active = await scheduler.activeRequestCount
        XCTAssertEqual(active, 0)
    }

    func test_schedulerQueuesUpToBoundedDepthForRecurrentRequests() async throws {
        let runtime = BlockingRuntime()
        let scheduler = DistillScheduler(runtime: runtime, maxConcurrentRequests: 1, maxQueueDepth: 1)

        let first = Task {
            try await scheduler.submit(DistillRequest(mode: .commandOutput, input: "first"))
        }
        while await runtime.pendingCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let second = Task {
            try await scheduler.submit(DistillRequest(mode: .commandOutput, input: "second"))
        }
        while await scheduler.queuedRequestCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        do {
            _ = try await scheduler.submit(DistillRequest(mode: .commandOutput, input: "third"))
            XCTFail("a bounded recurrent queue must fail loudly after maxQueueDepth is reached")
        } catch DistillError.queueFull {
            let active = await scheduler.activeRequestCount
            let queued = await scheduler.queuedRequestCount
            XCTAssertEqual(active, 1)
            XCTAssertEqual(queued, 1)
        }

        await runtime.releaseAll()
        _ = try await first.value
        while await runtime.pendingCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await runtime.releaseAll()
        _ = try await second.value

        let active = await scheduler.activeRequestCount
        let queued = await scheduler.queuedRequestCount
        XCTAssertEqual(active, 0)
        XCTAssertEqual(queued, 0)
    }

    func test_runtimeProducesDistillPrefixedOutput() async throws {
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let response = try await scheduler.submit(DistillRequest(
            mode: .commandOutput,
            input: "build passed\nwarnings zero",
            maxOutputCharacters: 200
        ))

        XCTAssertEqual(response.output, "O build passed\nO warnings zero",
                       "local runtime output should already follow the short distill line shape")
        XCTAssertEqual(response.inputCharacters, 26)
    }

    func test_mlxOutputCleanupRejectsHiddenThinkingAndPrefixDictionary() {
        let cleaned = MLXDistillRuntime.cleanOutput("<think>\nprivate\n</think>\nS=state, C=context")

        XCTAssertEqual(cleaned, "S=state, C=context")
        XCTAssertFalse(
            MLXDistillRuntime.isUsefulDistillOutput(cleaned),
            "MLX output must not expose hidden thinking or a prefix dictionary instead of compressed content"
        )
    }

    func test_mlxFallbackKeepsInputFactsWhenModelOutputIsInvalid() {
        let request = DistillRequest(
            mode: .longText,
            input: "RemoteCode Token Saver runs locally on macOS.\nIt preserves exact commands.",
            maxOutputCharacters: 180
        )

        let output = MLXDistillRuntime.fallbackOutput(for: request)

        XCTAssertEqual(
            output,
            "S RemoteCode Token Saver runs locally on macOS.\nS It preserves exact commands."
        )
        XCTAssertLessThanOrEqual(output.count, request.maxOutputCharacters)
    }
}
