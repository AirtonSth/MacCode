import Foundation
import Network
import CoreModel

/// Abstraction over the CCR reversible store, injected into the HTTP layer so
/// DistillCore stays free of a Persistence dependency. The sidecar's main()
/// adapts the Persistence `ReversibleContentStore` to this protocol.
public protocol ReversibleStoring: Sendable {
    /// Persist the original bytes and return a stable content handle.
    func storeOriginal(_ data: Data) throws -> String
    /// Recover the original bytes for a handle, or nil if unavailable.
    func retrieveOriginal(_ handle: String) throws -> Data?
}

public struct TokenSaverRecoveryRequestContext: Sendable, Equatable {
    public let workspaceID: String
    public let projectID: String
    public let threadID: String
    public let provider: String
    public let attemptID: String
    public let invocationID: String
    public let operationID: String

    public init(
        workspaceID: String,
        projectID: String,
        threadID: String,
        provider: String,
        attemptID: String,
        operationID: String,
        invocationID: String = ""
    ) {
        self.workspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.attemptID = attemptID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.invocationID = invocationID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.operationID = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasCompleteScope: Bool {
        !workspaceID.isEmpty && !projectID.isEmpty && !threadID.isEmpty
            && !provider.isEmpty && !attemptID.isEmpty
    }

    public var hasCompleteMutationContext: Bool {
        hasCompleteScope && !invocationID.isEmpty && !operationID.isEmpty
    }
}

public enum TokenSaverScopedRecoveryState: String, Sendable, Equatable {
    case prepared
    case delivered
    case acked
}

public struct TokenSaverScopedPreparation: Sendable, Equatable {
    public let capability: String
    public let idempotencyKey: String
    public let readBackVerified: Bool

    public init(
        capability: String,
        idempotencyKey: String,
        readBackVerified: Bool
    ) {
        self.capability = capability
        self.idempotencyKey = idempotencyKey
        self.readBackVerified = readBackVerified
    }
}

public struct TokenSaverScopedInvocationState: Sendable, Equatable {
    public let state: TokenSaverScopedRecoveryState
    public let transportOutcome: TokenSaverScopedDeliveryOutcome

    public init(state: TokenSaverScopedRecoveryState, transportOutcome: TokenSaverScopedDeliveryOutcome) {
        self.state = state
        self.transportOutcome = transportOutcome
    }
}

public enum TokenSaverScopedDeliveryOutcome: String, Sendable, Equatable {
    case notSent = "not_sent"
    case sentUnknown = "sent_unknown"
    case acked
    case failed
}

public protocol TokenSaverScopedRecoveryStoring: Sendable {
    func lookupInvocation(context: TokenSaverRecoveryRequestContext) throws -> TokenSaverScopedInvocationState?
    func prepareOriginal(_ data: Data, context: TokenSaverRecoveryRequestContext, lane: String) throws -> TokenSaverScopedPreparation
    func retrieveOriginal(capability: String, context: TokenSaverRecoveryRequestContext) throws -> Data?
    func markDelivered(capability: String, idempotencyKey: String, context: TokenSaverRecoveryRequestContext, outcome: TokenSaverScopedDeliveryOutcome) throws -> Bool
    func ack(capability: String, idempotencyKey: String, context: TokenSaverRecoveryRequestContext) throws -> Bool
}

public extension TokenSaverScopedRecoveryStoring {
    func lookupInvocation(context: TokenSaverRecoveryRequestContext) throws -> TokenSaverScopedInvocationState? { nil }
}

public struct DistillStatsProviderSavings: Codable, Sendable, Equatable {
    public let provider: String
    public let savedTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let runs: Int

    public init(provider: String, savedTokens: Int, inputTokens: Int, outputTokens: Int, runs: Int) {
        self.provider = provider
        self.savedTokens = savedTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.runs = runs
    }

    public enum CodingKeys: String, CodingKey {
        case provider
        case savedTokens = "saved_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case runs
    }
}

public struct DistillStatsModeSavings: Codable, Sendable, Equatable {
    public let provider: String
    public let mode: String
    public let savedTokens: Int
    public let runs: Int

    public init(provider: String, mode: String, savedTokens: Int, runs: Int) {
        self.provider = provider
        self.mode = mode
        self.savedTokens = savedTokens
        self.runs = runs
    }

    public enum CodingKeys: String, CodingKey {
        case provider
        case mode
        case savedTokens = "saved_tokens"
        case runs
    }
}

public struct DistillStatsSnapshot: Codable, Sendable, Equatable {
    public let totalSavedTokens: Int
    public let totalRuns: Int
    public let providers: [DistillStatsProviderSavings]
    public let modes: [DistillStatsModeSavings]

    public init(
        totalSavedTokens: Int = 0,
        totalRuns: Int = 0,
        providers: [DistillStatsProviderSavings] = [],
        modes: [DistillStatsModeSavings] = []
    ) {
        self.totalSavedTokens = totalSavedTokens
        self.totalRuns = totalRuns
        self.providers = providers
        self.modes = modes
    }

    public enum CodingKeys: String, CodingKey {
        case totalSavedTokens = "total_saved_tokens"
        case totalRuns = "total_runs"
        case providers
        case modes
    }
}

public protocol DistillStatsProviding: Sendable {
    func statsSnapshot() throws -> DistillStatsSnapshot
}

public enum ToolOutputTelemetrySkipReason: String, Sendable, Equatable {
    case overCap = "over_cap"
    case noService = "no_service"
    case notTerminal = "not_terminal"
}

public enum DistillApprovedModel {
    public static let id = TokenSaverApprovedModels.defaultModel.id
    public static let url = TokenSaverApprovedModels.defaultModel.url
    public static let runtime = TokenSaverApprovedModels.defaultModel.runtime
    public static let all = TokenSaverApprovedModels.all

    public static func isApproved(modelID: String, modelURL: String, runtime: String) -> Bool {
        TokenSaverApprovedModels.approved(id: modelID, url: modelURL, runtime: runtime) != nil
    }
}

public enum DistillServiceError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingRequiredOption(String)
    case invalidIntegerOption(String, String)
    case unsupportedRuntime(String)
    case unsupportedModel(modelID: String, modelURL: String)
    case unsupportedHost(String)
    case modelValidationFailed(String?)
    case mlxRuntimeUnavailable(String)

    public var description: String {
        switch self {
        case .missingRequiredOption(let option):
            return "missing required option \(option)"
        case .invalidIntegerOption(let option, let value):
            return "invalid integer option \(option)=\(value)"
        case .unsupportedRuntime(let runtime):
            return "unsupported runtime \(runtime)"
        case .unsupportedModel(let modelID, let modelURL):
            return "unsupported model \(modelID) \(modelURL)"
        case .unsupportedHost(let host):
            return "unsupported host \(host)"
        case .modelValidationFailed(let reason):
            return "approved MLX model validation failed: \(reason ?? "unknown reason")"
        case .mlxRuntimeUnavailable(let reason):
            return "MLX runtime unavailable: \(reason)"
        }
    }
}

/// Dispatch gate for the sidecar Mach-O. HTTP mode is only valid when this
/// binary is invoked as itself with flag-style arguments.
///
/// A leftover PATH wrapper (`~/.remote-code/bin/node`) is the same inode as
/// `RemoteCodeDistillService`. Codex is a `#!/usr/bin/env node` script, so
/// launching `codex app-server` becomes `node /opt/homebrew/bin/codex
/// app-server`. Falling through to `parse` then reports
/// `missing required option /opt/homebrew/bin/codex` and the app-server dies.
public enum DistillServiceLaunch {
    public static let httpServiceProgramName = "RemoteCodeDistillService"

    public static func shouldStartHTTPService(programName: String, arguments: [String]) -> Bool {
        let name = (programName as NSString).lastPathComponent
        guard name == httpServiceProgramName else { return false }
        if let first = arguments.first, !first.hasPrefix("--") {
            return false
        }
        return true
    }
}

