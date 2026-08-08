import CryptoKit
import Darwin
import Foundation
import CoreModel
import Persistence

// MARK: - Constants

/// Protocol constants for durable chunked agent-attachment upload v2.
/// Fixed wire policy — not negotiated per transfer.
public enum AttachmentUploadV2Policy {
    public static let protocolVersion = 2
    public static let maximumFileBytes = AgentAttachmentStore.maximumSizeBytes
    /// Fixed raw (decoded) chunk size. Last chunk may be shorter.
    public static let rawChunkBytes = 512 * 1_024
    public static let maximumChunkCount = 50
    /// Concurrent `receiving` jobs per authenticated owner.
    public static let maximumActiveJobs = 4
    /// Sum of declared `sizeBytes` for one owner's receiving jobs.
    public static let maximumReservedBytes = maximumActiveJobs * maximumFileBytes
    /// Defense in depth when many paired owners upload concurrently.
    public static let maximumGlobalActiveJobs = 16
    public static let maximumGlobalReservedBytes =
        maximumGlobalActiveJobs * maximumFileBytes
    /// Abandoned partial uploads stop reserving disk/admission forever.
    public static let receivingJobTTL: TimeInterval = 24 * 60 * 60
    /// Idempotency tombstones/results are useful for background retries, but
    /// cannot grow without bound under an authenticated misbehaving client.
    public static let terminalJobTTL: TimeInterval = 7 * 24 * 60 * 60
    /// A cancelled upload id must outlive the longest iOS background transfer.
    /// This compact deny record is independent from normal terminal-job caps.
    public static let cancellationDenyRetention: TimeInterval = 8 * 24 * 60 * 60
    /// Separate admission caps bound authenticated DELETE spam without ever
    /// evicting a live cancellation record.
    public static let maximumCancellationDenyRecordsPerOwner = 2_048
    public static let maximumGlobalCancellationDenyRecords = 8_192
    public static let maximumTerminalJobsPerOwner = 128
    public static let maximumGlobalTerminalJobs = 1_024
    public static let maximumFilenameBytes = 255
    public static let maximumMIMETypeBytes = 128

    public static func chunkCount(sizeBytes: Int) -> Int {
        guard sizeBytes > 0 else { return 0 }
        return (sizeBytes + rawChunkBytes - 1) / rawChunkBytes
    }

    public static func expectedChunkByteCount(index: Int, sizeBytes: Int) -> Int? {
        let count = chunkCount(sizeBytes: sizeBytes)
        guard index >= 0, index < count else { return nil }
        let fullChunks = sizeBytes / rawChunkBytes
        let remainder = sizeBytes % rawChunkBytes
        if index < fullChunks {
            return rawChunkBytes
        }
        return remainder == 0 ? rawChunkBytes : remainder
    }
}

// MARK: - Public status / errors

public enum AttachmentUploadV2Phase: String, Codable, Sendable, Equatable {
    case receiving
    case committed
    case cancelled
}

/// Snapshot safe to return to DirectHTTPServer / paired clients.
/// Never includes tokens or raw chunk bytes.
public struct AttachmentUploadV2Status: Equatable, Sendable {
    public let protocolVersion: Int
    public let uploadId: String
    public let workspaceId: String
    public let phase: AttachmentUploadV2Phase
    public let sizeBytes: Int
    public let chunkCount: Int
    public let receivedChunkIndices: [Int]
    public let receivedBytes: Int
    public let result: AgentAttachmentUploadResult?
    /// True only when this call durably records a previously absent chunk.
    /// Internal host response-status seam; omitted from the wire payload.
    public let newlyAcceptedChunk: Bool
    /// True only on the call that durably transitions receiving → committed.
    /// This is an internal host event seam and is not part of the wire payload.
    public let newlyCommitted: Bool

    public init(
        protocolVersion: Int = AttachmentUploadV2Policy.protocolVersion,
        uploadId: String,
        workspaceId: String,
        phase: AttachmentUploadV2Phase,
        sizeBytes: Int,
        chunkCount: Int,
        receivedChunkIndices: [Int],
        receivedBytes: Int,
        result: AgentAttachmentUploadResult? = nil,
        newlyAcceptedChunk: Bool = false,
        newlyCommitted: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.uploadId = uploadId
        self.workspaceId = workspaceId
        self.phase = phase
        self.sizeBytes = sizeBytes
        self.chunkCount = chunkCount
        self.receivedChunkIndices = receivedChunkIndices
        self.receivedBytes = receivedBytes
        self.result = result
        self.newlyAcceptedChunk = newlyAcceptedChunk
        self.newlyCommitted = newlyCommitted
    }
}

public enum AttachmentUploadV2Error: Error, Equatable, CustomStringConvertible {
    case invalidParams(String)
    case uploadUnknown
    case uploadCancelled
    case ownerMismatch
    case metadataConflict
    case chunkDigestConflict
    case chunkValidationFailed(String)
    case fileDigestMismatch
    case activeJobLimitExceeded
    case reservedBytesExceeded
    case storageFailure(String)

    public var description: String {
        switch self {
        case .invalidParams(let detail): return "Invalid attachment upload v2 params: \(detail)"
        case .uploadUnknown: return "Unknown attachment upload v2 id"
        case .uploadCancelled: return "Attachment upload v2 was cancelled"
        case .ownerMismatch: return "Attachment upload v2 owner mismatch"
        case .metadataConflict: return "Attachment upload v2 immutable metadata conflict"
        case .chunkDigestConflict: return "Attachment upload v2 chunk digest conflict"
        case .chunkValidationFailed(let detail): return "Attachment upload v2 chunk validation failed: \(detail)"
        case .fileDigestMismatch: return "Attachment upload v2 whole-file digest mismatch"
        case .activeJobLimitExceeded: return "Attachment upload v2 active job limit exceeded"
        case .reservedBytesExceeded: return "Attachment upload v2 reserved byte budget exceeded"
        case .storageFailure(let detail): return "Attachment upload v2 storage failure: \(detail)"
        }
    }
}

// MARK: - Store

private enum AttachmentUploadV2Synchronization {
    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var locks: [String: NSRecursiveLock] = [:]

