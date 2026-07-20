import XCTest
import CoreModel
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

    private struct FixedStatsProvider: DistillStatsProviding {
        let snapshot: DistillStatsSnapshot

        func statsSnapshot() throws -> DistillStatsSnapshot {
            snapshot
        }
    }

    func test_metricsDecodeLegacyPayloadDefaultsAdditiveFields() throws {
        let json = """
        {
          "active_requests": 1,
          "total_requests": 10,
          "successful_requests": 9,
          "failed_requests": 1,
          "max_concurrent_requests": 8
        }
        """.data(using: .utf8)!

        let metrics = try JSONDecoder().decode(DistillServiceMetrics.self, from: json)

        XCTAssertEqual(metrics.fallbackRequests, 0)
        XCTAssertEqual(metrics.cacheDriftWarnings, 0)
        XCTAssertEqual(metrics.encoderLaneInvocations, 0)
        XCTAssertEqual(metrics.resolvedWithoutLLMRate, 0)
        XCTAssertEqual(metrics.gateP95Millis, 0)
        XCTAssertEqual(metrics.toolOutputEligible, 0)
        XCTAssertEqual(metrics.toolOutputCompressed, 0)
        XCTAssertEqual(metrics.toolOutputSkippedOverCap, 0)
        XCTAssertEqual(metrics.toolOutputSkippedNoService, 0)
        XCTAssertEqual(metrics.toolOutputSkippedNotTerminal, 0)
    }

    func test_metricsRecorderReportsToolOutputHitRateAndBypassCounters() async {
        let recorder = DistillServiceMetricsRecorder()

        await recorder.recordToolOutputEligible()
        await recorder.recordToolOutputCompressed()
        await recorder.recordToolOutputSkipped(.overCap)
        await recorder.recordToolOutputSkipped(.noService)
        await recorder.recordToolOutputSkipped(.notTerminal)

        let snapshot = await recorder.snapshot(activeRequests: 0, maxConcurrentRequests: 2)

        XCTAssertEqual(snapshot.toolOutputEligible, 1)
        XCTAssertEqual(snapshot.toolOutputCompressed, 1)
        XCTAssertEqual(snapshot.toolOutputSkippedOverCap, 1)
        XCTAssertEqual(snapshot.toolOutputSkippedNoService, 1)
        XCTAssertEqual(snapshot.toolOutputSkippedNotTerminal, 1)
        XCTAssertEqual(snapshot.pipeHitRate, 1.0)
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

        // Both approved distill models must pass the configuration gate so the sidecar can be
        // launched pointing at either one. The qwen3 1.7B fallback:
        let compact = TokenSaverApprovedModels.distill17B
        let accepted = try DistillServiceConfiguration(
            authToken: "token",
            appSupportDirectory: "/tmp/remote-code",
            runtime: compact.runtime,
            modelID: compact.id,
            modelURL: compact.url
        )
        XCTAssertEqual(accepted.modelID, compact.id)

        // ...and the gemma4 E4B model, now loadable via RCGemma4ModelOverride and therefore
        // approved, must also be accepted (it was rejected while excluded from `all`).
        let e4b = TokenSaverApprovedModels.distillE4B
        let acceptedE4B = try DistillServiceConfiguration(
            authToken: "token",
            appSupportDirectory: "/tmp/remote-code",
            runtime: e4b.runtime,
            modelID: e4b.id,
            modelURL: e4b.url
        )
        XCTAssertEqual(acceptedE4B.modelID, e4b.id)
    }

    func test_httpServerRequiresBearerTokenAndServesDistillRequests() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "secret-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 2
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore()
        )
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
        XCTAssertEqual(snapshot.toolOutputEligible, 1)
        XCTAssertEqual(snapshot.toolOutputCompressed, 1)
        XCTAssertEqual(snapshot.pipeHitRate, 1.0)
    }

    func test_httpCompressAliasServesLocalCompressionWithoutProviderProxying() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "compress-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 1
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 1),
            scopedRecoveryStore: TestScopedRecoveryStore()
        )
        let ready = try await server.start()
        defer { server.stop() }

        let request = DistillRequest(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            mode: .commandOutput,
            input: "HTTP/1.1 provider body must not appear here\nbuild passed\n0 failures",
            question: "Did the build pass? Return PASS or FAIL only.",
            maxOutputCharacters: 200
        )
        let response = try await response(
            baseURL: ready.baseURL,
            path: "/v1/compress",
            method: "POST",
            token: "compress-token",
            body: try JSONEncoder().encode(request)
        )

        XCTAssertEqual(response.status, 200)
        let decoded = try JSONDecoder().decode(DistillResponse.self, from: response.data)
        XCTAssertEqual(decoded.output, "PASS")
    }

    func test_httpStatsEndpointReturnsSavingsLedgerSnapshot() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "stats-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 1
        )
        let stats = DistillStatsSnapshot(
            totalSavedTokens: 321,
            totalRuns: 4,
            providers: [DistillStatsProviderSavings(provider: "codex", savedTokens: 321, inputTokens: 900, outputTokens: 579, runs: 4)],
            modes: [DistillStatsModeSavings(provider: "codex", mode: "prompt", savedTokens: 321, runs: 4)]
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 1),
            statsProvider: FixedStatsProvider(snapshot: stats)
        )
        let ready = try await server.start()
        defer { server.stop() }

        let unauthorized = try await response(baseURL: ready.baseURL, path: "/v1/stats")
        XCTAssertEqual(unauthorized.status, 401, "stats exposes savings data and must require the bearer token")

        let authorized = try await response(baseURL: ready.baseURL, path: "/v1/stats", token: "stats-token")
        XCTAssertEqual(authorized.status, 200)
        let decoded = try JSONDecoder().decode(DistillStatsSnapshot.self, from: authorized.data)
        XCTAssertEqual(decoded, stats)
    }

    func test_httpRankAndEmbedExposeEncoderPrimitivesWithoutOverloadingDistill() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "encoder-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 1
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 1)
        )
        let ready = try await server.start()
        defer { server.stop() }

        let unauthorized = try await response(
            baseURL: ready.baseURL,
            path: "/v1/rank",
            method: "POST",
            body: try JSONEncoder().encode(DistillRankRequest(query: "auth failure", chunks: []))
        )
        XCTAssertEqual(unauthorized.status, 401, "encoder primitives expose prompt material and must require the bearer token")

        let rankRequest = DistillRankRequest(
            query: "auth failure",
            chunks: [
                DistillRankChunk(id: "noise", text: "render layout completed", contentType: .prose, position: 0),
                DistillRankChunk(id: "hit", text: "auth failure caused login error", contentType: .buildOutput, position: 1)
            ],
            toolArguments: "login",
            topK: 1,
            encoderLane: "colbert-shadow"
        )
        let ranked = try await response(
            baseURL: ready.baseURL,
            path: "/v1/rank",
            method: "POST",
            token: "encoder-token",
            body: try JSONEncoder().encode(rankRequest)
        )
        XCTAssertEqual(ranked.status, 200)
        let rankResponse = try JSONDecoder().decode(DistillRankResponse.self, from: ranked.data)
        XCTAssertEqual(rankResponse.encoderLane, "colbert-shadow")
        XCTAssertEqual(rankResponse.results.map(\.id), ["hit"],
                       "rank endpoint must expose deterministic BM25/content-type ranking while real encoder lanes remain optional")

        let embedded = try await response(
            baseURL: ready.baseURL,
            path: "/v1/embed",
            method: "POST",
            token: "encoder-token",
            body: try JSONEncoder().encode(DistillEmbedRequest(inputs: ["auth failure"], encoderLane: "modernbert"))
        )
        XCTAssertEqual(embedded.status, 200)
        let embedResponse = try JSONDecoder().decode(DistillEmbedResponse.self, from: embedded.data)
        XCTAssertFalse(embedResponse.available, "absent encoder runtime must fail open instead of returning fake vectors")
        XCTAssertEqual(embedResponse.encoderLane, "modernbert")
        XCTAssertEqual(embedResponse.embeddings, [])
    }

    func test_rankChunkDecodesLegacyPayloadWithDefaultContentType() throws {
        let data = Data(#"{"id":"auth","text":"authentication failed","position":1}"#.utf8)
        let chunk = try JSONDecoder().decode(DistillRankChunk.self, from: data)

        XCTAssertEqual(chunk.contentType, .prose,
                       "rank wire clients that omit additive contentType must keep the default prose ranking semantics")
        XCTAssertEqual(chunk.position, 1)
    }

    func test_clientRankAndEmbedUseDedicatedEndpoints() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "client-encoder-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 1
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 1)
        )
        let ready = try await server.start()
        defer { server.stop() }

        let client = try XCTUnwrap(DistillServiceClient(ready: ready, authToken: "client-encoder-token"))
        let rank = try await client.rank(DistillRankRequest(
            query: "database panic",
            chunks: [
                DistillRankChunk(id: "a", text: "database panic in migration", contentType: .buildOutput, position: 0),
                DistillRankChunk(id: "b", text: "all tests passed", contentType: .testReport, position: 1)
            ],
            topK: 1
        ))
        XCTAssertEqual(rank.results.first?.id, "a")

        let embed = try await client.embed(DistillEmbedRequest(inputs: ["database panic"], encoderLane: "modernbert"))
        XCTAssertFalse(embed.available)
        XCTAssertEqual(embed.embeddings.count, 0)
    }

    func test_httpServerSuccessHookReceivesCommandOutputSavingsRecord() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "record-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 2
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let recorder = RecordingSuccessHandler()
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore()
        ) { request, response in
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
        // Mode folds in the producing engine (deterministic test runtime) so the Token
        // Saver breakdown can attribute savings per technique.
        XCTAssertEqual(record.mode, "command-output (deterministic)")
        XCTAssertEqual(record.routeStage, .deterministic)
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
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore()
        )
        let ready = try await server.start()
        defer { server.stop() }

        let client = try XCTUnwrap(DistillServiceClient(ready: ready, authToken: "client-token"))
        let healthy = await client.isHealthy()
        XCTAssertTrue(healthy, "client must reach the unauthenticated health endpoint")

        let verbose = (1...40).map { "line \($0): verbose output to compress" }.joined(separator: "\n")
        let response = try await client.distill(
            DistillRequest(mode: .commandOutput, input: verbose, maxOutputCharacters: 4000),
            recoveryContext: testRecoveryContext()
        )
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
        XCTAssertEqual(empty.resultCacheHits, 0)
        XCTAssertEqual(empty.resultCacheMisses, 0)
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
            resultCacheHits: 4,
            resultCacheMisses: 5,
            systemPromptHash: "abc123",
            cacheDriftWarnings: 2,
            encoderLaneInvocations: 6,
            encoderLaneAccepts: 3,
            encoderLaneFallbacks: 2,
            encoderLaneFailures: 1,
            encoderLaneDeadlineTimeouts: 1,
            pipeHitRate: 0.25,
            maxConcurrentRequests: 8
        )
        let data = try JSONEncoder().encode(metrics)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["fallback_requests"] as? Int, 1,
                       "fallback_requests must appear under its snake_case JSON key")
        XCTAssertEqual(dict["result_cache_hits"] as? Int, 4,
                       "cache-hit telemetry must appear under its snake_case JSON key")
        XCTAssertEqual(dict["result_cache_misses"] as? Int, 5,
                       "cache-miss telemetry must appear under its snake_case JSON key")
        XCTAssertEqual(dict["volatile_token_warnings"] as? Int, 0,
                       "B6 warn-only cache-aligner telemetry must serialize under its snake_case JSON key")
        XCTAssertEqual(dict["system_prompt_hash"] as? String, "abc123",
                       "B6 cache-drift telemetry must expose the current prompt-contract hash")
        XCTAssertEqual(dict["cache_drift_warnings"] as? Int, 2,
                       "B6 cache-drift warnings must serialize under their snake_case JSON key")
        XCTAssertEqual(dict["encoder_lane_invocations"] as? Int, 6)
        XCTAssertEqual(dict["encoder_lane_accepts"] as? Int, 3)
        XCTAssertEqual(dict["encoder_lane_fallbacks"] as? Int, 2)
        XCTAssertEqual(dict["encoder_lane_failures"] as? Int, 1)
        XCTAssertEqual(dict["encoder_lane_deadline_timeouts"] as? Int, 1)
        XCTAssertEqual(dict["pipe_hit_rate"] as? Double, 0.25)
        // decode round-trip
        let decoded = try JSONDecoder().decode(DistillServiceMetrics.self, from: data)
        XCTAssertEqual(decoded, metrics)
    }

    func test_httpMetricsExposeVolatileTokenWarningsWithoutBlockingRequest() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "volatile-metrics-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 2
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore()
        )
        let ready = try await server.start()
        defer { server.stop() }

        let request = DistillRequest(
            mode: .commandOutput,
            input: "build id 7f8d2d3e-1234-4cde-8f90-abcdefabcdef at 2026-06-13T21:00:01Z",
            question: "Did token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature appear?",
            maxOutputCharacters: 200
        )
        let distillResponse = try await response(
            baseURL: ready.baseURL,
            path: "/v1/distill",
            method: "POST",
            token: "volatile-metrics-token",
            body: JSONEncoder().encode(request)
        )
        XCTAssertEqual(distillResponse.status, 200, "B6 is warn-only: volatile tokens must not block compression")

        let metrics = try await response(
            baseURL: ready.baseURL,
            path: "/metrics",
            token: "volatile-metrics-token"
        )
        let snapshot = try JSONDecoder().decode(DistillServiceMetrics.self, from: metrics.data)
        XCTAssertEqual(snapshot.volatileTokenWarnings, 3)
    }

    func test_httpMetricsExposeCacheDriftPromptHashWithoutBlockingRequest() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "cache-drift-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 2
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }

        let first = DistillRequest(
            mode: .commandOutput,
            input: "build passed",
            question: "Did it pass?",
            maxOutputCharacters: 200
        )
        let second = DistillRequest(
            mode: .commandOutput,
            input: "build failed",
            question: "Did it pass?",
            maxOutputCharacters: 200
        )
        let changed = DistillRequest(
            mode: .commandOutput,
            input: "build failed",
            question: "Did it fail?",
            maxOutputCharacters: 200
        )

        for request in [first, second, changed] {
            let distillResponse = try await response(
                baseURL: ready.baseURL,
                path: "/v1/distill",
                method: "POST",
                token: "cache-drift-token",
                body: JSONEncoder().encode(request)
            )
            XCTAssertEqual(distillResponse.status, 200, "B6 cache-drift telemetry is warn-only and must not block distill")
        }

        let metrics = try await response(
            baseURL: ready.baseURL,
            path: "/metrics",
            token: "cache-drift-token"
        )
        let snapshot = try JSONDecoder().decode(DistillServiceMetrics.self, from: metrics.data)
        XCTAssertEqual(snapshot.cacheDriftWarnings, 1)
        XCTAssertEqual(snapshot.systemPromptHash, CacheAlignerPromptContract.systemPromptHash(for: changed))
    }

    func test_httpMetricsExposeResultCacheHitAndMissCounts() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "cache-metrics-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 2
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore()
        )
        let ready = try await server.start()
        defer { server.stop() }

        let first = DistillRequest(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            mode: .commandOutput,
            input: "build passed\n0 failures",
            question: "Did the build pass? Return PASS or FAIL only.",
            maxOutputCharacters: 200
        )
        let second = DistillRequest(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            mode: .commandOutput,
            input: first.input,
            question: first.question,
            maxOutputCharacters: first.maxOutputCharacters
        )

        let firstResponse = try await response(
            baseURL: ready.baseURL,
            path: "/v1/distill",
            method: "POST",
            token: "cache-metrics-token",
            body: JSONEncoder().encode(first)
        )
        XCTAssertEqual(firstResponse.status, 200)
        let secondResponse = try await response(
            baseURL: ready.baseURL,
            path: "/v1/distill",
            method: "POST",
            token: "cache-metrics-token",
            body: JSONEncoder().encode(second)
        )
        XCTAssertEqual(secondResponse.status, 200)

        let metrics = try await response(
            baseURL: ready.baseURL,
            path: "/metrics",
            token: "cache-metrics-token"
        )
        let snapshot = try JSONDecoder().decode(DistillServiceMetrics.self, from: metrics.data)
        XCTAssertEqual(snapshot.totalRequests, 2)
        XCTAssertEqual(snapshot.successfulRequests, 2)
        XCTAssertEqual(snapshot.resultCacheMisses, 1,
                       "first identical request must be counted as a cache miss")
        XCTAssertEqual(snapshot.resultCacheHits, 1,
                       "second identical request must be counted as a cache hit")
    }

    // MARK: - Pre-auth buffer cap (OOM protection)

    // WHY: an unauthenticated client must not be able to exhaust heap by streaming
    // arbitrary bytes before completing a valid HTTP request. The cap applies only
    // while the bearer token has not yet been seen in the buffered header; authed
    // connections (large distill bodies) are never capped.

    func test_exceedsPreAuthCap_trueWhenUnauthAndOverCap() {
        // over cap, not authed -> must reject
        XCTAssertTrue(
            DistillHTTPServer.exceedsPreAuthCap(bufferCount: 65_537, headerAuthed: false, cap: 65_536),
            "unauthed connection with buffer > cap must be flagged for rejection"
        )
    }

    func test_exceedsPreAuthCap_falseWhenUnderCap() {
        // under cap, not authed -> buffering is fine
        XCTAssertFalse(
            DistillHTTPServer.exceedsPreAuthCap(bufferCount: 65_536, headerAuthed: false, cap: 65_536),
            "buffer exactly at cap must not be rejected"
        )
        XCTAssertFalse(
            DistillHTTPServer.exceedsPreAuthCap(bufferCount: 1_024, headerAuthed: false, cap: 65_536),
            "small pre-auth buffer must not be rejected"
        )
    }

    func test_exceedsPreAuthCap_falseWhenAuthedRegardlessOfSize() {
        // over cap but authed -> large legitimate body must not be capped
        XCTAssertFalse(
            DistillHTTPServer.exceedsPreAuthCap(bufferCount: 10_000_000, headerAuthed: true, cap: 65_536),
            "authed connection must never be rejected by the pre-auth cap, even with a 10 MB body"
        )
        XCTAssertFalse(
            DistillHTTPServer.exceedsPreAuthCap(bufferCount: 65_537, headerAuthed: true, cap: 65_536),
            "authed connection just over the cap boundary must not be rejected"
        )
    }

    func test_exceedsPreAuthCap_exactCapBoundary() {
        // boundary: count == cap+1 is the first rejection point
        XCTAssertFalse(
            DistillHTTPServer.exceedsPreAuthCap(bufferCount: 65_536, headerAuthed: false, cap: 65_536)
        )
        XCTAssertTrue(
            DistillHTTPServer.exceedsPreAuthCap(bufferCount: 65_537, headerAuthed: false, cap: 65_536)
        )
    }

    func test_declaredBodyExceedsLimit_usesContentLengthBoundary() {
        var raw = Data()
        raw.append(Data("POST /v1/distill HTTP/1.1\r\n".utf8))
        raw.append(Data("Authorization: Bearer t\r\n".utf8))
        raw.append(Data("Content-Length: 33\r\n\r\n".utf8))

        XCTAssertFalse(
            DistillHTTPServer.declaredBodyExceedsLimit(buffer: raw, cap: 33),
            "a request exactly at the body cap must be accepted so legitimate capped client payloads work"
        )
        XCTAssertTrue(
            DistillHTTPServer.declaredBodyExceedsLimit(buffer: raw, cap: 32),
            "the service must reject declared bodies above cap before buffering them"
        )
    }

    func test_httpServerRejectsOversizeDistillRequestBody() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "body-limit-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 2
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            requestBodyLimitBytes: 64
        )
        let ready = try await server.start()
        defer { server.stop() }

        let request = DistillRequest(mode: .commandOutput, input: String(repeating: "x", count: 128))
        let body = try JSONEncoder().encode(request)
        XCTAssertGreaterThan(body.count, 64, "fixture must exceed the injected service-side body cap")

        let response = try await response(
            baseURL: ready.baseURL,
            path: "/v1/distill",
            method: "POST",
            token: "body-limit-token",
            body: body
        )

        XCTAssertEqual(response.status, 413)
        let text = String(decoding: response.data, as: UTF8.self)
        XCTAssertTrue(text.contains("payload_too_large"),
                      "oversize requests must fail loud with a stable error code instead of reaching the scheduler")
    }

    // WHY: a live connection streaming > 64 KB before completing any HTTP headers
    // must be closed by the server, not buffered indefinitely.
    func test_serverClosesPreAuthConnectionExceedingCap() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "cap-test-token",
            appSupportDirectory: NSTemporaryDirectory()
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }

        // Send a raw TCP payload of 70 KB with no HTTP header terminator.
        // The server must close the connection once the cap is exceeded rather than
        // buffering forever.
        let port = ready.port
        let bigPayload = Data(repeating: UInt8(ascii: "X"), count: 70_000)

        let stream = try await Task<Bool, Error> {
            let session = URLSession(configuration: .ephemeral)
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/distill")!)
            req.httpMethod = "POST"
            req.httpBody = bigPayload
            // No Content-Length header and no Authorization -- simulates a raw
            // TCP client that has not yet finished sending headers.
            req.setValue("\(bigPayload.count)", forHTTPHeaderField: "Content-Length")
            req.timeoutInterval = 5
            do {
                _ = try await session.data(for: req)
                // Any response (401, 400, etc.) means the server handled it
                // correctly; connection was not held open indefinitely.
                return true
            } catch {
                // Network error = server closed the connection, also acceptable.
                return true
            }
        }.value

        XCTAssertTrue(stream, "server must not hang on a large pre-auth payload")
    }

    // WHY: the scan-offset optimisation must not change observable behaviour --
    // requestIsComplete must return the same answer whether scanning from 0 or a
    // non-zero offset that skips already-checked bytes.
    func test_requestIsComplete_offsetScanMatchesFullScan() throws {
        // Build a minimal HTTP POST with a small JSON body.
        let body = Data("{\"x\":1}".utf8)
        var raw = Data()
        raw.append(Data("POST /v1/distill HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8))
        raw.append(body)

        // Simulate receiving the request in two chunks and verify that scanning
        // from the mid-point offset produces the same answer as scanning from 0.
        let midOffset = raw.count / 2
        let partialFirst = raw[..<midOffset]
        let fullData = raw

        // Incomplete prefix: both scan strategies must return false.
        let server = try makeTestServer(token: "t")
        XCTAssertFalse(server.requestIsComplete(Data(partialFirst), from: 0))
        XCTAssertFalse(server.requestIsComplete(Data(partialFirst), from: max(0, midOffset - 10)))

        // Full buffer: both must return true regardless of offset.
        XCTAssertTrue(server.requestIsComplete(fullData, from: 0))
        XCTAssertTrue(server.requestIsComplete(fullData, from: midOffset))
    }

    func test_requestIsComplete_bodyContinuationOffsetStillFindsHeader() throws {
        let body = Data(String(repeating: "x", count: 70_000).utf8)
        var raw = Data()
        raw.append(Data("POST /v1/distill HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8))
        raw.append(body)

        let server = try makeTestServer(token: "t")
        let offsetAfterHeader = raw.count - body.count + 32_000

        XCTAssertTrue(
            server.requestIsComplete(raw, from: offsetAfterHeader),
            "large authed bodies can arrive after the header delimiter was already scanned; completion must still detect the buffered header"
        )
    }

    private func makeTestServer(token: String) throws -> DistillHTTPServer {
        let cfg = try DistillServiceConfiguration(
            authToken: token,
            appSupportDirectory: NSTemporaryDirectory()
        )
        return DistillHTTPServer(
            configuration: cfg,
            scheduler: DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 1)
        )
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
        if method == "POST", path == "/v1/distill" || path == "/v1/compress" {
            let context = testRecoveryContext()
            request.setValue(context.workspaceID, forHTTPHeaderField: "X-RemoteCode-Workspace-ID")
            request.setValue(context.projectID, forHTTPHeaderField: "X-RemoteCode-Project-ID")
            request.setValue(context.threadID, forHTTPHeaderField: "X-RemoteCode-Thread-ID")
            request.setValue(context.provider, forHTTPHeaderField: "X-RemoteCode-Provider")
            request.setValue(context.attemptID, forHTTPHeaderField: "X-RemoteCode-Attempt-ID")
            request.setValue(context.operationID, forHTTPHeaderField: "X-RemoteCode-Operation-ID")
            request.setValue(context.invocationID, forHTTPHeaderField: "X-RemoteCode-Invocation-ID")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, data)
    }

    // MARK: - DeadlineDistillRuntime fallback counter wiring

    // WHY: a permanently-cold MLX model returns the deterministic fallback on
    // every call, but prior to the onFallback hook those responses went through
    // the success path, so fallbackRequests stayed zero and the model's cold state
    // was undetectable via /metrics.  This test verifies that:
    //   (a) onFallback fires on the deadline-exceeded path (not the success path),
    //   (b) onFallback does NOT fire when the runtime succeeds within the deadline,
    //   (c) the shared metrics recorder passed to DistillHTTPServer reflects the
    //       fallback count via /metrics -- proving the full production wiring.
    func test_deadlineRuntime_onFallback_firesOnDeadlinePath_notOnSuccessPath() async throws {
        // Actor-safe counter: counts onFallback invocations.
        actor FallbackCounter {
            private(set) var count = 0
            func increment() { count += 1 }
        }
        let counter = FallbackCounter()

        // Runtime that never completes (simulates a permanently-cold model).
        struct InfiniteRuntime: DistillRuntime {
            func distill(_ request: DistillRequest) async throws -> String {
                // Block until cancelled (task group cancellation from deadline fire).
                try await Task.sleep(for: .seconds(60))
                return "unreachable"
            }
        }

        let runtime = DeadlineDistillRuntime(
            wrapping: InfiniteRuntime(),
            // 10 ms deadline so the test completes quickly without a real sleep.
            deadlineMilliseconds: 10,
            onFallback: { await counter.increment() }
        )

        // (a) deadline-exceeded path: onFallback must fire, result is the fallback string.
        let result = try await runtime.distill(
            DistillRequest(mode: .commandOutput, input: "some output", maxOutputCharacters: 200)
        )
        XCTAssertFalse(result.isEmpty,
                       "deadline fallback must return a non-empty deterministic result, not an empty string")
        let countAfterFallback = await counter.count
        XCTAssertEqual(countAfterFallback, 1,
                       "onFallback must fire exactly once when the deadline fires before the runtime finishes")

        // (b) success path: a fast runtime must NOT trigger onFallback.
        struct FastRuntime: DistillRuntime {
            func distill(_ request: DistillRequest) async throws -> String { "PASS" }
        }
        let fastRuntime = DeadlineDistillRuntime(
            wrapping: FastRuntime(),
            deadlineMilliseconds: 5_000,   // generous deadline -- fast runtime wins
            onFallback: { await counter.increment() }
        )
        _ = try await fastRuntime.distill(
            DistillRequest(mode: .commandOutput, input: "x", maxOutputCharacters: 200)
        )
        let countAfterSuccess = await counter.count
        XCTAssertEqual(countAfterSuccess, 1,
                       "onFallback must NOT fire when the runtime succeeds within the deadline")
    }

    // WHY: the full production wiring passes a shared DistillServiceMetricsRecorder
    // to both DeadlineDistillRuntime.onFallback and DistillHTTPServer (via
    // metricsRecorder:).  This test exercises that path end-to-end: a fallback
    // response must appear in /metrics as fallbackRequests=1, NOT as
    // successfulRequests=1, so operators can detect a permanently-cold model.
    func test_httpServer_sharedMetrics_fallbackCountAppearsInMetricsEndpoint() async throws {
        let sharedMetrics = DistillServiceMetricsRecorder()

        struct InfiniteRuntime: DistillRuntime {
            func distill(_ request: DistillRequest) async throws -> String {
                try await Task.sleep(for: .seconds(60))
                return "unreachable"
            }
        }

        let configuration = try DistillServiceConfiguration(
            authToken: "fallback-wiring-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 1
        )
        // Use 10 ms deadline directly (bypasses configuration's 1 s floor so the
        // test completes quickly without sleeping for the full minimum).
        let scheduler = DistillScheduler(
            runtime: DeadlineDistillRuntime(
                wrapping: InfiniteRuntime(),
                deadlineMilliseconds: 10,
                onFallback: { await sharedMetrics.recordFallback() }
            ),
            maxConcurrentRequests: 1
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore(),
            metricsRecorder: sharedMetrics
        )
        let ready = try await server.start()
        defer { server.stop() }

        // Submit one distill request -- the InfiniteRuntime never finishes,
        // so DeadlineDistillRuntime fires the fallback after 10 ms.
        let body = try JSONEncoder().encode(
            DistillRequest(mode: .commandOutput, input: "test input", maxOutputCharacters: 200)
        )
        let distillResp = try await response(
            baseURL: ready.baseURL,
            path: "/v1/distill",
            method: "POST",
            token: "fallback-wiring-token",
            body: body
        )
        // The request still returns 200 (fail-open), but the response carries the
        // deterministic fallback output, not the InfiniteRuntime output.
        XCTAssertEqual(distillResp.status, 200, "deadline fallback must still yield a 200 response (fail-open)")

        // /metrics must now show fallbackRequests=1 and successfulRequests=0.
        let metricsResp = try await response(
            baseURL: ready.baseURL,
            path: "/metrics",
            token: "fallback-wiring-token"
        )
        XCTAssertEqual(metricsResp.status, 200)
        let snapshot = try JSONDecoder().decode(DistillServiceMetrics.self, from: metricsResp.data)
        XCTAssertEqual(snapshot.fallbackRequests, 1,
                       "deadline-exceeded path must increment fallbackRequests so operators can detect a cold model; " +
                       "prior to the wiring this counter stayed zero even when every call hit the fallback")
        XCTAssertEqual(snapshot.failedRequests, 0,
                       "a fail-open fallback response must not increment failedRequests; " +
                       "it still yields a usable 200 response to the caller")
        XCTAssertEqual(snapshot.totalRequests, 1, "one request was submitted regardless of how it resolved")
    }

    // MARK: - invalidate

    /// Replacing a cached DistillServiceClient must call invalidate() on the old
    /// client so the underlying URLSession releases its socket/thread resources.
    /// The test verifies that invalidate() does not throw and is idempotent:
    /// if it were absent, the old URLSession would leak until dealloc (which may
    /// never happen while the cache holds a strong reference).
    func test_clientInvalidateIsIdempotentAndDoesNotCrash() async throws {
        let configuration = try DistillServiceConfiguration(
            authToken: "invalidate-test-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 1
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 1)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }

        guard let client = DistillServiceClient(ready: ready, authToken: "invalidate-test-token") else {
            XCTFail("DistillServiceClient(ready:authToken:) must succeed for a valid ready event")
            return
        }
        // First call: drains in-flight tasks and releases session resources.
        client.invalidate()
        // Second call: must not crash -- URLSession tolerates repeated invalidation.
        client.invalidate()
    }
}
