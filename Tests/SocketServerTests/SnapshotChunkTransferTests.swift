import CryptoKit
import XCTest
@testable import SocketServer

/// WHY-focused coverage for opt-in resumable snapshot chunks:
/// legacy full path stays intact; chunk path is identity-bound, TTL-bounded,
/// and reassembles to the same authoritative ConnectionSnapshotFrame bytes.
@MainActor
private final class ChunkSnapshotFakeRouter: FakeRouter, ConnectionSnapshotRouting {
    let workspaceID = UUID().uuidString
    let surfaceID = UUID().uuidString
    let threadID = UUID().uuidString
    private(set) var snapshotReadCount = 0

    func readConnectionSnapshotState() throws -> ConnectionSnapshotReadState {
        snapshotReadCount += 1
        return ConnectionSnapshotReadState(
            selectedWorkspaceId: workspaceID,
            workspaces: [.object(["id": .string(workspaceID), "name": .string("Chunk")])],
            surfaces: [ConnectionSnapshotWorkspaceItems(
                workspaceId: workspaceID,
                items: [.object(["id": .string(surfaceID), "type": .string("browser")])]
            )],
            agentThreads: [ConnectionSnapshotWorkspaceItems(
                workspaceId: workspaceID,
                items: [.object([
                    "id": .string(threadID),
                    "workspaceId": .string(workspaceID),
                    "title": .string("Thread"),
                ])]
            )],
            browserStates: [ConnectionSnapshotSurfaceState(
                workspaceId: workspaceID,
                surfaceId: surfaceID,
                state: .object(["url": .string("https://chunk.test")])
            )],
            filesStates: []
        )
    }
}

private final class ChunkSnapshotAuth: DirectAuthProvider {
    private let acceptedTokens: Set<String>
    init(acceptedTokens: Set<String>) { self.acceptedTokens = acceptedTokens }
    func verify(token: String) -> Bool { acceptedTokens.contains(token) }
    func createPairingCode() -> String? { nil }
    func redeemPairingCode(
        _ code: String,
        deviceName: String
    ) -> (deviceId: String, token: String)? { nil }
    func listDevices() -> [[String: Any]] { [] }
    func revokeDevice(_ id: String) {}
}

final class SnapshotChunkTransferTests: XCTestCase {

    // MARK: - Pure codec / cache

    func test_codec_splitAndDigest_areDeterministicAndBounded() {
        // WHY: resume only works if both sides share stable byte splits + digest.
        let payload = Data((0..<50_000).map { UInt8($0 % 251) })
        let chunks = SnapshotChunkCodec.split(payload, chunkBytes: 8_192)
        XCTAssertEqual(chunks.count, SnapshotChunkSizePolicy.chunkCount(
            totalBytes: payload.count,
            chunkBytes: 8_192
        ))
        XCTAssertEqual(Data(chunks.joined()), payload)
        XCTAssertEqual(
            SnapshotChunkCodec.sha256Hex(payload),
            SnapshotChunkCodec.sha256Hex(Data(chunks.joined()))
        )
        XCTAssertEqual(
            SnapshotChunkSizePolicy.negotiate(preferredChunkBytes: 1),
            SnapshotChunkSizePolicy.minimumBytes
        )
        XCTAssertEqual(
            SnapshotChunkSizePolicy.negotiate(preferredChunkBytes: 10_000_000),
            SnapshotChunkSizePolicy.maximumBytes
        )
    }

    func test_adaptivePreference_stableProgressIncreasesWithinBounds() {
        // WHY: client next-transfer growth must raise preferred gradually and
        // never escape host negotiate clamps (no unbounded payload growth).
        var adaptive = SnapshotChunkAdaptivePreference(
            preferredBytes: SnapshotChunkSizePolicy.minimumBytes
        )
        let before = adaptive.preferredBytes
        adaptive.noteStableChunkProgress()
        XCTAssertEqual(adaptive.preferredBytes, before, "growth requires consecutive stable signals")
        adaptive.noteStableChunkProgress()
        XCTAssertEqual(
            adaptive.preferredBytes,
            before + SnapshotChunkSizePolicy.increaseStepBytes
        )
        for _ in 0..<64 {
            adaptive.noteStableChunkProgress()
        }
        XCTAssertEqual(adaptive.preferredBytes, SnapshotChunkSizePolicy.maximumBytes)
        XCTAssertEqual(
            SnapshotChunkSizePolicy.negotiate(preferredChunkBytes: adaptive.preferredBytes),
            SnapshotChunkSizePolicy.maximumBytes
        )
    }

