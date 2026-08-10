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

    private actor CountingRuntime: DistillRuntime {
        private var count = 0
        let outputBuilder: @Sendable (Int, DistillRequest) -> String

        init(outputBuilder: @escaping @Sendable (Int, DistillRequest) -> String = { count, request in
            "S cached-\(count) \(request.input)"
        }) {
            self.outputBuilder = outputBuilder
        }

        func distill(_ request: DistillRequest) async throws -> String {
            count += 1
            return outputBuilder(count, request)
        }

        var callCount: Int { count }
    }

    /// Blocks every `distill` until released and counts `reclaimIdleMemory` calls, so a
    /// test can prove the scheduler reclaims GPU memory exactly when it drains to idle.
    private final class ReclaimTrackingRuntime: DistillRuntime, @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var reclaims = 0

        func distill(_ request: DistillRequest) async throws -> String {
            await withCheckedContinuation { continuation in
                lock.lock(); continuations.append(continuation); lock.unlock()
            }
            return "S \(request.input)"
        }

        func reclaimIdleMemory() {
            lock.lock(); reclaims += 1; lock.unlock()
        }

        func releaseAll() {
            lock.lock(); let pending = continuations; continuations.removeAll(); lock.unlock()
            pending.forEach { $0.resume() }
        }

        var reclaimCount: Int { lock.lock(); defer { lock.unlock() }; return reclaims }
    }

    func test_schedulerReclaimsIdleMemoryOncePerDrainNotPerConcurrentRequest() async throws {
        let runtime = ReclaimTrackingRuntime()
        let scheduler = DistillScheduler(runtime: runtime, maxConcurrentRequests: 4, maxQueueDepth: 4)

        let tasks = (0..<3).map { index in
            Task { try await scheduler.submit(DistillRequest(mode: .commandOutput, input: "in-\(index)")) }
        }
        while await scheduler.activeRequestCount < 3 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(runtime.reclaimCount, 0,
                       "memory must not be reclaimed while requests are still in flight — the cache stays warm during a burst")

        runtime.releaseAll()
        for task in tasks {
            _ = try await task.value
        }

        let active = await scheduler.activeRequestCount
        XCTAssertEqual(active, 0)
        XCTAssertEqual(runtime.reclaimCount, 1,
                       "the GPU cache is returned exactly once when the burst fully drains to idle, never per request")
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

    func test_schedulerQueueWaitTimeoutFailsOpenWithoutDoubleResume() async throws {
        // WHY: multi-thread agents stack behind multi-second MLX generations when
        // the waiter queue has no time budget. Timeout must throw queueFull so the
        // client keeps original tool output (Token Saver fail-open), and must not
        // leave a waiter that double-resumes when the slot later frees.
        let runtime = BlockingRuntime()
        let scheduler = DistillScheduler(
            runtime: runtime,
            maxConcurrentRequests: 1,
            maxQueueDepth: 4,
            maxQueueWaitMilliseconds: 80
        )

        let first = Task {
            try await scheduler.submit(DistillRequest(mode: .commandOutput, input: "held"))
        }
        while await runtime.pendingCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        do {
            _ = try await scheduler.submit(DistillRequest(mode: .commandOutput, input: "waits"))
            XCTFail("waiter must time out as queueFull instead of blocking unbounded")
        } catch DistillError.queueFull {
            // expected
        }

        let queued = await scheduler.queuedRequestCount
        XCTAssertEqual(queued, 0, "timed-out waiter must be removed from the queue")

        await runtime.releaseAll()
        _ = try await first.value
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

    func test_schedulerCachesAcceptedOutputByFullFingerprint() async throws {
        let runtime = CountingRuntime()
        let scheduler = DistillScheduler(runtime: runtime, maxConcurrentRequests: 1, resultCacheTTLSeconds: 60, resultCacheCapacity: 8)
        let first = DistillRequest(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            mode: .longText,
            input: "same large payload",
            question: "compress",
            maxOutputCharacters: 400
        )
        let second = DistillRequest(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            mode: .longText,
            input: "same large payload",
            question: "compress",
            maxOutputCharacters: 400
        )

        let firstResponse = try await scheduler.submit(first)
        let secondResponse = try await scheduler.submit(second)

        XCTAssertEqual(firstResponse.output, "S cached-1 same large payload")
        XCTAssertEqual(secondResponse.output, firstResponse.output,
                       "identical mode/input/question/output budget must reuse the accepted result instead of paying the runtime again")
        XCTAssertEqual(secondResponse.requestID, second.id,
                       "a cache hit must still be wrapped as a response to the current request")
        let callCount = await runtime.callCount
        let cacheCount = await scheduler.resultCacheCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(cacheCount, 1)
    }

    func test_schedulerResultCacheKeyIncludesQuestionAndOutputBudget() async throws {
        let runtime = CountingRuntime()
        let scheduler = DistillScheduler(runtime: runtime, maxConcurrentRequests: 1, resultCacheTTLSeconds: 60, resultCacheCapacity: 8)

        _ = try await scheduler.submit(DistillRequest(mode: .commandOutput, input: "alpha\nbeta", question: "Keep alpha only.", maxOutputCharacters: 400))
        _ = try await scheduler.submit(DistillRequest(mode: .commandOutput, input: "alpha\nbeta", question: "Keep beta only.", maxOutputCharacters: 400))
        _ = try await scheduler.submit(DistillRequest(mode: .commandOutput, input: "alpha\nbeta", question: "Keep alpha only.", maxOutputCharacters: 200))

        let callCount = await runtime.callCount
        let cacheCount = await scheduler.resultCacheCount
        XCTAssertEqual(callCount, 3,
                       "question and maxOutputCharacters are part of the fingerprint so stale answers cannot cross contracts")
        XCTAssertEqual(cacheCount, 3)
    }

    func test_resultCacheKeyIncludesModeModelRevisionAndPipelineVersion() {
        let base = DistillRequest(
            mode: .commandOutput,
            input: "alpha\nbeta",
            question: "Keep alpha only.",
            maxOutputCharacters: 400
        )
        let differentMode = DistillRequest(
            mode: .longText,
            input: "alpha\nbeta",
            question: "Keep alpha only.",
            maxOutputCharacters: 400
        )

        let key = DistillResultCacheKey(request: base, modelRevision: "model-a", pipelineVersion: "pipeline-v1")
        XCTAssertNotEqual(
            key,
            DistillResultCacheKey(request: differentMode, modelRevision: "model-a", pipelineVersion: "pipeline-v1"),
            "mode is part of the cache key so command-output and prose contracts cannot share answers"
        )
        XCTAssertNotEqual(
            key,
            DistillResultCacheKey(request: base, modelRevision: "model-b", pipelineVersion: "pipeline-v1"),
            "model revision is part of the cache key so model bumps invalidate stale hits"
        )
        XCTAssertNotEqual(
            key,
            DistillResultCacheKey(request: base, modelRevision: "model-a", pipelineVersion: "pipeline-v2"),
            "pipelineVersion is part of the cache key so crusher or literal-preservation changes invalidate stale hits"
        )
    }

    func test_schedulerDoesNotCacheOutputsWithUnvalidatedRetrieveHandles() async throws {
        let runtime = CountingRuntime { count, _ in
            "S handle-output-\(count) [[rc:abc123]]"
        }
        let scheduler = DistillScheduler(runtime: runtime, maxConcurrentRequests: 1, resultCacheTTLSeconds: 60, resultCacheCapacity: 8)
        let request = DistillRequest(mode: .longText, input: "payload with lossy handle source", maxOutputCharacters: 400)

        let first = try await scheduler.submit(request)
        let second = try await scheduler.submit(request)

        XCTAssertNotEqual(first.output, second.output,
                          "outputs with retrieve handles must not be served from cache without a live handle validation path")
        let callCount = await runtime.callCount
        let cacheCount = await scheduler.resultCacheCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(cacheCount, 0)
    }

    func test_commandOutputRuntimeReturnsOnlyRequestedFormat() async throws {
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let response = try await scheduler.submit(DistillRequest(
            mode: .commandOutput,
            input: "unit tests passed\n0 failures",
            question: "Did the tests pass? Return only PASS or FAIL, followed by failing test names if any.",
            maxOutputCharacters: 200
        ))

        XCTAssertEqual(response.output, "PASS",
                       "command output compression must return exactly what the provider requested, not SR1/O-prefixed prose")
        XCTAssertFalse(response.output.contains("PROMPT:"))
        XCTAssertFalse(response.output.contains("INPUT:"))
    }

    func test_commandOutputRuntimeHandlesCwdOnlyQuestion() async throws {
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let response = try await scheduler.submit(DistillRequest(
            mode: .commandOutput,
            input: "/tmp\n",
            question: "Return cwd only. If distill service unavailable, preserve raw cwd.",
            maxOutputCharacters: 200
        ))

        XCTAssertEqual(response.output, "/tmp")
    }

    func test_commandOutputRuntimeFiltersHTMLPathsWhenRequested() async throws {
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let response = try await scheduler.submit(DistillRequest(
            mode: .commandOutput,
            input: "foo.html\nbar.txt\nsite/index.html\n",
            question: "List existing HTML files, or NONE. Keep paths only.",
            maxOutputCharacters: 200
        ))

        XCTAssertEqual(response.output, "foo.html\nsite/index.html")
    }

    func test_commandOutputRuntimeHandlesCwdAndFilesFormat() async throws {
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let response = try await scheduler.submit(DistillRequest(
            mode: .commandOutput,
            input: "/tmp\nindex.html\nnotes.txt\n",
            question: "Return cwd and visible files. Format: CWD=<path>; FILES=<comma list or EMPTY>.",
            maxOutputCharacters: 200
        ))

        XCTAssertEqual(response.output, "CWD=/tmp; FILES=index.html, notes.txt")
    }

    func test_mlxRuntimeBypassesModelForExactCommandOutputContracts() throws {
        let cwd = DistillRequest(
            mode: .commandOutput,
            input: "/tmp\n",
            question: "Return cwd only. If distill service unavailable, preserve raw cwd.",
            maxOutputCharacters: 200
        )
        let htmlPaths = DistillRequest(
            mode: .commandOutput,
            input: "foo.html\nbar.txt\nsite/index.html\n",
            question: "List existing HTML files, or NONE. Keep paths only.",
            maxOutputCharacters: 200
        )
        let cwdAndFiles = DistillRequest(
            mode: .commandOutput,
            input: "/tmp\nindex.html\nnotes.txt\n",
            question: "Return cwd and visible files. Format: CWD=<path>; FILES=<comma list or EMPTY>.",
            maxOutputCharacters: 200
        )

        XCTAssertEqual(MLXDistillRuntime.deterministicCommandOutput(for: cwd), "/tmp")
        XCTAssertEqual(MLXDistillRuntime.deterministicCommandOutput(for: htmlPaths), "foo.html\nsite/index.html")
        XCTAssertEqual(MLXDistillRuntime.deterministicCommandOutput(for: cwdAndFiles), "CWD=/tmp; FILES=index.html, notes.txt")
    }

    func test_mlxRuntimeDoesNotBypassPassFailWithoutEvidence() throws {
        let request = DistillRequest(
            mode: .commandOutput,
            input: "bypass token unchanged\npassphrase accepted\nSources/error_handler.swift",
            question: "Did tests pass? Return PASS or FAIL only.",
            maxOutputCharacters: 200
        )

        XCTAssertNil(MLXDistillRuntime.deterministicCommandOutput(for: request),
                     "substring matches like bypass/passphrase/error_handler must not bypass the model as PASS/FAIL evidence")
        XCTAssertFalse(LocalDistillRuntime.commandOutputFallback(
            input: request.input,
            question: request.question,
            maxOutputCharacters: 200
        ).contains("Insufficient information"))
    }

    func test_mlxRuntimeDoesNotBypassJSONOnlyWithNoise() throws {
        let request = DistillRequest(
            mode: .commandOutput,
            input: "{\"ok\":true}\nwarning: extra stderr",
            question: "Return JSON only.",
            maxOutputCharacters: 200
        )

        XCTAssertNil(MLXDistillRuntime.deterministicCommandOutput(for: request),
                     "JSON-only deterministic bypass must require parseable JSON or JSONL, not JSON plus noise")
    }

    func test_mlxRuntimeDoesNotBypassExistsMissingWithoutCodeToken() throws {
        let request = DistillRequest(
            mode: .commandOutput,
            input: "file is present",
            question: "Return EXISTS or MISSING.",
            maxOutputCharacters: 200
        )

        XCTAssertNil(MLXDistillRuntime.deterministicCommandOutput(for: request),
                     "EXISTS/MISSING deterministic bypass must require an explicit code= token")
    }

    func test_mlxRuntimeCommandOutputClassifierCanExpandKnownContracts() throws {
        let request = DistillRequest(
            mode: .commandOutput,
            input: "foo.html\nbar.txt\n",
            question: "Extract relevant artifacts.",
            maxOutputCharacters: 200
        )
        let classifier: CommandOutputIntentClassifier = { _ in
            CommandOutputIntentDecision(intent: .pathsOnly, confidence: 0.94)
        }

        XCTAssertEqual(
            MLXDistillRuntime.deterministicCommandOutput(for: request, classifier: classifier),
            "foo.html\nbar.txt",
            "a confident encoder classifier can route to a self-validating deterministic extractor"
        )
    }

    func test_mlxRuntimeCommandOutputClassifierLowConfidenceFallsBackToHeuristic() throws {
        let request = DistillRequest(
            mode: .commandOutput,
            input: "foo.html\nbar.txt\n",
            question: "Extract relevant artifacts.",
            maxOutputCharacters: 200
        )
        let classifier: CommandOutputIntentClassifier = { _ in
            CommandOutputIntentDecision(intent: .pathsOnly, confidence: 0.20)
        }

        XCTAssertNil(
            MLXDistillRuntime.deterministicCommandOutput(for: request, classifier: classifier),
            "low-confidence classifier output must not bypass MLX when the heuristic has no known contract"
        )
    }

    func test_commandOutputFailingNamesReportsHiddenCount() async throws {
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let response = try await scheduler.submit(DistillRequest(
            mode: .commandOutput,
            input: "TestA failed\nTestB error\nTestC failed\nTestD failed",
            question: "Did tests pass? Return PASS or FAIL, followed by failing test names if any.",
            maxOutputCharacters: 300
        ))

        XCTAssertTrue(response.output.hasPrefix("FAIL "))
        XCTAssertTrue(response.output.contains("TestA failed"))
        XCTAssertTrue(response.output.contains("+1 more"),
                      "deterministic failing-name output must disclose when additional failures were omitted")
    }

    func test_commandOutputSavingsUseEstimatedTokensNotCharacterLength() {
        let request = DistillRequest(
            mode: .commandOutput,
            input: "line one\nline two\nline three\n",
            question: "Keep paths only.",
            provider: "claude",
            recordSavings: true,
            maxOutputCharacters: 200
        )
        // Token estimates deliberately diverge from the character lengths so a
        // regression back to `.count` (characters) would fail this test.
        let response = DistillResponse(
            requestID: request.id,
            output: "line one\n",
            inputCharacters: request.input.count,
            inputTokens: 999,
            outputTokens: 1
        )

        let record = DistillSavingsCalculator.record(for: request, response: response)

        XCTAssertEqual(record?.provider, "claude")
        XCTAssertEqual(record?.mode, "command-output")
        XCTAssertEqual(record?.inputTokens, 999, "saved-token accounting must use the measured token estimate, not input.count")
        XCTAssertEqual(record?.outputTokens, 1, "saved-token accounting must use the measured token estimate, not output.count")
        XCTAssertEqual(record?.savedTokens, 998)
        XCTAssertNotEqual(record?.inputTokens, request.input.count, "characters must never stand in for tokens")
    }

    /// Reproduces the published `distill` token report (github.com/samuelfaj/distill):
    /// a 30592-char command output (≈7648 tokens) compressed to 396 chars (≈99
    /// tokens) must record ≈7549 saved tokens — not ≈30196 saved characters.
    func test_commandOutputSavingsMatchPublishedTokenReport() {
        let rawOutput = String(repeating: "a", count: 30_592)
        let distilled = String(repeating: "b", count: 396)
        let request = DistillRequest(
            mode: .commandOutput,
            input: rawOutput,
            question: "Compress.",
            provider: "claude",
            recordSavings: true,
            maxOutputCharacters: 4_000
        )
        let response = DistillResponse(
            requestID: request.id,
            output: distilled,
            inputCharacters: rawOutput.count,
            inputTokens: TokenEstimator.estimate(rawOutput),
            outputTokens: TokenEstimator.estimate(distilled)
        )

        let record = DistillSavingsCalculator.record(for: request, response: response)

        XCTAssertEqual(record?.inputTokens, 7648)
        XCTAssertEqual(record?.outputTokens, 99)
        XCTAssertEqual(record?.savedTokens, 7549, "saved tokens must equal the published token delta, not the character delta")
    }

    func test_commandOutputSavingsCanUseHookedToolCacheState() {
        let request = DistillRequest(
            mode: .commandOutput,
            input: String(repeating: "line\n", count: 100),
            provider: "claude",
            recordSavings: true,
            cacheState: "tool_output_hooked"
        )
        let response = DistillResponse(
            requestID: request.id,
            output: "summary",
            inputCharacters: request.input.count,
            inputTokens: 100,
            outputTokens: 10
        )

        let record = DistillSavingsCalculator.record(for: request, response: response)

        XCTAssertEqual(record?.cacheState, "tool_output_hooked",
                       "I2: SDK PostToolUse compression must be measurable separately from one-shot pipe savings")
    }

    func test_sr1HumanizeSavingsCreditDefaultAgentVerbosityFactor() {
        let sr1 = "S ok.\nO done."
        let request = DistillRequest(
            mode: .sr1Humanize,
            input: """
            TARGET_LANGUAGE: Portuguese (Brazil)

            SR1_RESPONSE:
            \(sr1)
            """,
            provider: "codex",
            recordSavings: true,
            maxOutputCharacters: 500
        )
        let human = "Estado: ok.\nResultado: done with human wording."
        let response = DistillResponse(
            requestID: request.id,
            output: human,
            inputCharacters: request.input.count,
            inputTokens: 10,
            outputTokens: 20
        )

        let record = DistillSavingsCalculator.record(for: request, response: response)

        // WHY no multiplier: the previous version of this test pinned a 9x credit
        // (3x transcript expansion times a 3x "the agent would have been more verbose"
        // counterfactual) applied to CHARACTER counts. Nothing measured either factor,
        // and the only instrumentation that could have is a no-op, so the credited
        // number was unfalsifiable. The estimator now reports the estimated token delta
        // between the two texts that actually exist, via the same deterministic
        // estimator on both legs.
        XCTAssertEqual(record?.provider, "codex")
        XCTAssertEqual(record?.mode, "sr1-humanize")
        XCTAssertEqual(record?.inputTokens, TokenEstimator.estimate(human),
                       "input leg is the estimated token size of the humanized text, not its character count")
        XCTAssertEqual(record?.outputTokens, TokenEstimator.estimate(sr1),
                       "output leg uses the same estimator so saved = input - output stays consistent")
        XCTAssertEqual(record?.savedTokens,
                       max(TokenEstimator.estimate(human) - TokenEstimator.estimate(sr1), 0),
                       "saved tokens is a defensible delta between two produced texts, with no counterfactual credit")
    }

    func test_mlxCommandOutputCollapsesDuplicatedModelBlocks() throws {
        XCTAssertEqual(
            MLXDistillRuntime.collapseDuplicatedCommandOutput("PASS\nPASS"),
            "PASS"
        )
        XCTAssertEqual(
            MLXDistillRuntime.collapseDuplicatedCommandOutput("CWD=/tmp; FILES=index.html\nCWD=/tmp; FILES=index.html"),
            "CWD=/tmp; FILES=index.html"
        )
    }

    func test_commandOutputRuntimeDoesNotEchoLegacyPromptInputEnvelope() async throws {
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let response = try await scheduler.submit(DistillRequest(
            mode: .commandOutput,
            input: """
            PROMPT:
            Return cwd only. If distill service unavailable, preserve raw cwd.

            INPUT:
            /tmp
            """,
            maxOutputCharacters: 200
        ))

        XCTAssertEqual(response.output, "/tmp")
        XCTAssertFalse(response.output.contains("PROMPT:"))
        XCTAssertFalse(response.output.contains("INPUT:"))
    }

    func test_sr1HumanizeFallbackExpandsSpaceDelimitedDistillLines() async throws {
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let response = try await scheduler.submit(DistillRequest(
            mode: .sr1Humanize,
            input: """
            TARGET_LANGUAGE: Portuguese (Brazil)

            SR1_RESPONSE:
            O Snake game criado.
            O file: /Users/samuelfajreldines/snake.html (single-file, zero deps)
            P open: abrir snake.html no browser -> jogo roda
            """,
            maxOutputCharacters: 500
        ))

        XCTAssertEqual(
            response.output,
            """
            Snake game criado.
            file: /Users/samuelfajreldines/snake.html (single-file, zero deps)
            open: abrir snake.html no browser -> jogo roda
            """
        )
    }

    func test_sr1HumanizeFallbackExpandsInlineDistillClauses() async throws {
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let response = try await scheduler.submit(DistillRequest(
            mode: .sr1Humanize,
            input: """
            TARGET_LANGUAGE: Portuguese (Brazil)

            SR1_RESPONSE:
            S come. C cwd=/tmp. D load /distill rule, then create minimal HTML snake game.
            """,
            maxOutputCharacters: 500
        ))

        XCTAssertEqual(
            response.output,
            "Nao consegui expandir a resposta comprimida."
        )
    }

    func test_sr1HumanizeFallbackExpandsCompressedVariables() async throws {
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let response = try await scheduler.submit(DistillRequest(
            mode: .sr1Humanize,
            input: """
            TARGET_LANGUAGE: Portuguese (Brazil)

            SR1_RESPONSE:
            Dict: S=state C=context D=action R=risk O=outcome N=no-go P=proof #g1=Snake HTML game
            S received. D create #g1 in one file. O #g1 ready.
            """,
            maxOutputCharacters: 500
        ))

        XCTAssertFalse(response.output.contains("#g1"),
                       "SR1 aliases are a provider compression detail and must not be shown in the humanized answer")
        // O-first prose: only the outcome (O) segment survives, S/C/D chrome dropped,
        // and the #g1 alias is expanded to its literal value.
        XCTAssertEqual(response.output, "Snake HTML game ready")
    }

    func test_schedulerReportsMeasuredTokenSavingsFromRealCompression() async throws {
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        // 60 verbose lines; LocalDistillRuntime keeps only the first 12, so the
        // distilled output is materially smaller and savings must be positive.
        let verbose = (1...60).map { "line \($0): verbose command output that the model removes" }.joined(separator: "\n")
        let response = try await scheduler.submit(DistillRequest(
            mode: .commandOutput,
            input: verbose,
            maxOutputCharacters: 4000
        ))

        XCTAssertGreaterThan(response.inputTokens, 0)
        XCTAssertGreaterThan(response.outputTokens, 0)
        XCTAssertGreaterThan(response.savedTokens, 0,
                             "compressing 60 lines down to 12 must report measured tokens saved, not zero")
        XCTAssertEqual(response.savedTokens, max(response.inputTokens - response.outputTokens, 0),
                       "savedTokens must equal the measured input/output delta — never a synthetic ratio")
        XCTAssertLessThan(response.outputTokens, response.inputTokens)
    }

    func test_tokenEstimatorIsZeroForEmptyAndGrowsWithText() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
        XCTAssertGreaterThan(TokenEstimator.estimate("hello world this is a sentence"), 0)
        XCTAssertGreaterThan(
            TokenEstimator.estimate(String(repeating: "token ", count: 100)),
            TokenEstimator.estimate("token token token"),
            "more text must estimate to more tokens so the saved delta is meaningful"
        )
    }

    func test_mlxOutputCleanupRejectsHiddenThinkingAndPrefixDictionary() {
        let cleaned = MLXDistillRuntime.cleanOutput("<think>\nprivate\n</think>\nS=state, C=context")

        XCTAssertEqual(cleaned, "S=state, C=context")
        XCTAssertFalse(
            MLXDistillRuntime.isUsefulDistillOutput(cleaned),
            "MLX output must not expose hidden thinking or a prefix dictionary instead of compressed content"
        )
    }

    func test_mlxSR1HumanizeRejectsPartialDictionaryOutput() {
        let output = """
        Dict: S=state C=context D=action R=risk O=outcome N=no-go P=proof
        Estado: starting
        Acao: create file
        """

        XCTAssertFalse(
            MLXDistillRuntime.isUsefulOutput(output, mode: .sr1Humanize),
            "SR1 humanization must reject partial translations that still expose the SR1 dictionary"
        )
    }

    func test_mlxSR1HumanizeRejectsMixedCompressedAndHumanOutput() {
        let output = """
        S done.
        O created /tmp/index.html: self-contained Snake game.
        P verified:
        PASS inline JS parses.
        PASS HTTP smoke: 200, title present, canvas present.
        C controls:
        Arrow keys / WASD move.
        Space pauses.
        Enter restarts after game over.
        Touch buttons included.
        O criado /tmp/index.html: jogo Snake self-contained.
        """

        XCTAssertFalse(
            MLXDistillRuntime.isUsefulOutput(output, mode: .sr1Humanize),
            "SR1 humanization must reject model output that preserves compressed S/O/P/C lines before a human-language sentence"
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
