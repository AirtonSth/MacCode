import CryptoKit
import Darwin
import Foundation

/// Redirect-safe attachment transport layered over the durable v2 plaintext
/// store. Only ciphertext and an upload-scoped capability travel in the
/// background URLSession request; bearer, owner identity and encryption key
/// are accepted exclusively by the authenticated prepare call.
public enum AttachmentUploadV3Policy {
    public static let protocolVersion = 3
    public static let contentEncoding = "protected_chunks_v1"
    public static let plaintextChunkBytes = AttachmentUploadV2Policy.rawChunkBytes
    public static let nonceBytes = 12
    public static let authenticationTagBytes = 16
    public static let cipherOverheadBytes = nonceBytes + authenticationTagBytes
    public static let keyBytes = 32
    public static let capabilityBytes = 32
    /// Fifty chunks of fixed metadata encode below 40 KiB. Keep ample schema
    /// evolution headroom without allowing an authenticated peer to make the
    /// host buffer a multi-megabyte prepare envelope.
    public static let maximumPrepareBytes = 128 * 1_024
    public static let maximumSealedChunkBytes =
        plaintextChunkBytes + cipherOverheadBytes
    /// A normal root has at most the global 16 receiving jobs plus a small
    /// number of crash leftovers. Bound cold reconciliation work explicitly.
    public static let maximumProtectionEntriesPerSweep = 128
}

public struct AttachmentUploadV3PrepareRequest: Codable, Equatable, Sendable {
    public struct Chunk: Codable, Equatable, Sendable {
        public let index: Int
        public let plaintextBytes: Int
        public let plaintextSHA256: String
        public let sealedBytes: Int
        public let sealedSHA256: String
        public let nonceBase64URL: String
        public let capabilitySHA256: String

        enum CodingKeys: String, CodingKey {
            case index
            case plaintextBytes = "plaintext_bytes"
            case plaintextSHA256 = "plaintext_sha256"
            case sealedBytes = "sealed_bytes"
            case sealedSHA256 = "sealed_sha256"
            case nonceBase64URL = "nonce_base64url"
            case capabilitySHA256 = "capability_sha256"
        }

        public init(
            index: Int,
            plaintextBytes: Int,
            plaintextSHA256: String,
            sealedBytes: Int,
            sealedSHA256: String,
            nonceBase64URL: String,
            capabilitySHA256: String
        ) {
            self.index = index
            self.plaintextBytes = plaintextBytes
            self.plaintextSHA256 = plaintextSHA256
            self.sealedBytes = sealedBytes
            self.sealedSHA256 = sealedSHA256
            self.nonceBase64URL = nonceBase64URL
            self.capabilitySHA256 = capabilitySHA256
        }
    }

    public let protocolVersion: Int
    public let contentEncoding: String
    public let serverId: String
    public let ownerFingerprint: String
    public let workspaceId: String
    public let filename: String
    public let mimeType: String?
    public let totalPlaintextBytes: Int
    public let plaintextChunkBytes: Int
    public let chunkCount: Int
    public let fileSHA256: String
    public let encryptionKeyBase64URL: String
    public let chunks: [Chunk]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case contentEncoding = "content_encoding"
        case serverId = "server_id"
        case ownerFingerprint = "owner_fingerprint"
        case workspaceId = "workspace_id"
        case filename
        case mimeType = "mime_type"
        case totalPlaintextBytes = "total_plaintext_bytes"
        case plaintextChunkBytes = "plaintext_chunk_bytes"
        case chunkCount = "chunk_count"
        case fileSHA256 = "file_sha256"
        case encryptionKeyBase64URL = "encryption_key_base64url"
        case chunks
    }

    public init(
        protocolVersion: Int = AttachmentUploadV3Policy.protocolVersion,
        contentEncoding: String = AttachmentUploadV3Policy.contentEncoding,
        serverId: String,
        ownerFingerprint: String,
        workspaceId: String,
        filename: String,
        mimeType: String?,
        totalPlaintextBytes: Int,
        plaintextChunkBytes: Int = AttachmentUploadV3Policy.plaintextChunkBytes,
        chunkCount: Int,
        fileSHA256: String,
        encryptionKeyBase64URL: String,
        chunks: [Chunk]
    ) {
        self.protocolVersion = protocolVersion
        self.contentEncoding = contentEncoding
        self.serverId = serverId
        self.ownerFingerprint = ownerFingerprint
        self.workspaceId = workspaceId
        self.filename = filename
        self.mimeType = mimeType
        self.totalPlaintextBytes = totalPlaintextBytes
        self.plaintextChunkBytes = plaintextChunkBytes
        self.chunkCount = chunkCount
        self.fileSHA256 = fileSHA256
        self.encryptionKeyBase64URL = encryptionKeyBase64URL
        self.chunks = chunks
    }
}

