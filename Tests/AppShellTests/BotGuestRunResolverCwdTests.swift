import XCTest
import CoreModel
@testable import AppShell

/// A Bot conversation's cwd is its Bot home, which is never a VM mount, so it
/// must map to the guest home whatever the Application Support channel is.
final class BotGuestRunResolverCwdTests: XCTestCase {
    private let appSupport = URL(fileURLWithPath: "/Users/u/Library/Application Support/RemoteCodeDebug")
    private let uuid = "20fb04f1-0000-4000-8000-000000000001"

    func test_isBotHome_matchesOwnBotsRoot() {
        let home = appSupport.path + "/bots/\(uuid)/e1"
        XCTAssertTrue(BotGuestRunResolver.isBotHome(home, appSupport: appSupport))
        XCTAssertTrue(BotGuestRunResolver.isBotHome(home + "/", appSupport: appSupport))
        XCTAssertTrue(BotGuestRunResolver.isBotHome(home + "/files", appSupport: appSupport))
    }

    func test_isBotHome_matchesOtherChannelRoot() {
        // The thread was created under RemoteCode, but the app runs as RemoteCodeDebug.
        let stable = "/Users/u/Library/Application Support/RemoteCode/bots/\(uuid)/e1"
        XCTAssertTrue(BotGuestRunResolver.isBotHome(stable, appSupport: appSupport))
    }

    func test_isBotHome_rejectsNonBotPaths() {
        let rejected = [
            "/Users/u/dev/repo",
            "/Users/u/Library/Application Support/RemoteCode/bots/not-a-uuid/e1",
            "/Users/u/Library/Application Support/RemoteCode/bots/\(uuid)/files",
            "/Users/u/Library/Application Support/Other/bots/\(uuid)/e1",
            "/Users/u/Library/Application Support/RemoteCode/bots/\(uuid)",
        ]
        for path in rejected {
            XCTAssertFalse(BotGuestRunResolver.isBotHome(path, appSupport: appSupport), path)
        }
    }

    func test_botHomeCwd_mapsToGuestHome_notMountError() throws {
        let home = appSupport.path + "/bots/\(uuid)/e1"
        let workspace = BotGuestRunResolver.isBotHome(home, appSupport: appSupport) ? nil : "/Users/u/repo"
        XCTAssertEqual(
            try BotGuestRunResolver.guestCwd(requestCwd: home, workspace: workspace, mounted: []),
            BotComputerGuestSpec.guestUserHome
        )
    }

    /// A resumed Distill session is only found again under the cwd it was stored
    /// with, so the stored cwd wins when the guest can still reach it.
    func test_resumeGuestCwd_keepsStoredCwdOnlyWhenReachable() {
        let computed = "/Users/u/repo"
        let mount = "/Users/u/repo"
        XCTAssertEqual(BotGuestRunResolver.resumeGuestCwd(computed: computed, stored: nil, mounted: [mount]), computed)
        XCTAssertEqual(
            BotGuestRunResolver.resumeGuestCwd(computed: computed, stored: BotComputerGuestSpec.guestUserHome, mounted: [mount]),
            BotComputerGuestSpec.guestUserHome
        )
        XCTAssertEqual(
            BotGuestRunResolver.resumeGuestCwd(computed: computed, stored: "/Users/u/other", mounted: [mount]),
            computed
        )
        XCTAssertEqual(
            BotGuestRunResolver.resumeGuestCwd(computed: computed, stored: mount + "/src", mounted: [mount]),
            mount + "/src"
        )
    }
}
