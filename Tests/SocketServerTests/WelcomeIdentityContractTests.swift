import XCTest
@testable import SocketServer

/// C-W: a pinned iOS reconnect wants to validate the host from the welcome
/// alone (hostId, bootEpoch, API version, capability digest) instead of
/// waiting on the capabilities round trip. Shipped iOS builds decode welcome
/// with an exact key set, so the new fields must only reach clients that ask
/// for them, and the digest must equal the one on the authenticated
/// capabilities response or the client cannot use it to skip that request.
@MainActor
final class WelcomeIdentityContractTests: XCTestCase {
    /// The welcome key set every pre-C-W client decodes with exact-key checks.
    private static let legacyWelcomeKeys: Set<String> = [
        "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
        "serverTimeEpochMs", "heartbeatIntervalMs", "heartbeatTimeoutMs",
        "snapshotTimeoutMs", "currentSequence", "oldestReplaySequence", "capabilities",
    ]
    private static let validDigest = String(repeating: "ab", count: 32)

    private func frame(apiVersion: String? = nil, digest: String? = nil) -> ConnectionWelcomeFrame {
        ConnectionWelcomeFrame(
            protocolVersion: 3, type: "welcome", connectionId: "connection-1",
            hostId: "host-1", bootEpoch: 7, serverTimeEpochMs: 1,
            heartbeatIntervalMs: 10_000, heartbeatTimeoutMs: 30_000,
            snapshotTimeoutMs: 15_000, currentSequence: 5, oldestReplaySequence: 1,
            capabilities: ["events.replay"],
            apiVersion: apiVersion, capabilitiesDigest: digest
        )
    }

