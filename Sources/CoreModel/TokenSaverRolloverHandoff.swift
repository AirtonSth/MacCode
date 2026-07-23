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

    public struct Snapshot: Sendable, Equatable, Codable {
        public var parentState: ParentState
        public var branches: [String: Branch]
        public var boundUserID: String
    }

    public final class MemoryDurabilityStore: DurabilityStore, @unchecked Sendable {
        private let lock = NSLock()
        private var snap: Snapshot?
        public init() {}
        public func loadSnapshot() -> Snapshot? {
            lock.lock(); defer { lock.unlock() }; return snap
        }
        public func saveSnapshot(_ snapshot: Snapshot) -> Bool {
            lock.lock(); snap = snapshot; lock.unlock(); return true
        }
    }

    public final class FileDurabilityStore: DurabilityStore, @unchecked Sendable {
        private let lock = NSLock()
        private let url: URL
        public init(directory: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.url = directory.appendingPathComponent("rollover-snapshot.json")
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

    public init(boundUserID: String, store: DurabilityStore = MemoryDurabilityStore()) {
        self.boundUserID = boundUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.store = store
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
        _ = persistUnlocked()
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

    /// Lossy lanes require validator + corpus + durable original store-before-loss (AC-05).
    public func admitLossy(
        corpusOK: Bool,
        originalStored: Bool,
        verifiedReadback: Bool,
        recoveryHandle: String,
        scopeOK: Bool = true
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let handle = recoveryHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        return _live
            && lossyValidatorPresent
            && corpusOK
            && originalStored
            && verifiedReadback
            && !handle.isEmpty
            && scopeOK
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
