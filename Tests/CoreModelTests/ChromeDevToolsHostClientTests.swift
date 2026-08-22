import XCTest
@testable import CoreModel

final class ChromeDevToolsHostClientTests: XCTestCase {
    func testEachBotGetsOneStableBackgroundTargetAndTargetsNeverCross() throws {
        // WHY: browser sessions are Bot-owned state; sharing a CDP target would
        // let one Bot read or mutate another Bot's page.
        let discovery = FakeEndpointDiscovery()
        let transport = FakeChromeDevToolsTransport()
        let client = ChromeDevToolsHostClient(endpointDiscovery: discovery, transport: transport)
        let firstBot = BotID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let secondBot = BotID(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

        _ = try client.open(botID: firstBot, url: "https://one.example")
        _ = try client.open(botID: firstBot, url: "https://one.example/two")
        _ = try client.open(botID: secondBot, url: "https://two.example")
        _ = try client.open(botID: secondBot, url: "https://two.example/again")

        let creates = transport.calls.filter { $0.method == "Target.createTarget" }
        let contextCreates = transport.calls.filter { $0.method == "Target.createBrowserContext" }
        XCTAssertEqual(creates.count, 2,
                       "A Bot reuses its target, while a second Bot receives a distinct target.")
        XCTAssertEqual(contextCreates.count, 2,
                       "A Bot creates one isolated BrowserContext, while repeated calls reuse it.")
        XCTAssertEqual(Set(contextCreates.compactMap { $0.parameters["browserContextId"] as? String }).count, 0,
                       "BrowserContext creation must not borrow or accept another Bot's context.")
        let contextIDs = transport.browserContextIDs
        XCTAssertEqual(contextIDs.count, 2,
                       "Chrome must return one context ID per Bot.")
        XCTAssertEqual(Set(contextIDs).count, 2,
                       "Different Bots must never share a BrowserContext ID.")
        let targetContextIDs = creates.compactMap { $0.parameters["browserContextId"] as? String }
        XCTAssertEqual(targetContextIDs, contextIDs,
                       "Each hidden target must be created inside its own Bot's isolated context.")
        XCTAssertEqual(transport.targetIDs.count, 2,
                       "Repeated opens must reuse each Bot's existing target.")
        XCTAssertEqual(transport.targetIDs.count, Set(transport.targetIDs).count,
                       "Different Bots must never reuse a target ID.")
        XCTAssertEqual(Set(creates.compactMap { ($0.parameters["url"] as? String) }), ["about:blank"],
                       "Target creation must not navigate or borrow another Bot's current page.")
        XCTAssertTrue(creates.allSatisfy { ($0.parameters["background"] as? Bool) == true },
                      "Every target must be requested in background so Chrome is never activated.")
        XCTAssertTrue(creates.allSatisfy { ($0.parameters["hidden"] as? Bool) == true },
                      "Every logical Bot target must be hidden rather than a visible-tab fallback.")
        XCTAssertEqual(creates.compactMap { $0.parameters["focus"] as? Bool }, [false, false],
                       "The safe creation request must explicitly prohibit focus changes.")
        XCTAssertEqual(creates.compactMap { $0.parameters["newWindow"] as? Bool }, [false, false],
                       "A background target must stay in the existing Chrome window.")
        XCTAssertFalse(transport.calls.contains { $0.method == "Target.activateTarget" },
                       "The client must never activate a target to perform a browser action.")
    }

    func testOpenStateAndActionsMapToCDPWithoutActivation() throws {
        // WHY: logical Desktop browser actions must not steal the user's tab or
        // foreground application while still exercising the page.
        let transport = FakeChromeDevToolsTransport()
        transport.responses["Target.createTarget"] = [
            "result": [
                "targetId": "target-one",
                "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/target-one"
            ]
        ]
        transport.responses["Runtime.evaluate"] = [
            "result": ["result": ["value": ["url": "https://example.com", "title": "Example"]]]
        ]
        let client = ChromeDevToolsHostClient(
            endpointDiscovery: FakeEndpointDiscovery(),
            transport: transport
        )
        let bot = BotID()

        let opened = try client.open(botID: bot, url: "https://example.com")
        XCTAssertEqual(opened.url, "https://example.com")
        _ = try client.state(botID: bot)
        transport.responses["Runtime.evaluate"] = [
            "result": ["result": ["value": ["elements": [
                ["role": "button", "name": "Save", "value": ""]
            ]]]]
        ]
        let snapshot = try client.snapshot(botID: bot)
        XCTAssertEqual(snapshot.elements.count, 1)
        XCTAssertEqual(snapshot.elements[0].role, "button")

        _ = try client.click(botID: bot, ref: snapshot.elements[0].ref)
        _ = try client.type(botID: bot, ref: snapshot.elements[0].ref, text: "hello")
        _ = try client.hover(botID: bot, ref: snapshot.elements[0].ref)
        _ = try client.scroll(botID: bot, ref: snapshot.elements[0].ref, deltaX: 0, deltaY: 300)

        let methods = transport.calls.map(\.method)
        XCTAssertTrue(methods.contains("Page.navigate"), "Open must use Page.navigate on the Bot target.")
        XCTAssertGreaterThanOrEqual(methods.filter { $0 == "Runtime.evaluate" }.count, 6,
                                    "State, snapshot, and all four actions must use runtime evaluation.")
        XCTAssertFalse(methods.contains("Target.activateTarget"),
                       "CDP actions must not change Chrome's active target or application focus.")
    }

    func testRefsAreScopedToTheLatestSnapshotAndTarget() throws {
        // WHY: an element ref describes one observed DOM; replaying it after a
        // new observation or through another Bot could mutate the wrong page.
        let transport = FakeChromeDevToolsTransport()
        transport.responses["Target.createTarget"] = [
            "result": [
                "targetId": "target-one",
                "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/target-one"
            ]
        ]
        let client = ChromeDevToolsHostClient(
            endpointDiscovery: FakeEndpointDiscovery(),
            transport: transport
        )
        let bot = BotID()
        let otherBot = BotID()
        transport.runtimeValue = ["elements": [["role": "button", "name": "Save", "value": ""]]]
        let snapshot = try client.snapshot(botID: bot)

        XCTAssertThrowsError(try client.click(botID: otherBot, ref: snapshot.elements[0].ref)) { error in
            XCTAssertEqual(error as? ChromeDevToolsHostClientError, .staleReference,
                           "A ref from another Bot must not be usable against its target.")
        }
        _ = try client.snapshot(botID: bot)
        XCTAssertThrowsError(try client.click(botID: bot, ref: snapshot.elements[0].ref)) { error in
            XCTAssertEqual(error as? ChromeDevToolsHostClientError, .staleReference,
                           "Taking a new snapshot invalidates refs from the previous DOM observation.")
        }
    }

    func testUnsupportedBackgroundCreationAndProtocolFailuresFailClosed() throws {
        // WHY: a missing safe target or malformed protocol result must never
        // degrade into an active-tab fallback with an unproven side effect.
        let unsupportedTransport = FakeChromeDevToolsTransport()
        unsupportedTransport.responses["Target.createTarget"] = [
            "result": ["targetId": "missing-websocket", "webSocketDebuggerUrl": "http://not-a-websocket"]
        ]
        let client = ChromeDevToolsHostClient(
            endpointDiscovery: FakeEndpointDiscovery(),
            transport: unsupportedTransport
        )

        XCTAssertThrowsError(try client.open(botID: BotID(), url: "https://example.com")) { error in
            XCTAssertTrue(error is BrowserBackgroundUnsupported,
                          "A target without a safe background transport must be rejected explicitly.")
        }

        let contextFailureTransport = FakeChromeDevToolsTransport()
        contextFailureTransport.responses["Target.createBrowserContext"] = ["result": [:]]
        let contextFailureClient = ChromeDevToolsHostClient(
            endpointDiscovery: FakeEndpointDiscovery(),
            transport: contextFailureTransport
        )
        XCTAssertThrowsError(try contextFailureClient.open(botID: BotID(), url: "https://example.com")) { error in
            XCTAssertTrue(error is BrowserBackgroundUnsupported,
                          "A failed BrowserContext creation must fail closed before any target is created.")
        }
        XCTAssertEqual(contextFailureTransport.calls.filter { $0.method == "Target.createTarget" }.count, 0,
                       "Context failure must not fall back to a visible or shared target.")

        let rejectedTransport = FakeChromeDevToolsTransport()
        rejectedTransport.sendErrors["Target.createTarget"] = ChromeDevToolsHostClientError.protocolError("hidden is unsupported")
        let rejectedClient = ChromeDevToolsHostClient(
            endpointDiscovery: FakeEndpointDiscovery(),
            transport: rejectedTransport
        )
        XCTAssertThrowsError(try rejectedClient.open(botID: BotID(), url: "https://example.com")) { error in
            XCTAssertTrue(error is BrowserBackgroundUnsupported,
                          "CDP rejection of hidden creation must surface as BrowserBackgroundUnsupported.")
        }
        XCTAssertEqual(rejectedTransport.calls.filter { $0.method == "Target.createTarget" }.count, 1,
                       "A rejected hidden request must not retry as a visible or focused target.")

        let protocolTransport = FakeChromeDevToolsTransport()
        protocolTransport.responses["Target.createTarget"] = ["result": ["targetId": "target-one", "webSocketDebuggerUrl": "ws://target"]]
        protocolTransport.responses["Page.navigate"] = ["result": [:]]
        protocolTransport.responses["Runtime.evaluate"] = ["result": [:]]
        let protocolClient = ChromeDevToolsHostClient(
            endpointDiscovery: FakeEndpointDiscovery(),
            transport: protocolTransport
        )
        XCTAssertThrowsError(try protocolClient.state(botID: BotID())) { error in
            XCTAssertTrue(error is ChromeDevToolsHostClientError,
                          "A missing Runtime.evaluate result must not be reported as a successful page state.")
        }

        let transportFailure = FakeChromeDevToolsTransport()
        transportFailure.sendError = ChromeDevToolsHostClientError.transport("offline")
        let transportClient = ChromeDevToolsHostClient(
            endpointDiscovery: FakeEndpointDiscovery(),
            transport: transportFailure
        )
        XCTAssertThrowsError(try transportClient.open(botID: BotID(), url: "https://example.com")) { error in
            XCTAssertEqual(error as? ChromeDevToolsHostClientError, .transport("offline"),
                           "An unavailable WebSocket must fail closed instead of creating a phantom target.")
        }

        let factory = FakeWebSocketFactory()
        let persistentTransport = URLSessionChromeDevToolsTransport(timeout: 1) { url in
            let task = FakeWebSocketTask()
            factory.created.append((url, task))
            return task
        }
        let sessionURL = URL(string: "ws://127.0.0.1:9222/devtools/browser/session")!
        _ = try persistentTransport.send(method: "Runtime.enable", parameters: [:], webSocketURL: sessionURL)
        _ = try persistentTransport.send(method: "Runtime.evaluate", parameters: ["expression": "1"], webSocketURL: sessionURL)
        XCTAssertEqual(factory.created.count, 1,
                       "Repeated commands for one browser/target URL must reuse its persistent CDP session.")
        XCTAssertEqual(factory.created[0].1.resumeCount, 1,
                       "A persistent CDP session must be resumed once, not recreated per command.")
        XCTAssertEqual(factory.created[0].1.cancelCount, 0,
                       "The browser/target session must remain open after each command so hidden targets survive.")
        XCTAssertEqual(factory.created[0].1.commandIDs, [1, 2],
                       "Each persistent session must assign and correlate monotonically increasing command IDs.")

        let mismatchFactory = FakeWebSocketFactory(mismatchedReplyID: true)
        let mismatchTransport = URLSessionChromeDevToolsTransport(timeout: 1) { url in
            let task = FakeWebSocketTask(mismatchedReplyID: mismatchFactory.mismatchedReplyID)
            mismatchFactory.created.append((url, task))
            return task
        }
        XCTAssertThrowsError(try mismatchTransport.send(method: "Runtime.enable", parameters: [:], webSocketURL: sessionURL)) { error in
            guard let error = error as? ChromeDevToolsHostClientError,
                  case .protocolError = error else {
                return XCTFail("A mismatched CDP response id must fail as a protocol error.")
            }
        }
        XCTAssertEqual(mismatchFactory.created.count, 1,
                       "A mismatched reply must not trigger a second socket or visible-target retry.")
    }
}

private final class FakeEndpointDiscovery: ChromeDevToolsEndpointDiscovering {
    let endpoint = ChromeDevToolsEndpoint(
        httpBaseURL: URL(string: "http://127.0.0.1:9222")!,
        browserWebSocketURL: URL(string: "ws://127.0.0.1:9222/devtools/browser/fake")!
    )

