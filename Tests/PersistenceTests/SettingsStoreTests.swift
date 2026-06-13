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
        XCTAssertFalse(d.insomniaEnabled)
        XCTAssertTrue(d.insomniaAllowDisplaySleep)
        XCTAssertFalse(d.insomniaAllowSystemSleepWhenDisplayClosed)
        XCTAssertTrue(d.insomniaAllowScreenSaverAfter45MinutesOfInactivity)
        XCTAssertFalse(d.tokenSaverEnabled)
        XCTAssertEqual(d.terminalFontSize, 0)
    }

    func test_saveThenLoadRoundTrips() throws {
        let (s, _) = try store()
        s.save(AppSettings(
            diffWordWrap: true,
            diffIgnoreWhitespace: true,
            sidebarSort: "manual",
            insomniaEnabled: true,
            insomniaAllowDisplaySleep: false,
            insomniaAllowSystemSleepWhenDisplayClosed: true,
            insomniaAllowScreenSaverAfter45MinutesOfInactivity: false,
            tokenSaverEnabled: true,
            terminalFontSize: 16
        ))
        let r = s.load()
        XCTAssertTrue(r.diffWordWrap && r.diffIgnoreWhitespace)
        XCTAssertEqual(r.sidebarSort, "manual")
        XCTAssertTrue(r.insomniaEnabled)
        XCTAssertFalse(r.insomniaAllowDisplaySleep)
        XCTAssertTrue(r.insomniaAllowSystemSleepWhenDisplayClosed)
        XCTAssertFalse(r.insomniaAllowScreenSaverAfter45MinutesOfInactivity)
        XCTAssertTrue(r.tokenSaverEnabled)
        XCTAssertEqual(r.terminalFontSize, 16, "terminalFontSize must round-trip so new terminals keep the chosen base font")
    }

    func test_updatePreservesOtherFields() throws {
        let (s, _) = try store()
        s.save(AppSettings(diffWordWrap: true, diffIgnoreWhitespace: false, sidebarSort: "created", tokenSaverEnabled: true))
        s.update { $0.diffIgnoreWhitespace = true }
        let r = s.load()
        XCTAssertTrue(r.diffIgnoreWhitespace, "the updated field changes")
        XCTAssertTrue(r.diffWordWrap, "siblings must survive a partial update")
        XCTAssertEqual(r.sidebarSort, "created")
        XCTAssertTrue(r.tokenSaverEnabled, "Token Saver enablement must survive unrelated settings updates")
    }

    func test_olderBlobWithoutInsomniaFieldsKeepsExistingSettings() throws {
        let (s, db) = try store()
        try SettingsRepository(db: db).set("app_settings", #"{"diffWordWrap":true,"diffIgnoreWhitespace":false,"sidebarSort":"manual"}"#)
        let r = s.load()
        XCTAssertTrue(r.diffWordWrap, "older settings blobs must not be discarded when new Insomnia fields are absent")
        XCTAssertEqual(r.sidebarSort, "manual")
        XCTAssertFalse(r.insomniaEnabled)
        XCTAssertTrue(r.insomniaAllowDisplaySleep)
        XCTAssertFalse(r.insomniaAllowSystemSleepWhenDisplayClosed)
        XCTAssertTrue(r.insomniaAllowScreenSaverAfter45MinutesOfInactivity)
        XCTAssertFalse(r.tokenSaverEnabled)
        XCTAssertEqual(r.terminalFontSize, 0, "older settings blobs must default terminal font size to Ghostty default")
    }

    func test_corruptBlobDegradesToDefaults() throws {
        let (s, db) = try store()
        try SettingsRepository(db: db).set("app_settings", "{not valid json")
        XCTAssertEqual(s.load(), AppSettings(),
                       "a garbled blob must not crash — fall back to defaults")
    }
}
