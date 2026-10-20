import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// Bots never get a RemoteCode in-app browser tab: bot_browser_* routes to an
/// app-owned native Chrome target, Playwright MCP child, or an explicit refusal.
/// Tests inject a fake bridge — no npx, docker, or WKWebView work happens here.
final class BotBrowserRouterTests: XCTestCase {
    private final class FakeBotBrowserBridge: BotBrowserBridging, @unchecked Sendable {
        struct Call: Equatable {
            var botID: BotID
            var route: BotBrowserRoute
            var kind: String
            var action: String
            var ref: String
            var url: String
        }

        private let lock = NSLock()
        private var records: [Call] = []
        private var payloadValue: [String: Any] = [
            "url": "https://login.example.test/home", "title": "Home", "content": "### Page",
        ]
        var performExpectation: XCTestExpectation?

        func setPayload(url: String, title: String) {
            lock.lock()
            payloadValue = ["url": url, "title": title, "content": "### Page"]
            lock.unlock()
        }

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
            lock.lock()
            records.append(Call(botID: botID, route: route, kind: kind, action: action, ref: ref, url: url))
            let payload = payloadValue
            let expectation = performExpectation
            lock.unlock()
            expectation?.fulfill()
            return payload
        }

        func recorded() -> [Call] {
            lock.lock()
            defer { lock.unlock() }
            return records
        }
    }

    private final class GuestEnsureRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var botIDs: [BotID] = []
        func record(_ botID: BotID) {
            lock.lock()
            botIDs.append(botID)
            lock.unlock()
        }
        func recorded() -> [BotID] {
            lock.lock()
            defer { lock.unlock() }
            return botIDs
        }
    }

    @MainActor
    private func botSurfaceIDs(ctx: AppContext) -> [SurfaceID] {
        var found: [SurfaceID] = []
        func walk(_ node: LayoutNode) {
            switch node {
            case .pane(let pane):
                for surface in pane.surfaces where surface.metadata["bot_id"] != nil {
                    found.append(surface.id)
                }
            case .split(let split):
                split.children.forEach(walk)
            }
        }
        for (_, ws) in ctx.state.workspaces {
            walk(ws.layout)
        }
        return found
    }

    @MainActor
    func test_logicalBotRoutesNativeChrome_andNeverGetsASurface() async throws {
        // WHY: a logical-execution-space bot uses the app-owned headless
        // Chrome bridge; it must never fall back to an in-app surface.
        let appSupport = NSTemporaryDirectory() + "RC2BotBrowserLogical-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let fake = FakeBotBrowserBridge()
        let navigated = expectation(description: "native bridge navigate")
        fake.performExpectation = navigated
        router.botBrowserBridge = fake
        let workspace = try router.createWorkspace(name: "desk", cwd: NSTemporaryDirectory())
        let bot = try ctx.botStore.create(
            name: "Piper",
            title: "",
            description: "",
            workspaceID: workspace.id
        )

        let target = try router.openBotBrowser(
            botID: bot.id,
            url: "https://login.example.test/in",
            title: "Sign in"
        )
        XCTAssertEqual(target.url, "https://login.example.test/in")
        wait(for: [navigated], timeout: 5)
        XCTAssertEqual(fake.recorded().first?.route, .chromeHost)
        fake.performExpectation = nil

        let store = BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        try BotBrowserHost.requestAction(
            store: store,
            action: BotBrowserPendingAction(
                id: "act-1",
                botID: bot.id.value.uuidString.lowercased(),
                kind: BotBrowserCatalog.act,
                action: "click",
                ref: "e1",
                text: ""
            ),
            notify: { _ in }
        )
        await router.reconcileBotBrowserActions()
        let result = try XCTUnwrap(try store.takeActionResult(id: "act-1"))
        XCTAssertEqual(result.error, "")
        XCTAssertFalse(result.payload.isEmpty)

        XCTAssertTrue(fake.recorded().allSatisfy { $0.route == .chromeHost })
        XCTAssertTrue(botSurfaceIDs(ctx: ctx).isEmpty, "no in-app tab for a bot, ever")
    }

    @MainActor
    func test_botOwnedBrowserRoutesPlaywrightLocal_persistsTarget_noSurface() throws {
        // WHY: "if the bot has its own browser it must be a playwright" —
        // open must persist the target, hand the navigate to the local
        // Playwright child off-main, and never build an in-app tab.
        let appSupport = NSTemporaryDirectory() + "RC2BotBrowserOwned-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let fake = FakeBotBrowserBridge()
        // Echo the opened page so the detached persist agrees with the open persist.
        fake.setPayload(url: "https://login.example.test/in", title: "Sign in")
        let navigated = expectation(description: "bridge navigate")
        fake.performExpectation = navigated
        router.botBrowserBridge = fake
        let workspace = try router.createWorkspace(name: "desk", cwd: NSTemporaryDirectory())
        let bot = try ctx.botStore.create(
            name: "Piper",
            title: "",
            description: "",
            desktopKind: .botOwnedBrowser,
            workspaceID: workspace.id
        )

        let target = try router.openBotBrowser(
            botID: bot.id,
            url: "https://login.example.test/in",
            title: "Sign in"
        )
        XCTAssertEqual(target.url, "https://login.example.test/in")
        wait(for: [navigated], timeout: 5)

        let calls = fake.recorded()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.route, .playwrightLocal)
        XCTAssertEqual(calls.first?.kind, BotBrowserCatalog.open)
        XCTAssertEqual(calls.first?.url, target.url)
        XCTAssertEqual(calls.first?.botID, bot.id)

        let store = BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        let persisted = try XCTUnwrap(store.loadTarget(botID: bot.id))
        XCTAssertEqual(persisted.url, target.url)
        XCTAssertEqual(persisted.title, "Sign in")
        XCTAssertTrue(botSurfaceIDs(ctx: ctx).isEmpty, "the bot's browser is the Playwright child, not a tab")
    }

    @MainActor
    func test_dockerBotPendingActionRoutesPlaywrightGuest_afterGuestEnsure() async throws {
        // WHY: "if the bot has its own Docker it must use playwright inside
        // the docker" — the act must resume/create the guest first (stubbed
        // here; docker never runs in tests) and then exec into it.
        let appSupport = NSTemporaryDirectory() + "RC2BotBrowserGuest-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let fake = FakeBotBrowserBridge()
        router.botBrowserBridge = fake
        let guests = GuestEnsureRecorder()
        router.botBrowserGuestEnsureForTesting = { botID in guests.record(botID) }
        let workspace = try router.createWorkspace(name: "desk", cwd: NSTemporaryDirectory())
        let bot = try ctx.botStore.create(
            name: "Piper",
            title: "",
            description: "",
            desktopKind: .dockerDesktop,
            workspaceID: workspace.id
        )

        let store = BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        try BotBrowserHost.requestAction(
            store: store,
            action: BotBrowserPendingAction(
                id: "act-2",
                botID: bot.id.value.uuidString.lowercased(),
                kind: BotBrowserCatalog.act,
                action: "click",
                ref: "e2",
                text: ""
            ),
            notify: { _ in }
        )
        await router.reconcileBotBrowserActions()

        let result = try XCTUnwrap(try store.takeActionResult(id: "act-2"))
        XCTAssertEqual(result.error, "")
        // JSONSerialization escapes "/" — decode instead of substring-matching.
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.payload.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["url"] as? String, "https://login.example.test/home")
        XCTAssertEqual(payload["title"] as? String, "Home")
        XCTAssertEqual(fake.recorded().map(\.route), [.playwrightGuest])
        XCTAssertEqual(fake.recorded().first?.ref, "e2")
        XCTAssertEqual(guests.recorded(), [bot.id], "guest is provisioned before the bridge exec")
        // The bridge-reported page becomes the persisted truth bot_browser_get reads.
        XCTAssertEqual(try store.loadTarget(botID: bot.id)?.url, "https://login.example.test/home")
        XCTAssertTrue(botSurfaceIDs(ctx: ctx).isEmpty)
    }

    @MainActor
    func test_legacyPendingOpenDrainsThroughBridge_forNativeAndPlaywrightRoutes() throws {
        // WHY: bot_browser_open queued by an older DistillService (or the
        // legacy service.open API) must drain through the same Playwright
        // path — including the native Chrome route — and never a tab.
        let appSupport = NSTemporaryDirectory() + "RC2BotBrowserLegacy-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let fake = FakeBotBrowserBridge()
        let navigated = expectation(description: "bridge navigates both routes")
        navigated.expectedFulfillmentCount = 2
        fake.performExpectation = navigated
        fake.setPayload(url: "https://login.example.test/in", title: "Sign in")
        router.botBrowserBridge = fake
        let workspace = try router.createWorkspace(name: "desk", cwd: NSTemporaryDirectory())
        let owned = try ctx.botStore.create(
            name: "Piper",
            title: "",
            description: "",
            desktopKind: .botOwnedBrowser,
            workspaceID: workspace.id
        )
        let logical = try ctx.botStore.create(
            name: "Lint",
            title: "",
            description: "",
            workspaceID: workspace.id
        )

        let store = BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        _ = try BotBrowserHost.requestOpen(
            store: store,
            botID: owned.id,
            url: "https://login.example.test/in",
            title: "Sign in",
            notify: { _ in }
        )
        _ = try BotBrowserHost.requestOpen(
            store: store,
            botID: logical.id,
            url: "https://login.example.test/in",
            title: "Sign in",
            notify: { _ in }
        )

        let applied = try router.reconcileBotBrowserOpens()
        XCTAssertEqual(applied.map(\.url), ["https://login.example.test/in", "https://login.example.test/in"])
        XCTAssertTrue(try store.loadPendingOpens().isEmpty, "queue drains across native and Playwright routes")
        wait(for: [navigated], timeout: 5)
        XCTAssertEqual(fake.recorded().map(\.kind), [BotBrowserCatalog.open, BotBrowserCatalog.open])
        let calls = fake.recorded()
        XCTAssertEqual(Set(calls.map(\.botID)), Set([owned.id, logical.id]))
        XCTAssertTrue(calls.contains { $0.route == .playwrightLocal })
        XCTAssertTrue(calls.contains { $0.route == .chromeHost })
        XCTAssertTrue(botSurfaceIDs(ctx: ctx).isEmpty)
    }

    @MainActor
    func test_persistBotBrowserCookiesUsesHTTPCookieSnapshot() throws {
        // WHY: legacy restored bot tabs still capture cookies; that persist
        // path must keep feeding the login-wait fallback even though new
        // opens never create such a tab.
        let appSupport = NSTemporaryDirectory() + "RC2BotBrowserCookies-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let workspace = try router.createWorkspace(name: "desk", cwd: NSTemporaryDirectory())
        let bot = try ctx.botStore.create(
            name: "Piper",
            title: "",
            description: "",
            workspaceID: workspace.id
        )
        // A restored legacy tab is just a browser descriptor tagged bot_id.
        let descriptor = SurfaceDescriptor(
            type: .browser,
            title: "Sign in",
            metadata: [
                "url": "https://login.example.test/in",
                "bot_id": bot.id.value.uuidString.lowercased(),
            ]
        )
        try ctx.apply(.addSurface(workspace.id, paneID: nil, descriptor: descriptor))

        let cookie = HTTPCookie(properties: [
            .name: "session",
            .value: "live",
            .domain: "login.example.test",
            .path: "/",
        ])!
        router.persistBotBrowserCookies(
            surfaceID: descriptor.id,
            cookies: [cookie],
            url: "https://login.example.test/in",
            title: "Home"
        )
        let store = BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        let page = try XCTUnwrap(store.loadPageState(botID: bot.id))
        XCTAssertEqual(page.cookies["session"], "live")
        XCTAssertTrue(try BotBrowserService(callerBotID: bot.id, store: store).waitLogin().isComplete)
    }

    @MainActor
    func test_manualAction_8_waitLoginStatePollOpensLoginRequestOnActiveThread() async throws {
        // WHY: wait_login must open the same unified card (kind=login) on the bot's thread, not a private flow.
        let appSupport = NSTemporaryDirectory() + "RC2BotBrowserWaitLogin-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        router.botBrowserBridge = FakeBotBrowserBridge()
        let workspace = try router.createWorkspace(name: "desk", cwd: NSTemporaryDirectory())
        let bot = try ctx.botStore.create(name: "Piper", title: "", description: "", workspaceID: workspace.id)
        let thread = AgentThreadID()
        router.botActiveThreadResolverForTesting = { _ in thread }
        let store = BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        try store.persistTarget(BotBrowserTarget(url: "https://login.example.test/in", title: "Sign in"), botID: bot.id)

        var seen: [ManualActionRequest] = []
        let token = NotificationCenter.default.addObserver(
            forName: .botManualActionRequested, object: nil, queue: nil
        ) { note in
            if let request = note.userInfo?[BotHostNotificationKey.request] as? ManualActionRequest,
               request.botID == bot.id { seen.append(request) }
        }
        defer {
            NotificationCenter.default.removeObserver(token)
            BotComputerControl.shared.forget(bot.id)
        }
        try BotBrowserHost.requestAction(
            store: store,
            action: BotBrowserPendingAction(
                id: "wait-1",
                botID: bot.id.value.uuidString.lowercased(),
                kind: BotBrowserCatalog.stateKind,
                action: BotBrowserCatalog.waitLoginAction,
                ref: "",
                text: ""
            ),
            notify: { _ in }
        )
        await router.reconcileBotBrowserActions()

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.kind, .login)
        XCTAssertEqual(seen.first?.threadID, thread)
        XCTAssertEqual(BotComputerControl.shared.openRequest(bot.id)?.kind, .login)
    }

    @MainActor
    func test_browserActRefusedWhileUserControlsBot() async throws {
        // WHY: the bot browser act must obey the same control block as computer act (nothing executes).
        let appSupport = NSTemporaryDirectory() + "RC2BotBrowserControl-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let fake = FakeBotBrowserBridge()
        router.botBrowserBridge = fake
        let control = BotComputerControl()
        router.botComputerControl = control
        let workspace = try router.createWorkspace(name: "desk", cwd: NSTemporaryDirectory())
        let bot = try ctx.botStore.create(name: "Piper", title: "", description: "", workspaceID: workspace.id)
        control.take(bot.id)
        let store = BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        try BotBrowserHost.requestAction(
            store: store,
            action: BotBrowserPendingAction(
                id: "act-ctl", botID: bot.id.value.uuidString.lowercased(),
                kind: BotBrowserCatalog.act, action: "click", ref: "e1", text: ""
            ),
            notify: { _ in }
        )
        await router.reconcileBotBrowserActions()
        let result = try XCTUnwrap(try store.takeActionResult(id: "act-ctl"))
        XCTAssertTrue(result.payload.contains(ManualActionRequest.refusalPhrase))
        XCTAssertTrue(fake.recorded().isEmpty)
    }

    @MainActor
    func test_browserActRefusedWhenUserTakesControlDuringProvisioning() async throws {
        // WHY: control can flip while the guest provisions; the act must re-check right before it fires.
        let appSupport = NSTemporaryDirectory() + "RC2BotBrowserRace-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let fake = FakeBotBrowserBridge()
        router.botBrowserBridge = fake
        let control = BotComputerControl()
        router.botComputerControl = control
        let workspace = try router.createWorkspace(name: "desk", cwd: NSTemporaryDirectory())
        let bot = try ctx.botStore.create(name: "Piper", title: "", description: "", workspaceID: workspace.id)
        XCTAssertFalse(control.isControlledByUser(bot.id))
        let botID = bot.id
        router.botBrowserBeforeBridgeActForTesting = { control.take(botID) }
        let store = BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        try BotBrowserHost.requestAction(
            store: store,
            action: BotBrowserPendingAction(
                id: "act-race", botID: bot.id.value.uuidString.lowercased(),
                kind: BotBrowserCatalog.act, action: "click", ref: "e1", text: ""
            ),
            notify: { _ in }
        )
        await router.reconcileBotBrowserActions()
        let result = try XCTUnwrap(try store.takeActionResult(id: "act-race"))
        XCTAssertTrue(result.payload.contains(ManualActionRequest.refusalPhrase))
        XCTAssertTrue(fake.recorded().isEmpty)
    }
}