public enum AttachmentUploadV3Error: Error, Equatable, CustomStringConvertible {
    case invalidParams(String)
    case uploadUnknown
    case ownerInactive
    case capabilityRejected
    case metadataConflict
    case sealedChunkRejected(String)
    case storageFailure(String)

    public var description: String {
        switch self {
        case .invalidParams(let detail):
            return "Invalid protected attachment upload params: \(detail)"
        case .uploadUnknown:
            return "Unknown protected attachment upload"
        case .ownerInactive:
            return "Protected attachment upload owner is no longer active"
        case .capabilityRejected:
            return "Protected attachment upload capability rejected"
        case .metadataConflict:
            return "Protected attachment upload immutable metadata conflict"
        case .sealedChunkRejected(let detail):
            return "Protected attachment chunk rejected: \(detail)"
        case .storageFailure(let detail):
            return "Protected attachment upload storage failure: \(detail)"
        }
    }
}

public struct AttachmentUploadV3AuthorizedChunk: Sendable, Equatable {
    public let uploadId: String
    public let chunkIndex: Int
    public let ownerFingerprint: String
    public let expectedSealedBytes: Int
    public let expectedSealedSHA256: String
    fileprivate let manifest: AttachmentUploadV3Store.Manifest

    fileprivate init(
        uploadId: String,
        chunkIndex: Int,
        ownerFingerprint: String,
        expectedSealedBytes: Int,
        expectedSealedSHA256: String,
        manifest: AttachmentUploadV3Store.Manifest
    ) {
        self.uploadId = uploadId
        self.chunkIndex = chunkIndex
        self.ownerFingerprint = ownerFingerprint
        self.expectedSealedBytes = expectedSealedBytes
        self.expectedSealedSHA256 = expectedSealedSHA256
        self.manifest = manifest
    }
}

private enum AttachmentUploadV3Synchronization {
    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var locks: [String: NSRecursiveLock] = [:]

