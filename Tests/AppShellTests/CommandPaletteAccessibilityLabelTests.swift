import XCTest
@testable import AppShell

/// Verifies the VoiceOver label composition for command palette rows (P3-CP-VO).
///
/// Business rule: every runnable row must announce itself with a composed label
/// that includes title, subtitle (when present), and keyboard shortcut (when
/// present) so VoiceOver users can identify and invoke commands without reading
/// the three disjoint child text elements individually.
///
/// The seam under test is `CommandPalette.accessibilityLabel(title:subtitle:shortcut:)` --
/// a pure static function that encodes the composition rule. It is tested without
/// instantiating a full CommandPalette (which requires a live AppCommandRouter).
@MainActor
final class CommandPaletteAccessibilityLabelTests: XCTestCase {

    // MARK: - Title only

    func test_titleOnly_returnsTitle() {
        // WHY: when no subtitle or shortcut exists (e.g. a plain workspace-jump
        // row), the label must be exactly the title without trailing punctuation.
        let label = CommandPalette.accessibilityLabel(title: "Save Session Snapshot",
                                                     subtitle: "",
                                                     shortcut: nil)
        XCTAssertEqual(label, "Save Session Snapshot")
    }

    // MARK: - Title + subtitle

    func test_titleAndSubtitle_appendsSubtitle() {
        // WHY: subtitle carries context (e.g. "In current workspace") that lets
        // VO users distinguish between two similarly-named commands in the list.
        let label = CommandPalette.accessibilityLabel(title: "New Terminal Surface",
                                                     subtitle: "In current workspace",
                                                     shortcut: nil)
        XCTAssertEqual(label, "New Terminal Surface, In current workspace")
    }

    // MARK: - Title + shortcut

    func test_titleAndShortcut_appendsShortcut() {
        // WHY: the keyboard shortcut lets power users confirm the chord without
        // leaving the palette; it must appear in the VO announcement.
        let label = CommandPalette.accessibilityLabel(title: "Quit RemoteCode",
                                                     subtitle: "",
                                                     shortcut: "Command+Q")
        XCTAssertEqual(label, "Quit RemoteCode, Command+Q")
    }

    // MARK: - Title + subtitle + shortcut

    func test_allParts_joinedWithComma() {
        // WHY: a full row (title + subtitle + chord) must produce a single
        // comma-separated string; VO reads commas as a brief pause, which gives
        // natural separation without requiring the user to hear three elements.
        let label = CommandPalette.accessibilityLabel(title: "New Terminal Surface",
                                                     subtitle: "In current workspace",
                                                     shortcut: "Command+T")
        XCTAssertEqual(label, "New Terminal Surface, In current workspace, Command+T")
    }

    // MARK: - Empty shortcut string is not appended

    func test_emptyShortcutString_isOmitted() {
        // WHY: shortcut is Optional; passing a non-nil but empty string (defensive
        // caller) must not add a trailing ", " to the label.
        let label = CommandPalette.accessibilityLabel(title: "Open Workspace in Editor",
                                                     subtitle: "Cursor / VS Code / Zed / Xcode",
                                                     shortcut: "")
        XCTAssertEqual(label, "Open Workspace in Editor, Cursor / VS Code / Zed / Xcode")
    }

    // MARK: - Determinism

    func test_labelComposition_isDeterministic() {
        // WHY: the label is recomputed on every configure() call during table
        // reload; same inputs must always produce the same output.
        let args = ("New Workspace...", "Choose a folder to use as cwd", "Command+N" as String?)
        let first  = CommandPalette.accessibilityLabel(title: args.0, subtitle: args.1, shortcut: args.2)
        let second = CommandPalette.accessibilityLabel(title: args.0, subtitle: args.1, shortcut: args.2)
        XCTAssertEqual(first, second)
    }
}
