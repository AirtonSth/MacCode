import XCTest
import CoreModel
@testable import Persistence

final class BotDesktopVMStoreTests: XCTestCase {
    func test_ensurePersistsStableIdentity_becauseABotMustKeepTheSameGuestBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bot-desktops-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotDesktopVMStore(root: root)
        let botID = BotID()

        let first = try store.ensure(botID: botID)
        let second = try store.ensure(botID: botID)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.generation, 1)
        XCTAssertEqual(first.state, .stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.bundlePath))
        XCTAssertEqual(try store.identity(botID: botID)?.id, first.id)
    }
}
