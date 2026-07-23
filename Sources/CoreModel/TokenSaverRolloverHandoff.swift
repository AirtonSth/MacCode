import Foundation

/// Wave C rollover / handoff / lossy / verbosity / visual (task-19). Default OFF.
public enum TokenSaverRolloverHandoff {
    public static let taskID = "task-19"
    public static let defaultEnabled = false
}

/// Host-owned rollover/handoff runtime. Identity is bound at construction (same-user).
/// Durable store recovers forks/fencing across relaunch.
public final class TokenSaverRolloverHandoffRuntime: @unchecked Sendable {
    public static let taskID = "task-19"

    public enum ForkKind: String, Sendable, Codable { case manual, rollover }

    public struct ForkOperationID: Sendable, Equatable, Hashable, Codable {
        public let id: String
        public let parentHead: String
        public let kind: ForkKind
        public init(id: String = UUID().uuidString, parentHead: String, kind: ForkKind) {
            self.id = id
            self.parentHead = parentHead
            self.kind = kind
        }
    }

    public enum ParentState: String, Sendable, Codable {
        case parentActive
        case childPrepared
        case childActivated
        case cancelled
        case fenced
    }

    public struct Branch: Sendable, Equatable, Codable {
        public let forkID: ForkOperationID
        public let runAsUser: String
        public let childHead: String
    }

    public protocol DurabilityStore: AnyObject {
        func loadSnapshot() -> Snapshot?
        func saveSnapshot(_ snapshot: Snapshot) -> Bool
    }

    /// Owns durable originals for lossy admission (store-before-loss).
    public protocol LossyOriginalStore: AnyObject {
        func storeOriginal(handle: String, data: Data) -> Bool
        func loadOriginal(handle: String) -> Data?
    }

    public struct Snapshot: Sendable, Equatable, Codable {
        public var parentState: ParentState
        public var branches: [String: Branch]
        public var boundUserID: String
    }

    public struct LossyAdmission: Sendable, Equatable {
        public let handle: String
        public let marker: String
    }

