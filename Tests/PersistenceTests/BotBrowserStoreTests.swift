import XCTest
import CoreModel
@testable import Persistence

/// Answers host pending actions from a background thread the way the app's
/// reconcile loop does, so `call(open)`/`call(waitLogin)` host round-trips
/// complete without the app (and without any Playwright child) in tests.
private final class BotBrowserHostResponder: @unchecked Sendable {
    private let store: BotBrowserStore
    private let lock = NSLock()
    private var stopped = false
    private var seen: [BotBrowserPendingAction] = []
    private let respond: @Sendable (BotBrowserPendingAction) -> BotBrowserActionResult

    /// Default responder echoes the pending url/title, mirroring a healthy
    /// Playwright navigate.
    static func echo(_ item: BotBrowserPendingAction) -> BotBrowserActionResult {
        let payload: [String: Any] = ["url": item.url, "title": item.title, "content": "### Page"]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return BotBrowserActionResult(
            id: item.id,
            botID: item.botID,
            payload: String(data: data, encoding: .utf8) ?? "{}",
            error: ""
        )
    }

    init(
        store: BotBrowserStore,
        respond: @escaping @Sendable (BotBrowserPendingAction) -> BotBrowserActionResult = BotBrowserHostResponder.echo
    ) {
        self.store = store
        self.respond = respond
        Thread.detachNewThread { [weak self] in
            while let self, !self.isStopped {
                for item in (try? self.store.takePendingActions()) ?? [] {
                    self.record(item)
                    try? self.store.writeActionResult(self.respond(item))
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func record(_ item: BotBrowserPendingAction) {
        lock.lock()
        seen.append(item)
        lock.unlock()
    }

    func seenActions() -> [BotBrowserPendingAction] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

final class BotBrowserStoreTests: XCTestCase {
    func test_standingStarterNamesLiveBrowserTools_becauseDeskAlreadyAdmitsThem() {
        // WHY: Generated soul must name the same tools the bot-browser MCP
        // exposes — for the kinds that ADMIT the bot browser (botOwnedBrowser
        // and dockerDesktop). A drift here means first-chat "open this URL"
        // calls a name the server does not have. Logical-space bots browse
        // with the owner's Google Chrome and must never be taught bot_browser_*.
        XCTAssertEqual(BotStandingInstructions.openBrowserTool, BotBrowserCatalog.open)
        XCTAssertEqual(BotStandingInstructions.getBrowserTool, BotBrowserCatalog.get)
        XCTAssertEqual(BotStandingInstructions.waitLoginTool, BotBrowserCatalog.waitLogin)
        XCTAssertEqual(BotStandingInstructions.snapshotBrowserTool, BotBrowserCatalog.snapshot)
        XCTAssertEqual(BotStandingInstructions.actBrowserTool, BotBrowserCatalog.act)
        XCTAssertEqual(BotStandingInstructions.webSearchTool, "bot_web_search")
        XCTAssertEqual(BotStandingInstructions.webFetchTool, "bot_web_fetch")
        for kind in [BotDesktopKind.botOwnedBrowser, .dockerDesktop] {
            let tools = BotStandingInstructions.admittedToolsText(for: kind)
            XCTAssertTrue(tools.contains(BotBrowserCatalog.open), "\(kind) admits the bot browser")
            XCTAssertTrue(tools.contains(BotBrowserCatalog.get))
            XCTAssertTrue(tools.contains(BotBrowserCatalog.waitLogin))
            XCTAssertTrue(tools.contains(BotBrowserCatalog.snapshot))
            XCTAssertTrue(tools.contains(BotBrowserCatalog.act))
            XCTAssertFalse(tools.contains("bot_browser_evaluate"))
        }
        XCTAssertTrue(
            BotStandingInstructions.admittedToolsText(for: .botOwnedBrowser).contains("teammate's"),
            "the browser line still says whose browser it is"
        )
        let logical = BotStandingInstructions.admittedToolsText
        XCTAssertFalse(logical.contains(BotBrowserCatalog.open), "owner's-Chrome bots are not taught bot_browser_*")
        XCTAssertTrue(logical.contains("Google Chrome"))
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

    func test_snapshotMailboxRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-bot-browser-act-\(UUID().uuidString)", isDirectory: true)
        let store = BotBrowserStore(appSupportDirectory: root)
        let bot = BotID()
        let pending = BotBrowserPendingAction(
            id: "act-1",
            botID: bot.value.uuidString.lowercased(),
            kind: BotBrowserCatalog.snapshot,
            action: "",
            ref: "",
            text: ""
        )
        try store.enqueueAction(pending)
        try BotBrowserHost.applyPendingActions(store: store) { _, _ in
            "{\"url\":\"https://example.com\",\"elements\":[]}"
        }
        let result = try XCTUnwrap(try store.takeActionResult(id: "act-1"))
        XCTAssertTrue(result.payload.contains("example.com"))
        XCTAssertEqual(result.error, "")
    }

    func test_requestOpenEnqueuesPendingAndApplyCallsOpener() throws {
        // WHY: the legacy enqueue lane must keep working — older queued opens
        // still drain through the app's openBotBrowser (now Playwright-routed).
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
        let store = BotBrowserStore(appSupportDirectory: root)
        let service = BotBrowserService(callerBotID: bot, store: store)
        // open now round-trips through the host; echo it like the app would.
        let responder = BotBrowserHostResponder(store: store)
        defer { responder.stop() }

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
        let store = BotBrowserStore(appSupportDirectory: root)
        let service = BotBrowserService(callerBotID: bot, store: store)
        // open now round-trips through the host; echo it like the app would.
        let responder = BotBrowserHostResponder(store: store)
        defer { responder.stop() }

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

    func test_pendingActionDecodesLegacyJSONWithoutURLTitle() throws {
        // WHY: pending-actions.json queued by an older build has no url/title;
        // it must still drain after an update instead of failing decode and
        // wedging the whole mailbox.
        let legacy = """
        [{"id":"a1","botID":"b","kind":"bot_browser_snapshot","action":"","ref":"","text":""}]
        """
        let decoded = try JSONDecoder().decode([BotBrowserPendingAction].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.first?.id, "a1")
        XCTAssertEqual(decoded.first?.url, "")
        XCTAssertEqual(decoded.first?.title, "")

        // New fields round-trip for the open lane.
        let action = BotBrowserPendingAction(
            id: "a2",
            botID: "b",
            kind: BotBrowserCatalog.open,
            action: "",
            ref: "",
            text: "",
            url: "https://a.test",
            title: "A"
        )
        let data = try JSONEncoder().encode(action)
        XCTAssertEqual(try JSONDecoder().decode(BotBrowserPendingAction.self, from: data), action)
    }

    func test_stateKindIsAHostActionNotATool() {
        // WHY: waitLogin polls live page state through the host with this
        // kind; advertising it as a bot tool would invite direct calls the
        // schema layer never defined. The bridge translator (CoreModel)
        // matches these literals — drift breaks the whole lane.
        XCTAssertEqual(BotBrowserCatalog.stateKind, "state")
        XCTAssertEqual(BotBrowserCatalog.toolNames.count, 5)
        XCTAssertFalse(BotBrowserCatalog.toolNames.contains(BotBrowserCatalog.stateKind))
    }

    func test_callOpenDrivesHostActionAndReturnsHostPayload() throws {
        // WHY: open used to fire-and-forget into an in-app tab; the bot now
        // must see the Playwright navigate's real result synchronously, and
        // the queued action must carry the url the executor needs.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-browser-open-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = BotID()
        let store = BotBrowserStore(appSupportDirectory: root)
        let service = BotBrowserService(callerBotID: bot, store: store)
        let responder = BotBrowserHostResponder(store: store) { item in
            let payload = "{\"url\":\"\(item.url)\",\"title\":\"Playwright \(item.title)\",\"content\":\"### Page\"}"
            return BotBrowserActionResult(id: item.id, botID: item.botID, payload: payload, error: "")
        }
        defer { responder.stop() }

        let result = try service.call(name: BotBrowserCatalog.open, arguments: [
            "url": "https://login.example.test/in",
            "title": "Sign in",
        ])
        XCTAssertEqual(result["url"] as? String, "https://login.example.test/in")
        XCTAssertEqual(result["title"] as? String, "Playwright Sign in", "payload comes from the host, not the echo")

        let seen = responder.seenActions()
        XCTAssertEqual(seen.map(\.kind), [BotBrowserCatalog.open])
        XCTAssertEqual(seen.first?.url, "https://login.example.test/in")
        XCTAssertEqual(seen.first?.title, "Sign in")
        XCTAssertTrue(try store.loadPendingOpens().isEmpty, "call(open) must not double-enqueue the legacy lane")
        XCTAssertEqual(try service.current()?.url, "https://login.example.test/in", "target persists before the round-trip")
    }

    func test_callOpenPropagatesHostErrorVerbatim() throws {
        // WHY: a refused route (logical bot) or missing Node.js is reported
        // by the app through the error channel; the bot must read that exact
        // text instead of a generic timeout.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-browser-open-err-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = BotID()
        let store = BotBrowserStore(appSupportDirectory: root)
        let service = BotBrowserService(callerBotID: bot, store: store)
        let responder = BotBrowserHostResponder(store: store) { item in
            BotBrowserActionResult(id: item.id, botID: item.botID, payload: "", error: BotBrowserRoute.refusedMessage)
        }
        defer { responder.stop() }

        XCTAssertThrowsError(
            try service.call(name: BotBrowserCatalog.open, arguments: ["url": "https://login.example.test/in"])
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("Google Chrome"),
                "host error must surface verbatim, got \(error)"
            )
        }
    }

    func test_waitLoginPollsLiveHostStateAndCompletesOnURLChange() throws {
        // WHY: Playwright lanes feed no cookies, so the login wait must see
        // the LIVE page URL through the host (the user logs in inside the
        // Playwright Chrome, never touching the store) and complete when the
        // browser left the login page.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-browser-wait-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = BotID()
        let store = BotBrowserStore(appSupportDirectory: root)
        let service = BotBrowserService(callerBotID: bot, store: store)
        _ = try service.persistNavigation(url: "https://example.test/login", title: "Sign in")
        let responder = BotBrowserHostResponder(store: store) { item in
            XCTAssertEqual(item.kind, BotBrowserCatalog.stateKind, "waitLogin must poll the state kind")
            return BotBrowserActionResult(
                id: item.id,
                botID: item.botID,
                payload: "{\"url\":\"https://example.test/home\",\"title\":\"Home\",\"content\":\"### Page\"}",
                error: ""
            )
        }
        defer { responder.stop() }

        let result = try service.call(name: BotBrowserCatalog.waitLogin, arguments: ["timeout_ms": 8_000.0])
        XCTAssertEqual(result["complete"] as? Bool, true)
        XCTAssertEqual(result["url"] as? String, "https://example.test/home")
        XCTAssertEqual(result["user_message"] as? String, "")
        XCTAssertFalse(responder.seenActions().isEmpty)
    }

    func test_waitLoginFallsBackToStoredStateWhenHostIsGone() throws {
        // WHY: with the app closed the state poll times out; the wait must
        // then read the persisted page state (legacy tabs persist cookies
        // there) instead of throwing away a completed login.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-bot-browser-wait-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = BotID()
        let store = BotBrowserStore(appSupportDirectory: root)
        let service = BotBrowserService(callerBotID: bot, store: store)
        _ = try service.persistNavigation(url: "https://example.test/login", title: "Sign in")
        try store.persistPageState(
            BotBrowserPageState(url: "https://example.test/home", cookies: ["session": "1"]),
            botID: bot
        )
        let responder = BotBrowserHostResponder(store: store) { item in
            // Simulate a host that answers but cannot serve the state poll.
            BotBrowserActionResult(id: item.id, botID: item.botID, payload: "", error: "Bot browser is not available. Keep the RemoteCode app running and try again.")
        }
        defer { responder.stop() }

        let result = try service.call(name: BotBrowserCatalog.waitLogin, arguments: ["timeout_ms": 8_000.0])
        XCTAssertEqual(result["complete"] as? Bool, true, "stored logged-in state completes the wait")
    }
}
