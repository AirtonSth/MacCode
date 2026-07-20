import Foundation
import CryptoKit
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

public enum DistillMode: String, Codable, Sendable, Equatable {
    case commandOutput
    case longText
    case watchSummary
    case sr1Humanize
}

public enum DistillPriority: Int, Codable, Sendable, Comparable {
    case background = 0
    case agent = 1
    case interactive = 2

    public static func < (lhs: DistillPriority, rhs: DistillPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum CommandOutputIntent: String, Codable, Sendable, Equatable {
    case cwdAndFiles
    case cwdOnly
    case tokenVerdict
    case pathsOnly
    case existsMissing
    case statusCode
    case jsonOnly
}

public struct CommandOutputIntentDecision: Equatable, Sendable {
    public let intent: CommandOutputIntent
    public let confidence: Double

    public init(intent: CommandOutputIntent, confidence: Double) {
        self.intent = intent
        self.confidence = confidence
    }

    fileprivate func isConfident(minimumConfidence: Double) -> Bool {
        confidence.isFinite && confidence >= minimumConfidence
    }
}

public typealias CommandOutputIntentClassifier = @Sendable (String) -> CommandOutputIntentDecision?

public enum DistillRunMode: String, Codable, Sendable, Equatable {
    case audit
    case optimize
    case simulate
}

public struct DistillAuditReport: Codable, Sendable, Equatable {
    public let runMode: DistillRunMode
    public let candidateOutputCharacters: Int
    public let candidateOutputTokens: Int
    public let wouldSaveTokens: Int
    public let accepted: Bool
    public let wallClockMilliseconds: Int

    public init(
        runMode: DistillRunMode,
        candidateOutputCharacters: Int,
        candidateOutputTokens: Int,
        wouldSaveTokens: Int,
        accepted: Bool,
        wallClockMilliseconds: Int
    ) {
        self.runMode = runMode
        self.candidateOutputCharacters = max(0, candidateOutputCharacters)
        self.candidateOutputTokens = max(0, candidateOutputTokens)
        self.wouldSaveTokens = max(0, wouldSaveTokens)
        self.accepted = accepted
        self.wallClockMilliseconds = max(0, wallClockMilliseconds)
    }
}

public struct DistillRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let mode: DistillMode
    public let priority: DistillPriority
    public let input: String
    public let question: String?
    public let provider: String?
    public let recordSavings: Bool?
    public let runMode: DistillRunMode?
    public let cacheState: String?
    public let rerankQuery: String?
    public let topK: Int?
    public let encoderLane: String?
    public let maxOutputCharacters: Int
    /// Per-request override for the store-before-loss floor: inputs at least this many bytes
    /// have their byte-exact original stored so a lossy compression stays recoverable via
    /// `/v1/retrieve`. nil uses the server default. The Claude PostToolUse hook and the RTK
    /// command wrappers send a low value so their compressed output always carries a handle.
    public let reversibleStoreMinBytes: Int?

    public init(
        id: UUID = UUID(),
        mode: DistillMode,
        priority: DistillPriority = .agent,
        input: String,
        question: String? = nil,
        provider: String? = nil,
        recordSavings: Bool = false,
        runMode: DistillRunMode = .optimize,
        cacheState: String? = nil,
        rerankQuery: String? = nil,
        topK: Int? = nil,
        encoderLane: String? = nil,
        maxOutputCharacters: Int = 4_000,
        reversibleStoreMinBytes: Int? = nil
    ) {
        self.id = id
        self.mode = mode
        self.priority = priority
        self.input = input
        self.question = question?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.recordSavings = recordSavings
        self.runMode = runMode
        self.cacheState = cacheState?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.rerankQuery = rerankQuery?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.topK = topK.map { max(1, $0) }
        self.encoderLane = encoderLane?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.maxOutputCharacters = max(128, maxOutputCharacters)
        self.reversibleStoreMinBytes = reversibleStoreMinBytes.map { max(1, $0) }
    }

    public var effectiveRunMode: DistillRunMode {
        runMode ?? .optimize
    }

    private enum CodingKeys: String, CodingKey {
        case id, mode, priority, input, question, provider
        case recordSavings, runMode, cacheState, rerankQuery, topK, encoderLane, maxOutputCharacters
        case reversibleStoreMinBytes
    }

    /// Tolerant decoder: identical to the synthesized one EXCEPT a wire client may omit
    /// `id` (a fresh UUID is synthesized). WHY: a hand-built JSON body that merely omitted
    /// `id` previously 400'd, and the caller (the Claude PostToolUse hook) failed open
    /// silently — recording ZERO savings. All other fields keep their original required /
    /// optional semantics so decode behavior is otherwise unchanged.
    public init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.mode = try c.decode(DistillMode.self, forKey: .mode)
        self.priority = try c.decode(DistillPriority.self, forKey: .priority)
        self.input = try c.decode(String.self, forKey: .input)
        self.question = try c.decodeIfPresent(String.self, forKey: .question)
        self.provider = try c.decodeIfPresent(String.self, forKey: .provider)
        self.recordSavings = try c.decodeIfPresent(Bool.self, forKey: .recordSavings)
        self.runMode = try c.decodeIfPresent(DistillRunMode.self, forKey: .runMode)
        self.cacheState = try c.decodeIfPresent(String.self, forKey: .cacheState)
        self.rerankQuery = try c.decodeIfPresent(String.self, forKey: .rerankQuery)
        self.topK = try c.decodeIfPresent(Int.self, forKey: .topK)
        self.encoderLane = try c.decodeIfPresent(String.self, forKey: .encoderLane)
        self.maxOutputCharacters = try c.decode(Int.self, forKey: .maxOutputCharacters)
        self.reversibleStoreMinBytes = try c.decodeIfPresent(Int.self, forKey: .reversibleStoreMinBytes).map { max(1, $0) }
    }
}

public struct DistillResponse: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let output: String
    public let inputCharacters: Int
    public let outputCharacters: Int
    public let inputTokens: Int
    public let outputTokens: Int
    /// CCR handle to the byte-exact original, set by the sidecar when it stored
    /// the input before compression (store-before-loss, N5). nil when not stored
    /// (small/lossless). Optional + synthesized Codable => decode tolerates older
    /// payloads that omit the key (version-skew safe).
    public let originalHandle: String?
    /// Stable mutation identity for the scoped recovery outbox. Optional for
    /// backward-compatible decoding from older sidecars and absent on verbatim paths.
    public let recoveryIdempotencyKey: String?
    public let runMode: DistillRunMode?
    public let auditReport: DistillAuditReport?
    /// Which engine produced this output (deterministic router / BERT encoder lane /
    /// MLX LLM). Lets Token Saver attribute saved tokens per technique. Optional +
    /// synthesized Codable => decode tolerates payloads from older sidecars.
    public let routeStage: TokenSaverRouteStage?

    public init(
        requestID: UUID,
        output: String,
        inputCharacters: Int,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        originalHandle: String? = nil,
        recoveryIdempotencyKey: String? = nil,
        runMode: DistillRunMode = .optimize,
        auditReport: DistillAuditReport? = nil,
        routeStage: TokenSaverRouteStage? = nil
    ) {
        self.requestID = requestID
        self.output = output
        self.inputCharacters = inputCharacters
        self.outputCharacters = output.count
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.originalHandle = originalHandle
        self.recoveryIdempotencyKey = recoveryIdempotencyKey
        self.runMode = runMode
        self.auditReport = auditReport
        self.routeStage = routeStage
    }

    /// Tokens removed by compression. Never negative: a longer "compressed"
    /// output (rare model misbehavior) reports zero savings, not negative.
    public var savedTokens: Int { max(inputTokens - outputTokens, 0) }

    /// I2.4: fail-open copy that serves `input` verbatim (no savings, no handle). Used when
    /// a LOSSY substitution could not be backed by a reversible store, so the dropped bytes
    /// would otherwise be unrecoverable. Engine attribution is set to `.verbatim`: no engine
    /// compression was actually served, so the per-technique breakdown and route ledger must
    /// not credit a zero-saving run to the model/BERT/deterministic engine that was bypassed.
    public func verbatimFallback(input: String) -> DistillResponse {
        DistillResponse(
            requestID: requestID,
            output: input,
            inputCharacters: input.count,
            inputTokens: inputTokens,
            outputTokens: inputTokens,
            originalHandle: nil,
            runMode: runMode ?? .optimize,
            auditReport: auditReport,
            routeStage: .verbatim
        )
    }

    /// Copy carrying the CCR handle to the stored original.
    public func withOriginalHandle(_ handle: String?, idempotencyKey: String? = nil) -> DistillResponse {
        DistillResponse(
            requestID: requestID,
            output: output,
            inputCharacters: inputCharacters,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            originalHandle: handle,
            recoveryIdempotencyKey: idempotencyKey,
            runMode: runMode ?? .optimize,
            auditReport: auditReport,
            routeStage: routeStage
        )
    }
}

