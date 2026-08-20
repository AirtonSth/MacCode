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
        try BotGuestHome.wipe(appSupport: support, botID: botID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        try? FileManager.default.removeItem(at: support)
    }
}
