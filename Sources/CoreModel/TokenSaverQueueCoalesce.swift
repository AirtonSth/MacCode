import Foundation

/// Wave C queued_intent_coalescing + in_place_context_compaction + same_turn_structured_checkpoint (task-18).
/// Default OFF / opt-in. Canonical messages stay byte-exact.
public enum TokenSaverQueueCoalesce {
    public static let taskID = "task-18"
    public static let defaultEnabled = false
    public static let handlePrefix = "[[rc:"
    public static let handleSuffix = "]]"
}

/// Host-owned queue coalescing + compaction + checkpoint runtime (task-18). Default OFF.
public final class TokenSaverQueueCoalesceRuntime: @unchecked Sendable {
    public static let taskID = "task-18"

    public enum IntentKind: String, Sendable, Equatable {
        case additive
        case replace
        case contradict
        case attachmentOrder
        case modeChange
    }

    public struct QueuedIntent: Sendable, Equatable {
        public let id: String
        public let userID: String
        public let threadID: String
        public let provider: String
        public let model: String
        public let generation: UInt64
        public let kind: IntentKind
        public let canonicalText: Data
        public let dispatchStarted: Bool

        public init(
            id: String,
            userID: String,
            threadID: String,
            provider: String,
            model: String,
            generation: UInt64,
            kind: IntentKind,
            canonicalText: Data,
            dispatchStarted: Bool = false
        ) {
            self.id = id
            self.userID = userID
            self.threadID = threadID
            self.provider = provider
            self.model = model
            self.generation = generation
            self.kind = kind
            self.canonicalText = canonicalText
            self.dispatchStarted = dispatchStarted
        }
    }

    public enum CoalesceDecision: String, Sendable, Equatable {
        case coalesce
        case drainIndividual
        case notLive
        case dispatchStarted
        case scopeMismatch
        case nonAdditive
    }

    public struct CompactionOperationID: Sendable, Equatable, Hashable, Codable {
        public let providerHead: String
        public let generation: UInt64
        public let boundary: String
        public let rawHistoryDigest: String
        public init(providerHead: String, generation: UInt64, boundary: String, rawHistoryDigest: String) {
            self.providerHead = providerHead
            self.generation = generation
            self.boundary = boundary
            self.rawHistoryDigest = rawHistoryDigest
        }

        public var storageKey: String {
            "\(providerHead)|\(generation)|\(boundary)|\(rawHistoryDigest)"
        }
    }

    public enum Projection: String, Sendable, Equatable, Codable {
        case raw
        case compact
    }

    public struct Omission: Sendable, Equatable {
        public let handle: String
        public let original: Data
        public init(handle: String, original: Data) {
            self.handle = handle
            self.original = original
        }

        public var marker: String {
            "\(TokenSaverQueueCoalesce.handlePrefix)\(handle)\(TokenSaverQueueCoalesce.handleSuffix)"
        }
    }

    public struct HostReceipt: Sendable, Equatable {
        public let id: String
        public let kind: String
        public let value: String
        public init(id: String, kind: String, value: String) {
            self.id = id
            self.kind = kind
            self.value = value
        }
    }

    public struct Checkpoint: Sendable, Equatable {
        public let receipts: [HostReceipt]
        public let narrative: String?
        public let emitsProviderTurn: Bool
        public let pendingApproval: Bool
        public let pendingMutation: Bool
    }

    public protocol DurabilityStore: AnyObject {
        func loadProjection(key: String) -> Projection?
        func saveProjection(key: String, projection: Projection) -> Bool
        func deleteProjection(key: String)
        func loadOmission(handle: String) -> Data?
        func saveOmission(handle: String, data: Data) -> Bool
        func deleteOmission(handle: String)
    }

    /// Optional delete for transactional rollback.
    public protocol ProjectionDeleter: AnyObject {
        func deleteProjection(key: String)
        func deleteOmission(handle: String)
    }

