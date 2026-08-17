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
        let tools = BotStandingInstructions.admittedToolsText
        XCTAssertTrue(tools.contains(BotBrowserCatalog.open))
        XCTAssertTrue(tools.contains(BotBrowserCatalog.get))
        XCTAssertTrue(tools.contains(BotBrowserCatalog.waitLogin))
        XCTAssertTrue(tools.contains("teammate's"))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains(BotBrowserCatalog.open),
            "tools layer owns browser names"
        )
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

    func test_openAdvertisedWebsitePersists_becauseToolsSayWebsiteNotUrl() throws {
        // WHY: Tools invite "open a website". Parse only read url, so
        // first-chat "open this website" invented a hop or left the leftover
        // tab. Canonical url still wins. Schema does not grow a second key.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-browser-website-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = BotID()
        let service = BotBrowserService(
            callerBotID: bot,
            store: BotBrowserStore(appSupportDirectory: root)
        )

        let fromWebsite = try service.call(name: BotBrowserCatalog.open, arguments: [
            "website": "https://login.example.test/in",
        ])
        XCTAssertEqual(fromWebsite["url"] as? String, "https://login.example.test/in", "Website persists")
        XCTAssertEqual(try service.current()?.url, "https://login.example.test/in")

        let urlWins = try service.call(name: BotBrowserCatalog.open, arguments: [
            "url": "https://login.example.test/home",
            "website": "https://ignored.example.test",
        ])
        XCTAssertEqual(urlWins["url"] as? String, "https://login.example.test/home", "url wins")
        XCTAssertEqual(try service.current()?.url, "https://login.example.test/home")
    }

    func test_openCatalogDescribesWebsite_becauseThatIsTheAdvertisedField() {
        // WHY: Schema key stays url. Description must name Website so
        // first-chat does not invent a hop.
        let description = BotBrowserCatalog.description(for: BotBrowserCatalog.open)
        XCTAssertTrue(description.contains("website"))
        let schema = BotBrowserCatalog.schema(for: BotBrowserCatalog.open)
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["url"])
        XCTAssertNil(properties?["website"], "website is an advertised alias, not a second schema key")
        XCTAssertNil(properties?["last_website"], "last_website is an advertised alias, not a second schema key")
        let url = properties?["url"] as? [String: Any]
        XCTAssertEqual(url?["description"] as? String, "Website / last website. Same field as the URL to open.")
    }

    func test_openAdvertisedLastWebsitePersists_becauseHonestySaysLastWebsite() throws {
        // WHY: set_settings leftover last_website already rejects and
        // points at bot_browser_open ("Same path as last website"). Open
        // only read url / website, so first-chat retried last_website and
        // invented a hop. Canonical url still wins. Schema does not grow
        // a last_website key. Dest title stays Browser.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-browser-last-website-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = BotID()
        let service = BotBrowserService(
            callerBotID: bot,
            store: BotBrowserStore(appSupportDirectory: root)
        )

        let fromLastWebsite = try service.call(name: BotBrowserCatalog.open, arguments: [
            "last_website": "https://login.example.test/in",
        ])
        XCTAssertEqual(fromLastWebsite["url"] as? String, "https://login.example.test/in", "last website persists")
        XCTAssertEqual(try service.current()?.url, "https://login.example.test/in")

        let urlWins = try service.call(name: BotBrowserCatalog.open, arguments: [
            "url": "https://login.example.test/home",
            "last_website": "https://ignored.example.test",
        ])
        XCTAssertEqual(urlWins["url"] as? String, "https://login.example.test/home", "url wins")
        XCTAssertEqual(try service.current()?.url, "https://login.example.test/home")

        let websiteStillWorks = try service.call(name: BotBrowserCatalog.open, arguments: [
            "website": "https://login.example.test/again",
        ])
        XCTAssertEqual(websiteStillWorks["url"] as? String, "https://login.example.test/again", "website still persists")
    }
}
