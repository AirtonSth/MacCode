import CryptoKit
import Foundation
import RemoteCodeTreaty
import XCTest
@testable import SocketServer

private final class LiveRelayAuth: DirectAuthProvider, @unchecked Sendable {
    let token = "device-bearer"
    private let lock = NSLock()
    private var verifyCount = 0

    var verifyCalls: Int { lock.lock(); defer { lock.unlock() }; return verifyCount }
    func verify(token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        verifyCount += 1
        return token == self.token
    }
    func createPairingCode() -> String? { nil }
    func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? { nil }
    func listDevices() -> [[String: Any]] { [] }
    func revokeDevice(_ id: String) {}
}

/// Opt-in: talks to the deployed relay with a real Private account token.
/// Set RC_RELAY_LIVE_TOKEN (and optionally RC_RELAY_URL) to run it.
@MainActor
final class RelayLiveTests: XCTestCase {
    private typealias Key = Curve25519.KeyAgreement.PrivateKey

    func test_liveRelayCarriesHTTPAndWebSocketEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["RC_RELAY_LIVE_TOKEN"], !token.isEmpty else {
            throw XCTSkip("Set RC_RELAY_LIVE_TOKEN to exercise the deployed relay.")
        }
        let base = URL(string: env["RC_RELAY_URL"] ?? "wss://relay.remotecode.io")!
        let serverId = "live-\(UUID().uuidString.lowercased())"

        let auth = LiveRelayAuth()
        let server = DirectHTTPServer(
            port: UInt16.random(in: 44_001...54_000),
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            auth: auth,
            serverId: serverId,
            bootEpoch: 1
        )
        let hostKey = Key()
        let phoneKey = Key()
        let phonePublic = phoneKey.publicKey.rawRepresentation
        let client = RelayHostClient(
            server: server,
            relayBase: base,
            serverId: serverId,
            hostStatic: hostKey,
            accessToken: { token },
            trustedDeviceForRelayKey: { $0 == phonePublic ? "live-device" : nil }
        )
        client.start()
        defer { client.stop() }
        for _ in 0..<500 where !client.isConnected { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(client.isConnected, "host socket must connect to \(base.host ?? "relay")")
        try XCTSkipUnless(client.isConnected, "relay unreachable; nothing more to prove")

        func phoneSocket() -> URLSessionRelayWebSocket {
            var request = URLRequest(url: RelayEndpoints.connect(base: base, serverId: serverId))
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            return URLSessionRelayWebSocket(request)
        }

        func connect(key: Key) async throws -> (RelaySecureChannel, URLSessionRelayWebSocket) {
            let socket = phoneSocket()
            let channel = try await RelaySecureChannel.initiate(
                socket: socket,
                initiatorStatic: key,
                responderStaticPublicKey: hostKey.publicKey.rawRepresentation,
                serverId: serverId
            )
            return (channel, socket)
        }

        func get(_ path: String, bearer: Bool) -> Data {
            let header = bearer ? "Authorization: Bearer \(auth.token)\r\n" : ""
            return Data("GET \(path) HTTP/1.1\r\nHost: relay\r\n\(header)Connection: close\r\n\r\n".utf8)
        }

        /// Reads until the header and Content-Length body are complete; reports time to first byte.
        func readResponse(_ channel: RelaySecureChannel, _ socket: URLSessionRelayWebSocket, since: Date) async throws
            -> (text: String, firstByte: TimeInterval)
        {
            let watchdog = DispatchWorkItem { socket.close(code: 1000) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
            defer { watchdog.cancel() }
            var data = Data()
            var firstByte: TimeInterval?
            while true {
                data.append(try await channel.receive())
                if firstByte == nil { firstByte = Date().timeIntervalSince(since) }
                guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
                let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
                let length = head.lowercased().components(separatedBy: "content-length: ").dropFirst().first
                    .flatMap { Int($0.prefix(while: { $0.isNumber })) } ?? 0
                if data.count - end.upperBound >= length {
                    return (String(decoding: data, as: UTF8.self), firstByte ?? 0)
                }
            }
        }

        let started = Date()
        let (c1, s1) = try await connect(key: phoneKey)
        try await c1.send(get("/v1/discovery", bearer: false))
        let discovery = try await readResponse(c1, s1, since: started)
        s1.close(code: 1000)
        XCTAssertTrue(discovery.text.hasPrefix("HTTP/1.1 200"), discovery.text)
        let body = discovery.text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(json["server_id"] as? String, serverId)
        let millis = Int(discovery.firstByte * 1000)
        print("RELAY-LIVE connect-to-first-HTTP-byte (discovery, incl. WS connect + Noise handshake): \(millis) ms")
        XCTContext.runActivity(named: "relay live latency: first HTTP byte after \(millis) ms") { _ in }

        let (c2, s2) = try await connect(key: phoneKey)
        try await c2.send(get("/v1/capabilities/authenticated", bearer: true))
        let caps = try await readResponse(c2, s2, since: Date())
        s2.close(code: 1000)
        XCTAssertTrue(caps.text.hasPrefix("HTTP/1.1 200"), caps.text)

        let callsBefore = auth.verifyCalls
        do {
            _ = try await connect(key: Key())
            XCTFail("handshake must not complete for an untrusted key")
        } catch {}
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(auth.verifyCalls, callsBefore, "no HTTP request is served for an untrusted key")
    }
}