public struct DistillServiceConfiguration: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let authToken: String
    public let appSupportDirectory: String
    public let runtime: String
    public let modelID: String
    public let modelURL: String
    public let maxConcurrentRequests: Int
    public let maxQueueDepth: Int
    /// Bounded wait for an admission slot (0 = unlimited until hard queue depth).
    /// Multi-thread agents need a finite budget so MLX latency does not stack.
    public let maxQueueWaitMilliseconds: Int
    public let idleTimeoutMS: Int
    /// Per-call wall-clock deadline for a single distill generation. On exceed, the
    /// runtime fails open to the deterministic fallback so the agent never stalls.
    public let mlxCallDeadlineMS: Int

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 0,
        authToken: String,
        appSupportDirectory: String,
        runtime: String = DistillApprovedModel.runtime,
        modelID: String = DistillApprovedModel.id,
        modelURL: String = DistillApprovedModel.url,
        maxConcurrentRequests: Int = 8,
        maxQueueDepth: Int = 64,
        maxQueueWaitMilliseconds: Int = 0,
        idleTimeoutMS: Int = 300_000,
        mlxCallDeadlineMS: Int = 20_000
    ) throws {
        guard host == "127.0.0.1" || host == "localhost" else {
            throw DistillServiceError.unsupportedHost(host)
        }
        guard !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DistillServiceError.missingRequiredOption("--auth-token")
        }
        guard !appSupportDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DistillServiceError.missingRequiredOption("--app-support-dir")
        }
        guard runtime == DistillApprovedModel.runtime else {
            throw DistillServiceError.unsupportedRuntime(runtime)
        }
        guard DistillApprovedModel.isApproved(modelID: modelID, modelURL: modelURL, runtime: runtime) else {
            throw DistillServiceError.unsupportedModel(modelID: modelID, modelURL: modelURL)
        }

        self.host = host
        self.port = port
        self.authToken = authToken
        self.appSupportDirectory = appSupportDirectory
        self.runtime = runtime
        self.modelID = modelID
        self.modelURL = modelURL
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.maxQueueDepth = max(0, maxQueueDepth)
        self.maxQueueWaitMilliseconds = max(0, maxQueueWaitMilliseconds)
        self.idleTimeoutMS = max(1_000, idleTimeoutMS)
        self.mlxCallDeadlineMS = max(1_000, mlxCallDeadlineMS)
    }

    public static func parse(arguments: [String]) throws -> DistillServiceConfiguration {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--") else {
                throw DistillServiceError.missingRequiredOption(key)
            }
            guard index + 1 < arguments.count else {
                throw DistillServiceError.missingRequiredOption(key)
            }
            values[String(key.dropFirst(2))] = arguments[index + 1]
            index += 2
        }

        func intValue(_ key: String, default defaultValue: Int) throws -> Int {
            guard let raw = values[key] else { return defaultValue }
            guard let parsed = Int(raw) else {
                throw DistillServiceError.invalidIntegerOption("--\(key)", raw)
            }
            return parsed
        }

        let rawPort = try intValue("port", default: 0)
        guard rawPort >= 0 && rawPort <= Int(UInt16.max) else {
            throw DistillServiceError.invalidIntegerOption("--port", "\(rawPort)")
        }

        return try DistillServiceConfiguration(
            host: values["host"] ?? "127.0.0.1",
            port: UInt16(rawPort),
            authToken: values["auth-token"] ?? "",
            appSupportDirectory: values["app-support-dir"] ?? "",
            runtime: values["runtime"] ?? DistillApprovedModel.runtime,
            modelID: values["model-id"] ?? DistillApprovedModel.id,
            modelURL: values["model-url"] ?? DistillApprovedModel.url,
            maxConcurrentRequests: try intValue("max-concurrent-requests", default: 8),
            maxQueueDepth: try intValue("max-queue-depth", default: 64),
            maxQueueWaitMilliseconds: try intValue("max-queue-wait-ms", default: 0),
            idleTimeoutMS: try intValue("idle-timeout-ms", default: 300_000),
            mlxCallDeadlineMS: try intValue("mlx-call-deadline-ms", default: 20_000)
        )
    }
}

public struct DistillServiceReadyEvent: Codable, Sendable, Equatable {
    public let event: String
    public let baseURL: String
    public let host: String
    public let port: UInt16
    public let pid: Int32
    public let protocolVersion: Int
    public let runtime: String
    public let modelID: String
    public let maxConcurrentRequests: Int
    public let maxQueueDepth: Int

    public enum CodingKeys: String, CodingKey {
        case event
        case baseURL = "base_url"
        case host
        case port
        case pid
        case protocolVersion = "protocol"
        case runtime
        case modelID = "model_id"
        case maxConcurrentRequests = "max_concurrent_requests"
        case maxQueueDepth = "max_queue_depth"
    }
}

public struct DistillServiceMetrics: Codable, Sendable, Equatable {
    public let activeRequests: Int
    public let totalRequests: Int
    public let successfulRequests: Int
    public let failedRequests: Int
    public let fallbackRequests: Int
    public let toolOutputEligible: Int
    public let toolOutputCompressed: Int
    public let toolOutputSkippedOverCap: Int
    public let toolOutputSkippedNoService: Int
    public let toolOutputSkippedNotTerminal: Int
    public let resultCacheHits: Int
    public let resultCacheMisses: Int
    public let volatileTokenWarnings: Int
    public let systemPromptHash: String?
    public let cacheDriftWarnings: Int
    public let encoderLaneInvocations: Int
    public let encoderLaneAccepts: Int
    public let encoderLaneFallbacks: Int
    public let encoderLaneFailures: Int
    public let encoderLaneDeadlineTimeouts: Int
    public let pipeHitRate: Double
    /// C5: share of routed requests answered WITHOUT the MLX LLM, and average
    /// wall-clock of the encoder stage vs the LLM stage (BERT-first payoff).
    public let resolvedWithoutLLMRate: Double
    public let encoderAvgMillis: Double
    public let llmAvgMillis: Double
    /// M6: end-to-end gate/hook latency percentiles (incl. GPU contention).
    public let gateP50Millis: Int
    public let gateP95Millis: Int
    public let maxConcurrentRequests: Int