    func test_adaptivePreference_degradeReducesWithFloor() {
        // WHY: timeout/retry/jitter must shrink preferred immediately with a floor.
        var adaptive = SnapshotChunkAdaptivePreference(
            preferredBytes: SnapshotChunkSizePolicy.defaultBytes
        )
        let before = adaptive.preferredBytes
        adaptive.noteDegradedSignal()
        XCTAssertEqual(
            adaptive.preferredBytes,
            before - SnapshotChunkSizePolicy.decreaseStepBytes
        )
        for _ in 0..<64 {
            adaptive.noteDegradedSignal()
        }
        XCTAssertEqual(adaptive.preferredBytes, SnapshotChunkSizePolicy.minimumBytes)
    }

    func test_adaptivePreference_nextTransferOnlyDoesNotMutateActiveRecord() throws {
        // WHY: begin freezes chunkBytes on the transfer; later client preferred
        // adaptation must open a *new* transfer, not rewrite the in-flight one.
        let cache = SnapshotChunkTransferCache()
        let frame = Data((0..<40_000).map { UInt8($0 % 90) })
        var adaptive = SnapshotChunkAdaptivePreference(preferredBytes: 8_192)
        let first = try cache.insert(
            frameBytes: frame,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 1,
            snapshotId: "s1",
            sequence: 1,
            generatedAtEpochMs: 1,
            stateVersion: 3,
            preferredChunkBytes: adaptive.preferredBytes
        ).record
        let frozen = first.chunkBytes
        XCTAssertEqual(frozen, 8_192)

        adaptive.noteStableChunkProgress()
        adaptive.noteStableChunkProgress()
        XCTAssertGreaterThan(adaptive.preferredBytes, frozen)

        // Active transfer record stays at original negotiated size.
        XCTAssertEqual(first.chunkBytes, frozen)
        XCTAssertEqual(first.manifest.chunkBytes, frozen)
        let retry = try cache.fetchChunk(
            transferId: first.transferId,
            chunkIndex: 0,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 1
        )
        XCTAssertEqual(retry.byteCount, min(frozen, frame.count))

        // New begin with adapted preferred yields a different frozen size.
        adaptive.noteDegradedSignal()
        adaptive.noteDegradedSignal()
        let second = try cache.insert(
            frameBytes: frame,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 1,
            snapshotId: "s2",
            sequence: 2,
            generatedAtEpochMs: 2,
            stateVersion: 3,
            preferredChunkBytes: adaptive.preferredBytes
        ).record
        XCTAssertEqual(second.chunkBytes, adaptive.preferredBytes)
        XCTAssertEqual(first.chunkBytes, frozen, "prior transfer must remain immutable")
        XCTAssertNotEqual(first.transferId, second.transferId)
    }

    func test_legacyNilPreferred_stillNegotiatesDefaultWithoutAdaptiveRequirement() {
        // WHY: hosts without client adaptive state / old clients keep default clamp.
        XCTAssertEqual(
            SnapshotChunkSizePolicy.negotiate(preferredChunkBytes: nil),
            SnapshotChunkSizePolicy.defaultBytes
        )
        let adaptive = SnapshotChunkAdaptivePreference()
        XCTAssertEqual(adaptive.preferredBytes, SnapshotChunkSizePolicy.defaultBytes)
    }