    func discover() throws -> ChromeDevToolsEndpoint { endpoint }

    func targetWebSocketURL(for targetID: String, endpoint: ChromeDevToolsEndpoint) throws -> URL? {
        URL(string: "ws://127.0.0.1:9222/devtools/page/\(targetID)")
    }
}

private final class FakeChromeDevToolsTransport: ChromeDevToolsTransport {
    struct Call {
        let method: String
        let parameters: [String: Any]
        let webSocketURL: URL
    }

    var calls: [Call] = []
    var responses: [String: [String: Any]] = [:]
    var nextTargetID = "target-1"
    var targetIDs: [String] = []
    var nextBrowserContextID = "context-1"
    var browserContextIDs: [String] = []
    var runtimeValue: [String: Any] = ["url": "https://example.com", "title": "Example"]
    var sendError: Error?
    var sendErrors: [String: Error] = [:]

    func send(method: String, parameters: [String: Any], webSocketURL: URL) throws -> [String: Any] {
        calls.append(Call(method: method, parameters: parameters, webSocketURL: webSocketURL))
        if let error = sendErrors[method] { throw error }
        if let sendError { throw sendError }
        if method == "Target.createBrowserContext" {
            let contextID = nextBrowserContextID
            browserContextIDs.append(contextID)
            nextBrowserContextID = "context-\(browserContextIDs.count + 1)"
            return responses[method] ?? ["result": ["browserContextId": contextID]]
        }
        if method == "Target.createTarget" {
            targetIDs.append(nextTargetID)
            let result = [
                "targetId": nextTargetID,
                "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/\(nextTargetID)"
            ] as [String: Any]
            nextTargetID = "target-\(calls.filter { $0.method == "Target.createTarget" }.count + 1)"
            return responses[method] ?? ["result": result]
        }
        if let response = responses[method] { return response }
        if method == "Runtime.evaluate" {
            if parameters["expression"] as? String == "(() => ({ url: String(location.href), title: String(document.title) }))()" {
                return ["result": ["result": ["value": ["url": "https://example.com", "title": "Example"]]]]
            }
            if (parameters["expression"] as? String)?.contains("const token") == true {
                return ["result": ["result": ["value": runtimeValue]]]
            }
            if (parameters["expression"] as? String)?.contains("data-remotecode-ref") == true {
                return ["result": ["result": ["value": ["ok": true]]]]
            }
            return ["result": ["result": ["value": runtimeValue]]]
        }
        return ["result": ["result": ["value": ["ok": true]]]]
    }
}

private final class FakeWebSocketFactory {
    var created: [(URL, FakeWebSocketTask)] = []
    let mismatchedReplyID: Bool

