import XCTest
import CoreModel
@testable import Persistence

final class BotGuestHomeTests: XCTestCase {
    func test_ensureCreatesMode700HomeOutsideBotHome() throws {
        // WHY: Hide increments BotHome epoch. Guest Chromium profile must
        // survive hide and stay out of SOUL.md.
        let support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-guest-home-\(UUID().uuidString)", isDirectory: true)
        let botID = BotID()
        let home = try BotGuestHome.ensure(appSupport: support, botID: botID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path))
        XCTAssertTrue(home.path.contains("bot-guests"))
        XCTAssertFalse(home.path.contains("/bots/"))
        let mode = try FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        let viewerToken = BotComputerGuestSpec.viewerTokenURL(appSupport: support, botID: botID)
        try Data("test-token".utf8).write(to: viewerToken)
        XCTAssertFalse(
            viewerToken.path.hasPrefix(home.path + "/"),
            "the Bot-writable bind must not own its viewer bearer"
        )
        try BotGuestHome.wipe(appSupport: support, botID: botID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewerToken.path))
        try? FileManager.default.removeItem(at: support)
    }
}