    public enum CodingKeys: String, CodingKey {
        case activeRequests = "active_requests"
        case totalRequests = "total_requests"
        case successfulRequests = "successful_requests"
        case failedRequests = "failed_requests"
        case fallbackRequests = "fallback_requests"
        case toolOutputEligible = "tool_output_eligible"
        case toolOutputCompressed = "tool_output_compressed"
        case toolOutputSkippedOverCap = "tool_output_skipped_over_cap"
        case toolOutputSkippedNoService = "tool_output_skipped_no_service"
        case toolOutputSkippedNotTerminal = "tool_output_skipped_not_terminal"
        case resultCacheHits = "result_cache_hits"
        case resultCacheMisses = "result_cache_misses"
        case volatileTokenWarnings = "volatile_token_warnings"
        case systemPromptHash = "system_prompt_hash"
        case cacheDriftWarnings = "cache_drift_warnings"
        case encoderLaneInvocations = "encoder_lane_invocations"
        case encoderLaneAccepts = "encoder_lane_accepts"
        case encoderLaneFallbacks = "encoder_lane_fallbacks"
        case encoderLaneFailures = "encoder_lane_failures"
        case encoderLaneDeadlineTimeouts = "encoder_lane_deadline_timeouts"
        case pipeHitRate = "pipe_hit_rate"
        case resolvedWithoutLLMRate = "resolved_without_llm_rate"
        case encoderAvgMillis = "encoder_avg_millis"
        case llmAvgMillis = "llm_avg_millis"
        case gateP50Millis = "gate_p50_millis"
        case gateP95Millis = "gate_p95_millis"
        case maxConcurrentRequests = "max_concurrent_requests"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            activeRequests: try container.decode(Int.self, forKey: .activeRequests),
            totalRequests: try container.decode(Int.self, forKey: .totalRequests),
            successfulRequests: try container.decode(Int.self, forKey: .successfulRequests),
            failedRequests: try container.decode(Int.self, forKey: .failedRequests),
            fallbackRequests: try container.decodeIfPresent(Int.self, forKey: .fallbackRequests) ?? 0,
            toolOutputEligible: try container.decodeIfPresent(Int.self, forKey: .toolOutputEligible) ?? 0,
            toolOutputCompressed: try container.decodeIfPresent(Int.self, forKey: .toolOutputCompressed) ?? 0,
            toolOutputSkippedOverCap: try container.decodeIfPresent(Int.self, forKey: .toolOutputSkippedOverCap) ?? 0,
            toolOutputSkippedNoService: try container.decodeIfPresent(Int.self, forKey: .toolOutputSkippedNoService) ?? 0,
            toolOutputSkippedNotTerminal: try container.decodeIfPresent(Int.self, forKey: .toolOutputSkippedNotTerminal) ?? 0,
            resultCacheHits: try container.decodeIfPresent(Int.self, forKey: .resultCacheHits) ?? 0,
            resultCacheMisses: try container.decodeIfPresent(Int.self, forKey: .resultCacheMisses) ?? 0,
            volatileTokenWarnings: try container.decodeIfPresent(Int.self, forKey: .volatileTokenWarnings) ?? 0,
            systemPromptHash: try container.decodeIfPresent(String.self, forKey: .systemPromptHash),
            cacheDriftWarnings: try container.decodeIfPresent(Int.self, forKey: .cacheDriftWarnings) ?? 0,
            encoderLaneInvocations: try container.decodeIfPresent(Int.self, forKey: .encoderLaneInvocations) ?? 0,
            encoderLaneAccepts: try container.decodeIfPresent(Int.self, forKey: .encoderLaneAccepts) ?? 0,
            encoderLaneFallbacks: try container.decodeIfPresent(Int.self, forKey: .encoderLaneFallbacks) ?? 0,
            encoderLaneFailures: try container.decodeIfPresent(Int.self, forKey: .encoderLaneFailures) ?? 0,
            encoderLaneDeadlineTimeouts: try container.decodeIfPresent(Int.self, forKey: .encoderLaneDeadlineTimeouts) ?? 0,
            pipeHitRate: try container.decodeIfPresent(Double.self, forKey: .pipeHitRate) ?? 0,
            resolvedWithoutLLMRate: try container.decodeIfPresent(Double.self, forKey: .resolvedWithoutLLMRate) ?? 0,
            encoderAvgMillis: try container.decodeIfPresent(Double.self, forKey: .encoderAvgMillis) ?? 0,
            llmAvgMillis: try container.decodeIfPresent(Double.self, forKey: .llmAvgMillis) ?? 0,
            gateP50Millis: try container.decodeIfPresent(Int.self, forKey: .gateP50Millis) ?? 0,
            gateP95Millis: try container.decodeIfPresent(Int.self, forKey: .gateP95Millis) ?? 0,
            maxConcurrentRequests: try container.decode(Int.self, forKey: .maxConcurrentRequests)
        )
    }

    public init(
        activeRequests: Int,
        totalRequests: Int,
        successfulRequests: Int,
        failedRequests: Int,
        fallbackRequests: Int,
        toolOutputEligible: Int = 0,
        toolOutputCompressed: Int = 0,
        toolOutputSkippedOverCap: Int = 0,
        toolOutputSkippedNoService: Int = 0,
        toolOutputSkippedNotTerminal: Int = 0,
        resultCacheHits: Int = 0,
        resultCacheMisses: Int = 0,
        volatileTokenWarnings: Int = 0,
        systemPromptHash: String? = nil,
        cacheDriftWarnings: Int = 0,
        encoderLaneInvocations: Int = 0,
        encoderLaneAccepts: Int = 0,
        encoderLaneFallbacks: Int = 0,
        encoderLaneFailures: Int = 0,
        encoderLaneDeadlineTimeouts: Int = 0,
        pipeHitRate: Double = 0,
        resolvedWithoutLLMRate: Double = 0,
        encoderAvgMillis: Double = 0,
        llmAvgMillis: Double = 0,
        gateP50Millis: Int = 0,
        gateP95Millis: Int = 0,
        maxConcurrentRequests: Int
    ) {
        self.activeRequests = activeRequests
        self.totalRequests = totalRequests
        self.successfulRequests = successfulRequests
        self.failedRequests = failedRequests
        self.fallbackRequests = fallbackRequests
        self.toolOutputEligible = max(0, toolOutputEligible)
        self.toolOutputCompressed = max(0, toolOutputCompressed)
        self.toolOutputSkippedOverCap = max(0, toolOutputSkippedOverCap)
        self.toolOutputSkippedNoService = max(0, toolOutputSkippedNoService)
        self.toolOutputSkippedNotTerminal = max(0, toolOutputSkippedNotTerminal)
        self.resultCacheHits = resultCacheHits
        self.resultCacheMisses = resultCacheMisses
        self.volatileTokenWarnings = volatileTokenWarnings
        self.systemPromptHash = systemPromptHash
        self.cacheDriftWarnings = max(0, cacheDriftWarnings)
        self.encoderLaneInvocations = max(0, encoderLaneInvocations)
        self.encoderLaneAccepts = max(0, encoderLaneAccepts)
        self.encoderLaneFallbacks = max(0, encoderLaneFallbacks)
        self.encoderLaneFailures = max(0, encoderLaneFailures)
        self.encoderLaneDeadlineTimeouts = max(0, encoderLaneDeadlineTimeouts)
        self.pipeHitRate = min(1, max(0, pipeHitRate.isFinite ? pipeHitRate : 0))
        self.resolvedWithoutLLMRate = min(1, max(0, resolvedWithoutLLMRate.isFinite ? resolvedWithoutLLMRate : 0))
        self.encoderAvgMillis = max(0, encoderAvgMillis.isFinite ? encoderAvgMillis : 0)
        self.llmAvgMillis = max(0, llmAvgMillis.isFinite ? llmAvgMillis : 0)
        self.gateP50Millis = max(0, gateP50Millis)
        self.gateP95Millis = max(0, gateP95Millis)
        self.maxConcurrentRequests = maxConcurrentRequests
    }
}

