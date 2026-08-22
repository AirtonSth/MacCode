import XCTest
@testable import CoreModel

final class ChromeHostBrowserBridgeTests: XCTestCase {
    private final class FakeProcess: ManagedChromeHostProcess, @unchecked Sendable {
        private(set) var running = true
        private(set) var terminationCount = 0

        var isRunning: Bool { running }

        func terminate() {
            terminationCount += 1
            running = false
        }
    }

    private final class FakeNativeClient: NativeChromeHostBrowsing, @unchecked Sendable {
        private(set) var calls: [String] = []
        let endpoint: ChromeDevToolsEndpoint
        var stateSequence: [String] = []
        private var currentURL = "https://example.test/current"

        init(endpoint: ChromeDevToolsEndpoint) {
            self.endpoint = endpoint
        }

        func open(botID: BotID, url: String, title: String?) throws -> ChromeDevToolsPageState {
            calls.append("open")
            currentURL = url
            return ChromeDevToolsPageState(url: url, title: title ?? "Opened")
        }

        func state(botID: BotID) throws -> ChromeDevToolsPageState {
            calls.append("state")
            let url = stateSequence.isEmpty ? currentURL : stateSequence.removeFirst()
            return ChromeDevToolsPageState(url: url, title: "Current")
        }

        func snapshot(botID: BotID) throws -> ChromeDevToolsSnapshot {
            calls.append("snapshot")
            let target = ChromeDevToolsTarget(
                botID: botID,
                targetID: "target-1",
                webSocketURL: endpoint.browserWebSocketURL
            )
            return ChromeDevToolsSnapshot(
                target: target,
                token: "token-1",
                elements: [ChromeDevToolsElement(ref: "token-1.0", role: "button", name: "Continue")]
            )
        }

        func perform(
            botID: BotID,
            action: String,
            ref: String?,
            text: String,
            deltaX: Double,
            deltaY: Double
        ) throws -> ChromeDevToolsActionResult {
            calls.append("perform:\(action):\(ref ?? "")")
            let target = ChromeDevToolsTarget(
                botID: botID,
                targetID: "target-1",
                webSocketURL: endpoint.browserWebSocketURL
            )
            return ChromeDevToolsActionResult(target: target, action: action, ref: ref)
        }
    }

    private final class FakePlaywright: BotBrowserBridging, @unchecked Sendable {
        private(set) var calls: [BotBrowserRoute] = []

        func perform(
            botID: BotID,
            route: BotBrowserRoute,
            kind: String,
            action: String,
            ref: String,
            text: String,
            url: String,
            appSupport: URL
        ) throws -> [String: Any] {
            calls.append(route)
            return ["url": url, "title": "Playwright", "content": "delegated"]
        }
    }

    private final class RecordingCDPTransport: ChromeDevToolsTransport, @unchecked Sendable {
        private(set) var createdTargetIDs: [String] = []

        func send(
            method: String,
            parameters: [String: Any],
            webSocketURL: URL
        ) throws -> [String: Any] {
            guard method == "Target.createTarget" else {
                return ["result": [String: Any]()]
            }
            let targetID = "target-\(createdTargetIDs.count + 1)"
            createdTargetIDs.append(targetID)
            return [
                "result": [
                    "targetId": targetID,
                    "webSocketDebuggerUrl": "ws://127.0.0.1:9223/devtools/page/\(targetID)",
                ]
            ]
        }
    }

    private func endpoint() -> ChromeDevToolsEndpoint {
        ChromeDevToolsEndpoint(
            httpBaseURL: URL(string: "http://127.0.0.1:9223")!,
            browserWebSocketURL: URL(string: "ws://127.0.0.1:9223/devtools/browser/test")!
        )
    }

    private func activePortData() -> Data {
        Data("9223\n/devtools/browser/test\n".utf8)
    }