    private func keys(_ data: Data) throws -> Set<String> {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    // MARK: - Pure contract

    func test_defaultWelcome_keepsTheExactLegacyKeySet() throws {
        let data = try ConnectionTransportFrame.welcome(frame()).encoded()
        XCTAssertEqual(try keys(data), Self.legacyWelcomeKeys,
                       "a client that did not opt in must get the pre-C-W shape, with no null placeholders")
    }

    func test_identityWelcome_roundTripsThroughTheStrictDecoder() throws {
        let data = try ConnectionTransportFrame.welcome(
            frame(apiVersion: "2", digest: Self.validDigest)
        ).encoded()
        XCTAssertEqual(try keys(data), Self.legacyWelcomeKeys.union(["apiVersion", "capabilitiesDigest"]))
        guard case .welcome(let decoded) = try ConnectionTransportFrame.decodeStrict(data) else {
            return XCTFail("expected a welcome frame")
        }
        XCTAssertEqual(decoded.apiVersion, "2")
        XCTAssertEqual(decoded.capabilitiesDigest, Self.validDigest)
        XCTAssertEqual(decoded.hostId, "host-1")
        XCTAssertEqual(decoded.bootEpoch, 7)
    }

    func test_identityFieldsAreAllOrNothing_andTheDigestIsLowercaseSHA256Hex() throws {
        // A half extension is a host bug the client must not trust.
        for partial in [frame(apiVersion: "2"), frame(digest: Self.validDigest)] {
            XCTAssertThrowsError(try ConnectionTransportFrame.welcome(partial).encoded()) {
                XCTAssertEqual($0 as? ConnectionProtocolFailure, .invalidFrame)
            }
        }
        let full = try XCTUnwrap(JSONSerialization.jsonObject(
            with: ConnectionTransportFrame.welcome(frame(apiVersion: "2", digest: Self.validDigest)).encoded()
        ) as? [String: Any])
        for key in ["apiVersion", "capabilitiesDigest"] {
            var object = full
            object.removeValue(forKey: key)
            XCTAssertThrowsError(try ConnectionTransportFrame.decodeStrict(
                JSONSerialization.data(withJSONObject: object)
            )) { XCTAssertEqual($0 as? ConnectionProtocolFailure, .unknownFields, key) }
        }
        let badDigests = [
            String(repeating: "AB", count: 32),  // uppercase
            String(repeating: "a", count: 63),   // short
            String(repeating: "g", count: 64),   // not hex
        ]
        for digest in badDigests {
            XCTAssertThrowsError(try ConnectionTransportFrame.welcome(frame(apiVersion: "2", digest: digest)).encoded(),
                                 digest)
        }
        XCTAssertThrowsError(try ConnectionTransportFrame.welcome(frame(apiVersion: " ", digest: Self.validDigest)).encoded())
    }

    func test_optInHeader_acceptsOnlyTheIdentityExtension() {
        XCTAssertTrue(ConnectionWelcomeIdentity.isRequested(header: "identity.v1"))
        XCTAssertTrue(ConnectionWelcomeIdentity.isRequested(header: "future.v9, Identity.V1"))
        XCTAssertFalse(ConnectionWelcomeIdentity.isRequested(header: nil))
        XCTAssertFalse(ConnectionWelcomeIdentity.isRequested(header: ""))
        XCTAssertFalse(ConnectionWelcomeIdentity.isRequested(header: "identity.v2"))
        XCTAssertFalse(ConnectionWelcomeIdentity.isRequested(header: "identity.v10"))
    }

    func test_capabilityDigest_isStableForTheSameSetAndChangesWithIt() {
        let a = DirectHTTPServer.capabilitiesProjection(loopbackOnly: true).digest
        let b = DirectHTTPServer.capabilitiesProjection(loopbackOnly: true).digest
        XCTAssertEqual(a, b, "an unchanged capability set must keep its digest across hosts/restarts")
        XCTAssertTrue(ConnectionWelcomeIdentity.isValidDigest(a))
        XCTAssertNotEqual(
            a,
            DirectHTTPServer.capabilitiesProjection(loopbackOnly: false).digest,
            "a changed capability set must change the digest, or the client would reuse stale caps"
        )
        XCTAssertNotEqual(
            a,
            DirectHTTPServer.capabilitiesProjection(loopbackOnly: true, attachmentUpload: Self.attachment).digest
        )
    }

    // MARK: - Live host

    private static let attachment = AgentAttachmentUploadCapabilityAdvertisement(
        protocolVersion: 3,
        maxBytes: 25 * 1024 * 1024,
        chunkBytes: 512 * 1024,
        maxChunkCount: 50,
        maxFilenameBytes: 255,
        maxMIMETypeBytes: 128,
        contentEncodings: ["protected_chunks_v1"],
        cipherOverheadBytes: 28
    )

    private final class BearerAuth: DirectAuthProvider {
        func verify(token: String) -> Bool { token == "good-token" }
        func createPairingCode() -> String? { nil }
        func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? { nil }
        func listDevices() -> [[String: Any]] { [] }
        func revokeDevice(_ id: String) {}
    }

    /// The server holds its auth provider weakly; keep it alive for the test.
    private let auth = BearerAuth()

    private func startServer(serverId: String, bootEpoch: UInt64) throws -> (DirectHTTPServer, UInt16) {
        var lastError: Error?
        for _ in 0..<10 {
            let port = UInt16.random(in: 33000...44000)
            let server = DirectHTTPServer(
                port: port,
                loopbackOnly: true,
                dispatcher: JSONRPCDispatcher(
                    router: FakeRouter(),
                    agentAttachmentUploadCapability: Self.attachment
                ),
                auth: auth,
                serverId: serverId,
                bootEpoch: bootEpoch
            )
            do {
                try server.start()
                return (server, port)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? POSIXError(.EADDRINUSE)
    }

    private func welcome(port: UInt16, optIn: String?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        if let optIn { request.setValue(optIn, forHTTPHeaderField: "X-RC2-Welcome-Fields") }
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw POSIXError(.ETIMEDOUT)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: data = Data()
        }
        XCTAssertNoThrow(try ConnectionTransportFrame.decodeStrict(data),
                         "the live welcome must pass the strict contract decoder")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func authenticatedCapabilities(port: UInt16) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/capabilities/authenticated")!)
        request.setValue("Bearer good-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_liveWelcome_withoutOptIn_isByteShapeCompatibleWithShippedClients() async throws {
        let (server, port) = try startServer(serverId: "cw-legacy", bootEpoch: 9)
        defer { server.stop() }
        let object = try await welcome(port: port, optIn: nil)
        XCTAssertEqual(Set(object.keys), Self.legacyWelcomeKeys,
                       "older iOS builds reject a welcome with any extra key")
    }

    func test_liveWelcome_withOptIn_matchesTheAuthenticatedCapabilitiesIdentityAndDigest() async throws {
        let (server, port) = try startServer(serverId: "cw-identity", bootEpoch: 11)
        defer { server.stop() }
        let caps = try await authenticatedCapabilities(port: port)
        let object = try await welcome(port: port, optIn: "identity.v1")

        XCTAssertEqual(object["hostId"] as? String, caps["server_id"] as? String)
        XCTAssertEqual((object["bootEpoch"] as? NSNumber)?.int64Value,
                       (caps["boot_epoch"] as? NSNumber)?.int64Value)
        XCTAssertEqual(object["apiVersion"] as? String, "2")
        let digest = try XCTUnwrap(caps["capabilities_digest"] as? String)
        XCTAssertEqual(object["capabilitiesDigest"] as? String, digest,
                       "equal digests are the client's proof that its cached capabilities are still current")
    }
}
