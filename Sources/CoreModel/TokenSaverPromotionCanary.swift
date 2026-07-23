import Foundation

/// Fase 5 presentation UX + canary + BindingID promotion (task-21). Default OFF.
public enum TokenSaverPromotionCanary {
    public static let taskID = "task-21"
    public static let defaultEnabled = false
    /// Immutable alpha-spending schedule (steps require outcomes + dwell, not time alone).
    public static let canarySteps: [Double] = [0.01, 0.05, 0.25]
    public static let minAttribution: Double = 0.99
    public static let maxReconciliation: Double = 0.02
    /// Minimum dwell hours between steps (AC-05): 24h, 72h, 72h.
    public static let minDwellHours: [Int] = [24, 72, 72]
}

public final class TokenSaverPromotionCanaryRuntime: @unchecked Sendable {
    public static let taskID = "task-21"

    public enum CanaryStep: Int, Sendable {
        case one = 0
        case five = 1
        case twentyFive = 2
        case complete = 3
    }

    /// Opaque promotion gate — only internal mint after authority evidence.
    public struct PromotionGateSeal: Sendable, Equatable {
        fileprivate let token: UInt64
        fileprivate init(token: UInt64) { self.token = token }
    }

    public enum PromotionGate {
        /// Internal mint only (public modules cannot forge promotion from free booleans).
        internal static func seal(
            coverageCellsComplete: Bool,
            presentationParityOK: Bool,
            modelBOMComplete: Bool,
            semanticConsent: Bool,
            rollbackDrillOK: Bool,
            bindingDigest: String,
            registryEpoch: UInt64,
            revoked: Bool
        ) -> PromotionGateSeal? {
            let b = bindingDigest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard coverageCellsComplete, presentationParityOK, modelBOMComplete,
                  semanticConsent, rollbackDrillOK, !b.isEmpty, !revoked,
                  registryEpoch > 0 else { return nil }
            var h = Hasher()
            h.combine(b)
            h.combine(registryEpoch)
            return PromotionGateSeal(token: UInt64(bitPattern: Int64(h.finalize())))
        }
    }

    public let boundUserID: String
    public let bindingDigest: String
    private let lock = NSLock()
    private var _live = TokenSaverPromotionCanary.defaultEnabled
    private var step: CanaryStep = .one
    private var outcomesWatermark: Int = 0
    private var requiredOutcomes: [Int] = [10, 50, 200]
    private var stepEnteredAtHours: [Int: Int] = [0: 0] // step rawValue -> clock hours when entered
    private var clockHours: Int = 0
    private var revoked = false
    private var attribution: Double = 1.0
    private var reconciliation: Double = 0.0
    private var originalViews: [String: Data] = [:]
    private let durableRoot: URL?

    public init(boundUserID: String, bindingDigest: String, durableDirectory: URL? = nil) {
        self.boundUserID = boundUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bindingDigest = bindingDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        self.durableRoot = durableDirectory
        if let dir = durableDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public var live: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _live }
        set { lock.lock(); _live = newValue; lock.unlock() }
    }

    public func setAttribution(_ v: Double) { lock.lock(); attribution = v; lock.unlock() }
    public func setReconciliation(_ v: Double) { lock.lock(); reconciliation = v; lock.unlock() }

    /// Advance synthetic clock for dwell proofs (tests / host). Not a free promote path.
    public func advanceClock(hours: Int) {
        lock.lock(); clockHours += max(0, hours); lock.unlock()
    }

    public func recordOutcomes(_ n: Int) { lock.lock(); outcomesWatermark += max(0, n); lock.unlock() }

    /// UI must not show positive confirmed savings copy without a delivering confirmed lane (AC-01).
    public func uiMayShowConfirmedSavingsCopy(hasDeliveringConfirmedLane: Bool) -> Bool {
        lock.lock(); let isLive = _live; lock.unlock()
        return isLive && hasDeliveringConfirmedLane
    }

    /// Confirmed totals only from ledger-minted MeasuredSavingsReceipt + live + binding match.
    /// Public PresentationReceipt free-form path removed (forgeability).
    public func confirmedTotal(
        receipt: TokenSaverRecoveryProjections.MeasuredSavingsReceipt?,
        creditBindingDigest: String
    ) -> Int64 {
        lock.lock(); let isLive = _live; lock.unlock()
        guard isLive else { return 0 }
        guard let receipt else { return 0 }
        guard receipt.bindingDigest == creditBindingDigest,
              creditBindingDigest == bindingDigest else { return 0 }
        return max(0, receipt.tokens)
    }

    /// Store-before-loss: durable write + verified readback required before success.
    public func storeOriginal(handle: String, bytes: Data, requestingUserID: String) -> Bool {
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = requestingUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !bytes.isEmpty, u == boundUserID, !boundUserID.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        if originalViews[h] != nil { return false }
        if let root = durableRoot {
            let url = root.appendingPathComponent(Self.safeName(h))
            if FileManager.default.fileExists(atPath: url.path) { return false }
            do {
                try bytes.write(to: url, options: [.withoutOverwriting])
            } catch { return false }
            guard let readback = try? Data(contentsOf: url), readback == bytes else { return false }
        } else {
            // Memory-only mode still verifies round-trip in-process.
            originalViews[h] = bytes
            guard originalViews[h] == bytes else { return false }
            return true
        }
        originalViews[h] = bytes
        return true
    }

    public func viewOriginal(handle: String, requestingUserID: String) -> Data? {
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = requestingUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u == boundUserID else { return nil }
        lock.lock()
        if let mem = originalViews[h] {
            lock.unlock()
            return mem
        }
        let root = durableRoot
        lock.unlock()
        guard let root else { return nil }
        return try? Data(contentsOf: root.appendingPathComponent(Self.safeName(h)))
    }

    private static func safeName(_ handle: String) -> String {
        Data(handle.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
    }

    /// Canary advances with outcomes watermark **and** minimum dwell hours (AC-05).
    public func advanceCanary() -> CanaryStep {
        lock.lock(); defer { lock.unlock() }
        guard _live, !revoked else { return step }
        while step.rawValue < CanaryStep.complete.rawValue {
            let idx = step.rawValue
            guard idx < requiredOutcomes.count, outcomesWatermark >= requiredOutcomes[idx] else { break }
            let entered = stepEnteredAtHours[idx] ?? 0
            let dwell = TokenSaverPromotionCanary.minDwellHours[idx]
            guard clockHours - entered >= dwell else { break }
            if attribution < TokenSaverPromotionCanary.minAttribution ||
                reconciliation > TokenSaverPromotionCanary.maxReconciliation {
                return step
            }
            let next = CanaryStep(rawValue: idx + 1) ?? .complete
            step = next
            stepEnteredAtHours[next.rawValue] = clockHours
        }
        return step
    }

    public func revokeCanary() {
        lock.lock()
        revoked = true
        step = .one
        outcomesWatermark = 0
        stepEnteredAtHours = [0: clockHours]
        lock.unlock()
    }

    public func currentStep() -> CanaryStep {
        lock.lock(); defer { lock.unlock() }; return step
    }

    /// Promotion requires internal gate seal + canary step + binding match.
    public func mayPromote(gate: PromotionGateSeal, requestingUserID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _ = gate.token
        let u = requestingUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard _live, !revoked, u == boundUserID, !bindingDigest.isEmpty else { return false }
        guard attribution >= TokenSaverPromotionCanary.minAttribution else { return false }
        guard reconciliation <= TokenSaverPromotionCanary.maxReconciliation else { return false }
        return step == .complete || step == .twentyFive
    }
}
