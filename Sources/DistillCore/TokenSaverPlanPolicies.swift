import Foundation

public struct TokenSaverMemoryScope: Sendable, Hashable, Equatable {
    public let projectPath: String
    public let provider: String
    public let threadID: String

    public init(projectPath: String, provider: String, threadID: String) {
        self.projectPath = Self.normalizeProjectPath(projectPath)
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.threadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeProjectPath(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

public struct TokenSaverMemoryRecord: Sendable, Equatable {
    public let handle: String
    public let text: String
    public let scope: TokenSaverMemoryScope
    public let provenance: String

    public init(handle: String, text: String, scope: TokenSaverMemoryScope, provenance: String) {
        self.handle = handle
        self.text = text
        self.scope = scope
        self.provenance = provenance
    }
}

public struct TokenSaverMemoryStore: Sendable, Equatable {
    private var records: [String: TokenSaverMemoryRecord] = [:]

    public init(records: [TokenSaverMemoryRecord] = []) {
        for record in records { self.records[record.handle] = record }
    }

    @discardableResult
    public mutating func save(text: String, scope: TokenSaverMemoryScope, provenance: String) -> TokenSaverMemoryRecord {
        let handle = CrossTurnDedupPolicy.rawByteHash([scope.projectPath, scope.provider, scope.threadID, text].joined(separator: "\u{1f}"))
        let record = TokenSaverMemoryRecord(handle: handle, text: text, scope: scope, provenance: provenance)
        records[handle] = record
        return record
    }

    public func retrieve(handle: String, scope: TokenSaverMemoryScope) -> String? {
        guard let record = records[handle], sameProject(record.scope, scope) else { return nil }
        return record.text
    }

    public mutating func update(handle: String, text: String, scope: TokenSaverMemoryScope) -> Bool {
        guard let record = records[handle], sameProject(record.scope, scope) else { return false }
        records[handle] = TokenSaverMemoryRecord(handle: handle, text: text, scope: record.scope, provenance: record.provenance)
        return true
    }

    public mutating func delete(handle: String, scope: TokenSaverMemoryScope) -> Bool {
        guard let record = records[handle], sameProject(record.scope, scope) else { return false }
        records.removeValue(forKey: handle)
        return true
    }

    public func search(_ query: String, scope: TokenSaverMemoryScope, topK: Int = 5) -> [CCRSearchResult] {
        let scoped = records.values
            .filter { sameProject($0.scope, scope) }
            .map { CCRSearchRecord(handle: $0.handle, text: $0.text) }
        return CCRSearchIndex(records: scoped).search(query, topK: topK)
    }

    private func sameProject(_ lhs: TokenSaverMemoryScope, _ rhs: TokenSaverMemoryScope) -> Bool {
        lhs == rhs
    }
}

public struct TokenSaverTranscriptSample: Sendable, Equatable {
    public let provider: String
    public let text: String

    public init(provider: String, text: String) {
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.text = text
    }
}

public struct TokenSaverLearnedVerbosityBudget: Sendable, Equatable {
    public let maxLines: Int
    public let preferredPrefixes: [String]
}

public struct TokenSaverTranscriptLearningReport: Sendable, Equatable {
    public let providers: [String]
    public let learnedVerbosityBudget: TokenSaverLearnedVerbosityBudget
    public let recommendedRules: [String]
}

public enum TokenSaverTranscriptLearner {
    public static func learn(from samples: [TokenSaverTranscriptSample]) -> TokenSaverTranscriptLearningReport {
        let providers = Array(Set(samples.map(\.provider).filter { !$0.isEmpty })).sorted()
        let lineCounts = samples.map { max(1, $0.text.split(whereSeparator: \.isNewline).count) }
        let averageLines = lineCounts.isEmpty ? 8 : lineCounts.reduce(0, +) / lineCounts.count
        let maxLines = max(4, min(40, averageLines))
        var rules: [String] = []
        let corpus = samples.map(\.text).joined(separator: "\n").lowercased()
        if corpus.contains("skipped distill") || corpus.contains("large grep") || corpus.contains("large output") {
            rules.append("pipe large read/search/build output through distill unless exact bytes are required")
        }
        if lineCounts.contains(where: { $0 > 40 }) {
            rules.append("prefer distill semantic prefixes and short proof lines for provider replies")
        }
        if rules.isEmpty {
            rules.append("keep Token Saver defaults unchanged until corrections provide stronger evidence")
        }
        return TokenSaverTranscriptLearningReport(
            providers: providers,
            learnedVerbosityBudget: TokenSaverLearnedVerbosityBudget(maxLines: maxLines, preferredPrefixes: ["S", "C", "D", "R", "O", "N", "P"]),
            recommendedRules: rules
        )
    }
}

public struct DistillSimulationReport: Sendable, Equatable {
    public let runMode: DistillRunMode
    public let mode: DistillMode
    public let output: String
    public let candidateOutput: String
    public let inputTokens: Int
    public let candidateOutputTokens: Int
    public let wouldSaveTokens: Int
    public let providerCallRequired: Bool
}

public enum DistillSimulation {
    public static func simulate(input: String, candidateOutput: String, mode: DistillMode) -> DistillSimulationReport {
        let inputTokens = TokenEstimator.estimate(input)
        let outputTokens = TokenEstimator.estimate(candidateOutput)
        return DistillSimulationReport(
            runMode: .simulate,
            mode: mode,
            output: input,
            candidateOutput: candidateOutput,
            inputTokens: inputTokens,
            candidateOutputTokens: outputTokens,
            wouldSaveTokens: max(inputTokens - outputTokens, 0),
            providerCallRequired: false
        )
    }
}

public enum TokenSaverProviderProxyPolicy {
    public static func decision(for mode: DistillDeployMode) -> DistillDeployDecision {
        if mode == .reverseProxy {
            return DistillDeployDecision(
                mode: mode,
                allowed: false,
                reason: "provider HTTP bodies and provider-owned cached transcripts must not be proxied or rewritten"
            )
        }
        return DistillDeployPolicy.decision(for: mode)
    }

    public static func remoteCodeOwnedLaunchEnvironment(usesCustomBaseURL: Bool) -> [String: String] {
        usesCustomBaseURL ? ["ENABLE_TOOL_SEARCH": "true"] : [:]
    }
}

public enum TokenSaverRoutingHint: String, Sendable, Equatable {
    case deterministic
    case astStructure
    case mlClassifier
    case visionDeferred
    case contextImportance
}

public struct TokenSaverContentClassifierDecision: Sendable, Equatable {
    public let contentType: DistillContentType
    public let routingHint: TokenSaverRoutingHint
    public let confidence: Double
}

public enum TokenSaverContentClassifier {
    public static func classify(sample: String, fileName: String?, mimeType: String?) -> TokenSaverContentClassifierDecision {
        let lowerName = fileName?.lowercased() ?? ""
        let lowerMime = mimeType?.lowercased() ?? ""
        if lowerMime.hasPrefix("image/") {
            return TokenSaverContentClassifierDecision(contentType: .mixed, routingHint: .visionDeferred, confidence: 0.90)
        }
        if ["swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "kt"].contains(where: { lowerName.hasSuffix("." + $0) }) ||
            DistillContentRouter().classify(sample) == .sourceCode {
            return TokenSaverContentClassifierDecision(contentType: .sourceCode, routingHint: .astStructure, confidence: 0.88)
        }
        let routed = DistillContentRouter().classify(sample)
        return TokenSaverContentClassifierDecision(contentType: routed, routingHint: .deterministic, confidence: 0.74)
    }
}

public enum VisionTokenAction: String, Sendable, Equatable {
    case passThrough
    case compressMetadata
    case deferUntilMeasuredVolume
}

public struct VisionTokenDecision: Sendable, Equatable {
    public let action: VisionTokenAction
    public let shouldCompress: Bool
    public let reason: String
}

public enum VisionTokenRouter {
    public static func decision(query: String, mimeType: String?, byteCount: Int, isEnabled: Bool) -> VisionTokenDecision {
        guard mimeType?.lowercased().hasPrefix("image/") == true else {
            return VisionTokenDecision(action: .passThrough, shouldCompress: false, reason: "not_image")
        }
        guard isEnabled else {
            return VisionTokenDecision(action: .deferUntilMeasuredVolume, shouldCompress: false, reason: "vision token volume not yet measured")
        }
        let wantsInspection = query.localizedCaseInsensitiveContains("screenshot") ||
            query.localizedCaseInsensitiveContains("image") ||
            query.localizedCaseInsensitiveContains("read")
        return VisionTokenDecision(
            action: wantsInspection && byteCount > 512_000 ? .compressMetadata : .passThrough,
            shouldCompress: wantsInspection && byteCount > 512_000,
            reason: wantsInspection ? "query_image_analysis" : "no_image_intent"
        )
    }
}

public struct TokenSaverContextDropResult: Sendable, Equatable {
    public let output: String
    public let droppedLines: Int
}

public enum TokenSaverContextDropPolicy {
    public static func decide(text: String, maxLines: Int) -> TokenSaverContextDropResult {
        let result = DistillImportanceScorer.compact(text, maxKeep: max(1, maxLines), keepLast: min(8, max(1, maxLines / 3)))
        return TokenSaverContextDropResult(output: result.compacted, droppedLines: result.droppedLines)
    }
}

public struct TokenSaverTelemetryConfiguration: Sendable, Equatable {
    public let otelEnabled: Bool
    public let langfuseEnabled: Bool
    public let otelEndpoint: String?
}

public enum TokenSaverTelemetryExportPolicy {
    public static func defaultConfiguration() -> TokenSaverTelemetryConfiguration {
        TokenSaverTelemetryConfiguration(otelEnabled: false, langfuseEnabled: false, otelEndpoint: nil)
    }

    public static func labels(
        provider: String,
        mode: String,
        routeStage: TokenSaverRouteStage,
        cacheState: String
    ) -> [String: String] {
        [
            "provider": provider,
            "mode": mode,
            "route_stage": routeStage.rawValue,
            "cache_state": cacheState
        ]
    }
}

public struct EcosystemIntegrationDecision: Sendable, Equatable {
    public let toolName: String
    public let allowed: Bool
    public let reason: String
}

public enum EcosystemIntegrationPolicy {
    public static func decision(toolName: String, raisesRemoteCodeSessionSavings: Bool) -> EcosystemIntegrationDecision {
        EcosystemIntegrationDecision(
            toolName: toolName,
            allowed: raisesRemoteCodeSessionSavings,
            reason: raisesRemoteCodeSessionSavings
                ? "directly raises RemoteCode session savings"
                : "outside RemoteCode-owned savings path"
        )
    }
}
