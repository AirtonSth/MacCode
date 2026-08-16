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
}
