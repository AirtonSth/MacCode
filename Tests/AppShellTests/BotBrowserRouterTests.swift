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
}
