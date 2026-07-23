import Foundation
import CryptoKit

/// Fase 2 encrypted project-scoped store (task-09).
/// On-disk encrypted records; DEK + meta (migration/deleteEpoch) persist across process restarts.
public final class TokenSaverEncryptedStore: @unchecked Sendable {
    public static let schemaVersion = 2
    public static let previousSchemaVersion = 1
    public static let taskID = "task-09"

    public struct Scope: Sendable, Equatable, Codable, Hashable {
        public let uid: uid_t
        public let workspaceID: String
        public let projectID: String
        public let threadID: String
        public let provider: String
        public let sessionGeneration: UInt64

        public init(
            uid: uid_t,
            workspaceID: String,
            projectID: String,
            threadID: String,
            provider: String,
            sessionGeneration: UInt64
        ) {
            self.uid = uid
            self.workspaceID = workspaceID
            self.projectID = projectID
            self.threadID = threadID
            self.provider = provider
            self.sessionGeneration = sessionGeneration
        }

        public var digest: String {
            let payload = "\(uid)|\(workspaceID)|\(projectID)|\(threadID)|\(provider)|\(sessionGeneration)"
            return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct DiskRecord: Codable {
        let formatVersion: Int
        let scope: Scope
        let ciphertext: Data
    }

    private struct Meta: Codable {
        var migrationComplete: Bool
        var deleteEpoch: UInt64
        var retentionDays: Int
        var lateOutcomesRejected: Int
        /// Shadow migration journal: list of record ids still pending upgrade N-1→N.
        var pendingMigrationIDs: [String]
        var shredActive: Bool
    }

    public struct Envelope: Sendable, Equatable {
        public let ciphertext: Data
        public let scope: Scope
        public let formatVersion: Int
    }

    private let lock = NSLock()
    private let rootURL: URL
    private let metaURL: URL
    private let dekURL: URL
    private var key: SymmetricKey?
    private var meta: Meta
    public private(set) var lateOutcomesRejected: Int {
        get { lock.lock(); defer { lock.unlock() }; return meta.lateOutcomesRejected }
        set { lock.lock(); meta.lateOutcomesRejected = newValue; lock.unlock() }
    }
    public var migrationComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return meta.migrationComplete
    }
    public var deleteEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return meta.deleteEpoch
    }

    public init(projectRoot: URL) throws {
        let root = projectRoot.appendingPathComponent("token-saver-store", isDirectory: true)
        self.rootURL = root
        self.metaURL = root.appendingPathComponent("meta.json")
        self.dekURL = root.appendingPathComponent("dek.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: metaURL.path) {
            // Fail closed: unreadable/corrupt meta must not regenerate a live store.
            let data = try Data(contentsOf: metaURL)
            do {
                self.meta = try JSONDecoder().decode(Meta.self, from: data)
            } catch {
                throw StoreError.corruptMeta
            }
        } else {
            self.meta = Meta(
                migrationComplete: false,
                deleteEpoch: 0,
                retentionDays: 30,
                lateOutcomesRejected: 0,
                pendingMigrationIDs: [],
                shredActive: false
            )
            try Self.writeMeta(self.meta, to: metaURL)
        }

        if meta.shredActive || meta.deleteEpoch > 0 {
            // After shred/delete: no DEK; store is terminal for lossy writes.
            self.key = nil
            try? FileManager.default.removeItem(at: dekURL)
        } else if FileManager.default.fileExists(atPath: dekURL.path) {
            let raw = try Data(contentsOf: dekURL)
            guard raw.count == 32 else { throw StoreError.corruptKey }
            self.key = SymmetricKey(data: raw)
        } else {
            let generated = SymmetricKey(size: .bits256)
            let raw = generated.withUnsafeBytes { Data($0) }
            try raw.write(to: dekURL, options: .atomic)
            self.key = generated
        }
    }

    public func setRetentionDays(_ days: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        meta.retentionDays = max(0, days)
        try Self.writeMeta(meta, to: metaURL)
    }

    public var lossyAdmissionAllowed: Bool {
        lock.lock(); defer { lock.unlock() }
        return meta.retentionDays > 0
            && meta.deleteEpoch == 0
            && meta.migrationComplete
            && !meta.shredActive
            && key != nil
    }

    public func markMigrationComplete() throws {
        lock.lock()
        defer { lock.unlock() }
        meta.migrationComplete = true
        meta.pendingMigrationIDs = []
        try Self.writeMeta(meta, to: metaURL)
    }

    /// Shadow migration: inventory N-1 records, rewrite to N, journal progress, then seal complete.
    public func runShadowMigration() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let key else { throw StoreError.shredded }
        let files = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        var pending: [String] = []
        for f in files where f.pathExtension == "tsrec" {
            let id = f.deletingPathExtension().lastPathComponent
            let data = try Data(contentsOf: f)
            let record = try JSONDecoder().decode(DiskRecord.self, from: data)
            if record.formatVersion == Self.previousSchemaVersion {
                pending.append(id)
            }
        }
        meta.pendingMigrationIDs = pending
        try Self.writeMeta(meta, to: metaURL)

