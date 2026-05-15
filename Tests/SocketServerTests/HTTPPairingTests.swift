import XCTest
@testable import SocketServer
@testable import Persistence

final class HTTPPairingTests: XCTestCase {
    final class FakeAuth: DirectAuthProvider {
        var devices: [(String, String)] = [] // [(id, name)]
        var lastCode: String?
        func verify(token: String) -> Bool { token == "valid-token" }
        func createPairingCode() -> String? { lastCode = "123456"; return lastCode }
        func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? {
            guard code == "123456" else { return nil }
            let id = "dev-1"
            devices.append((id, deviceName))
            return (id, "valid-token")
        }
        func listDevices() -> [[String: Any]] {
            devices.map { ["id": $0.0, "display_name": $0.1] }
        }
        func revokeDevice(_ id: String) { devices.removeAll { $0.0 == id } }
    }

    @MainActor
    func test_pair_redeem_loopback_flow() throws {
        let port = UInt16.random(in: 33000...44000)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let auth = FakeAuth()
        let s = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher, auth: auth)
        try s.start()
        defer { s.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let pairURL = URL(string: "http://127.0.0.1:\(port)/v1/pair")!
        var req = URLRequest(url: pairURL); req.httpMethod = "POST"
        let pairEx = expectation(description: "pair")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let obj = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            XCTAssertEqual(obj?["code"] as? String, "123456")
            pairEx.fulfill()
        }.resume()
        wait(for: [pairEx], timeout: 3)

        let redeemURL = URL(string: "http://127.0.0.1:\(port)/v1/pair/redeem")!
        var req2 = URLRequest(url: redeemURL); req2.httpMethod = "POST"
        req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req2.httpBody = try JSONSerialization.data(withJSONObject: ["code": "123456", "device_name": "phone"])
        let redeemEx = expectation(description: "redeem")
        URLSession.shared.dataTask(with: req2) { data, _, _ in
            let obj = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            XCTAssertEqual(obj?["token"] as? String, "valid-token")
            XCTAssertEqual(obj?["device_id"] as? String, "dev-1")
            redeemEx.fulfill()
        }.resume()
        wait(for: [redeemEx], timeout: 3)
    }
}