    static func withLock<T>(root: URL, _ body: () throws -> T) rethrows -> T {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.lock()
        let lock = locks[key] ?? {
            let created = NSRecursiveLock()
            locks[key] = created
            return created
        }()
        registryLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Durable v3 protection metadata and authenticated decryptor.
///
/// The plaintext store remains AttachmentUploadV2Store so its crash-safe
/// assembly, cancellation tombstones and idempotency rules stay authoritative.
/// No public HTTP v2 route is required by this layer.
public final class AttachmentUploadV3Store: @unchecked Sendable {
    fileprivate struct Manifest: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let uploadId: String
        let request: AttachmentUploadV3PrepareRequest
    }

    public let root: URL
    public let plaintextStore: AttachmentUploadV2Store
    private let fileManager: FileManager
    private var didReconcileAbandonedManifestTemps = false
    // PERF: protected manifest load/persist allocated JSONDecoder/JSONEncoder
    // per call. Public API serializes per-root via withLock, so one sorted-keys
    // pair is safe and avoids per-mutation codec construction.
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public init(
        root: URL,
        plaintextStore: AttachmentUploadV2Store,
        fileManager: FileManager = .default
    ) {
        self.root = root.standardizedFileURL
        self.plaintextStore = plaintextStore
        self.fileManager = fileManager
    }

    public convenience init(
        plaintextStore: AttachmentUploadV2Store,
        fileManager: FileManager = .default
    ) {
        self.init(
            root: plaintextStore.root.appendingPathComponent(
                "protected-v3",
                isDirectory: true
            ),
            plaintextStore: plaintextStore,
            fileManager: fileManager
        )
    }

    @discardableResult
    public func prepare(
        uploadId: String,
        authorizedOwnerFingerprint: String,
        request: AttachmentUploadV3PrepareRequest
    ) throws -> AttachmentUploadV2Status {
        let id = try Self.validatedUploadId(uploadId)
        try Self.validate(
            request,
            uploadId: id,
            authorizedOwnerFingerprint: authorizedOwnerFingerprint
        )
        let candidate = Manifest(
            schemaVersion: 1,
            uploadId: id,
            request: request
        )

        return try withLock {
            try prepareRootAndReconcileManifestTemps(force: true)
            if let existing = try loadManifest(uploadId: id),
               existing != candidate {
                throw AttachmentUploadV3Error.metadataConflict
            }
            let status = try plaintextStore.begin(
                ownerFingerprint: request.ownerFingerprint,
                uploadId: id,
                workspaceId: request.workspaceId,
                filename: request.filename,
                mimeType: request.mimeType,
                sizeBytes: request.totalPlaintextBytes,
                sha256: request.fileSHA256
            )
            // A committed v2 manifest is already authoritative. Re-persisting
            // the encryption key would only extend sensitive-data lifetime.
            if status.phase == .receiving {
                try persistManifest(candidate)
            } else {
                try removeManifest(uploadId: id)
            }
            try pruneOrphanedProtectionManifestsBounded(
                excluding: [id]
            )
            return status
        }
    }

    /// Validates the one-time chunk capability, immutable geometry and active
    /// trust owner before the HTTP server reads any body bytes.
    public func authorizeChunk(
        uploadId: String,
        chunkIndex: Int,
        capabilityBase64URL: String,
        sealedSHA256: String,
        sealedBytes: Int,
        idempotencyKey: String,
        ownerIsActive: (String) -> Bool
    ) throws -> AttachmentUploadV3AuthorizedChunk {
        let id = try Self.validatedUploadId(uploadId)
        return try withLock {
            try prepareRootAndReconcileManifestTemps(force: false)
            guard let manifest = try loadManifest(uploadId: id) else {
                throw AttachmentUploadV3Error.uploadUnknown
            }
            let request = manifest.request
            guard ownerIsActive(request.ownerFingerprint) else {
                throw AttachmentUploadV3Error.ownerInactive
            }
            guard chunkIndex >= 0, chunkIndex < request.chunks.count else {
                throw AttachmentUploadV3Error.invalidParams("chunk index")
            }
            let chunk = request.chunks[chunkIndex]
            guard chunk.index == chunkIndex,
                  sealedBytes == chunk.sealedBytes,
                  sealedSHA256 == chunk.sealedSHA256,
                  idempotencyKey == Self.idempotencyKey(
                    uploadId: id,
                    chunkIndex: chunkIndex,
                    sealedSHA256: chunk.sealedSHA256
                  ),
                  let capability = Self.strictBase64URLDecode(
                    capabilityBase64URL,
                    expectedBytes: AttachmentUploadV3Policy.capabilityBytes
                  ),
                  Self.constantTimeEqual(
                    Data(SHA256.hash(data: capability)),
                    Data(hexadecimal: chunk.capabilitySHA256)
                  ) else {
                throw AttachmentUploadV3Error.capabilityRejected
            }
            return AttachmentUploadV3AuthorizedChunk(
                uploadId: id,
                chunkIndex: chunkIndex,
                ownerFingerprint: request.ownerFingerprint,
                expectedSealedBytes: chunk.sealedBytes,
                expectedSealedSHA256: chunk.sealedSHA256,
                manifest: manifest
            )
        }
    }

    @discardableResult
    public func putProtectedChunk(
        authorization: AttachmentUploadV3AuthorizedChunk,
        sealedData: Data,
        ownerIsActive: (String) -> Bool
    ) throws -> AttachmentUploadV2Status {
        try withLock {
            try prepareRootAndReconcileManifestTemps(force: false)
            guard let current = try loadManifest(
                uploadId: authorization.uploadId
            ), current == authorization.manifest else {
                throw AttachmentUploadV3Error.uploadUnknown
            }
            guard ownerIsActive(authorization.ownerFingerprint) else {
                throw AttachmentUploadV3Error.ownerInactive
            }
            let request = current.request
            let chunk = request.chunks[authorization.chunkIndex]
            guard sealedData.count == chunk.sealedBytes,
                  Self.hexDigest(SHA256.hash(data: sealedData))
                    == chunk.sealedSHA256 else {
                throw AttachmentUploadV3Error.sealedChunkRejected(
                    "sealed size or digest"
                )
            }
            guard let expectedNonce = Self.strictBase64URLDecode(
                chunk.nonceBase64URL,
                expectedBytes: AttachmentUploadV3Policy.nonceBytes
            ),
            sealedData.prefix(AttachmentUploadV3Policy.nonceBytes)
                == expectedNonce else {
                throw AttachmentUploadV3Error.sealedChunkRejected("nonce")
            }
            let masterKey = try Self.decodedKey(request)
            let aad = try Self.additionalAuthenticatedData(
                request: request,
                uploadId: authorization.uploadId,
                chunk: chunk
            )
            let plaintext: Data
            do {
                let box = try AES.GCM.SealedBox(combined: sealedData)
                plaintext = try AES.GCM.open(
                    box,
                    using: Self.derivedChunkKey(
                        masterKey: masterKey,
                        serverId: request.serverId,
                        uploadId: authorization.uploadId,
                        chunkIndex: authorization.chunkIndex
                    ),
                    authenticating: aad
                )
            } catch {
                throw AttachmentUploadV3Error.sealedChunkRejected(
                    "authentication"
                )
            }
            guard plaintext.count == chunk.plaintextBytes,
                  plaintext.count
                    <= AttachmentUploadV3Policy.plaintextChunkBytes,
                  Self.hexDigest(SHA256.hash(data: plaintext))
                    == chunk.plaintextSHA256 else {
                throw AttachmentUploadV3Error.sealedChunkRejected(
                    "plaintext size or digest"
                )
            }
            let status = try plaintextStore.putChunk(
                ownerFingerprint: request.ownerFingerprint,
                uploadId: authorization.uploadId,
                chunkIndex: authorization.chunkIndex,
                data: plaintext,
                sha256: chunk.plaintextSHA256
            )
            if status.phase != .receiving {
                try removeManifest(uploadId: authorization.uploadId)
            }
            return status
        }
    }

    public func status(
        ownerFingerprint: String,
        uploadId: String,
        workspaceId: String
    ) throws -> AttachmentUploadV2Status {
        try withLock {
            try prepareRootAndReconcileManifestTemps(force: false)
        }
        let status: AttachmentUploadV2Status
        do {
            status = try plaintextStore.status(
                ownerFingerprint: ownerFingerprint,
                uploadId: uploadId,
                workspaceId: workspaceId
            )
        } catch let error as AttachmentUploadV2Error {
            if error == .uploadUnknown || error == .uploadCancelled {
                try withLock {
                    try removeManifest(
                        uploadId: try Self.validatedUploadId(uploadId)
                    )
                }
            }
            throw error
        }
        if status.phase != .receiving {
            try withLock {
                try removeManifest(
                    uploadId: try Self.validatedUploadId(uploadId)
                )
            }
        }
        return status
    }

    @discardableResult
    public func cancel(
        ownerFingerprint: String,
        uploadId: String,
        workspaceId: String
    ) throws -> AttachmentUploadV2Status {
        try withLock {
            try prepareRootAndReconcileManifestTemps(force: false)
            let status = try plaintextStore.cancel(
                ownerFingerprint: ownerFingerprint,
                uploadId: uploadId,
                workspaceId: workspaceId
            )
            // The v2 cancellation tombstone is durable before the key is
            // removed, so a crash can leak a reclaimable key but never revive
            // an upload id.
            try removeManifest(uploadId: uploadId)
            return status
        }
    }

    public static func decodePrepareRequest(
        _ data: Data
    ) throws -> AttachmentUploadV3PrepareRequest {
        guard !data.isEmpty,
              data.count <= AttachmentUploadV3Policy.maximumPrepareBytes else {
            throw AttachmentUploadV3Error.invalidParams("prepare body size")
        }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(
                AttachmentUploadV3PrepareRequest.self,
                from: data
            )
        } catch {
            throw AttachmentUploadV3Error.invalidParams("prepare JSON")
        }
    }