    static func withLock<T>(root: URL, _ body: () throws -> T) rethrows -> T {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.lock()
        let lock: NSRecursiveLock
        if let existing = locks[key] {
            lock = existing
        } else {
            let created = NSRecursiveLock()
            locks[key] = created
            lock = created
        }
        registryLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

enum AttachmentUploadV2DurabilityKind: String, Sendable {
    case ownerBinding
    case manifest
    case chunk
    case cancellationDenyIndex
    case cancellationTombstone
    case assembledAttachment
    case finalAttachment
    case finalMetadata
    case finalComposerPath
}

enum AttachmentUploadV2DurabilityPoint: String, Sendable {
    case beforeFileSync
    case fileSynced
    case beforeAtomicRename
    case atomicRenameCompleted
    case parentDirectorySynced
}

struct AttachmentUploadV2DurabilityEvent: Sendable {
    let kind: AttachmentUploadV2DurabilityKind
    let point: AttachmentUploadV2DurabilityPoint
}

/// Durable, idempotent chunked attachment upload store for protocol version 2.
///
/// DirectHTTPServer can call `begin` / `putChunk` / `status` / `cancel` without
/// holding process memory of the full payload. Manifests + raw chunk files live
/// under an injected root; finalize reuses `AgentAttachmentStore`.
public final class AttachmentUploadV2Store: @unchecked Sendable {
    public let root: URL
    public let attachmentStore: AgentAttachmentStore
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let durabilityHook:
        @Sendable (AttachmentUploadV2DurabilityEvent) throws -> Void

    public convenience init(
        root: URL,
        attachmentStore: AgentAttachmentStore,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            root: root,
            attachmentStore: attachmentStore,
            fileManager: fileManager,
            now: now,
            durabilityHook: { _ in }
        )
    }

    init(
        root: URL,
        attachmentStore: AgentAttachmentStore,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        durabilityHook:
            @escaping @Sendable (AttachmentUploadV2DurabilityEvent) throws -> Void
    ) {
        self.root = root.standardizedFileURL
        self.attachmentStore = attachmentStore
        self.fileManager = fileManager
        self.now = now
        self.durabilityHook = durabilityHook
    }

    // MARK: Public API

    /// Creates or resumes a client-generated upload id under `ownerFingerprint`.
    /// Identical metadata is idempotent; conflicting immutable fields fail closed.
    @discardableResult
    public func begin(
        ownerFingerprint: String,
        uploadId: String,
        workspaceId: String,
        filename: String,
        mimeType: String?,
        sizeBytes: Int,
        sha256: String
    ) throws -> AttachmentUploadV2Status {
        let owner = try Self.validatedOwnerFingerprint(ownerFingerprint)
        let id = try Self.validatedUploadId(uploadId)
        let workspace = try Self.validatedWorkspaceId(workspaceId)
        let name = try Self.validatedFilename(filename)
        let mime = try Self.validatedMIMEType(mimeType)
        let digest = try Self.validatedDigest(sha256)
        guard (1...AttachmentUploadV2Policy.maximumFileBytes).contains(sizeBytes) else {
            throw AttachmentUploadV2Error.invalidParams("sizeBytes out of range")
        }
        let chunkCount = AttachmentUploadV2Policy.chunkCount(sizeBytes: sizeBytes)
        guard chunkCount > 0, chunkCount <= AttachmentUploadV2Policy.maximumChunkCount else {
            throw AttachmentUploadV2Error.invalidParams("chunkCount out of range")
        }
        let kind = Self.kind(filename: name, mimeType: mime)

        return try withLock {
            try prepareRoot()
            try validateExistingOwnerBinding(owner: owner, uploadId: id)
            if let cancellation = try loadCancellationDenyRecord(
                owner: owner,
                uploadId: id
            ) {
                guard cancellation.workspaceId == workspace else {
                    throw AttachmentUploadV2Error.metadataConflict
                }
                throw AttachmentUploadV2Error.uploadCancelled
            }
            if try loadCancellationTombstone(owner: owner, uploadId: id) != nil {
                _ = try ensureOwnerBinding(owner: owner, uploadId: id)
                throw AttachmentUploadV2Error.uploadCancelled
            }
            // Fast path for every chunk after the first: one small manifest
            // read, no lifetime-wide GC scan under the upload lock.
            if let existing = try loadManifest(owner: owner, uploadId: id) {
                try ensureOwner(existing, owner: owner)
                _ = try ensureOwnerBinding(owner: owner, uploadId: id)
                try ensureMetadataMatch(
                    existing,
                    workspaceId: workspace,
                    filename: name,
                    mimeType: mime,
                    sizeBytes: sizeBytes,
                    sha256: digest,
                    kind: kind
                )
                if existing.phase != .receiving {
                    try? removeIntermediateFiles(
                        in: jobDirectory(owner: owner, uploadId: id)
                    )
                }
                return status(from: existing)
            }
            try expireAbandonedReceivingJobs()
            try pruneTerminalJobs(reservingSlotFor: nil)

            let (active, reserved) = try scanReceivingBudget(owner: owner)
            guard active < AttachmentUploadV2Policy.maximumActiveJobs else {
                throw AttachmentUploadV2Error.activeJobLimitExceeded
            }
            guard reserved + sizeBytes <= AttachmentUploadV2Policy.maximumReservedBytes else {
                throw AttachmentUploadV2Error.reservedBytesExceeded
            }
            let (globalActive, globalReserved) = try scanGlobalReceivingBudget()
            guard globalActive < AttachmentUploadV2Policy.maximumGlobalActiveJobs else {
                throw AttachmentUploadV2Error.activeJobLimitExceeded
            }
            guard globalReserved + sizeBytes
                    <= AttachmentUploadV2Policy.maximumGlobalReservedBytes else {
                throw AttachmentUploadV2Error.reservedBytesExceeded
            }
            let createdOwnerBinding = try ensureOwnerBinding(
                owner: owner,
                uploadId: id
            )

            let jobDir = jobDirectory(owner: owner, uploadId: id)
            do {
                let ownerDir = jobDir.deletingLastPathComponent()
                let ownerDirExisted = fileManager.fileExists(
                    atPath: ownerDir.path
                )
                let chunksDir = chunksDirectory(in: jobDir)
                try fileManager.createDirectory(
                    at: chunksDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try applyDirectoryPermissions(jobDir)
                try applyDirectoryPermissions(ownerDir)
                try synchronizeDirectory(chunksDir)
                try synchronizeDirectory(jobDir)
                try synchronizeDirectory(ownerDir)
                if !ownerDirExisted {
                    try synchronizeDirectory(root)
                }

                let createdAt = now().timeIntervalSince1970
                let manifest = Manifest(
                    protocolVersion: AttachmentUploadV2Policy.protocolVersion,
                    uploadId: id,
                    ownerFingerprint: owner,
                    workspaceId: workspace,
                    filename: name,
                    mimeType: mime,
                    kind: kind,
                    sizeBytes: sizeBytes,
                    sha256: digest,
                    chunkCount: chunkCount,
                    chunkBytes: AttachmentUploadV2Policy.rawChunkBytes,
                    phase: .receiving,
                    receivedChunks: [:],
                    result: nil,
                    createdAtEpochSeconds: createdAt,
                    updatedAtEpochSeconds: createdAt
                )
                try persistManifest(manifest, in: jobDir)
                return status(from: manifest)
            } catch {
                if createdOwnerBinding {
                    try rollbackNewUpload(owner: owner, uploadId: id)
                }
                throw error
            }
        }
    }

    /// Accepts one raw chunk. Order-independent. Identical digests are
    /// idempotent; conflicting digests or sizes fail closed. Auto-finalizes
    /// exactly when every index is present.
    @discardableResult
    public func putChunk(
        ownerFingerprint: String,
        uploadId: String,
        chunkIndex: Int,
        data: Data,
        sha256: String
    ) throws -> AttachmentUploadV2Status {
        let owner = try Self.validatedOwnerFingerprint(ownerFingerprint)
        let id = try Self.validatedUploadId(uploadId)
        let digest = try Self.validatedDigest(sha256)

        return try withLock {
            try prepareRoot()
            try validateExistingOwnerBinding(owner: owner, uploadId: id)
            if try loadCancellationDenyRecord(owner: owner, uploadId: id) != nil {
                throw AttachmentUploadV2Error.uploadCancelled
            }
            if try loadCancellationTombstone(owner: owner, uploadId: id) != nil {
                throw AttachmentUploadV2Error.uploadCancelled
            }
            guard var manifest = try loadManifest(owner: owner, uploadId: id) else {
                throw AttachmentUploadV2Error.uploadUnknown
            }
            try ensureOwner(manifest, owner: owner)
            _ = try ensureOwnerBinding(owner: owner, uploadId: id)

            guard let expectedSize = AttachmentUploadV2Policy.expectedChunkByteCount(
                index: chunkIndex,
                sizeBytes: manifest.sizeBytes
            ) else {
                throw AttachmentUploadV2Error.chunkValidationFailed("index out of range")
            }
            guard data.count == expectedSize else {
                throw AttachmentUploadV2Error.chunkValidationFailed("byte count mismatch")
            }
            let actualDigest = Self.digest(data)
            guard actualDigest == digest else {
                throw AttachmentUploadV2Error.chunkValidationFailed("digest mismatch")
            }

            switch manifest.phase {
            case .cancelled:
                throw AttachmentUploadV2Error.uploadCancelled
            case .committed:
                guard manifest.receivedChunks[String(chunkIndex)] == digest else {
                    throw AttachmentUploadV2Error.chunkDigestConflict
                }
                try? removeIntermediateFiles(
                    in: jobDirectory(owner: owner, uploadId: id)
                )
                return status(from: manifest)
            case .receiving:
                break
            }

            let jobDir = jobDirectory(owner: owner, uploadId: id)
            let newlyAcceptedChunk: Bool
            if let prior = manifest.receivedChunks[String(chunkIndex)] {
                newlyAcceptedChunk = false
                if prior != digest {
                    throw AttachmentUploadV2Error.chunkDigestConflict
                }
                // A crash may leave the manifest durable but the atomic chunk
                // rename absent. Repair from the verified retry body.
                let chunkURL = chunkFileURL(in: jobDir, index: chunkIndex)
                if !fileManager.fileExists(atPath: chunkURL.path)
                    || (try? Self.streamDigest(at: chunkURL)) != digest {
                    try persistChunk(data, at: chunkURL)
                }
            } else {
                newlyAcceptedChunk = true
                let chunkURL = chunkFileURL(in: jobDir, index: chunkIndex)
                try persistChunk(data, at: chunkURL)
                manifest.receivedChunks[String(chunkIndex)] = digest
            }
            manifest.updatedAtEpochSeconds = now().timeIntervalSince1970
            try persistManifest(manifest, in: jobDir)

            if manifest.receivedChunks.count == manifest.chunkCount {
                manifest = try finalize(manifest: manifest, jobDir: jobDir)
                return status(
                    from: manifest,
                    newlyAcceptedChunk: newlyAcceptedChunk,
                    newlyCommitted: true
                )
            }
            return status(from: manifest, newlyAcceptedChunk: newlyAcceptedChunk)
        }
    }

    public func status(
        ownerFingerprint: String,
        uploadId: String,
        workspaceId: String
    ) throws -> AttachmentUploadV2Status {
        let owner = try Self.validatedOwnerFingerprint(ownerFingerprint)
        let id = try Self.validatedUploadId(uploadId)
        let workspace = try Self.validatedWorkspaceId(workspaceId)
        return try withLock {
            try prepareRoot()
            try validateExistingOwnerBinding(owner: owner, uploadId: id)
            if let cancellation = try loadCancellationDenyRecord(
                owner: owner,
                uploadId: id
            ) {
                guard cancellation.workspaceId == workspace else {
                    throw AttachmentUploadV2Error.metadataConflict
                }
                return status(
                    uploadId: id,
                    from: cancellation
                )
            }
            if let tombstone = try loadCancellationTombstone(
                owner: owner,
                uploadId: id
            ) {
                guard tombstone.workspaceId == workspace else {
                    throw AttachmentUploadV2Error.metadataConflict
                }
                return status(from: tombstone)
            }
            guard let manifest = try loadManifest(owner: owner, uploadId: id) else {
                throw AttachmentUploadV2Error.uploadUnknown
            }
            try ensureOwner(manifest, owner: owner)
            _ = try ensureOwnerBinding(owner: owner, uploadId: id)
            guard manifest.workspaceId == workspace else {
                throw AttachmentUploadV2Error.metadataConflict
            }
            if manifest.phase != .receiving {
                try? removeIntermediateFiles(
                    in: jobDirectory(owner: owner, uploadId: id)
                )
            }
            return status(from: manifest)
        }
    }

    /// Idempotent even before the first PUT: an unknown id gets a durable
    /// tombstone so an already-in-flight background PUT cannot resurrect it.
    /// Already-committed attachment content is retained and returned as committed.
    @discardableResult
    public func cancel(
        ownerFingerprint: String,
        uploadId: String,
        workspaceId: String
    ) throws -> AttachmentUploadV2Status {
        let owner = try Self.validatedOwnerFingerprint(ownerFingerprint)
        let id = try Self.validatedUploadId(uploadId)
        let workspace = try Self.validatedWorkspaceId(workspaceId)
        return try withLock {
            try prepareRoot()
            try validateExistingOwnerBinding(owner: owner, uploadId: id)
            if let cancellation = try loadCancellationDenyRecord(
                owner: owner,
                uploadId: id
            ) {
                guard cancellation.workspaceId == workspace else {
                    throw AttachmentUploadV2Error.metadataConflict
                }
                return status(
                    uploadId: id,
                    from: cancellation
                )
            }
            let createdOwnerBinding = try ensureOwnerBinding(
                owner: owner,
                uploadId: id
            )
            if let tombstone = try loadCancellationTombstone(
                owner: owner,
                uploadId: id
            ) {
                guard tombstone.workspaceId == workspace else {
                    throw AttachmentUploadV2Error.metadataConflict
                }
                return status(from: tombstone)
            }
            guard var manifest = try loadManifest(owner: owner, uploadId: id) else {
                do {
                    let cancelledAt = now().timeIntervalSince1970
                    try persistCancellationDenyRecord(
                        owner: owner,
                        uploadId: id,
                        workspaceId: workspace,
                        cancelledAtEpochSeconds: cancelledAt
                    )
                    try pruneTerminalJobs(reservingSlotFor: owner)
                    let tombstone = CancellationTombstone(
                        protocolVersion: AttachmentUploadV2Policy.protocolVersion,
                        uploadId: id,
                        ownerFingerprint: owner,
                        workspaceId: workspace,
                        updatedAtEpochSeconds: cancelledAt
                    )
                    try persistCancellationTombstone(tombstone)
                    return status(from: tombstone)
                } catch {
                    if createdOwnerBinding {
                        try rollbackNewUpload(owner: owner, uploadId: id)
                    }
                    throw error
                }
            }
            try ensureOwner(manifest, owner: owner)
            guard manifest.workspaceId == workspace else {
                throw AttachmentUploadV2Error.metadataConflict
            }
            let jobDir = jobDirectory(owner: owner, uploadId: id)
            switch manifest.phase {
            case .committed:
                try? removeIntermediateFiles(in: jobDir)
                return status(from: manifest)
            case .cancelled:
                try persistCancellationDenyRecord(
                    owner: owner,
                    uploadId: id,
                    workspaceId: workspace,
                    cancelledAtEpochSeconds: manifest.updatedAtEpochSeconds
                )
                try? removeIntermediateFiles(in: jobDir)
                return status(from: manifest)
            case .receiving:
                let cancelledAt = now().timeIntervalSince1970
                try persistCancellationDenyRecord(
                    owner: owner,
                    uploadId: id,
                    workspaceId: workspace,
                    cancelledAtEpochSeconds: cancelledAt
                )
                try pruneTerminalJobs(reservingSlotFor: owner)
                manifest.phase = .cancelled
                manifest.receivedChunks = [:]
                manifest.updatedAtEpochSeconds = cancelledAt
                // Persist the tombstone before deleting bytes. A crash may leak
                // reclaimable chunks, but can never resurrect a cancelled job.
                try persistManifest(manifest, in: jobDir)
                try? removeIntermediateFiles(in: jobDir)
                return status(from: manifest)
            }
        }
    }

    // MARK: Finalize

    private func finalize(manifest: Manifest, jobDir: URL) throws -> Manifest {
        var updated = manifest
        try pruneTerminalJobs(reservingSlotFor: manifest.ownerFingerprint)
        let assembled = jobDir.appendingPathComponent("assembled.tmp", isDirectory: false)
        defer { try? fileManager.removeItem(at: assembled) }

        try assembleChunks(manifest: updated, jobDir: jobDir, into: assembled)
        try synchronizeExistingFileAndParent(
            at: assembled,
            kind: .assembledAttachment
        )

        let attachment: AgentAttachment
        do {
            attachment = try attachmentStore.stageFile(
                at: assembled,
                displayName: updated.filename,
                kind: updated.kind,
                mimeType: updated.mimeType,
                expectedSHA256: updated.sha256,
                expectedSizeBytes: updated.sizeBytes,
                referenceID: Self.referenceID(
                    ownerFingerprint: updated.ownerFingerprint,
                    uploadId: updated.uploadId
                ),
                consumeSource: true
            )
        } catch let error as AgentAttachmentResolverError {
            switch error {
            case .malformedReference(let message) where message.contains("hash"):
                throw AttachmentUploadV2Error.fileDigestMismatch
            default:
                throw AttachmentUploadV2Error.storageFailure(error.description)
            }
        } catch {
            throw AttachmentUploadV2Error.storageFailure(String(describing: error))
        }

        try synchronizeCommittedAttachment(attachment)
        guard let reference = AgentAttachmentReference(attachment) else {
            throw AttachmentUploadV2Error.storageFailure("incomplete attachment metadata")
        }
        let insertionPath = (try? attachmentStore.composerInsertionPath(
            for: attachment
        )) ?? attachment.path
        try synchronizeExistingFileAndParent(
            at: URL(fileURLWithPath: insertionPath),
            kind: .finalComposerPath
        )
        let result = AgentAttachmentUploadResult(
            reference,
            composerInsertionText: insertionPath
        )
        updated.phase = .committed
        updated.result = Manifest.StoredResult(result)
        updated.updatedAtEpochSeconds = now().timeIntervalSince1970
        // Commit the result before reclaiming chunks. If the process dies
        // between these operations, status still returns the durable result.
        try persistManifest(updated, in: jobDir)
        try? removeIntermediateFiles(in: jobDir)
        return updated
    }

    private func assembleChunks(manifest: Manifest, jobDir: URL, into destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw AttachmentUploadV2Error.storageFailure("cannot create assembly file")
        }
        let writer: FileHandle
        do {
            writer = try FileHandle(forWritingTo: destination)
        } catch {
            throw AttachmentUploadV2Error.storageFailure("cannot open assembly file")
        }
        defer { try? writer.close() }

        var total = 0
        for index in 0..<manifest.chunkCount {
            let chunkURL = chunkFileURL(in: jobDir, index: index)
            guard let data = try? Data(contentsOf: chunkURL, options: .mappedIfSafe) else {
                throw AttachmentUploadV2Error.storageFailure("missing chunk \(index)")
            }
            guard let expected = AttachmentUploadV2Policy.expectedChunkByteCount(
                index: index,
                sizeBytes: manifest.sizeBytes
            ), data.count == expected else {
                throw AttachmentUploadV2Error.chunkValidationFailed("assembled chunk size")
            }
            let digest = Self.digest(data)
            guard manifest.receivedChunks[String(index)] == digest else {
                throw AttachmentUploadV2Error.chunkDigestConflict
            }
            do {
                try writer.write(contentsOf: data)
            } catch {
                throw AttachmentUploadV2Error.storageFailure("assembly write failed")
            }
            total += data.count
        }
        guard total == manifest.sizeBytes else {
            throw AttachmentUploadV2Error.chunkValidationFailed("assembled byte count")
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    // MARK: Manifest I/O

    private struct Manifest: Codable, Equatable {
        let protocolVersion: Int
        let uploadId: String
        let ownerFingerprint: String
        let workspaceId: String
        let filename: String
        let mimeType: String?
        let kind: AgentAttachmentKind
        let sizeBytes: Int
        let sha256: String
        let chunkCount: Int
        let chunkBytes: Int
        var phase: AttachmentUploadV2Phase
        /// chunkIndex string → sha256 hex (no raw content).
        var receivedChunks: [String: String]
        var result: StoredResult?
        let createdAtEpochSeconds: TimeInterval
        var updatedAtEpochSeconds: TimeInterval

        struct StoredResult: Codable, Equatable {
            let id: String
            let displayName: String
            let kind: AgentAttachmentKind
            let mimeType: String?
            let sha256: String
            let sizeBytes: Int
            let composerInsertionText: String

            init(_ result: AgentAttachmentUploadResult) {
                self.id = result.id
                self.displayName = result.displayName
                self.kind = result.kind
                self.mimeType = result.mimeType
                self.sha256 = result.sha256
                self.sizeBytes = result.sizeBytes
                self.composerInsertionText = result.composerInsertionText
            }

            var asResult: AgentAttachmentUploadResult {
                AgentAttachmentUploadResult(
                    id: id,
                    displayName: displayName,
                    kind: kind,
                    mimeType: mimeType,
                    sha256: sha256,
                    sizeBytes: sizeBytes,
                    composerInsertionText: composerInsertionText
                )
            }
        }

        var receivedBytes: Int {
            receivedChunks.keys.compactMap { Int($0) }.compactMap { index in
                AttachmentUploadV2Policy.expectedChunkByteCount(index: index, sizeBytes: sizeBytes)
            }.reduce(0, +)
        }

        var orderedIndices: [Int] {
            receivedChunks.keys.compactMap(Int.init).sorted()
        }
    }

    private struct CancellationTombstone: Codable, Equatable {
        let protocolVersion: Int
        let uploadId: String
        let ownerFingerprint: String
        let workspaceId: String
        let updatedAtEpochSeconds: TimeInterval
    }

    private struct CancellationDenyIndex: Codable, Equatable {
        let schemaVersion: Int
        var records: [String: CancellationDenyRecord]

        static let empty = CancellationDenyIndex(schemaVersion: 1, records: [:])
    }

    private struct CancellationDenyRecord: Codable, Equatable {
        let ownerFingerprint: String
        let workspaceId: String
        let cancelledAtEpochSeconds: TimeInterval
        let expiresAtEpochSeconds: TimeInterval
    }

    private func status(
        from manifest: Manifest,
        newlyAcceptedChunk: Bool = false,
        newlyCommitted: Bool = false
    ) -> AttachmentUploadV2Status {
        AttachmentUploadV2Status(
            protocolVersion: manifest.protocolVersion,
            uploadId: manifest.uploadId,
            workspaceId: manifest.workspaceId,
            phase: manifest.phase,
            sizeBytes: manifest.sizeBytes,
            chunkCount: manifest.chunkCount,
            receivedChunkIndices: manifest.orderedIndices,
            receivedBytes: manifest.receivedBytes,
            result: manifest.result?.asResult,
            newlyAcceptedChunk: newlyAcceptedChunk,
            newlyCommitted: newlyCommitted
        )
    }

    private func status(
        from tombstone: CancellationTombstone
    ) -> AttachmentUploadV2Status {
        AttachmentUploadV2Status(
            protocolVersion: tombstone.protocolVersion,
            uploadId: tombstone.uploadId,
            workspaceId: tombstone.workspaceId,
            phase: .cancelled,
            sizeBytes: 0,
            chunkCount: 0,
            receivedChunkIndices: [],
            receivedBytes: 0,
            result: nil
        )
    }

    private func status(
        uploadId: String,
        from cancellation: CancellationDenyRecord
    ) -> AttachmentUploadV2Status {
        AttachmentUploadV2Status(
            uploadId: uploadId,
            workspaceId: cancellation.workspaceId,
            phase: .cancelled,
            sizeBytes: 0,
            chunkCount: 0,
            receivedChunkIndices: [],
            receivedBytes: 0,
            result: nil
        )
    }

    private func jobDirectory(owner: String, uploadId: String) -> URL {
        root
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(uploadId, isDirectory: true)
    }

    private func chunksDirectory(in jobDir: URL) -> URL {
        jobDir.appendingPathComponent("chunks", isDirectory: true)
    }

    private func chunkFileURL(in jobDir: URL, index: Int) -> URL {
        chunksDirectory(in: jobDir)
            .appendingPathComponent(String(format: "%05d.raw", index), isDirectory: false)
    }

    private func manifestURL(in jobDir: URL) -> URL {
        jobDir.appendingPathComponent("manifest.json", isDirectory: false)
    }

    private var ownerBindingRoot: URL {
        root.appendingPathComponent(".upload-owners", isDirectory: true)
    }

    private var cancellationDenyIndexURL: URL {
        root.appendingPathComponent(
            ".cancelled-upload-denylist.json",
            isDirectory: false
        )
    }

    private func ownerBindingURL(uploadId: String) -> URL {
        ownerBindingRoot.appendingPathComponent("\(uploadId).owner", isDirectory: false)
    }

    private func cancellationTombstoneURL(owner: String, uploadId: String) -> URL {
        jobDirectory(owner: owner, uploadId: uploadId)
            .appendingPathComponent("cancelled.json", isDirectory: false)
    }

    private func loadManifest(owner: String, uploadId: String) throws -> Manifest? {
        let url = manifestURL(in: jobDirectory(owner: owner, uploadId: uploadId))
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.protocolVersion == AttachmentUploadV2Policy.protocolVersion,
                  manifest.uploadId == uploadId,
                  manifest.ownerFingerprint == owner else {
                throw AttachmentUploadV2Error.storageFailure("corrupt manifest identity")
            }
            return manifest
        } catch let error as AttachmentUploadV2Error {
            throw error
        } catch {
            throw AttachmentUploadV2Error.storageFailure("corrupt manifest")
        }
    }

    private func loadCancellationTombstone(
        owner: String,
        uploadId: String
    ) throws -> CancellationTombstone? {
        let url = cancellationTombstoneURL(owner: owner, uploadId: uploadId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let tombstone = try JSONDecoder().decode(
                CancellationTombstone.self,
                from: Data(contentsOf: url)
            )
            guard tombstone.protocolVersion == AttachmentUploadV2Policy.protocolVersion,
                  tombstone.uploadId == uploadId,
                  tombstone.ownerFingerprint == owner else {
                throw AttachmentUploadV2Error.storageFailure(
                    "corrupt cancellation tombstone identity"
                )
            }
            return tombstone
        } catch let error as AttachmentUploadV2Error {
            throw error
        } catch {
            throw AttachmentUploadV2Error.storageFailure(
                "corrupt cancellation tombstone"
            )
        }
    }

    private func persistCancellationTombstone(
        _ tombstone: CancellationTombstone
    ) throws {
        let jobDir = jobDirectory(
            owner: tombstone.ownerFingerprint,
            uploadId: tombstone.uploadId
        )
        do {
            let ownerDir = jobDir.deletingLastPathComponent()
            let ownerDirExisted = fileManager.fileExists(
                atPath: ownerDir.path
            )
            try fileManager.createDirectory(
                at: jobDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try applyDirectoryPermissions(jobDir)
            try applyDirectoryPermissions(ownerDir)
            try synchronizeDirectory(jobDir)
            try synchronizeDirectory(ownerDir)
            if !ownerDirExisted {
                try synchronizeDirectory(root)
            }
            let data = try JSONEncoder().encode(tombstone)
            let url = cancellationTombstoneURL(
                owner: tombstone.ownerFingerprint,
                uploadId: tombstone.uploadId
            )
            try durablyReplace(
                data,
                at: url,
                kind: .cancellationTombstone
            )
        } catch let error as AttachmentUploadV2Error {
            throw error
        } catch {
            throw AttachmentUploadV2Error.storageFailure(
                "cancellation tombstone write failed"
            )
        }
    }

    private func loadCancellationDenyIndex() throws -> CancellationDenyIndex {
        let url = cancellationDenyIndexURL
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }
        do {
            let index = try JSONDecoder().decode(
                CancellationDenyIndex.self,
                from: Data(contentsOf: url)
            )
            guard index.schemaVersion == CancellationDenyIndex.empty.schemaVersion else {
                throw AttachmentUploadV2Error.storageFailure(
                    "unsupported cancellation denylist schema"
                )
            }
            for (uploadId, record) in index.records {
                guard UUID(uuidString: uploadId) != nil,
                      uploadId == uploadId.lowercased(),
                      record.ownerFingerprint.count == 64,
                      record.ownerFingerprint.allSatisfy(\.isHexDigit),
                      record.ownerFingerprint == record.ownerFingerprint.lowercased(),
                      UUID(uuidString: record.workspaceId) != nil,
                      record.workspaceId == record.workspaceId.lowercased(),
                      record.cancelledAtEpochSeconds.isFinite,
                      record.expiresAtEpochSeconds.isFinite,
                      record.expiresAtEpochSeconds >= record.cancelledAtEpochSeconds else {
                    throw AttachmentUploadV2Error.storageFailure(
                        "corrupt cancellation denylist identity"
                    )
                }
            }
            return index
        } catch let error as AttachmentUploadV2Error {
            throw error
        } catch {
            // A corrupt denylist must fail closed; treating it as empty could
            // resurrect a cancelled background PUT.
            throw AttachmentUploadV2Error.storageFailure(
                "corrupt cancellation denylist"
            )
        }
    }

    private func loadCancellationDenyRecord(
        owner: String,
        uploadId: String
    ) throws -> CancellationDenyRecord? {
        guard let record = try loadCancellationDenyIndex().records[uploadId],
              record.expiresAtEpochSeconds > now().timeIntervalSince1970 else {
            return nil
        }
        guard record.ownerFingerprint == owner else {
            throw AttachmentUploadV2Error.ownerMismatch
        }
        return record
    }

    private func persistCancellationDenyRecord(
        owner: String,
        uploadId: String,
        workspaceId: String,
        cancelledAtEpochSeconds: TimeInterval
    ) throws {
        guard cancelledAtEpochSeconds.isFinite else {
            throw AttachmentUploadV2Error.storageFailure(
                "invalid cancellation timestamp"
            )
        }
        let currentEpochSeconds = now().timeIntervalSince1970
        let expiresAtEpochSeconds =
            cancelledAtEpochSeconds + AttachmentUploadV2Policy.cancellationDenyRetention
        guard expiresAtEpochSeconds.isFinite else {
            throw AttachmentUploadV2Error.storageFailure(
                "invalid cancellation expiry"
            )
        }

        var index = try loadCancellationDenyIndex()
        index.records = index.records.filter {
            $0.value.expiresAtEpochSeconds > currentEpochSeconds
        }
        if let existing = index.records[uploadId] {
            guard existing.ownerFingerprint == owner else {
                throw AttachmentUploadV2Error.ownerMismatch
            }
            guard existing.workspaceId == workspaceId else {
                throw AttachmentUploadV2Error.metadataConflict
            }
        } else if expiresAtEpochSeconds > currentEpochSeconds {
            let ownerRecordCount = index.records.values.reduce(into: 0) {
                count, record in
                if record.ownerFingerprint == owner {
                    count += 1
                }
            }
            guard ownerRecordCount
                    < AttachmentUploadV2Policy.maximumCancellationDenyRecordsPerOwner,
                  index.records.count
                    < AttachmentUploadV2Policy.maximumGlobalCancellationDenyRecords else {
                // Never evict a still-live cancellation: the caller preserves
                // its local source/tombstone and retries after capacity expires.
                throw AttachmentUploadV2Error.activeJobLimitExceeded
            }
            index.records[uploadId] = CancellationDenyRecord(
                ownerFingerprint: owner,
                workspaceId: workspaceId,
                cancelledAtEpochSeconds: cancelledAtEpochSeconds,
                expiresAtEpochSeconds: expiresAtEpochSeconds
            )
        }
        try persistCancellationDenyIndex(index)
    }

    private func persistCancellationDenyIndex(
        _ index: CancellationDenyIndex
    ) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(index)
            try durablyReplace(
                data,
                at: cancellationDenyIndexURL,
                kind: .cancellationDenyIndex
            )
        } catch let error as AttachmentUploadV2Error {
            throw error
        } catch {
            throw AttachmentUploadV2Error.storageFailure(
                "cancellation denylist write failed"
            )
        }
    }