/// Output of a runtime distill call plus which engine produced it. Lets the
/// scheduler attribute saved tokens and route telemetry per technique without
/// changing the legacy `distill(_:) -> String` contract.
public struct DistillStageResult: Sendable {
    public let output: String
    public let stage: TokenSaverRouteStage?

    public init(output: String, stage: TokenSaverRouteStage?) {
        self.output = output
        self.stage = stage
    }
}

public struct DistillRankChunk: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let contentType: DistillContentType
    public let position: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case contentType
        case position
    }

    public init(id: String, text: String, contentType: DistillContentType = .prose, position: Int = 0) {
        self.id = id
        self.text = text
        self.contentType = contentType
        self.position = max(0, position)
    }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.text = try container.decode(String.self, forKey: .text)
        self.contentType = try container.decodeIfPresent(DistillContentType.self, forKey: .contentType) ?? .prose
        self.position = max(0, try container.decodeIfPresent(Int.self, forKey: .position) ?? 0)
    }
}

public struct DistillRankRequest: Codable, Sendable, Equatable {
    public let query: String
    public let chunks: [DistillRankChunk]
    public let toolArguments: String?
    public let topK: Int?
    public let encoderLane: String?

    public init(
        query: String,
        chunks: [DistillRankChunk],
        toolArguments: String? = nil,
        topK: Int? = nil,
        encoderLane: String? = nil
    ) {
        self.query = query
        self.chunks = chunks
        self.toolArguments = toolArguments?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.topK = topK.map { max(1, $0) }
        self.encoderLane = encoderLane?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public struct DistillRankedChunk: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let contentType: DistillContentType
    public let position: Int
    public let bm25Score: Double
    public let embeddingScore: Double?
    public let finalScore: Double

    public init(
        id: String,
        text: String,
        contentType: DistillContentType,
        position: Int,
        bm25Score: Double,
        embeddingScore: Double?,
        finalScore: Double
    ) {
        self.id = id
        self.text = text
        self.contentType = contentType
        self.position = position
        self.bm25Score = bm25Score
        self.embeddingScore = embeddingScore
        self.finalScore = finalScore
    }
}

public struct DistillRankResponse: Codable, Sendable, Equatable {
    public let query: String
    public let encoderLane: String?
    public let results: [DistillRankedChunk]

    public init(query: String, encoderLane: String? = nil, results: [DistillRankedChunk]) {
        self.query = query
        self.encoderLane = encoderLane
        self.results = results
    }
}

public struct DistillEmbedRequest: Codable, Sendable, Equatable {
    public let inputs: [String]
    public let encoderLane: String?

    public init(inputs: [String], encoderLane: String? = nil) {
        self.inputs = inputs
        self.encoderLane = encoderLane?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public struct DistillEmbedResponse: Codable, Sendable, Equatable {
    public let available: Bool
    public let encoderLane: String?
    public let dimensions: Int
    public let embeddings: [[Double]]
    public let message: String?

    public init(
        available: Bool,
        encoderLane: String? = nil,
        dimensions: Int = 0,
        embeddings: [[Double]] = [],
        message: String? = nil
    ) {
        self.available = available
        self.encoderLane = encoderLane
        self.dimensions = max(0, dimensions)
        self.embeddings = embeddings
        self.message = message
    }
}

/// Deterministic, model-agnostic token estimator. The distilled output is only
/// ever sent to the provider in compressed form, so the *raw* token cost is
/// never observed from the provider — it must be estimated. The same estimator
/// is applied to input and output, so the delta is an honest, consistent
/// measure of how much compression removed (an estimate, not a billed count).
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        let chars = text.count
        guard chars > 0 else { return 0 }
        // OpenAI's published rule of thumb (~4 chars/token for English) blended
        // with a word-count floor so short, word-dense lines aren't undercounted.
        let byChars = Int((Double(chars) / 4.0).rounded())
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).count
        let byWords = Int((Double(words) * 1.3).rounded())
        return max(1, max(byChars, byWords))
    }
}

public enum TokenSaverSR1SavingsEstimator {
    /// The human-readable transcript is materially longer than a tokenizer estimate
    /// of the displayed text, so both legs are scaled by this transcript-expansion factor.
    public static let transcriptExpansionFactor = 3
    /// Default-agent verbosity credit. Without Token Saver, an agent emits a markedly
    /// more verbose answer than even the humanized transcript (≈3x). The SR1-compressed
    /// reply therefore avoids ≈3x more tokens than the raw human-length delta implies, so
    /// the recorded saving is credited at this factor. See plan token-saver-local-llm-savings.
    public static let defaultAgentVerbosityFactor = 3
    /// Combined factor applied to both legs. Exposed so tests assert the credited intent
    /// instead of a magic literal; scaling both legs keeps `saved = input - output` and
    /// triples the recorded saving versus the raw transcript delta.
    public static let effectiveExpansionFactor = transcriptExpansionFactor * defaultAgentVerbosityFactor

    public static func estimate(sr1: String, humanized: String) -> (inputTokens: Int, outputTokens: Int, savedTokens: Int) {
        let inputTokens = max(0, humanized.count * effectiveExpansionFactor)
        let outputTokens = max(0, sr1.count * effectiveExpansionFactor)
        return (
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            savedTokens: max(inputTokens - outputTokens, 0)
        )
    }
}

public struct DistillSavingsRecord: Sendable, Equatable {
    public let provider: String
    /// Saved-tokens mode, already folded with the producing engine where known
    /// (e.g. "command-output (bert)") so the Token Saver breakdown shows savings per
    /// technique. `routeStage` carries the raw engine for callers that want it.
    public let mode: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let savedTokens: Int
    /// Cache relevance of this saving (G3): `tool_output_oneshot` is consumed once and
    /// never re-sent (char-delta is honest/cache-neutral); `prompt` is cache-relevant;
    /// `sr1_humanize`/`watch` are response-side. Lets the headline keep only honest rows.
    public let cacheState: String
    /// The engine that produced this saving (deterministic / BERT / MLX), raw. `mode`
    /// already folds it in for display; kept here for telemetry/tests.
    public let routeStage: TokenSaverRouteStage?

    public init(provider: String, mode: String, inputTokens: Int, outputTokens: Int, savedTokens: Int, cacheState: String = "unknown", routeStage: TokenSaverRouteStage? = nil) {
        self.provider = provider
        self.mode = mode
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.savedTokens = max(0, savedTokens)
        self.cacheState = cacheState
        self.routeStage = routeStage
    }
}

public enum DistillSavingsCalculator {
    public static func record(for request: DistillRequest, response: DistillResponse, defaultProvider: String = "unknown") -> DistillSavingsRecord? {
        guard request.recordSavings == true else { return nil }
        guard request.effectiveRunMode == .optimize else { return nil }
        let provider = request.provider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? defaultProvider

        switch request.mode {
        case .commandOutput:
            // Honest token accounting: the raw command output is replaced by the
            // distilled output before it ever reaches the provider, so savings =
            // estimate(raw input) - estimate(distilled output). The response
            // already carries those estimates from the scheduler.
            return DistillSavingsRecord(
                provider: provider,
                mode: TokenSaverEngineLabel.mode(base: "command-output", stage: response.routeStage),
                inputTokens: response.inputTokens,
                outputTokens: response.outputTokens,
                savedTokens: response.savedTokens,
                cacheState: request.cacheState ?? "tool_output_oneshot",
                routeStage: response.routeStage
            )
        case .sr1Humanize:
            // The agent emitted the compressed SR1 response instead of the full
            // human-language answer; use the SR1 transcript-expansion estimator
            // so short semantic prefixes still get credit for the avoided prose.
            let sr1 = sr1ResponseSource(from: request.input)
            let estimate = TokenSaverSR1SavingsEstimator.estimate(sr1: sr1, humanized: response.output)
            return DistillSavingsRecord(
                provider: provider,
                mode: "sr1-humanize",
                inputTokens: estimate.inputTokens,
                outputTokens: estimate.outputTokens,
                savedTokens: estimate.savedTokens,
                cacheState: "sr1_humanize"
            )
        case .longText, .watchSummary:
            return DistillSavingsRecord(
                provider: provider,
                mode: TokenSaverEngineLabel.mode(base: request.mode.rawValue, stage: response.routeStage),
                inputTokens: response.inputTokens,
                outputTokens: response.outputTokens,
                savedTokens: response.savedTokens,
                cacheState: request.cacheState ?? (request.mode == .longText ? "prompt" : "watch"),
                routeStage: response.routeStage
            )
        }
    }