    func test_logicalRouteAndActivePortParsingAreNativeAndPrivate() {
        // WHY: logical Desktop must be the only route that can reach the
        // native bridge; DevToolsActivePort is the app-owned endpoint seam.
        XCTAssertEqual(BotBrowserRoute.forPublished(.logicalExecutionSpace), .chromeHost)
        XCTAssertEqual(BotBrowserRoute.forPublished(.botOwnedBrowser), .playwrightLocal)
        XCTAssertEqual(BotBrowserRoute.forPublished(.dockerDesktop), .playwrightGuest)
        XCTAssertTrue({
            guard let parsed = ManagedChromeHostBrowserBridge.endpoint(
                fromActivePort: String(data: activePortData(), encoding: .utf8)!
            ) else { return false }
            return parsed.httpBaseURL.absoluteString == "http://127.0.0.1:9223"
                && parsed.browserWebSocketURL.absoluteString == "ws://127.0.0.1:9223/devtools/browser/test"
        }())
        XCTAssertNil(ManagedChromeHostBrowserBridge.endpoint(fromActivePort: "not-a-port\n/nope"))
    }

    func test_chromeHostLaunchesOneHeadlessProfileAndMapsEveryAction() throws {
        // WHY: the app must start its own hidden Chrome endpoint, never depend
        // on a user debug flag, preserve the established payload shape, and
        // accept a changed OAuth/redirect URL after a bounded settle poll.
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RCChromeHost-\(UUID().uuidString)", isDirectory: true)
        let executable = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        let process = FakeProcess()
        let playwright = FakePlaywright()
        let clientBox = LockedClientBox()
        let sleepCounter = CallCounter()
        let launchRecorder = LaunchRecorder()
        let activePort = ManagedChromeHostBrowserBridge.activePortFile(appSupport: appSupport)
        let bridge = ManagedChromeHostBrowserBridge(
            playwright: playwright,
            resolveExecutable: { executable },
            launchProcess: { url, arguments in
                launchRecorder.record(executable: url, arguments: arguments)
                return process
            },
            makeClient: { endpoint in
                let client = FakeNativeClient(endpoint: endpoint)
                client.stateSequence = [
                    "https://prior.test",
                    "https://prior.test",
                    "https://oauth.example/callback",
                ]
                clientBox.client = client
                return client
            },
            readFile: { url in url == activePort ? Data("9223\n/devtools/browser/test\n".utf8) : nil },
            createDirectory: { _ in },
            removeFile: { _ in },
            sleep: { _ in sleepCounter.increment() },
            endpointTimeout: 0,
            endpointPollInterval: 0,
            navigationTimeout: 1,
            navigationPollInterval: 0.01
        )

        let botID = BotID()
        let open = try bridge.perform(
            botID: botID,
            route: .chromeHost,
            kind: "bot_browser_open",
            action: "",
            ref: "",
            text: "",
            url: "https://example.test",
            appSupport: appSupport
        )
        _ = try bridge.perform(
            botID: botID,
            route: .chromeHost,
            kind: "state",
            action: "",
            ref: "",
            text: "",
            url: "",
            appSupport: appSupport
        )
        let snapshot = try bridge.perform(
            botID: botID,
            route: .chromeHost,
            kind: "bot_browser_snapshot",
            action: "",
            ref: "",
            text: "",
            url: "",
            appSupport: appSupport
        )
        let act = try bridge.perform(
            botID: botID,
            route: .chromeHost,
            kind: "bot_browser_act",
            action: "click",
            ref: "token-1.0",
            text: "",
            url: "",
            appSupport: appSupport
        )

        XCTAssertEqual(open["url"] as? String, "https://oauth.example/callback")
        XCTAssertEqual(open["title"] as? String, "Current")
        XCTAssertNotNil(open["content"])
        XCTAssertTrue((snapshot["content"] as? String)?.contains("token-1.0") == true)
        XCTAssertEqual(act["url"] as? String, "https://example.test")
        XCTAssertNotNil(act["content"])
        XCTAssertEqual(launchRecorder.executable, executable)
        XCTAssertEqual(launchRecorder.arguments.count, 1)
        let arguments = try XCTUnwrap(launchRecorder.arguments.first)
        XCTAssertTrue(arguments.contains("--headless=new"))
        XCTAssertTrue(arguments.contains("--remote-debugging-port=0"))
        XCTAssertTrue(arguments.contains("--no-first-run"))
        XCTAssertTrue(arguments.contains("--no-default-browser-check"))
        XCTAssertTrue(arguments.contains("about:blank"))
        XCTAssertTrue(arguments.contains("--user-data-dir=\(ManagedChromeHostBrowserBridge.profileDirectory(appSupport: appSupport).path)"))
        XCTAssertEqual(
            clientBox.client?.calls,
            [
                "state", "open", "state", "state", "snapshot", "state", "snapshot",
                "state", "perform:click:token-1.0", "state", "snapshot",
            ]
        )
        XCTAssertEqual(sleepCounter.count, 1, "open polls a bounded settle window before returning a snapshot")
        XCTAssertEqual(playwright.calls, [])
    }

