import CryptoKit
import Darwin
import XCTest
@testable import SocketServer

/// Device revoke must invalidate the bearer and shut down that owner's HTTP
/// and WebSocket sockets before the 200 is written. A revoked session must
/// not receive or send; a sibling device must stay live; a new call with the
/// revoked token must fail.
private final class RevokeAuth: DirectAuthProvider, @unchecked Sendable {
    private struct Device {
        let id: String
        let token: String
        let fingerprint: String
        var revoked: Bool
    }

    private let lock = NSLock()
    private var byToken: [String: Device]
    private var byId: [String: Device]

    init(devices: [(id: String, token: String)]) {
        var byToken: [String: Device] = [:]
        var byId: [String: Device] = [:]
        for item in devices {
            let fingerprint = Self.fingerprint(for: item.id)
            let device = Device(
                id: item.id,
                token: item.token,
                fingerprint: fingerprint,
                revoked: false
            )
            byToken[item.token] = device
            byId[item.id] = device
        }
        self.byToken = byToken
        self.byId = byId
    }

    static func fingerprint(for deviceId: String) -> String {
        let material = Data("rc2.authorized-owner.v1:device:\(deviceId)".utf8)
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func verify(token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return byToken[token].map { !$0.revoked } ?? false
    }

    func authorizedOwnerFingerprint(token: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let device = byToken[token], !device.revoked else { return nil }
        return device.fingerprint
    }

    func isAuthorizedOwnerFingerprintActive(_ fingerprint: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return byId.values.contains { !$0.revoked && $0.fingerprint == fingerprint }
    }

    func revokeDevice(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard var device = byId[id] else { return }
        device.revoked = true
        byId[id] = device
        byToken[device.token] = device
    }

    func createPairingCode() -> String? { nil }
    func redeemPairingCode(
        _ code: String,
        deviceName: String
    ) -> (deviceId: String, token: String)? { nil }
    func listDevices() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return byId.values.map { device in
            ["id": device.id, "revoked": device.revoked]
        }
    }
}

final class DeviceRevokeClosesChannelsTests: XCTestCase {
    private let tokenA = "device-a-bearer"
    private let tokenB = "device-b-bearer"
    private let deviceA = "device-a"
    private let deviceB = "device-b"

