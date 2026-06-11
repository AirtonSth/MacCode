import XCTest
@testable import AppShell
import AppKit

/// CI-gate (mac-settings-palette.md P2): accessibility-identifier regression lint.
///
/// WHY: accessibility identifiers on CommandPalette controls are load-bearing for
/// two reasons:
///   1. Future XCUITest targets address elements by these identifiers; a silent
///      rename breaks UI automation without a compile error.
///   2. The identifiers are documented in QA-001 (CommandPalette.swift:155-180)
///      as stable external contracts. Renaming them requires coordinated updates
///      across CI scripts, test infrastructure, and any third-party automation.
///
/// These tests construct the AppKit objects under @MainActor and assert the exact
/// identifier strings set in CommandPalette.init.  Any rename is caught here before
/// reaching UI-test infrastructure.
@MainActor
final class AccessibilityIdentifierLintTests: XCTestCase {

    // MARK: - Helpers

    private func makeContext() throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "RC2A11yLint-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        var result: [NSView] = []
        func collect(_ v: NSView) {
            result.append(v)
            v.subviews.forEach(collect)
        }
        collect(view)
        return result
    }

    // MARK: - T001: commandPalette.window identifier

    /// WHY: QA-001 documents "commandPalette.window" as the stable XCUITest
    /// address for the palette NSPanel.  XCUIApplication().windows["commandPalette.window"]
    /// is the entry point for every palette UI test.  A rename to any other string
    /// silently breaks all palette UI automation.
    func test_commandPalette_windowIdentifier_isStable() throws {
        let (_, router) = try makeContext()
        let palette = CommandPalette(router: router)

        XCTAssertEqual(
            palette.window.accessibilityIdentifier(),
            "commandPalette.window",
            "CommandPalette.window must carry the stable 'commandPalette.window' a11y identifier " +
            "so XCUITest can address the palette panel by a stable key (QA-001)"
        )
    }

    // MARK: - T002: commandPalette.window NSUserInterfaceItemIdentifier

    /// WHY: `panel.identifier` is used by AppKit window restoration and by some
    /// accessibility APIs as a secondary lookup key.  If it drifts from the a11y
    /// identifier, tools that rely on one or the other see different strings.
    func test_commandPalette_windowNSIdentifier_matchesA11yIdentifier() throws {
        let (_, router) = try makeContext()
        let palette = CommandPalette(router: router)

        XCTAssertEqual(
            palette.window.identifier?.rawValue,
            "commandPalette.window",
            "CommandPalette panel.identifier must equal the a11y identifier so window " +
            "restoration and automation agree on the same string"
        )
    }

    // MARK: - T003: commandPalette.searchField identifier

    /// WHY: QA-001 documents "commandPalette.searchField" as the stable address
    /// for the search input.  Typing into XCUIApplication().textFields["commandPalette.searchField"]
    /// is the only reliable way to drive palette filtering in UI tests without
    /// coordinate-based clicks that break on layout changes.
    func test_commandPalette_searchFieldIdentifier_isStable() throws {
        let (_, router) = try makeContext()
        let palette = CommandPalette(router: router)

        guard let content = palette.window.contentView else {
            return XCTFail("CommandPalette.window must have a contentView for the search field to exist")
        }

        let searchFields = allSubviews(of: content).filter { view in
            view.accessibilityIdentifier() == "commandPalette.searchField"
        }
        XCTAssertEqual(
            searchFields.count, 1,
            "exactly one view must carry the 'commandPalette.searchField' identifier; " +
            "a rename or duplicate breaks the single stable XCUITest entry point for palette typing"
        )
        XCTAssertTrue(
            searchFields.first is NSTextField,
            "'commandPalette.searchField' must be an NSTextField so XCUITest can type into it"
        )
    }

    // MARK: - T004: commandPalette.table identifier

    /// WHY: QA-001 documents "commandPalette.table" as the address for the results
    /// NSTableView.  UI tests query rows by combining the table identifier with
    /// per-row "commandPalette.row.<id>" identifiers (set in tableView(_:viewFor:row:)).
    /// Renaming the table identifier breaks the row-addressing scheme for all tests.
    func test_commandPalette_tableIdentifier_isStable() throws {
        let (_, router) = try makeContext()
        let palette = CommandPalette(router: router)

        guard let content = palette.window.contentView else {
            return XCTFail("CommandPalette.window must have a contentView for the table to exist")
        }

        let tables = allSubviews(of: content).filter { view in
            view.accessibilityIdentifier() == "commandPalette.table"
        }
        XCTAssertEqual(
            tables.count, 1,
            "exactly one view must carry the 'commandPalette.table' identifier; " +
            "without it per-row 'commandPalette.row.<id>' addressing has no stable parent"
        )
        XCTAssertTrue(
            tables.first is NSTableView,
            "'commandPalette.table' must be an NSTableView so UI tests can enumerate rows"
        )
    }

    // MARK: - T005: no unexpected duplicate identifiers

    /// WHY: duplicate accessibility identifiers are ambiguous for UI automation;
    /// XCUITest returns an arbitrary match when two elements share a key.
    /// This test ensures all four known palette identifiers are unique within
    /// the view hierarchy.
    func test_commandPalette_knownIdentifiers_areUnique() throws {
        let (_, router) = try makeContext()
        let palette = CommandPalette(router: router)

        guard let content = palette.window.contentView else {
            return XCTFail("CommandPalette.window must have a contentView")
        }

        let knownIDs = ["commandPalette.searchField", "commandPalette.table"]
        for id in knownIDs {
            let matches = allSubviews(of: content).filter { $0.accessibilityIdentifier() == id }
            XCTAssertEqual(
                matches.count, 1,
                "identifier '\(id)' must appear exactly once; " +
                "\(matches.count) occurrences found - duplicates make XCUITest addressing ambiguous"
            )
        }
    }
}
