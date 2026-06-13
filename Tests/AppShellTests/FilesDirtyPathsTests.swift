import XCTest
@testable import AppShell

/// Tests for the dirty-path mutation that backs `files.state.get` mirror state.
///
/// WHY these tests matter:
///  - iOS reads `dirty_paths` to show whether a Mac edit is unsaved.
///  - Patch must add the edited path once, and save/discard must remove it.
///  - Ordering must remain stable so repeated state snapshots do not churn.
final class FilesDirtyPathsTests: XCTestCase {
    func test_markDirty_appendsPathOnce() {
        let first = filesDirtyPathsAfterMutation(existing: [], path: "src/App.swift", dirty: true)
        let second = filesDirtyPathsAfterMutation(existing: first, path: "src/App.swift", dirty: true)

        XCTAssertEqual(first, ["src/App.swift"],
            "first local edit must add the path so mirror clients can show unsaved file state")
        XCTAssertEqual(second, ["src/App.swift"],
            "repeated patch events for the same file must not duplicate dirty_paths entries")
    }

    func test_markClean_removesOnlyThatPath() {
        let next = filesDirtyPathsAfterMutation(
            existing: ["src/App.swift", "README.md"],
            path: "src/App.swift",
            dirty: false
        )

        XCTAssertEqual(next, ["README.md"],
            "saving one file must clear only that path while preserving other dirty files")
    }

    func test_markDirty_preservesExistingOrder() {
        let next = filesDirtyPathsAfterMutation(
            existing: ["README.md", "src/App.swift"],
            path: "docs/Guide.md",
            dirty: true
        )

        XCTAssertEqual(next, ["README.md", "src/App.swift", "docs/Guide.md"],
            "new dirty paths should append after existing paths to keep mirror snapshots stable")
    }
}
