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
    // PERF: stage/resolve/GC load and rewrite .metadata sidecars with a fresh
    // JSONDecoder/JSONEncoder per call. Public API already serializes per-root
    // via AgentAttachmentStorageSynchronization.withLock, so one pair is safe.
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

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
        return try stageFile(
            at: sourceURL,
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

    /// Stages a file by streaming bounded reads so large payloads (up to 25 MiB)
    /// never need a contiguous in-memory buffer. Optional expected digest/size
    /// fail closed when the on-disk bytes disagree.
    public func stageFile(
        at sourceURL: URL,
        displayName: String,
        kind: AgentAttachmentKind,
        mimeType: String?,
        expectedSHA256: String? = nil,
        expectedSizeBytes: Int? = nil,
        referenceID: String? = nil,
        consumeSource: Bool = false
    ) throws -> AgentAttachment {
        let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path)
        guard let sizeNumber = attributes?[.size] as? NSNumber else {
            throw AgentAttachmentResolverError.notReadableFile(sourceURL.path)
        }
        let size = sizeNumber.int64Value
        guard size > 0 else {
            throw AgentAttachmentResolverError.malformedReference("empty attachment data")
        }
        guard size <= Int64(Self.maximumSizeBytes) else {
            throw AgentAttachmentResolverError.exceedsMaximumSize(
                displayName,
                Self.maximumSizeBytes
            )
        }
        if let expectedSizeBytes, Int64(expectedSizeBytes) != size {
            throw AgentAttachmentResolverError.malformedReference("size does not match staged file")
        }
        let safeName = try Self.validatedDisplayName(displayName)
        let normalizedMIME = try Self.validatedMIMEType(mimeType)
            ?? (kind == .file ? "application/octet-stream" : nil)
        let sizeBytes = Int(size)
        let stableReferenceID: String
        if let referenceID {
            let normalized = referenceID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard Self.isReferenceID(normalized) else {
                throw AgentAttachmentResolverError.malformedReference("invalid attachment reference id")
            }
            stableReferenceID = normalized
        } else {
            stableReferenceID = UUID().uuidString.lowercased()
        }

        return try AgentAttachmentStorageSynchronization.withLock(root: root) {
            try prepareDirectories()
            let stagedURL: URL
            let temporaryURL: URL?
            let digest: String
            if consumeSource {
                stagedURL = sourceURL
                temporaryURL = nil
                digest = try Self.streamDigest(at: sourceURL)
            } else {
                let tempURL = root.appendingPathComponent(
                    ".stage-\(UUID().uuidString.lowercased()).tmp",
                    isDirectory: false
                )
                stagedURL = tempURL
                temporaryURL = tempURL
                digest = try Self.streamCopyAndDigest(
                    from: sourceURL,
                    to: tempURL,
                    fileManager: fileManager
                )
            }
            defer {
                if let temporaryURL {
                    try? fileManager.removeItem(at: temporaryURL)
                }
            }
            let stagedAttributes = try? fileManager.attributesOfItem(
                atPath: stagedURL.path
            )
            guard let stagedSize = (stagedAttributes?[.size] as? NSNumber)?.int64Value,
                  stagedSize == size else {
                throw AgentAttachmentResolverError.malformedReference(
                    "size changed while staging file"
                )
            }
            if let expectedSHA256 {
                let expected = expectedSHA256
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard Self.isDigest(expected), expected == digest else {
                    throw AgentAttachmentResolverError.malformedReference(
                        "hash does not match staged file"
                    )
                }
            }

            let storedURL = blobURL(digest: digest)
            let stagedPath = stagedURL.standardizedFileURL.resolvingSymlinksInPath().path
            let storedPath = storedURL.standardizedFileURL.resolvingSymlinksInPath().path
            if fileManager.fileExists(atPath: storedURL.path),
               (try? Self.streamDigest(at: storedURL)) == digest {
                if stagedPath != storedPath {
                    try? fileManager.removeItem(at: stagedURL)
                }
            } else {
                if fileManager.fileExists(atPath: storedURL.path) {
                    try fileManager.removeItem(at: storedURL)
                }
                if stagedPath != storedPath {
                    try fileManager.moveItem(at: stagedURL, to: storedURL)
                }
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
            if let existingMetadata = try loadMetadata(referenceID: stableReferenceID) {
                guard existingMetadata == metadata else {
                    throw AgentAttachmentResolverError.malformedReference(
                        "attachment reference metadata conflict"
                    )
                }
            } else {
                try persistMetadata(metadata, referenceID: stableReferenceID)
            }
            return AgentAttachment(
                id: stableReferenceID,
                path: storedURL.path,
                displayName: metadata.displayName,
                kind: metadata.kind,
                mimeType: metadata.mimeType,
                sha256: digest,
                sizeBytes: sizeBytes
            )
        }
    }

    /// Creates the same human-readable hardlink used by macOS drag/drop so a
    /// paired client can insert a recognizable host path without copying bytes.
    public func composerInsertionPath(
        for attachment: AgentAttachment
    ) throws -> String {
        let name = try Self.validatedDisplayName(attachment.displayName)
        guard let rawID = attachment.id?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              Self.isReferenceID(rawID) || Self.isDigest(rawID),
              let digest = attachment.sha256?.lowercased(),
              Self.isDigest(digest) else {
            throw AgentAttachmentResolverError.malformedReference(
                "incomplete attachment metadata"
            )
        }
        let source = URL(fileURLWithPath: attachment.path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let managedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard source.deletingLastPathComponent().path == managedRoot.path,
              source.lastPathComponent == digest,
              fileManager.isReadableFile(atPath: source.path) else {
            throw AgentAttachmentResolverError.notReadableFile(name)
        }

        return try AgentAttachmentStorageSynchronization.withLock(root: root) {
            try prepareDirectories()
            let linkRoot = root
                .appendingPathComponent("composer-paths", isDirectory: true)
                .appendingPathComponent(rawID, isDirectory: true)
            try fileManager.createDirectory(
                at: linkRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: linkRoot.path
            )
            let link = linkRoot.appendingPathComponent(name, isDirectory: false)
            if !fileManager.fileExists(atPath: link.path) {
                try fileManager.linkItem(at: source, to: link)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: link.path
                )
            }
            return link.path
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

    /// Reads a persisted attachment's bytes for a paired client, without
    /// touching GC dates. Only a blob stored directly in this store (symlinks
    /// resolved) whose bytes still match the recorded SHA-256 and size is
    /// returned; anything else throws `notReadableFile`.
    public func containedData(for attachment: AgentAttachment) throws -> Data {
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
            // The blob name is its digest; a recorded sha256 must agree with both.
            guard candidate.lastPathComponent == digest,
                  attachment.sha256 == nil || attachment.sha256?.lowercased() == digest,
                  attachment.sizeBytes == nil || attachment.sizeBytes == data.count else {
                throw AgentAttachmentResolverError.notReadableFile(attachment.displayName)
            }
            return data
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
            return try decoder.decode(Metadata.self, from: Data(contentsOf: url, options: .mappedIfSafe))
        } catch {
            throw AgentAttachmentResolverError.malformedReference("corrupt host attachment metadata")
        }
    }

    private func persistMetadata(_ metadata: Metadata, referenceID: String) throws {
        let data = try encoder.encode(metadata)
        let url = metadataURL(referenceID: referenceID)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Lowercase SHA-256 hex for attachment CAS / blob names.
    ///
    /// PERF: nibble table instead of per-byte `String(format:)` so stage /
    /// resolve / verify digests avoid 32 formatter calls while keeping the same
    /// CryptoKit lowercase hex contract.
    private static func digest(_ data: Data) -> String {
        hexDigest(SHA256.hash(data: data))
    }

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

    /// Streams `source` into `destination` in 1 MiB windows while hashing.
    private static func streamCopyAndDigest(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws -> String {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw AgentAttachmentResolverError.notReadableFile(source.path)
        }
        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: source)
        } catch {
            throw AgentAttachmentResolverError.notReadableFile(source.path)
        }
        defer { try? reader.close() }
        let writer: FileHandle
        do {
            writer = try FileHandle(forWritingTo: destination)
        } catch {
            throw AgentAttachmentResolverError.notReadableFile(destination.path)
        }
        defer { try? writer.close() }
        var hasher = SHA256()
        let window = 1_024 * 1_024
        while true {
            let chunk: Data
            do {
                chunk = try reader.read(upToCount: window) ?? Data()
            } catch {
                throw AgentAttachmentResolverError.notReadableFile(source.path)
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            do {
                try writer.write(contentsOf: chunk)
            } catch {
                throw AgentAttachmentResolverError.notReadableFile(destination.path)
            }
        }
        return hexDigest(hasher.finalize())
    }

    private static func streamDigest(at source: URL) throws -> String {
        let reader: FileHandle
        do {
            reader = try FileHandle(forReadingFrom: source)
        } catch {
            throw AgentAttachmentResolverError.notReadableFile(source.path)
        }
        defer { try? reader.close() }
        var hasher = SHA256()
        let window = 1_024 * 1_024
        while true {
            let chunk: Data
            do {
                chunk = try reader.read(upToCount: window) ?? Data()
            } catch {
                throw AgentAttachmentResolverError.notReadableFile(source.path)
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hexDigest(hasher.finalize())
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
              trimmed != ".",
              trimmed != "..",
              trimmed == URL(fileURLWithPath: trimmed).lastPathComponent,
              !trimmed.contains("\0"),
              trimmed.utf8.count <= 255 else {
            throw AgentAttachmentResolverError.malformedReference("invalid display name")
        }
        return trimmed
    }

    // PERF: compile once — was recompiled via range(of:options:.regularExpression)
    // on every attachment stage/resolve/validate media-type check.
    private static let mimeTypeRegex = try! NSRegularExpression(
        pattern: #"^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$"#
    )

    private static func validatedMIMEType(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let normalized = raw.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let full = NSRange(location: 0, length: (normalized as NSString).length)
        guard !normalized.isEmpty,
              mimeTypeRegex.firstMatch(in: normalized, options: [], range: full) != nil else {
            throw AgentAttachmentResolverError.malformedReference("invalid media type")
        }
        return normalized
    }
}
