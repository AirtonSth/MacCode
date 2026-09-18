import XCTest

/// WHY: `MainWindowController.newWorkspace` backs both the header "+" button
/// and the empty-state "New Workspace" button, and its `NSOpenPanel` cannot be
/// driven from a unit test. It used to call
/// `_ = try? router?.createWorkspace(fromFolder: url)` directly, which skipped
/// three guarantees the sidebar's `createWorkspace(fromFolder:)` owns:
///   - DEDUP-P2: choosing a folder that is already a workspace created a second
///     workspace for the same cwd (two rows, two terminal runtimes);
///   - File ▸ Open Recent never learned about the folder;
///   - a stale/missing folder closed the panel and did nothing, with no error.
///
/// The add behavior itself is locked behaviorally by
/// `WorkspaceCwdDeduplicationIntegrationTests` and the stale-folder spec in
/// `WorkspaceCwdDeduplicationTests`; these specs only lock the *wire* from the
/// shell buttons to that canonical path, using the source-contract convention
/// already used for AppKit-only menu wiring (`AppMenuOpenRecentTests`,
/// `NavigationFirstFrameTests`).
final class MainWindowControllerAddWorkspacePathTests: XCTestCase {
    private func mainWindowControllerSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // AppShellTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        return try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/AppShell/MainWindowController.swift"),
            encoding: .utf8
        )
    }

    private func newWorkspaceBody(in source: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: "@objc private func newWorkspace()"),
            "the header \"+\" and empty-state buttons must keep routing through newWorkspace()"
        )
        let tail = source[start.upperBound...]
        let end = tail.range(of: "@objc private func ")?.lowerBound ?? tail.endIndex
        return String(tail[..<end])
    }

    func test_headerNewWorkspaceTakesTheSidebarAddPath() throws {
        let body = try newWorkspaceBody(in: try mainWindowControllerSource())
        XCTAssertTrue(
            body.contains("sidebar.createWorkspace(fromFolder: url)"),
            "the panel result must go through SidebarView.createWorkspace(fromFolder:), which owns dedup, Open Recent and the failure sheet"
        )
        XCTAssertFalse(
            body.contains("try? router?.createWorkspace(fromFolder:"),
            "creating the workspace straight from the router skips DEDUP-P2 and reports nothing when the folder cannot be added"
        )
    }
}