    func test_cache_rejectsWrongIdentityAndExpiresDeterministically() throws {
        // WHY: a chunk HTTP request must never bypass ownership or serve after TTL.
        var now: UInt64 = 1_000
        let cache = SnapshotChunkTransferCache(
            clock: { now },
            ttlNanoseconds: 100,
            maxTransfers: 2,
            maxCachedBytes: 1024 * 1024
        )
        let frame = Data("snapshot-frame-bytes-for-cache-test".utf8)
        let record = try cache.insert(
            frameBytes: frame,
            ownerFingerprint: "owner-a",
            connectionId: "conn-1",
            hostId: "host-1",
            bootEpoch: 7,
            snapshotId: "snap-1",
            sequence: 3,
            generatedAtEpochMs: 99,
            stateVersion: 3,
            preferredChunkBytes: 8_192
        ).record
        XCTAssertEqual(record.digest, SnapshotChunkCodec.sha256Hex(frame))
        XCTAssertFalse(record.manifest.jsonObject.keys.contains("token"))
        XCTAssertFalse(record.manifest.jsonObject.keys.contains("authorization"))

        XCTAssertThrowsError(try cache.fetchChunk(
            transferId: record.transferId,
            chunkIndex: 0,
            ownerFingerprint: "owner-b",
            connectionId: "conn-1",
            hostId: "host-1",
            bootEpoch: 7
        )) { error in
            XCTAssertEqual(error as? SnapshotChunkTransferFailure, .identityMismatch)
        }
        XCTAssertThrowsError(try cache.fetchChunk(
            transferId: record.transferId,
            chunkIndex: 0,
            ownerFingerprint: "owner-a",
            connectionId: "conn-2",
            hostId: "host-1",
            bootEpoch: 7
        )) { error in
            XCTAssertEqual(error as? SnapshotChunkTransferFailure, .identityMismatch)
        }
        XCTAssertThrowsError(try cache.fetchChunk(
            transferId: record.transferId,
            chunkIndex: 0,
            ownerFingerprint: "owner-a",
            connectionId: "conn-1",
            hostId: "host-1",
            bootEpoch: 8
        )) { error in
            XCTAssertEqual(error as? SnapshotChunkTransferFailure, .identityMismatch)
        }

        let ok = try cache.fetchChunk(
            transferId: record.transferId,
            chunkIndex: 0,
            ownerFingerprint: "owner-a",
            connectionId: "conn-1",
            hostId: "host-1",
            bootEpoch: 7
        )
        XCTAssertEqual(Data(base64Encoded: ok.payloadBase64), frame)

        now = 1_200
        XCTAssertThrowsError(try cache.fetchChunk(
            transferId: record.transferId,
            chunkIndex: 0,
            ownerFingerprint: "owner-a",
            connectionId: "conn-1",
            hostId: "host-1",
            bootEpoch: 7
        )) { error in
            XCTAssertEqual(error as? SnapshotChunkTransferFailure, .transferExpired)
        }
        XCTAssertEqual(cache.countForTests, 0, "expired transfers must be removed deterministically")
    }

    func test_cache_missingChunkRetryDoesNotRequireReinsert() throws {
        // WHY: after interruption only missing indices are re-fetched from the
        // same transfer identity — accepted chunks must not force a re-begin.
        let cache = SnapshotChunkTransferCache()
        let frame = Data((0..<20_000).map { UInt8($0 % 200) })
        let record = try cache.insert(
            frameBytes: frame,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 1,
            snapshotId: "s",
            sequence: 1,
            generatedAtEpochMs: 1,
            stateVersion: 3,
            preferredChunkBytes: 8_192
        ).record
        XCTAssertGreaterThan(record.chunkCount, 1)
        let first = try record.chunkResponse(index: 0)
        // Simulate retry of chunk 1 only (chunk 0 already accepted client-side).
        let secondA = try cache.fetchChunk(
            transferId: record.transferId,
            chunkIndex: 1,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 1
        )
        let secondB = try cache.fetchChunk(
            transferId: record.transferId,
            chunkIndex: 1,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 1
        )
        XCTAssertEqual(secondA.payloadBase64, secondB.payloadBase64)
        XCTAssertNotEqual(first.payloadBase64, secondA.payloadBase64)
        XCTAssertEqual(cache.countForTests, 1)
    }

