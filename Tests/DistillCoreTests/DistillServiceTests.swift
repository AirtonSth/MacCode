import XCTest
@testable import DistillCore

final class DistillServiceTests: XCTestCase {
    private actor RecordingSuccessHandler {
        private var records: [DistillSavingsRecord] = []

        func record(request: DistillRequest, response: DistillResponse) {
            if let record = DistillSavingsCalculator.record(for: request, response: response) {
                records.append(record)
            }
        }

        func allRecords() -> [DistillSavingsRecord] {
            records
        }
    }

    func test_mlxRuntimeRequiresRealLocalModelFiles() async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2MissingMLXModel-\(UUID().uuidString)", isDirectory: true)

        do {
            _ = try await MLXDistillRuntime(modelDirectory: dir)
            XCTFail("production MLX runtime must fail loud when the verified local model directory is absent")
        } catch {
            XCTAssertFalse(String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func test_configurationRequiresApprovedMLXModelAndLocalhost() throws {
        XCTAssertThrowsError(try DistillServiceConfiguration(
            host: "0.0.0.0",
            authToken: "token",
            appSupportDirectory: "/tmp/remote-code"
        )) { error in
            XCTAssertEqual(error as? DistillServiceError, .unsupportedHost("0.0.0.0"))
        }

        XCTAssertThrowsError(try DistillServiceConfiguration(
            authToken: "token",
            appSupportDirectory: "/tmp/remote-code",
            runtime: "llama.cpp"
        )) { error in
            XCTAssertEqual(error as? DistillServiceError, .unsupportedRuntime("llama.cpp"))
        }

        XCTAssertThrowsError(try DistillServiceConfiguration(
            authToken: "token",
            appSupportDirectory: "/tmp/remote-code",
            modelID: "other/model",
            modelURL: "https://example.invalid/model"
        )) { error in
            XCTAssertEqual(
                error as? DistillServiceError,
                .unsupportedModel(modelID: "other/model", modelURL: "https://example.invalid/model")
            )
        }
    }

    func test_httpServerRequiresBearerTokenAndServesDistillRequests() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "secret-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 2
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }

        XCTAssertEqual(ready.event, "ready")
        XCTAssertEqual(ready.modelID, DistillApprovedModel.id)
        XCTAssertEqual(ready.runtime, DistillApprovedModel.runtime)
        XCTAssertGreaterThan(ready.port, 0)

        let unauth = try await response(baseURL: ready.baseURL, path: "/readyz")
        XCTAssertEqual(unauth.status, 401,
                       "sidecar endpoints that expose run data must reject missing bearer tokens")

        let request = DistillRequest(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            mode: .commandOutput,
            input: "build passed\n0 failures",
            question: "Did the build pass? Return PASS or FAIL only.",
            maxOutputCharacters: 200
        )
        let body = try JSONEncoder().encode(request)
        let distill = try await response(
            baseURL: ready.baseURL,
            path: "/v1/distill",
            method: "POST",
            token: "secret-token",
            body: body
        )
        XCTAssertEqual(distill.status, 200)
        let decoded = try JSONDecoder().decode(DistillResponse.self, from: distill.data)
        XCTAssertEqual(decoded.output, "PASS")
        XCTAssertEqual(decoded.requestID, request.id)

        let metrics = try await response(
            baseURL: ready.baseURL,
            path: "/metrics",
            token: "secret-token"
        )
        XCTAssertEqual(metrics.status, 200)
        let snapshot = try JSONDecoder().decode(DistillServiceMetrics.self, from: metrics.data)
        XCTAssertEqual(snapshot.totalRequests, 1)
        XCTAssertEqual(snapshot.successfulRequests, 1)
        XCTAssertEqual(snapshot.failedRequests, 0)
    }

