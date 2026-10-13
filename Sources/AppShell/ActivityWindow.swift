import AppKit
import DesignSystemKit
import SocketServer
import Surfaces
import SwiftUI

struct ActivityWireItem: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: String
    var run_id: String?
    var request_id: String?
    var notification_id: String?
    var workspace_id: String?
    var thread_id: String?
    var surface_id: String?
    var state: String
    var title: String
    var workspace_name: String?
    var provider: String?
    var summary: String?
    var occurred_at: String
    var started_at: String?
    var finished_at: String?
    var viewed_at: String?
    var attention_acknowledged_at: String?
    var needs_action: Bool
    var blocking: Bool
    var final_message_id: String?
    var checkpoint_id: String?
    var checkpoint_turn_count: Int? = nil
    var changed_files: [String] = []
    var error: String?
    var bot_id: String?
    var conversation_id: String?
    var origin_label: String?

    var durationLabel: String? {
        guard let start = started_at.flatMap(ActivityViewModel.parseDate),
              let finish = finished_at.flatMap(ActivityViewModel.parseDate) else { return nil }
        let interval = finish.timeIntervalSince(start)
        guard interval.isFinite, interval >= 0, interval < Double(Int.max) else { return nil }
        let seconds = Int(interval)
        return "\(seconds / 60)m \(seconds % 60)s"
    }
    var isNew: Bool { viewed_at == nil }
    var isMarkable: Bool { kind != "request" && ["completed", "failed", "interrupted", "stopped"].contains(state) }
    var statusLabel: String {
        switch state {
        case "completed": "Completed"
        case "failed": "Failed"
        case "interrupted": "Interrupted"
        case "stopped": "Stopped by you"
        case "waiting_approval": "Waiting for approval"
        case "waiting_answer": "Waiting for your answer"
        case "queued": "Queued"
        case "running": "Running"
        case "expired": "Request expired"
        default: state.capitalized
        }
    }
}

struct ActivityWireCounts: Codable, Equatable, Sendable {
    var running: Int = 0
    var queued: Int = 0
    var needs_you: Int = 0
    var finished: Int = 0
    var new_results: Int = 0
}

struct ActivityWirePage: Codable, Equatable, Sendable {
    var items: [ActivityWireItem] = []
    var next_cursor: String?
    var counts: ActivityWireCounts = .init()
    var generated_at: String?
}

@MainActor
struct ActivityClient {
    var list: ([String: JSONValue]) async throws -> JSONValue
    var setViewed: @MainActor ([String: JSONValue]) throws -> JSONValue
    var acknowledge: @MainActor ([String: JSONValue]) throws -> JSONValue

    init(router: AppCommandRouter) {
        list = { try await router.activityListOffMain(params: $0) }
        setViewed = { try router.activitySetViewed(params: $0) }
        acknowledge = { try router.activityAcknowledge(params: $0) }
    }

    init(
        list: @escaping ([String: JSONValue]) async throws -> JSONValue,
        setViewed: @escaping @MainActor ([String: JSONValue]) throws -> JSONValue,
        acknowledge: @escaping @MainActor ([String: JSONValue]) throws -> JSONValue
    ) {
        self.list = list
        self.setViewed = setViewed
        self.acknowledge = acknowledge
    }
}

private enum ActivityBatchError: LocalizedError {
    case invalidCutoff
    case invalidItemDate(String)
    case repeatedCursor
    case partial(updated: Int, total: Int)

    var errorDescription: String? {
        switch self {
        case .invalidCutoff: "Could not verify activity snapshot time; no results were changed."
        case .invalidItemDate(let id): "Could not verify timestamp for \(id); no further results were changed."
        case .repeatedCursor: "Activity paging repeated a cursor; remaining results were not changed."
        case .partial(let updated, let total): "Updated \(updated) of \(total) results before the host returned a partial response."
        }
    }
}

