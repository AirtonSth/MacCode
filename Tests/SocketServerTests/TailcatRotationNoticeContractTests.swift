import CryptoKit
import Darwin
import RemoteCodeTreaty
import XCTest
@testable import SocketServer

/// F5: before the Mac rotates its Tailcat keys it tells a connected phone that
/// its saved address is about to stop (`host.tailcat.rotating`), and a phone
/// that reconnects reads the digest of the published endpoints in the welcome.
/// Shipped iPhones decode the welcome with an exact key set and end the stream
/// on an unknown frame type, so both must reach only a socket whose upgrade
/// listed `tailcat.rotation_notice.v1`. Live tests wait on a counter or on a
/// marker event: `EventBus.shared` is one counter for the whole test process.
@MainActor
final class TailcatRotationNoticeContractTests: XCTestCase {
    /// The welcome key set every client that did not ask decodes with exact-key checks.
    private static let legacyWelcomeKeys: Set<String> = [
        "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
        "serverTimeEpochMs", "heartbeatIntervalMs", "heartbeatTimeoutMs",
        "snapshotTimeoutMs", "currentSequence", "oldestReplaySequence", "capabilities",
    ]
    private static let rotatingKeys: Set<String> = [
        "protocolVersion", "type", "connectionId", "hostId", "bootEpoch", "retiringDigest",
    ]
    private static let feature = "tailcat.rotation_notice.v1"
    /// Two endpoint digests of the spec's vector table (V4 and V5).
    private static let publishedDigest = "15b48f53ead19fe5862e0892d09e068ca614eec2df67e6aa7c82eeca72e6f7c4"
    private static let retiringDigest = "fab36afaecc72a73b73665294ceb4ae63d78118c5568cf8bdda6660b252eb18e"
    private static let badDigests = [
        String(repeating: "AB", count: 32),  // uppercase
        String(repeating: "a", count: 63),   // short
        String(repeating: "g", count: 64),   // not hex
    ]

    /// The server holds its auth provider weakly; keep it alive for the test.
    private let auth = RotationNoticeAuth()
    private let secret = Data(repeating: 0x11, count: 32)
    private let listenerID = Data(repeating: 0x22, count: 16)
    private let peer = Data(repeating: 0x33, count: 32)

    // MARK: - Pure contract

    func test_featureHeader_matchesOnlyTheExactRotationNoticeToken() {
        // A looser match would send a frame type the client cannot parse, which is terminal.
        XCTAssertEqual(ConnectionClientFeatures.header, "x-rc2-client-features")
        XCTAssertTrue(ConnectionClientFeatures.requestsTailcatRotationNotice(header: "tailcat.rotation_notice.v1"))
        XCTAssertTrue(ConnectionClientFeatures.requestsTailcatRotationNotice(
            header: "future.v9, tailcat.rotation_notice.v1"
        ))
        XCTAssertTrue(ConnectionClientFeatures.requestsTailcatRotationNotice(header: "Tailcat.Rotation_Notice.V1"))
        XCTAssertFalse(ConnectionClientFeatures.requestsTailcatRotationNotice(header: nil))
        XCTAssertFalse(ConnectionClientFeatures.requestsTailcatRotationNotice(header: ""))
        XCTAssertFalse(ConnectionClientFeatures.requestsTailcatRotationNotice(header: "tailcat.rotation_notice.v2"))
        XCTAssertFalse(ConnectionClientFeatures.requestsTailcatRotationNotice(header: "tailcat.rotation_notice.v10"))
        XCTAssertFalse(ConnectionClientFeatures.requestsTailcatRotationNotice(header: "identity.v1"))
    }