    func test_registryCloseByOwner_shutsDownMatchingSocketsAndLeavesOthers() throws {
        // WHY: close-by-owner must SHUT_RDWR the real socket, not only drop
        // the map entry. A sibling owner's socket must keep speaking.
        var pairA: [Int32] = [0, 0]
        var pairB: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pairA), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pairB), 0)
        defer {
            Darwin.close(pairA[0]); Darwin.close(pairA[1])
            Darwin.close(pairB[0]); Darwin.close(pairB[1])
        }

        let registry = ActiveWebSocketConnectionRegistry()
        let watermark = ConnectionSequenceWatermark(initialSequence: 1)
        registry.insert(
            "conn-a",
            ownerFingerprint: "owner-a",
            watermark: watermark,
            socketFD: pairA[0]
        )
        registry.insert(
            "conn-b",
            ownerFingerprint: "owner-b",
            watermark: watermark,
            socketFD: pairB[0]
        )

        let closed = Set(registry.close(ownedBy: "owner-a"))
        XCTAssertEqual(closed, Set([pairA[0]]))
        XCTAssertFalse(registry.hasConnection(ownedBy: "owner-a"))
        XCTAssertTrue(registry.hasConnection(ownedBy: "owner-b"))
        XCTAssertEqual(registry.ownerFingerprint(for: "conn-b"), "owner-b")

        var byte: UInt8 = 0
        XCTAssertEqual(
            Darwin.read(pairA[1], &byte, 1),
            0,
            "owner A peer must see EOF after close-by-owner shutdown"
        )
        var send: UInt8 = 7
        XCTAssertEqual(Darwin.write(pairB[0], &send, 1), 1)
        var received: UInt8 = 0
        XCTAssertEqual(Darwin.read(pairB[1], &received, 1), 1)
        XCTAssertEqual(received, 7, "owner B socket must still send after A is revoked")
    }

    func test_registryCloseByConnectionID_shutsDownOnlyThatSocket() throws {
        // WHY: the registry must also close a single connection by id without
        // touching a different owner's live socket.
        var pairA: [Int32] = [0, 0]
        var pairB: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pairA), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pairB), 0)
        defer {
            Darwin.close(pairA[0]); Darwin.close(pairA[1])
            Darwin.close(pairB[0]); Darwin.close(pairB[1])
        }

        let registry = ActiveWebSocketConnectionRegistry()
        let watermark = ConnectionSequenceWatermark(initialSequence: 1)
        registry.insert(
            "conn-a",
            ownerFingerprint: "owner-a",
            watermark: watermark,
            socketFD: pairA[0]
        )
        registry.insert(
            "conn-b",
            ownerFingerprint: "owner-b",
            watermark: watermark,
            socketFD: pairB[0]
        )

        XCTAssertEqual(registry.close("conn-a"), pairA[0])
        XCTAssertFalse(registry.hasConnection(ownedBy: "owner-a"))
        XCTAssertTrue(registry.hasConnection(ownedBy: "owner-b"))

        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(pairA[1], &byte, 1), 0)
        var send: UInt8 = 9
        XCTAssertEqual(Darwin.write(pairB[0], &send, 1), 1)
        var received: UInt8 = 0
        XCTAssertEqual(Darwin.read(pairB[1], &received, 1), 1)
        XCTAssertEqual(received, 9)
    }

    func test_registryCloseByOwner_includesDemotedPredecessors() throws {
        // WHY: a same-owner replacement demotes the predecessor but leaves
        // its TCP socket live. Revoke must shut both down.
        var pairOld: [Int32] = [0, 0]
        var pairNew: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pairOld), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pairNew), 0)
        defer {
            Darwin.close(pairOld[0]); Darwin.close(pairOld[1])
            Darwin.close(pairNew[0]); Darwin.close(pairNew[1])
        }

        let registry = ActiveWebSocketConnectionRegistry()
        let watermark = ConnectionSequenceWatermark(initialSequence: 1)
        registry.insert(
            "conn-old",
            ownerFingerprint: "owner-a",
            watermark: watermark,
            socketFD: pairOld[0]
        )
        registry.insert(
            "conn-new",
            ownerFingerprint: "owner-a",
            watermark: watermark,
            socketFD: pairNew[0]
        )
        XCTAssertNil(registry.ownerFingerprint(for: "conn-old"))
        XCTAssertEqual(registry.ownerFingerprint(for: "conn-new"), "owner-a")
        XCTAssertTrue(registry.hasConnection(ownedBy: "owner-a"))

        let closed = Set(registry.close(ownedBy: "owner-a"))
        XCTAssertEqual(closed, Set([pairOld[0], pairNew[0]]))
        XCTAssertFalse(registry.hasConnection(ownedBy: "owner-a"))

        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(pairOld[1], &byte, 1), 0)
        XCTAssertEqual(Darwin.read(pairNew[1], &byte, 1), 0)
    }

    func test_httpOwnerRegistryCloseByOwner_shutsDownMatchingSockets() throws {
        // WHY: HTTP keep-alive fds are tracked separately from WS and must
        // also lose SHUT_RDWR on revoke, leaving a sibling owner intact.
        var pairA: [Int32] = [0, 0]
        var pairB: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pairA), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pairB), 0)
        defer {
            Darwin.close(pairA[0]); Darwin.close(pairA[1])
            Darwin.close(pairB[0]); Darwin.close(pairB[1])
        }

        let registry = ActiveHTTPOwnerConnectionRegistry()
        registry.bind(pairA[0], ownerFingerprint: "owner-a")
        registry.bind(pairB[0], ownerFingerprint: "owner-b")
        XCTAssertEqual(Set(registry.close(ownedBy: "owner-a")), Set([pairA[0]]))
        XCTAssertTrue(registry.descriptors(ownedBy: "owner-a").isEmpty)
        XCTAssertEqual(registry.descriptors(ownedBy: "owner-b"), [pairB[0]])

        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(pairA[1], &byte, 1), 0)
        var send: UInt8 = 3
        XCTAssertEqual(Darwin.write(pairB[0], &send, 1), 1)
        var received: UInt8 = 0
        XCTAssertEqual(Darwin.read(pairB[1], &received, 1), 1)
        XCTAssertEqual(received, 3)
    }

    @MainActor
    func test_rpcConnectionClose_releasesHTTPOwnerBinding() async throws {
        // WHY: the /v1/rpc hand-off Task owns the fd, so every exit that closes
        // it must also drop the owner binding. A binding left behind survives
        // close(2): trackedOwnerFingerprints() reports a ghost owner and a later
        // revoke's SHUT_RDWR can land on a recycled descriptor that now belongs
        // to a different peer.
        let auth = RevokeAuth(devices: [(id: deviceA, token: tokenA)])
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: false,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            auth: auth,
            serverId: "owner-release-host",
            bootEpoch: 19
        )
        try server.start()
        defer { server.stop() }
        try await waitUntilHealthy(port: port)

        let fd = try connectLoopback(port: port)
        defer { Darwin.close(fd) }
        setReceiveTimeout(fd, seconds: 2)

        // postJSON sends `Connection: close`, which is the hand-off exit that
        // closes the fd without re-entering the keep-alive session.
        let response = try await postJSON(
            port: port,
            path: "/v1/rpc",
            body: [
                "jsonrpc": "2.0",
                "id": "owner-release",
                "method": "workspace.list",
                "params": [String: Any](),
            ],
            token: tokenA
        )
        XCTAssertEqual(response.status, 200, "the bearer-authenticated RPC must succeed")

        var bound = server.httpOwnerBoundDescriptorCountForTests
        let deadline = Date().addingTimeInterval(2)
        while bound != 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            bound = server.httpOwnerBoundDescriptorCountForTests
        }
        XCTAssertEqual(
            bound, 0,
            "a closed RPC connection must release its owner binding, not just its descriptor"
        )
    }

    @MainActor
    func test_deviceRevoke_closesOwnerWebSocketBefore200_leavesOtherDevice_rejectsRevokedToken() async throws {
        // WHY: after POST /v1/devices/revoke returns 200, device A's WS must
        // already be unable to receive the next EventBus sentinel; device B
        // still receives it; a new HTTP call with A's token is 401.
        let auth = RevokeAuth(devices: [
            (id: deviceA, token: tokenA),
            (id: deviceB, token: tokenB),
        ])
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: false,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            auth: auth,
            serverId: "revoke-ws-host",
            bootEpoch: 17
        )
        try server.start()
        defer { server.stop() }
        try await waitUntilHealthy(port: port)

        let taskA = wsTask(port: port, token: tokenA)
        let taskB = wsTask(port: port, token: tokenB)
        defer {
            taskA.cancel(with: .goingAway, reason: nil)
            taskB.cancel(with: .goingAway, reason: nil)
        }
        _ = try await receiveWelcome(taskA)
        _ = try await receiveWelcome(taskB)

        let revoke = try await postJSON(
            port: port,
            path: "/v1/devices/revoke",
            body: ["id": deviceA],
            token: tokenB
        )
        XCTAssertEqual(revoke.status, 200, "revoke must return 200 only after owner channels are shut")
        let revokeBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: revoke.body) as? [String: Any]
        )
        XCTAssertEqual(revokeBody["revoked"] as? String, deviceA)

        let sentinel = uniqueEventKind("revoke.closed")
        EventBus.shared.publishRawForTesting(
            kind: sentinel,
            payload: .object(["marker": .string("after-revoke")])
        )

        let fromB = try await receiveEvent(taskB, kind: sentinel)
        XCTAssertEqual(fromB["kind"] as? String, sentinel)

        var sawSentinelOnA = false
        do {
            for _ in 0..<8 {
                let obj = try await receiveObject(taskA, timeoutSeconds: 0.25)
                if obj["kind"] as? String == sentinel {
                    sawSentinelOnA = true
                    break
                }
            }
        } catch {
            // Closed/reset/timeout all prove A cannot receive the sentinel.
        }
        XCTAssertFalse(
            sawSentinelOnA,
            "device A must not receive EventBus traffic after revoke 200"
        )

        let rejected = try await getHealth(port: port, token: tokenA)
        XCTAssertEqual(rejected.status, 401, "a new request with the revoked token must fail")
        let alive = try await getHealth(port: port, token: tokenB)
        XCTAssertEqual(alive.status, 200, "device B must remain authorized after A is revoked")
    }

    @MainActor
    func test_deviceRevoke_closesOwnerHTTPKeepAliveBefore200_leavesOtherDevice() async throws {
        // WHY: an authenticated HTTP keep-alive for A must stop speaking
        // before revoke returns 200. B's keep-alive stays; A's token fails
        // on a fresh request.
        let auth = RevokeAuth(devices: [
            (id: deviceA, token: tokenA),
            (id: deviceB, token: tokenB),
        ])
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: false,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            auth: auth,
            serverId: "revoke-http-host",
            bootEpoch: 18
        )
        try server.start()
        defer { server.stop() }
        try await waitUntilHealthy(port: port)

        let fdA = try connectLoopback(port: port)
        let fdB = try connectLoopback(port: port)
        defer {
            Darwin.close(fdA)
            Darwin.close(fdB)
        }
        setReceiveTimeout(fdA, seconds: 2)
        setReceiveTimeout(fdB, seconds: 2)

        let firstA = try readHTTPResponse(
            from: fdA,
            afterWriting: healthRequest(token: tokenA)
        )
        XCTAssertEqual(firstA.status, 200, "device A keep-alive must authenticate before revoke")
        let firstB = try readHTTPResponse(
            from: fdB,
            afterWriting: healthRequest(token: tokenB)
        )
        XCTAssertEqual(firstB.status, 200, "device B keep-alive must authenticate before revoke")

        let revoke = try await postJSON(
            port: port,
            path: "/v1/devices/revoke",
            body: ["id": deviceA],
            token: tokenB
        )
        XCTAssertEqual(revoke.status, 200)
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: revoke.body) as? [String: Any])?["revoked"] as? String,
            deviceA
        )

        var eofByte: UInt8 = 0
        let eofRead = Darwin.read(fdA, &eofByte, 1)
        XCTAssertTrue(
            eofRead == 0 || eofRead < 0,
            "device A keep-alive must already be shut down when revoke returns 200"
        )

        try writeAll(healthRequest(token: tokenB), to: fdB)
        let secondB = try readHTTPResponse(from: fdB)
        XCTAssertEqual(secondB.status, 200, "device B keep-alive must still send after A is revoked")

        let rejected = try await getHealth(port: port, token: tokenA)
        XCTAssertEqual(rejected.status, 401, "a new request with the revoked token must fail")
    }

    // MARK: - Helpers

    private func waitUntilHealthy(port: UInt16) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/healthz")!)
            request.timeoutInterval = 0.4
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("server did not become healthy on port \(port)")
    }

    private func wsTask(port: UInt16, token: String) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return task
    }

    private func receiveWelcome(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
        for _ in 0..<30 {
            let obj = try await receiveObject(task, timeoutSeconds: 2)
            if obj["type"] as? String == "welcome" { return obj }
            if obj["type"] as? String == "heartbeat" { continue }
        }
        XCTFail("did not receive a welcome frame")
        return [:]
    }

    private func receiveEvent(
        _ task: URLSessionWebSocketTask,
        kind wantedKind: String
    ) async throws -> [String: Any] {
        for _ in 0..<40 {
            let obj = try await receiveObject(task, timeoutSeconds: 2)
            if obj["type"] as? String == "heartbeat" { continue }
            if obj["kind"] as? String == wantedKind { return obj }
        }
        XCTFail("did not receive event \(wantedKind)")
        return [:]
    }

    private enum TimeoutError: Error { case timedOut }

    private func receiveObject(
        _ task: URLSessionWebSocketTask,
        timeoutSeconds: Double
    ) async throws -> [String: Any] {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw TimeoutError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw URLError(.cannotDecodeContentData)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func uniqueEventKind(_ prefix: String) -> String {
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return "\(prefix).\(suffix)"
    }

    private func postJSON(
        port: UInt16,
        path: String,
        body: [String: Any],
        token: String
    ) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    private func getHealth(port: UInt16, token: String) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/health")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    private func healthRequest(token: String) -> Data {
        Data(
            "GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nConnection: keep-alive\r\n\r\n".utf8
        )
    }

    private func connectLoopback(port: UInt16) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.ECONNREFUSED)
        }
        return descriptor
    }

    private func setReceiveTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
    }

    private func readHTTPResponse(
        from fd: Int32,
        afterWriting request: Data? = nil
    ) throws -> (status: Int, body: Data) {
        if let request {
            try writeAll(request, to: fd)
        }
        var received = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        while received.range(of: terminator) == nil {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count <= 0 { throw POSIXError(.EIO) }
            received.append(bytes, count: count)
            if received.count > 64 * 1024 { throw POSIXError(.EIO) }
        }
        let headerEnd = try XCTUnwrap(received.range(of: terminator))
        let header = String(data: received[received.startIndex..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        let status = header.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? -1
        var contentLength = 0
        for line in header.split(separator: "\r\n").dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                let raw = line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces)
                contentLength = Int(raw ?? "") ?? 0
            }
        }
        var body = Data(received[headerEnd.upperBound...])
        while body.count < contentLength {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count <= 0 { throw POSIXError(.EIO) }
            body.append(bytes, count: count)
        }
        if body.count > contentLength {
            body = body.prefix(contentLength)
        }
        return (status, body)
    }
}
