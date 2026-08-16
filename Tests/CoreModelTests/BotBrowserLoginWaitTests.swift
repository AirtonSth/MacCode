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

    func test_sufficientCookieNamesAreDisjointFromNeverSufficient() {
        XCTAssertTrue(
            BotBrowserLoginPredicate.cookieNameSetsAreDisjoint,
            "jsessionid and other pre-login cookies must never sit in the sufficient set"
        )
        XCTAssertFalse(BotBrowserLoginPredicate.sufficientCookieNames.contains("jsessionid"))
        XCTAssertTrue(BotBrowserLoginPredicate.neverSufficientCookieNames.contains("jsessionid"))
        XCTAssertEqual(
            BotBrowserLoginPredicate.standard.cookieNames,
            BotBrowserLoginPredicate.sufficientCookieNames
        )
    }

    func test_waitAndPollTable_jsessionidOnLoginStaysIncomplete() throws {
        // WHY: LinkedIn sets JSESSIONID on /login before sign-in. That must not complete wait.
        let login = "https://www.linkedin.com/login"
        let feed = "https://www.linkedin.com/feed/"
        struct Row {
            var name: String
            var opened: String
            var pageURL: String
            var cookies: [HTTPCookie]
            var expectComplete: Bool
        }
        let rows: [Row] = [
            Row(
                name: "JSESSIONID on /login without li_at",
                opened: login,
                pageURL: login,
                cookies: [httpCookie(name: "JSESSIONID", value: "ajax:1")],
                expectComplete: false
            ),
            Row(
                name: "empty cookies on /login",
                opened: login,
                pageURL: login,
                cookies: [],
                expectComplete: false
            ),
            Row(
                name: "li_at",
                opened: login,
                pageURL: login,
                cookies: [httpCookie(name: "li_at", value: "AQED")],
                expectComplete: true
            ),
            Row(
                name: "/login to /feed no cookies",
                opened: login,
                pageURL: feed,
                cookies: [],
                expectComplete: true
            ),
            Row(
                name: "session",
                opened: login,
                pageURL: login,
                cookies: [httpCookie(name: "session", value: "ok")],
                expectComplete: true
            ),
        ]
        for row in rows {
            let page = BotBrowserPageState.fromHTTPCookies(row.cookies, url: row.pageURL, title: "")
            let waited = try XCTUnwrap(BotBrowserLoginWait.wait(url: row.opened, pages: [page]).first)
            XCTAssertEqual(waited.isComplete, row.expectComplete, row.name)
            if row.expectComplete {
                XCTAssertNil(waited.userMessage, row.name)
            } else {
                XCTAssertEqual(waited.userMessage, BotBrowserLoginWait.userPrompt(url: row.opened), row.name)
            }

            let polled = try BotBrowserLoginWait.pollUntilLoggedIn(
                url: row.opened,
                timeoutMS: row.expectComplete ? BotBrowserLoginWait.defaultTimeoutMS : 0,
                pollIntervalMS: 1,
                loadPage: { page },
                sleep: { _ in },
                now: { Date(timeIntervalSince1970: 0) }
            )
            XCTAssertEqual(polled.isComplete, row.expectComplete, "poll \(row.name)")
            if !row.expectComplete {
                XCTAssertEqual(polled.userMessage, BotBrowserLoginWait.userPrompt(url: row.opened), "poll \(row.name)")
            }
        }
    }

    private func httpCookie(name: String, value: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: "www.linkedin.com",
            .path: "/",
        ])!
    }
}