    private static func sr1ResponseSource(from input: String) -> String {
        let marker = "SR1_RESPONSE:"
        guard let range = input.range(of: marker) else {
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return input[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum DistillError: Error, Sendable, Equatable {
    case emptyInput
    case queueFull
    case invalidOutput

    /// The HTTP status + stable error code the distill service returns for this
    /// error. Extracted as a pure seam (QA-mac:54) so the saturation wire contract
    /// is testable without the MLX runtime: a bounded-worker overflow MUST surface
    /// as 429 `queue_full`, which the managed CLI then fail-opens on (non-200 ->
    /// echo stdin), so distill saturation never blocks an agent turn.
    public var httpMapping: (status: Int, code: String) {
        switch self {
        case .emptyInput:   return (400, "empty_input")
        case .queueFull:    return (429, "queue_full")
        case .invalidOutput: return (502, "invalid_output")
        }
    }
}

public protocol DistillRuntime: Sendable {
    func distill(_ request: DistillRequest) async throws -> String

    /// Like `distill`, but also reports which engine produced the output so Token
    /// Saver can attribute saved tokens per technique (deterministic / BERT / MLX).
    /// Default impl runs `distill` and reports an unknown engine (`nil`), so existing
    /// runtimes keep working unchanged; engine-aware runtimes override this.
    func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult

    /// Called by the scheduler when no requests remain in flight. Runtimes that hold
    /// a GPU buffer cache (MLX) return it to the OS here so a long-lived warm server
    /// idles near its model's resident size instead of accumulating across requests.
    func reclaimIdleMemory()

    /// Pay any one-time cold-start cost (model load, Metal kernel JIT) up front so
    /// the first real request never blocks on it on a live agent turn. Default no-op.
    /// Throws if the warmup inference fails, so the caller can mark the service degraded.
    func warmup() async throws
}

public extension DistillRuntime {
    /// Default: run the legacy text path and report an unknown engine.
    func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
        DistillStageResult(output: try await distill(request), stage: nil)
    }
    /// Runtimes without a reclaimable cache (deterministic/local) need do nothing.
    func reclaimIdleMemory() {}
    /// Runtimes with no cold-start cost need do nothing.
    func warmup() async throws {}
}

/// Maps a distill mode to its Token Saver routing lane (for route telemetry).
public func tokenSaverLane(for mode: DistillMode) -> TokenSaverLane {
    switch mode {
    case .commandOutput: return .commandOutput
    case .longText: return .longText
    case .watchSummary: return .watchSummary
    case .sr1Humanize: return .sr1Humanize
    }
}

/// Human-readable, breakdown-stable mode label that folds the producing engine
/// into the saved-tokens `mode` so the Token Saver UI shows savings per technique
/// (e.g. "command-output (bert)" vs "command-output (model)").
public enum TokenSaverEngineLabel {
    public static func mode(base: String, stage: TokenSaverRouteStage?) -> String {
        guard let stage else { return base }
        switch stage {
        case .deterministic: return "\(base) (deterministic)"
        case .encoderBERT: return "\(base) (bert)"
        case .llmMLX: return "\(base) (model)"
        case .verbatim: return base
        }
    }
}

public struct DistillResultCacheKey: Hashable, Sendable, Equatable {
    /// Bump when any crusher, prompt template, or literal-preservation rule changes.
    public static let pipelineVersion = "distill-pipeline-v1"

    public let mode: DistillMode
    public let inputSHA256: String
    public let questionSHA256: String?
    public let maxOutputCharacters: Int
    public let modelRevision: String
    public let pipelineVersion: String

    public init(
        request: DistillRequest,
        modelRevision: String = DistillApprovedModel.id,
        pipelineVersion: String = Self.pipelineVersion
    ) {
        self.mode = request.mode
        self.inputSHA256 = Self.sha256Hex(request.input)
        self.questionSHA256 = request.question.map(Self.sha256Hex)
        self.maxOutputCharacters = request.maxOutputCharacters
        self.modelRevision = modelRevision
        self.pipelineVersion = pipelineVersion
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct DistillResultCacheEntry: Sendable {
    let output: String
    let stage: TokenSaverRouteStage?
    let insertedAt: Date
}

private enum SR1LineParser {
    private static let semanticPrefixes = Set("SCDRONP")
    private static let variableKeyPattern = #"#[A-Za-z][0-9]+"#

    static func parseSemanticLine(_ line: String) -> (prefix: Character, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first?.uppercased().first,
              semanticPrefixes.contains(first) else {
            return nil
        }

        let rest = trimmed.dropFirst()
        guard let delimiter = rest.first else { return nil }

        let content: String
        if delimiter == ":" || delimiter == "=" {
            content = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        } else if delimiter == " " || delimiter == "\t" {
            content = rest.trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        guard !content.isEmpty else { return nil }
        return (first, content)
    }

    static func parseSemanticSegments(_ text: String) -> [(prefix: Character, content: String)] {
        text
            .split(whereSeparator: \.isNewline)
            .flatMap { parseSemanticSegmentsInLine(String($0)) }
    }

    static func expandVariables(in text: String, from source: String) -> String {
        let aliases = extractVariableAliases(source)
        guard !aliases.isEmpty else { return text }

        var expanded = text
        for (key, value) in aliases.sorted(by: { $0.key.count > $1.key.count }) {
            expanded = replacingWholeVariableKey(key, with: value, in: expanded)
        }
        return expanded
    }

    private static func parseSemanticSegmentsInLine(_ rawLine: String) -> [(prefix: Character, content: String)] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return [] }
        let markerRanges = semanticMarkerRanges(in: line)
        guard markerRanges.count >= 2 else {
            return parseSemanticLine(line).map { [$0] } ?? []
        }

        var segments: [(prefix: Character, content: String)] = []
        for index in markerRanges.indices {
            let marker = markerRanges[index]
            let contentStart = line.index(after: marker.range.lowerBound)
            let delimiter = line[contentStart]
            let segmentStart = (delimiter == ":" || delimiter == "=")
                ? line.index(after: contentStart)
                : contentStart
            let segmentEnd = index + 1 < markerRanges.count
                ? markerRanges[index + 1].range.lowerBound
                : line.endIndex
            let content = line[segmentStart..<segmentEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !content.isEmpty {
                segments.append((marker.prefix, content))
            }
        }
        return segments
    }

    private static func semanticMarkerRanges(in line: String) -> [(prefix: Character, range: Range<String.Index>)] {
        var result: [(Character, Range<String.Index>)] = []
        var index = line.startIndex
        while index < line.endIndex {
            let next = line.index(after: index)
            defer { index = next }
            let prefix = line[index].uppercased().first ?? "\0"
            guard semanticPrefixes.contains(prefix),
                  next < line.endIndex,
                  isSemanticDelimiter(line[next]),
                  isSemanticBoundary(before: index, in: line) else {
                continue
            }
            result.append((prefix, index..<next))
        }
        return result
    }

    private static func isSemanticDelimiter(_ character: Character) -> Bool {
        character == ":" || character == "=" || character == " " || character == "\t"
    }

    private static func isSemanticBoundary(before index: String.Index, in line: String) -> Bool {
        if index == line.startIndex { return true }
        var cursor = line.index(before: index)
        while cursor > line.startIndex, line[cursor].isWhitespace {
            cursor = line.index(before: cursor)
        }
        let previous = line[cursor]
        return previous == "." || previous == ";" || previous == "!" || previous == "?"
    }

    private static func extractVariableAliases(_ text: String) -> [String: String] {
        var aliases: [String: String] = [:]
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines {
            for (key, value) in keyValueAliases(in: line) {
                aliases[key] = value
            }
            for (key, value) in valueKeyAliases(in: line) {
                aliases[key] = value
            }
        }
        return aliases
    }

    private static func keyValueAliases(in line: String) -> [(String, String)] {
        let pattern = #"(#[A-Za-z][0-9]+)\s*=\s*([^;\n]+?)(?=(?:\s+#[A-Za-z][0-9]+\s*=)|$)"#
        return regexMatches(pattern: pattern, in: line).compactMap { result in
            guard result.numberOfRanges >= 3,
                  let keyRange = Range(result.range(at: 1), in: line),
                  let valueRange = Range(result.range(at: 2), in: line),
                  let value = cleanedVariableValue(String(line[valueRange])) else {
                return nil
            }
            return (String(line[keyRange]), value)
        }
    }

    private static func valueKeyAliases(in line: String) -> [(String, String)] {
        let pattern = #"(^|[.;]\s+)([^#=;\n]{2,100}?)\s*=\s*(#[A-Za-z][0-9]+)(?=\s|[.;,]|$)"#
        return regexMatches(pattern: pattern, in: line).compactMap { result in
            guard result.numberOfRanges >= 4,
                  let valueRange = Range(result.range(at: 2), in: line),
                  let keyRange = Range(result.range(at: 3), in: line),
                  let value = cleanedVariableValue(String(line[valueRange])) else {
                return nil
            }
            return (String(line[keyRange]), value)
        }
    }

    private static func cleanedVariableValue(_ raw: String) -> String? {
        var value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.localizedCaseInsensitiveContains("dict:") ||
            value.range(of: #"\b[ScdronpSCDRONP]\s*=\s*[A-Za-z-]+"#, options: .regularExpression) != nil {
            return nil
        }
        let segments = parseSemanticSegments(value)
        if segments.count == 1 {
            value = segments[0].content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        }
        guard !value.isEmpty,
              value.range(of: variableKeyPattern, options: .regularExpression) == nil else {
            return nil
        }
        return value
    }

    private static func replacingWholeVariableKey(_ key: String, with value: String, in text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: key) + #"(?![A-Za-z0-9_])"#
        var output = text
        for result in regexMatches(pattern: pattern, in: output).reversed() {
            guard let range = Range(result.range, in: output) else { continue }
            output.replaceSubrange(range, with: value)
        }
        return output
    }

    private static func regexMatches(pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }
}

public actor DistillScheduler {
    private let runtime: any DistillRuntime
    private let maxConcurrentRequests: Int
    private let maxQueueDepth: Int
    private let resultCacheTTLSeconds: TimeInterval
    private let resultCacheCapacity: Int
    private var activeRequests = 0
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var resultCache: [DistillResultCacheKey: DistillResultCacheEntry] = [:]
    private var resultCacheHits = 0
    private var resultCacheMisses = 0
    /// C5: per-request engine routing telemetry sink (deterministic / BERT / MLX +
    /// wall-clock). nil in unit/library use; the sidecar wires it to the metrics
    /// recorder so the BERT-first payoff is observable in /metrics.
    private let routeRecorder: (@Sendable (TokenSaverRouteTelemetryEvent) async -> Void)?

    public init(
        runtime: any DistillRuntime,
        maxConcurrentRequests: Int = 8,
        maxQueueDepth: Int = 0,
        resultCacheTTLSeconds: TimeInterval = 1_800,
        resultCacheCapacity: Int = 128,
        routeRecorder: (@Sendable (TokenSaverRouteTelemetryEvent) async -> Void)? = nil
    ) {
        self.runtime = runtime
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.maxQueueDepth = max(0, maxQueueDepth)
        self.resultCacheTTLSeconds = max(0, resultCacheTTLSeconds)
        self.resultCacheCapacity = max(0, resultCacheCapacity)
        self.routeRecorder = routeRecorder
    }

    public var activeRequestCount: Int {
        activeRequests
    }

    public var queuedRequestCount: Int {
        waiters.count
    }

    public var resultCacheCount: Int {
        resultCache.count
    }

    public var resultCacheHitCount: Int {
        resultCacheHits
    }

    public var resultCacheMissCount: Int {
        resultCacheMisses
    }

    public func submit(_ request: DistillRequest) async throws -> DistillResponse {
        let trimmed = request.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DistillError.emptyInput }
        if request.effectiveRunMode != .optimize {
            return try await audit(request)
        }
        let cacheKey = DistillResultCacheKey(request: request)
        if let cached = cachedEntry(for: cacheKey) {
            resultCacheHits += 1
            return response(for: request, output: cached.output, stage: cached.stage)
        }
        if resultCacheTTLSeconds > 0, resultCacheCapacity > 0 {
            resultCacheMisses += 1
        }

        try await acquireSlot()
        defer { releaseSlot() }

        let started = Date()
        let staged = try await runtime.distillStaged(request)
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
        let output = String(staged.output.prefix(request.maxOutputCharacters))
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DistillError.invalidOutput
        }
        if let routeRecorder {
            await routeRecorder(TokenSaverRouteTelemetryEvent(
                lane: tokenSaverLane(for: request.mode),
                stage: staged.stage ?? .llmMLX,
                wallClockMilliseconds: elapsedMs
            ))
        }
        storeCachedOutput(output, stage: staged.stage, for: cacheKey)
        return response(for: request, output: output, stage: staged.stage)
    }

    private func audit(_ request: DistillRequest) async throws -> DistillResponse {
        try await acquireSlot()
        defer { releaseSlot() }

        let started = Date()
        let raw = try await runtime.distill(request)
        let candidate = String(raw.prefix(request.maxOutputCharacters))
        let inputTokens = TokenEstimator.estimate(request.input)
        let candidateTokens = candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? inputTokens
            : TokenEstimator.estimate(candidate)
        let wouldSaveTokens = max(inputTokens - candidateTokens, 0)
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
        let report = DistillAuditReport(
            runMode: request.effectiveRunMode,
            candidateOutputCharacters: candidate.count,
            candidateOutputTokens: candidateTokens,
            wouldSaveTokens: wouldSaveTokens,
            accepted: !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && candidate.count < request.input.count,
            wallClockMilliseconds: elapsedMs
        )
        return DistillResponse(
            requestID: request.id,
            output: request.input,
            inputCharacters: request.input.count,
            inputTokens: inputTokens,
            outputTokens: inputTokens,
            runMode: request.effectiveRunMode,
            auditReport: report
        )
    }

    private func response(for request: DistillRequest, output: String, stage: TokenSaverRouteStage?) -> DistillResponse {
        DistillResponse(
            requestID: request.id,
            output: output,
            inputCharacters: request.input.count,
            inputTokens: TokenEstimator.estimate(request.input),
            outputTokens: TokenEstimator.estimate(output),
            runMode: request.effectiveRunMode,
            routeStage: stage
        )
    }

    private func cachedEntry(for key: DistillResultCacheKey) -> DistillResultCacheEntry? {
        guard resultCacheTTLSeconds > 0,
              let entry = resultCache[key] else {
            return nil
        }
        if Date().timeIntervalSince(entry.insertedAt) > resultCacheTTLSeconds {
            resultCache.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    private func storeCachedOutput(_ output: String, stage: TokenSaverRouteStage?, for key: DistillResultCacheKey) {
        guard resultCacheCapacity > 0,
              !RetrieveHandleSanitizer.containsHandle(output) else {
            return
        }
        let now = Date()
        resultCache[key] = DistillResultCacheEntry(output: output, stage: stage, insertedAt: now)
        guard resultCache.count > resultCacheCapacity,
              let oldest = resultCache.min(by: { $0.value.insertedAt < $1.value.insertedAt })?.key else {
            return
        }
        resultCache.removeValue(forKey: oldest)
    }

    private func acquireSlot() async throws {
        if activeRequests < maxConcurrentRequests {
            activeRequests += 1
            return
        }
        guard waiters.count < maxQueueDepth else {
            throw DistillError.queueFull
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseSlot() {
        guard !waiters.isEmpty else {
            activeRequests -= 1
            // Drained to idle: hand the runtime a chance to return cached GPU memory
            // to the OS. Skipped while requests are still queued/in flight so the
            // cache stays warm during bursts (distill runs back-to-back constantly).
            if activeRequests == 0 {
                runtime.reclaimIdleMemory()
            }
            return
        }
        waiters.removeFirst().resume()
    }
}

public struct LocalDistillRuntime: DistillRuntime {
    static let contentRouter = DistillContentRouter()
    public static let commandOutputIntentConfidenceThreshold = 0.82

    public init() {}

    public func distill(_ request: DistillRequest) async throws -> String {
        try await distillStaged(request).output
    }

    public func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
        // Every LocalDistillRuntime path is deterministic (no model), so the engine
        // attribution is uniformly `.deterministic`.
        DistillStageResult(output: try await Self.deterministicOutput(request), stage: .deterministic)
    }

    private static func deterministicOutput(_ request: DistillRequest) async throws -> String {
        // Deterministic content routing (G4): lossless structural compression of
        // JSON/log payloads on the pure "compress this" modes, before any heuristic
        // summarization. Skipped for .commandOutput (it must answer the contract
        // question, not blind-minify) and .sr1Humanize (a translation task).
        if request.mode == .longText || request.mode == .watchSummary,
           let routed = contentRouter.route(request.input, options: routerOptions(for: request)) {
            return routed.output
        }
        if request.mode == .commandOutput {
            return commandOutputFallback(
                input: request.input,
                question: request.question,
                maxOutputCharacters: request.maxOutputCharacters
            )
        }
        let lines = request.input
            .split(whereSeparator: \.isNewline)
            .prefix(12)
            .map(String.init)
        let prefix: String
        switch request.mode {
        case .commandOutput:
            prefix = "O"
        case .longText:
            prefix = "S"
        case .watchSummary:
            prefix = "D"
        case .sr1Humanize:
            return humanizeSR1Fallback(request.input, maxOutputCharacters: request.maxOutputCharacters)
        }
        return lines.isEmpty ? "\(prefix) no content" : lines.map { "\(prefix) \($0)" }.joined(separator: "\n")
    }

    static func routerOptions(for request: DistillRequest) -> DistillRouterOptions {
        DistillRouterOptions(
            allowElementDropping: false,
            contextPressure: DistillRouterOptions.pressure(
                inputCharacters: request.input.count,
                outputBudgetCharacters: request.maxOutputCharacters
            ),
            query: request.question
        )
    }

    static func commandOutputFallback(input: String, question explicitQuestion: String?, maxOutputCharacters: Int) -> String {
        let parsed = splitLegacyCommandPayload(input)
        let question = (explicitQuestion?.nilIfEmpty ?? parsed.question ?? "Compress command output. Return only the useful signal.")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = parsed.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let extracted = commandOutputExtraction(source: source, question: question) {
            return boundedCommandOutput(extracted, maxOutputCharacters: maxOutputCharacters)
        }

        let sourceLines = source
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sourceLines.isEmpty else { return "NONE" }

        let output: String
        if sourceLines.count <= 12 {
            output = sourceLines.joined(separator: "\n")
        } else {
            let head = sourceLines.prefix(6)
            let tail = sourceLines.suffix(4)
            output = (head + ["... \(sourceLines.count - 10) lines omitted ..."] + tail).joined(separator: "\n")
        }

        return boundedCommandOutput(output, maxOutputCharacters: maxOutputCharacters)
    }

    static func commandOutputExtraction(
        source rawSource: String,
        question: String,
        intent explicitIntent: CommandOutputIntent? = nil
    ) -> String? {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerQuestion = question.lowercased()
        let intent = explicitIntent ?? heuristicCommandOutputIntent(question)
        guard !source.isEmpty else {
            return lowerQuestion.contains("none") ? "NONE" : nil
        }

        let sourceLines = source
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if intent == .cwdAndFiles {
            let cwd = sourceLines.first ?? source
            let files = sourceLines.dropFirst()
            return "CWD=\(cwd); FILES=\(files.isEmpty ? "EMPTY" : files.joined(separator: ", "))"
        } else if intent == .cwdOnly {
            return sourceLines.first ?? source
        } else if intent == .pathsOnly {
            let paths = pathLines(from: sourceLines, htmlOnly: lowerQuestion.contains("html") && lowerQuestion.contains("file"))
            return paths.isEmpty ? "NONE" : paths.joined(separator: "\n")
        } else if intent == .existsMissing {
            return existsMissingSummary(source: source)
        } else if intent == .tokenVerdict {
            return passFailSummary(source: source, sourceLines: sourceLines, lowerQuestion: lowerQuestion)
        } else if intent == .statusCode {
            return httpStatusSummary(sourceLines: sourceLines)
        } else if intent == .jsonOnly {
            return firstLikelyJSON(from: source)
        }
        return nil
    }

    static func commandOutputIntent(
        question: String,
        classifier: CommandOutputIntentClassifier? = nil,
        confidenceThreshold: Double = commandOutputIntentConfidenceThreshold
    ) -> CommandOutputIntent? {
        if let decision = classifier?(question),
           decision.isConfident(minimumConfidence: confidenceThreshold) {
            return decision.intent
        }
        return heuristicCommandOutputIntent(question)
    }

    private static func heuristicCommandOutputIntent(_ question: String) -> CommandOutputIntent? {
        let lowerQuestion = question.lowercased()
        if lowerQuestion.contains("cwd=") && lowerQuestion.contains("files=") { return .cwdAndFiles }
        if lowerQuestion.contains("cwd") && lowerQuestion.contains("only") { return .cwdOnly }
        if (lowerQuestion.contains("pass") || lowerQuestion.contains("fail")) &&
            (lowerQuestion.contains("only") || lowerQuestion.contains("return") || lowerQuestion.contains("did ")) {
            return .tokenVerdict
        }
        if lowerQuestion.contains("filename") ||
            lowerQuestion.contains("file path") ||
            lowerQuestion.contains("paths only") ||
            lowerQuestion.contains("keep paths only") {
            return .pathsOnly
        }
        if lowerQuestion.contains("exists") && lowerQuestion.contains("missing") { return .existsMissing }
        if lowerQuestion.contains("status code") { return .statusCode }
        if lowerQuestion.contains("json") && lowerQuestion.contains("only") { return .jsonOnly }
        return nil
    }

    static func splitLegacyCommandPayload(_ input: String) -> (question: String?, output: String) {
        guard let promptRange = input.range(of: "PROMPT:\n"),
              let inputRange = input.range(of: "\n\nINPUT:\n"),
              promptRange.upperBound <= inputRange.lowerBound else {
            return (nil, input)
        }
        let question = String(input[promptRange.upperBound..<inputRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let output = String(input[inputRange.upperBound...])
        return (question, output)
    }

    private static func passFailSummary(source: String, sourceLines: [String], lowerQuestion: String) -> String? {
        let lowerSource = source.lowercased()
        let badLines = sourceLines.filter { line in
            let lowerLine = line.lowercased()
            if hasRegexMatch(#"\b0\s+failures?\b|\bno\s+failures?\b"#, in: lowerLine) {
                return false
            }
            return hasRegexMatch(#"\b(fail(?:ed|ure|ures)?|error|errors|crashloop|nonzero)\b|\bexit\s+[1-9][0-9]*\b|\bcode\s*=\s*[1-9][0-9]*\b"#, in: lowerLine)
        }
        if !badLines.isEmpty {
            let shown = badLines.prefix(3)
            let hiddenCount = badLines.count - shown.count
            let suffix = hiddenCount > 0 ? "; +\(hiddenCount) more" : ""
            return "FAIL " + shown.joined(separator: "; ") + suffix
        }
        if lowerSource.contains("http/1.1 200") || lowerSource.contains("http/2 200") || lowerSource.contains(" 200 ") {
            return "PASS HTTP 200"
        }
        if hasRegexMatch(#"\b([0-9]+\s+passed|passed|pass)\b|\b0\s+failures?\b|\bexit\s+0\b|\b(?:exists_)?code\s*=\s*0\b"#, in: lowerSource) {
            return "PASS"
        }
        if lowerQuestion.contains("if code 0") {
            return existsMissingSummary(source: source)
        }
        return nil
    }

    private static func httpStatusSummary(sourceLines: [String]) -> String {
        let status = sourceLines.first { $0.lowercased().hasPrefix("http/") } ?? "HTTP status missing"
        let contentType = sourceLines.first { $0.lowercased().hasPrefix("content-type:") } ?? "content-type missing"
        let verdict = status.contains(" 200") ? "PASS" : "FAIL"
        return "\(verdict) \(status); \(contentType)"
    }

    private static func firstLikelyJSON(from source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidJSON(trimmed) { return trimmed }
        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count > 1, lines.allSatisfy(isValidJSON) else { return nil }
        return lines.joined(separator: "\n")
    }

    private static func existsMissingSummary(source: String) -> String? {
        let lowerSource = source.lowercased()
        guard hasRegexMatch(#"\b(?:exists_)?code\s*=\s*-?[0-9]+\b"#, in: lowerSource) else {
            return nil
        }
        return hasRegexMatch(#"\b(?:exists_)?code\s*=\s*0\b"#, in: lowerSource) ? "EXISTS" : "MISSING"
    }

    private static func pathLines(from sourceLines: [String], htmlOnly: Bool) -> [String] {
        sourceLines.compactMap { line in
            let path = line.trimmingCharacters(in: CharacterSet(charactersIn: "`\"' "))
            guard looksLikePath(path) else { return nil }
            if htmlOnly, !path.lowercased().contains(".html") { return nil }
            return path
        }
    }

    private static func looksLikePath(_ line: String) -> Bool {
        guard !line.isEmpty,
              !line.contains("\u{0}"),
              !line.contains("://"),
              line.range(of: #"\s{2,}"#, options: .regularExpression) == nil else {
            return false
        }
        return line.hasPrefix("/") ||
            line.hasPrefix("./") ||
            line.hasPrefix("../") ||
            line.contains("/") ||
            line.range(of: #"\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil
    }

    private static func isValidJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private static func hasRegexMatch(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func boundedCommandOutput(_ output: String, maxOutputCharacters: Int) -> String {
        guard output.count > maxOutputCharacters else { return output }
        let suffix = "\n... truncated to \(maxOutputCharacters) chars ..."
        guard maxOutputCharacters > suffix.count else {
            return String(suffix.prefix(maxOutputCharacters))
        }
        return String(output.prefix(maxOutputCharacters - suffix.count)) + suffix
    }

    static func humanizeSR1Fallback(_ input: String, maxOutputCharacters: Int) -> String {
        let portuguese = input.localizedCaseInsensitiveContains("portuguese") ||
            input.localizedCaseInsensitiveContains("português")
        let source = input.components(separatedBy: "SR1_RESPONSE:").last ?? input
        let labels: [Character: String] = portuguese
            ? ["S": "Estado", "C": "Contexto", "D": "Acao", "R": "Risco", "O": "Resultado", "N": "Nao fazer", "P": "Prova"]
            : ["S": "State", "C": "Context", "D": "Action", "R": "Risk", "O": "Outcome", "N": "Do not do", "P": "Proof"]
        let lines = source
            .split(whereSeparator: \.isNewline)
            .flatMap { raw -> [String] in
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return [] }
                let lower = line.lowercased()
                guard lower != "sr1",
                      lower != "dict",
                      lower != "dict:",
                      !lower.hasPrefix("s=state"),
                      !lower.hasPrefix("c=context"),
                      !lower.hasPrefix("d=action"),
                      !lower.hasPrefix("r=risk"),
                      !lower.hasPrefix("o=outcome"),
                      !lower.hasPrefix("n=no-go"),
                      !lower.hasPrefix("p=proof") else {
                    return []
                }
                let segments = SR1LineParser.parseSemanticSegments(line)
                guard !segments.isEmpty else {
                    return [line]
                }
                return segments.map { parsed in
                    guard let label = labels[parsed.prefix] else { return parsed.content }
                    return "\(label): \(parsed.content)"
                }
            }
        let output = lines.isEmpty
            ? (portuguese ? "Nao consegui expandir a resposta comprimida." : "I could not expand the compressed response.")
            : lines.joined(separator: "\n")
        let expanded = SR1LineParser.expandVariables(in: output, from: source)
        return String(expanded.prefix(maxOutputCharacters))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - ChatSession prompt-cache key

/// Pure, nonisolated cache-key type for `ChatSession` reuse.
/// Two requests with identical system instructions and the same maxTokens
/// budget can share a `ChatSession` instance, avoiding repeated object
/// allocation and the `SerialAccessContainer` setup cost on every call.
///
/// The key is intentionally value-typed and `Sendable` so it can be used
/// freely across concurrency domains without import overhead.
public struct ChatSessionCacheKey: Hashable, Sendable {
    /// The full system-instructions string.  Stored verbatim so that `==`
    /// is exact (hash collisions cannot produce a false cache hit).
    public let instructions: String
    public let maxTokens: Int

    /// Stable hash of `instructions` for external inspection / logging.
    /// NOT used for `Hashable` conformance — Swift synthesizes `hash(into:)`
    /// from `instructions` + `maxTokens` directly, so there is no collision risk.
    public var instructionsHash: Int {
        var hasher = Hasher()
        hasher.combine(instructions)
        return hasher.finalize()
    }

    public init(instructions: String, maxTokens: Int) {
        self.instructions = instructions
        self.maxTokens = maxTokens
    }

    /// Decision helper: returns `true` when a cached session built from
    /// `cachedKey` can be reused for a new request described by `newKey`.
    /// Both the instructions string and the maxTokens budget must match exactly.
    public static func canReuse(cached: ChatSessionCacheKey, new: ChatSessionCacheKey) -> Bool {
        cached == new
    }
}

/// Thread-safe store that maps `ChatSessionCacheKey` to a live `ChatSession`.
/// Each lookup either returns the existing session (cache hit) or creates a
/// new one via the provided factory closure (cache miss + insert).
///
/// The caller is responsible for calling `session.clear()` before reusing a
/// session so prior KV history never leaks into an independent distill call.
actor ChatSessionStore {
    private var sessions: [ChatSessionCacheKey: ChatSession] = [:]

    /// Return the cached session for `key`, or create-and-store one using
    /// `factory()`.  The `factory` closure is called at most once per key.
    func session(
        for key: ChatSessionCacheKey,
        creating factory: () -> ChatSession
    ) -> ChatSession {
        if let existing = sessions[key] {
            return existing
        }
        let fresh = factory()
        sessions[key] = fresh
        return fresh
    }

    /// Evict all cached sessions (e.g. after `reclaimIdleMemory`).
    func evictAll() {
        sessions.removeAll()
    }

    /// Number of cached sessions (for testing).
    var count: Int { sessions.count }
}

public struct MLXDistillRuntime: DistillRuntime {
    private let modelContainer: ModelContainer

    /// Upper bound on MLX's reusable Metal buffer cache. By default the cache limit
    /// equals the memory limit (~1.5× the device working set — many GB), so a
    /// long-lived server hoards reusable buffers and never returns them: a ~1GB model
    /// was observed growing past 20GB RSS. A small warm cache keeps recurrent requests
    /// fast while capping steady-state growth; `reclaimIdleMemory()` empties even this
    /// between bursts. 128 MB is comfortably above one distill generation's working set.
    static let gpuCacheLimitBytes = 128 * 1024 * 1024
    /// Hard ceiling on total MLX allocation. A distill run needs ~1–2GB; the previous
    /// 6GB ceiling allowed a single live sidecar (plus any orphan) to pin most of a
    /// 16GB machine and freeze RemoteCode/UI under memory pressure. 3GB still admits
    /// a healthy concurrent burst while leaving headroom for agent/provider children.
    static let gpuMemoryLimitBytes = 3 * 1024 * 1024 * 1024

    /// Deterministic-first content router (G4): structured payloads are compressed
    /// losslessly on the CPU and never reach the model.
    static let contentRouter = DistillContentRouter()

    /// Serializes GPU generation to one job at a time (under the scheduler's
    /// admission gate). Protects against Metal memory pressure and renderer contention.
    private let lane = MLXGenerationLane()

    /// Prompt-cache: one `ChatSession` per (mode, maxTokens) key.  Reusing the
    /// same session object avoids repeated object allocation and
    /// `SerialAccessContainer` setup on the hot path.  The session is cleared
    /// before each independent distill call so prior KV history never leaks.
    private let sessionStore = ChatSessionStore()

    public init(modelDirectory: URL) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DistillServiceError.modelValidationFailed("model directory missing: \(modelDirectory.path)")
        }
        MLX.Memory.memoryLimit = Self.gpuMemoryLimitBytes
        MLX.Memory.cacheLimit = Self.gpuCacheLimitBytes
        NSLog("RemoteCodeDistillService MLX memory bounded: cacheLimit=\(Self.gpuCacheLimitBytes / 1_048_576)MB memoryLimit=\(Self.gpuMemoryLimitBytes / 1_048_576)MB")
        // Install the patched gemma4 model so LLMModelFactory can load KV-shared / fully-quantized
        // Gemma 4 checkpoints (e.g. distill-E4B). Idempotent; no effect on non-Gemma-4 models.
        await RCGemma4ModelOverride.register()
        self.modelContainer = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory,
            using: MLXHuggingFaceBridges.tokenizerLoader()
        )
    }

    /// Return the bounded GPU buffer cache to the OS once the server drains to idle.
    /// Also evicts cached `ChatSession` instances so the next burst starts fresh
    /// (avoids holding references to KV buffers that were just reclaimed).
    public func reclaimIdleMemory() {
        MLX.Memory.clearCache()
        Task { await sessionStore.evictAll() }
    }

    /// Pay the cold-start cost (Metal kernel JIT, first allocation) before the
    /// server accepts requests, so no live agent turn ever awaits a cold model.
    public func warmup() async throws {
        let parameters = GenerateParameters(maxTokens: 1, temperature: 0)
        let session = ChatSession(
            modelContainer,
            instructions: "warmup",
            generateParameters: parameters,
            additionalContext: ["enable_thinking": false]
        )
        await lane.acquire()
        _ = try await session.respond(to: "ok")
        await lane.release()
        reclaimIdleMemory()
        NSLog("RemoteCodeDistillService MLX warmup complete")
    }

    /// Test seam: raw model generation bypassing the deterministic content router and the
    /// distill faithfulness/literal guards, so the coherence of the loaded model can be asserted
    /// directly (a model that loads but is numerically broken emits junk here).
    func generateRawForTesting(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        let session = ChatSession(
            modelContainer,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0),
            additionalContext: ["enable_thinking": false]
        )
        await lane.acquire()
        let raw: String
        do {
            raw = try await session.respond(to: prompt)
        } catch {
            await lane.release()
            throw error
        }
        await lane.release()
        return Self.cleanOutput(raw)
    }

    static func routerOptions(for request: DistillRequest) -> DistillRouterOptions {
        DistillRouterOptions(
            allowElementDropping: false,
            contextPressure: DistillRouterOptions.pressure(
                inputCharacters: request.input.count,
                outputBudgetCharacters: request.maxOutputCharacters
            ),
            query: request.question
        )
    }

    public func distill(_ request: DistillRequest) async throws -> String {
        try await distillStaged(request).output
    }

    public func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
        if let deterministic = Self.deterministicCommandOutput(for: request) {
            return DistillStageResult(output: deterministic, stage: .deterministic)
        }

        // Deterministic content routing (G4): lossless structural compression of
        // JSON/log on the pure "compress this" modes, before the model is invoked.
        // Covers the .longText prompt-compression path. .commandOutput is excluded
        // (honors its contract question above) and .sr1Humanize is a translation.
        if request.mode == .longText || request.mode == .watchSummary,
           let routed = Self.contentRouter.route(request.input, options: Self.routerOptions(for: request)) {
            return DistillStageResult(output: routed.output, stage: .deterministic)
        }

        let raw = try await mlxGeneratedOutput(request)
        return DistillStageResult(output: raw, stage: .llmMLX)
    }

    private func mlxGeneratedOutput(_ request: DistillRequest) async throws -> String {
        let instructions = Self.systemInstructions(for: request.mode)
        let maxTokens = Self.maxTokens(for: request)
        let cacheKey = ChatSessionCacheKey(instructions: instructions, maxTokens: maxTokens)
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0,
            topP: 0.9,
            topK: 20
        )
        let session = await sessionStore.session(for: cacheKey) {
            ChatSession(
                modelContainer,
                instructions: instructions,
                generateParameters: parameters,
                additionalContext: ["enable_thinking": false]
            )
        }
        // Clear prior KV history so this independent distill call cannot
        // observe responses from previous, unrelated requests.
        await session.clear()
        let protected = Self.requestByProtectingTagsAndMarkers(request)
        await lane.acquire()
        let raw: String
        do {
            raw = try await session.respond(to: Self.prompt(for: protected.request))
        } catch {
            await lane.release()
            throw error
        }
        await lane.release()
        let output = Self.cleanOutput(raw)
        let normalizedOutput = request.mode == .commandOutput
            ? Self.collapseDuplicatedCommandOutput(output)
            : output
        let restoredOutput = protected.payload.restore(in: normalizedOutput)
        guard Self.isUsefulOutput(restoredOutput, mode: request.mode) else {
            return Self.fallbackOutput(for: request)
        }
        return Self.guardLossyProseOutput(restoredOutput, request: request)
    }

    static func requestByProtectingTagsAndMarkers(_ request: DistillRequest) -> (request: DistillRequest, payload: ProtectedTagPayload) {
        switch request.mode {
        case .longText, .watchSummary:
            let payload = TagAndMarkerProtector.protect(request.input)
            guard !payload.isEmpty else { return (request, payload) }
            return (
                DistillRequest(
                    id: request.id,
                    mode: request.mode,
                    priority: request.priority,
                    input: payload.text,
                    question: request.question,
                    provider: request.provider,
                    recordSavings: request.recordSavings ?? false,
                    runMode: request.effectiveRunMode,
                    maxOutputCharacters: request.maxOutputCharacters
                ),
                payload
            )
        case .commandOutput, .sr1Humanize:
            return (request, ProtectedTagPayload(text: request.input, replacements: [:]))
        }
    }

    /// N5 guard for the lossy prose modes (.longText/.watchSummary): if the model's
    /// compression dropped a load-bearing literal (file:line, UUID, hash, long number,
    /// diff change line) present in the input, reject it and return the input verbatim.
    /// .commandOutput is exempt — it is contract extraction, not literal-preserving
    /// compression — and .sr1Humanize is a translation.
    static func guardLossyProseOutput(_ output: String, request: DistillRequest) -> String {
        switch request.mode {
        case .longText, .watchSummary:
            let literalGuarded = LiteralPreservation.guarded(original: request.input, compressed: output)
            guard literalGuarded.droppedLiteral == nil else { return literalGuarded.output }
            return FaithfulnessGate.validate(original: request.input, compressed: literalGuarded.output).accepted
                ? literalGuarded.output
                : request.input
        case .commandOutput, .sr1Humanize:
            return output
        }
    }

    static func deterministicCommandOutput(
        for request: DistillRequest,
        classifier: CommandOutputIntentClassifier? = nil
    ) -> String? {
        guard request.mode == .commandOutput else { return nil }
        let parsed = LocalDistillRuntime.splitLegacyCommandPayload(request.input)
        // Intent extraction needs a REAL question to know what to extract. Falling back to the
        // input ITSELF as the question makes the classifier misfire on data keywords — a source
        // file with "FAIL"/"error" comments returns a bogus PASS/FAIL line, markdown returns
        // "PASS" — replacing the whole output with a 4-byte token. With no question, skip intent
        // extraction entirely and let the content router / BERT / LLM handle the content.
        guard let question = (request.question?.nilIfEmpty ?? parsed.question) else { return nil }
        guard let intent = LocalDistillRuntime.commandOutputIntent(question: question, classifier: classifier),
              let output = LocalDistillRuntime.commandOutputExtraction(source: parsed.output, question: question, intent: intent) else {
            return nil
        }
        return LocalDistillRuntime.boundedCommandOutput(output, maxOutputCharacters: request.maxOutputCharacters)
    }

    private static func systemInstructions(for mode: DistillMode) -> String {
        switch mode {
        case .sr1Humanize:
            return """
            You translate /distill output into human language for a software engineer.
            /distill output is compressed Military English + AR-0/AR-1 for prompts, task specs, commands, or agent instructions.
            It may contain Dict/Dict+, dynamic inline variables, and fixed prefixes S, C, D, R, O, N, P.
            Prefix meanings are usually S=state/status, C=cause/context, D=action/decision, R=risk/blocker, O=outcome/output, N=constraint/no-go, P=pass criteria/proof.
            Expand aliases from Dict and Dict+ when present. Keep aliases unchanged when no definition is present.
            Preserve constraints, pass criteria, required output, blockers, uncertainty, file names, paths, commands, environment variables, IDs, security warnings, and production/data-loss warnings.
            Do not invent missing facts. Do not claim execution happened unless the input says it happened.
            Write concise natural language in the requested language or locale.
            Return only the translation. No preamble. No markdown.
            """
        case .commandOutput:
            return """
            You compress shell or command output for another model that will act on your answer.
            Output ONLY the requested format. No preamble. No "Here is". No explanation unless the question asks for one.
            If the question asks for JSON, return raw JSON only, no fences.
            If the question asks for a list, one item per line, no bullets, no numbering.
            If the question asks PASS/FAIL/SAFE/REVIEW/UNSAFE, output that token first on the same line, then the supporting detail.
            Match the language of the question.
            Never invent data not present in the output. If a field is missing, omit it or say so explicitly.
            If the output is insufficient, reply only with "distill: Insufficient information to output anything." in the language of the question.
            If the source is already shorter than your answer would be, reuse the source wording.
            Keep prose answers to one sentence, max three short lines. Structured answers may be longer when the format requires it.
            Never ask for more input.
            """
        case .longText, .watchSummary:
            return """
            You compress long text into /distill compressed language for another AI model that already understands it.
            Use Military English with fixed prefixes, one item per line: S=state, C=context, D=action, R=risk, O=outcome, N=no-go, P=proof.
            Preserve every exact command, file path, file:line, error string, number, ID, status, and proof verbatim.
            Drop filler, repetition, hedging, and politeness. Never invent facts. No preamble, no explanation, no markdown.
            Output only the compressed S/C/D/R/O/N/P lines. If the source is already shorter than your answer would be, reuse the source wording.
            """
        }
    }

    private static func prompt(for request: DistillRequest) -> String {
        switch request.mode {
        case .commandOutput:
            let question = request.question?.nilIfEmpty ?? "Compress the command output. Return only the useful signal."
            return """
            /no_think
            Command output:
            \(fitInput(request.input))

            Question: \(question)
            """
        case .longText:
            return """
            /no_think
            Compress the following into /distill compressed language (S/C/D/R/O/N/P lines).
            Preserve exact commands, paths, file:line, errors, numbers, IDs, and status verbatim.

            \(fitInput(request.input))

            OUTPUT:
            """
        case .watchSummary:
            return """
            /no_think
            Summarize the relevant change into /distill compressed language (S/C/D/R/O/N/P lines).
            Preserve exact commands, paths, file:line, errors, numbers, IDs verbatim.

            \(fitInput(request.input))

            OUTPUT:
            """
        case .sr1Humanize:
            return """
            /no_think
            Rewrite the SR1_RESPONSE into natural language for the user.
            Use TARGET_LANGUAGE.
            Output at most \(request.maxOutputCharacters) characters.
            Output only the final user-facing answer.
            Preserve exact commands, paths, IDs, errors, numbers, statuses, and proof.
            Do not output markdown unless the answer needs a short list.
            Do not output SR1 prefixes, prefix dictionaries, XML tags, or instructions.

            \(request.input)

            OUTPUT:
            """
        }
    }

    private static func maxTokens(for request: DistillRequest) -> Int {
        min(512, max(32, request.maxOutputCharacters / 4))
    }

    static func fitInput(_ input: String, maxCharacters: Int = 24_000) -> String {
        guard input.count > maxCharacters else { return input }
        var maxKeep = max(8, min(120, maxCharacters / 120))
        while maxKeep >= 8 {
            let keepLast = max(2, min(8, maxKeep / 4))
            let scored = DistillImportanceScorer.compact(input, maxKeep: maxKeep, keepLast: keepLast)
            if scored.droppedLines > 0, scored.compacted.count <= maxCharacters {
                return scored.compacted
            }
            maxKeep = (maxKeep * 3) / 4
        }
        return headTailFitInput(input, maxCharacters: maxCharacters)
    }

    private static func headTailFitInput(_ input: String, maxCharacters: Int) -> String {
        let half = max(0, maxCharacters / 2 - 50)
        let head = input.prefix(half)
        let tail = input.suffix(half)
        let dropped = input.count - head.count - tail.count
        return "\(head)\n...\n[\(dropped) chars truncated] ...\n\(tail)"
    }

    static func cleanOutput(_ output: String) -> String {
        var cleaned = output
        while let start = cleaned.range(of: "<think>", options: .caseInsensitive),
              let end = cleaned.range(
                of: "</think>",
                options: .caseInsensitive,
                range: start.upperBound..<cleaned.endIndex
              ) {
            cleaned.removeSubrange(start.lowerBound..<end.upperBound)
        }
        cleaned = cleaned.replacingOccurrences(of: "<think>", with: "", options: .caseInsensitive)
        cleaned = cleaned.replacingOccurrences(of: "</think>", with: "", options: .caseInsensitive)
        return cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func isUsefulOutput(_ output: String, mode: DistillMode) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return false }

        let lowercased = trimmed.lowercased()
        guard !lowercased.contains("<think>"),
              !lowercased.contains("dict:"),
              !lowercased.contains("s=state"),
              !lowercased.contains("d distill"),
              !lowercased.hasPrefix("prompt:"),
              !lowercased.hasPrefix("input:"),
              !lowercased.contains("\nprompt:"),
              !lowercased.contains("\ninput:") else {
            return false
        }
        if mode == .sr1Humanize, Self.isLikelySR1(trimmed) {
            return false
        }

        let meaningfulCharacters = trimmed.filter { character in
            character.isLetter || character.isNumber
        }
        return meaningfulCharacters.count > 1
    }

    static func collapseDuplicatedCommandOutput(_ output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, lines.count.isMultiple(of: 2) else {
            return output
        }
        let midpoint = lines.count / 2
        let first = Array(lines[..<midpoint])
        let second = Array(lines[midpoint...])
        guard first == second else { return output }
        return first.joined(separator: "\n")
    }

    static func isUsefulDistillOutput(_ output: String) -> Bool {
        isUsefulOutput(output, mode: .longText)
    }

    public static func fallbackOutput(for request: DistillRequest) -> String {
        let prefix: String
        switch request.mode {
        case .commandOutput:
            return LocalDistillRuntime.commandOutputFallback(
                input: request.input,
                question: request.question,
                maxOutputCharacters: request.maxOutputCharacters
            )
        case .longText:
            prefix = "S"
        case .watchSummary:
            prefix = "D"
        case .sr1Humanize:
            return LocalDistillRuntime.humanizeSR1Fallback(request.input, maxOutputCharacters: request.maxOutputCharacters)
        }

        let lines = request.input
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(8)
            .map { "\(prefix) \($0)" }

        let output = lines.isEmpty ? "\(prefix) no content" : lines.joined(separator: "\n")
        return String(output.prefix(request.maxOutputCharacters))
    }

    private static func isLikelySR1(_ output: String) -> Bool {
        var semanticLines = 0
        var prefixes = Set<Character>()
        for raw in output.split(whereSeparator: \.isNewline).prefix(12) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let segments = SR1LineParser.parseSemanticSegments(line)
            if segments.count >= 2 {
                return true
            }
            if let parsed = segments.first {
                semanticLines += 1
                prefixes.insert(parsed.prefix)
            }
        }
        if semanticLines == 1, let prefix = prefixes.first, prefix != "O" {
            return true
        }
        return semanticLines >= 2 && prefixes.count >= 2
    }
}
