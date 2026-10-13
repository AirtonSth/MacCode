import XCTest
@testable import Persistence
import CoreModel

/// C8: preferences must round-trip the kv store, partial updates must not
/// clobber siblings, and a corrupt blob must degrade to safe defaults.
final class SettingsStoreTests: XCTestCase {

    private func store() throws -> (SettingsStore, SQLiteDB) {
        let tmp = NSTemporaryDirectory() + "rc2-settings-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (SettingsStore(db: db), db)
    }

    func test_newThreadDefaultsMigrateLegacyProviderToDistill_becauseNoOtherProviderIsOffered() {
        let suite = "rc-legacy-defaults-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentNewThreadDefaultsStore(defaults: defaults)
        store.save(AgentNewThreadDefaults(
            routingMode: .auto,
            runAsUser: nil,
            provider: .codex,
            providerInstanceId: "codex-cli",
            model: "gpt-5.6-sol",
            reasoningEffort: .xhigh,
            distillMainEffortSelection: nil
        ))

        let migrated = store.load()
        XCTAssertEqual(migrated?.provider, .distill)
        XCTAssertEqual(migrated?.providerInstanceId, "distill")
        XCTAssertEqual(migrated?.model, "", "the other provider's model must not carry over")
        XCTAssertEqual(migrated?.reasoningEffort, .medium, "the other provider's effort must not carry over")
        XCTAssertEqual(migrated?.routingMode, .manual)
        XCTAssertEqual(store.load(), migrated, "the migrated defaults persist")
    }

