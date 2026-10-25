import XCTest
@testable import AppShell

final class BotChatPresentationPreferencesTests: XCTestCase {
    func test_firstCleanChatMigrationClosesLegacyPanesAndPreservesDraftsAndWidths() throws {
        let name = "BotChatPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "bots.deskSidePane")
        defaults.set(true, forKey: "bots.deskThreadRail")
        defaults.set(true, forKey: "bots.groupInspector")
        defaults.set(360, forKey: "bots.deskThreadRailWidth")
        defaults.set("unfinished message", forKey: "bots.composerDrafts")
        BotChatPresentationPreferences.migrateIfNeeded(in: defaults)
        XCTAssertFalse(defaults.bool(forKey: "bots.deskSidePane"))
        XCTAssertFalse(defaults.bool(forKey: "bots.deskThreadRail"))
        XCTAssertFalse(defaults.bool(forKey: "bots.groupInspector"))
        XCTAssertEqual(defaults.integer(forKey: "bots.deskThreadRailWidth"), 360)
        XCTAssertEqual(defaults.string(forKey: "bots.composerDrafts"), "unfinished message")
        // Later explicit choices survive reopening, rather than being reset each launch.
        defaults.set(true, forKey: "bots.deskSidePane")
        BotChatPresentationPreferences.migrateIfNeeded(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "bots.deskSidePane"))
        XCTAssertFalse(defaults.bool(forKey: "bots.deskThreadRail"))
    }

    func test_newProfileStartsWithBothOptionalPanesClosed() throws {
        let name = "BotChatPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        BotChatPresentationPreferences.migrateIfNeeded(in: defaults)
        XCTAssertFalse(defaults.bool(forKey: "bots.deskSidePane"))
        XCTAssertFalse(defaults.bool(forKey: "bots.deskThreadRail"))
    }
}