    func test_welcomeDigest_isOmittedByDefault_andStrictWhenPresent() throws {
        let plain = try ConnectionTransportFrame.welcome(welcomeFrame()).encoded()
        XCTAssertEqual(try keys(plain), Self.legacyWelcomeKeys,
                       "absent must mean no information: no key and no null placeholder")

        let data = try ConnectionTransportFrame.welcome(welcomeFrame(digest: Self.publishedDigest)).encoded()
        XCTAssertEqual(try keys(data), Self.legacyWelcomeKeys.union(["tailcatEndpointDigest"]))
        guard case .welcome(let decoded) = try ConnectionTransportFrame.decodeStrict(data) else {
            return XCTFail("expected a welcome frame")
        }
        XCTAssertEqual(decoded.tailcatEndpointDigest, Self.publishedDigest)

        let full = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for bad in Self.badDigests {
            XCTAssertThrowsError(try ConnectionTransportFrame.welcome(welcomeFrame(digest: bad)).encoded(), bad) {
                XCTAssertEqual($0 as? ConnectionProtocolFailure, .invalidFrame)
            }
            var object = full
            object["tailcatEndpointDigest"] = bad
            XCTAssertThrowsError(try ConnectionTransportFrame.decodeStrict(
                JSONSerialization.data(withJSONObject: object)
            ), bad) { XCTAssertEqual($0 as? ConnectionProtocolFailure, .invalidFrame) }
        }
        // A null would break a client that decodes the welcome with an exact key set.
        var withNull = full
        withNull["tailcatEndpointDigest"] = NSNull()
        XCTAssertThrowsError(try ConnectionTransportFrame.decodeStrict(
            JSONSerialization.data(withJSONObject: withNull)
        )) { XCTAssertEqual($0 as? ConnectionProtocolFailure, .invalidFrame) }
    }

