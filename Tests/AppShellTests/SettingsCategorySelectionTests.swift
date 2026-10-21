import XCTest
@testable import AppShell
import CoreModel
import Persistence

/// WHY: Settings lives in the main window now, so the selected category is the
/// only place that remembers which destination the user left open. It must
/// survive a reopen of MacCode, or the Settings destination silently resets.
@MainActor
final class SettingsCategorySelectionTests: XCTestCase {
    func test_selectRouteAccountsSelectsAccountsAndPersistsAcrossViewModels() throws {
        let dir = NSTemporaryDirectory() + "RC2SettingsCategory-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let vm = SettingsViewModel(context: ctx)
        XCTAssertEqual(vm.selectedCategory, .remoteAccess)

        vm.select(route: .accounts)

        XCTAssertEqual(vm.selectedCategory, .accounts)
        XCTAssertEqual(SettingsViewModel(context: ctx).selectedCategory, .accounts)
    }
}
