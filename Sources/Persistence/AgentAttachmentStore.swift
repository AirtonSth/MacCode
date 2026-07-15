import CryptoKit
import Foundation
import CoreModel

/// Process-wide exclusion for the attachment root. Staging, validation, and GC
/// use the same lock so a reused digest is repaired/refreshed before cleanup can
/// make a deletion decision.
enum AgentAttachmentStorageSynchronization {
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

public final class AgentAttachmentStore: @unchecked Sendable {
    public static let maximumSizeBytes = 25 * 1024 * 1024

    private struct Metadata: Codable, Equatable {
        /// Absent only for legacy digest-keyed sidecars written before attachment
        /// references received their own opaque identity.
        let digest: String?
        let displayName: String
        let kind: AgentAttachmentKind
        let mimeType: String?
    }

    public let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
    }

    public func stage(paths: [String]) throws -> [AgentAttachment] {
        try paths.map(stage(path:))
    }

    public func stage(path: String) throws -> AgentAttachment {
        let source = try AgentAttachmentResolver.resolve(paths: [path], fileManager: fileManager)[0]
        let sourceURL = URL(fileURLWithPath: source.path)
        let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path)
        if let size = (attributes?[.size] as? NSNumber)?.int64Value,
           size > Int64(Self.maximumSizeBytes) {
            throw AgentAttachmentResolverError.exceedsMaximumSize(
                source.displayName,
                Self.maximumSizeBytes
            )
        }
        guard let data = try? Data(contentsOf: sourceURL, options: .mappedIfSafe) else {
            throw AgentAttachmentResolverError.notReadableFile(path)
        }
        return try stage(
            data: data,
            displayName: source.displayName,
            kind: source.kind,
            mimeType: source.mimeType
        )
    }

    /// Stages uploaded bytes directly into host-owned content-addressed storage.
    /// No workspace or client path is ever needed or returned.
    public func stage(
        data: Data,
        displayName: String,
        kind: AgentAttachmentKind,
        mimeType: String?
    ) throws -> AgentAttachment {
        guard !data.isEmpty else {
            throw AgentAttachmentResolverError.malformedReference("empty attachment data")
        }
        guard data.count <= Self.maximumSizeBytes else {
            throw AgentAttachmentResolverError.exceedsMaximumSize(
                displayName,
                Self.maximumSizeBytes
            )
        }
        let safeName = try Self.validatedDisplayName(displayName)
        let normalizedMIME = try Self.validatedMIMEType(mimeType)
            ?? (kind == .file ? "application/octet-stream" : nil)
        let digest = Self.digest(data)
        let referenceID = UUID().uuidString.lowercased()

        return try AgentAttachmentStorageSynchronization.withLock(root: root) {
            try prepareDirectories()
            let storedURL = blobURL(digest: digest)
            let existingData = try? Data(contentsOf: storedURL, options: .mappedIfSafe)
            if existingData.map(Self.digest) != digest {
                try data.write(to: storedURL, options: .atomic)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600, .modificationDate: Date()],
                ofItemAtPath: storedURL.path
            )

            let metadata = Metadata(
                digest: digest,
                displayName: safeName,
                kind: kind,
                mimeType: normalizedMIME
            )
            try persistMetadata(metadata, referenceID: referenceID)
            return AgentAttachment(
                id: referenceID,
                path: storedURL.path,
                displayName: metadata.displayName,
                kind: metadata.kind,
                mimeType: metadata.mimeType,
                sha256: digest,
                sizeBytes: data.count
            )
        }
    }

    /// Resolves an opaque client id back to host-owned provider metadata. The
    /// client never chooses a host path. Optional metadata is accepted only for
    /// upgrading a legacy digest that predates the metadata sidecar.
    public func resolveClientReference(_ reference: AgentAttachment) throws -> AgentAttachment {
        guard reference.path.isEmpty,
              let rawID = reference.id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              Self.isDigest(rawID) || Self.isReferenceID(rawID) else {
            throw AgentAttachmentResolverError.malformedReference(reference.id ?? "missing id")
        }
        return try AgentAttachmentStorageSynchronization.withLock(root: root) {
            let metadata: Metadata
            let digest: String
            if Self.isDigest(rawID) {
                // Legacy references used the blob digest as the public id. Keep
                // resolving them across upgrades without allowing a client path.
                digest = rawID
                if let stored = try loadMetadata(referenceID: rawID) {
                    metadata = stored
                } else {
                    metadata = Metadata(
                        digest: nil,
                        displayName: try Self.validatedDisplayName(reference.displayName),
                        kind: reference.kind,
                        mimeType: try Self.validatedMIMEType(reference.mimeType)
                    )
                    try prepareDirectories()
                    try persistMetadata(metadata, referenceID: rawID)
                }
            } else {
                guard let stored = try loadMetadata(referenceID: rawID),
                      let storedDigest = stored.digest?.lowercased(),
                      Self.isDigest(storedDigest) else {
                    throw AgentAttachmentResolverError.malformedReference("unknown host attachment reference")
                }
                metadata = stored
                digest = storedDigest
            }

            let storedURL = blobURL(digest: digest)
            guard fileManager.isReadableFile(atPath: storedURL.path),
                  let data = try? Data(contentsOf: storedURL, options: .mappedIfSafe),
                  Self.digest(data) == digest else {
                throw AgentAttachmentResolverError.notReadableFile(reference.displayName.isEmpty ? rawID : reference.displayName)
            }
            if let expected = reference.sha256, expected.lowercased() != digest {
                throw AgentAttachmentResolverError.malformedReference("hash does not match stored bytes")
            }
            if let expected = reference.sizeBytes, expected != data.count {
                throw AgentAttachmentResolverError.malformedReference("size does not match stored bytes")
            }
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: storedURL.path)
            try? fileManager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: metadataURL(referenceID: rawID).path
            )
            return AgentAttachment(
                id: rawID,
                path: storedURL.path,
                displayName: metadata.displayName,
                kind: metadata.kind,
                mimeType: metadata.mimeType,
                sha256: digest,
                sizeBytes: data.count
            )
        }
    }

    /// Revalidates a persisted attachment before a retry. Only immutable blobs
    /// inside this store with matching size and SHA-256 may be sent again.
    public func validatedForRetry(_ attachment: AgentAttachment) throws -> AgentAttachment {
        try AgentAttachmentStorageSynchronization.withLock(root: root) {
            let candidate = URL(fileURLWithPath: attachment.path).standardizedFileURL.resolvingSymlinksInPath()
            let managedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            let prefix = managedRoot.path.hasSuffix("/") ? managedRoot.path : managedRoot.path + "/"
            guard candidate.path.hasPrefix(prefix),
                  candidate.deletingLastPathComponent().path == managedRoot.path,
                  fileManager.isReadableFile(atPath: candidate.path),
                  let data = try? Data(contentsOf: candidate, options: .mappedIfSafe) else {
                throw AgentAttachmentResolverError.notReadableFile(attachment.displayName)
            }
            let digest = Self.digest(data)
            let rawReferenceID = attachment.id?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let metadata: Metadata?
            if let rawReferenceID, Self.isReferenceID(rawReferenceID) {
                guard let stored = try loadMetadata(referenceID: rawReferenceID),
                      let storedDigest = stored.digest?.lowercased(),
                      Self.isDigest(storedDigest) else {
                    throw AgentAttachmentResolverError.malformedReference("unknown host attachment reference")
                }
                metadata = stored
            } else {
                metadata = nil
            }
            let metadataDigest = metadata?.digest?.lowercased()
            let expectedDigest = attachment.sha256?.lowercased()
                ?? metadataDigest
                ?? rawReferenceID.flatMap { Self.isDigest($0) ? $0 : nil }
            guard expectedDigest?.lowercased() == digest,
                  metadataDigest == nil || metadataDigest == digest,
                  attachment.sizeBytes == nil || attachment.sizeBytes == data.count else {
                throw AgentAttachmentResolverError.notReadableFile(attachment.displayName)
            }
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: candidate.path)
            if let rawReferenceID, metadata != nil {
                try? fileManager.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: metadataURL(referenceID: rawReferenceID).path
                )
            }
            return AgentAttachment(
                id: rawReferenceID ?? digest,
                path: candidate.path,
                displayName: metadata?.displayName ?? attachment.displayName,
                kind: metadata?.kind ?? attachment.kind,
                mimeType: metadata?.mimeType ?? attachment.mimeType,
                sha256: digest,
                sizeBytes: data.count
            )
        }
    }

    private var metadataRoot: URL {
        root.appendingPathComponent(".metadata", isDirectory: true)
    }

    private func blobURL(digest: String) -> URL {
        root.appendingPathComponent(digest, isDirectory: false)
    }

    private func metadataURL(referenceID: String) -> URL {
        metadataRoot.appendingPathComponent("\(referenceID).json", isDirectory: false)
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: metadataRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func loadMetadata(referenceID: String) throws -> Metadata? {
        let url = metadataURL(referenceID: referenceID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: url))
        } catch {
            throw AgentAttachmentResolverError.malformedReference("corrupt host attachment metadata")
        }
    }

    private func persistMetadata(_ metadata: Metadata, referenceID: String) throws {
        let data = try JSONEncoder().encode(metadata)
        let url = metadataURL(referenceID: referenceID)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    static func isReferenceID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private static func validatedDisplayName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == URL(fileURLWithPath: trimmed).lastPathComponent,
              !trimmed.contains("\0"),
              trimmed.count <= 255 else {
            throw AgentAttachmentResolverError.malformedReference("invalid display name")
        }
        return trimmed
    }

    private static func validatedMIMEType(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let normalized = raw.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty,
              normalized.range(of: #"^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$"#, options: .regularExpression) != nil else {
            throw AgentAttachmentResolverError.malformedReference("invalid media type")
        }
        return normalized
    }
}
