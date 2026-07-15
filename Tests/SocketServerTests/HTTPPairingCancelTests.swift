import XCTest
@testable import SocketServer
@testable import Persistence

/// Covers item 33 host side: POST /v1/pair/cancel.
/// WHY a separate file: these cases assert HTTP *status codes* (200/404/503)
/// and the side effect on the outstanding-request throttle, which the JSON-
/// only helper in HTTPPairingTests does not surface. Mirrors that file's
/// FakeAuth / waitReady raw-socket warmup pattern so the cold-start body-loss
/// artifact documented there cannot poison the real assertions.
final class HTTPPairingCancelTests: XCTestCase {
    /// Stand-in for LocalAuthAdapter. `cancelPairingRequest` only succeeds
    /// for a request that exists and is still pending, matching the real
    /// terminal-state contract.
    final class FakeAuth: DirectAuthProvider {
        private var requests: [String: String] = [:]   // id -> status
        private var nextRequestNumber = 1
        var cancelCalls: [String] = []

        func verify(token: String) -> Bool { token == "valid-token" }
        func createPairingCode() -> String? { "123456" }
        func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? { nil }
        func createPairingRequest(deviceName: String) -> (requestId: String, code: String)? {
            createPairingRequest(deviceName: deviceName, privateAccountAccessToken: nil)
        }
        func createPairingRequest(deviceName: String, privateAccountAccessToken: String?) -> (requestId: String, code: String)? {
            // Unique ids so slot-accounting tests can hold several requests
            // outstanding at once, like distinct real pairing attempts.
            let id = "req-\(nextRequestNumber)"; nextRequestNumber += 1
            requests[id] = "pending"
            return (id, "424242")
        }
        func pairingRequestStatus(requestId: String) -> (status: String, deviceId: String?, token: String?)? {
            guard let s = requests[requestId] else { return nil }
            return (s, nil, nil)
        }
        func cancelPairingRequest(requestId: String) -> Bool {
            cancelCalls.append(requestId)
            guard requests[requestId] == "pending" else { return false }
            requests[requestId] = "cancelled"
            return true
        }
        func listDevices() -> [[String: Any]] { [] }
        func revokeDevice(_ id: String) {}
    }

    private let session = URLSession.shared