    public final class MemoryDurabilityStore: DurabilityStore, @unchecked Sendable {
        private let lock = NSLock()
        private var snap: Snapshot?
        /// Test hook: force save failures.
        public var failSaves = false
        public init() {}
        public func loadSnapshot() -> Snapshot? {
            lock.lock(); defer { lock.unlock() }; return snap
        }
        public func saveSnapshot(_ snapshot: Snapshot) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if failSaves { return false }
            snap = snapshot
            return true
        }
    }

    public final class MemoryLossyOriginalStore: LossyOriginalStore, @unchecked Sendable {
        private let lock = NSLock()
        private var byHandle: [String: Data] = [:]
        public var failStores = false
        public init() {}
        public func storeOriginal(handle: String, data: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if failStores { return false }
            if let existing = byHandle[handle], existing != data { return false }
            byHandle[handle] = data
            return true
        }
        public func loadOriginal(handle: String) -> Data? {
            lock.lock(); defer { lock.unlock() }; return byHandle[handle]
        }
    }

    public final class FileDurabilityStore: DurabilityStore, LossyOriginalStore, @unchecked Sendable {
        private let lock = NSLock()
        private let url: URL
        private let omitDir: URL
        public init(directory: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.url = directory.appendingPathComponent("rollover-snapshot.json")
            self.omitDir = directory.appendingPathComponent("lossy-originals")
            try FileManager.default.createDirectory(at: omitDir, withIntermediateDirectories: true)
        }
        public func loadSnapshot() -> Snapshot? {
            lock.lock(); defer { lock.unlock() }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }
        public func saveSnapshot(_ snapshot: Snapshot) -> Bool {
            lock.lock(); defer { lock.unlock() }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                return true
            } catch { return false }
        }
        private func omitURL(_ handle: String) -> URL {
            let safe = Data(handle.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            return omitDir.appendingPathComponent(safe)
        }
        public func storeOriginal(handle: String, data: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let path = omitURL(handle)
            if FileManager.default.fileExists(atPath: path.path) {
                if let existing = try? Data(contentsOf: path), existing == data { return true }
                return false
            }
            do {
                try data.write(to: path, options: [.withoutOverwriting])
                return true
            } catch { return false }
        }
        public func loadOriginal(handle: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return try? Data(contentsOf: omitURL(handle))
        }
    }

    private let lock = NSLock()
    private var _live = TokenSaverRolloverHandoff.defaultEnabled
    private var parentState: ParentState = .parentActive
    private var branches: [String: Branch] = [:]
    private var lossyValidatorPresent = false
    private var handoffConsent = false
    private var handoffDestinationBinding = ""
    /// Bound at init — only this user may own forks (same-user AC).
    public let boundUserID: String
    private let store: DurabilityStore
    private let lossyStore: LossyOriginalStore

    public init(
        boundUserID: String,
        store: DurabilityStore = MemoryDurabilityStore(),
        lossyStore: LossyOriginalStore? = nil
    ) {
        self.boundUserID = boundUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.store = store
        if let lossyStore {
            self.lossyStore = lossyStore
        } else if let combined = store as? LossyOriginalStore {
            self.lossyStore = combined
        } else {
            self.lossyStore = MemoryLossyOriginalStore()
        }
        if let snap = store.loadSnapshot(), snap.boundUserID == self.boundUserID {
            self.parentState = snap.parentState
            self.branches = snap.branches
        }
    }

    public var live: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _live }
        set { lock.lock(); _live = newValue; lock.unlock() }
    }

    public func setLossyValidatorPresent(_ v: Bool) {
        lock.lock(); lossyValidatorPresent = v; lock.unlock()
    }

    public func setHandoff(consent: Bool, destinationBinding: String) {
        lock.lock()
        handoffConsent = consent
        handoffDestinationBinding = destinationBinding.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
    }

    /// Fork for the bound user only. Caller-supplied alternate identity is rejected.
    /// Two manuals on same parent head → distinct IDs. Replay reuses same ForkOperationID.
    public func fork(
        op: ForkOperationID,
        requestingUserID: String,
        replay: Bool = false
    ) -> Branch? {
        lock.lock(); defer { lock.unlock() }
        guard _live else { return nil }
        let req = requestingUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !boundUserID.isEmpty, req == boundUserID else { return nil }
        if replay {
            if let existing = branches[op.id] { return existing }
        } else if let existing = branches[op.id] {
            return existing
        }
        let priorState = parentState
        if op.kind == .rollover {
            if parentState == .fenced { return nil }
            parentState = .childPrepared
        }
        let child = Branch(
            forkID: op,
            runAsUser: boundUserID,
            childHead: "child-\(op.id.prefix(8))"
        )
        branches[op.id] = child
        if op.kind == .rollover {
            parentState = .fenced
        }
        // Durability is required before publishing fork/fence (crash recovery).
        if !persistUnlocked() {
            branches.removeValue(forKey: op.id)
            parentState = priorState
            return nil
        }
        return child
    }

    public func parentAllowsNewTurns() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _live else { return true } // fail-open when OFF
        return parentState != .fenced
    }

    public func parentStateValue() -> ParentState {
        lock.lock(); defer { lock.unlock() }
        return parentState
    }

    public func branch(forkID: String) -> Branch? {
        lock.lock(); defer { lock.unlock() }
        return branches[forkID]
    }

    /// Lossy admission **owns** store-before-loss: writes original, verifies exact readback,
    /// then returns a recoverable `[[rc:handle]]` marker. Caller-asserted booleans are not accepted.
    public func admitLossy(
        original: Data,
        recoveryHandle: String,
        corpusOK: Bool,
        scopeOK: Bool = true
    ) -> LossyAdmission? {
        lock.lock(); defer { lock.unlock() }
        guard _live, lossyValidatorPresent, corpusOK, scopeOK else { return nil }
        let handle = recoveryHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty, !original.isEmpty else { return nil }
        guard lossyStore.storeOriginal(handle: handle, data: original) else { return nil }
        guard let readback = lossyStore.loadOriginal(handle: handle), readback == original else {
            return nil
        }
        let marker = "[[rc:\(handle)]]"
        return LossyAdmission(handle: handle, marker: marker)
    }

    public func retrieveLossyOriginal(handle: String) -> Data? {
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        return lossyStore.loadOriginal(handle: h)
    }

    public func rejectCriticalSuppression(bound: Int, candidate: Int) -> Bool {
        candidate > bound // true means reject
    }

    public func admitHandoff(requestingUserID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let req = requestingUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        return _live
            && handoffConsent
            && !handoffDestinationBinding.isEmpty
            && req == boundUserID
            && !boundUserID.isEmpty
    }

    /// Verbosity never changes reasoning effort or already-generated text.
    public func applyVerbosity(toGenerated text: String, level: String) -> String {
        _ = level
        return text
    }

    public func visualForcesOriginal(isOCR: Bool, isUI: Bool, isDebug: Bool) -> Bool {
        isOCR || isUI || isDebug
    }

    private func persistUnlocked() -> Bool {
        let snap = Snapshot(parentState: parentState, branches: branches, boundUserID: boundUserID)
        return store.saveSnapshot(snap)
    }
}
