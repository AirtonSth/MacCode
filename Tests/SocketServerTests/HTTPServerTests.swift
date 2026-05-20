import XCTest
@testable import SocketServer

final class HTTPServerTests: XCTestCase {
    override func tearDown() {
        DirectStaticFileRegistry.shared.resetForTests()
        super.tearDown()
    }

    @MainActor
    func test_health_and_discovery_loopback() throws {
        let port = UInt16.random(in: 33000...44000)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let s = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher)
        try s.start()
        defer { s.stop() }
        // wait for accept thread
        Thread.sleep(forTimeInterval: 0.05)
        let url = URL(string: "http://127.0.0.1:\(port)/healthz")!
        let healthEx = expectation(description: "health")
        URLSession.shared.dataTask(with: url) { data, resp, err in
            XCTAssertNil(err)
            if let r = resp as? HTTPURLResponse { XCTAssertEqual(r.statusCode, 200) }
            XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "ok\n")
            healthEx.fulfill()
        }.resume()
        let disco = expectation(description: "discovery")
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/v1/discovery")!) { data, _, _ in
            let obj = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            XCTAssertEqual(obj?["app"] as? String, "remotecode")
            XCTAssertEqual(obj?["relay"] as? Bool, false)
            disco.fulfill()
        }.resume()
        wait(for: [healthEx, disco], timeout: 4)
    }

    @MainActor
    func test_rpc_route_dispatches_to_desktop_router() throws {
        let port = UInt16.random(in: 33000...44000)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let s = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher)
        try s.start()
        defer { s.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = """
        {"jsonrpc":"2.0","id":"rpc-route","method":"workspace.create","params":{"name":"mobile","cwd":"/tmp"}}
        """.data(using: .utf8)!

        let routed = expectation(description: "rpc routed")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            XCTAssertNil(err)
            if let r = resp as? HTTPURLResponse { XCTAssertEqual(r.statusCode, 200) }
            let obj = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            XCTAssertEqual(obj?["id"] as? String, "rpc-route")
            let result = obj?["result"] as? [String: Any]
            XCTAssertEqual(result?["name"] as? String, "mobile")
            XCTAssertNil(obj?["error"], "mobile RPC must reach the desktop JSON-RPC dispatcher")
            routed.fulfill()
        }.resume()
        wait(for: [routed], timeout: 4)
    }

    @MainActor
    func test_staticFileRouteServesOnlyGrantedFilesWithoutDirectoryListing() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-static-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let html = temp.appendingPathComponent("index space.html")
        try "<h1>Exact mirror</h1>".write(to: html, atomically: true, encoding: .utf8)
        let grant = try XCTUnwrap(DirectStaticFileRegistry.shared.register(fileURL: html))

        let port = UInt16.random(in: 33000...44000)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let s = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher)
        try s.start()
        defer { s.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let served = expectation(description: "granted file served")
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)\(grant.routePath)")!) { data, resp, err in
            XCTAssertNil(err)
            XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
            XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "<h1>Exact mirror</h1>")
            served.fulfill()
        }.resume()

        let blocked = expectation(description: "directory blocked")
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/__rc2_static/not-granted/\(temp.lastPathComponent)")!) { _, resp, _ in
            XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 404,
                           "static server must not expose arbitrary Mac filesystem paths")
            blocked.fulfill()
        }.resume()

        wait(for: [served, blocked], timeout: 4)
    }
}
