import XCTest
@testable import AppShell

final class FilesSurfaceAuxSeamsTests: XCTestCase {
    func test_resolveSubmittedFilesPath_matrix() {
        // WHY: the path field accepts root paths, absolute workspace paths, slash-wrapped
        // relative paths, and blanks. The VM must receive only workspace-relative paths.
        XCTAssertEqual(resolveSubmittedFilesPath(raw: "/workspace", root: "/workspace"), "",
            "submitting the workspace root should navigate to the Files root")
        XCTAssertEqual(resolveSubmittedFilesPath(raw: "/workspace/src", root: "/workspace"), "src",
            "absolute paths under the workspace root should become relative paths")
        XCTAssertEqual(resolveSubmittedFilesPath(raw: " /docs/guide/ ", root: "/workspace"), "docs/guide",
            "relative paths should trim whitespace and leading/trailing slashes")
        XCTAssertNil(resolveSubmittedFilesPath(raw: "   ", root: "/workspace"),
            "blank path submission should not navigate")
    }

    func test_visibleFileEntries_hidesDotfilesUnlessShownAndStillAppliesNameFilter() {
        // WHY: .git/.DS_Store clutter should stay hidden by default, but the name filter must still
        // narrow visible rows when hidden files are enabled.
        let entries = [
            FilterableFileEntry(name: ".env", isDirectory: false),
            FilterableFileEntry(name: "README.md", isDirectory: false),
            FilterableFileEntry(name: "Sources", isDirectory: true)
        ]

        let hiddenOff = visibleFileEntries(entries, showHidden: false, query: "", isHidden: { $0.name.hasPrefix(".") })
        let hiddenOnFiltered = visibleFileEntries(entries, showHidden: true, query: "env", isHidden: { $0.name.hasPrefix(".") })

        XCTAssertEqual(hiddenOff.map(\.name), ["README.md", "Sources"],
            "hidden rows must be excluded while showHidden is off")
        XCTAssertEqual(hiddenOnFiltered.map(\.name), [".env"],
            "showHidden on should expose dotfiles and still honor the name filter")
    }

    func test_shouldGateLargeMedia_thresholdAndLoadAnyway() {
        // WHY: media previews above 64MB should not decode until the user explicitly opts in, and
        // the exact threshold boundary must not show the guard.
        XCTAssertFalse(shouldGateLargeMedia(size: LargeMediaGuardThreshold, loadAnyway: false),
            "size equal to the threshold should render directly")
        XCTAssertTrue(shouldGateLargeMedia(size: LargeMediaGuardThreshold + 1, loadAnyway: false),
            "size above the threshold should show the guard before loading")
        XCTAssertFalse(shouldGateLargeMedia(size: LargeMediaGuardThreshold + 1, loadAnyway: true),
            "Load Anyway must bypass the guard for the current file")
    }

    func test_binaryMetadataRows_includePathMimeAndByteSize() {
        // WHY: non-editable files use these rows as their only in-app inspection surface before
        // Reveal/Open Externally. Missing path/MIME/size makes binary diagnostics weak.
        let rows = binaryMetadataRows(relativePath: "build/app.bin", mime: "application/octet-stream", size: 42)

        XCTAssertEqual(rows, [
            BinaryMetadataRow(label: "Path", value: "build/app.bin"),
            BinaryMetadataRow(label: "MIME", value: "application/octet-stream"),
            BinaryMetadataRow(label: "Size", value: "42 bytes")
        ])
    }
}