    private func boundOwner(uploadId: String) throws -> String? {
        let url = ownerBindingURL(uploadId: uploadId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let value = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard value.count == 64, value.allSatisfy(\.isHexDigit) else {
                throw AttachmentUploadV2Error.storageFailure(
                    "corrupt upload owner binding"
                )
            }
            return value
        } catch let error as AttachmentUploadV2Error {
            throw error
        } catch {
            throw AttachmentUploadV2Error.storageFailure(
                "upload owner binding read failed"
            )
        }
    }

    private func validateExistingOwnerBinding(
        owner: String,
        uploadId: String
    ) throws {
        if let existing = try boundOwner(uploadId: uploadId),
           existing != owner {
            throw AttachmentUploadV2Error.ownerMismatch
        }
    }

    /// Returns true only when this call created a new binding.
    private func ensureOwnerBinding(owner: String, uploadId: String) throws -> Bool {
        if let existing = try boundOwner(uploadId: uploadId) {
            guard existing == owner else {
                throw AttachmentUploadV2Error.ownerMismatch
            }
            return false
        }
        do {
            try fileManager.createDirectory(
                at: ownerBindingRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try applyDirectoryPermissions(ownerBindingRoot)
            let url = ownerBindingURL(uploadId: uploadId)
            try durablyReplace(
                Data(owner.utf8),
                at: url,
                kind: .ownerBinding
            )
            return true
        } catch let error as AttachmentUploadV2Error {
            throw error
        } catch {
            throw AttachmentUploadV2Error.storageFailure(
                "upload owner binding write failed"
            )
        }
    }

    private func rollbackNewUpload(owner: String, uploadId: String) throws {
        let jobDir = jobDirectory(owner: owner, uploadId: uploadId)
        if fileManager.fileExists(atPath: jobDir.path) {
            do {
                try fileManager.removeItem(at: jobDir)
            } catch {
                throw AttachmentUploadV2Error.storageFailure(
                    "new upload rollback failed"
                )
            }
        }
        try removeOwnerBinding(uploadId: uploadId)
    }

    private func removeOwnerBinding(uploadId: String) throws {
        let url = ownerBindingURL(uploadId: uploadId)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw AttachmentUploadV2Error.storageFailure(
                "upload owner binding cleanup failed"
            )
        }
    }