    func test_missingActivePortFailsLoudAndTerminatesManagedProcess() {
        // WHY: no endpoint must never fall back to the user's active Chrome or
        // a visible browser; the managed process is cleaned up fail-closed.
        let process = FakeProcess()
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RCChromeHostMissing-\(UUID().uuidString)", isDirectory: true)
        let bridge = ManagedChromeHostBrowserBridge(
            resolveExecutable: { URL(fileURLWithPath: "/fake/Google Chrome") },
            launchProcess: { _, _ in process },
            readFile: { _ in nil },
            createDirectory: { _ in },
            removeFile: { _ in },
            sleep: { _ in },
            endpointTimeout: 0,
            endpointPollInterval: 0
        )

        XCTAssertThrowsError(
            try bridge.perform(
                botID: BotID(), route: .chromeHost, kind: "bot_browser_open", action: "",
                ref: "", text: "", url: "https://example.test", appSupport: appSupport
            )
        ) { error in
            XCTAssertEqual(error as? ManagedChromeHostBrowserBridgeError, .endpointUnavailable)
        }
        XCTAssertEqual(process.terminationCount, 1)
    }

    func test_existingCDPClientKeepsDistinctTargetsForDistinctBots() throws {
        // WHY: one private headless Chrome profile may serve many Bots, but
        // the existing client must never reuse one Bot's CDP target for another.
        let transport = RecordingCDPTransport()
        let endpoint = self.endpoint()
        let client = ChromeDevToolsHostClient(
            endpointDiscovery: { endpoint },
            transport: transport
        )
        _ = try client.open(botID: BotID(), url: "https://one.example")
        _ = try client.open(botID: BotID(), url: "https://two.example")
        XCTAssertEqual(transport.createdTargetIDs, ["target-1", "target-2"])
    }

    func test_playwrightRoutesRemainDelegatedWithoutChromeLaunch() throws {
        // WHY: native host integration must not change local Playwright or
        // guest behavior, including their route-specific bridge ownership.
        let playwright = FakePlaywright()
        let bridge = ManagedChromeHostBrowserBridge(
            playwright: playwright,
            resolveExecutable: { XCTFail("Playwright route must not resolve Chrome"); return nil }
        )
        let payload = try bridge.perform(
            botID: BotID(), route: .playwrightGuest, kind: "bot_browser_open", action: "",
            ref: "", text: "", url: "https://guest.test", appSupport: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(payload["content"] as? String, "delegated")
        XCTAssertEqual(playwright.calls, [.playwrightGuest])
    }

    private final class LockedClientBox: @unchecked Sendable {
        var client: FakeNativeClient?
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private final class LaunchRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var executable: URL?
        private(set) var arguments: [[String]] = []

        func record(executable: URL, arguments: [String]) {
            lock.lock()
            self.executable = executable
            self.arguments.append(arguments)
            lock.unlock()
        }
    }

}
