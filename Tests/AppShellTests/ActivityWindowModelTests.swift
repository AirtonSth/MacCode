import XCTest
@testable import AppShell
import SocketServer

@MainActor
final class ActivityWindowModelTests: XCTestCase {
    private func item(_ id: String, at date: String = "2026-10-12T11:59:00Z", viewed: String? = nil, kind: String = "agent", state: String = "completed", needsAction: Bool? = nil) -> ActivityWireItem {
        ActivityWireItem(
            id: id, kind: kind, run_id: "run", request_id: nil, notification_id: nil,
            workspace_id: "workspace", thread_id: nil, surface_id: nil, state: state,
            title: id, workspace_name: "Workspace", provider: "Codex", summary: "Summary",
            occurred_at: date, started_at: nil, finished_at: nil, viewed_at: viewed,
            attention_acknowledged_at: nil, needs_action: needsAction ?? (kind == "request"), blocking: false,
            final_message_id: nil, checkpoint_id: nil, changed_files: [], error: nil
        )
    }

    private func json<T: Encodable>(_ value: T) -> JSONValue {
        JSONValue.decode(from: try! JSONEncoder().encode(value))!
    }

    private func page(_ items: [ActivityWireItem], cursor: String? = nil, counts: ActivityWireCounts = .init(), generatedAt: String? = "2026-10-12T12:00:00Z") -> JSONValue {
        json(ActivityWirePage(items: items, next_cursor: cursor, counts: counts, generated_at: generatedAt))
    }

    private func updated(_ ids: [String]) -> JSONValue {
        .object(["updated_ids": .array(ids.map(JSONValue.string))])
    }

    private func waitUntil(_ description: String, timeout: Duration = .seconds(2), condition: @escaping () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(description)")
    }

