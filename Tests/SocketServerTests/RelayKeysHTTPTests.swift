import CryptoKit
import Darwin
import XCTest
@testable import SocketServer

private final class KeysAuth: DirectAuthProvider, @unchecked Sendable {
    let macKey = Data(repeating: 7, count: 32)
    private let lock = NSLock()
    private(set) var bearerKeys: [Data] = []
    private(set) var deviceKeys: [String: Data] = [:]

    func verify(token: String) -> Bool { token == "good" }
    func createPairingCode() -> String? { nil }
    func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? {
        code == "123456" ? ("dev-1", "tok-1") : nil
    }
    func pairingRequestStatus(requestId: String) -> (status: String, deviceId: String?, token: String?)? {
        ("approved", "dev-2", "tok-2")
    }
    func listDevices() -> [[String: Any]] { [] }
    func revokeDevice(_ id: String) {}
    func relayHostPublicKey() -> Data? { macKey }
    func setRelayPublicKey(forBearer token: String, key: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == "good" else { return false }
        bearerKeys.append(key)
        return true
    }
    func setRelayPublicKey(deviceId: String, key: Data) {
        lock.lock(); defer { lock.unlock() }
        deviceKeys[deviceId] = key
    }
}

@MainActor
final class RelayKeysHTTPTests: XCTestCase {
    private func makeServer(_ auth: KeysAuth) -> DirectHTTPServer {
        DirectHTTPServer(
            port: UInt16.random(in: 44_001...54_000),
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            auth: auth,
            serverId: "keys-host",
            bootEpoch: 1
        )
    }

    /// Sends one request through a relay-style (remote-authenticated) socket.
    private func send(_ server: DirectHTTPServer, _ raw: String) throws -> (status: Int, json: [String: Any]) {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        XCTAssertTrue(server.registerTailcatConnection(fd: pair[0]))
        Thread.detachNewThread { server.serveTailcatConnection(fd: pair[0], peer: "relay:test") }
        let client = pair[1]
        defer { Darwin.close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let bytes = Array(raw.utf8)
        XCTAssertEqual(Darwin.write(client, bytes, bytes.count), bytes.count)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(client, &buffer, buffer.count)
            if n <= 0 { break }
            response.append(buffer, count: n)
        }
        let text = String(decoding: response, as: UTF8.self)
        let status = Int(text.split(separator: " ").dropFirst().first ?? "0") ?? 0
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        return (status, json)
    }

    private func post(_ path: String, _ body: String, bearer: String? = nil) -> String {
        let auth = bearer.map { "Authorization: Bearer \($0)\r\n" } ?? ""
        return "POST \(path) HTTP/1.1\r\nHost: x\r\n\(auth)Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private let phoneKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation

    func testRelayKeysRequiresAValidBearer() throws {
        let auth = KeysAuth()
        let server = makeServer(auth)
        let body = #"{"relay_public_key":"\#(phoneKey.base64EncodedString())"}"#
        XCTAssertEqual(try send(server, post("/v1/relay/keys", body)).status, 401)
        XCTAssertEqual(try send(server, post("/v1/relay/keys", body, bearer: "bad")).status, 401)
        XCTAssertTrue(auth.bearerKeys.isEmpty, "an unauthenticated caller must not bind a relay key")
    }

    func testRelayKeysRejectsMalformedKeys() throws {
        let auth = KeysAuth()
        let server = makeServer(auth)
        for body in [#"{}"#, #"{"relay_public_key":"not base64!"}"#,
                     #"{"relay_public_key":"\#(Data(repeating: 1, count: 16).base64EncodedString())"}"#] {
            let result = try send(server, post("/v1/relay/keys", body, bearer: "good"))
            XCTAssertEqual(result.status, 400)
            XCTAssertEqual(result.json["error"] as? String, "invalid_relay_key")
        }
        XCTAssertTrue(auth.bearerKeys.isEmpty)
    }

    func testRelayKeysStoresKeyAndReturnsHostKey() throws {
        let auth = KeysAuth()
        let server = makeServer(auth)
        let body = #"{"relay_public_key":"\#(phoneKey.base64EncodedString())"}"#
        let result = try send(server, post("/v1/relay/keys", body, bearer: "good"))
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.json["relay_public_key"] as? String, auth.macKey.base64EncodedString())
        XCTAssertEqual(result.json["server_id"] as? String, "keys-host")
        XCTAssertEqual(result.json["relay_url"] as? String, "wss://relay.remotecode.io")
        XCTAssertEqual(auth.bearerKeys, [phoneKey])
    }

    func testRedeemAndStatusStoreTheDeviceKeyAndReturnTheHostKey() throws {
        let auth = KeysAuth()
        let server = makeServer(auth)
        let key = phoneKey.base64EncodedString()

        let redeem = try send(server, post("/v1/pair/redeem",
            #"{"code":"123456","device_name":"p","relay_public_key":"\#(key)"}"#))
        XCTAssertEqual(redeem.status, 200)
        XCTAssertEqual(redeem.json["relay_public_key"] as? String, auth.macKey.base64EncodedString())
        XCTAssertEqual(auth.deviceKeys["dev-1"], phoneKey)

        let status = try send(server, post("/v1/pair/status",
            #"{"request_id":"r","relay_public_key":"\#(key)"}"#))
        XCTAssertEqual(status.status, 200)
        XCTAssertEqual(status.json["token"] as? String, "tok-2")
        XCTAssertEqual(status.json["relay_public_key"] as? String, auth.macKey.base64EncodedString())
        XCTAssertEqual(auth.deviceKeys["dev-2"], phoneKey)
    }

    func testRedeemIgnoresInvalidKeyAndKeepsOldBehaviour() throws {
        let auth = KeysAuth()
        let server = makeServer(auth)
        let result = try send(server, post("/v1/pair/redeem",
            #"{"code":"123456","device_name":"p","relay_public_key":"AAAA"}"#))
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.json["token"] as? String, "tok-1")
        XCTAssertTrue(auth.deviceKeys.isEmpty, "a malformed key is dropped, not stored")
    }

    func testDiscoveryRelayFlagFollowsAvailability() throws {
        let auth = KeysAuth()
        let server = makeServer(auth)
        let get = "GET /v1/discovery HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        XCTAssertEqual(try send(server, get).json["relay"] as? Bool, false)
        server.relayAvailable = { true }
        XCTAssertEqual(try send(server, get).json["relay"] as? Bool, true)
    }
}