        for id in pending {
            let url = fileURL(for: id)
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(DiskRecord.self, from: data)
            let box = try AES.GCM.SealedBox(combined: record.ciphertext)
            let plain = try AES.GCM.open(box, using: key)
            let resealed = try AES.GCM.seal(plain, using: key)
            let upgraded = DiskRecord(
                formatVersion: Self.schemaVersion,
                scope: record.scope,
                ciphertext: resealed.combined!
            )
            try JSONEncoder().encode(upgraded).write(to: url, options: .atomic)
            meta.pendingMigrationIDs.removeAll { $0 == id }
            try Self.writeMeta(meta, to: metaURL)
        }
        meta.migrationComplete = true
        meta.pendingMigrationIDs = []
        try Self.writeMeta(meta, to: metaURL)
    }

    public func store(id: String, plaintext: Data, scope: Scope) throws -> Envelope {
        lock.lock()
        defer { lock.unlock() }
        guard let key,
              meta.retentionDays > 0,
              meta.deleteEpoch == 0,
              meta.migrationComplete,
              !meta.shredActive else {
            throw StoreError.lossyDenied
        }
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let combined = sealed.combined!
        let record = DiskRecord(formatVersion: Self.schemaVersion, scope: scope, ciphertext: combined)
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL(for: id), options: .atomic)
        return Envelope(ciphertext: combined, scope: scope, formatVersion: Self.schemaVersion)
    }

    public func readback(id: String, expectedScope: Scope) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let key else { throw StoreError.shredded }
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.missing }
        let data = try Data(contentsOf: url)
        let record = try JSONDecoder().decode(DiskRecord.self, from: data)
        guard record.scope == expectedScope else { throw StoreError.denied }
        guard Self.readerSupports(formatVersion: record.formatVersion) else { throw StoreError.unsupportedFormat }
        let box = try AES.GCM.SealedBox(combined: record.ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    public func retrieve(id: String, scope: Scope, expired: Bool, revoked: Bool) throws -> Data {
        if expired || revoked { throw StoreError.denied }
        return try readback(id: id, expectedScope: scope)
    }

    /// Crypto-shred: persist irreversible tombstone FIRST, then destroy DEK + records.
    /// Ordering is intentional: crash mid-shred must reopen as shredded (deleteEpoch/shredActive),
    /// never regenerate a live DEK under stale migrationComplete=true.
    public func markDeleted() throws {
        lock.lock()
        defer { lock.unlock() }
        meta.deleteEpoch += 1
        meta.shredActive = true
        meta.migrationComplete = false
        // Durable tombstone before any shred of DEK/records.
        try Self.writeMeta(meta, to: metaURL)
        key = nil
        if let files = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            for f in files {
                if f.lastPathComponent == "meta.json" { continue }
                try? FileManager.default.removeItem(at: f)
            }
        }
        try? FileManager.default.removeItem(at: dekURL)
    }

    public func acceptLateOutcome() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if meta.deleteEpoch > 0 || meta.shredActive {
            meta.lateOutcomesRejected += 1
            try? Self.writeMeta(meta, to: metaURL)
            return false
        }
        return true
    }

    public func seedLegacyRecord(id: String, plaintext: Data, scope: Scope) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let key else { throw StoreError.shredded }
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let record = DiskRecord(
            formatVersion: Self.previousSchemaVersion,
            scope: scope,
            ciphertext: sealed.combined!
        )
        try JSONEncoder().encode(record).write(to: fileURL(for: id), options: .atomic)
    }

    public func plaintextExistsOnDisk(scanning payload: Data) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            return false
        }
        for f in files {
            if f.lastPathComponent == "dek.bin" || f.lastPathComponent == "meta.json" { continue }
            if let data = try? Data(contentsOf: f), data.range(of: payload) != nil {
                return true
            }
        }
        return false
    }

    public var projectRootForTests: URL { rootURL.deletingLastPathComponent() }

    private func fileURL(for id: String) -> URL {
        rootURL.appendingPathComponent(id + ".tsrec")
    }

    private static func writeMeta(_ meta: Meta, to url: URL) throws {
        let data = try JSONEncoder().encode(meta)
        try data.write(to: url, options: .atomic)
    }

    public enum StoreError: Error {
        case lossyDenied, missing, denied, unsupportedFormat
        case corruptKey, keyGenerationFailed, shredded, corruptMeta
    }

    public enum Storeless {
        public static func collapse(_ raw: Data) -> Data {
            Data(raw.base64EncodedString().utf8)
        }
        public static func expand(_ collapsed: Data) -> Data? {
            guard let s = String(data: collapsed, encoding: .utf8) else { return nil }
            return Data(base64Encoded: s)
        }
        public static func roundTrip(_ raw: Data) -> Bool {
            expand(collapse(raw)) == raw
        }
    }

    public static func readerSupports(formatVersion: Int) -> Bool {
        formatVersion == schemaVersion || formatVersion == previousSchemaVersion
    }
}
