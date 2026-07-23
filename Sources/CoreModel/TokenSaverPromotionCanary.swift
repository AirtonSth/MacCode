import Foundation

/// Fase 5 presentation UX + canary + BindingID promotion (task-21). Default OFF.
public enum TokenSaverPromotionCanary {
    public static let taskID = "task-21"
    public static let defaultEnabled = false
    public static let canarySteps: [Double] = [0.01, 0.05, 0.25]
    public static let minAttribution: Double = 0.99
    public static let maxReconciliation: Double = 0.02
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

    public struct PromotionGateSeal: Sendable, Equatable {
        fileprivate let token: UInt64
        fileprivate let bindingDigest: String
        fileprivate let registryEpoch: UInt64
        fileprivate init(token: UInt64, bindingDigest: String, registryEpoch: UInt64) {
            self.token = token
            self.bindingDigest = bindingDigest
            self.registryEpoch = registryEpoch
        }
    }

    public enum PromotionGate {
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
            return PromotionGateSeal(
                token: UInt64(bitPattern: Int64(h.finalize())),
                bindingDigest: b,
                registryEpoch: registryEpoch
            )
        }
    }

    public let boundUserID: String
    public let bindingDigest: String
    private let lock = NSLock()
    private var _live = TokenSaverPromotionCanary.defaultEnabled
    private var step: CanaryStep = .one
    private var outcomesWatermark: Int = 0
    private var requiredOutcomes: [Int] = [10, 50, 200]
    private var stepEnteredAtHours: [Int: Int] = [:]
    private var revoked = false
    private var attribution: Double?
    private var reconciliation: Double?
    private var promotionAuthorized = false
    private let originalStore: TokenSaverLossyOriginalStoring?
    /// Injectable clock (hours since epoch). Default is wall clock. Tests may replace via @testable.
    internal var nowHours: () -> Int = {
        Int(Date().timeIntervalSince1970 / 3600.0)
    }

    public init(
        boundUserID: String,
        bindingDigest: String,
        originalStore: TokenSaverLossyOriginalStoring? = nil
    ) {
        self.boundUserID = boundUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bindingDigest = bindingDigest.trimmingCharacters(in: .whitespacesAndNewlines)
        self.originalStore = originalStore
        // stepEnteredAtHours is stamped on first advanceCanary using the (possibly injected) clock.
    }

    public var live: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _live }
        set {
            lock.lock()
            _live = newValue
            if !newValue { promotionAuthorized = false }
            lock.unlock()
        }
    }

    public func setAttribution(_ v: Double) {
        lock.lock()
        attribution = v
        if !v.isFinite || v < TokenSaverPromotionCanary.minAttribution {
            promotionAuthorized = false
        }
        lock.unlock()
    }
    public func setReconciliation(_ v: Double) {
        lock.lock()
        reconciliation = v
        if !v.isFinite || v > TokenSaverPromotionCanary.maxReconciliation {
            promotionAuthorized = false
        }
        lock.unlock()
    }
    public func recordOutcomes(_ n: Int) {
        lock.lock()
        let (sum, overflow) = outcomesWatermark.addingReportingOverflow(max(0, n))
        outcomesWatermark = overflow ? .max : sum
        lock.unlock()
    }

    public func uiMayShowConfirmedSavingsCopy(hasDeliveringConfirmedLane: Bool) -> Bool {
        lock.lock()
        let allowed = _live && promotionAuthorized
        lock.unlock()
        return allowed && hasDeliveringConfirmedLane
    }

    public func confirmedTotal(
        receipt: TokenSaverRecoveryProjections.MeasuredSavingsReceipt?,
        creditBindingDigest: String
    ) -> Int64 {
        lock.lock()
        let allowed = _live && promotionAuthorized
        lock.unlock()
        guard allowed else { return 0 }
        guard let receipt else { return 0 }
        guard receipt.bindingDigest == creditBindingDigest,
              creditBindingDigest == bindingDigest else { return 0 }
        return max(0, receipt.tokens)
    }

    /// Store-before-loss: durable directory required; key scoped by user+binding+handle.
    public func storeOriginal(handle: String, bytes: Data, requestingUserID: String) -> Bool {
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = requestingUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !bytes.isEmpty, u == boundUserID, !boundUserID.isEmpty else { return false }
        guard let originalStore else { return false }
        lock.lock(); defer { lock.unlock() }
        guard originalStore.save(handle: storageHandle(h), data: bytes) != .conflict,
              originalStore.load(handle: storageHandle(h)) == bytes else {
            return false
        }
        return true
    }

    public func viewOriginal(handle: String, requestingUserID: String) -> Data? {
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = requestingUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u == boundUserID else { return nil }
        return originalStore?.load(handle: storageHandle(h))
    }

    private func storageHandle(_ handle: String) -> String {
        "promotion|\(boundUserID)|\(bindingDigest)|\(handle)"
    }

    public func advanceCanary() -> CanaryStep {
        lock.lock(); defer { lock.unlock() }
        guard _live, !revoked else { return step }
        let now = nowHours()
        if stepEnteredAtHours[step.rawValue] == nil {
            stepEnteredAtHours[step.rawValue] = now
        }
        while step.rawValue < CanaryStep.complete.rawValue {
            let idx = step.rawValue
            guard idx < requiredOutcomes.count, outcomesWatermark >= requiredOutcomes[idx] else { break }
            let entered = stepEnteredAtHours[idx] ?? now
            let dwell = TokenSaverPromotionCanary.minDwellHours[idx]
            guard now - entered >= dwell else { break }
            guard let attribution, let reconciliation else { return step }
            if !attribution.isFinite || !reconciliation.isFinite ||
                attribution < TokenSaverPromotionCanary.minAttribution ||
                reconciliation > TokenSaverPromotionCanary.maxReconciliation {
                return step
            }
            let next = CanaryStep(rawValue: idx + 1) ?? .complete
            step = next
            stepEnteredAtHours[next.rawValue] = now
        }
        return step
    }

    public func revokeCanary() {
        lock.lock()
        revoked = true
        promotionAuthorized = false
        step = .one
        outcomesWatermark = 0
        stepEnteredAtHours = [0: nowHours()]
        lock.unlock()
    }

    public func currentStep() -> CanaryStep {
        lock.lock(); defer { lock.unlock() }; return step
    }

    public func mayPromote(gate: PromotionGateSeal, requestingUserID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return mayPromoteLocked(gate: gate, requestingUserID: requestingUserID)
    }

    @discardableResult
    public func activatePromotion(gate: PromotionGateSeal, requestingUserID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard mayPromoteLocked(gate: gate, requestingUserID: requestingUserID) else {
            return false
        }
        promotionAuthorized = true
        return true
    }

    private func mayPromoteLocked(gate: PromotionGateSeal, requestingUserID: String) -> Bool {
        let u = requestingUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard _live, !revoked, u == boundUserID, !bindingDigest.isEmpty else { return false }
        // Seal must be bound to this runtime's binding digest.
        guard gate.bindingDigest == bindingDigest, gate.registryEpoch > 0 else { return false }
        _ = gate.token
        guard let attribution, attribution.isFinite,
              attribution >= TokenSaverPromotionCanary.minAttribution else { return false }
        guard let reconciliation, reconciliation.isFinite,
              reconciliation <= TokenSaverPromotionCanary.maxReconciliation else { return false }
        return step == .complete || step == .twentyFive
    }
}