    init(mismatchedReplyID: Bool = false) {
        self.mismatchedReplyID = mismatchedReplyID
    }
}

private final class FakeWebSocketTask: ChromeDevToolsWebSocketTasking {
    private(set) var resumeCount = 0
    private(set) var cancelCount = 0
    private(set) var commandIDs: [Int] = []
    private let mismatchedReplyID: Bool
    private var queued: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var waitingReceiver: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?

    init(mismatchedReplyID: Bool = false) {
        self.mismatchedReplyID = mismatchedReplyID
    }

    func resume() { resumeCount += 1 }
    func cancel() { cancelCount += 1 }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard case .string(let raw) = message,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commandID = object["id"] as? Int else {
            return completionHandler(ChromeDevToolsHostClientError.protocolError("fake command malformed"))
        }
        commandIDs.append(commandID)
        if commandID == 1 {
            if !mismatchedReplyID {
                queued.append(.success(.string("{\"method\":\"Page.loadEventFired\"}")))
            }
            let responseID = mismatchedReplyID ? 99 : commandID
            queued.append(.success(.string("{\"id\":\(responseID),\"result\":{\"ok\":true}}")))
        } else {
            queued.append(.success(.string("{\"id\":\(commandID),\"result\":{\"ok\":true}}")))
        }
        completionHandler(nil)
    }

    func receive(
        completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        if queued.isEmpty {
            waitingReceiver = completionHandler
        } else {
            completionHandler(queued.removeFirst())
        }
    }
}