    private func persistManifest(_ manifest: Manifest, in jobDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(manifest)
        } catch {
            throw AttachmentUploadV2Error.storageFailure("manifest encode failed")
        }
        // Defense: never persist fields that look like bearer tokens beyond known keys.
        // Manifest schema is fixed; raw chunk bytes are never encoded.
        let url = manifestURL(in: jobDir)
        do {
            try durablyReplace(data, at: url, kind: .manifest)
            try applyDirectoryPermissions(jobDir)
        } catch let error as AttachmentUploadV2Error {
            throw error
        } catch {
            throw AttachmentUploadV2Error.storageFailure("manifest write failed")
        }
    }

    private func prepareRoot() throws {
        let rootExisted = fileManager.fileExists(atPath: root.path)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try applyDirectoryPermissions(root)
        if !rootExisted {
            try synchronizeDirectory(root)
            try synchronizeDirectory(root.deletingLastPathComponent())
        }
        let ownerBindingRootExisted = fileManager.fileExists(
            atPath: ownerBindingRoot.path
        )
        try fileManager.createDirectory(
            at: ownerBindingRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try applyDirectoryPermissions(ownerBindingRoot)
        if !ownerBindingRootExisted {
            try synchronizeDirectory(ownerBindingRoot)
            try synchronizeDirectory(root)
        }
    }

    private func persistChunk(_ data: Data, at url: URL) throws {
        do {
            try durablyReplace(data, at: url, kind: .chunk)
        } catch {
            throw AttachmentUploadV2Error.storageFailure("chunk write failed")
        }
    }

    /// Writes a replacement in the destination directory, makes its contents
    /// durable, atomically renames it into place, then makes that directory
    /// entry durable. A caller never acknowledges state that only reached the
    /// page cache.
    private func durablyReplace(
        _ data: Data,
        at destination: URL,
        kind: AttachmentUploadV2DurabilityKind
    ) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw AttachmentUploadV2Error.storageFailure(
                "durable temporary file creation failed"
            )
        }
        defer {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: temporary)
        } catch {
            throw AttachmentUploadV2Error.storageFailure(
                "durable temporary file open failed"
            )
        }
        var handleIsOpen = true
        defer {
            if handleIsOpen {
                try? handle.close()
            }
        }
        do {
            try handle.write(contentsOf: data)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
            try emitDurabilityEvent(kind: kind, point: .beforeFileSync)
            guard Darwin.fsync(handle.fileDescriptor) == 0 else {
                throw AttachmentUploadV2Error.storageFailure(
                    "durable file sync failed"
                )
            }
            try emitDurabilityEvent(kind: kind, point: .fileSynced)
            try handle.close()
            handleIsOpen = false
        } catch let error as AttachmentUploadV2Error {
            throw error
        } catch {
            throw AttachmentUploadV2Error.storageFailure(
                "durable temporary file write failed"
            )
        }

        try emitDurabilityEvent(kind: kind, point: .beforeAtomicRename)
        let renameResult = temporary.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw AttachmentUploadV2Error.storageFailure(
                "durable atomic rename failed"
            )
        }
        try emitDurabilityEvent(kind: kind, point: .atomicRenameCompleted)
        try synchronizeDirectory(parent)
        try emitDurabilityEvent(kind: kind, point: .parentDirectorySynced)
    }

    private func synchronizeCommittedAttachment(
        _ attachment: AgentAttachment
    ) throws {
        try synchronizeExistingFileAndParent(
            at: URL(fileURLWithPath: attachment.path),
            kind: .finalAttachment
        )
        guard let referenceID = attachment.id?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              !referenceID.isEmpty else {
            throw AttachmentUploadV2Error.storageFailure(
                "missing attachment metadata identity"
            )
        }
        try synchronizeExistingFileAndParent(
            at: attachmentStore.root
                .appendingPathComponent(".metadata", isDirectory: true)
                .appendingPathComponent("\(referenceID).json", isDirectory: false),
            kind: .finalMetadata
        )
    }

    private func synchronizeExistingFileAndParent(
        at url: URL,
        kind: AttachmentUploadV2DurabilityKind
    ) throws {
        try emitDurabilityEvent(kind: kind, point: .beforeFileSync)
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw AttachmentUploadV2Error.storageFailure(
                "durable file reopen failed"
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw AttachmentUploadV2Error.storageFailure(
                "durable existing file sync failed"
            )
        }
        try emitDurabilityEvent(kind: kind, point: .fileSynced)
        try synchronizeDirectory(url.deletingLastPathComponent())
        try emitDurabilityEvent(kind: kind, point: .parentDirectorySynced)
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw AttachmentUploadV2Error.storageFailure(
                "durable directory reopen failed"
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw AttachmentUploadV2Error.storageFailure(
                "durable directory sync failed"
            )
        }
    }

    private func emitDurabilityEvent(
        kind: AttachmentUploadV2DurabilityKind,
        point: AttachmentUploadV2DurabilityPoint
    ) throws {
        do {
            try durabilityHook(
                AttachmentUploadV2DurabilityEvent(kind: kind, point: point)
            )
        } catch let error as AttachmentUploadV2Error {
            throw error
        } catch {
            throw AttachmentUploadV2Error.storageFailure(
                "injected durability barrier failed"
            )
        }
    }

    private func removeIntermediateFiles(in jobDir: URL) throws {
        for url in [
            chunksDirectory(in: jobDir),
            jobDir.appendingPathComponent("assembled.tmp", isDirectory: false),
        ] where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw AttachmentUploadV2Error.storageFailure("intermediate cleanup failed")
            }
        }
    }

    /// Cancels stale receiving manifests before admission/status accounting.
    /// The compact deny record is persisted first so a crash can leak bytes but
    /// cannot make a cancelled upload resumable.
    private func expireAbandonedReceivingJobs() throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        let cutoff = now().timeIntervalSince1970 - AttachmentUploadV2Policy.receivingJobTTL
        let ownerDirs = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for ownerDir in ownerDirs {
            let jobs = (try? fileManager.contentsOfDirectory(
                at: ownerDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for jobDir in jobs {
                let url = manifestURL(in: jobDir)
                guard let data = try? Data(contentsOf: url),
                      var manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                      manifest.phase == .receiving,
                      manifest.updatedAtEpochSeconds <= cutoff else {
                    continue
                }
                let cancelledAt = now().timeIntervalSince1970
                try persistCancellationDenyRecord(
                    owner: manifest.ownerFingerprint,
                    uploadId: manifest.uploadId,
                    workspaceId: manifest.workspaceId,
                    cancelledAtEpochSeconds: cancelledAt
                )
                manifest.phase = .cancelled
                manifest.receivedChunks = [:]
                manifest.updatedAtEpochSeconds = cancelledAt
                try persistManifest(manifest, in: jobDir)
                try? removeIntermediateFiles(in: jobDir)
            }
        }
        try pruneTerminalJobs(reservingSlotFor: nil)
    }

    private struct TerminalJob {
        let owner: String
        let uploadId: String
        let directory: URL
        let updatedAtEpochSeconds: TimeInterval
        let cancellationWorkspaceId: String?
    }

    private func pruneTerminalJobs(reservingSlotFor owner: String?) throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        let cutoff = now().timeIntervalSince1970 - AttachmentUploadV2Policy.terminalJobTTL
        let ownerDirectories = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var jobsByOwner: [String: [TerminalJob]] = [:]
        for ownerDirectory in ownerDirectories {
            let jobs = (try? fileManager.contentsOfDirectory(
                at: ownerDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for jobDirectory in jobs {
                let terminalJob: TerminalJob?
                let manifestURL = manifestURL(in: jobDirectory)
                if let data = try? Data(contentsOf: manifestURL),
                   let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                   manifest.phase != .receiving {
                    terminalJob = TerminalJob(
                        owner: manifest.ownerFingerprint,
                        uploadId: manifest.uploadId,
                        directory: jobDirectory,
                        updatedAtEpochSeconds: manifest.updatedAtEpochSeconds,
                        cancellationWorkspaceId: manifest.phase == .cancelled
                            ? manifest.workspaceId
                            : nil
                    )
                } else {
                    let tombstoneURL = jobDirectory
                        .appendingPathComponent("cancelled.json", isDirectory: false)
                    if let data = try? Data(contentsOf: tombstoneURL),
                       let tombstone = try? JSONDecoder().decode(
                           CancellationTombstone.self,
                           from: data
                       ) {
                        terminalJob = TerminalJob(
                            owner: tombstone.ownerFingerprint,
                            uploadId: tombstone.uploadId,
                            directory: jobDirectory,
                            updatedAtEpochSeconds: tombstone.updatedAtEpochSeconds,
                            cancellationWorkspaceId: tombstone.workspaceId
                        )
                    } else {
                        terminalJob = nil
                    }
                }
                guard let terminalJob else {
                    continue
                }
                if terminalJob.updatedAtEpochSeconds <= cutoff {
                    try removeTerminalJob(terminalJob)
                    continue
                }
                jobsByOwner[terminalJob.owner, default: []].append(terminalJob)
            }
        }

        var retained: [TerminalJob] = []
        for (jobOwner, jobs) in jobsByOwner {
            let reserved = jobOwner == owner ? 1 : 0
            let limit = max(
                0,
                AttachmentUploadV2Policy.maximumTerminalJobsPerOwner - reserved
            )
            let newestFirst = jobs.sorted {
                $0.updatedAtEpochSeconds > $1.updatedAtEpochSeconds
            }
            retained.append(contentsOf: newestFirst.prefix(limit))
            for stale in newestFirst.dropFirst(limit) {
                try removeTerminalJob(stale)
            }
        }

        let globallyNewestFirst = retained.sorted {
            $0.updatedAtEpochSeconds > $1.updatedAtEpochSeconds
        }
        let globalLimit = max(
            0,
            AttachmentUploadV2Policy.maximumGlobalTerminalJobs - (owner == nil ? 0 : 1)
        )
        for stale in globallyNewestFirst.dropFirst(globalLimit) {
            try removeTerminalJob(stale)
        }
    }

    private func removeTerminalJob(_ job: TerminalJob) throws {
        if let workspaceId = job.cancellationWorkspaceId {
            // Preserve the cancellation decision outside normal terminal caps
            // before deleting the larger manifest/tombstone and owner binding.
            try persistCancellationDenyRecord(
                owner: job.owner,
                uploadId: job.uploadId,
                workspaceId: workspaceId,
                cancelledAtEpochSeconds: job.updatedAtEpochSeconds
            )
        }
        if fileManager.fileExists(atPath: job.directory.path) {
            do {
                try fileManager.removeItem(at: job.directory)
            } catch {
                throw AttachmentUploadV2Error.storageFailure(
                    "terminal upload cleanup failed"
                )
            }
        }
        try removeOwnerBinding(uploadId: job.uploadId)
        let ownerDirectory = job.directory.deletingLastPathComponent()
        if let contents = try? fileManager.contentsOfDirectory(
            atPath: ownerDirectory.path
        ), contents.isEmpty {
            try? fileManager.removeItem(at: ownerDirectory)
        }
    }

    private func applyDirectoryPermissions(_ url: URL) throws {
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Counts one authenticated owner's receiving jobs and reserved bytes.
    private func scanReceivingBudget(owner: String) throws -> (active: Int, reserved: Int) {
        let ownerDirectory = root.appendingPathComponent(owner, isDirectory: true)
        guard fileManager.fileExists(atPath: ownerDirectory.path) else { return (0, 0) }
        var active = 0
        var reserved = 0
        let jobs = (try? fileManager.contentsOfDirectory(
            at: ownerDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for job in jobs {
            let manifestURL = job.appendingPathComponent("manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                  manifest.ownerFingerprint == owner,
                  manifest.phase == .receiving else { continue }
            active += 1
            reserved += manifest.sizeBytes
        }
        return (active, reserved)
    }

    private func scanGlobalReceivingBudget() throws -> (active: Int, reserved: Int) {
        guard fileManager.fileExists(atPath: root.path) else { return (0, 0) }
        var active = 0
        var reserved = 0
        let ownerDirectories = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for ownerDirectory in ownerDirectories {
            let jobs = (try? fileManager.contentsOfDirectory(
                at: ownerDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for job in jobs {
                let manifestURL = job.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                      manifest.phase == .receiving else {
                    continue
                }
                active += 1
                reserved += manifest.sizeBytes
            }
        }
        return (active, reserved)
    }

    private func ensureOwner(_ manifest: Manifest, owner: String) throws {
        guard manifest.ownerFingerprint == owner else {
            throw AttachmentUploadV2Error.ownerMismatch
        }
    }

    private func ensureMetadataMatch(
        _ manifest: Manifest,
        workspaceId: String,
        filename: String,
        mimeType: String?,
        sizeBytes: Int,
        sha256: String,
        kind: AgentAttachmentKind
    ) throws {
        guard manifest.workspaceId == workspaceId,
              manifest.filename == filename,
              manifest.mimeType == mimeType,
              manifest.sizeBytes == sizeBytes,
              manifest.sha256 == sha256,
              manifest.kind == kind,
              manifest.chunkBytes == AttachmentUploadV2Policy.rawChunkBytes,
              manifest.protocolVersion == AttachmentUploadV2Policy.protocolVersion else {
            throw AttachmentUploadV2Error.metadataConflict
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try AttachmentUploadV2Synchronization.withLock(root: root, body)
    }

    // MARK: Validation helpers

    private static func validatedUploadId(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: trimmed) != nil else {
            throw AttachmentUploadV2Error.invalidParams("uploadId must be a UUID")
        }
        return trimmed
    }

    private static func validatedWorkspaceId(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: trimmed) != nil else {
            throw AttachmentUploadV2Error.invalidParams("workspaceId must be a UUID")
        }
        return trimmed
    }

    private static func validatedOwnerFingerprint(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 64,
              trimmed.allSatisfy(\.isHexDigit) else {
            throw AttachmentUploadV2Error.invalidParams("ownerFingerprint")
        }
        return trimmed.lowercased()
    }

    private static func validatedFilename(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              trimmed == URL(fileURLWithPath: trimmed).lastPathComponent,
              !trimmed.contains("\0"),
              trimmed.utf8.count <= AttachmentUploadV2Policy.maximumFilenameBytes else {
            throw AttachmentUploadV2Error.invalidParams("filename")
        }
        return trimmed
    }

    private static func validatedMIMEType(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let normalized = raw.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty,
              normalized.utf8.count <= AttachmentUploadV2Policy.maximumMIMETypeBytes,
              normalized.range(
                of: #"^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$"#,
                options: .regularExpression
              ) != nil else {
            throw AttachmentUploadV2Error.invalidParams("mimeType")
        }
        return normalized
    }

    private static func validatedDigest(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else {
            throw AttachmentUploadV2Error.invalidParams("sha256")
        }
        return normalized
    }

    private static func kind(filename: String, mimeType: String?) -> AgentAttachmentKind {
        if let mimeType, mimeType.hasPrefix("image/") { return .image }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp", "svg", "avif"
        ]
        return imageExtensions.contains(ext) ? .image : .file
    }

    /// PERF: nibble table instead of per-byte `String(format:)` so chunk /
    /// stream digest finalize avoids 32 formatter calls while keeping the same
    /// CryptoKit lowercase hex contract.
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

    private static func digest(_ data: Data) -> String {
        hexDigest(SHA256.hash(data: data))
    }

    private static func streamDigest(at url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AttachmentUploadV2Error.storageFailure("chunk read failed")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data: Data
            do {
                data = try handle.read(upToCount: 128 * 1_024) ?? Data()
            } catch {
                throw AttachmentUploadV2Error.storageFailure("chunk read failed")
            }
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hexDigest(hasher.finalize())
    }

    /// Stable host reference for crash-safe finalize retries. Owner scoping
    /// prevents two paired devices choosing the same upload UUID from sharing
    /// metadata.
    private static func referenceID(
        ownerFingerprint: String,
        uploadId: String
    ) -> String {
        var bytes = Array(SHA256.hash(
            data: Data("rc2.attachment-upload.v2:\(ownerFingerprint):\(uploadId)".utf8)
        ).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = hexDigest(bytes)
        let ranges = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        let segments = ranges.map { range -> String in
            let start = hex.index(hex.startIndex, offsetBy: range.lowerBound)
            let end = hex.index(hex.startIndex, offsetBy: range.upperBound)
            return String(hex[start..<end])
        }
        return segments.joined(separator: "-")
    }
}
