import Foundation

/// Fase 5 presentation UX + canary + BindingID promotion (task-21). Default OFF.
public enum TokenSaverPromotionCanary {
    public static let taskID = "task-21"
    public static let defaultEnabled = false
    /// Immutable alpha-spending schedule (steps require outcomes, not time alone).
    public static let canarySteps: [Double] = [0.01, 0.05, 0.25]
    public static let minAttribution: Double = 0.99
    public static let maxReconciliation: Double = 0.02
}

public final class TokenSaverPromotionCanaryRuntime: @unchecked Sendable {
    public static let taskID = "task-21"

    public enum CanaryStep: Int, Sendable {
        case one = 0
        case five = 1
        case twentyFive = 2
        case complete = 3
    }

    public struct PresentationReceipt: Sendable, Equatable {
        public let bindingDigest: String
        public let measuredTokens: Int64
        public let estimatedTokens: Int64
        public let confirmed: Bool
        public let originalHandle: String?
    }

    private let lock = NSLock()
    private var _live = TokenSaverPromotionCanary.defaultEnabled
    private var step: CanaryStep = .one
    private var outcomesWatermark: Int = 0
    private var requiredOutcomes: [Int] = [10, 50, 200]
    private var revoked = false
    private var coverageCellsComplete = false
    private var attribution: Double = 1.0
    private var reconciliation: Double = 0.0
    private var modelBOMComplete = false
    private var semanticConsent = false
    private var presentationParityOK = false
    private var originalViews: [String: Data] = [:] // handle -> original (memory cache)
    private let durableRoot: URL?

    public init(durableDirectory: URL? = nil) {
        self.durableRoot = durableDirectory
        if let dir = durableDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public var live: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _live }
        set { lock.lock(); _live = newValue; lock.unlock() }
    }

    public func setCoverageComplete(_ v: Bool) { lock.lock(); coverageCellsComplete = v; lock.unlock() }
    public func setAttribution(_ v: Double) { lock.lock(); attribution = v; lock.unlock() }
    public func setReconciliation(_ v: Double) { lock.lock(); reconciliation = v; lock.unlock() }
    public func setModelBOMComplete(_ v: Bool) { lock.lock(); modelBOMComplete = v; lock.unlock() }
    public func setSemanticConsent(_ v: Bool) { lock.lock(); semanticConsent = v; lock.unlock() }
    public func setPresentationParityOK(_ v: Bool) { lock.lock(); presentationParityOK = v; lock.unlock() }
    public func recordOutcomes(_ n: Int) { lock.lock(); outcomesWatermark += max(0, n); lock.unlock() }

    /// UI must not show positive confirmed savings copy without a delivering confirmed lane (AC-01).
    public func uiMayShowConfirmedSavingsCopy(hasDeliveringConfirmedLane: Bool) -> Bool {
        lock.lock(); let isLive = _live; lock.unlock()
        return isLive && hasDeliveringConfirmedLane
    }

    /// Never sum measured + estimated. Confirmed totals require live runtime (default OFF → 0).
    public func confirmedTotal(receipt: PresentationReceipt) -> Int64 {
        lock.lock(); let isLive = _live; lock.unlock()
        guard isLive else { return 0 }
        // Estimated tokens never contribute; only measured when confirmed.
        return receipt.confirmed ? max(0, receipt.measuredTokens) : 0
    }

    public func storeOriginal(handle: String, bytes: Data) -> Bool {
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        if originalViews[h] != nil { return false }
        if let root = durableRoot {
            let url = root.appendingPathComponent(Self.safeName(h))
            if FileManager.default.fileExists(atPath: url.path) { return false }
            do { try bytes.write(to: url, options: .atomic) } catch { return false }
        }
        originalViews[h] = bytes
        return true
    }

    public func viewOriginal(handle: String) -> Data? {
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Canary advances only with outcomes watermark, never time alone (AC-05).
    public func advanceCanary(elapsedHours: Int) -> CanaryStep {
        lock.lock(); defer { lock.unlock() }
        _ = elapsedHours // time alone insufficient
        guard _live, !revoked else { return step }
        while step.rawValue < CanaryStep.complete.rawValue {
            let idx = step.rawValue
            guard idx < requiredOutcomes.count, outcomesWatermark >= requiredOutcomes[idx] else { break }
            if attribution < TokenSaverPromotionCanary.minAttribution ||
                reconciliation > TokenSaverPromotionCanary.maxReconciliation {
                return step // hold
            }
            step = CanaryStep(rawValue: idx + 1) ?? .complete
        }
        return step
    }

    public func revokeCanary() {
        lock.lock()
        revoked = true
        step = .one
        outcomesWatermark = 0
        lock.unlock()
    }

    public func currentStep() -> CanaryStep {
        lock.lock(); defer { lock.unlock() }; return step
    }

    /// Promotion requires complete coverage, parity, BOM, semantic consent (AC-03/07/08/09).
    public func mayPromote(bindingDigest: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _live, !bindingDigest.isEmpty, !revoked else { return false }
        guard coverageCellsComplete else { return false }
        guard presentationParityOK else { return false }
        guard modelBOMComplete else { return false }
        guard semanticConsent else { return false }
        guard attribution >= TokenSaverPromotionCanary.minAttribution else { return false }
        guard reconciliation <= TokenSaverPromotionCanary.maxReconciliation else { return false }
        return step == .complete || step == .twentyFive
    }
}
