import Foundation

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
                maxTokenUnits: nil,
                maxSpendMicros: nil,
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
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
        let required = Set(CapacityRequiredMetricKey.allCases.map(\.rawValue))
        let declared = Set(requiredMetrics)
        if !required.isSubset(of: declared) {
            let missing = required.subtracting(declared).sorted().joined(separator: ",")
            throw CapacityContractError.missingRequiredField("requiredMetrics:\(missing)")
        }
        for tier in hardwareTier where tier.physicallyExecuted && tier.physicalMemoryBytes == 0 {
            throw CapacityContractError.invalidWorkload(
                "physicallyExecuted tier \(tier.tierName) must declare physicalMemoryBytes"
            )
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
    /// Per-run metric observations used to prove warmed n>=3 variance.
    public var warmedRuns: [CapacityWarmedRunObservation]
    /// Max relative range ((max-min)/max) across warmed runs per required metric.
    public var metricVarianceMax: [String: Double]

    public init(
        manifestId: String,
        schemaVersion: String = CapacityQualificationManifest.currentSchemaVersion,
        samples: [CapacityMetricSample],
        warmedSampleCount: Int,
        physicallyExecutedTier: [String],
        createdAtISO8601: String,
        warmedRuns: [CapacityWarmedRunObservation] = [],
        metricVarianceMax: [String: Double] = [:]
    ) {
        self.manifestId = manifestId
        self.schemaVersion = schemaVersion
        self.samples = samples
        self.warmedSampleCount = warmedSampleCount
        self.physicallyExecutedTier = physicallyExecutedTier
        self.createdAtISO8601 = createdAtISO8601
        self.warmedRuns = warmedRuns
        self.metricVarianceMax = metricVarianceMax
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
            if sample.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            // Each required metric must appear in every warmed run.
            for run in warmedRuns {
                guard let v = run.metrics[key] else {
                    throw CapacityContractError.missingRequiredField("warmedRun.\(run.runIndex).\(key)")
                }
                _ = v
            }
            guard metricVarianceMax[key] != nil else {
                throw CapacityContractError.missingRequiredField("metricVarianceMax.\(key)")
            }
        }
        // Physical tier claims must match manifest (or be empty when none claimed).
        let claimed = Set(manifest.hardwareTier.filter(\.physicallyExecuted).map(\.tierName))
        for name in physicallyExecutedTier {
            if !claimed.isEmpty && !claimed.contains(name) {
                throw CapacityContractError.invalidWorkload("unclaimed physical tier \(name)")
            }
        }
    }
}


/// Content-free gauge snapshot for signpost-style capacity instrumentation.
public struct CapacityGaugeSnapshot: Sendable, Codable, Equatable {
    public var acceptToPrepareMs: Double?
    public var prepareToSpawnMs: Double?
    public var ingressBytesThread: Int64
    public var ingressBytesGlobal: Int64
    public var durableCursor: Int64?
    public var lockWaitMs: Double?
    public var dbWaitMs: Double?
    public var subscriberQueueDepth: Int
    public var batcherPendingBytes: Int64
    public var batcherPendingCount: Int
    public var outboundQueueBytes: Int64
    public var eventToVisiblePaintMs: Double?
    public var stopDispatchMs: Double?
    public var dagLongestNoProgressMs: Double?
    public var appRSSKB: Int64?
    public var providerTreeRSSKB: Int64?
    public var sidecarRSSKB: Int64?
    public var openDescriptors: Int?
    public var ownershipCoverageFraction: Double?

    public init(
        acceptToPrepareMs: Double? = nil,
        prepareToSpawnMs: Double? = nil,
        ingressBytesThread: Int64 = 0,
        ingressBytesGlobal: Int64 = 0,
        durableCursor: Int64? = nil,
        lockWaitMs: Double? = nil,
        dbWaitMs: Double? = nil,
        subscriberQueueDepth: Int = 0,
        batcherPendingBytes: Int64 = 0,
        batcherPendingCount: Int = 0,
        outboundQueueBytes: Int64 = 0,
        eventToVisiblePaintMs: Double? = nil,
        stopDispatchMs: Double? = nil,
        dagLongestNoProgressMs: Double? = nil,
        appRSSKB: Int64? = nil,
        providerTreeRSSKB: Int64? = nil,
        sidecarRSSKB: Int64? = nil,
        openDescriptors: Int? = nil,
        ownershipCoverageFraction: Double? = nil
    ) {
        self.acceptToPrepareMs = acceptToPrepareMs
        self.prepareToSpawnMs = prepareToSpawnMs
        self.ingressBytesThread = ingressBytesThread
        self.ingressBytesGlobal = ingressBytesGlobal
        self.durableCursor = durableCursor
        self.lockWaitMs = lockWaitMs
        self.dbWaitMs = dbWaitMs
        self.subscriberQueueDepth = subscriberQueueDepth
        self.batcherPendingBytes = batcherPendingBytes
        self.batcherPendingCount = batcherPendingCount
        self.outboundQueueBytes = outboundQueueBytes
        self.eventToVisiblePaintMs = eventToVisiblePaintMs
        self.stopDispatchMs = stopDispatchMs
        self.dagLongestNoProgressMs = dagLongestNoProgressMs
        self.appRSSKB = appRSSKB
        self.providerTreeRSSKB = providerTreeRSSKB
        self.sidecarRSSKB = sidecarRSSKB
        self.openDescriptors = openDescriptors
        self.ownershipCoverageFraction = ownershipCoverageFraction
    }
}
