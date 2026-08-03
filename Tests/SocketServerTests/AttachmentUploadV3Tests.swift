import CryptoKit
import XCTest
@testable import Persistence
@testable import SocketServer

final class AttachmentUploadV3Tests: XCTestCase {
    private final class MutableClock: @unchecked Sendable {
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

    private final class ActiveOwnerAuth:
        DirectAuthProvider,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private let token: String
        private let owner: String
        private var active = true

        init(token: String, owner: String) {
            self.token = token
            self.owner = owner
        }

        func verify(token: String) -> Bool {
            token == self.token
        }

        func authorizedOwnerFingerprint(token: String) -> String? {
            token == self.token ? owner : nil
        }

        func isAuthorizedOwnerFingerprintActive(
            _ fingerprint: String
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return active && fingerprint == owner
        }

        func revoke() {
            lock.lock()
            active = false
            lock.unlock()
        }

        func createPairingCode() -> String? { nil }
        func redeemPairingCode(
            _ code: String,
            deviceName: String
        ) -> (deviceId: String, token: String)? { nil }
        func listDevices() -> [[String: Any]] { [] }
        func revokeDevice(_ id: String) { revoke() }
    }

    /// Multi-token owner map for cross-owner prepare isolation tests.
    private final class DualOwnerAuth:
        DirectAuthProvider,
        @unchecked Sendable
    {
        private let mappings: [String: String]

        init(mappings: [String: String]) {
            self.mappings = mappings
        }

        func verify(token: String) -> Bool {
            mappings[token] != nil
        }

        func authorizedOwnerFingerprint(token: String) -> String? {
            mappings[token]
        }

        func isAuthorizedOwnerFingerprintActive(
            _ fingerprint: String
        ) -> Bool {
            mappings.values.contains(fingerprint)
        }

        func createPairingCode() -> String? { nil }
        func redeemPairingCode(
            _ code: String,
            deviceName: String
        ) -> (deviceId: String, token: String)? { nil }
        func listDevices() -> [[String: Any]] { [] }
        func revokeDevice(_ id: String) {}
    }

    private struct Vector {
        let request: AttachmentUploadV3PrepareRequest
        let capability: Data
        let sealed: Data
    }

