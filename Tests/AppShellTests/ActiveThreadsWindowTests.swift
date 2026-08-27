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

    @MainActor
    func test_tabRefreshAcknowledgesSelectionAndKeepsLatestProjectionAndFailure() async throws {
        let directory = NSTemporaryDirectory() + "rc-active-refresh-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "Finished target", provider: .codex, model: "gpt-5")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id, provider: .codex, providerInstanceId: "codex", model: "gpt-5",
            status: .completed, startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 20)
        )
        try context.runRepo.upsert(run)

        let viewModel = ActiveThreadsViewModel(context: context, router: router, loadImmediately: false)
        viewModel.selectedTab = .lastFinished
        XCTAssertEqual(viewModel.selectedTab, .lastFinished,
                       "tab selection must be acknowledged before the deferred read")
        viewModel.scheduleTabRefresh(.lastFinished)
        viewModel.selectedTab = .active
        viewModel.scheduleTabRefresh(.active)
        viewModel.selectedTab = .lastFinished
        viewModel.scheduleTabRefresh(.lastFinished)
        for _ in 0..<1_000 {
            if viewModel.finishedItems.count == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(viewModel.selectedTab, .lastFinished)
        XCTAssertEqual(viewModel.finishedItems.map(\.runID), [run.id],
                       "the latest selected tab must publish the exact finished projection")
        XCTAssertEqual(viewModel.finishedItems.first?.title, "Finished target")

        try context.db.execute("DROP TABLE agent_runs")
        viewModel.selectedTab = .lastFinished
        viewModel.scheduleTabRefresh(.lastFinished)
        for _ in 0..<1_000 {
            if viewModel.errorMessage != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.errorMessage,
                        "a failed finished-run repository read must remain visible")
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

    @MainActor
    func test_reloadFinished_usesListChromeWithoutDurableGet() throws {
        // WHY: Last Finished used to compile one full threadRepo.get per run
        // (26 columns + routing JSON) on MainActor. Chrome is four columns.
        let directory = NSTemporaryDirectory() + "rc-active-chrome-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspaceID = WorkspaceID()
        var threads: [AgentThread] = []
        for index in 0..<20 {
            let thread = AgentThread(
                workspaceId: workspaceID,
                title: "Finished \(index)",
                provider: .codex,
                model: "gpt-5"
            )
            try context.threadRepo.upsert(thread)
            try context.runRepo.upsert(AgentRun(
                threadId: thread.id,
                provider: .codex,
                providerInstanceId: "codex",
                model: "gpt-5",
                status: .completed,
                startedAt: Date(timeIntervalSince1970: Double(index)),
                finishedAt: Date(timeIntervalSince1970: Double(100 + index))
            ))
            threads.append(thread)
        }
        let viewModel = ActiveThreadsViewModel(context: context, router: router, loadImmediately: false)
        let getsBefore = context.threadRepo.durableGetCountForTesting
        let chromeBefore = context.threadRepo.listChromeCallCountForTesting
        viewModel.reloadFinished()
        XCTAssertEqual(viewModel.finishedItems.count, 20)
        XCTAssertEqual(
            Set(viewModel.finishedItems.map(\.title)),
            Set(threads.map(\.title)),
            "finished rows must keep the durable thread title"
        )
        XCTAssertEqual(
            context.threadRepo.durableGetCountForTesting,
            getsBefore,
            "reloadFinished must not compile N full gets"
        )
        XCTAssertEqual(
            context.threadRepo.listChromeCallCountForTesting,
            chromeBefore + 1
        )
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ActiveThreadsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("listChrome(ids:"))
        XCTAssertFalse(
            source.contains("threadRepo.get(id: threadID)"),
            "reloadActive must not walk full gets for painted chrome"
        )
        XCTAssertFalse(source.contains("threadRepo.get(id: run.threadId)"))
    }

    func test_listChrome_skipsUnknownIds() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let threadRepo = AgentThreadRepository(db: db)
        let kept = AgentThread(title: "kept", provider: .grok, model: "grok-4")
        try threadRepo.upsert(kept)
        let missing = AgentThreadID()
        let chrome = try threadRepo.listChrome(ids: [kept.id, missing])
        XCTAssertEqual(Set(chrome.keys), [kept.id])
        XCTAssertEqual(chrome[kept.id]?.title, "kept")
        XCTAssertEqual(chrome[kept.id]?.provider, .grok)
        XCTAssertEqual(chrome[kept.id]?.model, "grok-4")
        XCTAssertNil(chrome[missing])
    }

    func test_listChrome_fasterThanNDurableGets() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let threadRepo = AgentThreadRepository(db: db)
        var ids: [AgentThreadID] = []
        ids.reserveCapacity(20)
        for index in 0..<20 {
            let thread = AgentThread(title: "chrome-\(index)", provider: .claude, model: "opus")
            try threadRepo.upsert(thread)
            ids.append(thread.id)
        }
        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = try threadRepo.listChrome(ids: ids)
            for id in ids { _ = try threadRepo.get(id: id) }
        }
        var chromeSamples: [Double] = []
        var getSamples: [Double] = []
        chromeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            chromeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.listChrome(ids: ids)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    for id in ids { _ = try threadRepo.get(id: id) }
                }
            })
        }
        let chromeMed = median(chromeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - chromeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] active-threads listChrome_ms=%@ durable_get_ms=%@ improvement_pct=%.2f chrome=%@ get=%@",
            String(chromeMed), String(getMed), improvement,
            String(describing: chromeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "batched listChrome must beat N durable gets by ≥5% (got \(improvement)%; chrome=\(chromeMed)ms get=\(getMed)ms)"
        )
    }
}
