import Foundation

/// Distill generate via an OpenAI-compatible HTTP endpoint (oMLX, llama.cpp server).
/// Deterministic crushers still run first. Transport errors fail open to the original.
public struct OpenAICompatibleDistillRuntime: DistillRuntime {
    public let baseURL: URL
    public let model: String
    public let token: String
    public let timeout: TimeInterval
    private let complete: @Sendable (String, String, String, Int) async -> String?

    public init(
        baseURL: URL,
        model: String,
        token: String = "",
        timeout: TimeInterval = 20,
        complete: (@Sendable (String, String, String, Int) async -> String?)? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.token = token
        self.timeout = timeout
        if let complete {
            self.complete = complete
        } else {
            let url = baseURL
            let tok = token
            let limit = timeout
            self.complete = { system, user, modelID, maxTokens in
                await Self.postChat(
                    baseURL: url,
                    token: tok,
                    timeout: limit,
                    system: system,
                    user: user,
                    model: modelID,
                    maxTokens: maxTokens
                )
            }
        }
    }

    public func distill(_ request: DistillRequest) async throws -> String {
        try await distillStaged(request).output
    }

    public func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
        if let structured = LocalDistillRuntime.structuredCommandOutput(for: request) {
            return DistillStageResult(output: structured, stage: .deterministic)
        }
        if let deterministic = MLXDistillRuntime.deterministicCommandOutput(for: request) {
            return DistillStageResult(output: deterministic, stage: .deterministic)
        }
        if let repeated = MLXDistillRuntime.deterministicExactRepeatWireOutput(for: request) {
            return DistillStageResult(output: repeated, stage: .deterministic)
        }
        if request.mode == .wireEncode {
            return DistillStageResult(output: request.input, stage: .verbatim)
        }
        if request.mode == .longText || request.mode == .watchSummary,
           let routed = MLXDistillRuntime.contentRouter.route(
            request.input,
            options: MLXDistillRuntime.routerOptions(for: request)
           ) {
            return DistillStageResult(output: routed.output, stage: .deterministic)
        }

        let system = DistillPrompt.systemInstructions(for: request.mode)
        let user = DistillPrompt.userPrompt(for: request)
        let requested = max(32, request.maxOutputCharacters / 4)
        let maxTokens = request.mode == .wireEncode ? min(128, requested) : min(512, requested)
        guard let raw = await complete(system, user, model, maxTokens) else {
            return DistillStageResult(output: request.input, stage: .llmMLX)
        }
        let cleaned = MLXDistillRuntime.cleanOutput(raw)
        let normalized = request.mode == .commandOutput
            ? MLXDistillRuntime.collapseDuplicatedCommandOutput(cleaned)
            : cleaned
        guard MLXDistillRuntime.isUsefulOutput(normalized, mode: request.mode) else {
            return DistillStageResult(output: request.input, stage: .llmMLX)
        }
        return DistillStageResult(
            output: MLXDistillRuntime.guardLossyProseOutput(normalized, request: request),
            stage: .llmMLX
        )
    }

    public func rawGenerate(system: String, user: String, maxTokens: Int) async -> String? {
        await complete(system, user, model, max(32, min(512, maxTokens)))
    }

    static func postChat(
        baseURL: URL,
        token: String,
        timeout: TimeInterval,
        system: String,
        user: String,
        model: String,
        maxTokens: Int
    ) async -> String? {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        if let content = message["content"] as? String, !content.isEmpty {
            return content
        }
        return nil
    }
}
