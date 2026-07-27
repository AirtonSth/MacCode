import CryptoKit
import Foundation

/// Capability advertised on welcome when the host supports resumable HTTP
/// snapshot chunks. Opt-in only — legacy clients keep calling `sync.snapshot`.
public enum SnapshotChunkCapability {
    public static let wireName = "snapshot.chunks.v1"
    public static let digestAlgorithm = "sha256"
}

/// Bounded negotiated chunk size. Clients may send `preferredChunkBytes`; the
/// host clamps. Named seam for later measured-quality adaptation on the host.
public enum SnapshotChunkSizePolicy {
    public static let minimumBytes = 8_192
    public static let maximumBytes = 256 * 1_024
    public static let defaultBytes = 64 * 1_024
    /// Hard ceiling on assembled frame bytes (matches transport frame limit).
    public static let maximumTotalBytes = ConnectionTransportFrame.maximumEncodedBytes
    public static let maximumChunkCount = 128
    /// Process-wide cache budget so concurrent transfers cannot unbounded-grow.
    public static let maximumCachedTransfers = 8
    public static let maximumCachedBytes = 8 * 1_024 * 1_024
    public static let defaultTTLNanoseconds: UInt64 = 120_000_000_000

    public static func negotiate(preferredChunkBytes: Int?) -> Int {
        let preferred = preferredChunkBytes ?? defaultBytes
        return min(maximumBytes, max(minimumBytes, preferred))
    }

    public static func chunkCount(totalBytes: Int, chunkBytes: Int) -> Int {
        guard totalBytes > 0, chunkBytes > 0 else { return 0 }
        return (totalBytes + chunkBytes - 1) / chunkBytes
    }
}

/// Manifest returned by `sync.snapshot.begin`. Intentionally omits bearer
/// tokens, host secrets, and arbitrary request payloads.
public struct SnapshotChunkManifest: Equatable, Sendable {
    public let transferId: String
    public let snapshotId: String
    public let connectionId: String
    public let hostId: String
    public let bootEpoch: UInt64
    public let sequence: Int64
    public let generatedAtEpochMs: Int64
    public let stateVersion: Int
    public let totalBytes: Int
    public let chunkCount: Int
    public let chunkBytes: Int
    public let digestAlgorithm: String
    public let digest: String

    public var jsonObject: [String: Any] {
        [
            "transferId": transferId,
            "snapshotId": snapshotId,
            "connectionId": connectionId,
            "hostId": hostId,
            "bootEpoch": NSNumber(value: bootEpoch),
            "sequence": NSNumber(value: sequence),
            "generatedAtEpochMs": NSNumber(value: generatedAtEpochMs),
            "stateVersion": stateVersion,
            "totalBytes": totalBytes,
            "chunkCount": chunkCount,
            "chunkBytes": chunkBytes,
            "digestAlgorithm": digestAlgorithm,
            "digest": digest,
        ]
    }
}

public struct SnapshotChunkResponse: Equatable, Sendable {
    public let transferId: String
    public let chunkIndex: Int
    public let byteOffset: Int
    public let byteCount: Int
    public let payloadBase64: String

    public var jsonObject: [String: Any] {
        [
            "transferId": transferId,
            "chunkIndex": chunkIndex,
            "byteOffset": byteOffset,
            "byteCount": byteCount,
            "payloadBase64": payloadBase64,
        ]
    }
}

public enum SnapshotChunkTransferFailure: Error, Equatable {
    case invalidParams
    case transferUnknown
    case transferExpired
    case identityMismatch
    case commitMismatch
    case chunkOutOfRange
    case payloadTooLarge
    case cachePressure
}

/// Result of inserting a transfer: the new record plus any prior transfers
/// removed for TTL/memory pressure (callers must cancel their watermark reservations).
struct SnapshotChunkInsertResult: Sendable {
    let record: SnapshotChunkTransferRecord
    let releasedReservations: [SnapshotChunkTransferRecord]
}

/// Pure split/digest helpers — shared by production cache and unit tests.
public enum SnapshotChunkCodec {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func split(_ data: Data, chunkBytes: Int) -> [Data] {
        guard !data.isEmpty, chunkBytes > 0 else { return data.isEmpty ? [] : [data] }
        var chunks: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkBytes, data.count)
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }
}

/// One in-flight chunked snapshot bound to authenticated ownership.
struct SnapshotChunkTransferRecord: Sendable {
    let transferId: String
    let ownerFingerprint: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let snapshotId: String
    let sequence: Int64
    let generatedAtEpochMs: Int64
    let stateVersion: Int
    let frameBytes: Data
    let digest: String
    let chunkBytes: Int
    let chunks: [Data]
    let createdAtNanoseconds: UInt64
    let expiresAtNanoseconds: UInt64

    var totalBytes: Int { frameBytes.count }
    var chunkCount: Int { chunks.count }

