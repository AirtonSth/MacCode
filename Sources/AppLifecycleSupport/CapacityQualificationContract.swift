import Foundation
import CryptoKit

/// Versioned capacity/qualification contract (plan-optimize-swift S1 / T-003).
///
/// Pure data + validation only: freezes workload shape, required metrics,
/// estimator rules, and abort ceilings before any pressure action or tuning.
/// Content-free: never carries prompts, tool output, paths, env, or handles.

public enum CapacityContractError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(String)
    case missingRequiredField(String)
    case requiredMetricNull(String)
    case invalidWorkload(String)
    case invalidEstimator(String)
    case invalidAbortLimit(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let v):
            return "Unsupported capacity contract schema_version: \(v)"
        case .missingRequiredField(let field):
            return "Capacity contract missing required field: \(field)"
        case .requiredMetricNull(let name):
            return "Required capacity metric is null: \(name)"
        case .invalidWorkload(let reason):
            return "Invalid capacity workload: \(reason)"
        case .invalidEstimator(let reason):
            return "Invalid capacity estimator: \(reason)"
        case .invalidAbortLimit(let reason):
            return "Invalid capacity abort limit: \(reason)"
        }
    }
}

/// Metric families that must appear in every qualification artifact.
/// App RSS and provider-tree RSS are deliberately separate keys.
public enum CapacityRequiredMetricKey: String, CaseIterable, Sendable, Codable, Equatable {
    case acceptToPrepareMsP95 = "accept_to_prepare_ms_p95"
    case prepareToSpawnMsP95 = "prepare_to_spawn_ms_p95"
    case eventToVisiblePaintMsP95 = "event_to_visible_paint_ms_p95"
    case stopDispatchMsP95 = "stop_dispatch_ms_p95"
    case dagLongestNoProgressMs = "dag_longest_no_progress_ms"
    case appRSSKB = "app_rss_kb"
    case providerTreeRSSKB = "provider_tree_rss_kb"
    case sidecarRSSKB = "sidecar_rss_kb"
    case ownershipCoverageFraction = "ownership_coverage_fraction"
    case batcherPendingBytes = "batcher_pending_bytes"
    case batcherPendingCount = "batcher_pending_count"
    case lockWaitMsP95 = "lock_wait_ms_p95"
    case mainActorStallMsMax = "main_actor_stall_ms_max"
}

public struct CapacityWorkloadSpec: Sendable, Codable, Equatable {
    public var roots: Int
    public var nestedNodes: Int
    public var depths: [Int]
    public var fanOut: [Int]
    public var providerMix: [String]
    public var explicitStarts: Int
    public var scheduledStarts: Int
    public var activeNodes: Int
    public var waitingNodes: Int
    public var eventRatePerSecond: Double
    public var byteRatePerSecond: Double
    public var terminalCount: Int
    public var clientCount: Int
    public var faultKinds: [String]
    public var tokenSaverMode: String
    public var graphifyMode: String

    public init(
        roots: Int,
        nestedNodes: Int,
        depths: [Int],
        fanOut: [Int],
        providerMix: [String],
        explicitStarts: Int,
        scheduledStarts: Int,
        activeNodes: Int,
        waitingNodes: Int,
        eventRatePerSecond: Double,
        byteRatePerSecond: Double,
        terminalCount: Int,
        clientCount: Int,
        faultKinds: [String],
        tokenSaverMode: String,
        graphifyMode: String
    ) {
        self.roots = roots
        self.nestedNodes = nestedNodes
        self.depths = depths
        self.fanOut = fanOut
        self.providerMix = providerMix
        self.explicitStarts = explicitStarts
        self.scheduledStarts = scheduledStarts
        self.activeNodes = activeNodes
        self.waitingNodes = waitingNodes
        self.eventRatePerSecond = eventRatePerSecond
        self.byteRatePerSecond = byteRatePerSecond
        self.terminalCount = terminalCount
        self.clientCount = clientCount
        self.faultKinds = faultKinds
        self.tokenSaverMode = tokenSaverMode
        self.graphifyMode = graphifyMode
    }
}

public struct CapacityEstimatorSpec: Sendable, Codable, Equatable {
    /// Minimum warmed samples required for a comparable claim (plan: n>=3).
    public var minWarmedSamples: Int
    public var warmUpSeconds: Double
    public var measurementWindowSeconds: Double
    /// Plateau: max relative slope of managed host RSS over the window.
    public var plateauMaxRelativeSlope: Double
    public var p95Definition: String
    public var p99Definition: String

