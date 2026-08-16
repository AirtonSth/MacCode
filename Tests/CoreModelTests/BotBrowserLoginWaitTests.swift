import XCTest
@testable import CoreModel

final class BotBrowserLoginWaitTests: XCTestCase {
    func test_waitDoesNotCompleteUntilLoggedIn_twice() {
        // WHY: the bot must tell the user to log in and only continue after the fixture is signed in.
        let url = "https://login.example.test/in"
        for run in 1...2 {
            let loggedOut = BotBrowserPageState(url: url, title: "Sign in", cookies: [:])
            let loggedIn = BotBrowserPageState(url: "https://login.example.test/home", title: "Home", cookies: ["session": "ok"])
            let steps = BotBrowserLoginWait.wait(url: url, pages: [loggedOut, loggedOut, loggedIn])
            XCTAssertEqual(steps.count, 3, "run \(run)")
            XCTAssertFalse(steps[0].isComplete, "run \(run) still logged out")
            XCTAssertFalse(steps[1].isComplete, "run \(run) still logged out")
            XCTAssertEqual(steps[0].userMessage, BotBrowserLoginWait.userPrompt(url: url))
            XCTAssertTrue(steps[2].isComplete, "run \(run) logged in")
            XCTAssertNil(steps[2].userMessage)
            XCTAssertEqual(steps[2].url, loggedIn.url)
        }
    }

    func test_pollUntilLoggedInDoesNotCompleteUntilFixtureLogsIn() throws {
        let url = "https://login.example.test/in"
        let loggedOut = BotBrowserPageState(url: url, cookies: [:])
        let loggedIn = BotBrowserPageState(url: url, cookies: ["session": "1"])
        for run in 1...2 {
            let pages = [loggedOut, loggedOut, loggedIn]
            var index = 0
            let result = try BotBrowserLoginWait.pollUntilLoggedIn(
                url: url,
                timeoutMS: BotBrowserLoginWait.defaultTimeoutMS,
                pollIntervalMS: 1,
                loadPage: {
                    let page = pages[min(index, pages.count - 1)]
                    index += 1
                    return page
                },
                sleep: { _ in },
                now: { Date(timeIntervalSince1970: 0) }
            )
            XCTAssertTrue(result.isComplete, "run \(run)")
            XCTAssertGreaterThan(index, 2, "run \(run) must poll through logged-out samples")
            XCTAssertEqual(BotBrowserLoginWait.defaultTimeoutMS, 1_800_000)
        }
    }

    func test_fromHTTPCookiesDrivesLoginPredicate() {
        let loggedOut = BotBrowserPageState.fromHTTPCookies([], url: "https://example.test", title: "")
        XCTAssertFalse(BotBrowserLoginPredicate.standard.isLoggedIn(loggedOut))
        let cookie = HTTPCookie(properties: [
            .name: "session",
            .value: "ok",
            .domain: "example.test",
            .path: "/",
        ])!
        let loggedIn = BotBrowserPageState.fromHTTPCookies([cookie], url: "https://example.test", title: "Home")
        XCTAssertTrue(BotBrowserLoginPredicate.standard.isLoggedIn(loggedIn))
        XCTAssertEqual(loggedIn.cookies["session"], "ok")
    }

    func test_standardPredicateCompletesOnLiAtCookieNotSessionSidOrAuth() throws {
        // WHY: a real LinkedIn sign-in sets li_at, not session/sid/auth.
        let loginURL = "https://www.linkedin.com/login"
        let cookie = HTTPCookie(properties: [
            .name: "li_at",
            .value: "AQED",
            .domain: ".linkedin.com",
            .path: "/",
        ])!
        XCTAssertFalse(["session", "sid", "auth"].contains(cookie.name.lowercased()))
        let loggedOut = BotBrowserPageState(url: loginURL, title: "Sign in", cookies: [:])
        let loggedIn = BotBrowserPageState.fromHTTPCookies(
            [cookie],
            url: "https://www.linkedin.com/feed/",
            title: "Feed"
        )
        XCTAssertFalse(BotBrowserLoginPredicate.standard.isLoggedIn(loggedOut, openedURL: loginURL))
        XCTAssertTrue(BotBrowserLoginPredicate.standard.hasAuthCookie(loggedIn))
        let steps = BotBrowserLoginWait.wait(url: loginURL, pages: [loggedOut, loggedIn])
        XCTAssertFalse(steps[0].isComplete)
        XCTAssertEqual(steps[0].userMessage, BotBrowserLoginWait.userPrompt(url: loginURL))
        XCTAssertTrue(steps[1].isComplete)
        XCTAssertNil(steps[1].userMessage)

        var index = 0
        let pages = [loggedOut, loggedIn]
        let polled = try BotBrowserLoginWait.pollUntilLoggedIn(
            url: loginURL,
            timeoutMS: BotBrowserLoginWait.defaultTimeoutMS,
            pollIntervalMS: 1,
            loadPage: {
                let page = pages[min(index, pages.count - 1)]
                index += 1
                return page
            },
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 0) }
        )
        XCTAssertTrue(polled.isComplete)
        XCTAssertEqual(polled.url, loggedIn.url)
    }

    func test_standardPredicateCompletesWhenURLLeavesLoginPath() {
        let opened = "https://www.linkedin.com/login"
        let stillLogin = BotBrowserPageState(url: opened, cookies: [:])
        let feed = BotBrowserPageState(url: "https://www.linkedin.com/feed/", cookies: [:])
        XCTAssertFalse(BotBrowserLoginPredicate.standard.isLoggedIn(stillLogin, openedURL: opened))
        XCTAssertTrue(BotBrowserLoginPredicate.standard.leftLoginPage(openedURL: opened, currentURL: feed.url))
        let result = BotBrowserLoginWait.evaluate(url: opened, page: feed)
        XCTAssertTrue(result.isComplete)
    }
}