public actor DistillServiceMetricsRecorder {
    private var totalRequests = 0
    private var successfulRequests = 0
    private var failedRequests = 0
    private var fallbackRequests = 0
    private var toolOutputEligible = 0
    private var toolOutputCompressed = 0
    private var toolOutputSkippedOverCap = 0
    private var toolOutputSkippedNoService = 0
    private var toolOutputSkippedNotTerminal = 0
    private var volatileTokenWarnings = 0
    private var systemPromptHash: String?
    private var cacheDriftWarnings = 0
    private var routeLedger = TokenSaverRouteLedger()
    private var encoderMetrics = EncoderLaneMetricsSnapshot(invocations: 0, accepts: 0, fallbacks: 0, failures: 0)
    private var gateLatency = LatencyPercentileTracker()

    public init() {}

    /// M6: record end-to-end gate/hook latency for the p50/p95 percentiles.
    public func recordLatency(milliseconds: Int) {
        gateLatency.record(milliseconds: milliseconds)
    }

    /// C5: record a per-lane routing outcome (stage + wall-clock) for the BERT-first ledger.
    public func recordRoute(_ event: TokenSaverRouteTelemetryEvent) {
        routeLedger.record(event)
    }

    /// M5: capture the encoder lane's cumulative counters for /metrics.
    public func recordEncoderMetrics(_ snapshot: EncoderLaneMetricsSnapshot) {
        encoderMetrics = snapshot
    }

    public func recordRequest() {
        totalRequests += 1
    }

    public func recordSuccess() {
        successfulRequests += 1
    }

    public func recordFailure() {
        failedRequests += 1
    }

    public func recordFallback() {
        fallbackRequests += 1
    }

    public func recordToolOutputEligible() {
        toolOutputEligible += 1
    }

    public func recordToolOutputCompressed() {
        toolOutputCompressed += 1
    }

    public func recordToolOutputSkipped(_ reason: ToolOutputTelemetrySkipReason) {
        switch reason {
        case .overCap:
            toolOutputSkippedOverCap += 1
        case .noService:
            toolOutputSkippedNoService += 1
        case .notTerminal:
            toolOutputSkippedNotTerminal += 1
        }
    }

    public func recordVolatileTokenWarnings(_ count: Int) {
        volatileTokenWarnings += max(0, count)
    }

    public func recordSystemPromptHash(_ hash: String) {
        let trimmed = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let previous = systemPromptHash, previous != trimmed {
            cacheDriftWarnings += 1
        }
        systemPromptHash = trimmed
    }

    public func snapshot(
        activeRequests: Int,
        maxConcurrentRequests: Int,
        resultCacheHits: Int = 0,
        resultCacheMisses: Int = 0
    ) -> DistillServiceMetrics {
        DistillServiceMetrics(
            activeRequests: activeRequests,
            totalRequests: totalRequests,
            successfulRequests: successfulRequests,
            failedRequests: failedRequests,
            fallbackRequests: fallbackRequests,
            toolOutputEligible: toolOutputEligible,
            toolOutputCompressed: toolOutputCompressed,
            toolOutputSkippedOverCap: toolOutputSkippedOverCap,
            toolOutputSkippedNoService: toolOutputSkippedNoService,
            toolOutputSkippedNotTerminal: toolOutputSkippedNotTerminal,
            resultCacheHits: resultCacheHits,
            resultCacheMisses: resultCacheMisses,
            volatileTokenWarnings: volatileTokenWarnings,
            systemPromptHash: systemPromptHash,
            cacheDriftWarnings: cacheDriftWarnings,
            encoderLaneInvocations: encoderMetrics.invocations,
            encoderLaneAccepts: encoderMetrics.accepts,
            encoderLaneFallbacks: encoderMetrics.fallbacks,
            encoderLaneFailures: encoderMetrics.failures,
            encoderLaneDeadlineTimeouts: encoderMetrics.deadlineTimeouts,
            pipeHitRate: toolOutputEligible == 0 ? 0 : Double(toolOutputCompressed) / Double(toolOutputEligible),
            resolvedWithoutLLMRate: routeLedger.resolvedWithoutLLMRate,
            encoderAvgMillis: routeLedger.averageLatencyMillis(stage: .encoderBERT),
            llmAvgMillis: routeLedger.averageLatencyMillis(stage: .llmMLX),
            gateP50Millis: gateLatency.p50,
            gateP95Millis: gateLatency.p95,
            maxConcurrentRequests: maxConcurrentRequests
        )
    }
}

public final class DistillHTTPServer: @unchecked Sendable {
    /// `(request, response, threadID)` — `threadID` comes from recovery headers
    /// (`X-RemoteCode-Thread-ID`) so the savings ledger can attribute the row.
    public typealias SuccessHandler = @Sendable (DistillRequest, DistillResponse, String) async -> Void
    /// Live paid-feature admission, re-evaluated by the HTTP boundary for every
    /// compression request. The sidecar executable wires this to authoritative
    /// settings; the default preserves standalone/test server compatibility.
    public typealias DistillAdmission = @Sendable () -> Bool
    /// Optional ledger seam for forfeited (not-delivered) savings. DistillCore stays
    /// Persistence-free; the sidecar wires this to `TokenSaverSavingsRepository`.
    public typealias SavingsRecordHandler = @Sendable (DistillSavingsRecord) async -> Void
    /// Optional audit seam for coverage/denial rows (`token_saver_audit_events`).
    public typealias AuditEventHandler = @Sendable (
        _ eventKind: String,
        _ reason: String?,
        _ countValue: Int64?
    ) async -> Void

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct ErrorBody: Codable {
        let error: String
        let message: String
    }

