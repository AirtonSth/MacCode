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

        let creates = transport.calls.filter { $0.method == "Target.createTarget" }
        XCTAssertEqual(creates.count, 2,
                       "A Bot reuses its target, while a second Bot receives a distinct target.")
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

        let rejectedTransport = FakeChromeDevToolsTransport()
        rejectedTransport.sendError = ChromeDevToolsHostClientError.protocolError("hidden is unsupported")
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
    var runtimeValue: [String: Any] = ["url": "https://example.com", "title": "Example"]
    var sendError: Error?

    func send(method: String, parameters: [String: Any], webSocketURL: URL) throws -> [String: Any] {
        calls.append(Call(method: method, parameters: parameters, webSocketURL: webSocketURL))
        if let sendError { throw sendError }
        if method == "Target.createTarget" {
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