    public final class MemoryDurabilityStore: DurabilityStore, ProjectionDeleter, @unchecked Sendable {
        private let lock = NSLock()
        private var projections: [String: Projection] = [:]
        private var omissions: [String: Data] = [:]
        public init() {}
        public func loadProjection(key: String) -> Projection? {
            lock.lock(); defer { lock.unlock() }; return projections[key]
        }
        public func saveProjection(key: String, projection: Projection) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let existing = projections[key], existing != projection { return false }
            projections[key] = projection
            return true
        }
        public func deleteProjection(key: String) {
            lock.lock(); projections.removeValue(forKey: key); lock.unlock()
        }
        public func loadOmission(handle: String) -> Data? {
            lock.lock(); defer { lock.unlock() }; return omissions[handle]
        }
        public func saveOmission(handle: String, data: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if omissions[handle] != nil { return false }
            omissions[handle] = data
            return true
        }
        public func deleteOmission(handle: String) {
            lock.lock(); omissions.removeValue(forKey: handle); lock.unlock()
        }
    }

    public final class FileDurabilityStore: DurabilityStore, ProjectionDeleter, @unchecked Sendable {
        private let lock = NSLock()
        private let root: URL
        public init(directory: URL) throws {
            self.root = directory
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("proj"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("omit"), withIntermediateDirectories: true)
        }
        private func projURL(_ key: String) -> URL {
            let safe = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            return root.appendingPathComponent("proj").appendingPathComponent(safe)
        }
        private func omitURL(_ handle: String) -> URL {
            let safe = Data(handle.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            return root.appendingPathComponent("omit").appendingPathComponent(safe)
        }
        public func loadProjection(key: String) -> Projection? {
            lock.lock(); defer { lock.unlock() }
            guard let data = try? Data(contentsOf: projURL(key)),
                  let s = String(data: data, encoding: .utf8) else { return nil }
            return Projection(rawValue: s)
        }
        public func saveProjection(key: String, projection: Projection) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let url = projURL(key)
            if let existing = loadProjectionUnlocked(url: url), existing != projection { return false }
            do {
                try Data(projection.rawValue.utf8).write(to: url, options: .atomic)
                return true
            } catch { return false }
        }
        public func deleteProjection(key: String) {
            lock.lock(); defer { lock.unlock() }
            try? FileManager.default.removeItem(at: projURL(key))
        }
        private func loadProjectionUnlocked(url: URL) -> Projection? {
            guard let data = try? Data(contentsOf: url),
                  let s = String(data: data, encoding: .utf8) else { return nil }
            return Projection(rawValue: s)
        }
        public func loadOmission(handle: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return try? Data(contentsOf: omitURL(handle))
        }
        public func saveOmission(handle: String, data: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let url = omitURL(handle)
            if FileManager.default.fileExists(atPath: url.path) { return false }
            do {
                try data.write(to: url, options: .atomic)
                return true
            } catch { return false }
        }
        public func deleteOmission(handle: String) {
            lock.lock(); defer { lock.unlock() }
            try? FileManager.default.removeItem(at: omitURL(handle))
        }
    }

    private let lock = NSLock()
    private var _live: Bool = TokenSaverQueueCoalesce.defaultEnabled
    private var optIn: Bool = false
    private var admittedOps: Set<String> = []
    private let store: DurabilityStore
    /// Authoritative provider head for CAS — only via `setProviderAuthority`.
    private var _providerHead: String = ""
    private var _generation: UInt64 = 0

    public init(store: DurabilityStore = MemoryDurabilityStore()) {
        self.store = store
    }

    public var live: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _live }
        set { lock.lock(); _live = newValue; lock.unlock() }
    }

    public func setOptIn(_ value: Bool) {
        lock.lock(); optIn = value; lock.unlock()
    }

    public func setProviderAuthority(head: String, generation: UInt64) {
        lock.lock()
        _providerHead = head
        _generation = generation
        lock.unlock()
    }

    // MARK: - Coalescing

    public func decideCoalesce(_ a: QueuedIntent, _ b: QueuedIntent) -> CoalesceDecision {
        lock.lock(); let isLive = _live; let consented = optIn; lock.unlock()
        guard isLive, consented else { return .notLive }
        if a.dispatchStarted || b.dispatchStarted { return .dispatchStarted }
        guard a.userID == b.userID,
              a.threadID == b.threadID,
              a.provider == b.provider,
              a.model == b.model,
              a.generation == b.generation else {
            return .scopeMismatch
        }
        if a.kind != .additive || b.kind != .additive {
            return .nonAdditive
        }
        return .coalesce
    }

    /// Pairwise over the whole batch. Any non-coalesce pair drains the batch.
    public func coalescePreview(_ intents: [QueuedIntent]) -> (decision: CoalesceDecision, retainedCanonical: [Data]) {
        let retained = intents.map(\.canonicalText)
        guard intents.count >= 2 else {
            return (.drainIndividual, retained)
        }
        for i in 0..<intents.count {
            for j in (i + 1)..<intents.count {
                let d = decideCoalesce(intents[i], intents[j])
                if d != .coalesce {
                    return (d, retained)
                }
            }
        }
        return (.coalesce, retained)
    }

    // MARK: - Compaction CAS

    public func admitCompaction(
        pendingTool: Bool,
        pendingApproval: Bool,
        op: CompactionOperationID
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _live else { return false }
        if pendingTool || pendingApproval { return false }
        // CAS against authoritative heads (same lock as setProviderAuthority)
        if !_providerHead.isEmpty, op.providerHead != _providerHead { return false }
        if _generation != 0, op.generation != _generation { return false }
        if store.loadProjection(key: op.storageKey) != nil { return false }
        admittedOps.insert(op.storageKey)
        return true
    }

    /// Commit exactly one projection under a single lock (check + durable write).
    /// Compact requires [[rc:handle]] markers. Projection is written first; omissions next;
    /// any omission failure rolls back the projection so retry is possible.
    @discardableResult
    public func commit(
        op: CompactionOperationID,
        projection: Projection,
        compactProjectionText: String? = nil,
        omissions: [Omission] = []
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _live else { return false }
        guard admittedOps.contains(op.storageKey) else { return false }
        // CAS heads under same lock as durable writes
        if !_providerHead.isEmpty, op.providerHead != _providerHead { return false }
        if _generation != 0, op.generation != _generation { return false }

        var prepared: [(String, Data, String)] = [] // handle, data, marker check already done
        if projection == .compact {
            guard !omissions.isEmpty else { return false }
            guard let text = compactProjectionText, !text.isEmpty else { return false }
            for o in omissions {
                let h = o.handle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !h.isEmpty else { return false }
                guard text.contains(o.marker) else { return false }
                prepared.append((h, o.original, o.marker))
            }
        }

        // Projection first (authoritative choice raw XOR compact)
        guard store.saveProjection(key: op.storageKey, projection: projection) else { return false }

        if projection == .compact {
            var written: [String] = []
            for (h, data, _) in prepared {
                if !store.saveOmission(handle: h, data: data) {
                    store.deleteProjection(key: op.storageKey)
                    for w in written { store.deleteOmission(handle: w) }
                    return false
                }
                written.append(h)
            }
        }

        admittedOps.remove(op.storageKey)
        return true
    }

    public func projection(for op: CompactionOperationID) -> Projection? {
        store.loadProjection(key: op.storageKey)
    }

    public func retrieveOmission(handle: String) -> Data? {
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.loadOmission(handle: h)
    }

    // MARK: - Checkpoint

    public func buildCheckpoint(
        receipts: [HostReceipt],
        narrativeFromMLX: String?,
        pendingMutation: Bool,
        pendingApproval: Bool,
        live: Bool? = nil
    ) -> Checkpoint? {
        lock.lock(); let isLive = live ?? _live; lock.unlock()
        guard isLive else { return nil }
        if pendingMutation || pendingApproval { return nil }
        guard !receipts.isEmpty else { return nil }
        // Only host receipt fields; no free invent.
        let cleaned = receipts.filter {
            !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !cleaned.isEmpty else { return nil }
        let narrative = narrativeFromMLX.map { String($0.prefix(500)) }
        return Checkpoint(
            receipts: cleaned,
            narrative: narrative,
            emitsProviderTurn: false,
            pendingApproval: false,
            pendingMutation: false
        )
    }
}
