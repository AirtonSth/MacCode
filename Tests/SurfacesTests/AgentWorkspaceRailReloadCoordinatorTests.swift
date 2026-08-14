import XCTest

final class AgentWorkspaceRailReloadCoordinatorTests: XCTestCase {
    /// Every workspace used to own a repeating poll task. With many restored
    /// workspaces those tasks scanned the same receipt store concurrently every
    /// two seconds, contending on its cross-process mutex and sustaining CPU use
    /// while the user scrolled. One shared loop serializes complete poll rounds.
    func test_subagentPollingUsesOneSharedNonOverlappingLoop() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/Surfaces/AgentWorkspaceRailReloadCoordinator.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var subagentPollTask: Task<Void, Never>?"))
        XCTAssertFalse(
            source.contains("subagentPollTasks: [WorkspaceID: Task<Void, Never>]"),
            "workspace-owned repeating tasks can overlap receipt scans and starve UI work"
        )
        XCTAssertTrue(source.contains("loadSubagentActivitySnapshotsOffMainActor"))
        XCTAssertFalse(
            source.contains("for workspaceID in workspaceIDs"),
            "one receipt-store scan must serve the complete round instead of rescanning once per workspace"
        )
        XCTAssertFalse(
            source.contains("subagentPollTask?.cancel()"),
            "membership churn must not cancel and restart a poll while its detached receipt read is still finishing"
        )
        XCTAssertTrue(
            source.contains("viewModel.selectedThreadRunIsStartingOrRunning || viewModel.subagentActivity.isLive"),
            "completed idle threads are refreshed by lifecycle events and must not rescan the receipt store forever"
        )
    }
}
