import XCTest
@testable import DistillCore

/// Verifies the per-technique (deterministic / BERT / MLX) engine attribution added
/// so the Token Saver UI can show "saved with bert" vs "saved with the model" vs
/// "saved deterministically" — not a single opaque "command-output" bucket.
final class TokenSaverEngineAttributionTests: XCTestCase {

    // MARK: - Engine label folding

    func test_engineLabelFoldsStageIntoMode() {
        XCTAssertEqual(TokenSaverEngineLabel.mode(base: "command-output", stage: .deterministic), "command-output (deterministic)")
        XCTAssertEqual(TokenSaverEngineLabel.mode(base: "command-output", stage: .encoderBERT), "command-output (bert)")
        XCTAssertEqual(TokenSaverEngineLabel.mode(base: "command-output", stage: .llmMLX), "command-output (model)")
        XCTAssertEqual(TokenSaverEngineLabel.mode(base: "command-output", stage: .apiExternal), "command-output (api)")
        // verbatim produced no real saving -> keep the base label unchanged.
        XCTAssertEqual(TokenSaverEngineLabel.mode(base: "command-output", stage: .verbatim), "command-output")
        // unknown engine (older sidecar / legacy rows) -> base label, no suffix.
        XCTAssertEqual(TokenSaverEngineLabel.mode(base: "longText", stage: nil), "longText")
    }

    // MARK: - Savings calculator carries the engine

    func test_savingsRecordFoldsEngineForCommandOutput() {
        let request = DistillRequest(mode: .commandOutput, input: String(repeating: "log line\n", count: 40), provider: "codex", recordSavings: true)
        let response = DistillResponse(
            requestID: request.id, output: "kept", inputCharacters: 320,
            inputTokens: 100, outputTokens: 10, routeStage: .encoderBERT
        )
        let record = DistillSavingsCalculator.record(for: request, response: response)
        XCTAssertEqual(record?.provider, "codex")
        XCTAssertEqual(record?.routeStage, .encoderBERT)
        XCTAssertEqual(record?.mode, "command-output (bert)",
                       "WHY: a BERT-extracted command-output saving must be attributable to BERT in the breakdown")
        XCTAssertEqual(record?.savedTokens, 90)
    }

    func test_savingsRecordFoldsEngineForLongTextModel() {
        let request = DistillRequest(mode: .longText, input: "a fairly long prompt to compress", provider: "claude", recordSavings: true)
        let response = DistillResponse(
            requestID: request.id, output: "S short", inputCharacters: 32,
            inputTokens: 50, outputTokens: 5, routeStage: .llmMLX
        )
        let record = DistillSavingsCalculator.record(for: request, response: response)
        XCTAssertEqual(record?.mode, "longText (model)")
        XCTAssertEqual(record?.routeStage, .llmMLX)
    }

    func test_verbatimFallbackReportsVerbatimEngineNotTheBypassedOne() {
        // A lossy result that couldn't be stored reversibly fails open to verbatim (0 saved).
        // It must NOT credit the bypassed engine (model/bert): the breakdown + route ledger
        // would otherwise show a spurious engine-attributed zero-saving run.
        let produced = DistillResponse(
            requestID: UUID(), output: "compressed", inputCharacters: 100,
            inputTokens: 100, outputTokens: 10, routeStage: .llmMLX
        )
        let verbatim = produced.verbatimFallback(input: "the full original input")
        XCTAssertEqual(verbatim.routeStage, .verbatim, "the bypassed engine (.llmMLX) must not be preserved")
        XCTAssertEqual(verbatim.savedTokens, 0, "verbatim fallback serves the input → zero savings")

        let request = DistillRequest(mode: .commandOutput, input: "x", provider: "claude", recordSavings: true)
        let record = DistillSavingsCalculator.record(for: request, response: verbatim)
        XCTAssertEqual(record?.mode, "command-output", "verbatim must record the plain base mode, no engine suffix")
        XCTAssertEqual(record?.routeStage, .verbatim)
    }

    func test_savingsRecordUnknownEngineKeepsLegacyMode() {
        // A response from an older sidecar (no routeStage) must still record under the
        // plain base mode so legacy aggregation is unbroken.
        let request = DistillRequest(mode: .commandOutput, input: "x", provider: "claude", recordSavings: true)
        let response = DistillResponse(requestID: request.id, output: "y", inputCharacters: 1, inputTokens: 10, outputTokens: 1)
        XCTAssertEqual(DistillSavingsCalculator.record(for: request, response: response)?.mode, "command-output")
    }

    // MARK: - Scheduler propagates the engine + feeds route telemetry