    public static func idempotencyKey(
        uploadId: String,
        chunkIndex: Int,
        sealedSHA256: String
    ) -> String {
        hexDigest(
            SHA256.hash(
                data: Data(
                    "rc2.upload.v3:\(uploadId):\(chunkIndex):\(sealedSHA256)"
                        .utf8
                )
            )
        )
    }

    public static func additionalAuthenticatedData(
        request: AttachmentUploadV3PrepareRequest,
        uploadId: String,
        chunk: AttachmentUploadV3PrepareRequest.Chunk
    ) throws -> Data {
        let object: [String: Any] = [
            "chunk_count": request.chunkCount,
            "chunk_index": chunk.index,
            "chunk_plaintext_sha256": chunk.plaintextSHA256,
            "content_encoding": AttachmentUploadV3Policy.contentEncoding,
            "file_sha256": request.fileSHA256,
            "filename": request.filename,
            "mime_type": request.mimeType ?? NSNull(),
            "owner_fingerprint": request.ownerFingerprint,
            "plaintext_bytes": chunk.plaintextBytes,
            "plaintext_chunk_bytes":
                AttachmentUploadV3Policy.plaintextChunkBytes,
            "protocol_version": AttachmentUploadV3Policy.protocolVersion,
            "server_id": request.serverId,
            "total_plaintext_bytes": request.totalPlaintextBytes,
            "upload_id": uploadId,
            "workspace_id": request.workspaceId,
        ]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw AttachmentUploadV3Error.invalidParams("AAD")
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    public static func derivedChunkKey(
        masterKey: Data,
        serverId: String,
        uploadId: String,
        chunkIndex: Int
    ) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            salt: Data(
                "rc2.protected-chunks.v1:\(serverId):\(uploadId)".utf8
            ),
            info: Data("chunk:\(chunkIndex)".utf8),
            outputByteCount: AttachmentUploadV3Policy.keyBytes
        )
    }

    // MARK: - Validation and durable manifest

    private static func validate(
        _ request: AttachmentUploadV3PrepareRequest,
        uploadId: String,
        authorizedOwnerFingerprint: String
    ) throws {
        guard request.protocolVersion == AttachmentUploadV3Policy.protocolVersion,
              request.contentEncoding == AttachmentUploadV3Policy.contentEncoding,
              !request.serverId.isEmpty,
              request.ownerFingerprint == authorizedOwnerFingerprint,
              isLowerHex(request.ownerFingerprint),
              UUID(uuidString: request.workspaceId) != nil,
              (1...AttachmentUploadV2Policy.maximumFileBytes)
                .contains(request.totalPlaintextBytes),
              request.plaintextChunkBytes
                == AttachmentUploadV3Policy.plaintextChunkBytes,
              request.chunkCount
                == AttachmentUploadV2Policy.chunkCount(
                    sizeBytes: request.totalPlaintextBytes
                ),
              request.chunkCount > 0,
              request.chunkCount <= AttachmentUploadV2Policy.maximumChunkCount,
              request.chunks.count == request.chunkCount,
              isLowerHex(request.fileSHA256),
              strictBase64URLDecode(
                  request.encryptionKeyBase64URL,
                  expectedBytes: AttachmentUploadV3Policy.keyBytes
              ) != nil else {
            throw AttachmentUploadV3Error.invalidParams(
                "protocol, owner or geometry"
            )
        }
        var nonces: Set<Data> = []
        for (index, chunk) in request.chunks.enumerated() {
            guard let expectedPlaintext =
                    AttachmentUploadV2Policy.expectedChunkByteCount(
                        index: index,
                        sizeBytes: request.totalPlaintextBytes
                    ),
                  chunk.index == index,
                  chunk.plaintextBytes == expectedPlaintext,
                  chunk.sealedBytes
                    == expectedPlaintext
                        + AttachmentUploadV3Policy.cipherOverheadBytes,
                  chunk.sealedBytes
                    <= AttachmentUploadV3Policy.maximumSealedChunkBytes,
                  isLowerHex(chunk.plaintextSHA256),
                  isLowerHex(chunk.sealedSHA256),
                  isLowerHex(chunk.capabilitySHA256),
                  let nonce = strictBase64URLDecode(
                      chunk.nonceBase64URL,
                      expectedBytes: AttachmentUploadV3Policy.nonceBytes
                  ),
                  nonces.insert(nonce).inserted else {
                throw AttachmentUploadV3Error.invalidParams(
                    "chunk metadata"
                )
            }
        }
    }

    private static func validatedUploadId(_ raw: String) throws -> String {
        guard let uuid = UUID(uuidString: raw) else {
            throw AttachmentUploadV3Error.invalidParams("upload id")
        }
        return uuid.uuidString.lowercased()
    }

    private static func decodedKey(
        _ request: AttachmentUploadV3PrepareRequest
    ) throws -> Data {
        guard let key = strictBase64URLDecode(
            request.encryptionKeyBase64URL,
            expectedBytes: AttachmentUploadV3Policy.keyBytes
        ) else {
            throw AttachmentUploadV3Error.invalidParams("key")
        }
        return key
    }

    private static func strictBase64URLDecode(
        _ value: String,
        expectedBytes: Int
    ) -> Data? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({
                  (65...90).contains($0)
                      || (97...122).contains($0)
                      || (48...57).contains($0)
                      || $0 == 45
                      || $0 == 95
              }) else {
            return nil
        }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64),
              data.count == expectedBytes,
              base64URL(data) == value else {
            return nil
        }
        return data
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isLowerHex(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    /// PERF: nibble table instead of per-byte `String(format:)` so chunk /
    /// sealed / plaintext digest finalize avoids 32 formatter calls while
    /// keeping the same CryptoKit lowercase hex contract.
    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexDigest<D: Sequence>(
        _ digest: D
    ) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data?) -> Bool {
        guard let rhs, lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try AttachmentUploadV3Synchronization.withLock(root: root, body)
    }

    private func prepareRoot() throws {
        let existed = fileManager.fileExists(atPath: root.path)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        if !existed {
            try synchronizeDirectory(root.deletingLastPathComponent())
        }
    }

    private func prepareRootAndReconcileManifestTemps(
        force: Bool
    ) throws {
        try prepareRoot()
        guard force || !didReconcileAbandonedManifestTemps else { return }
        try removeAbandonedManifestTempsBounded()
        didReconcileAbandonedManifestTemps = true
    }

    nonisolated static func isAbandonedManifestTempFilename(
        _ filename: String
    ) -> Bool {
        let components = filename.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 4,
              components[0].isEmpty,
              components[3] == "tmp" else {
            return false
        }
        let uploadID = String(components[1])
        let temporaryID = String(components[2])
        guard let uploadUUID = UUID(uuidString: uploadID),
              uploadID == uploadUUID.uuidString.lowercased(),
              let temporaryUUID = UUID(uuidString: temporaryID),
              temporaryID == temporaryUUID.uuidString else {
            return false
        }
        return true
    }

    /// Removes only exact atomic-manifest temp names left by a force/power kill.
    /// Every inspected entry and file size is bounded. O_NOFOLLOW plus unlink
    /// means reconciliation never reads a key or follows/removes a directory.
    private func removeAbandonedManifestTempsBounded() throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return
        }
        var visited = 0
        var removedAny = false
        while visited
                < AttachmentUploadV3Policy.maximumProtectionEntriesPerSweep,
              let url = enumerator.nextObject() as? URL {
            visited += 1
            guard Self.isAbandonedManifestTempFilename(
                url.lastPathComponent
            ) else {
                continue
            }
            let descriptor = open(
                url.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                if errno == ENOENT { continue }
                throw AttachmentUploadV3Error.storageFailure(
                    "protected temp manifest open"
                )
            }
            var metadata = stat()
            let valid = fstat(descriptor, &metadata) == 0
                && (metadata.st_mode & S_IFMT) == S_IFREG
                && metadata.st_size >= 0
                && metadata.st_size
                    <= off_t(AttachmentUploadV3Policy.maximumPrepareBytes)
            close(descriptor)
            guard valid else {
                throw AttachmentUploadV3Error.storageFailure(
                    "protected temp manifest type or size"
                )
            }
            if unlink(url.path) == 0 {
                removedAny = true
            } else if errno != ENOENT {
                throw AttachmentUploadV3Error.storageFailure(
                    "protected temp manifest removal"
                )
            }
        }
        if removedAny {
            try synchronizeDirectory(root)
        }
    }

    private func manifestURL(uploadId: String) -> URL {
        root.appendingPathComponent("\(uploadId).json", isDirectory: false)
    }

    private func loadManifest(uploadId: String) throws -> Manifest? {
        let url = manifestURL(uploadId: uploadId)
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AttachmentUploadV3Error.storageFailure(
                "protected manifest open"
            )
        }
        defer { close(descriptor) }
        do {
            var before = stat()
            guard fstat(descriptor, &before) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_size >= 0,
                  before.st_size
                    <= off_t(AttachmentUploadV3Policy.maximumPrepareBytes)
            else {
                throw AttachmentUploadV3Error.storageFailure(
                    "protected manifest type or size"
                )
            }
            let size = Int(before.st_size)
            let handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: false
            )
            let data = try handle.read(
                upToCount:
                    AttachmentUploadV3Policy.maximumPrepareBytes + 1
            ) ?? Data()
            var after = stat()
            guard data.count <= AttachmentUploadV3Policy.maximumPrepareBytes,
                  data.count == size,
                  fstat(descriptor, &after) == 0,
                  (after.st_mode & S_IFMT) == S_IFREG,
                  before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino,
                  before.st_size == after.st_size else {
                throw AttachmentUploadV3Error.storageFailure(
                    "protected manifest changed or exceeded its bound"
                )
            }
            let manifest = try decoder.decode(Manifest.self, from: data)
            guard manifest.schemaVersion == 1,
                  manifest.uploadId == uploadId else {
                throw AttachmentUploadV3Error.storageFailure(
                    "protected manifest identity"
                )
            }
            do {
                try Self.validate(
                    manifest.request,
                    uploadId: uploadId,
                    authorizedOwnerFingerprint:
                        manifest.request.ownerFingerprint
                )
            } catch {
                throw AttachmentUploadV3Error.storageFailure(
                    "protected manifest contents"
                )
            }
            return manifest
        } catch let error as AttachmentUploadV3Error {
            throw error
        } catch {
            throw AttachmentUploadV3Error.storageFailure(
                "protected manifest read"
            )
        }
    }

    private func persistManifest(_ manifest: Manifest) throws {
        let data: Data
        do {
            data = try encoder.encode(manifest)
        } catch {
            throw AttachmentUploadV3Error.storageFailure(
                "protected manifest encode"
            )
        }
        guard data.count <= AttachmentUploadV3Policy.maximumPrepareBytes else {
            throw AttachmentUploadV3Error.storageFailure(
                "protected manifest too large"
            )
        }
        let destination = manifestURL(uploadId: manifest.uploadId)
        let temporary = root.appendingPathComponent(
            ".\(manifest.uploadId).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw AttachmentUploadV3Error.storageFailure(
                "protected manifest create"
            )
        }
        do {
            try synchronizeFile(temporary)
            if rename(temporary.path, destination.path) != 0 {
                throw AttachmentUploadV3Error.storageFailure(
                    "protected manifest rename"
                )
            }
            try synchronizeDirectory(root)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func removeManifest(uploadId: String) throws {
        let url = manifestURL(uploadId: uploadId)
        if unlink(url.path) == 0 {
            try synchronizeDirectory(root)
            return
        }
        guard errno == ENOENT else {
            throw AttachmentUploadV3Error.storageFailure(
                "protected manifest removal"
            )
        }
    }

    /// Reconcile a bounded number of protection-key manifests against the
    /// authoritative plaintext store. Terminal/tombstoned/expired jobs no
    /// longer need an encryption key; active receiving jobs are preserved.
    private func pruneOrphanedProtectionManifestsBounded(
        excluding: Set<String> = []
    ) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return
        }
        var visited = 0
        var inspected = 0
        while visited
                < AttachmentUploadV3Policy.maximumProtectionEntriesPerSweep,
              inspected
                < AttachmentUploadV3Policy.maximumProtectionEntriesPerSweep,
              let url = enumerator.nextObject() as? URL {
            visited += 1
            guard url.pathExtension == "json" else { continue }
            inspected += 1
            let uploadId = url.deletingPathExtension().lastPathComponent
            guard !excluding.contains(uploadId),
                  UUID(uuidString: uploadId) != nil else {
                continue
            }
            let manifest: Manifest
            do {
                guard let loaded = try loadManifest(uploadId: uploadId) else {
                    continue
                }
                manifest = loaded
            } catch {
                // Corrupt protection metadata is evidence of user intent.
                // Fail closed and preserve it for explicit recovery.
                continue
            }
            do {
                let status = try plaintextStore.status(
                    ownerFingerprint: manifest.request.ownerFingerprint,
                    uploadId: uploadId,
                    workspaceId: manifest.request.workspaceId
                )
                if status.phase != .receiving {
                    try removeManifest(uploadId: uploadId)
                }
            } catch let error as AttachmentUploadV2Error {
                switch error {
                case .uploadUnknown, .uploadCancelled:
                    try removeManifest(uploadId: uploadId)
                default:
                    continue
                }
            }
        }
    }

    private func synchronizeFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw AttachmentUploadV3Error.storageFailure("open file for sync")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw AttachmentUploadV3Error.storageFailure("file sync")
        }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw AttachmentUploadV3Error.storageFailure(
                "open directory for sync"
            )
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw AttachmentUploadV3Error.storageFailure("directory sync")
        }
    }
}

private extension Data {
    init?(hexadecimal: String) {
        guard hexadecimal.utf8.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexadecimal.utf8.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
