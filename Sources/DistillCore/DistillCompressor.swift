import Foundation

public struct DistillCompressor: Sendable {
    private let scheduler: DistillScheduler
    private let savingsRecorder: (@Sendable (DistillSavingsRecord) async -> Void)?

    public init(
        runtime: any DistillRuntime = LocalDistillRuntime(),
        maxConcurrentRequests: Int = 2,
        maxQueueDepth: Int = 0,
        savingsRecorder: (@Sendable (DistillSavingsRecord) async -> Void)? = nil
    ) {
        self.scheduler = DistillScheduler(
            runtime: runtime,
            maxConcurrentRequests: maxConcurrentRequests,
            maxQueueDepth: maxQueueDepth
        )
        self.savingsRecorder = savingsRecorder
    }

    public func compress(
        _ input: String,
        mode: DistillMode = .longText,
        question: String? = nil,
        provider: String? = nil,
        runMode: DistillRunMode = .optimize,
        maxOutputCharacters: Int = 4_000
    ) async throws -> DistillResponse {
        let request = DistillRequest(
            mode: mode,
            priority: .agent,
            input: input,
            question: question,
            provider: provider,
            recordSavings: savingsRecorder != nil,
            runMode: runMode,
            maxOutputCharacters: maxOutputCharacters
        )
        let response = try await scheduler.submit(request)
        if let savingsRecorder,
           let record = DistillSavingsCalculator.record(for: request, response: response) {
            await savingsRecorder(record)
        }
        return response
    }
}

public enum DistillDeployMode: String, Codable, Sendable, Equatable {
    case library
    case cliWrap = "cli_wrap"
    case reverseProxy = "reverse_proxy"
    case mcpRetrieveOnly = "mcp_retrieve_only"
    case mcpCompress = "mcp_compress"
}

public struct DistillDeployDecision: Codable, Sendable, Equatable {
    public let mode: DistillDeployMode
    public let allowed: Bool
    public let reason: String
}

public enum DistillDeployPolicy {
    public static func decision(for mode: DistillDeployMode) -> DistillDeployDecision {
        switch mode {
        case .library:
            return DistillDeployDecision(
                mode: mode,
                allowed: true,
                reason: "stable in-process compress() API; no proxy cache mutation"
            )
        case .mcpRetrieveOnly:
            return DistillDeployDecision(
                mode: mode,
                allowed: true,
                reason: "retrieve-only MCP recovers CCR originals without double-paying compression"
            )
        case .cliWrap:
            return DistillDeployDecision(
                mode: mode,
                allowed: false,
                reason: "evaluation required before wrapping provider CLIs"
            )
        case .reverseProxy:
            return DistillDeployDecision(
                mode: mode,
                allowed: false,
                reason: "HTTP reverse proxy can poison provider prompt/KV cache"
            )
        case .mcpCompress:
            return DistillDeployDecision(
                mode: mode,
                allowed: false,
                reason: "MCP compression pays extra tool round trips; use retrieve-only MCP"
            )
        }
    }
}
