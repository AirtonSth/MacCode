import Foundation

/// Gate -1 / Fase 0A addressability + memory-only probe (task-04).
/// Pure policy: never promotes lanes; never writes production SQLite/WAL/backup.
public enum TokenSaverAddressabilityGate {
    public static let schemaVersion = 1
    public static let taskID = "task-04"

    /// Absolute opportunity threshold (eligible tokens) before a slice may authorize build.
    public static let absoluteOpportunityThreshold: Int64 = 1_000

    /// Expected net value after overlap/cost must be > 0 to authorize.
    public static let minimumNetExpectedValue: Double = 0.0

    public struct SliceOpportunity: Sendable, Equatable {
        public let binding: TokenSaverBindingID
        public let absoluteEligibleTokens: Int64
        public let overlapFraction: Double
        public let incrementalCost: Double
        public let expectedValuePerToken: Double

        public var bindingDigestHex: String { binding.digestHex }

        /// Internal until a trusted census adapter constructs opportunities from
        /// provider-measured token events. External callers cannot label arbitrary
        /// character/byte counts as eligible tokens.
        internal init(
            binding: TokenSaverBindingID,
            absoluteEligibleTokens: Int64,
            overlapFraction: Double,
            incrementalCost: Double,
            expectedValuePerToken: Double
        ) {
            self.binding = binding
            self.absoluteEligibleTokens = absoluteEligibleTokens
            self.overlapFraction = min(max(overlapFraction, 0), 1)
            self.incrementalCost = max(incrementalCost, 0)
            self.expectedValuePerToken = expectedValuePerToken
        }

        /// Net expected value after overlap and incremental cost.
        public var netExpectedValue: Double {
            let uniqueTokens = Double(absoluteEligibleTokens) * (1.0 - overlapFraction)
            return uniqueTokens * expectedValuePerToken - incrementalCost
        }

        public var meetsAbsoluteThreshold: Bool {
            absoluteEligibleTokens >= TokenSaverAddressabilityGate.absoluteOpportunityThreshold
        }

        public var isQualifying: Bool {
            binding.isComplete
                && meetsAbsoluteThreshold
                && netExpectedValue.isFinite
                && netExpectedValue > TokenSaverAddressabilityGate.minimumNetExpectedValue
        }
    }

    public enum SharedInfraDecision: Sendable, Equatable {
        case authorized(reusedBySlices: Int)
        case deniedNeedsAtLeastTwoSlices(observed: Int)
    }

    public enum BuildAuthorization: Sendable, Equatable {
        case authorizeNextSlice(bindingDigestHex: String)
        case denyBelowThreshold
        case denyNonPositiveNetValue
        case denyIncompleteBinding
        case denyEmptyPortfolio
    }

    /// Gate 0A / -1: at most one next disposable slice when opportunity clears.
    /// Qualifying candidates are filtered first (threshold + net value), then the
    /// highest absolute volume (tie-break net value, then digest) wins.
    public static func authorizeBuild(sortedByPriority opportunities: [SliceOpportunity]) -> BuildAuthorization {
        guard !opportunities.isEmpty else { return .denyEmptyPortfolio }
        let qualifying = opportunities.filter(\.isQualifying)
        if qualifying.isEmpty {
            if opportunities.contains(where: { $0.meetsAbsoluteThreshold && !$0.binding.isComplete }) {
                return .denyIncompleteBinding
            }
            if opportunities.contains(where: { $0.meetsAbsoluteThreshold }) {
                return .denyNonPositiveNetValue
            }
            return .denyBelowThreshold
        }
        let winner = qualifying.sorted {
            if $0.absoluteEligibleTokens != $1.absoluteEligibleTokens {
                return $0.absoluteEligibleTokens > $1.absoluteEligibleTokens
            }
            if $0.netExpectedValue != $1.netExpectedValue {
                return $0.netExpectedValue > $1.netExpectedValue
            }
            return $0.bindingDigestHex < $1.bindingDigestHex
        }.first!
        return .authorizeNextSlice(bindingDigestHex: winner.bindingDigestHex)
    }

    /// Shared infrastructure requires ≥2 slices demonstrating reuse.
    public static func authorizeSharedInfrastructure(sliceCountDemonstratingReuse: Int) -> SharedInfraDecision {
        if sliceCountDemonstratingReuse >= 2 {
            return .authorized(reusedBySlices: sliceCountDemonstratingReuse)
        }
        return .deniedNeedsAtLeastTwoSlices(observed: sliceCountDemonstratingReuse)
    }
}

/// Memory-only synthetic probe (Fase 0A). Never opens production SQLite/WAL/backup paths.
public final class TokenSaverMemoryOnlyProbe: @unchecked Sendable {
    public enum Arm: String, Sendable, CaseIterable {
        case noChange = "no_change"
        case wrapperExact = "wrapper_exact"
        case providerNative = "provider_native"
    }

    public struct ArmResult: Sendable, Equatable {
        public let arm: Arm
        public let outputTokens: Int64
        public let latencyMs: Double
    }

    public struct Comparison: Sendable, Equatable {
        public let arms: [ArmResult]
        public let bestArm: Arm
        public let deltaVsNoChange: Int64
    }

    private let lock = NSLock()
    private var memoryBlobs: [String: Data] = [:]
    private(set) public var refusedProductionPaths: [String] = []

    public init() {}

    /// Production path patterns that must never be written by the probe.
    public static let forbiddenPathSubstrings: [String] = [
        ".sqlite",
        ".sqlite-wal",
        ".sqlite-shm",
        "/WAL",
        "backup",
        "Application Support/RemoteCode",
    ]

    public func isForbiddenProductionPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return Self.forbiddenPathSubstrings.contains { lower.contains($0.lowercased()) }
    }

    /// Attempt to persist probe envelope. Production-like paths are refused; memory-only succeeds.
    @discardableResult
    public func storeEnvelope(id: String, bytes: Data, pathHint: String?) -> Bool {
        if let pathHint, isForbiddenProductionPath(pathHint) {
            lock.lock()
            refusedProductionPaths.append(pathHint)
            lock.unlock()
            return false
        }
        lock.lock()
        memoryBlobs[id] = bytes
        lock.unlock()
        return true
    }

    public func loadEnvelope(id: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return memoryBlobs[id]
    }

    public var memoryBlobCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return memoryBlobs.count
    }

    /// Compare no-change vs wrapper/exact and optional provider-native mock.
    public func compareArms(
        rawTokens: Int64,
        wrapperTokens: Int64,
        providerNativeTokens: Int64?
    ) -> Comparison {
        let raw = max(0, rawTokens)
        let wrapper = max(0, wrapperTokens)
        var arms: [ArmResult] = [
            .init(arm: .noChange, outputTokens: raw, latencyMs: 0),
            .init(arm: .wrapperExact, outputTokens: wrapper, latencyMs: 1),
        ]
        if let native = providerNativeTokens {
            arms.append(.init(arm: .providerNative, outputTokens: max(0, native), latencyMs: 2))
        }
        let best = arms.min(by: { $0.outputTokens < $1.outputTokens })!.arm
        let noChange = arms.first(where: { $0.arm == .noChange })!.outputTokens
        let bestTokens = arms.first(where: { $0.arm == best })!.outputTokens
        return Comparison(
            arms: arms,
            bestArm: best,
            deltaVsNoChange: noChange - bestTokens
        )
    }
}
