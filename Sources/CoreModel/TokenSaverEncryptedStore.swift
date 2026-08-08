import Foundation
import CryptoKit
import Security

public protocol TokenSaverProjectKeyProviding: AnyObject {
    func load(reference: String) throws -> Data?
    /// Atomically inserts a new key or returns the existing winner.
    func storeIfAbsent(_ key: Data, reference: String) throws -> Data
    func delete(reference: String) throws
}

public final class TokenSaverKeychainProjectKeyProvider: TokenSaverProjectKeyProviding, @unchecked Sendable {
    private static let service = "io.remotecode.token-saver.project-dek"

    public init() {}

    public func load(reference: String) throws -> Data? {
        var query = baseQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeyError.status(status)
        }
        return data
    }

    public func storeIfAbsent(_ key: Data, reference: String) throws -> Data {
        var add = baseQuery(reference: reference)
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return key }
        if status == errSecDuplicateItem, let existing = try load(reference: reference) {
            return existing
        }
        throw KeyError.status(status)
    }

    public func delete(reference: String) throws {
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyError.status(status)
        }
    }

    private func baseQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: reference,
        ]
    }

    public enum KeyError: Error {
        case status(OSStatus)
    }
}

final class TokenSaverInMemoryProjectKeyProvider: TokenSaverProjectKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    func load(reference: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return keys[reference]
    }

    func storeIfAbsent(_ key: Data, reference: String) -> Data {
        lock.lock(); defer { lock.unlock() }
        if let existing = keys[reference] { return existing }
        keys[reference] = key
        return key
    }

    func delete(reference: String) {
        lock.lock(); keys.removeValue(forKey: reference); lock.unlock()
    }
}

public enum TokenSaverOriginalSaveResult: Sendable, Equatable {
    case created
    case alreadyIdentical
    case conflict
}

public protocol TokenSaverLossyOriginalStoring: AnyObject {
    func save(handle: String, data: Data) -> TokenSaverOriginalSaveResult
    func load(handle: String) -> Data?
    func delete(handle: String)
}

/// Shared adapter for every lossy lane. It keeps recoverable originals inside the
/// project-scoped encrypted store rather than in lane-specific plaintext files.
public final class TokenSaverEncryptedOriginalStore: TokenSaverLossyOriginalStoring, @unchecked Sendable {
    private let store: TokenSaverEncryptedStore
    private let scope: TokenSaverEncryptedStore.Scope

    public init(store: TokenSaverEncryptedStore, scope: TokenSaverEncryptedStore.Scope) {
        self.store = store
        self.scope = scope
    }

    public func save(handle: String, data: Data) -> TokenSaverOriginalSaveResult {
        if let existing = try? store.readback(id: handle, expectedScope: scope) {
            return existing == data ? .alreadyIdentical : .conflict
        }
        do {
            _ = try store.store(id: handle, plaintext: data, scope: scope)
            return .created
        } catch TokenSaverEncryptedStore.StoreError.conflict {
            guard let existing = try? store.readback(id: handle, expectedScope: scope) else {
                return .conflict
            }
            return existing == data ? .alreadyIdentical : .conflict
        } catch {
            return .conflict
        }
    }

    public func load(handle: String) -> Data? {
        try? store.readback(id: handle, expectedScope: scope)
    }