    func test_cache_commit_isSingleFlightAndRejectsMismatchWithoutRemoval() throws {
        // WHY: commit is the only authority advance; mismatch must leave the
        // transfer (and thus reservation) intact; success removes exactly once.
        let cache = SnapshotChunkTransferCache()
        let frame = Data("commit-once-frame-bytes".utf8)
        let record = try cache.insert(
            frameBytes: frame,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 2,
            snapshotId: "snap-commit",
            sequence: 42,
            generatedAtEpochMs: 1,
            stateVersion: 3,
            preferredChunkBytes: 8_192
        ).record

        XCTAssertThrowsError(try cache.takeForCommit(
            transferId: record.transferId,
            snapshotId: "snap-commit",
            digest: String(repeating: "ab", count: 32),
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 2
        )) { error in
            XCTAssertEqual(error as? SnapshotChunkTransferFailure, .commitMismatch)
        }
        XCTAssertEqual(cache.countForTests, 1, "digest mismatch must not drop the transfer")

        XCTAssertThrowsError(try cache.takeForCommit(
            transferId: record.transferId,
            snapshotId: "wrong-snap",
            digest: record.digest,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 2
        )) { error in
            XCTAssertEqual(error as? SnapshotChunkTransferFailure, .commitMismatch)
        }
        XCTAssertEqual(cache.countForTests, 1)

        let taken = try cache.takeForCommit(
            transferId: record.transferId,
            snapshotId: "snap-commit",
            digest: record.digest,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 2
        )
        XCTAssertEqual(taken.sequence, 42)
        XCTAssertEqual(cache.countForTests, 0)

        // Second commit is fail-closed: transfer gone, no second adopt source.
        XCTAssertThrowsError(try cache.takeForCommit(
            transferId: record.transferId,
            snapshotId: "snap-commit",
            digest: record.digest,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 2
        )) { error in
            XCTAssertEqual(error as? SnapshotChunkTransferFailure, .transferUnknown)
        }
    }

    func test_cache_commitExpiry_releasesTransferWithoutSequenceSource() throws {
        // WHY: expired transfers must not remain adopt-able; reservation cancel
        // is the caller's job after transferExpired.
        var now: UInt64 = 1_000
        let cache = SnapshotChunkTransferCache(
            clock: { now },
            ttlNanoseconds: 50,
            maxTransfers: 2,
            maxCachedBytes: 1024 * 1024
        )
        let frame = Data("expire-before-commit".utf8)
        let record = try cache.insert(
            frameBytes: frame,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 1,
            snapshotId: "s",
            sequence: 7,
            generatedAtEpochMs: 1,
            stateVersion: 3,
            preferredChunkBytes: 8_192
        ).record
        now = 1_100
        XCTAssertThrowsError(try cache.takeForCommit(
            transferId: record.transferId,
            snapshotId: record.snapshotId,
            digest: record.digest,
            ownerFingerprint: "owner",
            connectionId: "c",
            hostId: "h",
            bootEpoch: 1
        )) { error in
            XCTAssertEqual(error as? SnapshotChunkTransferFailure, .transferExpired)
        }
        XCTAssertEqual(cache.countForTests, 0)
    }

    // MARK: - HTTP integration

    @MainActor
    func test_legacyFullSyncSnapshot_stillWorksWhenChunksCapabilityAdvertised() async throws {
        // WHY: opt-in must not break legacy clients that only call sync.snapshot.
        let router = ChunkSnapshotFakeRouter()
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            serverId: "chunk-host",
            bootEpoch: 11
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let socket = webSocketTask(port: port)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let welcome = try await receiveObject(socket)
        let capabilities = try XCTUnwrap(welcome["capabilities"] as? [String])
        XCTAssertTrue(capabilities.contains(SnapshotChunkCapability.wireName))
        let connectionID = try XCTUnwrap(welcome["connectionId"] as? String)

        let full = try await rpc(
            port: port,
            id: "legacy-full",
            method: "sync.snapshot",
            params: baseParams(connectionID: connectionID)
        )
        XCTAssertNil(full["error"])
        let result = try XCTUnwrap(full["result"] as? [String: Any])
        XCTAssertEqual(result["type"] as? String, "snapshot")
        XCTAssertEqual(result["hostId"] as? String, "chunk-host")
        XCTAssertEqual(router.snapshotReadCount, 1)
    }