    func test_rotatingFrame_strictContract_hasExactlySixKeys() throws {
        let data = try XCTUnwrap(ConnectionClientFeatures.tailcatRotatingData(
            connectionId: "connection-1", hostId: "host-1", bootEpoch: 42,
            retiringDigest: Self.retiringDigest
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Self.rotatingKeys,
                       "the frame carries a digest and the socket's identity, nothing else")
        XCTAssertEqual(object["type"] as? String, "host.tailcat.rotating")
        guard case .tailcatRotating(let frame) = try ConnectionTransportFrame.decodeStrict(data) else {
            return XCTFail("expected a rotating frame")
        }
        XCTAssertEqual(frame, ConnectionTailcatRotatingFrame(
            protocolVersion: 3, type: "host.tailcat.rotating", connectionId: "connection-1",
            hostId: "host-1", bootEpoch: 42, retiringDigest: Self.retiringDigest
        ))

        for bad in Self.badDigests {
            XCTAssertNil(ConnectionClientFeatures.tailcatRotatingData(
                connectionId: "connection-1", hostId: "host-1", bootEpoch: 42, retiringDigest: bad
            ), bad)
            var invalid = object
            invalid["retiringDigest"] = bad
            XCTAssertThrowsError(try ConnectionTransportFrame.decodeStrict(
                JSONSerialization.data(withJSONObject: invalid)
            ), bad) { XCTAssertEqual($0 as? ConnectionProtocolFailure, .invalidFrame) }
        }
        // No secret in the frame: an address, a key or a sequence is refused.
        let extras: [String: Any] = ["connBlob": "blob", "sequence": 7]
        for (key, value) in extras {
            var widened = object
            widened[key] = value
            XCTAssertThrowsError(try ConnectionTransportFrame.decodeStrict(
                JSONSerialization.data(withJSONObject: widened)
            ), key) { XCTAssertEqual($0 as? ConnectionProtocolFailure, .unknownFields) }
        }
    }

    // MARK: - Live host

    func test_liveWelcome_withoutTheFeatureHeader_keepsTheLegacyKeySet_evenWhenADigestIsPublished() async throws {
        let (server, port) = try startServer(serverId: "f5-legacy")
        defer { server.stop() }
        server.setTailcatEndpointDigest(Self.publishedDigest)

        let plain = try await welcome(port: port, features: nil)
        XCTAssertEqual(Set(plain.keys), Self.legacyWelcomeKeys,
                       "shipped iPhones reject a welcome with any extra key")
        let otherToken = try await welcome(port: port, features: "tailcat.rotation_notice.v2")
        XCTAssertEqual(Set(otherToken.keys), Self.legacyWelcomeKeys)
        let identityOnly = try await welcome(port: port, features: nil, welcomeFields: "identity.v1")
        XCTAssertEqual(Set(identityOnly.keys), Self.legacyWelcomeKeys.union(ConnectionWelcomeIdentity.keys),
                       "another opt-in must not bring the Tailcat digest with it")
    }

    func test_liveWelcome_withTheFeatureHeader_carriesThePublishedDigest_andOmitsItWhenNothingIsPublished() async throws {
        let (server, port) = try startServer(serverId: "f5-digest")
        defer { server.stop() }
        server.setTailcatEndpointDigest(Self.publishedDigest)
        let published = try await welcome(port: port, features: Self.feature)
        XCTAssertEqual(Set(published.keys), Self.legacyWelcomeKeys.union(["tailcatEndpointDigest"]))
        XCTAssertEqual(published["tailcatEndpointDigest"] as? String, Self.publishedDigest)

        // A stale digest in a welcome would describe an address nobody serves.
        server.setTailcatEndpointDigest(nil)
        let unpublished = try await welcome(port: port, features: Self.feature)
        XCTAssertEqual(Set(unpublished.keys), Self.legacyWelcomeKeys, "omitted, never null")

        // A malformed value is stored as "no information"; it must not cost the socket its welcome.
        server.setTailcatEndpointDigest("not-a-digest")
        let malformed = try await welcome(port: port, features: Self.feature)
        XCTAssertEqual(Set(malformed.keys), Self.legacyWelcomeKeys)
    }

    func test_rotationNotice_reachesOnlySocketsThatAskedForIt_andIsNotAnEventBusEvent() async throws {
        let (server, port) = try startServer(serverId: "f5-notice")
        defer { server.stop() }
        let asked = socket(port: port, features: Self.feature)
        defer { asked.cancel(with: .goingAway, reason: nil) }
        let legacy = socket(port: port, features: nil)
        defer { legacy.cancel(with: .goingAway, reason: nil) }
        let askedWelcome = try await next(asked)
        XCTAssertEqual(askedWelcome["type"] as? String, "welcome")
        let legacyWelcome = try await next(legacy)
        XCTAssertEqual(Set(legacyWelcome.keys), Self.legacyWelcomeKeys)
        // Both are subscribed, which happens after the point where a sink is registered.
        let streaming = await waitUntil { server.wsTracker.activeClients == 2 }
        XCTAssertTrue(streaming)
        XCTAssertEqual(server.tailcatRotationNoticeSocketCountForTesting, 1,
                       "only the socket that listed the feature has a sink")

        let observed = ObservedEventKinds()
        let subscriber = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            observed.append(event.kind)
        }
        defer { EventBus.shared.unsubscribe(subscriber) }

        XCTAssertEqual(server.announceTailcatRotation(retiringDigest: Self.retiringDigest), 1)

        let askedFrames = try await frames(asked) { $0["type"] as? String == "host.tailcat.rotating" }
        let notice = try XCTUnwrap(askedFrames.last)
        XCTAssertEqual(Set(notice.keys), Self.rotatingKeys, "no sequence: the frame never moves a cursor")
        XCTAssertEqual(notice["retiringDigest"] as? String, Self.retiringDigest)
        XCTAssertEqual(notice["connectionId"] as? String, askedWelcome["connectionId"] as? String)
        XCTAssertEqual(notice["hostId"] as? String, "f5-notice")
        XCTAssertEqual((notice["bootEpoch"] as? NSNumber)?.uint64Value, 42)
        XCTAssertNoThrow(try ConnectionTransportFrame.decodeStrict(
            JSONSerialization.data(withJSONObject: notice)
        ))

        // A frame the legacy socket cannot parse is terminal on an old iPhone.
        let name = "f5-after-\(UUID().uuidString)"
        publishMarker(name)
        let legacyFrames = try await frames(legacy) { self.marker($0) == name }
        XCTAssertEqual(marker(legacyFrames.last ?? [:]), name)
        XCTAssertFalse(legacyFrames.contains { $0["type"] as? String == "host.tailcat.rotating" })
        let sequences = legacyFrames.compactMap { ($0["sequence"] as? NSNumber)?.int64Value }
        XCTAssertFalse(sequences.isEmpty)
        XCTAssertTrue(zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 },
                      "event sequences on the legacy socket stay ordered")

