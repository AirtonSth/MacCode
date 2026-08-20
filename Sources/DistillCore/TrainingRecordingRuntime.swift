import Foundation

/// Records SFT/rejected JSONL around any Distill generate, regardless of HTTP/CLI/MCP.
public struct TrainingRecordingRuntime: DistillRuntime {
    private let wrapped: any DistillRuntime
    private let writer: TokenSaverTrainingDatasetWriter?
    private let modelID: String
    private let source: String

    public init(
        wrapping wrapped: any DistillRuntime,
        writer: TokenSaverTrainingDatasetWriter?,
        modelID: String,
        source: String
    ) {
        self.wrapped = wrapped
        self.writer = writer
        self.modelID = modelID
        self.source = source
    }

    public func distill(_ request: DistillRequest) async throws -> String {
        try await distillStaged(request).output
    }

    public func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
        let staged = try await wrapped.distillStaged(request)
        if let writer, staged.stage == .llmMLX {
            writer.record(
                request: request,
                output: staged.output,
                stage: staged.stage,
                modelID: modelID,
                source: source
            )
        }
        return staged
    }

    public func warmup() async throws {
        try await wrapped.warmup()
    }

    public func reclaimIdleMemory() {
        wrapped.reclaimIdleMemory()
    }

    public func rawGenerate(system: String, user: String, maxTokens: Int) async -> String? {
        let out = await wrapped.rawGenerate(system: system, user: user, maxTokens: maxTokens)
        writer?.recordRaw(
            system: system,
            user: user,
            assistant: out,
            modelID: modelID,
            source: source
        )
        return out
    }
}