    func test_httpServerSuccessHookReceivesCommandOutputSavingsRecord() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "record-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 2
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let recorder = RecordingSuccessHandler()
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler) { request, response in
            await recorder.record(request: request, response: response)
        }
        let ready = try await server.start()
        defer { server.stop() }

        let request = DistillRequest(
            mode: .commandOutput,
            input: "alpha.html\nnotes.txt\nbeta.html\n",
            question: "List existing HTML files, or NONE. Keep paths only.",
            provider: "codex",
            recordSavings: true,
            maxOutputCharacters: 200
        )
        let body = try JSONEncoder().encode(request)

        let distill = try await response(
            baseURL: ready.baseURL,
            path: "/v1/distill",
            method: "POST",
            token: "record-token",
            body: body
        )

        XCTAssertEqual(distill.status, 200)
        let records = await recorder.allRecords()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.provider, "codex")
        XCTAssertEqual(record.mode, "command-output")
        XCTAssertEqual(record.inputTokens, TokenEstimator.estimate(request.input),
                       "command-output savings record estimated tokens of the raw input, not its character length")
        XCTAssertEqual(record.outputTokens, TokenEstimator.estimate("alpha.html\nbeta.html"),
                       "command-output savings record estimated tokens of the distilled output, not its character length")
        XCTAssertEqual(record.savedTokens, max(TokenEstimator.estimate(request.input) - TokenEstimator.estimate("alpha.html\nbeta.html"), 0))
        XCTAssertNotEqual(record.inputTokens, request.input.count, "characters must never be recorded as tokens")
    }

    func test_clientCompressesViaServerAndReportsMeasuredSavings() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "client-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 4
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 4)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }

        let client = try XCTUnwrap(DistillServiceClient(ready: ready, authToken: "client-token"))
        let healthy = await client.isHealthy()
        XCTAssertTrue(healthy, "client must reach the unauthenticated health endpoint")

        let verbose = (1...40).map { "line \($0): verbose output to compress" }.joined(separator: "\n")
        let response = try await client.distill(DistillRequest(mode: .commandOutput, input: verbose, maxOutputCharacters: 4000))
        XCTAssertGreaterThan(response.savedTokens, 0, "the real client+server round-trip must yield measured savings")
        XCTAssertEqual(response.savedTokens, max(response.inputTokens - response.outputTokens, 0))

        // Wrong bearer token must surface as a loud, typed error (not silent).
        let badClient = DistillServiceClient(baseURL: URL(string: ready.baseURL)!, authToken: "wrong")
        do {
            _ = try await badClient.distill(DistillRequest(mode: .longText, input: "x"))
            XCTFail("client must throw on a rejected bearer token")
        } catch let DistillClientError.badStatus(code, _) {
            XCTAssertEqual(code, 401)
        }
    }

    // WHY: fallback frequency must be observable to know how often Token Saver degrades.
    // When DeadlineDistillRuntime fires the deterministic fallback it calls
    // metrics.recordFallback(); this test verifies the counter increments and
    // surfaces in /metrics, while total/success/failed are unaffected.
    func test_metricsRecorder_fallbackCounterIncrements_andAppearsInSnapshot() async {
        let recorder = DistillServiceMetricsRecorder()

        // baseline: all counters start at zero
        let empty = await recorder.snapshot(activeRequests: 0, maxConcurrentRequests: 8)
        XCTAssertEqual(empty.fallbackRequests, 0)
        XCTAssertEqual(empty.totalRequests, 0)
        XCTAssertEqual(empty.successfulRequests, 0)
        XCTAssertEqual(empty.failedRequests, 0)

        // record one request + one fallback (simulates deadline-exceeded path)
        await recorder.recordRequest()
        await recorder.recordFallback()

        let afterFallback = await recorder.snapshot(activeRequests: 1, maxConcurrentRequests: 8)
        XCTAssertEqual(afterFallback.fallbackRequests, 1,
                       "fallback counter must reflect every recordFallback() call")
        // success and failure counters must remain untouched by a fallback
        XCTAssertEqual(afterFallback.successfulRequests, 0,
                       "recordFallback must not alter successfulRequests")
        XCTAssertEqual(afterFallback.failedRequests, 0,
                       "recordFallback must not alter failedRequests")
        XCTAssertEqual(afterFallback.totalRequests, 1)

        // a second fallback increments to 2
        await recorder.recordFallback()
        let after2 = await recorder.snapshot(activeRequests: 0, maxConcurrentRequests: 8)
        XCTAssertEqual(after2.fallbackRequests, 2)

        // mixed: one success, one failure -- fallback stays at 2
        await recorder.recordSuccess()
        await recorder.recordFailure()
        let mixed = await recorder.snapshot(activeRequests: 0, maxConcurrentRequests: 8)
        XCTAssertEqual(mixed.fallbackRequests, 2,
                       "success/failure recordings must not alter fallbackRequests")
        XCTAssertEqual(mixed.successfulRequests, 1)
        XCTAssertEqual(mixed.failedRequests, 1)
    }

    // WHY: the JSON key "fallback_requests" must round-trip through Codable so
    // the /metrics endpoint exposes the counter to external observers.
    func test_metricsSnapshot_fallbackRequests_serializesWithSnakeCaseKey() throws {
        let metrics = DistillServiceMetrics(
            activeRequests: 0,
            totalRequests: 3,
            successfulRequests: 2,
            failedRequests: 0,
            fallbackRequests: 1,
            maxConcurrentRequests: 8
        )
        let data = try JSONEncoder().encode(metrics)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["fallback_requests"] as? Int, 1,
                       "fallback_requests must appear under its snake_case JSON key")
        // decode round-trip
        let decoded = try JSONDecoder().decode(DistillServiceMetrics.self, from: data)
        XCTAssertEqual(decoded, metrics)
    }

    private func response(
        baseURL: String,
        path: String,
        method: String = "GET",
        token: String? = nil,
        body: Data? = nil
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = method
        request.timeoutInterval = 3
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, data)
    }
}