        // An EventBus kind would be replayed to clients that never asked.
        XCTAssertTrue(observed.values.contains("workspace.updated"), "the subscriber was live across the announce")
        XCTAssertFalse(observed.values.contains("host.tailcat.rotating"))
        XCTAssertFalse(EventBus.shared.snapshot().recent.contains { $0.kind == "host.tailcat.rotating" })
    }

    func test_rotationNotice_afterSocketClose_reachesNobody() async throws {
        let (server, port) = try startServer(serverId: "f5-closed")
        defer { server.stop() }
        let asked = socket(port: port, features: Self.feature)
        _ = try await next(asked)
        let registered = await waitUntil { server.tailcatRotationNoticeSocketCountForTesting == 1 }
        XCTAssertTrue(registered)

        asked.cancel(with: .goingAway, reason: nil)
        // A leaked sink would write to a descriptor the system may hand to another socket.
        let released = await waitUntil { server.tailcatRotationNoticeSocketCountForTesting == 0 }
        XCTAssertTrue(released, "the sink must go away with the connection")
        XCTAssertEqual(server.announceTailcatRotation(retiringDigest: Self.retiringDigest), 0)
    }

    // MARK: - Listener (the only thing the supervisor knows)

    func test_listenerForwardsTheDigestToAServerSetLater() async throws {
        // The HTTP server is recreated at every wake; the new one must not start without the digest.
        let listener = TailcatLoopbackListener(authenticator: TailcatRemoteConnectionAuthenticator())
        listener.setPublishedEndpointDigest(Self.publishedDigest)
        let (server, port) = try startServer(serverId: "f5-listener-digest")
        defer { server.stop() }
        listener.setHTTPServer(server)

        let published = try await welcome(port: port, features: Self.feature)
        XCTAssertEqual(published["tailcatEndpointDigest"] as? String, Self.publishedDigest)

        listener.setPublishedEndpointDigest(nil)
        let unpublished = try await welcome(port: port, features: Self.feature)
        XCTAssertEqual(Set(unpublished.keys), Self.legacyWelcomeKeys)
    }

    func test_listenerForwardsTheRotationNoticeToTheServer() async throws {
        // With the protocol's empty default the notice would never leave the Mac.
        let listener = TailcatLoopbackListener(authenticator: TailcatRemoteConnectionAuthenticator())
        let (server, port) = try startServer(serverId: "f5-listener-notice")
        defer { server.stop() }
        listener.setHTTPServer(server)
        let asked = socket(port: port, features: Self.feature)
        defer { asked.cancel(with: .goingAway, reason: nil) }
        _ = try await next(asked)
        let registered = await waitUntil { server.tailcatRotationNoticeSocketCountForTesting == 1 }
        XCTAssertTrue(registered)

        listener.announceRotation(retiringDigest: Self.retiringDigest)
        let askedFrames = try await frames(asked) { $0["type"] as? String == "host.tailcat.rotating" }
        XCTAssertEqual(askedFrames.last?["retiringDigest"] as? String, Self.retiringDigest)

        // Without a server the listener has nobody to tell.
        listener.setHTTPServer(nil)
        listener.announceRotation(retiringDigest: Self.publishedDigest)
        let streaming = await waitUntil { server.wsTracker.activeClients == 1 }
        XCTAssertTrue(streaming)
        let name = "f5-detached-\(UUID().uuidString)"
        publishMarker(name)
        let later = try await frames(asked) { self.marker($0) == name }
        XCTAssertEqual(marker(later.last ?? [:]), name)
        XCTAssertFalse(later.contains { $0["type"] as? String == "host.tailcat.rotating" })
    }

    func test_tailcatScopeSocket_getsTheWelcomeDigestButNoRotationSink() async throws {
        // The rotation shuts a Tailcat-scope socket down in the same turn: a frame
        // queued for it fails its write, which is recorded as a slow-client drop
        // and publishes a diagnostic event to every other socket.
        let server = DirectHTTPServer(
            port: UInt16.random(in: 44_001...54_000),
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            auth: auth,
            serverId: "f5-tailcat-scope",
            bootEpoch: 42
        )
        let listener = TailcatLoopbackListener(authenticator: configuredAuthenticator())
        listener.setHTTPServer(server)
        listener.setPublishedEndpointDigest(Self.publishedDigest)
        let port = try listener.start()
        defer { listener.stop() }

        let fd = try connectIPv4(port: port)
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let upgrade = "GET /v1/ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
            + "Authorization: Bearer good-token\r\nX-RC2-Since-Seq: \(EventBus.shared.currentSeq)\r\n"
            + "X-RC2-Client-Features: \(Self.feature)\r\n\r\n"
        try writeAll(fd: fd, payload: preamble(counter: 1) + Data(upgrade.utf8))
        var reader = RawWebSocketReader(fd: fd)
        let head = try reader.upgradeResponseHead()
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101"), head)
        let first = try reader.nextTextFrame()
        XCTAssertEqual(first["type"] as? String, "welcome")
        XCTAssertEqual(first["tailcatEndpointDigest"] as? String, Self.publishedDigest,
                       "a phone that reconnects over Tailcat still reads the published digest")

        // The subscription is installed after the point where a sink would be
        // registered, so a marker delivered on this socket proves that point passed.
        let streaming = await waitUntil { server.wsTracker.activeClients == 1 }
        XCTAssertTrue(streaming)
        let name = "f5-scope-\(UUID().uuidString)"
        publishMarker(name)
        var delivered = false
        var budget = 400
        while !delivered, budget > 0 {
            let frame = try reader.nextTextFrame()
            delivered = marker(frame) == name
            budget -= 1
        }
        XCTAssertTrue(delivered)
        XCTAssertEqual(server.tailcatRotationNoticeSocketCountForTesting, 0)
        XCTAssertEqual(server.announceTailcatRotation(retiringDigest: Self.publishedDigest), 0)
    }

    // MARK: - Helpers

    private func welcomeFrame(digest: String? = nil) -> ConnectionWelcomeFrame {
        ConnectionWelcomeFrame(
            protocolVersion: 3, type: "welcome", connectionId: "connection-1",
            hostId: "host-1", bootEpoch: 7, serverTimeEpochMs: 1,
            heartbeatIntervalMs: 10_000, heartbeatTimeoutMs: 30_000,
            snapshotTimeoutMs: 15_000, currentSequence: 5, oldestReplaySequence: 1,
            capabilities: ["events.replay"],
            tailcatEndpointDigest: digest
        )
    }

    private func keys(_ data: Data) throws -> Set<String> {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    private func startServer(serverId: String) throws -> (DirectHTTPServer, UInt16) {
        var lastError: Error?
        for _ in 0..<10 {
            let port = UInt16.random(in: 33000...44000)
            let server = DirectHTTPServer(
                port: port, loopbackOnly: true,
                dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                serverId: serverId, bootEpoch: 42
            )
            do { try server.start(); return (server, port) } catch { lastError = error }
        }
        throw lastError ?? POSIXError(.EADDRINUSE)
    }

    /// A LAN (loopback) socket that starts at the current sequence, so it gets
    /// no backlog of events other tests published.
    private func socket(
        port: UInt16, features: String?, welcomeFields: String? = nil
    ) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue("\(EventBus.shared.currentSeq)", forHTTPHeaderField: "X-RC2-Since-Seq")
        if let features { request.setValue(features, forHTTPHeaderField: "X-RC2-Client-Features") }
        if let welcomeFields { request.setValue(welcomeFields, forHTTPHeaderField: "X-RC2-Welcome-Fields") }
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1_024 * 1_024
        task.resume()
        return task
    }

    private func next(_ task: URLSessionWebSocketTask, seconds: Double = 10) async throws -> [String: Any] {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
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
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every frame, heartbeats included, up to and including the first one `stop` accepts.
    private func frames(
        _ task: URLSessionWebSocketTask,
        until stop: ([String: Any]) -> Bool
    ) async throws -> [[String: Any]] {
        var collected: [[String: Any]] = []
        for _ in 0..<400 {
            let frame = try await next(task)
            collected.append(frame)
            if stop(frame) { return collected }
        }
        XCTFail("frame budget exhausted")
        return collected
    }

    /// The first frame of a new socket, which must be a welcome the strict decoder accepts.
    private func welcome(
        port: UInt16, features: String?, welcomeFields: String? = nil
    ) async throws -> [String: Any] {
        let task = socket(port: port, features: features, welcomeFields: welcomeFields)
        defer { task.cancel(with: .goingAway, reason: nil) }
        let object = try await next(task)
        XCTAssertEqual(object["type"] as? String, "welcome")
        XCTAssertNoThrow(try ConnectionTransportFrame.decodeStrict(
            JSONSerialization.data(withJSONObject: object)
        ), "the live welcome must pass the strict contract decoder")
        return object
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func publishMarker(_ name: String) {
        EventBus.shared.publish(kind: .workspaceUpdated, payload: .object([
            "workspace_id": .string("w-f5-notice"), "name": .string(name),
        ]))
    }

    private func marker(_ frame: [String: Any]) -> String? {
        (frame["payload"] as? [String: Any])?["name"] as? String
    }

    // MARK: - Tailcat scope (preamble and bearer, as in TailcatLoopbackListenerTests)

    private func configuredAuthenticator() -> TailcatRemoteConnectionAuthenticator {
        let authenticator = TailcatRemoteConnectionAuthenticator()
        authenticator.replaceContexts([.init(
            serverID: "host.primary",
            listenerID: listenerID,
            secret: secret,
            allowedPeerPublic: ["nodekey:" + peer.map { String(format: "%02x", $0) }.joined()]
        )])
        return authenticator
    }

    private func preamble(counter: UInt64) -> Data {
        var authenticated = Data("RCTC".utf8)
        authenticated.append(1)
        authenticated.append(contentsOf: [0, 0, 0])
        authenticated.append(listenerID)
        authenticated.append(Data(SHA256.hash(data: Data("host.primary".utf8))))
        var bigEndianCounter = counter.bigEndian
        withUnsafeBytes(of: &bigEndianCounter) { authenticated.append(contentsOf: $0) }
        authenticated.append(Data(repeating: UInt8(counter), count: 16))
        authenticated.append(peer)
        authenticated.append(contentsOf: HMAC<SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: secret)
        ))
        return authenticated
    }

    private func connectIPv4(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }

    private func writeAll(fd: Int32, payload: Data) throws {
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
    }
}