    func testCacheAndSelectionAreImmediateThenFreshResponseWins() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        let cached = ActivityWirePage(items: [item("cached")], counts: .init(), generated_at: nil)
        let fresh = page([item("fresh")], counts: ActivityWireCounts(running: 2, needs_you: 3, finished: 4))
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in fresh }, setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.loadCached(cached)
        model.selectedID = "cached"
        model.scrollID = "cached"
        XCTAssertEqual(model.page.items.first?.id, "cached")
        XCTAssertEqual(model.selectedID, "cached")
        XCTAssertEqual(model.scrollID, "cached")
        model.refreshAfterFrame()
        await waitUntil("fresh result") { model.page.items.first?.id == "fresh" }
        XCTAssertEqual(model.page.items.first?.id, "fresh")
        XCTAssertEqual(model.page.counts.finished, 4)
        XCTAssertEqual(model.tab, .needsYou, "first visit prefers action-needed work from host scope counts")
    }

    func testRestoredTabSurvivesHostCountsAndPeriodPersistsSinceQuery() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        var request: [String: JSONValue] = [:]
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in request = params; return self.page([], counts: .init(running: 8, needs_you: 3, finished: 9)) },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.period = .week
        model.refreshAfterFrame()
        await waitUntil("period query") { request["since"] != nil }
        XCTAssertEqual(model.tab, .finished, "restored tab must not change when counts refresh")
        XCTAssertEqual(request["section"]?.stringValue, "finished")
        XCTAssertEqual(request["limit"]?.intValue, 50)
        XCTAssertNotNil(request["since"]?.stringValue)
        XCTAssertEqual(defaults.string(forKey: "activity.period"), "week")
    }

    func testRestoredTargetPagesUntilExactItemAndMissingTargetDoesNotMarkSeen() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        defaults.set("run:target", forKey: "activity.selection")
        defaults.set("run:target", forKey: "activity.scroll")
        var listCalls = 0
        var mutations = 0
        let first = page((0..<50).map { item("run-\($0)") }, cursor: "frozen-next")
        let second = page([item("run:target")])
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in
                listCalls += 1
                if params["cursor"] == nil { return first }
                XCTAssertEqual(params["cursor"]?.stringValue, "frozen-next")
                return second
            },
            setViewed: { _ in mutations += 1; return self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("restored target on second page") { model.detail?.id == "run:target" }
        XCTAssertEqual(model.scrollID, "run:target")
        model.detailPresented(model.detail!)
        XCTAssertEqual(mutations, 1, "only mounting the exact detail may mark the result seen")

        let missingDefaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        missingDefaults.set("finished", forKey: "activity.tab")
        missingDefaults.set("run:missing", forKey: "activity.selection")
        var missingMutations = 0
        let missing = ActivityViewModel(service: ActivityClient(
            list: { _ in self.page([self.item("other")]) },
            setViewed: { _ in missingMutations += 1; return self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: missingDefaults)
        missing.refreshAfterFrame()
        await waitUntil("missing target error") { missing.error != nil && !missing.loading }
        XCTAssertNil(missing.detail)
        XCTAssertEqual(missing.selectedID, "run:missing")
        XCTAssertEqual(missingMutations, 0, "missing target must never mark another result seen")
    }

    func testAcknowledgedNeedsYouSelectionDisappearingOnRefreshDoesNotReportMissingExternalTarget() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("needsYou", forKey: "activity.tab")
        var listCalls = 0
        var acknowledged = false
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in
                listCalls += 1
                return self.page(acknowledged ? [] : [self.item("failed", state: "failed", needsAction: true)])
            },
            setViewed: { _ in self.updated([]) },
            acknowledge: { _ in acknowledged = true; return .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("Needs you result loaded") { model.page.items.count == 1 && !model.loading }
        model.openDetail(model.page.items[0])

        model.acknowledge(model.page.items[0])

        await waitUntil("acknowledgment refresh completed") { listCalls == 2 && !model.loading }
        XCTAssertTrue(acknowledged)
        XCTAssertNil(model.error)
        XCTAssertNil(model.selectedID)
        XCTAssertTrue(model.page.items.isEmpty)

        let routedDefaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        let routed = ActivityViewModel(service: ActivityClient(
            list: { _ in self.page([]) },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: routedDefaults)
        routed.applyRoute(intent: NotificationRouteIntent(threadId: nil, workspaceId: nil, opensActivity: true, activityItemId: "external-target"))
        await waitUntil("missing external route error") { routed.error != nil && !routed.loading }
        XCTAssertEqual(routed.error, "Requested activity result was not found.")
        XCTAssertEqual(routed.selectedID, "external-target")

        let resolvedDefaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var didAcknowledge = false
        var resolvedListCalls = 0
        let routedFailure = self.item("routed-failure", state: "failed", needsAction: true)
        let resolved = ActivityViewModel(service: ActivityClient(
            list: { _ in resolvedListCalls += 1; return self.page(didAcknowledge ? [] : [routedFailure]) },
            setViewed: { _ in self.updated([]) },
            acknowledge: { _ in didAcknowledge = true; return .object([:]) }
        ), defaults: resolvedDefaults)
        resolved.applyRoute(intent: NotificationRouteIntent(threadId: nil, workspaceId: nil, opensActivity: true, activityItemId: "routed-failure"))
        await waitUntil("external target resolved") { resolved.detail?.id == "routed-failure" && !resolved.loading }
        resolved.acknowledge(routedFailure)
        await waitUntil("resolved external target acknowledgment refresh") { didAcknowledge && resolvedListCalls == 2 && !resolved.loading }
        XCTAssertNil(resolved.error)
        XCTAssertNil(resolved.selectedID)
    }

    func testExplicitActivityRouteReplacesMountedFiltersWithoutMarkingResultsSeen() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var request: [String: JSONValue]?
        var mutations = 0
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in request = params; return self.page([]) },
            setViewed: { _ in mutations += 1; return self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.search = "old search"
        model.outcome = "failed"
        model.period = .week
        model.selectedID = "old result"
        model.applyRoute(intent: NotificationRouteIntent(threadId: nil, workspaceId: nil, opensActivity: true))
        XCTAssertEqual(model.tab, .finished)
        XCTAssertEqual(model.search, "")
        XCTAssertEqual(model.outcome, "")
        XCTAssertEqual(model.period, .all)
        XCTAssertNil(model.selectedID)
        await waitUntil("explicit Activity route freshness") { request != nil }
        XCTAssertEqual(request?["section"]?.stringValue, "finished")
        XCTAssertNil(request?["since"])
        XCTAssertEqual(mutations, 0, "opening grouped results must not mark any occurrence seen")
    }

    func testRecordedDurationUsesRunTimestampsAndRejectsNegativeIntervals() {
        var run = item("duration")
        run.started_at = "2026-10-12T12:00:00.000Z"
        run.finished_at = "2026-10-12T12:04:12.000Z"
        XCTAssertEqual(run.durationLabel, "4m 12s")
        run.finished_at = "2026-10-12T11:59:00Z"
        XCTAssertNil(run.durationLabel, "invalid timestamp order must never fabricate elapsed time")
    }

    func testFailedResultCanBeViewedWithoutAcknowledgmentButLiveRunCannot() {
        let failed = item("failed", state: "failed", needsAction: true)
        let running = item("running", state: "running")
        XCTAssertTrue(failed.isMarkable)
        XCTAssertTrue(failed.needs_action, "viewing failure must not acknowledge it")
        XCTAssertFalse(running.isMarkable, "running result must not be marked viewed")
        XCTAssertFalse(item("request", kind: "request", state: "failed").isMarkable)
    }

    func testDetailViewedMutationExcludesRequestAndUndoRestoresNilTimestamp() {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var mutations: [[String: JSONValue]] = []
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in self.page([]) },
            setViewed: { params in
                mutations.append(params)
                return self.updated(params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            },
            acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        let result = item("run:one")
        model.openDetail(result)
        XCTAssertTrue(mutations.isEmpty, "opening a result must not mark it seen before detail mounts")
        model.detailPresented(result)
        XCTAssertEqual(mutations.first?["item_ids"]?.arrayValue?.compactMap(\.stringValue), ["run:one"])
        model.undoViewed()
        XCTAssertEqual(mutations.count, 2)
        XCTAssertEqual(mutations.last?["restore_viewed_at"]?.objectValue?["run:one"], .null)
        XCTAssertEqual(mutations.last?["item_ids"]?.arrayValue?.compactMap(\.stringValue), ["run:one"])
    }

    func testBatchCapturesAllFilteredPagesButExcludesArrivalAfterSnapshotAndUndoRestoresNil() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        defaults.set("week", forKey: "activity.period")
        defaults.set("needle", forKey: "activity.search")
        defaults.set("workspace", forKey: "activity.workspace")
        var listCalls = 0
        var mutationCalls: [[String: JSONValue]] = []
        let first = page((0..<50).map { item("run-\($0)", at: "2026-10-12T11:59:00Z") }, cursor: "next")
        let second = page([
            item("run-50", at: "2026-10-12T11:58:00Z"),
            item("request-callback", at: "2026-10-12T11:58:00Z", kind: "request"),
            item("arrival-after-cutoff", at: "2026-10-12T12:01:00Z")
        ])
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in
                listCalls += 1
                XCTAssertEqual(params["section"]?.stringValue, "finished")
                XCTAssertEqual(params["search"]?.stringValue, "needle")
                XCTAssertEqual(params["workspace_id"]?.stringValue, "workspace")
                XCTAssertEqual(params["limit"]?.intValue, 50)
                XCTAssertNotNil(params["since"]?.stringValue)
                return listCalls == 1 ? first : second
            },
            setViewed: { params in
                mutationCalls.append(params)
                let ids = params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                XCTAssertLessThanOrEqual(ids.count, 200)
                return self.updated(ids)
            },
            acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.period = .week
        model.markCurrentResultsSeen()
        await waitUntil("batch completion") { !model.batchRunning }
        XCTAssertEqual(listCalls, 2, "batch must page beyond the visible 50 rows")
        XCTAssertEqual(mutationCalls.count, 1)
        let changed = mutationCalls[0]["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(changed.count, 51)
        XCTAssertFalse(changed.contains("arrival-after-cutoff"), "new arrivals after captured generated_at stay outside batch")
        XCTAssertFalse(changed.contains("request-callback"), "request callbacks are not bulk-marked as viewed")
        XCTAssertEqual(model.undoCount, 51)

        model.undoViewed()
        XCTAssertEqual(mutationCalls.count, 2)
        let undo = mutationCalls[1]
        XCTAssertEqual(undo["viewed"]?.boolValue, false)
        XCTAssertEqual(undo["restore_viewed_at"]?.objectValue?.count, 51)
        XCTAssertTrue(undo["restore_viewed_at"]?.objectValue?.values.allSatisfy { $0 == .null } == true)
    }

    func testBatchUsesClickTimeCutoffEvenWhenResponseSnapshotIsNewer() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let afterClick = formatter.string(from: Date().addingTimeInterval(30))
        let responseTime = formatter.string(from: Date().addingTimeInterval(60))
        var changedIDs: [String] = []
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in self.page([self.item("arrived-after-click", at: afterClick)], generatedAt: responseTime) },
            setViewed: { params in
                changedIDs = params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return self.updated(changedIDs)
            },
            acknowledge: { _ in .object([:]) }
        ), defaults: defaults)

        model.markCurrentResultsSeen()
        await waitUntil("batch completion") { !model.batchRunning }
        XCTAssertTrue(changedIDs.isEmpty, "response-time arrivals must stay outside click-time batch")
        XCTAssertEqual(model.batchStatus, "No unseen results matched this filter.")
    }

    func testBatchPartialResponseReportsExactCountAndUndoOnlyUpdatedIDs() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        defaults.set("finished", forKey: "activity.tab")
        var setCalls = 0
        var mutations: [[String: JSONValue]] = []
        let first = page((0..<50).map { item("run-\($0)") }, cursor: "next")
        let second = page([item("run-50", at: "2026-10-12T11:58:00Z")])
        let model = ActivityViewModel(service: ActivityClient(
            list: { params in params["cursor"] == nil ? first : second },
            setViewed: { params in
                mutations.append(params)
                setCalls += 1
                let ids = params["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return self.updated(setCalls == 1 ? Array(ids.prefix(20)) : ids)
            },
            acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.markCurrentResultsSeen()
        await waitUntil("batch completion") { !model.batchRunning }
        XCTAssertEqual(model.undoCount, 20)
        XCTAssertTrue(model.error?.contains("20") == true, "partial host result must report successful count")
        XCTAssertEqual(mutations.count, 1, "stop after host reports partial update")
        model.undoViewed()
        XCTAssertEqual(mutations.count, 2)
        let ids = mutations[1]["item_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(ids.count, 20)
        XCTAssertTrue(mutations[1]["restore_viewed_at"]?.objectValue?.values.allSatisfy { $0 == .null } == true)
    }

    func testActivityInvalidationFloodCoalescesRefreshAndPreservesSelection() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var calls = 0
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in calls += 1; return self.page([self.item("latest")]) },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("automatic initial tab load") { calls > 0 && !model.loading }
        let settledInitialCalls = calls
        model.selectedID = "latest"
        for _ in 0..<30 {
            EventBus.shared.publish(kind: .agentRunFinished, payload: .object(["id": .string(UUID().uuidString)]))
        }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(calls - settledInitialCalls, 1, "invalidation flood must add one latest-wins refresh after automatic initial tab selection")
        XCTAssertEqual(model.selectedID, "latest")
    }

    func testRequestEventsInvalidateAndQueuedItemsStaySeparateFromRunning() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var calls = 0
        let queued = item("queued", state: "queued")
        let running = item("running", state: "running")
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in calls += 1; return self.page([queued, running], counts: ActivityWireCounts(running: 1, queued: 1)) },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("initial activity result") { calls > 0 && !model.loading }
        XCTAssertEqual(model.runningItems.map(\.id), ["running"])
        XCTAssertEqual(model.queuedItems.map(\.id), ["queued"])
        EventBus.shared.publish(kind: .agentRequestOpened, payload: .object([:]))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThanOrEqual(calls, 2)
    }

    func testFilterChangeClearsPriorScopeWhenMatchingCacheMissingAndRefreshFails() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var calls = 0
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in
                calls += 1
                if calls == 1 { return self.page([self.item("old-scope")], counts: ActivityWireCounts(running: 1)) }
                throw NSError(domain: "offline", code: 2)
            },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("initial activity result") { calls > 0 && !model.loading }
        XCTAssertEqual(model.page.items.first?.id, "old-scope")
        model.workspaceID = "other-workspace"
        XCTAssertTrue(model.page.items.isEmpty)
        await waitUntil("refresh error") { model.error != nil }
        XCTAssertTrue(model.page.items.isEmpty, "failed refresh must not restore rows from prior scope")
        XCTAssertFalse(model.hasSuccessfulSnapshot)
    }

    func testRapidFilterChangeAndOfflineFailureStayExplicit() async {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        var calls = 0
        let model = ActivityViewModel(service: ActivityClient(
            list: { _ in
                calls += 1
                return self.page([self.item(calls == 1 ? "stale" : "latest")], counts: ActivityWireCounts(running: 1))
            },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        model.refreshAfterFrame()
        await waitUntil("first activity result") { calls > 0 && !model.loading }
        XCTAssertEqual(model.page.items.first?.id, "stale")
        model.search = "new target"
        model.refreshAfterFrame()
        await waitUntil("latest activity result") { model.page.items.first?.id == "latest" && !model.loading }
        XCTAssertEqual(model.page.items.first?.id, "latest")
        XCTAssertNil(model.error)

        let failing = ActivityViewModel(service: ActivityClient(
            list: { _ in throw NSError(domain: "offline", code: 2) },
            setViewed: { _ in self.updated([]) }, acknowledge: { _ in .object([:]) }
        ), defaults: defaults)
        failing.refreshAfterFrame()
        await waitUntil("offline error") { failing.error != nil }
        XCTAssertNotNil(failing.error, "offline refresh must not look like successful empty results")
    }
}