    @MainActor
    func test_beginAndChunks_reassembleToAuthoritativeSnapshotFrame() async throws {
        // WHY: final assembled bytes must decode as the same snapshot authority
        // (identity + sequence + state) as the full path would deliver; commit
        // is required before the host treats the transfer as adopted.
        let router = ChunkSnapshotFakeRouter()
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            serverId: "chunk-host",
            bootEpoch: 11
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let socket = webSocketTask(port: port)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let welcome = try await receiveObject(socket)
        let connectionID = try XCTUnwrap(welcome["connectionId"] as? String)

        var beginParams = baseParams(connectionID: connectionID)
        beginParams["preferredChunkBytes"] = 8_192
        let begin = try await rpc(
            port: port,
            id: "begin",
            method: "sync.snapshot.begin",
            params: beginParams
        )
        XCTAssertNil(begin["error"], "\(begin)")
        let manifest = try XCTUnwrap(begin["result"] as? [String: Any])
        XCTAssertEqual(Set(manifest.keys), [
            "transferId", "snapshotId", "connectionId", "hostId", "bootEpoch",
            "sequence", "generatedAtEpochMs", "stateVersion",
            "totalBytes", "chunkCount", "chunkBytes",
            "digestAlgorithm", "digest",
        ])
        XCTAssertFalse(manifest.keys.contains { $0.lowercased().contains("token") })
        XCTAssertEqual(manifest["digestAlgorithm"] as? String, "sha256")
        let transferId = try XCTUnwrap(manifest["transferId"] as? String)
        let snapshotId = try XCTUnwrap(manifest["snapshotId"] as? String)
        let chunkCount = try XCTUnwrap((manifest["chunkCount"] as? NSNumber)?.intValue)
        let totalBytes = try XCTUnwrap((manifest["totalBytes"] as? NSNumber)?.intValue)
        let digest = try XCTUnwrap(manifest["digest"] as? String)
        XCTAssertEqual(router.snapshotReadCount, 1)

        // Out-of-order + duplicate redelivery of chunk 0.
        var assembled = [Data?](repeating: nil, count: chunkCount)
        for index in (0..<chunkCount).reversed() {
            let chunk = try await rpc(
                port: port,
                id: "chunk-\(index)",
                method: "sync.snapshot.chunk",
                params: [
                    "transferId": transferId,
                    "chunkIndex": index,
                    "connectionId": connectionID,
                    "expectedHostId": "chunk-host",
                    "expectedBootEpoch": 11,
                ]
            )
            XCTAssertNil(chunk["error"], "\(chunk)")
            let body = try XCTUnwrap(chunk["result"] as? [String: Any])
            let b64 = try XCTUnwrap(body["payloadBase64"] as? String)
            assembled[index] = try XCTUnwrap(Data(base64Encoded: b64))
        }
        // Retry an already-accepted chunk without re-begin.
        let retry = try await rpc(
            port: port,
            id: "chunk-0-retry",
            method: "sync.snapshot.chunk",
            params: [
                "transferId": transferId,
                "chunkIndex": 0,
                "connectionId": connectionID,
                "expectedHostId": "chunk-host",
                "expectedBootEpoch": 11,
            ]
        )
        XCTAssertNil(retry["error"])
        XCTAssertEqual(router.snapshotReadCount, 1, "chunk retries must not re-read host state")

        let frameData = assembled.compactMap { $0 }.reduce(into: Data()) { $0.append($1) }
        XCTAssertEqual(frameData.count, totalBytes)
        XCTAssertEqual(SnapshotChunkCodec.sha256Hex(frameData), digest)
        let frame = try ConnectionTransportFrame.decodeStrict(frameData)
        guard case .snapshot(let snapshot) = frame else {
            return XCTFail("assembled bytes must be a snapshot transport frame")
        }
        XCTAssertEqual(snapshot.connectionId, connectionID)
        XCTAssertEqual(snapshot.hostId, "chunk-host")
        XCTAssertEqual(snapshot.bootEpoch, 11)
        XCTAssertEqual(snapshot.stateVersion, 3)
        XCTAssertEqual(snapshot.snapshotId, snapshotId)

        let commit = try await rpc(
            port: port,
            id: "commit",
            method: "sync.snapshot.commit",
            params: [
                "transferId": transferId,
                "snapshotId": snapshotId,
                "digest": digest,
                "connectionId": connectionID,
                "expectedHostId": "chunk-host",
                "expectedBootEpoch": 11,
            ]
        )
        XCTAssertNil(commit["error"], "\(commit)")
        let commitResult = try XCTUnwrap(commit["result"] as? [String: Any])
        XCTAssertEqual(commitResult["committed"] as? Bool, true)
        XCTAssertEqual(commitResult["transferId"] as? String, transferId)
        XCTAssertEqual(commitResult["snapshotId"] as? String, snapshotId)
    }