    var manifest: SnapshotChunkManifest {
        SnapshotChunkManifest(
            transferId: transferId,
            snapshotId: snapshotId,
            connectionId: connectionId,
            hostId: hostId,
            bootEpoch: bootEpoch,
            sequence: sequence,
            generatedAtEpochMs: generatedAtEpochMs,
            stateVersion: stateVersion,
            totalBytes: totalBytes,
            chunkCount: chunkCount,
            chunkBytes: chunkBytes,
            digestAlgorithm: SnapshotChunkCapability.digestAlgorithm,
            digest: digest
        )
    }

    func chunkResponse(index: Int) throws -> SnapshotChunkResponse {
        guard chunks.indices.contains(index) else {
            throw SnapshotChunkTransferFailure.chunkOutOfRange
        }
        let payload = chunks[index]
        let offset = chunks.prefix(index).reduce(0) { $0 + $1.count }
        return SnapshotChunkResponse(
            transferId: transferId,
            chunkIndex: index,
            byteOffset: offset,
            byteCount: payload.count,
            payloadBase64: payload.base64EncodedString()
        )
    }
}

/// TTL + memory-bounded process cache for resumable snapshot chunks.
/// Cleanup is deterministic on insert, fetch, and explicit `evictExpired`.
public final class SnapshotChunkTransferCache: @unchecked Sendable {
    public typealias ClockNanoseconds = () -> UInt64

    private let lock = NSLock()
    private var transfers: [String: SnapshotChunkTransferRecord] = [:]
    private var totalCachedBytes = 0
    private let clock: ClockNanoseconds
    private let ttlNanoseconds: UInt64
    private let maxTransfers: Int
    private let maxCachedBytes: Int

    public init(
        clock: @escaping ClockNanoseconds = { DispatchTime.now().uptimeNanoseconds },
        ttlNanoseconds: UInt64 = SnapshotChunkSizePolicy.defaultTTLNanoseconds,
        maxTransfers: Int = SnapshotChunkSizePolicy.maximumCachedTransfers,
        maxCachedBytes: Int = SnapshotChunkSizePolicy.maximumCachedBytes
    ) {
        self.clock = clock
        self.ttlNanoseconds = ttlNanoseconds
        self.maxTransfers = max(1, maxTransfers)
        self.maxCachedBytes = max(SnapshotChunkSizePolicy.maximumTotalBytes, maxCachedBytes)
    }

    public var countForTests: Int {
        lock.lock(); defer { lock.unlock() }
        return transfers.count
    }

    public var cachedBytesForTests: Int {
        lock.lock(); defer { lock.unlock() }
        return totalCachedBytes
    }

    /// Insert a prepared frame. Returns the bound transfer plus any transfers
    /// dropped for TTL/memory pressure (caller cancels those watermark reservations).
    func insert(
        frameBytes: Data,
        ownerFingerprint: String,
        connectionId: String,
        hostId: String,
        bootEpoch: UInt64,
        snapshotId: String,
        sequence: Int64,
        generatedAtEpochMs: Int64,
        stateVersion: Int,
        preferredChunkBytes: Int?
    ) throws -> SnapshotChunkInsertResult {
        guard frameBytes.count > 0,
              frameBytes.count <= SnapshotChunkSizePolicy.maximumTotalBytes else {
            throw SnapshotChunkTransferFailure.payloadTooLarge
        }
        let chunkBytes = SnapshotChunkSizePolicy.negotiate(preferredChunkBytes: preferredChunkBytes)
        let chunks = SnapshotChunkCodec.split(frameBytes, chunkBytes: chunkBytes)
        guard chunks.count <= SnapshotChunkSizePolicy.maximumChunkCount else {
            throw SnapshotChunkTransferFailure.payloadTooLarge
        }
        let now = clock()
        let record = SnapshotChunkTransferRecord(
            transferId: UUID().uuidString,
            ownerFingerprint: ownerFingerprint,
            connectionId: connectionId,
            hostId: hostId,
            bootEpoch: bootEpoch,
            snapshotId: snapshotId,
            sequence: sequence,
            generatedAtEpochMs: generatedAtEpochMs,
            stateVersion: stateVersion,
            frameBytes: frameBytes,
            digest: SnapshotChunkCodec.sha256Hex(frameBytes),
            chunkBytes: chunkBytes,
            chunks: chunks,
            createdAtNanoseconds: now,
            expiresAtNanoseconds: now &+ ttlNanoseconds
        )
        lock.lock(); defer { lock.unlock() }
        var released: [SnapshotChunkTransferRecord] = []
        released.append(contentsOf: evictExpiredLocked(now: now))
        // Drop oldest until we fit this transfer.
        while transfers.count >= maxTransfers
            || totalCachedBytes + record.totalBytes > maxCachedBytes {
            guard let oldest = transfers.values.min(by: {
                $0.createdAtNanoseconds < $1.createdAtNanoseconds
            }) else { break }
            if let dropped = removeLocked(transferId: oldest.transferId) {
                released.append(dropped)
            }
        }
        if totalCachedBytes + record.totalBytes > maxCachedBytes {
            throw SnapshotChunkTransferFailure.cachePressure
        }
        transfers[record.transferId] = record
        totalCachedBytes += record.totalBytes
        return SnapshotChunkInsertResult(record: record, releasedReservations: released)
    }