    func test_defaultsWhenNothingStored() throws {
        let (s, _) = try store()
        let d = s.load()
        XCTAssertEqual(d, AppSettings(), "absent settings must be the documented defaults")
        XCTAssertFalse(d.diffWordWrap)
        XCTAssertTrue(d.notificationActionAlertsEnabled)
        XCTAssertTrue(d.notificationCompletionAlertsEnabled)
        XCTAssertFalse(d.notificationSoundEnabled)
        XCTAssertEqual(d.notificationMutedWorkspaceIDs, [])
        XCTAssertEqual(d.sidebarSort, "updated")
        XCTAssertFalse(d.insomniaEnabled)
        XCTAssertTrue(d.insomniaAllowDisplaySleep)
        XCTAssertFalse(d.insomniaAllowSystemSleepWhenDisplayClosed)
        XCTAssertTrue(d.insomniaAllowScreenSaverAfter45MinutesOfInactivity)
        XCTAssertEqual(d.terminalFontSize, 0)
        XCTAssertTrue(d.petEnabled, "a fresh install must show the pet without requiring setup")
        XCTAssertTrue(d.petAnimationsEnabled)
        XCTAssertTrue(d.petReadyCounterEnabled)
        XCTAssertEqual(d.petPosition, "bottomRight")
        XCTAssertEqual(d.petSize, 1.5, "the pet must start at the existing 150% size")
        XCTAssertEqual(d.petAttentionFilter, "all")
        XCTAssertFalse(d.petReduceMotion)
        XCTAssertTrue(d.botsControlPlaneEnabled, "P1a ships the Bot control plane on")
        XCTAssertTrue(d.botsMemoryEnabled, "P1a includes memory CRUD")
        XCTAssertFalse(d.botsEffectsEnabled)
        XCTAssertFalse(d.botsAutonomyEnabled)
        XCTAssertFalse(d.botsDesktopVMEnabled)
        XCTAssertFalse(d.botsDesktopRemoteEnabled)
        XCTAssertFalse(d.botsChannelsEnabled)
        XCTAssertFalse(d.isBotEffectsActive, "later Bot phases stay fail-closed")
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
            notificationActionAlertsEnabled: false,
            notificationCompletionAlertsEnabled: false,
            notificationSoundEnabled: true,
            notificationMutedWorkspaceIDs: ["workspace-a", "workspace-b"],
            terminalFontSize: 16,
            petEnabled: true,
            petAnimationsEnabled: false,
            petReadyCounterEnabled: false,
            petPosition: "free",
            petSize: 1.5,
            petAttentionFilter: "needsYou",
            petReduceMotion: true
        ))
        let r = s.load()
        XCTAssertTrue(r.diffWordWrap && r.diffIgnoreWhitespace)
        XCTAssertEqual(r.sidebarSort, "manual")
        XCTAssertTrue(r.insomniaEnabled)
        XCTAssertFalse(r.insomniaAllowDisplaySleep)
        XCTAssertTrue(r.insomniaAllowSystemSleepWhenDisplayClosed)
        XCTAssertFalse(r.insomniaAllowScreenSaverAfter45MinutesOfInactivity)
        XCTAssertEqual(r.terminalFontSize, 16, "terminalFontSize must round-trip so new terminals keep the chosen base font")
        XCTAssertTrue(r.petEnabled)
        XCTAssertFalse(r.petAnimationsEnabled)
        XCTAssertFalse(r.petReadyCounterEnabled)
        XCTAssertEqual(r.petPosition, "free")
        XCTAssertEqual(r.petSize, 1.5)
        XCTAssertEqual(r.petAttentionFilter, "needsYou")
        XCTAssertTrue(r.petReduceMotion)
        XCTAssertFalse(r.notificationActionAlertsEnabled)
        XCTAssertFalse(r.notificationCompletionAlertsEnabled)
        XCTAssertTrue(r.notificationSoundEnabled)
        XCTAssertEqual(r.notificationMutedWorkspaceIDs, ["workspace-a", "workspace-b"])
    }

    func test_updatePreservesOtherFields() throws {
        let (s, _) = try store()
        s.save(AppSettings(diffWordWrap: true, diffIgnoreWhitespace: false, sidebarSort: "created", terminalFontSize: 14))
        s.update { $0.diffIgnoreWhitespace = true }
        let r = s.load()
        XCTAssertTrue(r.diffIgnoreWhitespace, "the updated field changes")
        XCTAssertTrue(r.diffWordWrap, "siblings must survive a partial update")
        XCTAssertEqual(r.sidebarSort, "created")
        XCTAssertEqual(r.terminalFontSize, 14, "unrelated fields must survive a partial update")
    }

    func test_blobWithRemovedTokenSaverKeysStillLoadsTheOtherSettings() throws {
        // WHY: blobs written while Token Saver existed carry its keys. They must
        // still load, or every upgraded user would fall back to defaults.
        let (s, db) = try store()
        try SettingsRepository(db: db).set(
            "app_settings",
            #"{"diffWordWrap":true,"tokenSaverEnabled":true,"tokenSaverAPIToken":"sk-legacy","tokenSaverModelSource":"api","graphifyPinnedRoots":["/r"],"terminalFontSize":13}"#
        )
        let r = s.load()
        XCTAssertTrue(r.diffWordWrap)
        XCTAssertEqual(r.terminalFontSize, 13)
    }

    func test_dropRemovedLegacyKeysRewritesTheBlobOnlyWhenThoseKeysArePresent() throws {
        // WHY: the old Token Saver API token is a secret for a feature that no
        // longer exists. Nothing else rewrites the blob, so the cleanup must,
        // without touching the user's other settings.
        let (s, db) = try store()
        let repo = SettingsRepository(db: db)
        try repo.set(
            "app_settings",
            #"{"sidebarSort":"manual","tokenSaverEnabled":true,"tokenSaverAPIToken":"sk-legacy","sessionLearnEnabled":true,"graphifyEnabled":true}"#
        )

        XCTAssertTrue(s.dropRemovedLegacyKeys())
        let stored = try XCTUnwrap(repo.get("app_settings"))
        for key in SettingsStore.removedLegacyKeys {
            XCTAssertFalse(stored.contains("\"\(key)\""), key)
        }
        XCTAssertFalse(stored.contains("sk-legacy"))
        XCTAssertEqual(s.reload().sidebarSort, "manual")

        XCTAssertFalse(s.dropRemovedLegacyKeys(), "a clean blob is not rewritten")
        XCTAssertEqual(try repo.get("app_settings"), stored)
    }

    func test_olderBlobWithoutInsomniaFieldsKeepsExistingSettings() throws {
        let (s, db) = try store()
        try SettingsRepository(db: db).set("app_settings", #"{"diffWordWrap":true,"diffIgnoreWhitespace":false,"sidebarSort":"manual"}"#)
        let r = s.load()
        XCTAssertTrue(r.diffWordWrap, "older settings blobs must not be discarded when new Insomnia fields are absent")
        XCTAssertEqual(r.sidebarSort, "manual")
        XCTAssertFalse(r.insomniaEnabled)
        XCTAssertTrue(r.notificationActionAlertsEnabled)
        XCTAssertTrue(r.notificationCompletionAlertsEnabled)
        XCTAssertFalse(r.notificationSoundEnabled)
        XCTAssertEqual(r.notificationMutedWorkspaceIDs, [])
        XCTAssertTrue(r.insomniaAllowDisplaySleep)
        XCTAssertFalse(r.insomniaAllowSystemSleepWhenDisplayClosed)
        XCTAssertTrue(r.insomniaAllowScreenSaverAfter45MinutesOfInactivity)
        XCTAssertEqual(r.terminalFontSize, 0, "older settings blobs must default terminal font size to Ghostty default")
        XCTAssertTrue(r.petEnabled, "settings created before the pet existed must receive the current pet default")
        XCTAssertTrue(r.petAnimationsEnabled)
        XCTAssertTrue(r.petReadyCounterEnabled)
        XCTAssertEqual(r.petPosition, "bottomRight")
        XCTAssertEqual(r.petSize, 1.5, "older blobs without a pet size must receive the current 150% default")
        XCTAssertEqual(r.petAttentionFilter, "all")
        XCTAssertFalse(r.petReduceMotion)
        XCTAssertTrue(r.botsControlPlaneEnabled, "older blobs must receive the shipped P1a control-plane default")
        XCTAssertTrue(r.botsMemoryEnabled)
        XCTAssertFalse(r.botsEffectsEnabled)
        XCTAssertFalse(r.botsAutonomyEnabled)
    }

    func test_corruptBlobDegradesToDefaults() throws {
        let (s, db) = try store()
        try SettingsRepository(db: db).set("app_settings", "{not valid json")
        XCTAssertEqual(s.load(), AppSettings(),
                       "a garbled blob must not crash — fall back to defaults")
    }

    func test_explicitPetPreferencesOverrideDefaults() throws {
        let (s, _) = try store()
        s.save(AppSettings(petEnabled: false, petSize: 1))

        let r = s.load()
        XCTAssertFalse(r.petEnabled, "a user who disables the pet must keep that choice")
        XCTAssertEqual(r.petSize, 1, "a user-selected 100% size must survive relaunch")
    }
}
