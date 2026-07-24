import Foundation

/// Wave A shadow instrumentation without mutating provider requests (task-13).
public enum TokenSaverWaveAShadowMetrics {
    public static let taskID = "task-13"
    public static let defaultActive = false

    /// Complete pair under ONE BindingID with distinct trajectory IDs.
    public struct PairedControlEvidence: Sendable, Equatable {
        public let pairID: String
        public let bindingDigest: String
        public let treatmentTrajectoryID: String
        public let controlTrajectoryID: String
        public let treatmentRounds: Int
        public let controlRounds: Int
        public let treatmentUsageTokens: Int
        public let controlUsageTokens: Int
        public let sameTaskCorpus: Bool
        public let sameTaskSuccess: Bool
        public let retriesMatched: Bool

        public init(
            pairID: String,
            bindingDigest: String,
            treatmentTrajectoryID: String,
            controlTrajectoryID: String,
            treatmentRounds: Int,
            controlRounds: Int,
            treatmentUsageTokens: Int,
            controlUsageTokens: Int,
            sameTaskCorpus: Bool,
            sameTaskSuccess: Bool,
            retriesMatched: Bool
        ) {
            self.pairID = pairID
            self.bindingDigest = bindingDigest
            self.treatmentTrajectoryID = treatmentTrajectoryID
            self.controlTrajectoryID = controlTrajectoryID
            self.treatmentRounds = treatmentRounds
            self.controlRounds = controlRounds
            self.treatmentUsageTokens = treatmentUsageTokens
            self.controlUsageTokens = controlUsageTokens
            self.sameTaskCorpus = sameTaskCorpus
            self.sameTaskSuccess = sameTaskSuccess
            self.retriesMatched = retriesMatched
        }

        public var isComplete: Bool {
            guard !pairID.isEmpty, isCanonicalDigest(bindingDigest) else { return false }
            guard treatmentTrajectoryID != controlTrajectoryID,
                  !treatmentTrajectoryID.isEmpty, !controlTrajectoryID.isEmpty else { return false }
            guard treatmentRounds >= 0, controlRounds >= 0 else { return false }
            guard treatmentUsageTokens >= 0, controlUsageTokens >= 0 else { return false }
            return sameTaskCorpus && sameTaskSuccess && retriesMatched
        }

        public var claimedRoundsAvoided: Int {
            max(0, controlRounds - treatmentRounds)
        }
    }

    public struct Record: Sendable, Equatable {
        public let bindingDigest: String
        public let cacheVolatileTokens: Int
        public let queueCohortSize: Int
        public let providerRoundsAvoided: Int
        public let pair: PairedControlEvidence?

        public init?(
            bindingDigest: String,
            cacheVolatileTokens: Int,
            queueCohortSize: Int,
            pair: PairedControlEvidence?
        ) {
            guard isCanonicalDigest(bindingDigest) else { return nil }
            if let pair {
                guard pair.isComplete, pair.bindingDigest == bindingDigest else { return nil }
            }
            self.bindingDigest = bindingDigest
            self.cacheVolatileTokens = max(0, cacheVolatileTokens)
            self.queueCohortSize = max(0, queueCohortSize)
            self.pair = pair
            if let pair, pair.isComplete {
                self.providerRoundsAvoided = pair.claimedRoundsAvoided
            } else {
                self.providerRoundsAvoided = 0
            }
        }
    }

    public final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [Record] = []
        private var nextRecordIndex = 0
        private let maxRecords: Int
        private var _droppedRecords: Int = 0
        public var droppedRecords: Int { lock.lock(); defer { lock.unlock() }; return _droppedRecords }
        public init(maxRecords: Int = 4_096) {
            self.maxRecords = max(1, maxRecords)
        }
        public func append(_ r: Record) {
            lock.lock()
            if records.count < maxRecords {
                records.append(r)
            } else {
                records[nextRecordIndex] = r
                nextRecordIndex = (nextRecordIndex + 1) % maxRecords
                if _droppedRecords < .max { _droppedRecords += 1 }
            }
            lock.unlock()
        }
        public func snapshot() -> [Record] {
            lock.lock()
            defer { lock.unlock() }
            guard records.count == maxRecords, nextRecordIndex > 0 else { return records }
            return Array(records[nextRecordIndex...]) + Array(records[..<nextRecordIndex])
        }
        public var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }
    }

    public static let sharedLedger = Ledger()

    public static func isCanonicalDigest(_ s: String) -> Bool {
        s.count == 64 && s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }

    public static func observeWithoutMutation(_ providerVisible: Data) -> Data { providerVisible }

    @discardableResult
    public static func emit(
        bindingDigest: String,
        cacheVolatileTokens: Int,
        queueCohortSize: Int,
        pair: PairedControlEvidence?,
        ledger: Ledger = sharedLedger
    ) -> Record? {
        guard let r = Record(
            bindingDigest: bindingDigest,
            cacheVolatileTokens: cacheVolatileTokens,
            queueCohortSize: queueCohortSize,
            pair: pair
        ) else { return nil }
        ledger.append(r)
        return r
    }
}