/// Reads the host's side of a WebSocket from a raw descriptor (host frames are unmasked).
private struct RawWebSocketReader {
    let fd: Int32
    private var buffer: [UInt8] = []

    init(fd: Int32) { self.fd = fd }

    private mutating func fill() throws {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &chunk, chunk.count)
        guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
        buffer.append(contentsOf: chunk[0..<count])
    }

    /// The upgrade answer's status line and headers; what follows stays buffered.
    mutating func upgradeResponseHead() throws -> String {
        let terminator = Array("\r\n\r\n".utf8)
        while true {
            if buffer.count >= terminator.count,
               let start = (0...(buffer.count - terminator.count)).first(where: {
                   Array(buffer[$0..<($0 + terminator.count)]) == terminator
               }) {
                let head = String(decoding: buffer[0..<start], as: UTF8.self)
                buffer.removeFirst(start + terminator.count)
                return head
            }
            try fill()
        }
    }

    /// The next text frame as a JSON object; other opcodes (ping) are skipped.
    mutating func nextTextFrame() throws -> [String: Any] {
        while true {
            while buffer.count < 2 { try fill() }
            let opcode = buffer[0] & 0x0F
            var length = Int(buffer[1] & 0x7F)
            var header = 2
            if length == 126 {
                while buffer.count < 4 { try fill() }
                length = Int(buffer[2]) << 8 | Int(buffer[3])
                header = 4
            } else if length == 127 {
                while buffer.count < 10 { try fill() }
                length = buffer[2..<10].reduce(0) { $0 << 8 | Int($1) }
                header = 10
            }
            while buffer.count < header + length { try fill() }
            let payload = Data(buffer[header..<(header + length)])
            buffer.removeFirst(header + length)
            guard opcode == 0x1 else { continue }
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw POSIXError(.EBADMSG)
            }
            return object
        }
    }
}

/// Kinds a subscriber saw; the handler runs on the EventBus delivery queue.
private final class ObservedEventKinds: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [String] = []

    func append(_ kind: String) {
        lock.lock(); kinds.append(kind); lock.unlock()
    }

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return kinds
    }
}

private final class RotationNoticeAuth: DirectAuthProvider {
    func verify(token: String) -> Bool { token == "good-token" }
    func createPairingCode() -> String? { nil }
    func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? { nil }
    func listDevices() -> [[String: Any]] { [] }
    func revokeDevice(_ id: String) {}
}