    @MainActor
    func test_chunk_failClosed_wrongOwnerWrongHostAndUnknownTransfer() async throws {
        // WHY: chunk HTTP must not bypass WS/HTTP auth or ownership gates.
        let tokenA = "chunk-owner-a"
        let tokenB = "chunk-owner-b"
        let auth = ChunkSnapshotAuth(acceptedTokens: [tokenA, tokenB])
        let router = ChunkSnapshotFakeRouter()
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: false,
            dispatcher: JSONRPCDispatcher(router: router),
            auth: auth,
            serverId: "chunk-host",
            bootEpoch: 11
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue("Bearer \(tokenA)", forHTTPHeaderField: "Authorization")
        request.setValue("\(EventBus.shared.currentSeq)", forHTTPHeaderField: "x-rc2-since-seq")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let welcome = try await receiveObject(socket)
        let connectionID = try XCTUnwrap(welcome["connectionId"] as? String)

        let begin = try await rpc(
            port: port,
            id: "begin-a",
            method: "sync.snapshot.begin",
            params: baseParams(connectionID: connectionID),
            bearerToken: tokenA
        )
        let transferId = try XCTUnwrap((begin["result"] as? [String: Any])?["transferId"] as? String)

        let wrongOwner = try await rpc(
            port: port,
            id: "chunk-b",
            method: "sync.snapshot.chunk",
            params: [
                "transferId": transferId,
                "chunkIndex": 0,
                "connectionId": connectionID,
                "expectedHostId": "chunk-host",
                "expectedBootEpoch": 11,
            ],
            bearerToken: tokenB
        )
        XCTAssertEqual((wrongOwner["error"] as? [String: Any])?["code"] as? Int, -32602)

        let wrongHost = try await rpc(
            port: port,
            id: "chunk-host-mismatch",
            method: "sync.snapshot.chunk",
            params: [
                "transferId": transferId,
                "chunkIndex": 0,
                "connectionId": connectionID,
                "expectedHostId": "other-host",
                "expectedBootEpoch": 11,
            ],
            bearerToken: tokenA
        )
        XCTAssertEqual((wrongHost["error"] as? [String: Any])?["code"] as? Int, -32602)

        let unknown = try await rpc(
            port: port,
            id: "chunk-unknown",
            method: "sync.snapshot.chunk",
            params: [
                "transferId": UUID().uuidString,
                "chunkIndex": 0,
                "connectionId": connectionID,
                "expectedHostId": "chunk-host",
                "expectedBootEpoch": 11,
            ],
            bearerToken: tokenA
        )
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32041)
    }

    @MainActor
    func test_begin_rejectsMalformedPreferredChunkAndDoesNotAdoptUntilCommit() async throws {
        // WHY: begin may only reserve; authority advances on commit after verified
        // assembly. Proven via watermark single-flight fence + commit single-flight.
        let router = ChunkSnapshotFakeRouter()
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            serverId: "chunk-host",
            bootEpoch: 11
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let socket = webSocketTask(port: port)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let welcome = try await receiveObject(socket)
        let connectionID = try XCTUnwrap(welcome["connectionId"] as? String)

        var bad = baseParams(connectionID: connectionID)
        bad["preferredChunkBytes"] = -1
        let invalid = try await rpc(
            port: port,
            id: "bad-chunk",
            method: "sync.snapshot.begin",
            params: bad
        )
        XCTAssertEqual((invalid["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual(router.snapshotReadCount, 0)

        let ok = try await rpc(
            port: port,
            id: "ok-begin",
            method: "sync.snapshot.begin",
            params: baseParams(connectionID: connectionID)
        )
        XCTAssertNil(ok["error"], "\(ok)")
        let manifest = try XCTUnwrap(ok["result"] as? [String: Any])
        let sequence = try XCTUnwrap((manifest["sequence"] as? NSNumber)?.int64Value)
        XCTAssertGreaterThanOrEqual(sequence, 0)
        XCTAssertEqual(router.snapshotReadCount, 1)
        let transferId = try XCTUnwrap(manifest["transferId"] as? String)
        let snapshotId = try XCTUnwrap(manifest["snapshotId"] as? String)
        let digest = try XCTUnwrap(manifest["digest"] as? String)

        // Reservation held: second begin must fail closed without advancing.
        let secondBegin = try await rpc(
            port: port,
            id: "second-begin",
            method: "sync.snapshot.begin",
            params: baseParams(connectionID: connectionID)
        )
        XCTAssertEqual((secondBegin["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual(router.snapshotReadCount, 1, "failed begin must not re-read host state")

        // Commit mismatch leaves reservation/transfer intact (no adopt).
        let badCommit = try await rpc(
            port: port,
            id: "bad-commit",
            method: "sync.snapshot.commit",
            params: [
                "transferId": transferId,
                "snapshotId": snapshotId,
                "digest": String(repeating: "00", count: 32),
                "connectionId": connectionID,
                "expectedHostId": "chunk-host",
                "expectedBootEpoch": 11,
            ]
        )
        XCTAssertEqual((badCommit["error"] as? [String: Any])?["code"] as? Int, -32602)
        let stillBlocked = try await rpc(
            port: port,
            id: "still-blocked",
            method: "sync.snapshot.begin",
            params: baseParams(connectionID: connectionID)
        )
        XCTAssertEqual((stillBlocked["error"] as? [String: Any])?["code"] as? Int, -32602)

        let commit = try await rpc(
            port: port,
            id: "good-commit",
            method: "sync.snapshot.commit",
            params: [
                "transferId": transferId,
                "snapshotId": snapshotId,
                "digest": digest,
                "connectionId": connectionID,
                "expectedHostId": "chunk-host",
                "expectedBootEpoch": 11,
            ]
        )
        XCTAssertNil(commit["error"], "\(commit)")
        XCTAssertEqual((commit["result"] as? [String: Any])?["committed"] as? Bool, true)

        // Single-flight: second commit cannot re-adopt (transfer gone).
        let doubleCommit = try await rpc(
            port: port,
            id: "double-commit",
            method: "sync.snapshot.commit",
            params: [
                "transferId": transferId,
                "snapshotId": snapshotId,
                "digest": digest,
                "connectionId": connectionID,
                "expectedHostId": "chunk-host",
                "expectedBootEpoch": 11,
            ]
        )
        XCTAssertEqual((doubleCommit["error"] as? [String: Any])?["code"] as? Int, -32041)

        // After successful commit the fence is released for a new begin.
        let afterCommitBegin = try await rpc(
            port: port,
            id: "after-commit-begin",
            method: "sync.snapshot.begin",
            params: baseParams(connectionID: connectionID)
        )
        XCTAssertNil(afterCommitBegin["error"], "\(afterCommitBegin)")
        XCTAssertEqual(router.snapshotReadCount, 2)
    }

    @MainActor
    func test_commit_withoutAssemblyCredentials_isFailClosed() async throws {
        // WHY: incomplete client path never holds real digest/snapshotId from a
        // live transfer; forged commit must not advance authority.
        let router = ChunkSnapshotFakeRouter()
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            serverId: "chunk-host",
            bootEpoch: 11
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let socket = webSocketTask(port: port)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let welcome = try await receiveObject(socket)
        let connectionID = try XCTUnwrap(welcome["connectionId"] as? String)

        let forged = try await rpc(
            port: port,
            id: "forged-commit",
            method: "sync.snapshot.commit",
            params: [
                "transferId": UUID().uuidString,
                "snapshotId": UUID().uuidString,
                "digest": String(repeating: "ab", count: 32),
                "connectionId": connectionID,
                "expectedHostId": "chunk-host",
                "expectedBootEpoch": 11,
            ]
        )
        XCTAssertEqual((forged["error"] as? [String: Any])?["code"] as? Int, -32041)

        // Begin still available — forged commit did not leave a stuck fence.
        let begin = try await rpc(
            port: port,
            id: "begin-after-forged",
            method: "sync.snapshot.begin",
            params: baseParams(connectionID: connectionID)
        )
        XCTAssertNil(begin["error"], "\(begin)")
    }

    // MARK: - Helpers

    private func baseParams(connectionID: String) -> [String: Any] {
        [
            "connectionId": connectionID,
            "expectedHostId": "chunk-host",
            "expectedBootEpoch": 11,
            "supportedStateVersion": 3,
        ]
    }

    @MainActor
    private func receiveObject(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: data = Data()
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    private func webSocketTask(port: UInt16) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue(
            "\(EventBus.shared.currentSeq)",
            forHTTPHeaderField: "x-rc2-since-seq"
        )
        return URLSession.shared.webSocketTask(with: request)
    }

    @MainActor
    private func rpc(
        port: UInt16,
        id: String,
        method: String,
        params: [String: Any],
        bearerToken: String? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