    public init(
        minWarmedSamples: Int = 3,
        warmUpSeconds: Double,
        measurementWindowSeconds: Double,
        plateauMaxRelativeSlope: Double = 0.05,
        p95Definition: String = "empirical_0.95_order_statistic",
        p99Definition: String = "empirical_0.99_order_statistic"
    ) {
        self.minWarmedSamples = minWarmedSamples
        self.warmUpSeconds = warmUpSeconds
        self.measurementWindowSeconds = measurementWindowSeconds
        self.plateauMaxRelativeSlope = plateauMaxRelativeSlope
        self.p95Definition = p95Definition
        self.p99Definition = p99Definition
    }
}

public struct CapacityAbortLimits: Sendable, Codable, Equatable {
    public var maxTokenUnits: Int?
    public var maxSpendMicros: Int64?
    public var maxWallSeconds: Double
    public var maxMainActorStallMs: Double

    public init(
        maxTokenUnits: Int? = nil,
        maxSpendMicros: Int64? = nil,
        maxWallSeconds: Double,
        maxMainActorStallMs: Double = 2_000
    ) {
        self.maxTokenUnits = maxTokenUnits
        self.maxSpendMicros = maxSpendMicros
        self.maxWallSeconds = maxWallSeconds
        self.maxMainActorStallMs = maxMainActorStallMs
    }
}

public struct CapacityHardwareTierClaim: Sendable, Codable, Equatable {
    public var tierName: String
    public var physicalMemoryBytes: UInt64
    /// Only true when this host physically executed the canary.
    public var physicallyExecuted: Bool
    public var providerCLIVersions: [String: String]
    public var modelPins: [String: String]
    public var artifactExpiryISO8601: String

    public init(
        tierName: String,
        physicalMemoryBytes: UInt64,
        physicallyExecuted: Bool,
        providerCLIVersions: [String: String] = [:],
        modelPins: [String: String] = [:],
        artifactExpiryISO8601: String
    ) {
        self.tierName = tierName
        self.physicalMemoryBytes = physicalMemoryBytes
        self.physicallyExecuted = physicallyExecuted
        self.providerCLIVersions = providerCLIVersions
        self.modelPins = modelPins
        self.artifactExpiryISO8601 = artifactExpiryISO8601
    }
}