    public func delete(handle: String) {
        try? store.delete(id: handle, expectedScope: scope)
    }
}

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

        public var isComplete: Bool {
            sessionGeneration > 0
                && [workspaceID, projectID, threadID, provider].allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        }

        public var digest: String {
            var payload = Data()
            for field in [
                String(uid),
                workspaceID,
                projectID,
                threadID,
                provider,
                String(sessionGeneration),
            ] {
                let bytes = Data(field.utf8)
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
                payload.append(bytes)
            }
            return TokenSaverEncryptedStore.hexDigest(SHA256.hash(data: payload))
        }
    }

    /// PERF: nibble table instead of per-byte `String(format:)` so scope,
    /// record-path, and key-reference digests avoid 32 formatter calls while
    /// keeping the same CryptoKit lowercase hex contract for durable paths.
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
        /// Opaque Keychain account; never contains key bytes.
        var keyReference: String?
    }

    public struct Envelope: Sendable, Equatable {
        public let ciphertext: Data
        public let scope: Scope
        public let formatVersion: Int
    }

    private let lock = NSLock()
    // PERF: store/readback/delete/migration/meta write each allocated a fresh
    // JSONDecoder/JSONEncoder. Mutations already hold `lock`, so one pair is
    // safe and avoids per-record codec construction on the Token Saver path.
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let rootURL: URL
    private let metaURL: URL
    /// N-1 migration source only. New stores never persist a plaintext DEK file.
    private let dekURL: URL
    private let keyProvider: TokenSaverProjectKeyProviding
    private let keyReference: String
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

    public init(
        projectRoot: URL,
        keyProvider: TokenSaverProjectKeyProviding = TokenSaverKeychainProjectKeyProvider()
    ) throws {
        let root = projectRoot.appendingPathComponent("token-saver-store", isDirectory: true)
        self.rootURL = root
        self.metaURL = root.appendingPathComponent("meta.json")
        self.dekURL = root.appendingPathComponent("dek.bin")
        self.keyProvider = keyProvider
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
                shredActive: false,
                keyReference: nil
            )
        }

        let reference = meta.keyReference ?? Self.defaultKeyReference(for: root)
        self.keyReference = reference
        if meta.keyReference == nil {
            meta.keyReference = reference
            // Init is not yet complete (key still pending); one-shot encode is
            // fine for this single open-path write.
            try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
        }

        if meta.shredActive || meta.deleteEpoch > 0 {
            // After shred/delete: no DEK; store is terminal for lossy writes.
            self.key = nil
            try keyProvider.delete(reference: reference)
            try? FileManager.default.removeItem(at: dekURL)
        } else {
            let raw: Data
            if let stored = try keyProvider.load(reference: reference) {
                raw = stored
            } else if FileManager.default.fileExists(atPath: dekURL.path) {
                // One-way N-1 migration from the unencapsulated branch prototype.
                let legacy = try Data(contentsOf: dekURL)
                raw = try keyProvider.storeIfAbsent(legacy, reference: reference)
                try FileManager.default.removeItem(at: dekURL)
            } else {
                let generated = SymmetricKey(size: .bits256)
                let candidate = generated.withUnsafeBytes { Data($0) }
                raw = try keyProvider.storeIfAbsent(candidate, reference: reference)
            }
            guard raw.count == 32 else { throw StoreError.corruptKey }
            self.key = SymmetricKey(data: raw)
        }
    }

    public func setRetentionDays(_ days: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        meta.retentionDays = max(0, days)
        try writeMetaUnlocked(meta)
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
        try writeMetaUnlocked(meta)
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
            let record = try decoder.decode(DiskRecord.self, from: data)
            if record.formatVersion == Self.previousSchemaVersion {
                pending.append(id)
            }
        }
        meta.pendingMigrationIDs = pending
        try writeMetaUnlocked(meta)

        for id in pending {
            let url = rootURL.appendingPathComponent(id + ".tsrec")
            let data = try Data(contentsOf: url)
            let record = try decoder.decode(DiskRecord.self, from: data)
            let box = try AES.GCM.SealedBox(combined: record.ciphertext)
            let plain = try AES.GCM.open(box, using: key)
            let resealed = try AES.GCM.seal(plain, using: key)
            let upgraded = DiskRecord(
                formatVersion: Self.schemaVersion,
                scope: record.scope,
                ciphertext: resealed.combined!
            )
            try encoder.encode(upgraded).write(to: url, options: .atomic)
            meta.pendingMigrationIDs.removeAll { $0 == id }
            try writeMetaUnlocked(meta)
        }
        meta.migrationComplete = true
        meta.pendingMigrationIDs = []
        try writeMetaUnlocked(meta)
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
        guard scope.isComplete else { throw StoreError.denied }
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let combined = sealed.combined!
        let record = DiskRecord(formatVersion: Self.schemaVersion, scope: scope, ciphertext: combined)
        let data = try encoder.encode(record)
        do {
            try data.write(to: fileURL(for: id), options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            throw StoreError.conflict
        }
        return Envelope(ciphertext: combined, scope: scope, formatVersion: Self.schemaVersion)
    }

    public func readback(id: String, expectedScope: Scope) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard expectedScope.isComplete else { throw StoreError.denied }
        guard let key else { throw StoreError.shredded }
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.missing }
        let data = try Data(contentsOf: url)
        let record = try decoder.decode(DiskRecord.self, from: data)
        guard record.scope == expectedScope else { throw StoreError.denied }
        guard Self.readerSupports(formatVersion: record.formatVersion) else { throw StoreError.unsupportedFormat }
        let box = try AES.GCM.SealedBox(combined: record.ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    public func retrieve(id: String, scope: Scope, expired: Bool, revoked: Bool) throws -> Data {
        if expired || revoked { throw StoreError.denied }
        return try readback(id: id, expectedScope: scope)
    }

    public func delete(id: String, expectedScope: Scope) throws {
        lock.lock()
        defer { lock.unlock() }
        guard expectedScope.isComplete else { throw StoreError.denied }
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let record = try decoder.decode(DiskRecord.self, from: data)
        guard record.scope == expectedScope else { throw StoreError.denied }
        try FileManager.default.removeItem(at: url)
    }

    /// Crypto-shred: persist irreversible tombstone FIRST, then destroy DEK + records.
    /// Ordering is intentional: crash mid-shred must reopen as shredded (deleteEpoch/shredActive),
    /// never regenerate a live DEK under stale migrationComplete=true.
    public func markDeleted() throws {
        lock.lock()
        defer { lock.unlock() }
        if meta.deleteEpoch < .max {
            meta.deleteEpoch += 1
        }
        meta.shredActive = true
        meta.migrationComplete = false
        // Durable tombstone before any shred of DEK/records.
        try writeMetaUnlocked(meta)
        key = nil
        try keyProvider.delete(reference: keyReference)
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
            if meta.lateOutcomesRejected < .max {
                meta.lateOutcomesRejected += 1
            }
            try? writeMetaUnlocked(meta)
            return false
        }
        return true
    }

    public func seedLegacyRecord(id: String, plaintext: Data, scope: Scope) throws {
        lock.lock()
        defer { lock.unlock() }
        guard scope.isComplete else { throw StoreError.denied }
        guard let key else { throw StoreError.shredded }
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let record = DiskRecord(
            formatVersion: Self.previousSchemaVersion,
            scope: scope,
            ciphertext: sealed.combined!
        )
        try encoder.encode(record).write(to: fileURL(for: id), options: .atomic)
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
        let safe = Self.hexDigest(SHA256.hash(data: Data(id.utf8)))
        return rootURL.appendingPathComponent(safe + ".tsrec")
    }

    private func writeMetaUnlocked(_ meta: Meta) throws {
        let data = try encoder.encode(meta)
        try data.write(to: metaURL, options: .atomic)
    }

    private static func defaultKeyReference(for root: URL) -> String {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
        return hexDigest(SHA256.hash(data: Data(canonical.utf8)))
    }

    public enum StoreError: Error {
        case lossyDenied, missing, denied, unsupportedFormat, conflict
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
