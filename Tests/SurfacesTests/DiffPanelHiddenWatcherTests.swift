import XCTest
import CoreModel
@testable import Surfaces

/// WHY: a hidden Diff panel kept its recursive FSEvents stream on the whole
/// workspace and re-ran `git summary` (5 git spawns) up to every 2 s while an
/// agent edited or built in the repo, until the tab was closed. Nobody can see
/// a hidden panel, so it must stop watching, and it must refresh once when it
/// is shown again so the user never sees stale state first.
@MainActor
final class DiffPanelHiddenWatcherTests: XCTestCase {
    func test_hiddenPanelStopsWatching_andShowingAgainRestartsIt() throws {
        let cwd = NSTemporaryDirectory() + "rc2-diff-hidden-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        let surface = DiffPanelSurface(workspaceID: WorkspaceID(), cwd: cwd)
        defer { surface.close() }
        let registry = SurfaceRegistry()
        registry.register(surface)
        let id = surface.descriptor.id

        registry.setVisibleSurfaceIDs([id])
        XCTAssertTrue(surface.viewModel.isWatchingFileSystem, "a visible panel watches the workspace")

        registry.setVisibleSurfaceIDs([])
        XCTAssertFalse(surface.viewModel.isWatchingFileSystem, "a hidden panel must not keep the FSEvents stream")

        registry.setVisibleSurfaceIDs([id])
        XCTAssertTrue(surface.viewModel.isWatchingFileSystem, "showing the panel again must resume watching")
    }

    func test_showingThePanelRefreshesOnce() {
        let git = FakeGitClient()
        let vm = DiffPanelViewModel(cwd: NSTemporaryDirectory(), gitClient: git)
        defer { vm.stopFSWatcher() }
        let baseline = git.summaryCallCount
        vm.didBecomeVisible()
        let deadline = Date().addingTimeInterval(2)
        while git.summaryCallCount == baseline, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(git.summaryCallCount - baseline, 1, "becoming visible refreshes exactly once")
    }
}
