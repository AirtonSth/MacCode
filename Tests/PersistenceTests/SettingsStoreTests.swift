import XCTest
@testable import Persistence

/// C8: preferences must round-trip the kv store, partial updates must not
/// clobber siblings, and a corrupt blob must degrade to safe defaults.
final class SettingsStoreTests: XCTestCase {

    private func store() throws -> (SettingsStore, SQLiteDB) {
        let tmp = NSTemporaryDirectory() + "rc2-settings-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (SettingsStore(db: db), db)
    }

    func test_defaultsWhenNothingStored() throws {
        let (s, _) = try store()
        let d = s.load()
        XCTAssertEqual(d, AppSettings(), "absent settings must be the documented defaults")
        XCTAssertFalse(d.diffWordWrap)
        XCTAssertEqual(d.sidebarSort, "updated")
    }

    func test_saveThenLoadRoundTrips() throws {
        let (s, _) = try store()
        s.save(AppSettings(diffWordWrap: true, diffIgnoreWhitespace: true, sidebarSort: "manual"))
        let r = s.load()
        XCTAssertTrue(r.diffWordWrap && r.diffIgnoreWhitespace)
        XCTAssertEqual(r.sidebarSort, "manual")
    }

    func test_updatePreservesOtherFields() throws {
        let (s, _) = try store()
        s.save(AppSettings(diffWordWrap: true, diffIgnoreWhitespace: false, sidebarSort: "created"))
        s.update { $0.diffIgnoreWhitespace = true }
        let r = s.load()
        XCTAssertTrue(r.diffIgnoreWhitespace, "the updated field changes")
        XCTAssertTrue(r.diffWordWrap, "siblings must survive a partial update")
        XCTAssertEqual(r.sidebarSort, "created")
    }

    func test_corruptBlobDegradesToDefaults() throws {
        let (s, db) = try store()
        try SettingsRepository(db: db).set("app_settings", "{not valid json")
        XCTAssertEqual(s.load(), AppSettings(),
                       "a garbled blob must not crash — fall back to defaults")
    }
}