    private var root: URL!
    private var plaintextStore: AttachmentUploadV2Store!
    private var store: AttachmentUploadV3Store!
    private let owner = String(repeating: "a", count: 64)
    private let workspaceId = "04bc0dac-0c27-46e0-9807-7f920f52db1c"
    private let serverId = "host-protected-v3-test"

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rc-attach-upload-v3-\(UUID().uuidString)",
            isDirectory: true
        )
        plaintextStore = AttachmentUploadV2Store(
            root: root.appendingPathComponent("plaintext", isDirectory: true),
            attachmentStore: AgentAttachmentStore(
                root: root.appendingPathComponent(
                    "attachments",
                    isDirectory: true
                )
            )
        )
        store = AttachmentUploadV3Store(
            root: root.appendingPathComponent("protected", isDirectory: true),
            plaintextStore: plaintextStore
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        store = nil
        plaintextStore = nil
        root = nil
        super.tearDown()
    }

    func test_knownVectorRoundTripsAndSurvivesColdRestart() throws {
        // WHY: the iOS and Mac implementations must derive the same per-chunk
        // key and byte-for-byte sorted JSON AAD after either process relaunches.
        let uploadId = "11111111-1111-4111-8111-111111111111"
        let plaintext = Data("protected attachment vector".utf8)
        let vector = try makeVector(
            uploadId: uploadId,
            plaintext: plaintext
        )
        let prepared = try store.prepare(
            uploadId: uploadId,
            authorizedOwnerFingerprint: owner,
            request: vector.request
        )
        XCTAssertEqual(prepared.phase, .receiving)

        let restarted = AttachmentUploadV3Store(
            root: store.root,
            plaintextStore: plaintextStore
        )
        let authorization = try restarted.authorizeChunk(
            uploadId: uploadId,
            chunkIndex: 0,
            capabilityBase64URL: base64URL(vector.capability),
            sealedSHA256: sha256Hex(vector.sealed),
            sealedBytes: vector.sealed.count,
            idempotencyKey: AttachmentUploadV3Store.idempotencyKey(
                uploadId: uploadId,
                chunkIndex: 0,
                sealedSHA256: sha256Hex(vector.sealed)
            ),
            ownerIsActive: { $0 == self.owner }
        )
        let committed = try restarted.putProtectedChunk(
            authorization: authorization,
            sealedData: vector.sealed,
            ownerIsActive: { $0 == self.owner }
        )
        XCTAssertEqual(committed.phase, .committed)
        XCTAssertEqual(
            try Data(
                contentsOf: URL(
                    fileURLWithPath: try XCTUnwrap(
                        committed.result?.composerInsertionText
                    )
                )
            ),
            plaintext
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: restarted.root.appendingPathComponent(
                    "\(uploadId).json"
                ).path
            ),
            "commit must remove the persisted encryption key"
        )
    }

    func test_capabilityAndRevocationFailBeforeChunkAcceptance() throws {
        // WHY: a redirect target that learns only URL/upload/index cannot read
        // or replay ciphertext, and revoking the trust row immediately kills a
        // previously issued capability.
        let uploadId = UUID().uuidString.lowercased()
        let vector = try makeVector(
            uploadId: uploadId,
            plaintext: Data("revocation".utf8)
        )
        _ = try store.prepare(
            uploadId: uploadId,
            authorizedOwnerFingerprint: owner,
            request: vector.request
        )
        XCTAssertThrowsError(
            try store.authorizeChunk(
                uploadId: uploadId,
                chunkIndex: 0,
                capabilityBase64URL: base64URL(
                    Data(repeating: 0xff, count: 32)
                ),
                sealedSHA256: sha256Hex(vector.sealed),
                sealedBytes: vector.sealed.count,
                idempotencyKey: AttachmentUploadV3Store.idempotencyKey(
                    uploadId: uploadId,
                    chunkIndex: 0,
                    sealedSHA256: sha256Hex(vector.sealed)
                ),
                ownerIsActive: { _ in true }
            )
        ) {
            XCTAssertEqual(
                $0 as? AttachmentUploadV3Error,
                .capabilityRejected
            )
        }
        let authorized = try store.authorizeChunk(
            uploadId: uploadId,
            chunkIndex: 0,
            capabilityBase64URL: base64URL(vector.capability),
            sealedSHA256: sha256Hex(vector.sealed),
            sealedBytes: vector.sealed.count,
            idempotencyKey: AttachmentUploadV3Store.idempotencyKey(
                uploadId: uploadId,
                chunkIndex: 0,
                sealedSHA256: sha256Hex(vector.sealed)
            ),
            ownerIsActive: { _ in true }
        )
        XCTAssertThrowsError(
            try store.putProtectedChunk(
                authorization: authorized,
                sealedData: vector.sealed,
                ownerIsActive: { _ in false }
            )
        ) {
            XCTAssertEqual($0 as? AttachmentUploadV3Error, .ownerInactive)
        }
        XCTAssertEqual(
            try plaintextStore.status(
                ownerFingerprint: owner,
                uploadId: uploadId,
                workspaceId: workspaceId
            ).receivedChunkIndices,
            []
        )
    }

    func test_tamperAndCrossUploadReplayFailAuthentication() throws {
        // WHY: capability possession must not make a chunk valid under a
        // different upload/AAD tuple, and any bit flip must fail before
        // plaintext reaches the durable assembler.
        let firstId = UUID().uuidString.lowercased()
        let secondId = UUID().uuidString.lowercased()
        let plaintext = Data("bound to one upload".utf8)
        let first = try makeVector(uploadId: firstId, plaintext: plaintext)
        let second = try makeVector(
            uploadId: secondId,
            plaintext: plaintext,
            masterKey: Data(repeating: 0x11, count: 32),
            capability: first.capability,
            nonce: Data(repeating: 0x22, count: 12)
        )
        _ = try store.prepare(
            uploadId: firstId,
            authorizedOwnerFingerprint: owner,
            request: first.request
        )
        _ = try store.prepare(
            uploadId: secondId,
            authorizedOwnerFingerprint: owner,
            request: second.request
        )
        let secondAuthorization = try store.authorizeChunk(
            uploadId: secondId,
            chunkIndex: 0,
            capabilityBase64URL: base64URL(first.capability),
            sealedSHA256: sha256Hex(second.sealed),
            sealedBytes: second.sealed.count,
            idempotencyKey: AttachmentUploadV3Store.idempotencyKey(
                uploadId: secondId,
                chunkIndex: 0,
                sealedSHA256: sha256Hex(second.sealed)
            ),
            ownerIsActive: { _ in true }
        )
        XCTAssertThrowsError(
            try store.putProtectedChunk(
                authorization: secondAuthorization,
                sealedData: first.sealed,
                ownerIsActive: { _ in true }
            )
        )

        let firstAuthorization = try store.authorizeChunk(
            uploadId: firstId,
            chunkIndex: 0,
            capabilityBase64URL: base64URL(first.capability),
            sealedSHA256: sha256Hex(first.sealed),
            sealedBytes: first.sealed.count,
            idempotencyKey: AttachmentUploadV3Store.idempotencyKey(
                uploadId: firstId,
                chunkIndex: 0,
                sealedSHA256: sha256Hex(first.sealed)
            ),
            ownerIsActive: { _ in true }
        )
        var tampered = first.sealed
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(
            try store.putProtectedChunk(
                authorization: firstAuthorization,
                sealedData: tampered,
                ownerIsActive: { _ in true }
            )
        )
    }

    func test_prepareIsExactlyIdempotentAndCancelRemovesKeyAfterTombstone()
        throws
    {
        let uploadId = UUID().uuidString.lowercased()
        let vector = try makeVector(
            uploadId: uploadId,
            plaintext: Data("idempotent".utf8)
        )
        let first = try store.prepare(
            uploadId: uploadId,
            authorizedOwnerFingerprint: owner,
            request: vector.request
        )
        let second = try store.prepare(
            uploadId: uploadId,
            authorizedOwnerFingerprint: owner,
            request: vector.request
        )
        XCTAssertEqual(first, second)

        var conflicting = vector.request
        let conflictData = try JSONEncoder().encode(conflicting)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: conflictData)
                as? [String: Any]
        )
        object["filename"] = "different.bin"
        conflicting = try JSONDecoder().decode(
            AttachmentUploadV3PrepareRequest.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertThrowsError(
            try store.prepare(
                uploadId: uploadId,
                authorizedOwnerFingerprint: owner,
                request: conflicting
            )
        ) {
            XCTAssertEqual($0 as? AttachmentUploadV3Error, .metadataConflict)
        }

        let cancelled = try store.cancel(
            ownerFingerprint: owner,
            uploadId: uploadId,
            workspaceId: workspaceId
        )
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertThrowsError(
            try store.authorizeChunk(
                uploadId: uploadId,
                chunkIndex: 0,
                capabilityBase64URL: base64URL(vector.capability),
                sealedSHA256: sha256Hex(vector.sealed),
                sealedBytes: vector.sealed.count,
                idempotencyKey: AttachmentUploadV3Store.idempotencyKey(
                    uploadId: uploadId,
                    chunkIndex: 0,
                    sealedSHA256: sha256Hex(vector.sealed)
                ),
                ownerIsActive: { _ in true }
            )
        )
        XCTAssertEqual(
            try plaintextStore.status(
                ownerFingerprint: owner,
                uploadId: uploadId,
                workspaceId: workspaceId
            ).phase,
            .cancelled
        )
    }

    func test_coldStatusRemovesProtectionManifestAfterPlaintextCommit()
        throws
    {
        // WHY: the Mac can commit the authoritative plaintext manifest and die
        // before deleting the v3 key. The first authenticated cold status must
        // finish that cleanup without requiring another upload.
        let uploadId = UUID().uuidString.lowercased()
        let plaintext = Data("commit-before-key-cleanup".utf8)
        let vector = try makeVector(
            uploadId: uploadId,
            plaintext: plaintext
        )
        _ = try store.prepare(
            uploadId: uploadId,
            authorizedOwnerFingerprint: owner,
            request: vector.request
        )
        let protectionManifest = store.root.appendingPathComponent(
            "\(uploadId).json",
            isDirectory: false
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: protectionManifest.path
            )
        )

        let committed = try plaintextStore.putChunk(
            ownerFingerprint: owner,
            uploadId: uploadId,
            chunkIndex: 0,
            data: plaintext,
            sha256: sha256Hex(plaintext)
        )
        XCTAssertEqual(committed.phase, .committed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: protectionManifest.path
            ),
            "the test must model a crash before v3 key removal"
        )

        let restarted = AttachmentUploadV3Store(
            root: store.root,
            plaintextStore: plaintextStore
        )
        XCTAssertEqual(
            try restarted.status(
                ownerFingerprint: owner,
                uploadId: uploadId,
                workspaceId: workspaceId
            ).phase,
            .committed
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: protectionManifest.path
            )
        )
    }

    func test_manifestReadIsBoundedFailClosedAndDoesNotFollowSymlinks()
        throws
    {
        // WHY: a corrupt local key envelope is not "no upload." Preserve the
        // bytes and fail closed without unbounded reads or following a swapped
        // filesystem entry outside the protected root.
        let uploadId = UUID().uuidString.lowercased()
        let vector = try makeVector(
            uploadId: uploadId,
            plaintext: Data("bounded manifest".utf8)
        )
        try FileManager.default.createDirectory(
            at: store.root,
            withIntermediateDirectories: true
        )
        let manifest = store.root.appendingPathComponent(
            "\(uploadId).json",
            isDirectory: false
        )

        let corrupt = Data("{\"schemaVersion\":1}".utf8)
        try corrupt.write(to: manifest)
        XCTAssertThrowsError(
            try store.prepare(
                uploadId: uploadId,
                authorizedOwnerFingerprint: owner,
                request: vector.request
            )
        ) {
            guard case .storageFailure =
                    $0 as? AttachmentUploadV3Error else {
                return XCTFail("corrupt manifest must fail as storage")
            }
        }
        XCTAssertEqual(try Data(contentsOf: manifest), corrupt)

        try FileManager.default.removeItem(at: manifest)
        let oversized = Data(
            repeating: 0x41,
            count: AttachmentUploadV3Policy.maximumPrepareBytes + 1
        )
        try oversized.write(to: manifest)
        XCTAssertThrowsError(
            try store.prepare(
                uploadId: uploadId,
                authorizedOwnerFingerprint: owner,
                request: vector.request
            )
        ) {
            guard case .storageFailure =
                    $0 as? AttachmentUploadV3Error else {
                return XCTFail("oversized manifest must fail as storage")
            }
        }
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(
                atPath: manifest.path
            )[.size] as? NSNumber,
            NSNumber(value: oversized.count)
        )

        try FileManager.default.removeItem(at: manifest)
        let outside = root.appendingPathComponent("outside-key-envelope")
        let outsideBytes = Data("do-not-follow".utf8)
        try outsideBytes.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: manifest,
            withDestinationURL: outside
        )
        XCTAssertThrowsError(
            try store.prepare(
                uploadId: uploadId,
                authorizedOwnerFingerprint: owner,
                request: vector.request
            )
        ) {
            guard case .storageFailure =
                    $0 as? AttachmentUploadV3Error else {
                return XCTFail("symlinked manifest must fail as storage")
            }
        }
        XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
    }

    func test_prepareReclaimsOnlyBoundedExactCrashTempKeyEnvelopes()
        throws
    {
        // WHY: power loss after fsync but before atomic rename leaves a hidden
        // temp containing the encryption key. The next operation must reclaim
        // it durably, without an unbounded root walk or arbitrary hidden-file
        // deletion.
        try FileManager.default.createDirectory(
            at: store.root,
            withIntermediateDirectories: true
        )
        let crashUploadID = UUID().uuidString.lowercased()
        let exactCount =
            AttachmentUploadV3Policy.maximumProtectionEntriesPerSweep + 1
        for _ in 0..<exactCount {
            let name =
                ".\(crashUploadID).\(UUID().uuidString).tmp"
            XCTAssertTrue(
                AttachmentUploadV3Store
                    .isAbandonedManifestTempFilename(name)
            )
            try Data(repeating: 0xA5, count: 32).write(
                to: store.root.appendingPathComponent(name)
            )
        }
        XCTAssertFalse(
            AttachmentUploadV3Store.isAbandonedManifestTempFilename(
                ".\(crashUploadID).not-a-uuid.tmp"
            )
        )
        XCTAssertFalse(
            AttachmentUploadV3Store.isAbandonedManifestTempFilename(
                "\(crashUploadID).\(UUID().uuidString).tmp"
            )
        )

        let firstID = UUID().uuidString.lowercased()
        let first = try makeVector(
            uploadId: firstID,
            plaintext: Data("first cleanup trigger".utf8)
        )
        _ = try store.prepare(
            uploadId: firstID,
            authorizedOwnerFingerprint: owner,
            request: first.request
        )
        var remainingExact = try FileManager.default
            .contentsOfDirectory(atPath: store.root.path)
            .filter(
                AttachmentUploadV3Store
                    .isAbandonedManifestTempFilename
            )
        XCTAssertEqual(
            remainingExact.count,
            1,
            "one sweep must inspect at most its explicit entry budget"
        )

        let arbitrary = store.root.appendingPathComponent(
            ".\(crashUploadID).not-a-uuid.tmp"
        )
        let arbitraryBytes = Data("unrelated hidden file".utf8)
        try arbitraryBytes.write(to: arbitrary)
        let secondID = UUID().uuidString.lowercased()
        let second = try makeVector(
            uploadId: secondID,
            plaintext: Data("second cleanup trigger".utf8)
        )
        _ = try store.prepare(
            uploadId: secondID,
            authorizedOwnerFingerprint: owner,
            request: second.request
        )
        remainingExact = try FileManager.default
            .contentsOfDirectory(atPath: store.root.path)
            .filter(
                AttachmentUploadV3Store
                    .isAbandonedManifestTempFilename
            )
        XCTAssertTrue(remainingExact.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: arbitrary),
            arbitraryBytes,
            "reconciliation must never remove a name outside exact grammar"
        )
    }

    func test_maximumPrepareGeometryFitsCapAndCapPlusOneIsRejected()
        throws
    {
        // WHY: the 25 MiB/50-chunk cellular edge must fit the same fixed
        // prepare cap on both platforms; the server must reject cap+1 before
        // JSON decoding or allocation growth.
        let total = AttachmentUploadV2Policy.maximumFileBytes
        let count = AttachmentUploadV2Policy.chunkCount(sizeBytes: total)
        XCTAssertEqual(count, AttachmentUploadV2Policy.maximumChunkCount)
        let chunks = try (0..<count).map { index in
            var nonce = Data(
                repeating: 0,
                count: AttachmentUploadV3Policy.nonceBytes
            )
            nonce[nonce.index(before: nonce.endIndex)] = UInt8(index)
            let plaintextBytes = try XCTUnwrap(
                AttachmentUploadV2Policy.expectedChunkByteCount(
                    index: index,
                    sizeBytes: total
                )
            )
            return AttachmentUploadV3PrepareRequest.Chunk(
                index: index,
                plaintextBytes: plaintextBytes,
                plaintextSHA256: sha256Hex(
                    Data("plaintext-\(index)".utf8)
                ),
                sealedBytes: plaintextBytes
                    + AttachmentUploadV3Policy.cipherOverheadBytes,
                sealedSHA256: sha256Hex(
                    Data("sealed-\(index)".utf8)
                ),
                nonceBase64URL: base64URL(nonce),
                capabilitySHA256: sha256Hex(
                    Data("capability-\(index)".utf8)
                )
            )
        }
        let request = AttachmentUploadV3PrepareRequest(
            serverId: serverId,
            ownerFingerprint: owner,
            workspaceId: workspaceId,
            filename: String(repeating: "f", count: 255),
            mimeType: "application/" + String(repeating: "x", count: 116),
            totalPlaintextBytes: total,
            chunkCount: count,
            fileSHA256: String(repeating: "f", count: 64),
            encryptionKeyBase64URL: base64URL(
                Data(repeating: 0x11, count: 32)
            ),
            chunks: chunks
        )
        let encoded = try JSONEncoder().encode(request)
        XCTAssertLessThanOrEqual(
            encoded.count,
            AttachmentUploadV3Policy.maximumPrepareBytes
        )
        XCTAssertEqual(
            try AttachmentUploadV3Store.decodePrepareRequest(encoded),
            request
        )
        let capPlusOne = Data(
            repeating: 0x20,
            count: AttachmentUploadV3Policy.maximumPrepareBytes + 1
        )
        XCTAssertThrowsError(
            try AttachmentUploadV3Store.decodePrepareRequest(capPlusOne)
        ) {
            XCTAssertEqual(
                $0 as? AttachmentUploadV3Error,
                .invalidParams("prepare body size")
            )
        }
    }

    func test_preparePrunesExpiredAndUnknownProtectionManifestsBoundedly()
        throws
    {
        // WHY: a kill can strand the v3 encryption key after the v2 job
        // expires or disappears. A later bounded prepare sweep must reclaim
        // those exact orphan keys while preserving live receiving jobs.
        let scopedRoot = root.appendingPathComponent(
            "orphan-reconciliation",
            isDirectory: true
        )
        let clock = MutableClock(
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let plaintext = AttachmentUploadV2Store(
            root: scopedRoot.appendingPathComponent(
                "plaintext",
                isDirectory: true
            ),
            attachmentStore: AgentAttachmentStore(
                root: scopedRoot.appendingPathComponent(
                    "attachments",
                    isDirectory: true
                )
            ),
            now: { clock.now() }
        )
        let protected = AttachmentUploadV3Store(
            root: scopedRoot.appendingPathComponent(
                "protected",
                isDirectory: true
            ),
            plaintextStore: plaintext
        )

        let expiredId = UUID().uuidString.lowercased()
        let expired = try makeVector(
            uploadId: expiredId,
            plaintext: Data("expires".utf8)
        )
        _ = try protected.prepare(
            uploadId: expiredId,
            authorizedOwnerFingerprint: owner,
            request: expired.request
        )
        let expiredManifest = protected.root.appendingPathComponent(
            "\(expiredId).json"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expiredManifest.path)
        )

        clock.advance(
            by: AttachmentUploadV2Policy.receivingJobTTL + 1
        )
        let liveId = UUID().uuidString.lowercased()
        let live = try makeVector(
            uploadId: liveId,
            plaintext: Data("live".utf8)
        )
        _ = try protected.prepare(
            uploadId: liveId,
            authorizedOwnerFingerprint: owner,
            request: live.request
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: expiredManifest.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: protected.root.appendingPathComponent(
                    "\(liveId).json"
                ).path
            ),
            "the bounded sweep must preserve a live receiving key"
        )

        let unknownId = UUID().uuidString.lowercased()
        let unknown = try makeVector(
            uploadId: unknownId,
            plaintext: Data("unknown".utf8)
        )
        _ = try protected.prepare(
            uploadId: unknownId,
            authorizedOwnerFingerprint: owner,
            request: unknown.request
        )
        let unknownManifest = protected.root.appendingPathComponent(
            "\(unknownId).json"
        )
        try FileManager.default.removeItem(
            at: plaintext.root
                .appendingPathComponent(owner, isDirectory: true)
                .appendingPathComponent(unknownId, isDirectory: true)
        )

        let triggerId = UUID().uuidString.lowercased()
        let trigger = try makeVector(
            uploadId: triggerId,
            plaintext: Data("trigger".utf8)
        )
        _ = try protected.prepare(
            uploadId: triggerId,
            authorizedOwnerFingerprint: owner,
            request: trigger.request
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: unknownManifest.path)
        )
    }

    @MainActor
    func test_httpContractMatchesIOSPrepareCapabilityPUTAndStatus()
        async throws
    {
        // WHY: unit crypto can pass while the real parser still gates `/v3`
        // as bearer-only or advertises v2. Exercise the exact paired wire.
        let token = "valid-test-bearer"
        let auth = ActiveOwnerAuth(token: token, owner: owner)
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(
                router: FakeRouter(),
                agentAttachmentUploadCapability: .protectedV3
            ),
            auth: auth,
            serverId: serverId,
            bootEpoch: 1,
            attachmentUploadV2Store: plaintextStore,
            attachmentUploadV3Store: store
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let base = URL(string: "http://127.0.0.1:\(port)")!

        let (capabilityData, capabilityResponse) =
            try await URLSession.shared.data(
                from: base.appendingPathComponent("/v1/capabilities")
            )
        XCTAssertEqual(
            (capabilityResponse as? HTTPURLResponse)?.statusCode,
            200
        )
        let capabilityRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: capabilityData)
                as? [String: Any]
        )
        let agent = try XCTUnwrap(
            capabilityRoot["agent"] as? [String: Any]
        )
        let capability = try XCTUnwrap(
            agent["attachment_upload"] as? [String: Any]
        )
        XCTAssertEqual(capability["protocol_version"] as? Int, 3)
        XCTAssertEqual(
            capability["content_encodings"] as? [String],
            ["protected_chunks_v1"]
        )
        XCTAssertEqual(capability["cipher_overhead_bytes"] as? Int, 28)

        let uploadId = UUID().uuidString.lowercased()
        let plaintext = Data("paired HTTP v3".utf8)
        let vector = try makeVector(
            uploadId: uploadId,
            plaintext: plaintext
        )
        let uploadURL = base.appendingPathComponent(
            "/v1/agent/attachment-uploads/v3/\(uploadId)"
        )
        var oversizedPrepare = URLRequest(
            url: uploadURL.appendingPathComponent("prepare")
        )
        oversizedPrepare.httpMethod = "POST"
        oversizedPrepare.httpBody = Data(
            repeating: 0x20,
            count: AttachmentUploadV3Policy.maximumPrepareBytes + 1
        )
        oversizedPrepare.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        oversizedPrepare.setValue(
            serverId,
            forHTTPHeaderField: "X-RC2-Expected-Host-ID"
        )
        oversizedPrepare.setValue(
            uploadId,
            forHTTPHeaderField: "Idempotency-Key"
        )
        oversizedPrepare.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        let (_, oversizedResponse) =
            try await URLSession.shared.data(for: oversizedPrepare)
        XCTAssertEqual(
            (oversizedResponse as? HTTPURLResponse)?.statusCode,
            413
        )

        var prepare = URLRequest(
            url: uploadURL.appendingPathComponent("prepare")
        )
        prepare.httpMethod = "POST"
        prepare.httpBody = try JSONEncoder().encode(vector.request)
        prepare.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        prepare.setValue(
            serverId,
            forHTTPHeaderField: "X-RC2-Expected-Host-ID"
        )
        prepare.setValue(uploadId, forHTTPHeaderField: "Idempotency-Key")
        prepare.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        let (prepareData, prepareResponse) =
            try await URLSession.shared.data(for: prepare)
        XCTAssertEqual(
            (prepareResponse as? HTTPURLResponse)?.statusCode,
            200
        )
        let prepareBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: prepareData)
                as? [String: Any]
        )
        XCTAssertEqual(prepareBody["protocol_version"] as? Int, 3)
        XCTAssertEqual(prepareBody["prepared"] as? Bool, true)

        var put = URLRequest(
            url: uploadURL
                .appendingPathComponent("chunks")
                .appendingPathComponent("0")
        )
        put.httpMethod = "PUT"
        put.httpBody = vector.sealed
        put.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
        put.setValue(
            base64URL(vector.capability),
            forHTTPHeaderField: "X-RC2-Chunk-Capability"
        )
        let sealedDigest = sha256Hex(vector.sealed)
        put.setValue(
            sealedDigest,
            forHTTPHeaderField: "X-RC2-Sealed-SHA256"
        )
        put.setValue(
            String(vector.sealed.count),
            forHTTPHeaderField: "X-RC2-Sealed-Bytes"
        )
        put.setValue(
            AttachmentUploadV3Store.idempotencyKey(
                uploadId: uploadId,
                chunkIndex: 0,
                sealedSHA256: sealedDigest
            ),
            forHTTPHeaderField: "Idempotency-Key"
        )
        let missingAuthPut = put
        let (_, missingAuthResponse) =
            try await URLSession.shared.data(for: missingAuthPut)
        XCTAssertEqual(
            (missingAuthResponse as? HTTPURLResponse)?.statusCode,
            401,
            "every protected chunk must require the bearer"
        )

        var wrongAuthPut = put
        wrongAuthPut.setValue(
            "Bearer forged",
            forHTTPHeaderField: "Authorization"
        )
        let (_, wrongAuthResponse) =
            try await URLSession.shared.data(for: wrongAuthPut)
        XCTAssertEqual(
            (wrongAuthResponse as? HTTPURLResponse)?.statusCode,
            401,
            "a chunk capability must not bypass bearer ownership"
        )

        put.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        let (putData, putResponse) =
            try await URLSession.shared.data(for: put)
        XCTAssertEqual((putResponse as? HTTPURLResponse)?.statusCode, 204)
        XCTAssertTrue(putData.isEmpty)

        var status = URLRequest(url: uploadURL)
        status.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        status.setValue(
            serverId,
            forHTTPHeaderField: "X-RC2-Expected-Host-ID"
        )
        status.setValue(uploadId, forHTTPHeaderField: "Idempotency-Key")
        status.setValue(
            workspaceId,
            forHTTPHeaderField: "X-RC2-Workspace-ID"
        )
        let (statusData, statusResponse) =
            try await URLSession.shared.data(for: status)
        XCTAssertEqual(
            (statusResponse as? HTTPURLResponse)?.statusCode,
            200
        )
        let statusBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: statusData)
                as? [String: Any]
        )
        XCTAssertEqual(statusBody["protocol_version"] as? Int, 3)
        XCTAssertEqual(statusBody["state"] as? String, "committed")
        XCTAssertEqual(statusBody["received_bytes"] as? Int, plaintext.count)
    }

    @MainActor
    func test_httpPrepare_ignoresHostIdentityGatesAndStillRequiresBearerOwner() async throws {
        // WHY: prepare.server_id is a client crypto label, not a Mac host gate;
        // X-RC2-Expected-Host-ID must not authorize or block. Bearer + owner still fail closed.
        let token = "valid-test-bearer"
        let otherToken = "other-owner-bearer"
        let otherOwner = String(repeating: "b", count: 64)
        let auth = DualOwnerAuth(
            mappings: [token: owner, otherToken: otherOwner]
        )
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: false,
            dispatcher: JSONRPCDispatcher(
                router: FakeRouter(),
                agentAttachmentUploadCapability: .protectedV3
            ),
            auth: auth,
            serverId: serverId,
            bootEpoch: 1,
            attachmentUploadV2Store: plaintextStore,
            attachmentUploadV3Store: store
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 50_000_000)

        let uploadId = UUID().uuidString.lowercased()
        let vector = try makeVector(
            uploadId: uploadId,
            plaintext: Data("identity-gate".utf8),
            requestServerId: "client-declared-crypto-label"
        )
        let prepareURL = URL(string: "http://127.0.0.1:\(port)")!
            .appendingPathComponent("/v1/agent/attachment-uploads/v3/\(uploadId)/prepare")

        func prepareRequest(
            bearer: String?,
            expectedHost: String?,
            body: AttachmentUploadV3PrepareRequest
        ) throws -> URLRequest {
            var request = URLRequest(url: prepareURL)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(uploadId, forHTTPHeaderField: "Idempotency-Key")
            if let bearer {
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            }
            if let expectedHost {
                request.setValue(expectedHost, forHTTPHeaderField: "X-RC2-Expected-Host-ID")
            }
            return request
        }

        // Missing / invalid bearer fail closed even with matching host header.
        let (_, missingAuth) = try await URLSession.shared.data(
            for: try prepareRequest(bearer: nil, expectedHost: serverId, body: vector.request)
        )
        XCTAssertEqual((missingAuth as? HTTPURLResponse)?.statusCode, 401)

        let (_, badAuth) = try await URLSession.shared.data(
            for: try prepareRequest(bearer: "forged", expectedHost: serverId, body: vector.request)
        )
        XCTAssertEqual((badAuth as? HTTPURLResponse)?.statusCode, 401)

        // Wrong expected-host + client-declared server_id still prepares for owner.
        let (prepareData, prepareResponse) = try await URLSession.shared.data(
            for: try prepareRequest(
                bearer: token,
                expectedHost: "stale-other-host",
                body: vector.request
            )
        )
        XCTAssertEqual((prepareResponse as? HTTPURLResponse)?.statusCode, 200)
        let prepareBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: prepareData) as? [String: Any]
        )
        XCTAssertEqual(prepareBody["prepared"] as? Bool, true)

        // Missing expected-host still succeeds (idempotent prepare).
        let (_, noHost) = try await URLSession.shared.data(
            for: try prepareRequest(bearer: token, expectedHost: nil, body: vector.request)
        )
        XCTAssertEqual((noHost as? HTTPURLResponse)?.statusCode, 200)

        // Different valid owner cannot take over the upload (owner mismatch).
        let otherUploadId = UUID().uuidString.lowercased()
        var foreign = try makeVector(
            uploadId: otherUploadId,
            plaintext: Data("foreign".utf8),
            requestServerId: "client-declared-crypto-label"
        ).request
        // Force owner_fingerprint in body to match token owner while presenting
        // a different bearer → store rejects owner mismatch.
        foreign = AttachmentUploadV3PrepareRequest(
            serverId: foreign.serverId,
            ownerFingerprint: owner,
            workspaceId: foreign.workspaceId,
            filename: foreign.filename,
            mimeType: foreign.mimeType,
            totalPlaintextBytes: foreign.totalPlaintextBytes,
            chunkCount: foreign.chunkCount,
            fileSHA256: foreign.fileSHA256,
            encryptionKeyBase64URL: foreign.encryptionKeyBase64URL,
            chunks: foreign.chunks
        )
        let foreignURL = URL(string: "http://127.0.0.1:\(port)")!
            .appendingPathComponent("/v1/agent/attachment-uploads/v3/\(otherUploadId)/prepare")
        var foreignRequest = URLRequest(url: foreignURL)
        foreignRequest.httpMethod = "POST"
        foreignRequest.httpBody = try JSONEncoder().encode(foreign)
        foreignRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        foreignRequest.setValue(otherUploadId, forHTTPHeaderField: "Idempotency-Key")
        foreignRequest.setValue("Bearer \(otherToken)", forHTTPHeaderField: "Authorization")
        let (foreignData, foreignResponse) = try await URLSession.shared.data(for: foreignRequest)
        XCTAssertEqual((foreignResponse as? HTTPURLResponse)?.statusCode, 400)
        let foreignBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: foreignData) as? [String: Any]
        )
        let foreignError = try XCTUnwrap(foreignBody["error"] as? [String: Any])
        XCTAssertNotEqual(foreignError["code"] as? String, "host_identity_mismatch")
    }

    func test_v3RouteParserRejectsTraversalAndAcceptsFrozenFamily() {
        let id = "11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(
            DirectHTTPServer.attachmentUploadV3Route(
                path: "/v1/agent/attachment-uploads/v3/\(id)/prepare"
            ),
            .prepare(uploadId: id)
        )
        XCTAssertEqual(
            DirectHTTPServer.attachmentUploadV3Route(
                path: "/v1/agent/attachment-uploads/v3/\(id)/chunks/49"
            ),
            .chunk(uploadId: id, index: 49)
        )
        XCTAssertNil(
            DirectHTTPServer.attachmentUploadV3Route(
                path: "/v1/agent/attachment-uploads/v3/\(id)/chunks/50"
            )
        )
        XCTAssertNil(
            DirectHTTPServer.attachmentUploadV3Route(
                path: "/v1//agent/attachment-uploads/v3/\(id)"
            )
        )
    }

    private func makeVector(
        uploadId: String,
        plaintext: Data,
        masterKey: Data = Data(repeating: 0x11, count: 32),
        capability: Data = Data(repeating: 0x33, count: 32),
        nonce: Data = Data(repeating: 0x22, count: 12),
        requestServerId: String? = nil
    ) throws -> Vector {
        let declaredServerId = requestServerId ?? serverId
        let plaintextDigest = sha256Hex(plaintext)
        let capabilityDigest = sha256Hex(capability)
        let placeholder = String(repeating: "0", count: 64)
        func request(sealedDigest: String) -> AttachmentUploadV3PrepareRequest {
            AttachmentUploadV3PrepareRequest(
                serverId: declaredServerId,
                ownerFingerprint: owner,
                workspaceId: workspaceId,
                filename: "vector.bin",
                mimeType: "application/octet-stream",
                totalPlaintextBytes: plaintext.count,
                chunkCount: 1,
                fileSHA256: plaintextDigest,
                encryptionKeyBase64URL: base64URL(masterKey),
                chunks: [
                    .init(
                        index: 0,
                        plaintextBytes: plaintext.count,
                        plaintextSHA256: plaintextDigest,
                        sealedBytes: plaintext.count
                            + AttachmentUploadV3Policy.cipherOverheadBytes,
                        sealedSHA256: sealedDigest,
                        nonceBase64URL: base64URL(nonce),
                        capabilitySHA256: capabilityDigest
                    ),
                ]
            )
        }
        let preliminary = request(sealedDigest: placeholder)
        let aad = try AttachmentUploadV3Store.additionalAuthenticatedData(
            request: preliminary,
            uploadId: uploadId,
            chunk: preliminary.chunks[0]
        )
        let sealed = try AES.GCM.seal(
            plaintext,
            using: AttachmentUploadV3Store.derivedChunkKey(
                masterKey: masterKey,
                serverId: declaredServerId,
                uploadId: uploadId,
                chunkIndex: 0
            ),
            nonce: try AES.GCM.Nonce(data: nonce),
            authenticating: aad
        )
        let combined = try XCTUnwrap(sealed.combined)
        return Vector(
            request: request(sealedDigest: sha256Hex(combined)),
            capability: capability,
            sealed: combined
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