    /// POST returning (statusCode, parsed-JSON-or-nil). JSON parse is best
    /// effort so text error bodies (404/503) still yield a status code.
    private func postStatus(_ url: String, _ body: [String: Any]?) -> (status: Int, json: [String: Any]?) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("close", forHTTPHeaderField: "Connection")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let ex = expectation(description: url)
        var status = -1
        var json: [String: Any]?
        session.dataTask(with: req) { data, resp, _ in
            status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            json = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            ex.fulfill()
        }.resume()
        wait(for: [ex], timeout: 3)
        return (status, json)
    }

    /// Mirror of HTTPPairingTests.waitReady: block until the listener answers
    /// /healthz, then fire one tolerant warm POST to absorb the raw-socket
    /// cold-start first-POST body-loss artifact before any assertion runs.
    private func waitReady(_ base: String) {
        for _ in 0..<40 {
            let ex = expectation(description: "healthz")
            var ok = false
            session.dataTask(with: URL(string: "\(base)/healthz")!) { data, resp, _ in
                ok = (resp as? HTTPURLResponse)?.statusCode == 200 && (data?.isEmpty == false)
                ex.fulfill()
            }.resume()
            wait(for: [ex], timeout: 1)
            if ok { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = postStatus("\(base)/v1/pair", ["device_name": "warmup"])
    }

    /// Sacrificial first case (alphabetical order) - absorbs the cold-start
    /// POST poisoning so the real assertions below run clean and order-
    /// independent. Same rationale as HTTPPairingTests.test_aaa_processWarmup.
    @MainActor
    func test_aaa_cancelWarmup_noAssertions() throws {
        let port = UInt16.random(in: 33000...44000)
        // DirectHTTPServer.auth is `weak`; an inline FakeAuth() would be
        // deallocated immediately and every /v1/pair* call would 503. Hold a
        // strong reference for the server's lifetime.
        let auth = FakeAuth()
        let s = DirectHTTPServer(port: port, loopbackOnly: true,
                                 dispatcher: JSONRPCDispatcher(router: FakeRouter()), auth: auth, bootEpoch: 1)
        try s.start(); defer { s.stop() }
        let base = "http://127.0.0.1:\(port)"
        waitReady(base)
        _ = postStatus("\(base)/v1/pair/cancel", ["request_id": "req-1"])
    }

    /// WHY: a device cancelling a known outstanding request must get
    /// 200 {"cancelled":true}, and the request must read terminal afterward
    /// so the device/Mac stop treating it as pending. Guards the happy-path
    /// wire shape both ends of the contract depend on.
    @MainActor
    func test_cancelKnownRequest_returns200CancelledTrue_andStatusTerminal() throws {
        let port = UInt16.random(in: 33000...44000)
        let auth = FakeAuth()
        let s = DirectHTTPServer(port: port, loopbackOnly: true,
                                 dispatcher: JSONRPCDispatcher(router: FakeRouter()), auth: auth, bootEpoch: 1)
        try s.start(); defer { s.stop() }
        let base = "http://127.0.0.1:\(port)"
        waitReady(base)

        let rid = try XCTUnwrap(postStatus("\(base)/v1/pair", ["device_name": "phone"]).json?["request_id"] as? String)

        let cancel = postStatus("\(base)/v1/pair/cancel", ["request_id": rid])
        XCTAssertEqual(cancel.status, 200)
        XCTAssertEqual(cancel.json?["cancelled"] as? Bool, true)

        // The request must now be terminal, not pending.
        let after = postStatus("\(base)/v1/pair/status", ["request_id": rid])
        XCTAssertEqual(after.status, 200)
        XCTAssertEqual(after.json?["status"] as? String, "cancelled")
    }

    /// WHY: cancelling an id that was never issued must be 404 "unknown
    /// request", not a 200 - otherwise a device could not tell a real cancel
    /// from a no-op, and the 404-vs-200 branch is the contract iOS keys on.
    @MainActor
    func test_cancelUnknownRequest_returns404() throws {
        let port = UInt16.random(in: 33000...44000)
        // Hold a strong ref: DirectHTTPServer.auth is `weak` (see warmup note).
        let auth = FakeAuth()
        let s = DirectHTTPServer(port: port, loopbackOnly: true,
                                 dispatcher: JSONRPCDispatcher(router: FakeRouter()), auth: auth, bootEpoch: 1)
        try s.start(); defer { s.stop() }
        let base = "http://127.0.0.1:\(port)"
        waitReady(base)

        let cancel = postStatus("\(base)/v1/pair/cancel", ["request_id": "does-not-exist"])
        XCTAssertEqual(cancel.status, 404)
    }

    /// WHY: cancel must free the creator's outstanding-request slot
    /// (maxOutstandingPerPeer = 5), or a device that abandons pairing sheets
    /// a few times is refused with 429 until the Mac app restarts. Pins the
    /// release-by-request-id side effect of POST /v1/pair/cancel end to end.
    @MainActor
    func test_cancelReleasesOutstandingSlot_restoresCapacity() throws {
        let port = UInt16.random(in: 33000...44000)
        let auth = FakeAuth()
        let s = DirectHTTPServer(port: port, loopbackOnly: true,
                                 dispatcher: JSONRPCDispatcher(router: FakeRouter()), auth: auth, bootEpoch: 1)
        try s.start(); defer { s.stop() }
        let base = "http://127.0.0.1:\(port)"
        waitReady(base)   // consumes 1 slot (its warm POST creates a request)

        // Fill the remaining 4 of maxOutstandingPerPeer = 5.
        var lastRid = ""
        for _ in 0..<4 {
            lastRid = try XCTUnwrap(postStatus("\(base)/v1/pair", ["device_name": "phone"]).json?["request_id"] as? String)
        }
        XCTAssertEqual(postStatus("\(base)/v1/pair", ["device_name": "phone"]).status, 429,
                       "at the cap the next request must be refused")

        XCTAssertEqual(postStatus("\(base)/v1/pair/cancel", ["request_id": lastRid]).status, 200)
        XCTAssertEqual(postStatus("\(base)/v1/pair", ["device_name": "phone"]).status, 200,
                       "cancelling an outstanding request must restore capacity for a new one")
    }

    /// WHY: with no auth provider configured pairing is disabled; cancel must
    /// answer 503 like /v1/pair, never silently 200, so a device sees the
    /// host cannot pair rather than a false success.
    @MainActor
    func test_cancelWithoutAuthProvider_returns503() throws {
        let port = UInt16.random(in: 33000...44000)
        let s = DirectHTTPServer(port: port, loopbackOnly: true,
                                 dispatcher: JSONRPCDispatcher(router: FakeRouter()), auth: nil, bootEpoch: 1)
        try s.start(); defer { s.stop() }
        let base = "http://127.0.0.1:\(port)"
        // No auth -> /v1/pair warmup also 503; healthz still confirms ready.
        for _ in 0..<40 {
            let ex = expectation(description: "healthz")
            var ok = false
            session.dataTask(with: URL(string: "\(base)/healthz")!) { data, resp, _ in
                ok = (resp as? HTTPURLResponse)?.statusCode == 200 && (data?.isEmpty == false)
                ex.fulfill()
            }.resume()
            wait(for: [ex], timeout: 1)
            if ok { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = postStatus("\(base)/v1/pair/cancel", ["request_id": "x"])   // absorb cold-start

        let cancel = postStatus("\(base)/v1/pair/cancel", ["request_id": "x"])
        XCTAssertEqual(cancel.status, 503)
    }
}
