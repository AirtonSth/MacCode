import CryptoKit
import XCTest
@testable import CoreModel
@testable import Persistence
@testable import SocketServer

private final class AttachmentUploadV2TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private enum AttachmentUploadV2InjectedDurabilityFailure: Error {
    case requested
}

private final class AttachmentUploadV2DurabilityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var targetKind: AttachmentUploadV2DurabilityKind?
    private var targetPoint: AttachmentUploadV2DurabilityPoint?
    private var failOnMatch = 0
    private var matchingEvents = 0
    private var recordedEvents: [AttachmentUploadV2DurabilityEvent] = []

    func arm(
        kind: AttachmentUploadV2DurabilityKind,
        point: AttachmentUploadV2DurabilityPoint,
        failOnMatch: Int = 1
    ) {
        lock.lock()
        targetKind = kind
        targetPoint = point
        self.failOnMatch = failOnMatch
        matchingEvents = 0
        recordedEvents = []
        lock.unlock()
    }

    func handle(_ event: AttachmentUploadV2DurabilityEvent) throws {
        lock.lock()
        recordedEvents.append(event)
        let matches = event.kind == targetKind && event.point == targetPoint
        if matches {
            matchingEvents += 1
        }
        let shouldFail = matches && matchingEvents == failOnMatch
        lock.unlock()
        if shouldFail {
            throw AttachmentUploadV2InjectedDurabilityFailure.requested
        }
    }

    func events() -> [AttachmentUploadV2DurabilityEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

final class AttachmentUploadV2Tests: XCTestCase {
    private var root: URL!
    private var attachmentRoot: URL!
    private var store: AttachmentUploadV2Store!
    private let owner = String(repeating: "a", count: 64)
    private let workspaceId = "04bc0dac-0c27-46e0-9807-7f920f52db1c"

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-attach-upload-v2-\(UUID().uuidString)", isDirectory: true)
        attachmentRoot = root.appendingPathComponent("managed-attachments", isDirectory: true)
        let uploadRoot = root.appendingPathComponent("upload-v2", isDirectory: true)
        store = AttachmentUploadV2Store(
            root: uploadRoot,
            attachmentStore: AgentAttachmentStore(root: attachmentRoot)
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        store = nil
        root = nil
        attachmentRoot = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func beginUpload(
        payload: Data,
        filename: String = "payload.bin",
        mimeType: String? = "application/octet-stream",
        uploadId: String = UUID().uuidString
    ) throws -> (uploadId: String, status: AttachmentUploadV2Status) {
        let status = try store.begin(
            ownerFingerprint: owner,
            uploadId: uploadId,
            workspaceId: workspaceId,
            filename: filename,
            mimeType: mimeType,
            sizeBytes: payload.count,
            sha256: sha256Hex(payload)
        )
        return (uploadId.lowercased(), status)
    }

    private func putAllChunks(
        uploadId: String,
        payload: Data,
        order: [Int]? = nil
    ) throws -> AttachmentUploadV2Status {
        let chunkSize = AttachmentUploadV2Policy.rawChunkBytes
        let count = AttachmentUploadV2Policy.chunkCount(sizeBytes: payload.count)
        let indices = order ?? Array(0..<count)
        var last: AttachmentUploadV2Status!
        for index in indices {
            let start = index * chunkSize
            let end = min(start + chunkSize, payload.count)
            let slice = payload.subdata(in: start..<end)
            last = try store.putChunk(
                ownerFingerprint: owner,
                uploadId: uploadId,
                chunkIndex: index,
                data: slice,
                sha256: sha256Hex(slice)
            )
        }
        return last
    }

    // MARK: - Policy

    func test_policy_constantsMatchRequiredBounds() {
        // WHY: DirectHTTPServer and clients share a fixed wire policy; drift
        // would break resume and size rejection parity with agent.attachment.upload.
        XCTAssertEqual(AttachmentUploadV2Policy.protocolVersion, 2)
        XCTAssertEqual(AttachmentUploadV2Policy.maximumFileBytes, 25 * 1024 * 1024)
        XCTAssertEqual(AttachmentUploadV2Policy.rawChunkBytes, 512 * 1024)
        XCTAssertEqual(AttachmentUploadV2Policy.maximumChunkCount, 50)
        XCTAssertEqual(
            AttachmentUploadV2Policy.chunkCount(sizeBytes: AttachmentUploadV2Policy.maximumFileBytes),
            50
        )
        XCTAssertEqual(
            AttachmentUploadV2Policy.expectedChunkByteCount(
                index: 49,
                sizeBytes: AttachmentUploadV2Policy.maximumFileBytes
            ),
            AttachmentUploadV2Policy.rawChunkBytes
        )
        XCTAssertGreaterThan(
            AttachmentUploadV2Policy.cancellationDenyRetention,
            AttachmentUploadV2Policy.terminalJobTTL,
            "cancel deny records need margin beyond the longest background transfer"
        )
        XCTAssertGreaterThanOrEqual(
            AttachmentUploadV2Policy.maximumCancellationDenyRecordsPerOwner,
            2_048
        )
        XCTAssertGreaterThanOrEqual(
            AttachmentUploadV2Policy.maximumGlobalCancellationDenyRecords,
            8_192
        )
    }

    // MARK: - Happy path / out-of-order / auto-finalize

    func test_outOfOrderChunksAutoFinalizeWithExactBytes() throws {
        // WHY: Cellular / multi-path clients retransmit and reorder; host must
        // commit exactly once when the full set is present.
        let payload = Data((0..<3_000).map { UInt8($0 % 251) })
        let (uploadId, began) = try beginUpload(payload: payload, filename: "note.txt", mimeType: "text/plain")
        XCTAssertEqual(began.phase, .receiving)
        XCTAssertEqual(began.protocolVersion, 2)
        XCTAssertTrue(began.receivedChunkIndices.isEmpty)
        XCTAssertNil(began.result)

        let chunkSize = AttachmentUploadV2Policy.rawChunkBytes
        let count = AttachmentUploadV2Policy.chunkCount(sizeBytes: payload.count)
        // Single-chunk payload for this size; still exercises put + finalize.
        XCTAssertEqual(count, 1)
        let slice = payload.subdata(in: 0..<payload.count)
        let committed = try store.putChunk(
            ownerFingerprint: owner,
            uploadId: uploadId,
            chunkIndex: 0,
            data: slice,
            sha256: sha256Hex(slice)
        )

        XCTAssertEqual(committed.phase, .committed)
        XCTAssertEqual(committed.receivedBytes, payload.count)
        XCTAssertEqual(committed.receivedChunkIndices, [0])
        let result = try XCTUnwrap(committed.result)
        XCTAssertEqual(result.sha256, sha256Hex(payload))
        XCTAssertEqual(result.sizeBytes, payload.count)
        XCTAssertEqual(result.displayName, "note.txt")
        XCTAssertEqual(
            URL(fileURLWithPath: result.composerInsertionText).lastPathComponent,
            "note.txt"
        )
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.composerInsertionText)), payload)
        XCTAssertFalse(result.composerInsertionText.contains(uploadId),
                       "composer path must point at managed attachment storage, not the staging upload id layout only by coincidence — path is host-owned")
        _ = chunkSize
    }

    func test_multiChunkOutOfOrderCommit() throws {
        // WHY: chunkCount > 1 is the resume contract; order must not matter.
        let chunk = AttachmentUploadV2Policy.rawChunkBytes
        let payload = Data(repeating: 0x5A, count: chunk + 100)
        let (uploadId, _) = try beginUpload(payload: payload)

        let part1 = payload.subdata(in: chunk..<payload.count)
        let part0 = payload.subdata(in: 0..<chunk)

        let afterLastFirst = try store.putChunk(
            ownerFingerprint: owner,
            uploadId: uploadId,
            chunkIndex: 1,
            data: part1,
            sha256: sha256Hex(part1)
        )
        XCTAssertEqual(afterLastFirst.phase, .receiving)
        XCTAssertEqual(afterLastFirst.receivedChunkIndices, [1])
        XCTAssertEqual(afterLastFirst.receivedBytes, part1.count)

        let committed = try store.putChunk(
            ownerFingerprint: owner,
            uploadId: uploadId,
            chunkIndex: 0,
            data: part0,
            sha256: sha256Hex(part0)
        )
        XCTAssertEqual(committed.phase, .committed)
        XCTAssertEqual(committed.receivedChunkIndices, [0, 1])
        XCTAssertEqual(try XCTUnwrap(committed.result).sizeBytes, payload.count)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(committed.result).composerInsertionText)),
            payload
        )
    }

    // MARK: - Idempotency / conflicts

    func test_duplicateIdenticalChunkIsIdempotent() throws {
        // WHY: retries must not fail or double-commit when the same digest returns.
        let payload = Data("duplicate-chunk-bytes".utf8)
        let (uploadId, _) = try beginUpload(payload: payload)
        let digest = sha256Hex(payload)

        let first = try store.putChunk(
            ownerFingerprint: owner,
            uploadId: uploadId,
            chunkIndex: 0,
            data: payload,
            sha256: digest
        )
        let second = try store.putChunk(
            ownerFingerprint: owner,
            uploadId: uploadId,
            chunkIndex: 0,
            data: payload,
            sha256: digest
        )
        XCTAssertEqual(first.phase, .committed)
        XCTAssertEqual(second.phase, .committed)
        XCTAssertEqual(first.result, second.result)
    }

    func test_conflictingChunkDigestFailsClosed() throws {
        let payload = Data("original-chunk-content".utf8)
        let (uploadId, _) = try beginUpload(payload: payload)
        // Force multi-step: begin with larger size so we can conflict before finalize.
        let big = Data(repeating: 0x11, count: 200)
        let uploadId2 = UUID().uuidString
        _ = try store.begin(
            ownerFingerprint: owner,
            uploadId: uploadId2,
            workspaceId: workspaceId,
            filename: "big.bin",
            mimeType: "application/octet-stream",
            sizeBytes: big.count,
            sha256: sha256Hex(big)
        )
        let good = big
        _ = try store.putChunk(
            ownerFingerprint: owner,
            uploadId: uploadId2,
            chunkIndex: 0,
            data: good,
            sha256: sha256Hex(good)
        )
        // Already committed single-chunk; re-put with different digest must conflict.
        let bad = Data(repeating: 0x22, count: big.count)
        XCTAssertThrowsError(
            try store.putChunk(
                ownerFingerprint: owner,
                uploadId: uploadId2,
                chunkIndex: 0,
                data: bad,
                sha256: sha256Hex(bad)
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .chunkDigestConflict)
        }
        _ = uploadId
        _ = payload
    }

    func test_conflictingChunkDigestWhileReceivingFailsClosed() throws {
        let chunk = AttachmentUploadV2Policy.rawChunkBytes
        let payload = Data(repeating: 0x33, count: chunk + 50)
        let (uploadId, _) = try beginUpload(payload: payload)
        let part1 = payload.subdata(in: chunk..<payload.count)
        _ = try store.putChunk(
            ownerFingerprint: owner,
            uploadId: uploadId,
            chunkIndex: 1,
            data: part1,
            sha256: sha256Hex(part1)
        )
        let conflict = Data(repeating: 0x44, count: part1.count)
        XCTAssertThrowsError(
            try store.putChunk(
                ownerFingerprint: owner,
                uploadId: uploadId,
                chunkIndex: 1,
                data: conflict,
                sha256: sha256Hex(conflict)
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .chunkDigestConflict)
        }
    }

    func test_conflictingImmutableMetadataFailsClosed() throws {
        let payload = Data("meta".utf8)
        let uploadId = UUID().uuidString
        _ = try beginUpload(payload: payload, uploadId: uploadId)
        XCTAssertThrowsError(
            try store.begin(
                ownerFingerprint: owner,
                uploadId: uploadId,
                workspaceId: workspaceId,
                filename: "other.bin",
                mimeType: "application/octet-stream",
                sizeBytes: payload.count,
                sha256: sha256Hex(payload)
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .metadataConflict)
        }
    }

    func test_beginIsIdempotentWithIdenticalMetadata() throws {
        let payload = Data("same-meta".utf8)
        let uploadId = UUID().uuidString
        let first = try beginUpload(payload: payload, uploadId: uploadId).status
        let second = try beginUpload(payload: payload, uploadId: uploadId).status
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.phase, .receiving)
    }

    func test_chunkByteCountAndDigestValidation() throws {
        let payload = Data(repeating: 0x7, count: 128)
        let (uploadId, _) = try beginUpload(payload: payload)
        XCTAssertThrowsError(
            try store.putChunk(
                ownerFingerprint: owner,
                uploadId: uploadId,
                chunkIndex: 0,
                data: Data(repeating: 0x7, count: 64),
                sha256: sha256Hex(Data(repeating: 0x7, count: 64))
            )
        ) { error in
            guard case .chunkValidationFailed = error as? AttachmentUploadV2Error else {
                return XCTFail("expected chunkValidationFailed, got \(error)")
            }
        }
        let full = payload
        XCTAssertThrowsError(
            try store.putChunk(
                ownerFingerprint: owner,
                uploadId: uploadId,
                chunkIndex: 0,
                data: full,
                sha256: sha256Hex(Data(repeating: 0x8, count: full.count))
            )
        ) { error in
            guard case .chunkValidationFailed = error as? AttachmentUploadV2Error else {
                return XCTFail("expected digest mismatch validation, got \(error)")
            }
        }
    }

    func test_wholeFileDigestMismatchFailsClosed() throws {
        // WHY: clients may lie about the aggregate digest while sending valid chunks.
        let payload = Data("honest-bytes".utf8)
        let uploadId = UUID().uuidString
        _ = try store.begin(
            ownerFingerprint: owner,
            uploadId: uploadId,
            workspaceId: workspaceId,
            filename: "lie.bin",
            mimeType: "application/octet-stream",
            sizeBytes: payload.count,
            sha256: String(repeating: "ab", count: 32) // valid hex shape, wrong digest
        )
        XCTAssertThrowsError(
            try store.putChunk(
                ownerFingerprint: owner,
                uploadId: uploadId,
                chunkIndex: 0,
                data: payload,
                sha256: sha256Hex(payload)
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .fileDigestMismatch)
        }
    }

    // MARK: - Cancel / durability

    func test_ownerBindingIsDurableBeforeReceivingManifest() throws {
        // WHY: a receiving manifest without its stable owner binding could be
        // rebound after a bearer rotates and violate cross-device isolation.
        let uploadRoot = root.appendingPathComponent(
            "owner-order-upload-v2",
            isDirectory: true
        )
        let probe = AttachmentUploadV2DurabilityProbe()
        let orderedStore = AttachmentUploadV2Store(
            root: uploadRoot,
            attachmentStore: AgentAttachmentStore(
                root: root.appendingPathComponent("owner-order-managed")
            ),
            durabilityHook: { try probe.handle($0) }
        )
        let payload = Data([0x01])
        _ = try orderedStore.begin(
            ownerFingerprint: owner,
            uploadId: UUID().uuidString,
            workspaceId: workspaceId,
            filename: "owner.bin",
            mimeType: "application/octet-stream",
            sizeBytes: payload.count,
            sha256: sha256Hex(payload)
        )
        let events = probe.events()
        let ownerDurable = try XCTUnwrap(
            events.lastIndex {
                $0.kind == .ownerBinding
                    && $0.point == .parentDirectorySynced
            }
        )
        let manifestWrite = try XCTUnwrap(
            events.firstIndex {
                $0.kind == .manifest && $0.point == .beforeFileSync
            }
        )
        XCTAssertLessThan(ownerDurable, manifestWrite)
    }

    func test_chunkFailureBeforeFsyncOrRenameNeverAcknowledgesAcceptedState() throws {
        // WHY: a 2xx before the chunk and its directory entry are durable can
        // make iOS delete its only source after a host power loss.
        for point in [
            AttachmentUploadV2DurabilityPoint.beforeFileSync,
            .beforeAtomicRename,
        ] {
            let caseRoot = root.appendingPathComponent(
                "chunk-\(point.rawValue)",
                isDirectory: true
            )
            let uploadRoot = caseRoot.appendingPathComponent(
                "upload-v2",
                isDirectory: true
            )
            let managedRoot = caseRoot.appendingPathComponent(
                "managed",
                isDirectory: true
            )
            let probe = AttachmentUploadV2DurabilityProbe()
            let faultStore = AttachmentUploadV2Store(
                root: uploadRoot,
                attachmentStore: AgentAttachmentStore(root: managedRoot),
                durabilityHook: { try probe.handle($0) }
            )
            let payload = Data("must-remain-client-owned".utf8)
            let uploadId = UUID().uuidString.lowercased()
            _ = try faultStore.begin(
                ownerFingerprint: owner,
                uploadId: uploadId,
                workspaceId: workspaceId,
                filename: "durable.bin",
                mimeType: "application/octet-stream",
                sizeBytes: payload.count,
                sha256: sha256Hex(payload)
            )
            probe.arm(kind: .chunk, point: point)

            XCTAssertThrowsError(
                try faultStore.putChunk(
                    ownerFingerprint: owner,
                    uploadId: uploadId,
                    chunkIndex: 0,
                    data: payload,
                    sha256: sha256Hex(payload)
                )
            )

            let chunkDirectory = uploadRoot
                .appendingPathComponent(owner, isDirectory: true)
                .appendingPathComponent(uploadId, isDirectory: true)
                .appendingPathComponent("chunks", isDirectory: true)
            XCTAssertTrue(
                ((try? FileManager.default.contentsOfDirectory(
                    atPath: chunkDirectory.path
                )) ?? []).isEmpty,
                "a failed pre-rename write must leave neither an accepted chunk nor a temp file"
            )
            let relaunched = AttachmentUploadV2Store(
                root: uploadRoot,
                attachmentStore: AgentAttachmentStore(root: managedRoot)
            )
            let recovered = try relaunched.status(
                ownerFingerprint: owner,
                uploadId: uploadId,
                workspaceId: workspaceId
            )
            XCTAssertEqual(recovered.phase, .receiving)
            XCTAssertTrue(recovered.receivedChunkIndices.isEmpty)
            XCTAssertFalse(recovered.newlyAcceptedChunk)
        }
    }

    func test_commitResultIsDurableBeforeCommittedManifestCanBeAcknowledged() throws {
        // WHY: if the final manifest write fails, a retry must see receiving
        // state plus durable host-owned bytes, never a committed receipt whose
        // attachment vanished.
        let uploadRoot = root.appendingPathComponent(
            "commit-order-upload-v2",
            isDirectory: true
        )
        let managedRoot = root.appendingPathComponent(
            "commit-order-managed",
            isDirectory: true
        )
        let probe = AttachmentUploadV2DurabilityProbe()
        let faultStore = AttachmentUploadV2Store(
            root: uploadRoot,
            attachmentStore: AgentAttachmentStore(root: managedRoot),
            durabilityHook: { try probe.handle($0) }
        )
        let payload = Data("commit-order".utf8)
        let uploadId = UUID().uuidString.lowercased()
        _ = try faultStore.begin(
            ownerFingerprint: owner,
            uploadId: uploadId,
            workspaceId: workspaceId,
            filename: "commit.txt",
            mimeType: "text/plain",
            sizeBytes: payload.count,
            sha256: sha256Hex(payload)
        )
        // putChunk first records the receiving chunk manifest; the second
        // manifest replacement is the committed result.
        probe.arm(
            kind: .manifest,
            point: .beforeAtomicRename,
            failOnMatch: 2
        )
        XCTAssertThrowsError(
            try faultStore.putChunk(
                ownerFingerprint: owner,
                uploadId: uploadId,
                chunkIndex: 0,
                data: payload,
                sha256: sha256Hex(payload)
            )
        )

        let events = probe.events()
        let committedManifestBarrier = try XCTUnwrap(
            events.lastIndex {
                $0.kind == .manifest && $0.point == .beforeAtomicRename
            }
        )
        for kind in [
            AttachmentUploadV2DurabilityKind.finalAttachment,
            .finalMetadata,
            .finalComposerPath,
        ] {
            let durableResultBarrier = try XCTUnwrap(
                events.lastIndex {
                    $0.kind == kind && $0.point == .parentDirectorySynced
                }
            )
            XCTAssertLessThan(durableResultBarrier, committedManifestBarrier)
        }

        let digest = sha256Hex(payload)
        XCTAssertEqual(
            try Data(contentsOf: managedRoot.appendingPathComponent(digest)),
            payload
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: managedRoot
                    .appendingPathComponent(".metadata", isDirectory: true)
                    .path
            ).count,
            1
        )

        let relaunched = AttachmentUploadV2Store(
            root: uploadRoot,
            attachmentStore: AgentAttachmentStore(root: managedRoot)
        )
        let recovered = try relaunched.status(
            ownerFingerprint: owner,
            uploadId: uploadId,
            workspaceId: workspaceId
        )
        XCTAssertEqual(recovered.phase, .receiving)
        XCTAssertEqual(recovered.receivedChunkIndices, [0])
        XCTAssertNil(recovered.result)

        let committed = try relaunched.putChunk(
            ownerFingerprint: owner,
            uploadId: uploadId,
            chunkIndex: 0,
            data: payload,
            sha256: digest
        )
        XCTAssertEqual(committed.phase, .committed)
        XCTAssertTrue(committed.newlyCommitted)
    }

    func test_cancelDenyDecisionIsDurableBeforeManifestCleanup() throws {
        // WHY: an in-flight background PUT may arrive after DELETE; a crash
        // during the larger manifest transition must still reject resurrection.
        let uploadRoot = root.appendingPathComponent(
            "cancel-order-upload-v2",
            isDirectory: true
        )
        let managedRoot = root.appendingPathComponent(
            "cancel-order-managed",
            isDirectory: true
        )
        let probe = AttachmentUploadV2DurabilityProbe()
        let faultStore = AttachmentUploadV2Store(
            root: uploadRoot,
            attachmentStore: AgentAttachmentStore(root: managedRoot),
            durabilityHook: { try probe.handle($0) }
        )
        let chunkBytes = AttachmentUploadV2Policy.rawChunkBytes
        let payload = Data(repeating: 0x31, count: chunkBytes + 1)
        let uploadId = UUID().uuidString.lowercased()
        _ = try faultStore.begin(
            ownerFingerprint: owner,
            uploadId: uploadId,
            workspaceId: workspaceId,
            filename: "cancel.bin",
            mimeType: "application/octet-stream",
            sizeBytes: payload.count,
            sha256: sha256Hex(payload)
        )
        let firstChunk = payload.subdata(in: 0..<chunkBytes)
        _ = try faultStore.putChunk(
            ownerFingerprint: owner,
            uploadId: uploadId,
            chunkIndex: 0,
            data: firstChunk,
            sha256: sha256Hex(firstChunk)
        )
        probe.arm(kind: .manifest, point: .beforeAtomicRename)

        XCTAssertThrowsError(
            try faultStore.cancel(
                ownerFingerprint: owner,
                uploadId: uploadId,
                workspaceId: workspaceId
            )
        )
        let events = probe.events()
        let denyDurable = try XCTUnwrap(
            events.lastIndex {
                $0.kind == .cancellationDenyIndex
                    && $0.point == .parentDirectorySynced
            }
        )
        let manifestAttempt = try XCTUnwrap(
            events.lastIndex {
                $0.kind == .manifest && $0.point == .beforeAtomicRename
            }
        )
        XCTAssertLessThan(denyDurable, manifestAttempt)

        let chunkURL = uploadRoot
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(uploadId, isDirectory: true)
            .appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent("00000.raw", isDirectory: false)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: chunkURL.path),
            "failure occurred before recoverable byte cleanup"
        )
        let relaunched = AttachmentUploadV2Store(
            root: uploadRoot,
            attachmentStore: AgentAttachmentStore(root: managedRoot)
        )
        XCTAssertEqual(
            try relaunched.status(
                ownerFingerprint: owner,
                uploadId: uploadId,
                workspaceId: workspaceId
            ).phase,
            .cancelled
        )
        XCTAssertThrowsError(
            try relaunched.putChunk(
                ownerFingerprint: owner,
                uploadId: uploadId,
                chunkIndex: 1,
                data: Data([0x31]),
                sha256: sha256Hex(Data([0x31]))
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .uploadCancelled)
        }
    }

    func test_cancelIsIdempotentWhileReceivingAndPreservesCommittedContent() throws {
        let chunk = AttachmentUploadV2Policy.rawChunkBytes
        let receivingPayload = Data(repeating: 0x9, count: chunk + 10)
        let (receivingId, _) = try beginUpload(payload: receivingPayload, filename: "partial.bin")
        let part0 = receivingPayload.subdata(in: 0..<chunk)
        _ = try store.putChunk(
            ownerFingerprint: owner,
            uploadId: receivingId,
            chunkIndex: 0,
            data: part0,
            sha256: sha256Hex(part0)
        )
        let cancelled = try store.cancel(
            ownerFingerprint: owner,
            uploadId: receivingId,
            workspaceId: workspaceId
        )
        XCTAssertEqual(cancelled.phase, .cancelled)
        let cancelledAgain = try store.cancel(
            ownerFingerprint: owner,
            uploadId: receivingId,
            workspaceId: workspaceId
        )
        XCTAssertEqual(cancelledAgain.phase, .cancelled)

        let committedPayload = Data("committed-must-survive-cancel".utf8)
        let (committedId, _) = try beginUpload(payload: committedPayload, filename: "done.txt", mimeType: "text/plain")
        let committed = try putAllChunks(uploadId: committedId, payload: committedPayload)
        XCTAssertEqual(committed.phase, .committed)
        let path = try XCTUnwrap(committed.result?.composerInsertionText)
        let bytesBefore = try Data(contentsOf: URL(fileURLWithPath: path))

        let afterCancel = try store.cancel(
            ownerFingerprint: owner,
            uploadId: committedId,
            workspaceId: workspaceId
        )
        XCTAssertEqual(afterCancel.phase, .committed, "cancel must not demote committed uploads")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytesBefore,
                       "committed managed blob must remain readable after cancel")
    }

    func test_cancelBeforeFirstPUTPersistsTombstoneAndOwnerBinding() throws {
        // WHY: cancelling an iOS background task races the already-sent PUT.
        // A durable DELETE-before-PUT tombstone must win that race after relaunch,
        // and a rotated token must not silently create a duplicate owner job.
        let uploadId = UUID().uuidString
        let cancelled = try store.cancel(
            ownerFingerprint: owner,
            uploadId: uploadId,
            workspaceId: workspaceId
        )
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertEqual(cancelled.sizeBytes, 0)

        let relaunched = AttachmentUploadV2Store(
            root: store.root,
            attachmentStore: AgentAttachmentStore(root: attachmentRoot)
        )
        let recovered = try relaunched.status(
            ownerFingerprint: owner,
            uploadId: uploadId,
            workspaceId: workspaceId
        )
        XCTAssertEqual(recovered.phase, .cancelled)
        XCTAssertThrowsError(
            try relaunched.begin(
                ownerFingerprint: owner,
                uploadId: uploadId,
                workspaceId: workspaceId,
                filename: "late.bin",
                mimeType: "application/octet-stream",
                sizeBytes: 1,
                sha256: sha256Hex(Data([0x01]))
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .uploadCancelled)
        }

        XCTAssertThrowsError(
            try relaunched.begin(
                ownerFingerprint: String(repeating: "b", count: 64),
                uploadId: uploadId,
                workspaceId: workspaceId,
                filename: "duplicate.bin",
                mimeType: "application/octet-stream",
                sizeBytes: 1,
                sha256: sha256Hex(Data([0x01]))
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .ownerMismatch)
        }
    }

    func test_cancelDenyRecordSurvivesTerminalCapPressureAndRejectsDelayedPUT() throws {
        // WHY: iOS may deliver a background PUT days after local cancellation.
        // Normal terminal caps may remove the large tombstone first, but must
        // never make that delayed transfer resumable during its task lifetime.
        let clock = AttachmentUploadV2TestClock(
            Date(timeIntervalSince1970: 2_000_000_000)
        )
        let uploadRoot = root.appendingPathComponent("upload-v2", isDirectory: true)
        store = AttachmentUploadV2Store(
            root: uploadRoot,
            attachmentStore: AgentAttachmentStore(root: attachmentRoot),
            now: { clock.now() }
        )

        let victimId = UUID().uuidString.lowercased()
        _ = try store.cancel(
            ownerFingerprint: owner,
            uploadId: victimId,
            workspaceId: workspaceId
        )
        clock.advance(by: 1)

        for _ in 0..<AttachmentUploadV2Policy.maximumTerminalJobsPerOwner {
            _ = try store.cancel(
                ownerFingerprint: owner,
                uploadId: UUID().uuidString,
                workspaceId: workspaceId
            )
            clock.advance(by: 1)
        }

        let victimDirectory = uploadRoot
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(victimId, isDirectory: true)
        let victimBinding = uploadRoot
            .appendingPathComponent(".upload-owners", isDirectory: true)
            .appendingPathComponent("\(victimId).owner", isDirectory: false)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: victimDirectory.path),
            "the test must exercise eviction of the full terminal tombstone"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: victimBinding.path),
            "the test must exercise eviction of the normal owner binding"
        )

        let relaunched = AttachmentUploadV2Store(
            root: uploadRoot,
            attachmentStore: AgentAttachmentStore(root: attachmentRoot),
            now: { clock.now() }
        )
        let lateByte = Data([0x01])
        XCTAssertThrowsError(
            try relaunched.begin(
                ownerFingerprint: owner,
                uploadId: victimId,
                workspaceId: workspaceId,
                filename: "late.bin",
                mimeType: "application/octet-stream",
                sizeBytes: lateByte.count,
                sha256: sha256Hex(lateByte)
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .uploadCancelled)
        }
        XCTAssertThrowsError(
            try relaunched.putChunk(
                ownerFingerprint: owner,
                uploadId: victimId,
                chunkIndex: 0,
                data: lateByte,
                sha256: sha256Hex(lateByte)
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .uploadCancelled)
        }
        XCTAssertEqual(
            try relaunched.status(
                ownerFingerprint: owner,
                uploadId: victimId,
                workspaceId: workspaceId
            ).phase,
            .cancelled
        )
        XCTAssertThrowsError(
            try relaunched.begin(
                ownerFingerprint: String(repeating: "b", count: 64),
                uploadId: victimId,
                workspaceId: workspaceId,
                filename: "other-owner.bin",
                mimeType: "application/octet-stream",
                sizeBytes: lateByte.count,
                sha256: sha256Hex(lateByte)
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .ownerMismatch)
        }
    }

    func test_cancelDenyCapacityRejectsNewIDsWithoutEvictingLiveRecords() throws {
        // WHY: authenticated DELETE spam must be bounded, but making room by
        // evicting a still-live id would let a delayed background PUT resurrect.
        let clock = AttachmentUploadV2TestClock(
            Date(timeIntervalSince1970: 2_000_000_000)
        )
        let uploadRoot = root.appendingPathComponent("upload-v2", isDirectory: true)
        store = AttachmentUploadV2Store(
            root: uploadRoot,
            attachmentStore: AgentAttachmentStore(root: attachmentRoot),
            now: { clock.now() }
        )
        let owners = ["a", "b", "c", "d"].map {
            String(repeating: $0, count: 64)
        }
        let victimId = UUID().uuidString.lowercased()
        _ = try store.cancel(
            ownerFingerprint: owners[0],
            uploadId: victimId,
            workspaceId: workspaceId
        )

        let indexURL = uploadRoot.appendingPathComponent(
            ".cancelled-upload-denylist.json",
            isDirectory: false
        )
        var index = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: indexURL))
                as? [String: Any]
        )
        var records = try XCTUnwrap(index["records"] as? [String: Any])
        let cancelledAt = clock.now().timeIntervalSince1970
        let expiresAt = cancelledAt
            + AttachmentUploadV2Policy.cancellationDenyRetention
        for position in 1..<AttachmentUploadV2Policy.maximumGlobalCancellationDenyRecords {
            let ownerIndex = min(
                position
                    / AttachmentUploadV2Policy.maximumCancellationDenyRecordsPerOwner,
                owners.count - 1
            )
            records[UUID().uuidString.lowercased()] = [
                "ownerFingerprint": owners[ownerIndex],
                "workspaceId": workspaceId,
                "cancelledAtEpochSeconds": cancelledAt,
                "expiresAtEpochSeconds": expiresAt,
            ]
        }
        index["records"] = records
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
            .write(to: indexURL, options: .atomic)
        XCTAssertEqual(
            records.count,
            AttachmentUploadV2Policy.maximumGlobalCancellationDenyRecords
        )

        let victimDirectory = uploadRoot
            .appendingPathComponent(owners[0], isDirectory: true)
            .appendingPathComponent(victimId, isDirectory: true)
        let victimBinding = uploadRoot
            .appendingPathComponent(".upload-owners", isDirectory: true)
            .appendingPathComponent("\(victimId).owner", isDirectory: false)
        try FileManager.default.removeItem(at: victimDirectory)
        try FileManager.default.removeItem(at: victimBinding)

        XCTAssertThrowsError(try store.cancel(
            ownerFingerprint: owners[0],
            uploadId: UUID().uuidString,
            workspaceId: workspaceId
        )) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .activeJobLimitExceeded)
        }
        XCTAssertThrowsError(try store.cancel(
            ownerFingerprint: String(repeating: "e", count: 64),
            uploadId: UUID().uuidString,
            workspaceId: workspaceId
        )) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .activeJobLimitExceeded)
        }

        let lateByte = Data([0x01])
        XCTAssertThrowsError(try store.begin(
            ownerFingerprint: owners[0],
            uploadId: victimId,
            workspaceId: workspaceId,
            filename: "late-after-cap.bin",
            mimeType: "application/octet-stream",
            sizeBytes: lateByte.count,
            sha256: sha256Hex(lateByte)
        )) { error in
            XCTAssertEqual(error as? AttachmentUploadV2Error, .uploadCancelled)
        }
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: indexURL))
                as? [String: Any]
        )
        XCTAssertEqual(
            (persisted["records"] as? [String: Any])?.count,
            AttachmentUploadV2Policy.maximumGlobalCancellationDenyRecords,
            "failed admission must preserve every live cancellation"
        )
    }

    func test_freshStoreInstanceRecoversDurableState() throws {
        // WHY: host relaunch must resume manifests under the same root without RAM.
        let payload = Data("durable-across-relaunch".utf8)
        let (uploadId, _) = try beginUpload(payload: payload, filename: "relaunch.bin")
        let digest = sha256Hex(payload)

        let relaunched = AttachmentUploadV2Store(
            root: store.root,
            attachmentStore: AgentAttachmentStore(root: attachmentRoot)
        )
        let status = try relaunched.status(
            ownerFingerprint: owner,
            uploadId: uploadId,
            workspaceId: workspaceId
        )
        XCTAssertEqual(status.phase, .receiving)
        XCTAssertEqual(status.sizeBytes, payload.count)

        let committed = try relaunched.putChunk(
            ownerFingerprint: owner,
            uploadId: uploadId,
            chunkIndex: 0,
            data: payload,
            sha256: digest
        )
        XCTAssertEqual(committed.phase, .committed)
        XCTAssertEqual(try XCTUnwrap(committed.result).sha256, digest)

        let third = AttachmentUploadV2Store(
            root: store.root,
            attachmentStore: AgentAttachmentStore(root: attachmentRoot)
        )
        let recovered = try third.status(
            ownerFingerprint: owner,
            uploadId: uploadId,
            workspaceId: workspaceId
        )
        XCTAssertEqual(recovered.phase, .committed)
        XCTAssertEqual(recovered.result?.id, committed.result?.id)
    }

    func test_ownerFingerprintScopesAccess() throws {
        let payload = Data("owner-scoped".utf8)
        let (uploadId, _) = try beginUpload(payload: payload)
        XCTAssertThrowsError(
            try store.status(
                ownerFingerprint: String(repeating: "b", count: 64),
                uploadId: uploadId,
                workspaceId: workspaceId
            )
        ) { error in
            // Wrong owner path has no job → unknown, or mismatch if path shared.
            let ok = (error as? AttachmentUploadV2Error) == .uploadUnknown
                || (error as? AttachmentUploadV2Error) == .ownerMismatch
            XCTAssertTrue(ok, "unexpected error \(error)")
        }
    }

    func test_manifestOmitsTokenAndRawContent() throws {
        // WHY: durable sidecars must never become a secret or payload dump.
        let payload = Data("not-in-manifest".utf8)
        let (uploadId, _) = try beginUpload(payload: payload)
        _ = try putAllChunks(uploadId: uploadId, payload: payload)
        let manifestURL = store.root
            .appendingPathComponent(owner)
            .appendingPathComponent(uploadId)
            .appendingPathComponent("manifest.json")
        let text = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertFalse(text.contains("not-in-manifest"))
        XCTAssertFalse(text.lowercased().contains("bearer"))
        XCTAssertFalse(text.lowercased().contains("token"))
        XCTAssertTrue(text.contains("\"phase\":\"committed\""))
        XCTAssertTrue(text.contains("sha256"))
    }

    func test_filePermissionsAreBounded() throws {
        let payload = Data("perms".utf8)
        let (uploadId, _) = try beginUpload(payload: payload)
        let jobDir = store.root.appendingPathComponent(owner).appendingPathComponent(uploadId)
        let manifestURL = jobDir.appendingPathComponent("manifest.json")
        let rootPerms = try FileManager.default.attributesOfItem(atPath: store.root.path)[.posixPermissions] as? NSNumber
        let jobPerms = try FileManager.default.attributesOfItem(atPath: jobDir.path)[.posixPermissions] as? NSNumber
        let filePerms = try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(rootPerms?.uint16Value ?? 0, 0o700)
        XCTAssertEqual(jobPerms?.uint16Value ?? 0, 0o700)
        XCTAssertEqual(filePerms?.uint16Value ?? 0, 0o600)
    }

    func test_activeJobLimitIsEnforced() throws {
        // WHY: unbounded concurrent receiving jobs would exhaust disk under a shared root.
        let original = AttachmentUploadV2Policy.maximumActiveJobs
        // Fill the active budget with partial multi-chunk jobs.
        let chunk = AttachmentUploadV2Policy.rawChunkBytes
        let payload = Data(repeating: 0x1, count: chunk + 1)
        var ids: [String] = []
        for _ in 0..<original {
            let id = UUID().uuidString
            ids.append(id)
            _ = try beginUpload(payload: payload, uploadId: id)
            let part0 = payload.subdata(in: 0..<chunk)
            _ = try store.putChunk(
                ownerFingerprint: owner,
                uploadId: id,
                chunkIndex: 0,
                data: part0,
                sha256: sha256Hex(part0)
            )
        }
        for _ in 0..<32 {
            XCTAssertThrowsError(
                try beginUpload(payload: payload, uploadId: UUID().uuidString)
            ) { error in
                XCTAssertEqual(error as? AttachmentUploadV2Error, .activeJobLimitExceeded)
            }
        }
        let bindingRoot = store.root.appendingPathComponent(
            ".upload-owners",
            isDirectory: true
        )
        let bindingCount = try FileManager.default.contentsOfDirectory(
            atPath: bindingRoot.path
        ).count
        XCTAssertEqual(
            bindingCount,
            original,
            "rejected random ids must not leak owner-binding inodes"
        )
        // Cancel one slot and ensure a new begin is accepted.
        _ = try store.cancel(
            ownerFingerprint: owner,
            uploadId: ids[0],
            workspaceId: workspaceId
        )
        XCTAssertNoThrow(try beginUpload(payload: payload, uploadId: UUID().uuidString))
    }

    func test_rejectsPathTraversalFilenameAndBadUploadId() throws {
        let payload = Data("x".utf8)
        XCTAssertThrowsError(
            try store.begin(
                ownerFingerprint: owner,
                uploadId: "not-a-uuid",
                workspaceId: workspaceId,
                filename: "ok.bin",
                mimeType: "application/octet-stream",
                sizeBytes: payload.count,
                sha256: sha256Hex(payload)
            )
        )
        XCTAssertThrowsError(
            try store.begin(
                ownerFingerprint: owner,
                uploadId: UUID().uuidString,
                workspaceId: workspaceId,
                filename: "../etc/passwd",
                mimeType: "application/octet-stream",
                sizeBytes: payload.count,
                sha256: sha256Hex(payload)
            )
        )
        XCTAssertThrowsError(
            try store.begin(
                ownerFingerprint: String(repeating: ".", count: 64),
                uploadId: UUID().uuidString,
                workspaceId: workspaceId,
                filename: "ok.bin",
                mimeType: "application/octet-stream",
                sizeBytes: payload.count,
                sha256: sha256Hex(payload)
            )
        )
    }

    func test_statusReportsReceivingProgress() throws {
        let chunk = AttachmentUploadV2Policy.rawChunkBytes
        let payload = Data(repeating: 0x55, count: chunk * 2)
        let (uploadId, _) = try beginUpload(payload: payload)
        let part0 = payload.subdata(in: 0..<chunk)
        let mid = try store.putChunk(
            ownerFingerprint: owner,
            uploadId: uploadId,
            chunkIndex: 0,
            data: part0,
            sha256: sha256Hex(part0)
        )
        XCTAssertEqual(mid.phase, .receiving)
        XCTAssertEqual(mid.receivedChunkIndices, [0])
        XCTAssertEqual(mid.receivedBytes, chunk)
        XCTAssertEqual(mid.chunkCount, 2)
        XCTAssertNil(mid.result)
    }
}
