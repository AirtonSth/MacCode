import XCTest
@testable import SocketServer

/// P0.19: GET /v1/devices and POST /v1/devices/revoke require `device-admin`
/// (or `*`). Generic write/file/read bearers must not inherit administration.
private final class ScopedDeviceAuth: DirectAuthProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let grants: [String: String]
    private var listCallCountStorage = 0
    private var revokeCallCountStorage = 0
    private var lastRevokedStorage: String?

    init(grants: [String: String]) {
        self.grants = grants
    }

    var listCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return listCallCountStorage
    }

    var revokeCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return revokeCallCountStorage
    }

    var lastRevoked: String? {
        lock.lock(); defer { lock.unlock() }
        return lastRevokedStorage
    }

    func verify(token: String) -> Bool { grants[token] != nil }

    func authorizedRPCPrincipal(token: String) -> DirectRPCPrincipal? {
        guard let capabilities = grants[token] else { return nil }
        return DirectRPCPrincipal(
            ownerFingerprint: "owner-\(token)",
            grantedCapabilities: capabilities
        )
    }

    func createPairingCode() -> String? { nil }
    func redeemPairingCode(
        _ code: String,
        deviceName: String
    ) -> (deviceId: String, token: String)? { nil }

    func listDevices() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        listCallCountStorage += 1
        return [["id": "device-1"]]
    }

    func revokeDevice(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        revokeCallCountStorage += 1
        lastRevokedStorage = id
    }
}

final class DeviceAdminCapabilityTests: XCTestCase {
    private let starToken = "star-token"
    private let adminToken = "admin-token"
    private let writeToken = "write-token"
    private let fileToken = "file-token"
    private let readToken = "read-token"

    func test_grantClassifier_starAndDeviceAdminAllow_writeFileReadDenied() {
        // WHY: a write/file bearer must not enumerate or revoke devices.
        XCTAssertTrue(JSONRPCDispatcher.isAuthorizedDeviceAdmin(grantedCapabilities: "*"))
        XCTAssertTrue(
            JSONRPCDispatcher.isAuthorizedDeviceAdmin(grantedCapabilities: "device-admin")
        )
        XCTAssertTrue(
            JSONRPCDispatcher.isAuthorizedDeviceAdmin(grantedCapabilities: "read, device-admin")
        )
        XCTAssertFalse(JSONRPCDispatcher.isAuthorizedDeviceAdmin(grantedCapabilities: "write"))
        XCTAssertFalse(JSONRPCDispatcher.isAuthorizedDeviceAdmin(grantedCapabilities: "file"))
        XCTAssertFalse(JSONRPCDispatcher.isAuthorizedDeviceAdmin(grantedCapabilities: "read"))
        XCTAssertFalse(JSONRPCDispatcher.isAuthorizedDeviceAdmin(grantedCapabilities: "read,write,file"))
        XCTAssertFalse(JSONRPCDispatcher.isAuthorizedDeviceAdmin(grantedCapabilities: ""))
    }

    func test_deviceAdminHTTPAdmission_unauthenticatedRemoteIsUnauthorized() {
        XCTAssertEqual(
            DirectHTTPServer.deviceAdminHTTPAdmission(
                loopbackOnly: false,
                presentedBearer: false,
                grantedCapabilities: nil
            ),
            .unauthorized
        )
        XCTAssertEqual(
            DirectHTTPServer.deviceAdminHTTPAdmission(
                loopbackOnly: true,
                presentedBearer: false,
                grantedCapabilities: nil
            ),
            .allow,
            "tokenless loopback stays Mac-local administration"
        )
        XCTAssertEqual(
            DirectHTTPServer.deviceAdminHTTPAdmission(
                loopbackOnly: false,
                presentedBearer: true,
                grantedCapabilities: "write"
            ),
            .forbidden
        )
        XCTAssertEqual(
            DirectHTTPServer.deviceAdminHTTPAdmission(
                loopbackOnly: false,
                presentedBearer: true,
                grantedCapabilities: "file"
            ),
            .forbidden
        )
        XCTAssertEqual(
            DirectHTTPServer.deviceAdminHTTPAdmission(
                loopbackOnly: false,
                presentedBearer: true,
                grantedCapabilities: "device-admin"
            ),
            .allow
        )
    }

    @MainActor
    func test_unauthenticatedDevicesRoutesAreNot200() async throws {
        // WHY: device metadata and revoke are administrative. Anonymous
        // callers on a non-loopback bind must not receive 200.
        let auth = ScopedDeviceAuth(grants: [starToken: "*"])
        let live = try await startServer(auth: auth)
        defer { live.stop() }

        let list = try await request(
            port: live.port,
            method: "GET",
            path: "/v1/devices",
            token: nil
        )
        XCTAssertNotEqual(list.status, 200)
        XCTAssertEqual(list.status, 401)
        XCTAssertEqual(auth.listCallCount, 0)

        let revoke = try await request(
            port: live.port,
            method: "POST",
            path: "/v1/devices/revoke",
            token: nil,
            body: ["id": "device-1"]
        )
        XCTAssertNotEqual(revoke.status, 200)
        XCTAssertEqual(revoke.status, 401)
        XCTAssertEqual(auth.revokeCallCount, 0)
    }

    @MainActor
    func test_writeAndFileBearersCannotListOrRevokeDevices() async throws {
        let auth = ScopedDeviceAuth(grants: [
            starToken: "*",
            adminToken: "device-admin",
            writeToken: "write",
            fileToken: "file",
            readToken: "read",
        ])
        let live = try await startServer(auth: auth)
        defer { live.stop() }

        for token in [writeToken, fileToken, readToken] {
            let list = try await request(
                port: live.port,
                method: "GET",
                path: "/v1/devices",
                token: token
            )
            XCTAssertEqual(list.status, 403, "\(token) must not list devices")
            let revoke = try await request(
                port: live.port,
                method: "POST",
                path: "/v1/devices/revoke",
                token: token,
                body: ["id": "device-1"]
            )
            XCTAssertEqual(revoke.status, 403, "\(token) must not revoke devices")
        }
        XCTAssertEqual(auth.listCallCount, 0)
        XCTAssertEqual(auth.revokeCallCount, 0)

        let adminList = try await request(
            port: live.port,
            method: "GET",
            path: "/v1/devices",
            token: adminToken
        )
        XCTAssertEqual(adminList.status, 200)
        let starRevoke = try await request(
            port: live.port,
            method: "POST",
            path: "/v1/devices/revoke",
            token: starToken,
            body: ["id": "device-1"]
        )
        XCTAssertEqual(starRevoke.status, 200)
        XCTAssertEqual(auth.listCallCount, 1)
        XCTAssertEqual(auth.revokeCallCount, 1)
        XCTAssertEqual(auth.lastRevoked, "device-1")
    }

    private struct LiveServer {
        let server: DirectHTTPServer
        let port: UInt16
        func stop() { server.stop() }
    }

    @MainActor
    private func startServer(auth: DirectAuthProvider) async throws -> LiveServer {
        let port = UInt16.random(in: 33_000...44_000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: false,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            auth: auth,
            serverId: "device-admin-host",
            bootEpoch: 1
        )
        try server.start()
        let live = LiveServer(server: server, port: port)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/healthz")!)
            request.timeoutInterval = 0.4
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return live
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        live.stop()
        XCTFail("server did not become healthy on port \(port)")
        throw URLError(.cannotConnectToHost)
    }

    private func request(
        port: UInt16,
        method: String,
        path: String,
        token: String?,
        body: [String: Any]? = nil
    ) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }
}