public struct CapacityQualificationManifest: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = "1.0.0"

    public var schemaVersion: String
    public var id: String
    public var workload: CapacityWorkloadSpec
    public var estimator: CapacityEstimatorSpec
    public var abortLimits: CapacityAbortLimits
    public var requiredMetrics: [String]
    public var hardwareTier: [CapacityHardwareTierClaim]
    public var notes: String?

    public init(
        schemaVersion: String = CapacityQualificationManifest.currentSchemaVersion,
        id: String,
        workload: CapacityWorkloadSpec,
        estimator: CapacityEstimatorSpec,
        abortLimits: CapacityAbortLimits,
        requiredMetrics: [String] = CapacityRequiredMetricKey.allCases.map(\.rawValue),
        hardwareTier: [CapacityHardwareTierClaim] = [],
        notes: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.workload = workload
        self.estimator = estimator
        self.abortLimits = abortLimits
        self.requiredMetrics = requiredMetrics
        self.hardwareTier = hardwareTier
        self.notes = notes
    }

    public static func defaultHardcoreSwarm(id: String = "hardcore-swarm-v1") -> CapacityQualificationManifest {
        CapacityQualificationManifest(
            id: id,
            workload: CapacityWorkloadSpec(
                roots: 32,
                nestedNodes: 64,
                depths: [1, 2, 4],
                fanOut: [1, 2, 4],
                providerMix: ["claude", "codex", "grok", "fake"],
                explicitStarts: 32,
                scheduledStarts: 8,
                activeNodes: 48,
                waitingNodes: 16,
                eventRatePerSecond: 200,
                byteRatePerSecond: 2_000_000,
                terminalCount: 8,
                clientCount: 4,
                faultKinds: ["malformed_frame", "reorder", "pipe_pressure", "stop_race", "resume"],
                tokenSaverMode: "on_and_off",
                graphifyMode: "on_and_off"
            ),
            estimator: CapacityEstimatorSpec(
                minWarmedSamples: 3,
                warmUpSeconds: 30,
                measurementWindowSeconds: 120,
                plateauMaxRelativeSlope: 0.05
            ),
            abortLimits: CapacityAbortLimits(
                maxTokenUnits: 500_000,
                maxSpendMicros: 5_000_000,
                maxWallSeconds: 1_800,
                maxMainActorStallMs: 2_000
            ),
            notes: "Frozen hardcore multi-agent workload for plan-optimize-swift T-003."
        )
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CapacityContractError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !id.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw CapacityContractError.missingRequiredField("id")
        }
        if workload.roots < 1 {
            throw CapacityContractError.invalidWorkload("roots must be >= 1")
        }
        if workload.nestedNodes < 0 {
            throw CapacityContractError.invalidWorkload("nestedNodes must be >= 0")
        }
        if workload.depths.isEmpty {
            throw CapacityContractError.invalidWorkload("depths must be non-empty")
        }
        if workload.providerMix.isEmpty {
            throw CapacityContractError.invalidWorkload("providerMix must be non-empty")
        }
        if estimator.minWarmedSamples < 3 {
            throw CapacityContractError.invalidEstimator("minWarmedSamples must be >= 3")
        }
        if estimator.measurementWindowSeconds <= 0 {
            throw CapacityContractError.invalidEstimator("measurementWindowSeconds must be > 0")
        }
        if abortLimits.maxWallSeconds <= 0 {
            throw CapacityContractError.invalidAbortLimit("maxWallSeconds must be > 0")
        }
        if abortLimits.maxMainActorStallMs <= 0 {
            throw CapacityContractError.invalidAbortLimit("maxMainActorStallMs must be > 0")
        }
        // Paid real-provider canaries fail closed: token/spend ceilings required.
        guard let maxTokens = abortLimits.maxTokenUnits, maxTokens > 0 else {
            throw CapacityContractError.invalidAbortLimit(
                "maxTokenUnits must be declared and > 0 for fail-closed canary"
            )
        }
        guard let maxSpend = abortLimits.maxSpendMicros, maxSpend > 0 else {
            throw CapacityContractError.invalidAbortLimit(
                "maxSpendMicros must be declared and > 0 for fail-closed canary"
            )
        }
        _ = maxTokens
        _ = maxSpend
        let required = Set(CapacityRequiredMetricKey.allCases.map(\.rawValue))
        let declared = Set(requiredMetrics)
        if !required.isSubset(of: declared) {
            let missing = required.subtracting(declared).sorted().joined(separator: ",")
            throw CapacityContractError.missingRequiredField("requiredMetrics:\(missing)")
        }
        for tier in hardwareTier where tier.physicallyExecuted {
            if tier.physicalMemoryBytes == 0 {
                throw CapacityContractError.invalidWorkload(
                    "physicallyExecuted tier \(tier.tierName) must declare physicalMemoryBytes"
                )
            }
            // Freshness: physical claims must carry a parseable future-or-present expiry.
            let expiry = tier.artifactExpiryISO8601.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if expiry.isEmpty {
                throw CapacityContractError.invalidWorkload(
                    "physicallyExecuted tier \(tier.tierName) must declare artifactExpiryISO8601"
                )
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var expiryDate = formatter.date(from: expiry)
            if expiryDate == nil {
                formatter.formatOptions = [.withInternetDateTime]
                expiryDate = formatter.date(from: expiry)
            }
            guard let expiryDate else {
                throw CapacityContractError.invalidWorkload(
                    "physicallyExecuted tier \(tier.tierName) has unparseable artifactExpiryISO8601"
                )
            }
            if expiryDate < Date() {
                throw CapacityContractError.invalidWorkload(
                    "physicallyExecuted tier \(tier.tierName) artifact is expired"
                )
            }
        }
    }

    public static func decodeAndValidate(from data: Data) throws -> CapacityQualificationManifest {
        let decoded = try JSONDecoder().decode(CapacityQualificationManifest.self, from: data)
        try decoded.validate()
        return decoded
    }

    public func encodePretty() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Stable content digest for artifact binding (not just id equality).
    public func contentDigest() throws -> String {
        let data = try encodePretty()
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Qualification run artifact: required metrics are fatal when null.
public struct CapacityMetricSample: Sendable, Codable, Equatable {
    public var name: String
    /// Null means unavailable. Required metrics must not be null in a pass artifact.
    public var value: Double?
    public var unit: String

    public init(name: String, value: Double?, unit: String) {
        self.name = name
        self.value = value
        self.unit = unit
    }
}

public struct CapacityWarmedRunObservation: Sendable, Codable, Equatable {
    public var runIndex: Int
    public var metrics: [String: Double]

    public init(runIndex: Int, metrics: [String: Double]) {
        self.runIndex = runIndex
        self.metrics = metrics
    }
}

public struct CapacityQualificationArtifact: Sendable, Codable, Equatable {
    public var manifestId: String
    public var schemaVersion: String
    public var samples: [CapacityMetricSample]
    public var warmedSampleCount: Int
    public var physicallyExecutedTier: [String]
    public var createdAtISO8601: String
    public var manifestDigest: String
    /// Per-run metric observations used to prove warmed n>=3 variance.
    public var warmedRuns: [CapacityWarmedRunObservation]
    /// Max relative range ((max-min)/max) across warmed runs per required metric.
    public var metricVarianceMax: [String: Double]
    /// Prior same-machine baseline means for p95/p99 regression (empty = first run).
    public var priorBaselineMeans: [String: Double]

    public init(
        manifestId: String,
        schemaVersion: String = CapacityQualificationManifest.currentSchemaVersion,
        samples: [CapacityMetricSample],
        warmedSampleCount: Int,
        physicallyExecutedTier: [String],
        createdAtISO8601: String,
        manifestDigest: String,
        warmedRuns: [CapacityWarmedRunObservation] = [],
        metricVarianceMax: [String: Double] = [:],
        priorBaselineMeans: [String: Double] = [:]
    ) {
        self.manifestId = manifestId
        self.schemaVersion = schemaVersion
        self.samples = samples
        self.warmedSampleCount = warmedSampleCount
        self.physicallyExecutedTier = physicallyExecutedTier
        self.createdAtISO8601 = createdAtISO8601
        self.manifestDigest = manifestDigest
        self.warmedRuns = warmedRuns
        self.metricVarianceMax = metricVarianceMax
        self.priorBaselineMeans = priorBaselineMeans
    }

    public func validate(against manifest: CapacityQualificationManifest) throws {
        try manifest.validate()
        guard schemaVersion == manifest.schemaVersion else {
            throw CapacityContractError.unsupportedSchemaVersion(schemaVersion)
        }
        guard manifestId == manifest.id else {
            throw CapacityContractError.missingRequiredField("manifestId mismatch")
        }
        if warmedSampleCount < manifest.estimator.minWarmedSamples {
            throw CapacityContractError.invalidEstimator(
                "warmedSampleCount \(warmedSampleCount) < min \(manifest.estimator.minWarmedSamples)"
            )
        }
        if warmedRuns.count < manifest.estimator.minWarmedSamples {
            throw CapacityContractError.invalidEstimator(
                "warmedRuns \(warmedRuns.count) < min \(manifest.estimator.minWarmedSamples)"
            )
        }
        // Duplicate metric names fail loud (no Dictionary trap).
        var seen = Set<String>()
        for sample in samples {
            if seen.contains(sample.name) {
                throw CapacityContractError.invalidWorkload("duplicate metric \(sample.name)")
            }
            seen.insert(sample.name)
            if sample.unit.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                throw CapacityContractError.invalidWorkload("metric \(sample.name) missing unit")
            }
        }
        let byName = Dictionary(uniqueKeysWithValues: samples.map { ($0.name, $0) })
        for key in manifest.requiredMetrics {
            guard let sample = byName[key] else {
                throw CapacityContractError.missingRequiredField(key)
            }
            if sample.value == nil {
                throw CapacityContractError.requiredMetricNull(key)
            }
            guard let claimed = sample.value, claimed.isFinite else {
                throw CapacityContractError.invalidWorkload("metric \(key) must be finite")
            }
            if key == CapacityRequiredMetricKey.ownershipCoverageFraction.rawValue {
                // Promotion requires complete ownership (release-gates).
                guard claimed == 1.0 else {
                    throw CapacityContractError.invalidWorkload(
                        "ownership_coverage_fraction must be 1.0 for promotion (got \(claimed))"
                    )
                }
            } else if key == CapacityRequiredMetricKey.mainActorStallMsMax.rawValue {
                guard claimed < manifest.abortLimits.maxMainActorStallMs else {
                    throw CapacityContractError.invalidWorkload(
                        "main_actor_stall_ms_max \(claimed) >= abort \(manifest.abortLimits.maxMainActorStallMs)"
                    )
                }
            } else if claimed < 0 {
                throw CapacityContractError.invalidWorkload("metric \(key) must be >= 0")
            }
            // Each required metric must appear in every warmed run; sample is the mean.
            var sum = 0.0
            for run in warmedRuns {
                guard let v = run.metrics[key], v.isFinite else {
                    throw CapacityContractError.missingRequiredField("warmedRun.\(run.runIndex).\(key)")
                }
                if key == CapacityRequiredMetricKey.ownershipCoverageFraction.rawValue {
                    guard v == 1.0 else {
                        throw CapacityContractError.invalidWorkload(
                            "warmed ownership_coverage_fraction must be 1.0 (got \(v))"
                        )
                    }
                } else if key == CapacityRequiredMetricKey.mainActorStallMsMax.rawValue {
                    guard v < manifest.abortLimits.maxMainActorStallMs else {
                        throw CapacityContractError.invalidWorkload(
                            "warmed main_actor_stall_ms_max \(v) exceeds abort"
                        )
                    }
                } else if v < 0 {
                    throw CapacityContractError.invalidWorkload("warmed metric \(key) must be >= 0")
                }
                sum += v
            }
            let mean = sum / Double(warmedRuns.count)
            if abs(claimed - mean) > 1e-9 {
                throw CapacityContractError.invalidEstimator("sample \(key) != mean of warmedRuns")
            }
            guard metricVarianceMax[key] != nil else {
                throw CapacityContractError.missingRequiredField("metricVarianceMax.\(key)")
            }
        }
        // Physical tier set must exactly equal physically executed claims (or both empty).
        let claimed = Set(manifest.hardwareTier.filter(\.physicallyExecuted).map(\.tierName))
        let reported = Set(physicallyExecutedTier)
        if claimed != reported {
            throw CapacityContractError.invalidWorkload("physical tier set mismatch claimed=\(claimed.sorted()) reported=\(reported.sorted())")
        }
        // Unique warmed run indices + recompute variance from runs.
        var seenIdx = Set<Int>()
        for run in warmedRuns {
            if seenIdx.contains(run.runIndex) {
                throw CapacityContractError.invalidEstimator("duplicate warmed runIndex \(run.runIndex)")
            }
            seenIdx.insert(run.runIndex)
        }
        if warmedRuns.count != warmedSampleCount {
            throw CapacityContractError.invalidEstimator("warmedRuns.count != warmedSampleCount")
        }
        for key in manifest.requiredMetrics {
            let values = warmedRuns.compactMap { $0.metrics[key] }
            guard values.count == warmedRuns.count else {
                throw CapacityContractError.missingRequiredField("warmedRun.\(key)")
            }
            let lo = values.min() ?? 0
            let hi = values.max() ?? 0
            let recomputed = hi == 0 ? 0 : (hi - lo) / hi
            guard let declared = metricVarianceMax[key] else {
                throw CapacityContractError.missingRequiredField("metricVarianceMax.\(key)")
            }
            guard declared.isFinite, declared >= 0, declared <= 1 else {
                throw CapacityContractError.invalidEstimator("metricVarianceMax.\(key) must be finite in [0,1]")
            }
            if abs(declared - recomputed) > 1e-9 {
                throw CapacityContractError.invalidEstimator("variance mismatch for \(key)")
            }
            // Estimator quality: relative range across current warmed runs ≤0.10.
            if key.hasSuffix("_p95") || key.hasSuffix("_p99") || key == CapacityRequiredMetricKey.lockWaitMsP95.rawValue {
                if declared > 0.10 {
                    throw CapacityContractError.invalidEstimator(
                        "variance gate: \(key) relative range \(declared) > 0.10"
                    )
                }
            }
            // Promotion mode (any physical tier claimed): prior baseline required
            // for latency metrics. Bootstrap/first-run uses empty physical tiers.
            let promotionMode = !self.physicallyExecutedTier.isEmpty
            if promotionMode,
               (key.hasSuffix("_p95") || key.hasSuffix("_p99") || key == CapacityRequiredMetricKey.lockWaitMsP95.rawValue) {
                guard let prior = self.priorBaselineMeans[key], prior > 0 else {
                    throw CapacityContractError.missingRequiredField("priorBaselineMeans.\(key)")
                }
                let currentMean = byName[key]?.value ?? 0
                let regression = (currentMean - prior) / prior
                if regression > 0.10 {
                    throw CapacityContractError.invalidEstimator(
                        "regression gate: \(key) \(regression) > 0.10 vs prior baseline"
                    )
                }
            }
        }
        // Bind artifact to immutable manifest content digest.
        let expectedDigest = try manifest.contentDigest()
        if manifestDigest != expectedDigest {
            throw CapacityContractError.invalidWorkload("manifestDigest mismatch")
        }
    }
}

// CapacityGaugeSnapshot + CapacityGaugeRecorder live in AgentRuntime so the
// accept→spawn production path can record without a package cycle (S1).
