import XCTest
import CoreModel
import Persistence
import SocketServer
@testable import AppShell

final class BotBrowserRouterTests: XCTestCase {
    @MainActor
    func test_openBotBrowserPersistsTargetAndEmitsHostState() throws {
        // WHY: navigating the bot browser must persist URL/title and emit surface.browser.
        let appSupport = NSTemporaryDirectory() + "RC2BotBrowser-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let workspace = try router.createWorkspace(name: "desk", cwd: NSTemporaryDirectory())
        let bot = try ctx.botStore.create(
            name: "Piper",
            title: "",
            description: "",
            provider: .claude,
            workspaceID: workspace.id
        )
        let startSeq = EventBus.shared.snapshot().lastSeq
        var events: [(String?, String?)] = []
        let token = EventBus.shared.subscribe(since: startSeq) { event in
            if event.kind == BotBrowserHostState.eventKind {
                events.append((event.payload.objectValue?["url"]?.stringValue, event.payload.objectValue?["title"]?.stringValue))
            }
        }
        defer { EventBus.shared.unsubscribe(token) }

        let target = try router.openBotBrowser(
            botID: bot.id,
            url: "https://login.example.test/in",
            title: "Sign in"
        )
        XCTAssertEqual(target.url, "https://login.example.test/in")
        let store = BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        let persisted = try XCTUnwrap(store.loadTarget(botID: bot.id))
        XCTAssertEqual(persisted.url, target.url)
        XCTAssertEqual(persisted.title, "Sign in")

        let seen = events.contains { $0.0 == target.url }
        XCTAssertTrue(seen, "open must emit \(BotBrowserHostState.eventKind) with the new URL, got \(events)")

        let reopened = BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        XCTAssertEqual(try reopened.loadTarget(botID: bot.id)?.url, target.url)
    }

    @MainActor
    func test_mcpOpenAppliesThroughReconcileOpenBotBrowser() throws {
        // WHY: bot_browser_open runs in DistillService; the app must apply pending via openBotBrowser.
        let appSupport = NSTemporaryDirectory() + "RC2BotBrowserMCP-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let workspace = try router.createWorkspace(name: "desk", cwd: NSTemporaryDirectory())
        let bot = try ctx.botStore.create(
            name: "Piper", title: "", description: "", provider: .claude, workspaceID: workspace.id
        )
        let store = BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        let service = BotBrowserService(callerBotID: bot.id, store: store)
        _ = try service.call(name: BotBrowserCatalog.open, arguments: [
            "url": "https://login.example.test/in",
            "title": "Sign in",
        ])
        XCTAssertFalse(try store.loadPendingOpens().isEmpty)

        let startSeq = EventBus.shared.snapshot().lastSeq
        var urls: [String] = []
        let token = EventBus.shared.subscribe(since: startSeq) { event in
            if event.kind == BotBrowserHostState.eventKind,
               let url = event.payload.objectValue?["url"]?.stringValue {
                urls.append(url)
            }
        }
        defer { EventBus.shared.unsubscribe(token) }

        let applied = try router.reconcileBotBrowserOpens()
        XCTAssertEqual(applied.map(\.url), ["https://login.example.test/in"])
        XCTAssertTrue(try store.loadPendingOpens().isEmpty)
        XCTAssertTrue(urls.contains("https://login.example.test/in"))
    }

    @MainActor
    func test_persistBotBrowserCookiesUsesHTTPCookieSnapshot() throws {
        let appSupport = NSTemporaryDirectory() + "RC2BotBrowserCookies-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let workspace = try router.createWorkspace(name: "desk", cwd: NSTemporaryDirectory())
        let bot = try ctx.botStore.create(
            name: "Piper", title: "", description: "", provider: .claude, workspaceID: workspace.id
        )
        let opened = try router.openBotBrowser(botID: bot.id, url: "https://login.example.test/in", title: "Sign in")
        let surfaceID = try XCTUnwrap(
            ctx.state.workspaces[workspace.id].flatMap { ws -> SurfaceID? in
                var found: SurfaceID?
                func walk(_ node: LayoutNode) {
                    switch node {
                    case .pane(let pane):
                        if let match = pane.surfaces.first(where: { $0.metadata["bot_id"] == bot.id.value.uuidString.lowercased() }) {
                            found = match.id
                        }
                    case .split(let split):
                        split.children.forEach(walk)
                    }
                }
                walk(ws.layout)
                return found
            }
        )
        let cookie = HTTPCookie(properties: [
            .name: "session",
            .value: "live",
            .domain: "login.example.test",
            .path: "/",
        ])!
        router.persistBotBrowserCookies(
            surfaceID: surfaceID,
            cookies: [cookie],
            url: opened.url,
            title: "Home"
        )
        let store = BotBrowserStore(appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true))
        let page = try XCTUnwrap(store.loadPageState(botID: bot.id))
        XCTAssertEqual(page.cookies["session"], "live")
        XCTAssertTrue(try BotBrowserService(callerBotID: bot.id, store: store).waitLogin().isComplete)
    }
}
