import Foundation
import CryptoKit

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

    public enum OmissionSaveResult: Sendable, Equatable {
        /// First durable write of this handle.
        case created
        /// Handle already present with identical bytes (shared / re-save); must not be rolled back.
        case alreadyIdentical
        /// Handle present with different bytes, or write failed.
        case conflict
    }

    public protocol DurabilityStore: AnyObject {
        func loadProjection(key: String) -> Projection?
        func saveProjection(key: String, projection: Projection, commitment: String) -> Bool
        func deleteProjection(key: String)
        func loadOmission(handle: String) -> Data?
        func saveOmission(handle: String, data: Data) -> OmissionSaveResult
        func deleteOmission(handle: String)
    }

    /// Optional delete for transactional rollback.
    public protocol ProjectionDeleter: AnyObject {
        func deleteProjection(key: String)
        func deleteOmission(handle: String)
    }

    public final class MemoryDurabilityStore: DurabilityStore, ProjectionDeleter, @unchecked Sendable {
        private let lock = NSLock()
        private var projections: [String: (projection: Projection, commitment: String)] = [:]
        private var omissions: [String: Data] = [:]
        public init() {}
        public func loadProjection(key: String) -> Projection? {
            lock.lock(); defer { lock.unlock() }; return projections[key]?.projection
        }
        public func saveProjection(key: String, projection: Projection, commitment: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let existing = projections[key] {
                return existing.projection == projection && existing.commitment == commitment
            }
            projections[key] = (projection, commitment)
            return true
        }
        public func deleteProjection(key: String) {
            lock.lock(); projections.removeValue(forKey: key); lock.unlock()
        }
        public func loadOmission(handle: String) -> Data? {
            lock.lock(); defer { lock.unlock() }; return omissions[handle]
        }
        public func saveOmission(handle: String, data: Data) -> OmissionSaveResult {
            lock.lock(); defer { lock.unlock() }
            if let existing = omissions[handle] {
                return existing == data ? .alreadyIdentical : .conflict
            }
            omissions[handle] = data
            return .created
        }
        public func deleteOmission(handle: String) {
            lock.lock(); omissions.removeValue(forKey: handle); lock.unlock()
        }
    }

    public final class FileDurabilityStore: DurabilityStore, ProjectionDeleter, @unchecked Sendable {
        private struct DiskProjection: Codable {
            let projection: Projection
            let commitment: String
        }

        private let lock = NSLock()
        private let root: URL
        private let originalStore: TokenSaverLossyOriginalStoring?
        public init(directory: URL, originalStore: TokenSaverLossyOriginalStoring? = nil) throws {
            self.root = directory
            self.originalStore = originalStore
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("proj"), withIntermediateDirectories: true)
        }
        private func projURL(_ key: String) -> URL {
            let safe = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            return root.appendingPathComponent("proj").appendingPathComponent(safe)
        }
        public func loadProjection(key: String) -> Projection? {
            lock.lock(); defer { lock.unlock() }
            return loadProjectionUnlocked(url: projURL(key))
        }
        public func saveProjection(key: String, projection: Projection, commitment: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let url = projURL(key)
            if let existing = loadProjectionRecordUnlocked(url: url) {
                // Idempotent only when same value; never overwrite a different projection.
                return existing.projection == projection && existing.commitment == commitment
            }
            // Exclusive create: withoutOverwriting fails if another writer raced in.
            do {
                let record = DiskProjection(projection: projection, commitment: commitment)
                try JSONEncoder().encode(record).write(to: url, options: [.withoutOverwriting])
                return true
            } catch {
                if let existing = loadProjectionRecordUnlocked(url: url) {
                    return existing.projection == projection && existing.commitment == commitment
                }
                return false
            }
        }
        public func deleteProjection(key: String) {
            lock.lock(); defer { lock.unlock() }
            try? FileManager.default.removeItem(at: projURL(key))
        }
        private func loadProjectionUnlocked(url: URL) -> Projection? {
            loadProjectionRecordUnlocked(url: url)?.projection
        }
        private func loadProjectionRecordUnlocked(url: URL) -> DiskProjection? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            if let record = try? JSONDecoder().decode(DiskProjection.self, from: data) {
                return record
            }
            // N-1 files contained only the projection raw value. They remain readable,
            // but cannot be treated as a same-byte replay without a commitment.
            guard let s = String(data: data, encoding: .utf8) else { return nil }
            guard let projection = Projection(rawValue: s) else { return nil }
            return DiskProjection(projection: projection, commitment: "")
        }
        public func loadOmission(handle: String) -> Data? {
            originalStore?.load(handle: storageHandle(handle))
        }
        public func saveOmission(handle: String, data: Data) -> OmissionSaveResult {
            switch originalStore?.save(handle: storageHandle(handle), data: data) {
            case .created: return .created
            case .alreadyIdentical: return .alreadyIdentical
            case .conflict, .none: return .conflict
            }
        }
        public func deleteOmission(handle: String) {
            originalStore?.delete(handle: storageHandle(handle))
        }
        private func storageHandle(_ handle: String) -> String {
            "queue-compaction|\(handle)"
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
        // Fail closed without initialized authority (no empty-head / zero-gen wildcards).
        guard !_providerHead.isEmpty, _generation != 0 else { return false }
        guard op.providerHead == _providerHead, op.generation == _generation else { return false }
        if store.loadProjection(key: op.storageKey) != nil { return false }
        admittedOps.insert(op.storageKey)
        return true
    }

    /// Commit exactly one projection under a single lock (check + durable write).
    /// Compact: **store-before-loss** — durable originals first, then exclusive projection commit.
    /// Markers in compact text must biject with supplied omissions (no extras, no missing).
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
        guard !_providerHead.isEmpty, _generation != 0 else { return false }
        guard op.providerHead == _providerHead, op.generation == _generation else { return false }

        var prepared: [(String, Data)] = []
        if projection == .compact {
            guard !omissions.isEmpty else { return false }
            guard let text = compactProjectionText, !text.isEmpty else { return false }
            guard Self.validateCompactMarkers(text: text, omissions: omissions) else { return false }
            var seenHandles = Set<String>()
            for o in omissions {
                let h = o.handle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !h.isEmpty, seenHandles.insert(h).inserted else { return false }
                prepared.append((h, o.original))
            }
        }

        // Store-before-loss: originals before compact projection becomes authoritative.
        // Only newly-created handles are rolled back on failure (never shared pre-existing).
        var newlyCreated: [String] = []
        if projection == .compact {
            for (h, data) in prepared {
                switch store.saveOmission(handle: h, data: data) {
                case .created:
                    newlyCreated.append(h)
                case .alreadyIdentical:
                    break
                case .conflict:
                    for w in newlyCreated { store.deleteOmission(handle: w) }
                    return false
                }
            }
        }

        // Exclusive projection publish (raw XOR compact).
        let commitment = Self.projectionCommitment(
            projection: projection,
            compactProjectionText: compactProjectionText,
            omissions: omissions
        )
        if !store.saveProjection(key: op.storageKey, projection: projection, commitment: commitment) {
            // If another writer published, its projection may reference an identical
            // original. Preserve store-before-loss over eager orphan cleanup.
            if store.loadProjection(key: op.storageKey) == nil {
                for w in newlyCreated { store.deleteOmission(handle: w) }
            }
            return false
        }

        admittedOps.remove(op.storageKey)
        return true
    }

    // PERF: compile once — was recompiled on every compact commit validation.
    private static let compactMarkerRegex = try! NSRegularExpression(
        pattern: #"\[\[rc:([^\]]+)\]\]"#
    )

    /// Every well-formed `[[rc:handle]]` maps 1:1 to an omission; no extras, missing, empty, or malformed `[[rc:` stubs.
    public static func validateCompactMarkers(text: String, omissions: [Omission]) -> Bool {
        // Reject any `[[rc:` that is not a complete well-formed marker with non-empty handle.
        // PERF: count opens without allocating a full `components(separatedBy:)` array.
        let openCount = countOccurrences(
            of: TokenSaverQueueCoalesce.handlePrefix,
            in: text
        )
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var textHandles: [String] = []
        compactMarkerRegex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let r = match.range(at: 1)
            if r.location != NSNotFound {
                let h = ns.substring(with: r)
                // Empty or whitespace-only handles are malformed.
                if !h.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textHandles.append(h)
                }
            }
        }
        // Every `[[rc:` open must produce exactly one valid non-empty handle match.
        guard openCount == textHandles.count else { return false }
        let omissionHandles = omissions.map { $0.handle.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard omissionHandles.allSatisfy({ !$0.isEmpty }) else { return false }
        guard Set(omissionHandles).count == omissionHandles.count else { return false }
        guard Set(textHandles).count == textHandles.count else { return false }
        guard textHandles.count == omissionHandles.count else { return false }
        guard Set(textHandles) == Set(omissionHandles) else { return false }
        for o in omissions {
            guard text.contains(o.marker) else { return false }
        }
        return true
    }

    /// Count non-overlapping occurrences of `needle` without splitting the haystack.
    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: search) {
            count += 1
            search = range.upperBound..<haystack.endIndex
        }
        return count
    }

    /// PERF: nibble table instead of per-byte `String(format:)` so projection
    /// commitments avoid 32 formatter calls while keeping the same CryptoKit
    /// lowercase hex contract for durable compaction identity.
    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    private static func projectionCommitment(
        projection: Projection,
        compactProjectionText: String?,
        omissions: [Omission]
    ) -> String {
        var bytes = Data(projection.rawValue.utf8)
        func appendField(_ field: Data) {
            var length = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(field)
        }
        appendField(Data((compactProjectionText ?? "").utf8))
        for omission in omissions.sorted(by: { $0.handle < $1.handle }) {
            appendField(Data(omission.handle.utf8))
            appendField(Data(SHA256.hash(data: omission.original)))
        }
        return hexDigest(SHA256.hash(data: bytes))
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
