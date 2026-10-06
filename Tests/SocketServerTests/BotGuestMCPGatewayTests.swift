import Darwin
import XCTest
import CoreModel
import Persistence
@testable import SocketServer

/// The gateway is the only door from a bot's Linux guest to the Mac's bot
/// tools. The guest can reach every Mac loopback port, so these tests pin that
/// the door opens only for the live run's bearer, only to the allowlisted
/// tools, never for browser-style requests, and closes the moment the run ends.
final class BotGuestMCPGatewayTests: XCTestCase {
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private(set) var environments: [[String: String]] = []
        private(set) var threadNames: [String] = []
        let entered = DispatchSemaphore(value: 0)
        /// When set, every tools/call waits on it (tools/list never does).
        let gate: DispatchSemaphore?

        init(gate: DispatchSemaphore? = nil) {
            self.gate = gate
        }

        func record(_ environment: [String: String], _ line: String) {
            lock.lock()
            lines.append(line)
            environments.append(environment)
            threadNames.append(Thread.current.name ?? "")
            lock.unlock()
        }

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
    }

    private let botID = UUID().uuidString
    private let runID = UUID().uuidString
    private var gateways: [BotGuestMCPGateway] = []

    override func tearDown() {
        gateways.forEach { $0.stop() }
        gateways = []
        super.tearDown()
    }

    private func makeGateway(
        _ routes: [BotGuestMCPGateway.Route] = BotGuestMCPGateway.defaultRoutes,
        maxConcurrentCallsPerRun: Int = BotGuestMCPGateway.defaultMaxConcurrentCallsPerRun
    ) -> BotGuestMCPGateway {
        let gateway = BotGuestMCPGateway(routes: routes, maxConcurrentCallsPerRun: maxConcurrentCallsPerRun)
        gateways.append(gateway)
        return gateway
    }

    /// A route with the real allowlist of `server` whose handler only records.
    private func spyRoute(
        _ server: String,
        spy: Spy,
        reply: @escaping @Sendable (String) -> String? = { line in
            let id = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"] ?? 0
            let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": "ok"]]]]
            return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)
        }
    ) -> BotGuestMCPGateway.Route {
        var route = BotGuestMCPGateway.defaultRoutes.first { $0.name == server }!
        route.handle = { environment, line in
            spy.record(environment, line)
            spy.entered.signal()
            if line.contains("tools/call") { spy.gate?.wait() }
            return reply(line)
        }
        return route
    }

    private func issue(_ gateway: BotGuestMCPGateway, runID: String? = nil) throws -> String {
        try gateway.issue(BotGuestMCPGateway.Binding(
            runID: runID ?? self.runID,
            hostEnvironment: [BotSelfConfigCatalog.callerEnvironmentKey: botID]
        )).token
    }

    private func post(
        _ server: String,
        _ body: String,
        token: String?,
        method: String = "POST",
        headers: [String: String] = ["Content-Type": "application/json"]
    ) -> LoopbackHTTPRequest {
        var all = headers
        if let token { all["Authorization"] = "Bearer \(token)" }
        return LoopbackHTTPRequest(method: method, path: "/mcp/\(server)", headers: all, body: Data(body.utf8))
    }

    private func call(_ id: Int, _ tool: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":{}}}"#
    }

    private func json(_ response: LoopbackHTTPResponse?) throws -> [String: Any] {
        let response = try XCTUnwrap(response)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func toolNames(_ response: LoopbackHTTPResponse?) throws -> Set<String> {
        let result = try XCTUnwrap(try json(response)["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        return Set(tools.compactMap { $0["name"] as? String })
    }

    private func errorMessage(_ response: LoopbackHTTPResponse?) throws -> String {
        let error = try XCTUnwrap(try json(response)["error"] as? [String: Any])
        return try XCTUnwrap(error["message"] as? String)
    }

    private let listTools = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
    private let neverGone: @Sendable () -> Bool = { false }

    // MARK: - Auth

    func test_onlyTheLiveRunBearerOpensTheGateway() throws {
        let spy = Spy()
        let gateway = makeGateway([spyRoute(BotWebCatalog.serverName, spy: spy)])
        let token = try issue(gateway)
        let web = BotWebCatalog.serverName

        XCTAssertEqual(gateway.respond(to: post(web, listTools, token: nil), isClientGone: neverGone)?.status, 401)
        XCTAssertEqual(gateway.respond(to: post(web, listTools, token: "x" + token.dropFirst()), isClientGone: neverGone)?.status, 401)
        XCTAssertEqual(gateway.respond(
            to: post(web, listTools, token: nil, headers: ["Content-Type": "application/json", "Authorization": "Basic \(token)"]),
            isClientGone: neverGone
        )?.status, 401)
        XCTAssertEqual(spy.callCount, 0, "a refused request must never run a handler")

        XCTAssertEqual(gateway.respond(to: post(web, listTools, token: token), isClientGone: neverGone)?.status, 200)
        XCTAssertEqual(spy.callCount, 1)

        gateway.revoke(runID: runID)
        XCTAssertEqual(gateway.respond(to: post(web, listTools, token: token), isClientGone: neverGone)?.status, 401,
                       "a finished run's bearer must not keep working")
        XCTAssertEqual(spy.callCount, 1)
    }

    func test_eachRunGetsItsOwnUnguessableBearerAndRevokeEndsOnlyThatRun() throws {
        let spy = Spy()
        let gateway = makeGateway([spyRoute(BotWebCatalog.serverName, spy: spy)])
        let first = try issue(gateway)
        let otherRun = UUID().uuidString
        let second = try issue(gateway, runID: otherRun)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 43, "32 random bytes, base64url without padding")
        XCTAssertNil(first.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))

        gateway.revoke(runID: otherRun)
        XCTAssertEqual(gateway.respond(to: post(BotWebCatalog.serverName, listTools, token: first), isClientGone: neverGone)?.status, 200)
        XCTAssertEqual(gateway.respond(to: post(BotWebCatalog.serverName, listTools, token: second), isClientGone: neverGone)?.status, 401)
    }

    func test_bearerDigestsCompareInConstantTimeOverEveryByte() {
        let digest = [UInt8](repeating: 7, count: 32)
        var lastByteDiffers = digest
        lastByteDiffers[31] = 8
        XCTAssertTrue(BotGuestMCPGateway.constantTimeEqual(digest, digest))
        XCTAssertFalse(BotGuestMCPGateway.constantTimeEqual(digest, lastByteDiffers))
        XCTAssertFalse(BotGuestMCPGateway.constantTimeEqual(digest, Array(digest.prefix(31))))
    }

    // MARK: - Allowlist

    func test_selfConfigHidesAndRefusesTheHostCatalogTools() throws {
        let gateway = makeGateway()
        let token = try issue(gateway)
        let server = BotSelfConfigCatalog.serverName

        let names = try toolNames(gateway.respond(to: post(server, listTools, token: token), isClientGone: neverGone))
        XCTAssertEqual(names, Set(BotSelfConfigCatalog.toolNames))
        XCTAssertFalse(names.contains { $0.hasPrefix("rc_") }, "rc_* tools drive the whole Mac app")
        XCTAssertTrue(names.contains(BotSelfConfigCatalog.askPeer), "peer delegation stays available in the VM")

        let spy = Spy()
        let spying = makeGateway([spyRoute(server, spy: spy)])
        let spyToken = try issue(spying)
        for tool in RemoteCodeHostCatalog.toolNames {
            let message = try errorMessage(spying.respond(to: post(server, call(2, tool), token: spyToken), isClientGone: neverGone))
            XCTAssertTrue(message.contains("not available"), tool)
        }
        XCTAssertEqual(spy.callCount, 0)
    }

    func test_computerOffersOnlyTheToolsThatNeedTheMac() throws {
        let gateway = makeGateway()
        let token = try issue(gateway)
        let server = BotComputerCatalog.serverName
        let names = try toolNames(gateway.respond(to: post(server, listTools, token: token), isClientGone: neverGone))
        XCTAssertEqual(names, [
            BotComputerCatalog.requestUserAction,
            BotComputerCatalog.postScreenshot,
            BotComputerCatalog.requestMacExecution,
        ])

        // exec/observe/act: the agent has its own shell and desktop in the
        // guest. rebuild would recreate the container the agent runs in.
        let spy = Spy()
        let spying = makeGateway([spyRoute(server, spy: spy)])
        let spyToken = try issue(spying)
        for tool in [BotComputerCatalog.exec, BotComputerCatalog.rebuild, BotComputerCatalog.observe, BotComputerCatalog.act] {
            let message = try errorMessage(spying.respond(to: post(server, call(3, tool), token: spyToken), isClientGone: neverGone))
            XCTAssertEqual(message, "\(tool) is not available to bot runs inside the Linux VM.")
        }
        XCTAssertEqual(spy.callCount, 0, "a denied tool must never reach the host handler")
        _ = try json(spying.respond(to: post(server, call(4, BotComputerCatalog.postScreenshot), token: spyToken), isClientGone: neverGone))
        XCTAssertEqual(spy.callCount, 1)
    }

    func test_filteredServersDropInitializeInstructionsThatNameHiddenTools() throws {
        let gateway = makeGateway()
        let token = try issue(gateway)
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#
        for server in [BotComputerCatalog.serverName, BotSelfConfigCatalog.serverName] {
            let result = try XCTUnwrap(try json(gateway.respond(to: post(server, initialize, token: token), isClientGone: neverGone))["result"] as? [String: Any])
            XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
            XCTAssertNil(result["instructions"], server)
        }
        let web = try XCTUnwrap(try json(gateway.respond(to: post(BotWebCatalog.serverName, initialize, token: token), isClientGone: neverGone))["result"] as? [String: Any])
        XCTAssertNotNil(web["instructions"])
    }

    func test_unknownServerIs404AndNoDistillerOrComputerUseIsRouted() throws {
        let gateway = makeGateway()
        let token = try issue(gateway)
        for server in ["distill", "computer-use", "remotecode-bot-browser", "retrieve", ""] {
            XCTAssertEqual(gateway.respond(to: post(server, listTools, token: token), isClientGone: neverGone)?.status, 404, server)
        }
    }

    // MARK: - Request hygiene

    func test_browserStyleAndNonJSONRequestsNeverReachAHandler() throws {
        let spy = Spy()
        let gateway = makeGateway([spyRoute(BotWebCatalog.serverName, spy: spy)])
        let token = try issue(gateway)
        let web = BotWebCatalog.serverName
        let withOrigin = post(web, listTools, token: token, headers: ["Content-Type": "application/json", "Origin": "http://evil.example"])
        XCTAssertEqual(gateway.respond(to: withOrigin, isClientGone: neverGone)?.status, 403)
        XCTAssertEqual(gateway.respond(to: post(web, "", token: token, method: "OPTIONS"), isClientGone: neverGone)?.status, 405)
        XCTAssertEqual(gateway.respond(to: post(web, "", token: token, method: "GET"), isClientGone: neverGone)?.status, 405)
        XCTAssertEqual(gateway.respond(to: post(web, "", token: token, method: "DELETE"), isClientGone: neverGone)?.status, 405)
        XCTAssertEqual(gateway.respond(to: post(web, listTools, token: token, headers: ["Content-Type": "text/plain"]), isClientGone: neverGone)?.status, 415)
        XCTAssertEqual(gateway.respond(to: post(web, listTools, token: token, headers: [:]), isClientGone: neverGone)?.status, 415)
        XCTAssertEqual(gateway.respond(to: post(web, "[1,2]", token: token), isClientGone: neverGone)?.status, 400)
        XCTAssertEqual(spy.callCount, 0)
        XCTAssertEqual(gateway.respond(
            to: post(web, listTools, token: token, headers: ["Content-Type": "application/json; charset=utf-8"]),
            isClientGone: neverGone
        )?.status, 200)
    }

    func test_notificationsAreAcceptedWithoutAReplyOrHandler() throws {
        let spy = Spy()
        let gateway = makeGateway([spyRoute(BotWebCatalog.serverName, spy: spy)])
        let token = try issue(gateway)
        let response = gateway.respond(
            to: post(BotWebCatalog.serverName, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, token: token),
            isClientGone: neverGone
        )
        XCTAssertEqual(response?.status, 202)
        XCTAssertEqual(response?.body.count, 0)
        XCTAssertEqual(spy.callCount, 0)
    }

    // MARK: - Execution

    func test_handlerRunsWithTheRunsHostEnvironmentOnADedicatedThread() async throws {
        let spy = Spy()
        let gateway = makeGateway([spyRoute(BotWebCatalog.serverName, spy: spy)])
        let token = try issue(gateway)
        // Called from a Swift concurrency context on purpose: the handler must
        // still run on the gateway's own thread, not the cooperative pool.
        _ = try json(gateway.respond(to: post(BotWebCatalog.serverName, listTools, token: token), isClientGone: neverGone))
        XCTAssertEqual(spy.environments.first?[BotSelfConfigCatalog.callerEnvironmentKey], botID)
        XCTAssertEqual(spy.threadNames.first, BotGuestMCPGateway.handlerThreadPrefix + BotWebCatalog.serverName)
    }

    func test_hostEnvironmentKeepsOnlyWhatTheMacStdioChildInherits() {
        let run: [String: String] = [
            "RC_REMOTE_CODE_BOT_ID": "bot",
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": "/support",
            "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": "thread",
            "RC_REMOTE_CODE_ROOT_RUN_ID": "run",
            "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH": "/tmp/s.sock",
            BotPeerDelegation.capabilityEnvironmentKey: "cap",
            "RC_REMOTE_CODE_BOT_TURN_CONTEXT": "ctx",
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            "PATH": "/usr/bin",
            "HOME": "/Users/me",
            "OPENROUTER_API_KEY": "secret",
            "RC_REMOTE_CODE_ROOT_RUN_ID_EXTRA": "x",
        ]
        let kept = BotGuestMCPGateway.Binding.hostEnvironment(fromRunEnvironment: run)
        XCTAssertEqual(Set(kept.keys), Set(BotGuestMCPGateway.Binding.hostEnvironmentKeys))
        XCTAssertEqual(kept["RC_REMOTE_CODE_ROOT_RUN_ID"], "run")
    }

    func test_revokeAnswersAnInFlightCallAtOnceAndDropsItsLateResult() throws {
        let spy = Spy(gate: DispatchSemaphore(value: 0))
        let gateway = makeGateway([spyRoute(BotSelfConfigCatalog.serverName, spy: spy)])
        let token = try issue(gateway)
        let request = post(BotSelfConfigCatalog.serverName, call(5, BotSelfConfigCatalog.askPeer), token: token)
        let done = expectation(description: "in-flight call answered")
        let box = ResponseBox()
        Thread.detachNewThread { [neverGone] in
            box.value = gateway.respond(to: request, isClientGone: neverGone)
            done.fulfill()
        }
        XCTAssertEqual(spy.entered.wait(timeout: .now() + 5), .success)

        let revokedAt = Date()
        gateway.revoke(runID: runID)
        wait(for: [done], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(revokedAt), 0.5, "a stopped run must not wait for a peer's whole turn")
        XCTAssertEqual(try errorMessage(box.value), "The RemoteCode run that made this call has ended.")
        spy.gate?.signal()
    }

    func test_eachRunHasItsOwnConcurrencyCapAndSlotsFreeWhenWorkEnds() throws {
        let gate = DispatchSemaphore(value: 0)
        let spy = Spy(gate: gate)
        let gateway = makeGateway([spyRoute(BotWebCatalog.serverName, spy: spy)], maxConcurrentCallsPerRun: 2)
        let token = try issue(gateway)
        let web = BotWebCatalog.serverName
        let finished = expectation(description: "blocked calls finish")
        finished.expectedFulfillmentCount = 2
        for id in 1...2 {
            let request = post(web, call(id, BotWebCatalog.fetch), token: token)
            Thread.detachNewThread { [neverGone] in
                _ = gateway.respond(to: request, isClientGone: neverGone)
                finished.fulfill()
            }
            XCTAssertEqual(spy.entered.wait(timeout: .now() + 5), .success)
        }

        // A third call is refused at once rather than queued behind the others.
        let refused = try errorMessage(gateway.respond(to: post(web, call(3, BotWebCatalog.fetch), token: token), isClientGone: neverGone))
        XCTAssertTrue(refused.hasPrefix("Too many RemoteCode tool calls at once for this run"), refused)
        XCTAssertEqual(spy.callCount, 2)

        // The cap is per run: another run is not starved by this one.
        let other = try issue(gateway, runID: UUID().uuidString)
        _ = try toolNames(gateway.respond(to: post(web, listTools, token: other), isClientGone: neverGone))

        gate.signal()
        gate.signal()
        wait(for: [finished], timeout: 5)
        // Both slots came back: with a leak this list would be refused.
        _ = try toolNames(gateway.respond(to: post(web, listTools, token: token), isClientGone: neverGone))
    }

    func test_clientHangupStopsWaitingWithoutAReply() throws {
        let spy = Spy(gate: DispatchSemaphore(value: 0))
        let gateway = makeGateway([spyRoute(BotWebCatalog.serverName, spy: spy)])
        let token = try issue(gateway)
        let gone = ResponseBox()
        let start = Date()
        let response = gateway.respond(to: post(BotWebCatalog.serverName, call(1, BotWebCatalog.fetch), token: token)) { [gone] in
            gone.calls += 1
            return gone.calls >= 2
        }
        XCTAssertNil(response, "nobody is left to read a reply")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        spy.gate?.signal()
    }

    // MARK: - Real socket

    func test_realSocketServesMCPOverLoopbackOnly() throws {
        let gateway = makeGateway()
        XCTAssertNil(gateway.port, "the listener starts lazily, on the first guest run")
        let token = try issue(gateway)
        let port = try XCTUnwrap(gateway.port)
        XCTAssertEqual(gateway.boundAddressForTesting, "127.0.0.1")

        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let ok = try rawRequest(port: port, """
        POST /mcp/\(BotComputerCatalog.serverName) HTTP/1.1\r
        Host: host.docker.internal:\(port)\r
        Authorization: Bearer \(token)\r
        Content-Type: application/json\r
        Accept: application/json, text/event-stream\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """)
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200 OK\r\n"), ok)
        XCTAssertTrue(ok.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(ok.contains(BotComputerCatalog.postScreenshot))
        XCTAssertFalse(ok.contains(BotComputerCatalog.exec))

        let wrong = try rawRequest(port: port, "POST /mcp/\(BotWebCatalog.serverName) HTTP/1.1\r\nAuthorization: Bearer nope\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")
        XCTAssertTrue(wrong.hasPrefix("HTTP/1.1 401 "), wrong)

        let chunked = try rawRequest(port: port, "POST /mcp/\(BotWebCatalog.serverName) HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n")
        XCTAssertTrue(chunked.hasPrefix("HTTP/1.1 411 "), chunked)

        let huge = try rawRequest(port: port, "POST /mcp/\(BotWebCatalog.serverName) HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(2 * 1_024 * 1_024)\r\n\r\n")
        XCTAssertTrue(huge.hasPrefix("HTTP/1.1 413 "), huge)

        gateway.stop()
        XCTAssertNil(gateway.port)
        XCTAssertThrowsError(try rawRequest(port: port, "GET / HTTP/1.1\r\n\r\n"), "stop closes the listener")
    }

    private final class ResponseBox: @unchecked Sendable {
        var value: LoopbackHTTPResponse?
        var calls = 0
    }

    private func rawRequest(port: UInt16, _ text: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: response, as: UTF8.self)
    }
}
