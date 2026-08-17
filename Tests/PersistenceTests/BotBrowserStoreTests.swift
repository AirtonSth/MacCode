import XCTest
import CoreModel
@testable import Persistence

final class BotBrowserStoreTests: XCTestCase {
    func test_standingStarterNamesLiveBrowserTools_becauseDeskAlreadyAdmitsThem() {
        // WHY: Generated soul must name the same tools the bot-browser MCP
        // exposes. A drift here means first-chat "open this URL" calls a
        // name the server does not have.
        XCTAssertEqual(BotStandingInstructions.openBrowserTool, BotBrowserCatalog.open)
        XCTAssertEqual(BotStandingInstructions.getBrowserTool, BotBrowserCatalog.get)
        XCTAssertEqual(BotStandingInstructions.waitLoginTool, BotBrowserCatalog.waitLogin)
        let starter = BotStandingInstructions.fallback(name: "Piper", title: "Scout")
        XCTAssertTrue(starter.contains(BotBrowserCatalog.open))
        XCTAssertTrue(starter.contains(BotBrowserCatalog.get))
        XCTAssertTrue(starter.contains(BotBrowserCatalog.waitLogin))
        XCTAssertTrue(starter.contains("teammate's"))
    }

    func test_websiteDataPersistsPerBotAndDoesNotLeak() throws {
        // WHY: two bots must keep isolated cookies/local storage across reopen.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-browser-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = BotID()
        let beta = BotID()
        let first = BotBrowserStore(appSupportDirectory: root)
        try first.writeMarker("alpha-session", botID: alpha)
        try first.writeMarker("beta-session", botID: beta)

        let reopened = BotBrowserStore(appSupportDirectory: root)
        XCTAssertEqual(try reopened.readMarker(botID: alpha), "alpha-session")
        XCTAssertEqual(try reopened.readMarker(botID: beta), "beta-session")
        XCTAssertNotEqual(try reopened.readMarker(botID: alpha), try reopened.readMarker(botID: beta))
        XCTAssertNil(try reopened.readWebsiteData(botID: alpha)["beta-session"])
        XCTAssertFalse(try reopened.readWebsiteData(botID: beta).values.contains("alpha-session"))

        let dirAlpha = reopened.directory(for: alpha)
        let dirBeta = reopened.directory(for: beta)
        XCTAssertEqual(dirAlpha.lastPathComponent, BotBrowserIdentity.persistDirectoryName(for: alpha))
        XCTAssertNotEqual(dirAlpha, dirBeta)
        XCTAssertNotEqual(
            BotBrowserIdentity.dataStoreIdentifier(for: alpha),
            BotBrowserIdentity.dataStoreIdentifier(for: beta)
        )
        let sharedRaw = UUID()
        XCTAssertNotEqual(
            BotBrowserIdentity.dataStoreIdentifier(for: BotID(sharedRaw)),
            sharedRaw,
            "bot store id must not be the workspace-style raw UUID"
        )
    }

    func test_openPersistsTargetAcrossReopen() throws {
        // WHY: last URL/title must survive process restart via the shipped store.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-browser-nav-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = BotID()
        let store = BotBrowserStore(appSupportDirectory: root)
        let service = BotBrowserService(callerBotID: bot, store: store)
        let opened = try service.open(url: "https://login.example.test/in", title: "Sign in")
        XCTAssertEqual(opened.url, "https://login.example.test/in")
        XCTAssertEqual(opened.title, "Sign in")

        let again = BotBrowserStore(appSupportDirectory: root)
        let restored = try XCTUnwrap(again.loadTarget(botID: bot))
        XCTAssertEqual(restored.url, opened.url)
        XCTAssertEqual(restored.title, opened.title)
        XCTAssertEqual(try BotBrowserService(callerBotID: bot, store: again).current()?.url, opened.url)
    }

    func test_requestOpenEnqueuesPendingAndApplyCallsOpener() throws {
        // WHY: MCP cannot touch WKWebView; it must enqueue so the app calls openBotBrowser.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-browser-pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = BotID()
        let store = BotBrowserStore(appSupportDirectory: root)
        var notifyCount = 0
        let target = try BotBrowserHost.requestOpen(
            store: store,
            botID: bot,
            url: "https://login.example.test/in",
            title: "Sign in",
            notify: { _ in notifyCount += 1 }
        )
        XCTAssertEqual(notifyCount, 1)
        XCTAssertEqual(try store.loadPendingOpens().map(\.url), [target.url])

        var opened: [(String, String)] = []
        let applied = try BotBrowserHost.applyPendingOpens(store: store) { botID, url, title in
            XCTAssertEqual(botID, bot)
            opened.append((url, title ?? ""))
            return BotBrowserTarget(url: url, title: title ?? "")
        }
        XCTAssertEqual(applied.map(\.url), [target.url])
        XCTAssertEqual(opened.first?.0, target.url)
        XCTAssertEqual(opened.first?.1, "Sign in")
        XCTAssertTrue(try store.loadPendingOpens().isEmpty)
    }

    func test_waitLoginUsesStoredPageState() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-browser-wait-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = BotID()
        let store = BotBrowserStore(appSupportDirectory: root)
        let service = BotBrowserService(callerBotID: bot, store: store)
        _ = try service.open(url: "https://login.example.test/in", title: "Sign in")
        try store.persistPageState(
            BotBrowserPageState(url: "https://login.example.test/in", cookies: [:]),
            botID: bot
        )
        let pending = try service.waitLogin()
        XCTAssertFalse(pending.isComplete)
        XCTAssertEqual(pending.userMessage, BotBrowserLoginWait.userPrompt(url: "https://login.example.test/in"))
        try store.persistPageState(
            BotBrowserPageState(url: "https://login.example.test/home", cookies: ["session": "1"]),
            botID: bot
        )
        let done = try service.waitLogin()
        XCTAssertTrue(done.isComplete)
        XCTAssertNil(done.userMessage)
    }

    func test_callRejectsAnotherBotId() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-browser-x-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let caller = BotID()
        let other = BotID()
        let service = BotBrowserService(callerBotID: caller, store: BotBrowserStore(appSupportDirectory: root))
        XCTAssertThrowsError(
            try service.call(name: BotBrowserCatalog.open, arguments: [
                "bot_id": other.value.uuidString,
                "url": "https://example.test",
            ])
        ) { error in
            XCTAssertEqual(error as? BotBrowserError, .crossBot)
        }
    }
}