    func fetchChunk(
        transferId: String,
        chunkIndex: Int,
        ownerFingerprint: String,
        connectionId: String,
        hostId: String,
        bootEpoch: UInt64
    ) throws -> SnapshotChunkResponse {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        // Resolve the requested transfer first so expiry is distinguishable from
        // unknown, then sweep other expired entries for deterministic cleanup.
        guard let record = transfers[transferId] else {
            _ = evictExpiredLocked(now: now)
            throw SnapshotChunkTransferFailure.transferUnknown
        }
        if now >= record.expiresAtNanoseconds {
            // Identity-check the expired record so only the rightful owner
            // surfaces transferExpired (and cancels their watermark reservation).
            let matches = record.ownerFingerprint == ownerFingerprint
                && record.connectionId == connectionId
                && record.hostId == hostId
                && record.bootEpoch == bootEpoch
            _ = removeLocked(transferId: transferId)
            _ = evictExpiredLocked(now: now)
            throw matches
                ? SnapshotChunkTransferFailure.transferExpired
                : SnapshotChunkTransferFailure.identityMismatch
        }
        _ = evictExpiredLocked(now: now)
        guard record.ownerFingerprint == ownerFingerprint,
              record.connectionId == connectionId,
              record.hostId == hostId,
              record.bootEpoch == bootEpoch else {
            throw SnapshotChunkTransferFailure.identityMismatch
        }
        // Re-read after sweep in case concurrent cleanup removed it (single-threaded
        // lock makes this a pure defensive re-check).
        guard let live = transfers[transferId] else {
            throw SnapshotChunkTransferFailure.transferUnknown
        }
        return try live.chunkResponse(index: chunkIndex)
    }

    /// Atomically validate + remove a transfer for `sync.snapshot.commit`.
    /// On success the caller must adopt the returned sequence exactly once.
    /// Mismatch leaves the transfer in place; expiry removes it.
    func takeForCommit(
        transferId: String,
        snapshotId: String,
        digest: String,
        ownerFingerprint: String,
        connectionId: String,
        hostId: String,
        bootEpoch: UInt64
    ) throws -> SnapshotChunkTransferRecord {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        guard let record = transfers[transferId] else {
            _ = evictExpiredLocked(now: now)
            throw SnapshotChunkTransferFailure.transferUnknown
        }
        if now >= record.expiresAtNanoseconds {
            let matches = record.ownerFingerprint == ownerFingerprint
                && record.connectionId == connectionId
                && record.hostId == hostId
                && record.bootEpoch == bootEpoch
            _ = removeLocked(transferId: transferId)
            _ = evictExpiredLocked(now: now)
            throw matches
                ? SnapshotChunkTransferFailure.transferExpired
                : SnapshotChunkTransferFailure.identityMismatch
        }
        guard record.ownerFingerprint == ownerFingerprint,
              record.connectionId == connectionId,
              record.hostId == hostId,
              record.bootEpoch == bootEpoch else {
            throw SnapshotChunkTransferFailure.identityMismatch
        }
        let normalizedDigest = digest.lowercased()
        guard record.snapshotId == snapshotId,
              record.digest == normalizedDigest else {
            throw SnapshotChunkTransferFailure.commitMismatch
        }
        guard let taken = removeLocked(transferId: transferId) else {
            throw SnapshotChunkTransferFailure.transferUnknown
        }
        return taken
    }

    @discardableResult
    func evictExpired() -> [SnapshotChunkTransferRecord] {
        lock.lock(); defer { lock.unlock() }
        return evictExpiredLocked(now: clock())
    }

    func removeAllForTests() {
        lock.lock(); defer { lock.unlock() }
        transfers.removeAll()
        totalCachedBytes = 0
    }

    @discardableResult
    private func evictExpiredLocked(now: UInt64) -> [SnapshotChunkTransferRecord] {
        let expired = transfers.values.filter { now >= $0.expiresAtNanoseconds }
        var removed: [SnapshotChunkTransferRecord] = []
        for record in expired {
            if let dropped = removeLocked(transferId: record.transferId) {
                removed.append(dropped)
            }
        }
        return removed
    }

    @discardableResult
    private func removeLocked(transferId: String) -> SnapshotChunkTransferRecord? {
        guard let record = transfers.removeValue(forKey: transferId) else { return nil }
        totalCachedBytes = max(0, totalCachedBytes - record.totalBytes)
        return record
    }
}
