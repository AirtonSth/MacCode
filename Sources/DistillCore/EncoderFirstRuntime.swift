import Foundation

/// Wraps any `DistillRuntime` with a BERT-first extractive lane (C3) for large command
/// output. The real encoder selects the most query-relevant lines BEFORE the wrapped
/// runtime's expensive path (the MLX LLM) is touched — and, crucially, it runs even
/// when the LLM failed to load and the wrapped runtime is the deterministic fallback.
/// So the "BERT technique" actually contributes saved tokens independently of the LLM.
///
/// Ordering, for `.commandOutput`:
///   1. precise deterministic intent extraction (PASS/FAIL, cwd+files, …) — fast + exact
///   2. BERT extractive line-selection for large, intent-less logs — `.encoderBERT`
///   3. otherwise delegate to the wrapped runtime (LLM or deterministic fallback)
/// Everything is fail-open: a nil encoder lane, an encoder miss, or no net reduction
/// all fall through to the wrapped runtime, so this never regresses the working path.
public struct EncoderFirstRuntime: DistillRuntime {
    private let wrapped: any DistillRuntime
    private let encoderLane: EncoderLane?

    public init(wrapping wrapped: any DistillRuntime, encoderLane: EncoderLane?) {
        self.wrapped = wrapped
        self.encoderLane = encoderLane
    }

    /// Build the encoder lane from the approved embedder. Returns nil (fail-open) when no
    /// approved embedder is available; the caller then wraps with `encoderLane: nil` and
    /// the runtime behaves exactly like the wrapped one.
    public static func makeEncoderLane() -> EncoderLane? {
        guard let backend = try? MLXEmbeddingBackend() else {
            FileHandle.standardError.write(Data("RemoteCodeDistillService BERT encoder lane unavailable; running without the encoder technique\n".utf8))
            return nil
        }
        FileHandle.standardError.write(Data("RemoteCodeDistillService BERT encoder lane enabled (\(TokenSaverApprovedEncoderManifests.defaultEmbedder.id))\n".utf8))
        return EncoderLane(
            manifest: TokenSaverApprovedEncoderManifests.defaultEmbedder,
            scorer: backend.scoreFn(),
            warmup: { try await backend.warmup() },
            reclaimIdleMemory: { await backend.reclaimIdleMemory() }
        )
    }

    public func distill(_ request: DistillRequest) async throws -> String {
        try await distillStaged(request).output
    }

    public func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
        if request.mode == .commandOutput {
            // 1. Precise deterministic intent extraction first (smaller + exact than BERT).
            if let deterministic = MLXDistillRuntime.deterministicCommandOutput(for: request) {
                return DistillStageResult(output: deterministic, stage: .deterministic)
            }
            // 1b. Lossless deterministic content-router BEFORE BERT, so STRUCTURED content
            // (JSON, repetitive logs/search) is crushed exactly. BERT does line-selection, which
            // corrupts JSON (it drops braces/keys) — the router's JSONCrusher minifies losslessly
            // instead. `.losslessOnly` so nothing needs a reversible handle; structure-dropping
            // formats (diff, source code) return nil here and fall through to BERT below.
            let routable = LocalDistillRuntime.splitLegacyCommandPayload(request.input).output
            let lossless = DistillRouterOptions(
                allowElementDropping: false,
                query: request.question
            )
            if let routed = DistillContentRouter().route(routable, options: lossless) {
                return DistillStageResult(output: routed.output, stage: .deterministic)
            }
            // 2. BERT extractive selection for large, intent-less logs / code.
            if let bert = await encoderExtractedCommandOutput(request) {
                return DistillStageResult(output: bert, stage: .encoderBERT)
            }
        }
        // 3. Delegate (LLM, deterministic router, or fallback).
        return try await wrapped.distillStaged(request)
    }

    public func rawGenerate(system: String, user: String, maxTokens: Int) async -> String? {
        await wrapped.rawGenerate(system: system, user: user, maxTokens: maxTokens)
    }

    public func warmup() async throws {
        await encoderLane?.warmup()
        try await wrapped.warmup()
    }

    public func reclaimIdleMemory() {
        wrapped.reclaimIdleMemory()
        let lane = encoderLane
        Task { await lane?.reclaimIdleMemory() }
    }

    /// BERT extractive selection for `.commandOutput`. Returns nil (fall through) when:
    /// no approved encoder, small/non-line input, lane fallback, or no net reduction.
    /// Never throws.
    func encoderExtractedCommandOutput(_ request: DistillRequest) async -> String? {
        guard request.mode == .commandOutput, let encoderLane else { return nil }
        let parsed = LocalDistillRuntime.splitLegacyCommandPayload(request.input)
        let source = parsed.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitQuestion = request.question?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawQuery = (explicitQuestion?.isEmpty == false ? explicitQuestion : parsed.question)
            ?? "Keep only the lines relevant to the task."
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = source
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Only worth the encoder for genuinely large multi-line output.
        guard lines.count >= 24, source.count >= 2_000 else { return nil }
        let chunks = lines.enumerated().map { index, line in
            QueryAwareChunk(id: "L\(index)", text: line, position: index)
        }
        let topK = max(8, min(lines.count / 3, 60))
        guard let ranked = await encoderLane.rank(chunks: chunks, query: query, topK: topK),
              !ranked.isEmpty else {
            return nil
        }
        // Reassemble selected lines in original order so the extract stays readable.
        let keep = Set(ranked.map(\.chunk.id))
        let selected = chunks.filter { keep.contains($0.id) }.map(\.text)
        guard !selected.isEmpty else { return nil }
        let output = LocalDistillRuntime.boundedCommandOutput(
            selected.joined(separator: "\n"),
            maxOutputCharacters: request.maxOutputCharacters
        )
        // Accept only a real reduction; otherwise let the wrapped runtime try.
        // PERF: never-inflate via O(1) utf8.count (not Character.count grapheme walk).
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              output.utf8.count < source.utf8.count else {
            return nil
        }
        return output
    }
}