@MainActor
final class ActivityViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case running, needsYou, finished
        var id: String { rawValue }
        var wireValue: String { self == .needsYou ? "needs_you" : rawValue }
        var title: String { self == .needsYou ? "Needs you" : rawValue.capitalized }
    }

    enum Period: String, CaseIterable, Identifiable {
        case all, day, week, month
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Any time"
            case .day: "Past 24 hours"
            case .week: "Past 7 days"
            case .month: "Past 30 days"
            }
        }
        var since: String? {
            guard self != .all else { return nil }
            let seconds: TimeInterval = self == .day ? 86_400 : self == .week ? 604_800 : 2_592_000
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date().addingTimeInterval(-seconds))
        }
    }

    @Published private(set) var page = ActivityWirePage()
    @Published private(set) var detail: ActivityWireItem?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var undoCount: Int?
    @Published private(set) var batchStatus: String?
    @Published private(set) var batchRunning = false
    @Published private(set) var showingCachedResults = false
    @Published private(set) var hasSuccessfulSnapshot = false
    @Published var tab: Tab { didSet { needsInitialTabChoice = false; resetSelectionForFilterChange(); if tab != .finished && !outcome.isEmpty { outcome = "" }; persist(); if !applyingInitialTabChoice { refreshAfterFrame() } } }
    @Published var search = "" { didSet { resetSelectionForFilterChange(); persist(); refreshAfterFrame() } }
    @Published var outcome = "" { didSet { resetSelectionForFilterChange(); persist(); refreshAfterFrame() } }
    @Published var workspaceID = "" { didSet { resetSelectionForFilterChange(); persist(); refreshAfterFrame() } }
    @Published var period: Period { didSet { guard oldValue != period else { return }; resetSelectionForFilterChange(); persist(); refreshAfterFrame() } }
    @Published var selectedID: String? { didSet { persist() } }
    @Published var scrollID: String? { didSet { persist() } }

    private let service: ActivityClient
    private let defaults: UserDefaults
    private var cursor: String?
    private var activeSince: String?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var undoSnapshot: [String: String?] = [:]
    private var needsInitialTabChoice = false
    private var applyingInitialTabChoice = false
    private var scrollRestored = false
    private var eventSubscription: UUID?
    private var refreshInvalidationPending = false
    private var requestedTargetID: String?

    init(router: AppCommandRouter, defaults: UserDefaults = .standard) {
        service = ActivityClient(router: router)
        self.defaults = defaults
        let restored = defaults.string(forKey: "activity.tab").flatMap(Tab.init(rawValue:))
        needsInitialTabChoice = restored == nil
        tab = restored ?? .running
        search = defaults.string(forKey: "activity.search") ?? ""
        outcome = restored == .finished ? (defaults.string(forKey: "activity.outcome") ?? "") : ""
        workspaceID = defaults.string(forKey: "activity.workspace") ?? ""
        period = Period(rawValue: defaults.string(forKey: "activity.period") ?? "all") ?? .all
        activeSince = period.since
        selectedID = defaults.string(forKey: "activity.selection")
        requestedTargetID = selectedID
        scrollID = defaults.string(forKey: "activity.scroll")
        if let data = defaults.data(forKey: cacheKey), let cached = try? JSONDecoder().decode(ActivityWirePage.self, from: data) {
            page = cached
            hasSuccessfulSnapshot = true
            cursor = cached.next_cursor
            if let selectedID { detail = cached.items.first(where: { $0.id == selectedID }) }
            showingCachedResults = true
        }
        subscribeToActivityInvalidations()
    }

    init(service: ActivityClient, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        let restored = defaults.string(forKey: "activity.tab").flatMap(Tab.init(rawValue:))
        needsInitialTabChoice = restored == nil
        tab = restored ?? .running
        search = defaults.string(forKey: "activity.search") ?? ""
        outcome = restored == .finished ? (defaults.string(forKey: "activity.outcome") ?? "") : ""
        workspaceID = defaults.string(forKey: "activity.workspace") ?? ""
        period = Period(rawValue: defaults.string(forKey: "activity.period") ?? "all") ?? .all
        activeSince = period.since
        selectedID = defaults.string(forKey: "activity.selection")
        requestedTargetID = selectedID
        scrollID = defaults.string(forKey: "activity.scroll")
        if let data = defaults.data(forKey: cacheKey), let cached = try? JSONDecoder().decode(ActivityWirePage.self, from: data) {
            page = cached
            hasSuccessfulSnapshot = true
            cursor = cached.next_cursor
            if let selectedID { detail = cached.items.first(where: { $0.id == selectedID }) }
            showingCachedResults = true
        }
        subscribeToActivityInvalidations()
    }

    deinit {
        task?.cancel()
        if let eventSubscription { EventBus.shared.unsubscribe(eventSubscription) }
    }

    private func subscribeToActivityInvalidations() {
        eventSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { [weak self] event in
            guard ["notification.created", "notification.read", "notification.dismissed", "bots.attention.changed", "bot.attention.updated", "bot.scheduler.updated", "operation.updated", "agent.run.started", "agent.run.completed", "agent.run.failed", "agent.run.finished", "agent.run.cancelled", "agent.request.opened", "agent.request.resolved", "agent.user_input.requested", "agent.user_input.resolved"].contains(event.kind) else { return }
            Task { @MainActor [weak self] in self?.scheduleInvalidationRefresh() }
        }
    }

    private func scheduleInvalidationRefresh() {
        guard !refreshInvalidationPending else { return }
        refreshInvalidationPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            self.refreshInvalidationPending = false
            self.refreshAfterFrame()
        }
    }

    private var cacheKey: String {
        "activity.page.\(tab.rawValue).\(workspaceID).\(outcome).\(period.rawValue).\(search)"
    }

    private func resetSelectionForFilterChange() {
        requestedTargetID = nil
        selectedID = nil
        scrollID = nil
        detail = nil
        scrollRestored = false
        if let data = defaults.data(forKey: cacheKey), let cached = try? JSONDecoder().decode(ActivityWirePage.self, from: data) {
            page = cached
            cursor = cached.next_cursor
            hasSuccessfulSnapshot = true
            showingCachedResults = true
        } else {
            page = ActivityWirePage()
            cursor = nil
            hasSuccessfulSnapshot = false
            showingCachedResults = false
        }
    }

    private func persist() {
        defaults.set(tab.rawValue, forKey: "activity.tab")
        defaults.set(search, forKey: "activity.search")
        defaults.set(outcome, forKey: "activity.outcome")
        defaults.set(workspaceID, forKey: "activity.workspace")
        defaults.set(period.rawValue, forKey: "activity.period")
        defaults.set(selectedID, forKey: "activity.selection")
        defaults.set(scrollID, forKey: "activity.scroll")
    }

    private func persistPage() {
        guard let data = try? JSONEncoder().encode(page) else { return }
        defaults.set(data, forKey: cacheKey)
        let stale = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("activity.page.") && $0 != cacheKey }
            .sorted()
        for key in stale.dropLast(7) { defaults.removeObject(forKey: key) }
    }

    func loadCached(_ cached: ActivityWirePage) {
        page = cached
        hasSuccessfulSnapshot = true
        cursor = cached.next_cursor
        if let selectedID { detail = cached.items.first(where: { $0.id == selectedID }) }
        showingCachedResults = true
    }

    func applyRoute(intent: NotificationRouteIntent) {
        tab = .finished
        workspaceID = intent.workspaceId?.value.uuidString ?? ""
        search = ""
        outcome = ""
        period = .all
        selectedID = nil
        scrollID = nil
        requestedTargetID = intent.activityItemId
        if let itemID = intent.activityItemId {
            selectedID = itemID
            scrollID = itemID
        }
        refreshAfterFrame()
    }

    func refreshAfterFrame() {
        task?.cancel()
        generation &+= 1
        let request = generation
        task = Task { @MainActor [weak self] in
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            guard let self, !Task.isCancelled, self.generation == request else { return }
            self.cursor = nil
            self.activeSince = self.period.since
            self.loading = true
            self.error = nil
            do {
                let params = Self.listParams(tab: self.tab, search: self.search, outcome: self.outcome, workspaceID: self.workspaceID, since: self.activeSince)
                let next = try Self.decodePage(try await self.service.list(params))
                guard !Task.isCancelled, self.generation == request else { return }
                self.page = next
                self.hasSuccessfulSnapshot = true
                if let selectedID = self.selectedID {
                    self.detail = next.items.first(where: { $0.id == selectedID })
                } else {
                    self.detail = nil
                }
                if self.requestedTargetID == self.detail?.id { self.requestedTargetID = nil }
                self.showingCachedResults = false
                self.cursor = next.next_cursor
                self.persistPage()
                if let targetID = self.selectedID, self.detail == nil, self.requestedTargetID == targetID {
                    var cursors = Set<String>()
                    while !self.page.items.contains(where: { $0.id == targetID }), let pageCursor = self.cursor {
                        guard !Task.isCancelled, self.generation == request, cursors.insert(pageCursor).inserted else { return }
                        var pageParams = Self.listParams(tab: self.tab, search: self.search, outcome: self.outcome, workspaceID: self.workspaceID, since: self.activeSince)
                        pageParams["cursor"] = .string(pageCursor)
                        let targetPage = try Self.decodePage(try await self.service.list(pageParams))
                        guard !Task.isCancelled, self.generation == request else { return }
                        self.page.items += targetPage.items
                        self.cursor = targetPage.next_cursor
                        self.page.generated_at = targetPage.generated_at
                        self.persistPage()
                        if let target = targetPage.items.first(where: { $0.id == targetID }) {
                            self.detail = target
                            self.requestedTargetID = nil
                            self.scrollID = targetID
                        }
                    }
                    guard !Task.isCancelled, self.generation == request else { return }
                    if self.detail == nil { self.error = "Requested activity result was not found." }
                } else if let selectedID = self.selectedID, self.detail == nil {
                    self.selectedID = nil
                    self.scrollID = nil
                }
                if self.needsInitialTabChoice {
                    self.needsInitialTabChoice = false
                    let preferred: Tab = next.counts.needs_you > 0 ? .needsYou : (next.counts.running > 0 ? .running : .finished)
                    if preferred != self.tab {
                        self.applyingInitialTabChoice = true
                        self.tab = preferred
                        self.applyingInitialTabChoice = false
                        self.refreshAfterFrame()
                        return
                    } else { self.persist() }
                }
            } catch {
                guard self.generation == request else { return }
                self.error = error.localizedDescription
            }
            if self.generation == request { self.loading = false; self.task = nil }
        }
    }

    func loadMore() {
        guard let cursor, !loading else { return }
        let request = generation
        let pageCursor = cursor
        loading = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var params = Self.listParams(tab: self.tab, search: self.search, outcome: self.outcome, workspaceID: self.workspaceID, since: self.activeSince)
                params["cursor"] = .string(pageCursor)
                let next = try Self.decodePage(try await self.service.list(params))
                guard self.generation == request else { return }
                self.page.items += next.items
                self.cursor = next.next_cursor
                self.page.generated_at = next.generated_at
                self.persistPage()
            } catch {
                if self.generation == request { self.error = error.localizedDescription }
            }
            if self.generation == request { self.loading = false; self.task = nil }
        }
    }

    func openDetail(_ item: ActivityWireItem) {
        requestedTargetID = nil
        selectedID = item.id
        scrollID = item.id
        detail = item
    }

    func restoreScrollAnchor() -> String? {
        defer { scrollRestored = true }
        return scrollID ?? selectedID
    }

    func didDisplay(_ id: String) {
        if scrollRestored { scrollID = id }
    }

    func detailPresented(_ item: ActivityWireItem) {
        guard detail?.id == item.id, item.isNew, item.isMarkable else { return }
        setViewed([item], viewed: true)
    }

    func markCurrentResultsSeen() {
        guard !batchRunning else { return }
        batchRunning = true
        batchStatus = "Collecting matching results…"
        error = nil
        undoSnapshot = [:]
        undoCount = nil
        let snapshotTab = tab
        let snapshotSearch = search
        let snapshotOutcome = outcome
        let snapshotWorkspace = workspaceID
        let snapshotSince = period.since
        let clickTime = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            var snapshots: [String: String?] = [:]
            var updated = Set<String>()
            do {
                var params = Self.listParams(tab: snapshotTab, search: snapshotSearch, outcome: snapshotOutcome, workspaceID: snapshotWorkspace, since: snapshotSince)
                var result = try Self.decodePage(try await self.service.list(params))
                guard let generatedAt = result.generated_at.flatMap(Self.parseDate) else { throw ActivityBatchError.invalidCutoff }
                let cutoff = min(clickTime, generatedAt)
                var cursors = Set<String>()
                while true {
                    for item in result.items where item.isMarkable && item.isNew {
                        guard let time = Self.parseDate(item.occurred_at) else { throw ActivityBatchError.invalidItemDate(item.id) }
                        if time <= cutoff { snapshots[item.id] = item.viewed_at }
                    }
                    guard let next = result.next_cursor else { break }
                    guard cursors.insert(next).inserted else { throw ActivityBatchError.repeatedCursor }
                    params["cursor"] = .string(next)
                    result = try Self.decodePage(try await self.service.list(params))
                }
                guard !snapshots.isEmpty else {
                    self.batchStatus = "No unseen results matched this filter."
                    self.batchRunning = false
                    return
                }
                let ids = snapshots.keys.sorted()
                for start in stride(from: 0, to: ids.count, by: 200) {
                    let chunk = Array(ids[start..<min(start + 200, ids.count)])
                    let response = try self.service.setViewed(["item_ids": .array(chunk.map(JSONValue.string)), "viewed": .bool(true)])
                    let chunkUpdated = Self.updatedIDs(response).intersection(chunk)
                    updated.formUnion(chunkUpdated)
                    self.undoSnapshot = snapshots.filter { updated.contains($0.key) }
                    self.undoCount = updated.count
                    if chunkUpdated.count != chunk.count { throw ActivityBatchError.partial(updated: updated.count, total: ids.count) }
                }
                self.batchStatus = "Marked \(updated.count) results seen."
                self.refreshAfterFrame()
            } catch {
                if !self.undoSnapshot.isEmpty {
                    self.batchStatus = "Marked \(self.undoSnapshot.count) results before failure. Undo restores marked results."
                }
                self.error = error.localizedDescription
            }
            self.batchRunning = false
        }
    }

    private func setViewed(_ items: [ActivityWireItem], viewed: Bool) {
        let candidates = items.filter(\.isMarkable)
        guard !candidates.isEmpty else { return }
        var captured: [String: String?] = [:]
        do {
            for start in stride(from: 0, to: candidates.count, by: 200) {
                let chunk = Array(candidates[start..<min(start + 200, candidates.count)])
                let response = try service.setViewed(["item_ids": .array(chunk.map { .string($0.id) }), "viewed": .bool(viewed)])
                let returned = Self.updatedIDs(response).intersection(chunk.map(\.id))
                for item in chunk where returned.contains(item.id) { captured[item.id] = item.viewed_at }
                if returned.count != chunk.count { throw ActivityBatchError.partial(updated: captured.count, total: candidates.count) }
            }
            if viewed {
                undoSnapshot = captured
                undoCount = captured.count
                batchStatus = "Marked \(captured.count) results seen."
            }
            refreshAfterFrame()
        } catch {
            if viewed && !captured.isEmpty { undoSnapshot = captured; undoCount = captured.count }
            self.error = error.localizedDescription
        }
    }

    func undoViewed() {
        let snapshot = undoSnapshot
        guard !snapshot.isEmpty else { return }
        var restored = Set<String>()
        do {
            let ids = snapshot.keys.sorted()
            for start in stride(from: 0, to: ids.count, by: 200) {
                let chunk = Array(ids[start..<min(start + 200, ids.count)])
                let restore = Dictionary(uniqueKeysWithValues: chunk.map { id in (id, (snapshot[id] ?? nil).map(JSONValue.string) ?? .null) })
                let response = try service.setViewed(["item_ids": .array(chunk.map(JSONValue.string)), "viewed": .bool(false), "restore_viewed_at": .object(restore)])
                let chunkRestored = Self.updatedIDs(response).intersection(chunk)
                restored.formUnion(chunkRestored)
                if chunkRestored.count != chunk.count { throw ActivityBatchError.partial(updated: restored.count, total: ids.count) }
            }
            undoSnapshot.removeAll()
            undoCount = nil
            batchStatus = "Restored \(restored.count) results to their previous seen state."
            refreshAfterFrame()
        } catch {
            undoSnapshot = snapshot.filter { !restored.contains($0.key) }
            undoCount = undoSnapshot.count
            self.error = error.localizedDescription
            if !undoSnapshot.isEmpty { batchStatus = "Restored \(restored.count); \(undoSnapshot.count) still need Undo." }
        }
    }

    private static func listParams(tab: Tab, search: String, outcome: String, workspaceID: String, since: String?) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["section": .string(tab.wireValue), "search": .string(search), "limit": .number(50)]
        if !outcome.isEmpty { params["outcome"] = .string(outcome) }
        if !workspaceID.isEmpty { params["workspace_id"] = .string(workspaceID) }
        if let since { params["since"] = .string(since) }
        return params
    }

    private static func decodePage(_ value: JSONValue) throws -> ActivityWirePage {
        try JSONDecoder().decode(ActivityWirePage.self, from: JSONEncoder().encode(value))
    }

    private static func updatedIDs(_ value: JSONValue) -> Set<String> {
        Set(value.objectValue?["updated_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    fileprivate static func parseDate(_ value: String) -> Date? {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFractions.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    func acknowledge(_ item: ActivityWireItem) {
        guard item.state == "failed" || item.state == "interrupted" else { return }
        do {
            _ = try service.acknowledge(["item_id": .string(item.id)])
            refreshAfterFrame()
        } catch { self.error = error.localizedDescription }
    }
}

struct ActivityRootView: View {
    @StateObject private var model: ActivityViewModel
    @State private var narrowDetail = false
    let openThread: (ActivityWireItem) -> Void
    let openEvidence: (ActivityWireItem, String?) -> Void
    private let workspaceOptions: () -> [(id: String, name: String)]
    let route: NotificationRouteIntent?
    let consumeRoute: () -> Void

    init(router: AppCommandRouter, route: NotificationRouteIntent? = nil, consumeRoute: @escaping () -> Void = {}, openThread: @escaping (ActivityWireItem) -> Void = { _ in }, openEvidence: @escaping (ActivityWireItem, String?) -> Void = { _, _ in }) {
        _model = StateObject(wrappedValue: ActivityViewModel(router: router))
        self.openThread = openThread
        self.openEvidence = openEvidence
        self.route = route
        self.consumeRoute = consumeRoute
        workspaceOptions = { router.activityWorkspaceOptions }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: DS.Space.sm) {
                ForEach(ActivityViewModel.Tab.allCases) { tab in
                    AgentListFilterChip(title: tab.title, count: count(for: tab), selected: model.tab == tab, identifier: "activity.tab.\(tab.rawValue)") { model.tab = tab }
                }
                Spacer()
                if model.undoCount != nil { Button("Undo") { model.undoViewed() } }
                if model.tab == .finished {
                    Button(model.batchRunning ? "Collecting…" : "Mark results seen") { model.markCurrentResultsSeen() }
                        .disabled(model.batchRunning)
                }
                if let status = model.batchStatus { Text(status).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).lineLimit(2) }
            }.padding(.horizontal, DS.Space.xl).padding(.bottom, DS.Space.md)
            HStack(spacing: 0) {
                list.frame(minWidth: 220, idealWidth: 310, maxWidth: narrowDetail ? .infinity : 390)
                if !narrowDetail, let detail = model.detail {
                    Rectangle().fill(DS.Palette.line).frame(width: 1)
                    detailView(detail).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if model.loading || model.batchRunning { ProgressView().controlSize(.small).padding(DS.Space.sm) }
        }
        .frame(minWidth: 540, minHeight: 420)
        .background(DS.Palette.bg)
        .onAppear {
            if let route { apply(route) }
            else { model.refreshAfterFrame() }
        }
        .onChange(of: route) { _, next in
            if let next { apply(next) }
        }
        .alert("Activity could not be updated", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.dismissError() } })) {
            Button("OK") { model.dismissError() }
        } message: { Text(model.error ?? "") }
    }

    private func apply(_ route: NotificationRouteIntent) {
        model.applyRoute(intent: route)
        consumeRoute()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Activity").font(DS.Font.title.weight(.semibold)).foregroundColor(DS.Palette.text)
            if model.hasSuccessfulSnapshot {
                Text("\(model.page.counts.running) running · \(model.page.counts.needs_you) need you · \(model.page.counts.finished) finished")
                    .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
            } else {
                Text("Activity counts unavailable")
                    .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
            }
            HStack {
                TextField("Search title, workspace, or summary", text: $model.search).textFieldStyle(.roundedBorder)
                Picker("Workspace", selection: $model.workspaceID) {
                    Text("All workspaces").tag("")
                    ForEach(workspaces, id: \.id) { workspace in Text(workspace.name).tag(workspace.id) }
                }.frame(width: 170)
                Picker("Period", selection: $model.period) {
                    ForEach(ActivityViewModel.Period.allCases) { period in Text(period.title).tag(period) }
                }.frame(width: 145)
                if model.tab == .finished {
                    Picker("Outcome", selection: $model.outcome) {
                        Text("All outcomes").tag("")
                        Text("Completed").tag("completed")
                        Text("Failed").tag("failed")
                        Text("Interrupted").tag("interrupted")
                        Text("Stopped by you").tag("stopped")
                    }.frame(width: 150)
                }
            }
        }.padding(DS.Space.xl)
    }

    private var list: some View {
        VStack {
            if narrowDetail, let item = model.detail {
                HStack { Button("Back to activity") { narrowDetail = false }; Spacer() }
                    .padding(.horizontal, DS.Space.md)
                detailView(item)
            } else {
                if let error = model.error {
                    HStack {
                        Text(model.showingCachedResults ? "Showing saved results. Update failed: \(error)" : "Update failed: \(error)")
                            .font(DS.Font.caption).foregroundColor(DS.Palette.danger).lineLimit(2)
                        Button("Retry") { model.refreshAfterFrame() }
                    }.padding(DS.Space.sm)
                }
                if model.page.items.isEmpty && !model.loading && model.error == nil && model.hasSuccessfulSnapshot {
                    DSEmptyState(icon: "tray", title: "No activity", subtitle: "Results and requests will appear here.")
                } else if !model.page.items.isEmpty {
                    ScrollViewReader { proxy in
                        List {
                            if model.tab == .running {
                                if !model.runningItems.isEmpty {
                                    Section("Running") {
                                        ForEach(model.runningItems) { item in activityRow(item) }
                                    }
                                }
                                if !model.queuedItems.isEmpty {
                                    Section("Queued · \(model.page.counts.queued)") {
                                        ForEach(model.queuedItems) { item in activityRow(item) }
                                    }
                                }
                            } else {
                                ForEach(model.page.items) { item in activityRow(item) }
                            }
                        }.listStyle(.plain).accessibilityIdentifier("activity.list")
                            .onAppear { let anchor = model.restoreScrollAnchor(); if let anchor { proxy.scrollTo(anchor, anchor: .center) } }
                            .onChange(of: model.selectedID) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    }
                    if model.cursorAvailable { Button("Load more") { model.loadMore() }.padding(.bottom, DS.Space.sm) }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func activityRow(_ item: ActivityWireItem) -> some View {
        Button { model.openDetail(item); narrowDetail = true } label: { row(item) }
            .buttonStyle(.plain).id(item.id)
            .onAppear { model.didDisplay(item.id) }
    }

    private func row(_ item: ActivityWireItem) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text(item.title).font(DS.Font.body.weight(.semibold)).foregroundColor(DS.Palette.text).lineLimit(2)
                Spacer()
                Text(item.statusLabel).font(DS.Font.caption).foregroundColor(color(item.state))
            }
            Text([item.workspace_name, item.provider, item.origin_label].compactMap { $0 }.joined(separator: " · ")).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
            if let summary = item.summary { Text(summary).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).lineLimit(2) }
            if item.isNew { Text("New result").font(DS.Font.caption.weight(.semibold)).foregroundColor(DS.Palette.text) }
        }.padding(.vertical, DS.Space.xs).accessibilityElement(children: .combine)
    }

    private func detailView(_ item: ActivityWireItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text(item.title).font(DS.Font.title.weight(.semibold)).foregroundColor(DS.Palette.text)
                DSPill(item.statusLabel, tone: item.state == "failed" ? .danger : item.state == "completed" ? .success : .neutral)
                Text(item.workspace_name ?? "Workspace unavailable").foregroundColor(DS.Palette.textSecondary)
                if let origin = item.origin_label { Text(origin).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary) }
                if let provider = item.provider { Text(provider).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary) }
                Text(item.kind == "agent" ? "Agent summary" : "Result").font(DS.Font.body.weight(.semibold)).foregroundColor(DS.Palette.text)
                Text(item.summary ?? "No summary available for this run.").font(DS.Font.body).foregroundColor(DS.Palette.text)
                Text(item.occurred_at).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                if let duration = item.durationLabel { Text("Duration \(duration)").font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary) }
                if let error = item.error { Text(error).foregroundColor(DS.Palette.danger) }
                if item.thread_id != nil || item.bot_id != nil || item.surface_id != nil || item.notification_id != nil {
                    Button(item.bot_id != nil ? "Open bot" : item.surface_id != nil && item.thread_id == nil ? "Open terminal" : "Open destination") { openThread(item) }
                    if item.checkpoint_turn_count != nil, item.thread_id != nil, item.workspace_id != nil, item.run_id != nil {
                        Button("View changes") { openEvidence(item, nil) }
                    }
                }
                if !item.changed_files.isEmpty {
                    Text("Changes").font(DS.Font.body.weight(.semibold))
                    ForEach(item.changed_files, id: \.self) { path in
                        if item.checkpoint_turn_count != nil, item.thread_id != nil, item.workspace_id != nil, item.run_id != nil {
                            Button("View \(path)") { openEvidence(item, path) }
                        } else {
                            Text(path).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                        }
                    }
                }
                if item.state == "failed" || item.state == "interrupted" { Button("Acknowledge failure") { model.acknowledge(item) } }
                if item.state == "waiting_approval" || item.state == "waiting_answer" { Text("Open the request in its canonical conversation to respond.").foregroundColor(DS.Palette.textSecondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.xl)
        }.onAppear { model.detailPresented(item) }
    }

    private var workspaces: [(id: String, name: String)] {
        var names = Dictionary(model.page.items.compactMap { item -> (String, String)? in
            guard let id = item.workspace_id, let name = item.workspace_name else { return nil }
            return (id, name)
        }, uniquingKeysWith: { first, _ in first })
        for workspace in workspaceOptions() { names[workspace.id] = workspace.name }
        return names.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func count(for tab: ActivityViewModel.Tab) -> Int {
        switch tab {
        case .running: model.page.counts.running
        case .needsYou: model.page.counts.needs_you
        case .finished: model.page.counts.finished
        }
    }

    private func color(_ state: String) -> Color {
        switch state {
        case "running": .blue
        case "failed", "interrupted": DS.Palette.danger
        case "completed": DS.Palette.success
        case "stopped": DS.Palette.textSecondary
        default: DS.Palette.warning
        }
    }
}

extension ActivityViewModel {
    var runningItems: [ActivityWireItem] { page.items.filter { $0.state != "queued" } }
    var queuedItems: [ActivityWireItem] { page.items.filter { $0.state == "queued" } }
    var cursorAvailable: Bool { cursor != nil }
    func dismissError() { error = nil }
}
