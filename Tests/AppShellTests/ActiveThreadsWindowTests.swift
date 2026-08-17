import XCTest
@testable import AppShell
@testable import Persistence
import CoreModel

final class ActiveThreadsWindowTests: XCTestCase {
    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ActiveThreadsWindowTests.swift
            .deletingLastPathComponent() // AppShellTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent(relative)
    }

    func test_sidebarPlacesActiveThreadsImmediatelyAfterNewWorkspace_beforeScheduleTasks() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        let newWorkspace = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.newWorkspace\")"))
        let activeThreads = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.activeThreads\")"))
        let scheduleTasks = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.scheduleTasks\")"))
        let reportBug = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.reportBug\")"))
        XCTAssertLessThan(reportBug.lowerBound, newWorkspace.lowerBound,
                          "Report Bug is a header icon, not a dest row under Active Threads")
        XCTAssertLessThan(newWorkspace.lowerBound, activeThreads.lowerBound)
        XCTAssertLessThan(activeThreads.lowerBound, scheduleTasks.lowerBound)
    }

    func test_sidebarActiveThreadsBadgeUsesPetFormatter_becauseCountMustMatchPetBlueBadge() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("PetActiveThreadCountFormatter.badgeText(count: vm.activeThreadCount)"),
                      "sidebar badge must reuse PetActiveThreadCountFormatter so 0/1/99+ stay consistent")
        XCTAssertTrue(source.contains("badgeIsBlue: true"),
                      "Active Threads badge must be Pet-blue")
        XCTAssertTrue(source.contains("activeThreadCount"),
                      "sidebar must publish live activeThreadCount for the badge")
        XCTAssertNil(PetActiveThreadCountFormatter.badgeText(count: 0))
        XCTAssertEqual(PetActiveThreadCountFormatter.badgeText(count: 2), "2")
        XCTAssertEqual(PetActiveThreadCountFormatter.badgeText(count: 100), "99+")
    }

    func test_activeThreadsOpensInMainContent_notDetachedWindow() throws {
        let main = try String(contentsOf: sourceURL("Sources/AppShell/MainWindowController.swift"), encoding: .utf8)
        let sidebar = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("presentActiveThreadsInMainContent"),
                      "Active Threads must mount in the main workspace content column")
        XCTAssertTrue(main.contains("installActiveThreadsContent"),
                      "main shell must install ActiveThreadsRootView into workspaceContent")
        XCTAssertTrue(main.contains("case activeThreads"),
                      "ShellContentMode must include activeThreads")
        XCTAssertTrue(main.contains("visibleWorkspaceLabel.stringValue = \"Active Threads\""),
                      "title bar must read Active Threads while that shell destination is active")
        XCTAssertTrue(sidebar.contains("onPresentActiveThreads"),
                      "sidebar must route Active Threads to the main shell presenter")
        XCTAssertTrue(sidebar.contains("isActiveThreadsSelected"),
                      "sidebar must track Active Threads selection so workspace rows can fully deselect")
        XCTAssertTrue(sidebar.contains("setActiveThreadsSelected"),
                      "shell must be able to select/deselect Active Threads without a floating window")
    }

    func test_activeThreadsRootViewHasActiveAndLastFinishedTabs() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ActiveThreadsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("case active"),
                      "Active tab is required")
        XCTAssertTrue(source.contains("case lastFinished"),
                      "Last Finished tab is required")
        XCTAssertTrue(source.contains("\"Active\""),
                      "Active tab label must be user-facing English")
        XCTAssertTrue(source.contains("\"Last Finished\""),
                      "Last Finished tab label must be user-facing English")
        XCTAssertTrue(source.contains("listRecentFinished"),
                      "finished tab must load durable recent terminal runs")
        XCTAssertTrue(source.contains("presentWorkspaceContent()"),
                      "opening a thread must leave the Active Threads shell first")
        XCTAssertTrue(source.contains("openAgentThread"),
                      "opening a row must route into the agent thread")
    }

    func test_appContextPublishesSidebarRefreshOnActiveCountChange_becauseBadgeMustStayLive() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/AppContext.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("lastPublishedActiveThreadCount"),
                      "projection refresh must track last published active count")
        XCTAssertTrue(source.contains("countChanged"),
                      "count-only transitions must refresh sidebar chrome")
        XCTAssertTrue(source.contains("titlesChanged || countChanged"),
                      "must not early-return when only active count changes")
    }

    func test_listRecentFinishedExcludesActiveStatuses_andRespectsLimit() throws {
        // WHY: Last Finished must never show pending/running rows and must stay capped.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "finished-list", provider: .grok, model: "grok-4.5")
        try threadRepo.upsert(thread)
        let threadID = thread.id

        let finished = AgentRun(
            id: AgentRunID(),
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok",
            model: "grok-4.5",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200)
        )
        let running = AgentRun(
            id: AgentRunID(),
            threadId: threadID,
            provider: .grok,
            providerInstanceId: "grok",
            model: "grok-4.5",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 300)
        )
        let olderFinished = AgentRun(
            id: AgentRunID(),
            threadId: threadID,
            provider: .claude,
            providerInstanceId: "claude",
            model: "opus",
            status: .failed,
            startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 50)
        )
        try runRepo.upsert(finished)
        try runRepo.upsert(running)
        try runRepo.upsert(olderFinished)

        let rows = try runRepo.listRecentFinished(limit: 1)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, finished.id)
        XCTAssertEqual(rows[0].status, .completed)

        let allFinished = try runRepo.listRecentFinished(limit: 10)
        XCTAssertEqual(allFinished.count, 2)
        XCTAssertFalse(allFinished.contains(where: { $0.status == .running || $0.status == .pending }))
        XCTAssertEqual(allFinished.map(\.id), [finished.id, olderFinished.id])
    }
}
