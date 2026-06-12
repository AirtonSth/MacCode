import XCTest
@testable import AppShell

/// T-KEYBIND-RELOAD: Pins the contract for keybindings live-reload wiring.
///
/// WHY: AppDelegate.keybindingsReloaded() observes rc2KeybindingsReloaded and
/// calls invalidateCache() before re-applying applyKeybindingOverride to live
/// menu items. Two invariants must hold or menu shortcuts silently stop updating
/// after a keybindings.json edit:
///   1. The notification name string must be stable -- a rename breaks the
///      observer registration in AppDelegate.
///   2. After posting the notification, the cache must be invalidated so the
///      next loadDefaultPath() reads the updated file, not a stale parse.
///
/// AppDelegate itself requires a full AppKit + AppContext init and is not
/// exercised here; the underlying seams (notification name + invalidateCache)
/// are pure and can be pinned without that stack.
@MainActor
final class KeybindingsReloadNotificationTests: XCTestCase {

    override func tearDown() {
        KeybindingConfig.invalidateCache()
        super.tearDown()
    }

    // MARK: - T-KEYBIND-RELOAD-1: notification name stability

    /// WHY: AppDelegate registers: name: .rc2KeybindingsReloaded, object: nil.
    /// If the raw string changes, the observer silently stops firing and menu
    /// shortcuts no longer update on file edit. The raw string is the contract.
    func test_notificationName_rawStringIsStable() {
        XCTAssertEqual(
            Notification.Name.rc2KeybindingsReloaded.rawValue,
            "rc2KeybindingsReloaded",
            "notification raw string must be stable -- a rename silently breaks AppDelegate observer registration"
        )
    }

    // MARK: - T-KEYBIND-RELOAD-2: posting the notification causes invalidateCache seam

    /// WHY: The live-reload path is:
    ///   file changes -> pane calls invalidateCache() -> posts rc2KeybindingsReloaded
    ///   -> AppDelegate observes -> calls invalidateCache() again + applyKeybindingOverride
    /// This test pins that invalidateCache() after a file write causes the
    /// next loadDefaultPath() to return fresh content -- the precondition for
    /// applyKeybindingOverride to pick up the new binding.
    ///
    /// We cannot drive AppDelegate without a full AppKit stack, but the
    /// invalidateCache seam is observable and is exactly what keybindingsReloaded()
    /// calls before re-applying overrides.
    func test_invalidateCacheAfterFileWrite_returnsUpdatedConfig() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2ReloadTest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Write v1 and prime the cache via loadDefaultPath's seam (load(path:)).
        let v1 = #"[{"key":"mod+k","command":"commandPalette.toggle"}]"#
        try v1.write(to: tempURL, atomically: true, encoding: .utf8)
        let cfg1 = KeybindingConfig.load(path: tempURL.path)
        XCTAssertEqual(cfg1.bindings.count, 1, "v1 load must parse one binding")

        // Simulate file update + cache invalidation (what the pane + AppDelegate do).
        let v2 = #"[{"key":"mod+k","command":"commandPalette.toggle"},{"key":"mod+p","command":"terminal.new"}]"#
        try v2.write(to: tempURL, atomically: true, encoding: .utf8)
        KeybindingConfig.invalidateCache()

        // After invalidation the next load must return the updated content.
        let cfg2 = KeybindingConfig.load(path: tempURL.path)
        XCTAssertEqual(cfg2.bindings.count, 2,
            "after invalidateCache() load must re-parse from disk -- " +
            "if it returns 1 binding, stale cache means menu shortcuts never update on file edit")
    }

    // MARK: - T-KEYBIND-RELOAD-3: posting does not crash and observer is callable

    /// WHY: The notification machinery must not crash when rc2KeybindingsReloaded
    /// is posted with no active observer (e.g. during unit test runs without a
    /// live AppDelegate). A crash here would silently break the Settings pane
    /// Reload button for any test configuration that exercises the pane.
    func test_postingReloadNotification_doesNotCrash() {
        // Must not throw or crash even when no AppDelegate observer is registered.
        NotificationCenter.default.post(name: .rc2KeybindingsReloaded, object: nil)
    }
}