    /// A runtime that reports a fixed engine stage, to assert the scheduler threads it
    /// into the response and the route recorder.
    private struct StagedFakeRuntime: DistillRuntime {
        let stage: TokenSaverRouteStage
        func distill(_ request: DistillRequest) async throws -> String { "compressed-output" }
        func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
            DistillStageResult(output: "compressed-output", stage: stage)
        }
    }

    func test_schedulerThreadsEngineIntoResponseAndTelemetry() async throws {
        let recorded = RouteEventBox()
        let scheduler = DistillScheduler(
            runtime: StagedFakeRuntime(stage: .encoderBERT),
            resultCacheTTLSeconds: 0,
            routeRecorder: { event in await recorded.append(event) }
        )
        let response = try await scheduler.submit(
            DistillRequest(mode: .commandOutput, input: "some big command output to compress", provider: "claude", recordSavings: true)
        )
        XCTAssertEqual(response.routeStage, .encoderBERT, "WHY: the engine that produced the output must reach the savings recorder")
        let events = await recorded.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.stage, .encoderBERT)
        XCTAssertEqual(events.first?.lane, .commandOutput)
        XCTAssertFalse(events.first?.resolvedWithoutLLM == false,
                       "WHY: a BERT-resolved request counts toward the resolved-without-LLM payoff")
    }

    func test_localRuntimeReportsDeterministicEngine() async throws {
        let staged = try await LocalDistillRuntime().distillStaged(
            DistillRequest(mode: .commandOutput, input: "pwd\n/tmp\nfile.txt", question: "list files")
        )
        XCTAssertEqual(staged.stage, .deterministic,
                       "WHY: LocalDistillRuntime has no model — every path is deterministic")
    }

    func test_deadlineFallbackReportsDeterministicEngine() async throws {
        // A runtime that always exceeds the deadline -> fail-open fallback -> deterministic.
        struct SlowRuntime: DistillRuntime {
            func distill(_ request: DistillRequest) async throws -> String {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "never"
            }
        }
        let deadline = DeadlineDistillRuntime(wrapping: SlowRuntime(), deadlineMilliseconds: 20)
        let staged = try await deadline.distillStaged(DistillRequest(mode: .commandOutput, input: "ls -la /very/large/output"))
        XCTAssertEqual(staged.stage, .deterministic,
                       "WHY: the deterministic fail-open fallback must be attributed to the deterministic engine, never the model")
    }
}

/// Actor box to collect route telemetry events from the scheduler's @Sendable recorder.
private actor RouteEventBox {
    private(set) var events: [TokenSaverRouteTelemetryEvent] = []
    func append(_ event: TokenSaverRouteTelemetryEvent) { events.append(event) }
}

/// The Claude PostToolUse hook hand-builds a JSON body that omitted `id`, which made
/// the sidecar reject it 400 and the hook fail open silently — recording ZERO Claude
/// savings. The decoder must now tolerate a missing id (and priority / maxOutput).
final class DistillRequestTolerantDecodeTests: XCTestCase {
    private let decoder = JSONDecoder()

    func test_decodesBodyMissingId() throws {
        // The Claude PostToolUse hook hand-builds a body without `id`; that previously
        // 400'd. It must now decode (a fresh id is synthesized), while other fields keep
        // their original semantics (runMode absent -> nil, recordSavings preserved).
        let json = #"{"mode":"commandOutput","priority":1,"input":"big output","provider":"claude","recordSavings":true,"cacheState":"tool_output_hooked","maxOutputCharacters":2000}"#
        let request = try decoder.decode(DistillRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.mode, .commandOutput)
        XCTAssertEqual(request.input, "big output")
        XCTAssertEqual(request.provider, "claude")
        XCTAssertEqual(request.recordSavings, true)
        XCTAssertEqual(request.priority, .agent)
        XCTAssertNil(request.runMode, "absent runMode must stay nil (effectiveRunMode defaults), unchanged from before")
        XCTAssertNotNil(request.id, "a fresh id must be synthesized so the request is valid")
    }

    func test_stillRejectsBodyMissingRequiredFields() {
        // `mode` and `input` stay genuinely required — those remain hard errors.
        XCTAssertThrowsError(try decoder.decode(DistillRequest.self, from: Data(#"{"input":"x","priority":1,"maxOutputCharacters":500}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(DistillRequest.self, from: Data(#"{"mode":"longText","priority":1,"maxOutputCharacters":500}"#.utf8)))
    }

    func test_roundTripsEncodedRequest() throws {
        let original = DistillRequest(
            mode: .longText, priority: .interactive, input: "round trip me",
            question: "q", provider: "codex", recordSavings: true, cacheState: "prompt",
            maxOutputCharacters: 1234
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try decoder.decode(DistillRequest.self, from: data)
        XCTAssertEqual(decoded.mode, original.mode)
        XCTAssertEqual(decoded.priority, original.priority)
        XCTAssertEqual(decoded.input, original.input)
        XCTAssertEqual(decoded.provider, original.provider)
        XCTAssertEqual(decoded.recordSavings, original.recordSavings)
        XCTAssertEqual(decoded.cacheState, original.cacheState)
        XCTAssertEqual(decoded.maxOutputCharacters, original.maxOutputCharacters)
        XCTAssertEqual(decoded.id, original.id)
    }
}
