import XCTest
@testable import DistillCore

final class MLXHotPathSafetyTests: XCTestCase {
    private struct SlowRuntime: DistillRuntime {
        let ms: UInt64
        func distill(_ request: DistillRequest) async throws -> String {
            try await Task.sleep(nanoseconds: ms * 1_000_000)
            return "SLOW"
        }
    }
    private struct ThrowingRuntime: DistillRuntime {
        struct Boom: Error {}
        func distill(_ request: DistillRequest) async throws -> String { throw Boom() }
    }
    private struct FastRuntime: DistillRuntime {
        func distill(_ request: DistillRequest) async throws -> String { "OK" }
    }

    private func req() -> DistillRequest { DistillRequest(mode: .longText, input: "compress me please") }

    // MARK: - Deadline + fail-open

    func test_deadlineExceeded_failsOpenToFallback_doesNotThrow() async throws {
        let runtime = DeadlineDistillRuntime(
            wrapping: SlowRuntime(ms: 3_000),
            deadlineMilliseconds: 50,
            fallback: { _ in "FALLBACK" }
        )
        let output = try await runtime.distill(req())
        XCTAssertEqual(output, "FALLBACK", "a stalled generation past the deadline must fail open, never block/throw")
    }

    func test_runtimeThrow_failsOpenToFallback() async throws {
        let runtime = DeadlineDistillRuntime(
            wrapping: ThrowingRuntime(),
            deadlineMilliseconds: 5_000,
            fallback: { _ in "FALLBACK" }
        )
        let output = try await runtime.distill(req())
        XCTAssertEqual(output, "FALLBACK")
    }

    func test_fastRuntime_passesThroughBeforeDeadline() async throws {
        let runtime = DeadlineDistillRuntime(
            wrapping: FastRuntime(),
            deadlineMilliseconds: 5_000,
            fallback: { _ in "FALLBACK" }
        )
        let output = try await runtime.distill(req())
        XCTAssertEqual(output, "OK", "a fast generation returns its real result, not the fallback")
    }

    // MARK: - Single GPU lane serialization

    private actor ConcurrencyProbe {
        private var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    func test_generationLaneSerializesToOneAtATime() async {
        let lane = MLXGenerationLane()
        let probe = ConcurrencyProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    await lane.acquire()
                    await probe.enter()
                    try? await Task.sleep(nanoseconds: 500_000)
                    await probe.leave()
                    await lane.release()
                }
            }
        }
        let peak = await probe.peak
        XCTAssertEqual(peak, 1, "the lane must admit at most one GPU generation at a time")
    }

    // MARK: - /readyz warmup gate

    func test_readyzReturns503UntilMarkedReady() async throws {
        let configuration = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: NSTemporaryDirectory())
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler, startsReady: false)
        let ready = try await server.start()
        defer { server.stop() }

        let before = try await http(ready.baseURL + "/readyz", token: "tok")
        XCTAssertEqual(before.status, 503, "cold model => /readyz 503 so callers never route to it")

        server.markReady()
        let after = try await http(ready.baseURL + "/readyz", token: "tok")
        XCTAssertEqual(after.status, 200, "after warmup, readiness flips to 200")
    }

    private func http(_ url: String, token: String? = nil) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 5
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, data)
    }
}