    private struct RetrieveResponse: Codable {
        let handle: String
        let found: Bool
        let original: String?
    }

    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return false }
            didResume = true
            return true
        }
    }

    private let configuration: DistillServiceConfiguration
    private let scheduler: DistillScheduler
    /// Exposed so callers can wire `DeadlineDistillRuntime.onFallback` to
    /// `metrics.recordFallback()` without coupling the scheduler layer to the
    /// HTTP layer.  Read-only; the recorder itself is the mutation surface.
    public let metrics: DistillServiceMetricsRecorder
    private let queue = DispatchQueue(label: "io.remotecode.distill.http", qos: .userInitiated)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let onSuccess: SuccessHandler?
    private let distillAdmission: DistillAdmission
    private let onSavingsRecord: SavingsRecordHandler?
    private let onAuditEvent: AuditEventHandler?
    private let reversibleStore: ReversibleStoring?
    private let scopedRecoveryStore: TokenSaverScopedRecoveryStoring?
    private let statsProvider: DistillStatsProviding?
    private let reversibleStoreMinBytes: Int
    private let requestBodyLimitBytes: Int
    private var listener: NWListener?
    private var actualPort: UInt16 = 0
    private let readyLock = NSLock()
    private var _ready: Bool

    public init(
        configuration: DistillServiceConfiguration,
        scheduler: DistillScheduler,
        reversibleStore: ReversibleStoring? = nil,
        scopedRecoveryStore: TokenSaverScopedRecoveryStoring? = nil,
        statsProvider: DistillStatsProviding? = nil,
        reversibleStoreMinBytes: Int = 8_192,
        requestBodyLimitBytes: Int = DistillHTTPServer.maxRequestBodyBytes,
        startsReady: Bool = true,
        metricsRecorder: DistillServiceMetricsRecorder? = nil,
        onSuccess: SuccessHandler? = nil,
        onSavingsRecord: SavingsRecordHandler? = nil,
        onAuditEvent: AuditEventHandler? = nil,
        distillAdmission: @escaping DistillAdmission = { true }
    ) {
        self.configuration = configuration
        self.scheduler = scheduler
        self.reversibleStore = reversibleStore
        self.scopedRecoveryStore = scopedRecoveryStore
        self.statsProvider = statsProvider
        self.reversibleStoreMinBytes = max(1, reversibleStoreMinBytes)
        self.requestBodyLimitBytes = max(1, requestBodyLimitBytes)
        self._ready = startsReady
        self.metrics = metricsRecorder ?? DistillServiceMetricsRecorder()
        self.distillAdmission = distillAdmission
        self.onSuccess = onSuccess
        self.onSavingsRecord = onSavingsRecord
        self.onAuditEvent = onAuditEvent
    }

    /// Flip readiness on once the runtime is warm. Until then /readyz returns 503
    /// so callers never route a request to a cold model (P1-T1).
    public func markReady() {
        readyLock.lock(); _ready = true; readyLock.unlock()
    }

    private var isReady: Bool {
        readyLock.lock(); defer { readyLock.unlock() }; return _ready
    }

    public func start() async throws -> DistillServiceReadyEvent {
        let requestedPort = NWEndpoint.Port(rawValue: configuration.port) ?? .any
        let listener = try NWListener(using: .tcp, on: requestedPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection: connection, buffer: Data())
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    self.actualPort = listener.port?.rawValue ?? self.configuration.port
                    continuation.resume(returning: self.readyEvent())
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    public func readyEvent() -> DistillServiceReadyEvent {
        let port = actualPort == 0 ? configuration.port : actualPort
        return DistillServiceReadyEvent(
            event: "ready",
            baseURL: "http://\(configuration.host):\(port)",
            host: configuration.host,
            port: port,
            pid: ProcessInfo.processInfo.processIdentifier,
            protocolVersion: 1,
            runtime: configuration.runtime,
            modelID: configuration.modelID,
            maxConcurrentRequests: configuration.maxConcurrentRequests,
            maxQueueDepth: configuration.maxQueueDepth
        )
    }

    /// Maximum bytes buffered for a connection whose HTTP header has not yet been
    /// parsed and the bearer token verified. 65536 bytes is far above any realistic
    /// HTTP request-line + headers (typical auth request is < 2 KB), and far below
    /// the input sizes a legitimate authed POST /v1/distill may carry (uncapped once
    /// auth is confirmed via the Authorization header in the buffer).
    static let preAuthBufferCap = 65_536
    /// Maximum accepted HTTP body size for POST /v1/distill. The client caps the
    /// raw input at 32 MiB; this body cap leaves JSON overhead room while rejecting
    /// malicious or stale clients before the service buffers unbounded data.
    public static let maxRequestBodyBytes = 36 * 1024 * 1024

    /// Pure seam: returns true when a connection has not yet been header-authed and
    /// its accumulated buffer exceeds the pre-auth cap. Extracted for testability.
    /// WHY: an unauthenticated client must not be able to OOM the distill service by
    /// streaming arbitrary bytes before completing an HTTP request.
    static func exceedsPreAuthCap(bufferCount: Int, headerAuthed: Bool, cap: Int = preAuthBufferCap) -> Bool {
        !headerAuthed && bufferCount > cap
    }

    static func declaredContentLength(headerText: String) -> Int? {
        headerText
            .split(separator: "\r\n")
            .dropFirst()
            .compactMap { line -> Int? in
                let pieces = line.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2,
                      pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" else {
                    return nil
                }
                return Int(pieces[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .first
    }

    // PERF: header scans run on every receive/auth/body-limit check; share one
    // 4-byte CRLFCRLF terminator instead of allocating Data("\r\n\r\n".utf8)
    // on each call (same pattern as SocketServer HTTPServer).
    private static let httpHeaderTerminator = Data([0x0d, 0x0a, 0x0d, 0x0a])

    static func declaredBodyExceedsLimit(buffer: Data, cap: Int = maxRequestBodyBytes) -> Bool {
        guard let headerRange = buffer.range(of: httpHeaderTerminator),
              let headerText = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8),
              let declaredLength = declaredContentLength(headerText: headerText) else {
            return false
        }
        return declaredLength > cap
    }

    /// Returns true if the Authorization header in the (possibly partial) buffer
    /// matches the expected bearer token. Requires the header section to be complete
    /// (i.e. `\r\n\r\n` present). Used to lift the pre-auth cap once auth is seen.
    private func bufferIsHeaderAuthed(_ data: Data) -> Bool {
        guard let headerRange = data.range(of: Self.httpHeaderTerminator),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return false
        }
        let expected = "Bearer \(configuration.authToken)"
        return headerText
            .split(separator: "\r\n")
            .dropFirst()
            .contains { line in
                let pieces = line.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2,
                      pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "authorization" else {
                    return false
                }
                return pieces[1].trimmingCharacters(in: .whitespacesAndNewlines) == expected
            }
    }

    // scanOffset tracks the last position searched for "\r\n\r\n" so each receive
    // cycle only scans new bytes rather than re-scanning the entire buffer.
    private func receive(connection: NWConnection, buffer: Data, scanOffset: Int = 0, headerAuthed: Bool = false) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete, data == nil {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            // Promote headerAuthed once the header section is fully buffered.
            let authed = headerAuthed || self.bufferIsHeaderAuthed(nextBuffer)

            // Reject pre-auth connections that exceed the buffer cap. An authed
            // connection (large distill body) is never capped here.
            if DistillHTTPServer.exceedsPreAuthCap(bufferCount: nextBuffer.count, headerAuthed: authed) {
                connection.cancel()
                return
            }
            if authed && DistillHTTPServer.declaredBodyExceedsLimit(buffer: nextBuffer, cap: self.requestBodyLimitBytes) {
                self.send(
                    status: 413,
                    body: ErrorBody(error: "payload_too_large", message: "distill request body exceeds limit"),
                    connection: connection
                )
                return
            }

            // Advance the scan offset to avoid re-scanning bytes already checked.
            // The separator is 4 bytes; we must not skip past a partial match at the
            // tail of the previously-scanned window, so retreat by 3.
            let nextScanOffset = max(0, nextBuffer.count - (data?.count ?? 0) - 3)

            if self.requestIsComplete(nextBuffer, from: nextScanOffset) {
                Task {
                    await self.handle(buffer: nextBuffer, connection: connection)
                }
            } else {
                self.receive(connection: connection, buffer: nextBuffer, scanOffset: nextScanOffset, headerAuthed: authed)
            }
        }
    }

    /// Returns true when `data` contains a complete HTTP request (headers + declared body).
    /// `from` is a hint: the search for `\r\n\r\n` starts at `max(0, from - 3)` to
    /// avoid re-scanning already-checked bytes while still catching a separator that
    /// straddles the previous read boundary.
    /// Internal (not private) so unit tests can exercise the scan-offset logic directly.
    func requestIsComplete(_ data: Data, from scanOffset: Int = 0) -> Bool {
        let separator = Self.httpHeaderTerminator
        let searchStart = max(0, scanOffset - 3)
        let headerRange = data.range(of: separator, in: searchStart..<data.count)
            ?? data.range(of: separator)
        guard let headerRange,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return false
        }
        let contentLength = Self.declaredContentLength(headerText: headerText) ?? 0
        return data.count >= headerRange.upperBound + contentLength
    }

    private func handle(buffer: Data, connection: NWConnection) async {
        guard let request = parse(buffer: buffer) else {
            send(status: 400, body: ErrorBody(error: "bad_request", message: "invalid http request"), connection: connection)
            return
        }

        if request.path == "/healthz" {
            send(status: 200, body: ["status": "ok"], connection: connection)
            return
        }

        guard request.headers["authorization"] == "Bearer \(configuration.authToken)" else {
            send(status: 401, body: ErrorBody(error: "unauthorized", message: "missing bearer token"), connection: connection)
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/readyz"):
            if isReady {
                send(status: 200, body: readyEvent(), connection: connection)
            } else {
                send(status: 503, body: ErrorBody(error: "not_ready", message: "model warming up"), connection: connection)
            }
        case ("GET", "/metrics"):
            let active = await scheduler.activeRequestCount
            let cacheHits = await scheduler.resultCacheHitCount
            let cacheMisses = await scheduler.resultCacheMissCount
            let snapshot = await metrics.snapshot(
                activeRequests: active,
                maxConcurrentRequests: configuration.maxConcurrentRequests,
                resultCacheHits: cacheHits,
                resultCacheMisses: cacheMisses
            )
            send(status: 200, body: snapshot, connection: connection)
        case ("GET", "/v1/stats"):
            handleStats(connection: connection)
        case ("POST", "/v1/distill"),
             ("POST", "/v1/compress"),
             ("POST", "/v1/rank"),
             ("POST", "/v1/embed"):
            guard distillAdmission() else {
                denyDistill(connection: connection)
                return
            }
            switch request.path {
            case "/v1/rank":
                handleRank(request: request, connection: connection)
            case "/v1/embed":
                handleEmbed(request: request, connection: connection)
            default:
                await handleDistill(request: request, connection: connection)
            }
        case (_, "/v1/distill"), (_, "/v1/compress"):
            send(status: 405, body: ErrorBody(error: "method_not_allowed", message: "use POST"), connection: connection)
        case (_, "/v1/rank"), (_, "/v1/embed"):
            send(status: 405, body: ErrorBody(error: "method_not_allowed", message: "use POST"), connection: connection)
        case ("GET", let path) where path.hasPrefix("/v1/retrieve/"):
            handleRetrieve(request: request, connection: connection)
        default:
            send(status: 404, body: ErrorBody(error: "not_found", message: request.path), connection: connection)
        }
    }

    private func handleStats(connection: NWConnection) {
        do {
            let snapshot = try statsProvider?.statsSnapshot() ?? DistillStatsSnapshot()
            send(status: 200, body: snapshot, connection: connection)
        } catch {
            send(status: 500, body: ErrorBody(error: "stats_unavailable", message: "\(error)"), connection: connection)
        }
    }

    /// Recover a byte-exact original previously stored via store-before-loss (N5).
    /// Returns 200 {found:true, original} when present, 404 {found:false} otherwise
    /// — never empty/hang (a typed "original unavailable").
    ///
    /// Authorization: recovery **scope headers** are required to look up either
    /// store. Bearer alone never authorizes raw-SHA retrieve (wave -1): when the
    /// unscoped reversible store is configured, missing scope is 403
    /// `recovery_scope_required`. Scoped-only deployments keep the historical
    /// 404 miss when scope headers are absent.
    private func handleRetrieve(request: HTTPRequest, connection: NWConnection) {
        let handle = String(request.path.dropFirst("/v1/retrieve/".count))
        guard !handle.isEmpty else {
            send(status: 404, body: RetrieveResponse(handle: handle, found: false, original: nil), connection: connection)
            return
        }
        guard let context = recoveryContext(headers: request.headers, requiresOperationID: false) else {
            // Wave -1: bearer alone must not authorize raw-SHA content lookup.
            if reversibleStore != nil {
                send(
                    status: 403,
                    body: ErrorBody(
                        error: "recovery_scope_required",
                        message: "scoped recovery capability required"
                    ),
                    connection: connection
                )
                return
            }
            send(status: 404, body: RetrieveResponse(handle: handle, found: false, original: nil), connection: connection)
            return
        }
        // Scoped capabilities only. Do not serve residual content-addressed SHA
        // rows from reversibleStore: headers are not bound to those blobs, so any
        // process with the local bearer + a predicted hash could cross-read.
        if let scopedRecoveryStore {
            do {
                if let data = try scopedRecoveryStore.retrieveOriginal(capability: handle, context: context),
                   let original = String(data: data, encoding: .utf8) {
                    send(status: 200, body: RetrieveResponse(handle: handle, found: true, original: original), connection: connection)
                    return
                }
            } catch {
                // typed miss below
            }
        }
        send(status: 404, body: RetrieveResponse(handle: handle, found: false, original: nil), connection: connection)
    }

    private func recoveryContext(headers: [String: String], requiresOperationID: Bool) -> TokenSaverRecoveryRequestContext? {
        let context = TokenSaverRecoveryRequestContext(
            workspaceID: headers["x-remotecode-workspace-id"] ?? "",
            projectID: headers["x-remotecode-project-id"] ?? "",
            threadID: headers["x-remotecode-thread-id"] ?? "",
            provider: headers["x-remotecode-provider"] ?? "",
            attemptID: headers["x-remotecode-attempt-id"] ?? "",
            operationID: headers["x-remotecode-operation-id"] ?? "",
            invocationID: headers["x-remotecode-invocation-id"] ?? ""
        )
        return (requiresOperationID ? context.hasCompleteMutationContext : context.hasCompleteScope) ? context : nil
    }

    /// True when `split(separator: "\n", omittingEmptySubsequences: false).count >= threshold`.
    ///
    /// PERF: UTF-8 LF scan with early exit — no `Array` of `Substring` for multi-line
    /// tool dumps. Component count is `newlineCount + 1` for this split form.
    private static func newlineSeparatedComponentCount(_ text: String, atLeast threshold: Int) -> Bool {
        if threshold <= 1 { return true }
        let neededNewlines = threshold - 1
        var newlines = 0
        for byte in text.utf8 where byte == 0x0A {
            newlines += 1
            if newlines >= neededNewlines { return true }
        }
        return false
    }

    /// Lossy deterministic crushers with store-before-loss (command-output only).
    /// Returns a ready response when stack/test/source/diff/HTML crushers win; nil to
    /// fall through to EncoderFirst (lossless → BERT → E4B).
    private func tryScopedLossyCommandOutput(
        request: DistillRequest,
        scopedContext: TokenSaverRecoveryRequestContext?,
        scopedRecoveryStore: TokenSaverScopedRecoveryStoring?
    ) async -> DistillResponse? {
        guard request.mode == .commandOutput,
              request.effectiveRunMode == .optimize,
              let scopedContext,
              let scopedRecoveryStore else {
            return nil
        }
        // Cheap size + shape gate: avoid prepareOriginal on tiny / non-lossy payloads.
        // PERF: multi-MB tool outputs already pass the byte gate — do not allocate a
        // full `split` Array just to count lines. When the byte gate fails, scan LF
        // with early exit at 30 components (same as
        // `split(separator: "\n", omittingEmptySubsequences: false).count`).
        let input = request.input
        guard input.utf8.count >= 2_048
                || Self.newlineSeparatedComponentCount(input, atLeast: 30) else {
            return nil
        }
        guard CommandOutputLossyRouter.isLossyCandidate(input) else { return nil }
        guard distillAdmission() else { return nil }

        do {
            // PERF: one UTF-8 materialization for prepare + readback equality
            // (store-before-loss path on multi-KB/MB command output).
            let originalBytes = Data(input.utf8)
            let preparation = try scopedRecoveryStore.prepareOriginal(
                originalBytes,
                context: scopedContext,
                lane: "deterministic_lossy"
            )
            guard preparation.readBackVerified,
                  try scopedRecoveryStore.retrieveOriginal(
                    capability: preparation.capability,
                    context: scopedContext
                  ) == originalBytes else {
                return nil
            }
            guard let routed = CommandOutputLossyRouter.routeIfBeneficial(
                input: input,
                handle: preparation.capability,
                query: request.question
            ), routed.output != input else {
                return nil
            }
            guard try scopedRecoveryStore.markDelivered(
                capability: preparation.capability,
                idempotencyKey: preparation.idempotencyKey,
                context: scopedContext,
                outcome: .sentUnknown
            ) else {
                return nil
            }
            let inputTokens = TokenEstimator.estimate(input)
            let outputTokens = TokenEstimator.estimate(routed.output)
            return DistillResponse(
                requestID: request.id,
                output: routed.output,
                inputCharacters: input.count,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                originalHandle: preparation.capability,
                recoveryIdempotencyKey: preparation.idempotencyKey,
                runMode: .optimize,
                routeStage: .deterministic
            )
        } catch {
            // Fail open to EncoderFirst / model path.
            return nil
        }
    }

    /// LOSSLESS-ONLY UNSCOPED TIER.
    /// Prefer the scheduler candidate when it is already a byte-exact expandable
    /// reduction; otherwise (command-output only) attempt a fresh LogCollapser RLE.
    /// WHY command-output-only for the fresh pass: long-text containment tests use
    /// collapsible repeated lines with a lossy runtime and require byte-exact
    /// fail-open; re-running RLE on those would change their security probes.
    /// JSON minify is semantic-only (not byte-exact) and must not skip store-before-loss.
    /// Returns nil when no proven-lossless gain exists — caller fails open.
    private static func losslessUnscopedDelivery(
        original: String,
        compressed: DistillResponse,
        mode: DistillMode
    ) -> DistillResponse? {
        if isByteExactLosslessReduction(original: original, reduced: compressed.output) {
            // Serve the already-computed lossless bytes; never attach a handle.
            return DistillResponse(
                requestID: compressed.requestID,
                output: compressed.output,
                inputCharacters: compressed.inputCharacters,
                inputTokens: compressed.inputTokens,
                outputTokens: compressed.outputTokens,
                originalHandle: nil,
                recoveryIdempotencyKey: nil,
                runMode: compressed.runMode ?? .optimize,
                auditReport: compressed.auditReport,
                routeStage: compressed.routeStage ?? .deterministic
            )
        }
        // Fresh lossless pass: only for command-output (bare `cmd | distill` path),
        // where EncoderFirst may not be in the test runtime and LocalDistillRuntime
        // skips the content router for this mode.
        guard mode == .commandOutput,
              let reduced = attemptLosslessOnlyReduction(input: original) else {
            return nil
        }
        return DistillResponse(
            requestID: compressed.requestID,
            output: reduced,
            inputCharacters: original.count,
            inputTokens: compressed.inputTokens > 0
                ? compressed.inputTokens
                : TokenEstimator.estimate(original),
            outputTokens: TokenEstimator.estimate(reduced),
            originalHandle: nil,
            recoveryIdempotencyKey: nil,
            runMode: compressed.runMode ?? .optimize,
            auditReport: compressed.auditReport,
            // Distinct stage so the ledger can attribute lossless-unscoped savings.
            routeStage: .deterministic
        )
    }

    /// True when `reduced` expands byte-exactly to `original` (LogCollapser RLE).
    private static func isByteExactLosslessReduction(original: String, reduced: String) -> Bool {
        guard reduced != original, reduced.utf8.count < original.utf8.count else {
            return false
        }
        // expand(collapse(x)) == x is the store-before-loss-trivial proof.
        return LogCollapser.expand(reduced) == original
    }

    /// Fresh lossless-only attempt with the same invertibility proof.
    private static func attemptLosslessOnlyReduction(input: String) -> String? {
        guard let collapsed = LogCollapser.collapse(input),
              collapsed.utf8.count < input.utf8.count,
              LogCollapser.expand(collapsed) == input else {
            return nil
        }
        return collapsed
    }

    /// Mode base matching DistillSavingsCalculator display labels.
    private static func savingsModeBase(for mode: DistillMode) -> String {
        switch mode {
        case .commandOutput: return "command-output"
        case .longText: return "longText"
        case .watchSummary: return "watchSummary"
        case .sr1Humanize: return "sr1-humanize"
        }
    }

    private static func savingsAttributability(for mode: DistillMode) -> String {
        switch mode {
        case .longText: return "prompt_bound"
        case .commandOutput, .watchSummary, .sr1Humanize: return "not_prompt_bound"
        }
    }

    private static func savingsCacheState(for request: DistillRequest) -> String {
        if let explicit = request.cacheState { return explicit }
        switch request.mode {
        case .commandOutput: return "tool_output_oneshot"
        case .longText: return "prompt"
        case .watchSummary: return "watch"
        case .sr1Humanize: return "sr1_humanize"
        }
    }

    /// Emit delivered=0 forfeit row + denial audit when lossy compression is discarded.
    private func emitForfeitedCompression(
        request: DistillRequest,
        compressed: DistillResponse,
        threadID: String = ""
    ) async {
        let base = Self.savingsModeBase(for: request.mode)
        let trimmedProvider = request.provider?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let provider = trimmedProvider.isEmpty ? "unknown" : trimmedProvider
        // Keep the scheduler's compressed token counts so the forfeit is visible
        // as would-have-saved rather than a silent zero.
        let record = DistillSavingsRecord(
            provider: provider,
            mode: "\(base) (discarded-no-handle)",
            inputTokens: compressed.inputTokens,
            outputTokens: compressed.outputTokens,
            savedTokens: compressed.savedTokens,
            cacheState: Self.savingsCacheState(for: request),
            routeStage: compressed.routeStage,
            attributability: Self.savingsAttributability(for: request.mode),
            delivered: false,
            threadID: threadID
        )
        if let onSavingsRecord {
            await onSavingsRecord(record)
        }
        if let onAuditEvent {
            // Coverage/denial audit: operators query token_saver_audit_events for
            // how much compression was forfeited for lack of a recovery handle.
            await onAuditEvent(
                "token_saver_denial",
                "discarded_no_handle",
                Int64(max(0, compressed.savedTokens))
            )
        }
    }

    private func handleDistill(request: HTTPRequest, connection: NWConnection) async {
        guard distillAdmission() else {
            denyDistill(connection: connection)
            return
        }
        await metrics.recordRequest()
        guard request.body.count <= requestBodyLimitBytes else {
            await metrics.recordFailure()
            send(status: 413, body: ErrorBody(error: "payload_too_large", message: "distill request body exceeds limit"), connection: connection)
            return
        }
        do {
            let distillRequest = try decoder.decode(DistillRequest.self, from: request.body)
            // Prefer scoped recovery header; empty for bare CLI pipes.
            let savingsThreadID = (request.headers["x-remotecode-thread-id"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if distillRequest.mode == .commandOutput {
                await metrics.recordToolOutputEligible()
            }
            let volatileScan = CacheAlignerVolatileTokenDetector.scan(
                [distillRequest.input, distillRequest.question ?? ""].joined(separator: "\n")
            )
            if volatileScan.warningCount > 0 {
                await metrics.recordVolatileTokenWarnings(volatileScan.warningCount)
            }
            await metrics.recordSystemPromptHash(CacheAlignerPromptContract.systemPromptHash(for: distillRequest))
            // Precomputed-output mode (Wave A/B ledger): the client already delivered
            // `precomputedOutput` to the caller. Record the honest original→precomputed
            // delta via onSuccess and skip the model/scheduler entirely — mirror the
            // terminal-recovery early-return below (build response, onSuccess, 200).
            if let response = distillRequest.responseUsingPrecomputedOutput() {
                if distillRequest.mode == .commandOutput, response.output != distillRequest.input {
                    await metrics.recordToolOutputCompressed()
                }
                if let onSuccess { await onSuccess(distillRequest, response, savingsThreadID) }
                await metrics.recordSuccess()
                send(status: 200, body: response, connection: connection)
                return
            }
            // Recovery scope is optional for compression. Without complete scope we still
            // run the scheduler so `cmd | distill` saves tokens; we only attach a
            // reversible handle when store+scope prepare succeeds (store-before-loss).
            // Prior behavior returned input verbatim whenever scope was missing, which
            // made bare CLI pipes and partial agent env always fail-open with zero savings.
            var scopedContext: TokenSaverRecoveryRequestContext?
            if distillRequest.effectiveRunMode == .optimize {
                scopedContext = recoveryContext(headers: request.headers, requiresOperationID: true)
                if let scopedRecoveryStore, let context = scopedContext {
                    do {
                        if let existing = try scopedRecoveryStore.lookupInvocation(context: context) {
                            let terminal = existing.state != .prepared
                                || existing.transportOutcome == .sentUnknown
                                || existing.transportOutcome == .acked
                            if terminal {
                                let tokens = TokenEstimator.estimate(distillRequest.input)
                                let response = DistillResponse(
                                    requestID: distillRequest.id,
                                    output: distillRequest.input,
                                    inputCharacters: distillRequest.input.count,
                                    inputTokens: tokens,
                                    outputTokens: tokens,
                                    originalHandle: nil,
                                    runMode: .optimize,
                                    routeStage: .verbatim
                                )
                                if let onSuccess { await onSuccess(distillRequest, response, savingsThreadID) }
                                await metrics.recordSuccess()
                                send(status: 200, body: response, connection: connection)
                                return
                            }
                        }
                    } catch {
                        // Fall through to compress without handle.
                        scopedContext = nil
                    }
                }
            }
            guard distillAdmission() else {
                denyDistill(connection: connection)
                return
            }

            // Store-before-loss + lossy deterministic crushers (stack/test/source/diff/HTML)
            // before BERT/LLM. Only when scoped recovery can mint a handle — never serve
            // unrecoverable element-dropping reductions.
            if let early = await tryScopedLossyCommandOutput(
                request: distillRequest,
                scopedContext: scopedContext,
                scopedRecoveryStore: scopedRecoveryStore
            ) {
                if distillRequest.mode == .commandOutput {
                    await metrics.recordToolOutputCompressed()
                }
                if let onSuccess {
                    await onSuccess(distillRequest, early, savingsThreadID)
                }
                await metrics.recordSuccess()
                send(status: 200, body: early, connection: connection)
                return
            }

            let compressed = try await scheduler.submit(distillRequest)
            // A toggle can change while an in-flight model call finishes. Do not
            // store originals, publish reduced output, or record savings after
            // authority is revoked.
            guard distillAdmission() else {
                denyDistill(connection: connection)
                return
            }
            var response = compressed
            if distillRequest.effectiveRunMode == .optimize,
               compressed.output != distillRequest.input {
                // Store-before-loss (T-003): a lossy optimize output may only be
                // served when backed by a scope-bound recovery handle. Do NOT fall
                // back to unscoped SHA storage after a scoped prepare failure —
                // that would bypass opt-out / kill / retention=0 governance and
                // emit handles that bearer-only retrieve must default-deny.
                // Missing/incomplete scope, prepare failure, or readback failure
                // all fail open to the byte-exact original — except for a
                // lossless-only unscoped tier (byte-exact round-trip proof),
                // which needs no handle because nothing becomes unrecoverable.
                var deliveredWithHandle = false
                if let scopedContext, let scopedRecoveryStore {
                    do {
                        // PERF: one UTF-8 materialization for prepare + readback equality
                        // on lossy optimize outputs (can be multi-KB/MB).
                        let originalBytes = Data(distillRequest.input.utf8)
                        let preparation = try scopedRecoveryStore.prepareOriginal(
                            originalBytes,
                            context: scopedContext,
                            lane: distillRequest.mode == .commandOutput ? "deterministic_wrapper" : "semantic_prose"
                        )
                        guard preparation.readBackVerified,
                              try scopedRecoveryStore.retrieveOriginal(
                                capability: preparation.capability,
                                context: scopedContext
                              ) == originalBytes,
                              try scopedRecoveryStore.markDelivered(
                                capability: preparation.capability,
                                idempotencyKey: preparation.idempotencyKey,
                                context: scopedContext,
                                outcome: .sentUnknown
                              ) else {
                            throw DistillError.invalidOutput
                        }
                        response = compressed.withOriginalHandle(
                            preparation.capability,
                            idempotencyKey: preparation.idempotencyKey
                        )
                        deliveredWithHandle = true
                    } catch {
                        deliveredWithHandle = false
                    }
                }
                if !deliveredWithHandle {
                    if let lossless = Self.losslessUnscopedDelivery(
                        original: distillRequest.input,
                        compressed: compressed,
                        mode: distillRequest.mode
                    ) {
                        // WHY: byte-exact expandable reduction satisfies store-before-loss
                        // trivially — expand recovers the original, so no handle/grant.
                        response = lossless
                    } else {
                        // Existing fail-open: never serve unrecoverable lossy bytes.
                        response = compressed.verbatimFallback(input: distillRequest.input)
                        // WHY: previously this path looked like saved_tokens=0 with no
                        // signal that the scheduler had already found a reduction. Emit
                        // a delivered=0 forfeit row + denial audit so operators see it.
                        await emitForfeitedCompression(
                            request: distillRequest,
                            compressed: compressed,
                            threadID: savingsThreadID
                        )
                    }
                }
            }
            if distillRequest.mode == .commandOutput, response.output != distillRequest.input {
                await metrics.recordToolOutputCompressed()
            }
            if let onSuccess {
                await onSuccess(distillRequest, response, savingsThreadID)
            }
            await metrics.recordSuccess()
            send(status: 200, body: response, connection: connection)
        } catch let error as DistillError {
            await metrics.recordFailure()
            // Status + code come from the pure DistillError.httpMapping seam (tested);
            // the human messages stay here.
            let message: String
            switch error {
            case .emptyInput:    message = "input is empty"
            case .queueFull:     message = "bounded distill worker is full"
            case .invalidOutput: message = "runtime returned empty output"
            }
            let mapping = error.httpMapping
            send(status: mapping.status, body: ErrorBody(error: mapping.code, message: message), connection: connection)
        } catch {
            await metrics.recordFailure()
            send(status: 400, body: ErrorBody(error: "bad_request", message: "invalid distill request"), connection: connection)
        }
    }

    private func denyDistill(connection: NWConnection) {
        send(
            status: 409,
            body: ErrorBody(
                error: "token_saver_disabled",
                message: "Token Saver is disabled; preserve the original input"
            ),
            connection: connection
        )
    }

    private func handleRank(request: HTTPRequest, connection: NWConnection) {
        guard request.body.count <= requestBodyLimitBytes else {
            send(status: 413, body: ErrorBody(error: "payload_too_large", message: "rank request body exceeds limit"), connection: connection)
            return
        }
        do {
            let rankRequest = try decoder.decode(DistillRankRequest.self, from: request.body)
            let chunks = rankRequest.chunks.enumerated().map { offset, chunk in
                QueryAwareChunk(
                    id: chunk.id,
                    text: chunk.text,
                    contentType: chunk.contentType,
                    position: chunk.position == 0 ? offset : chunk.position
                )
            }
            let ranked = QueryAwareChunkRanker()
                .rank(chunks: chunks, query: rankRequest.query, toolArguments: rankRequest.toolArguments)
                .prefix(max(1, rankRequest.topK ?? chunks.count))
                .map { ranked in
                    DistillRankedChunk(
                        id: ranked.chunk.id,
                        text: ranked.chunk.text,
                        contentType: ranked.chunk.contentType,
                        position: ranked.chunk.position,
                        bm25Score: ranked.bm25Score,
                        embeddingScore: ranked.embeddingScore,
                        finalScore: ranked.finalScore
                    )
                }
            send(status: 200, body: DistillRankResponse(query: rankRequest.query, encoderLane: rankRequest.encoderLane, results: Array(ranked)), connection: connection)
        } catch {
            send(status: 400, body: ErrorBody(error: "bad_request", message: "invalid rank request"), connection: connection)
        }
    }

    private func handleEmbed(request: HTTPRequest, connection: NWConnection) {
        guard request.body.count <= requestBodyLimitBytes else {
            send(status: 413, body: ErrorBody(error: "payload_too_large", message: "embed request body exceeds limit"), connection: connection)
            return
        }
        do {
            let embedRequest = try decoder.decode(DistillEmbedRequest.self, from: request.body)
            send(
                status: 200,
                body: DistillEmbedResponse(
                    available: false,
                    encoderLane: embedRequest.encoderLane,
                    message: "encoder lane unavailable; no synthetic embeddings returned"
                ),
                connection: connection
            )
        } catch {
            send(status: 400, body: ErrorBody(error: "bad_request", message: "invalid embed request"), connection: connection)
        }
    }

    private func parse(buffer: Data) -> HTTPRequest? {
        guard let headerRange = buffer.range(of: Self.httpHeaderTerminator),
              let headerText = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            headers[pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bodyStart = headerRange.upperBound
        let body = buffer.count > bodyStart ? buffer[bodyStart...] : Data()
        return HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: String(requestLine[1]).split(separator: "?").first.map(String.init) ?? "/",
            headers: headers,
            body: Data(body)
        )
    }

    // PERF: every distill HTTP response used to allocate Content-Type /
    // Connection header Data (and the encode-failure body). Reuse static
    // bytes; status line and Content-Length stay dynamic per response.
    private static let contentTypeJSONHeader = Data("Content-Type: application/json\r\n".utf8)
    private static let connectionCloseHeader = Data("Connection: close\r\n\r\n".utf8)
    private static let encodingFailedBody = Data(#"{"error":"encoding_failed"}"#.utf8)

    private func send<T: Encodable>(status: Int, body: T, connection: NWConnection) {
        let payload: Data
        do {
            payload = try encoder.encode(body)
        } catch {
            payload = Self.encodingFailedBody
        }
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 400: phrase = "Bad Request"
        case 401: phrase = "Unauthorized"
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        case 413: phrase = "Payload Too Large"
        case 429: phrase = "Too Many Requests"
        case 502: phrase = "Bad Gateway"
        case 503: phrase = "Service Unavailable"
        default: phrase = "Error"
        }
        var data = Data("HTTP/1.1 \(status) \(phrase)\r\n".utf8)
        data.append(Self.contentTypeJSONHeader)
        data.append(Data("Content-Length: \(payload.count)\r\n".utf8))
        data.append(Self.connectionCloseHeader)
        data.append(payload)

        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
