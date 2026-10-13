import Foundation
import CoreModel
import Persistence
import RemoteCodeTreaty
import SocketServer

typealias ActivityCounts = AgentActivityCounts
typealias ActivityPage = AgentActivityPage

final class ActivityService: @unchecked Sendable {
    private let db: SQLiteDB
    private let readDB: SQLiteDB
    private let workspaceNames: [WorkspaceID: String]
    private let activeRunIDProvider: (AgentThreadID) -> AgentRunID?
    private let registeredScripts: [AgentActivityItem]

    @MainActor
    init(context: AppContext, activeRunIDProvider: ((AgentThreadID) -> AgentRunID?)? = nil) {
        db = context.db
        readDB = context.readDB
        workspaceNames = context.state.workspaces.mapValues(\.name)
        let activeRuns = Dictionary(uniqueKeysWithValues: context.coordinator.primaryActiveThreadIdsSnapshot().compactMap { thread in
            context.coordinator.activeRunId(threadId: thread).map { (thread, $0) }
        })
        self.activeRunIDProvider = activeRunIDProvider ?? { activeRuns[$0] }
        registeredScripts = context.projectScriptRuns.activeSnapshot().map { script in
            AgentActivityItem(
                id: "project-script:\(script.surfaceID.value.uuidString):\(script.startedAt.timeIntervalSince1970)",
                kind: .notification, workspaceID: script.workspaceID.value, surfaceID: script.surfaceID.value,
                state: .running, title: "Project script: \(PetAttentionRedactor.safeContextLabel(script.name) ?? "Running")",
                workspaceName: context.state.workspaces[script.workspaceID]?.name, occurredAt: script.startedAt, startedAt: script.startedAt
            )
        }

    }

    func list(_ params: [String: JSONValue]) throws -> JSONValue {
        let filter = try ActivityFilter(params: params)
        let snapshotAt = filter.cursor.flatMap(ActivityCursor.init(rawValue:))?.snapshotAt ?? Date()
        let cursor = filter.cursor.flatMap(ActivityCursor.init(rawValue:))
        guard filter.cursor == nil || cursor != nil else { throw JSONRPCError.invalidParams }

        let threads = try AgentThreadRepository(db: readDB).list().filter { !$0.isEphemeral && !AgentThreadTitle.isSubagentThreadTitle($0.title) }
        let threadByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id.description, $0) })
        let runs = try allRuns(threadByID: threadByID)
        let origins = try ActivityOriginProjection.load(db: readDB, threads: threads)
        let runByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.runID.description, $0) })
        let callbacks = try ProviderPendingCallbackRepository(db: readDB).list(states: [.pending, .stale])
        let activeRunByThread = Dictionary(uniqueKeysWithValues: threads.compactMap { thread in
            activeRunIDProvider(thread.id).map { (thread.id.description, $0) }
        })
        let blockedRunIDs = Set(callbacks.compactMap { callback -> AgentRunID? in
            guard callback.state == .pending,
                  let active = activeRunByThread[callback.threadId.description],
                  runByID[active.description]?.status == "running" else { return nil }
            return active
        })
        let resultRepository = AgentRunResultRepository(db: readDB)
        let resultRows = try stride(from: 0, to: runs.count, by: 500).flatMap { start in
            try resultRepository.list(runIds: Array(runs[start..<min(start + 500, runs.count)].map(\.runID)))
        }
        let resultByRun = Dictionary(uniqueKeysWithValues: resultRows.map { ($0.runId.description, $0) })
        let checkpointByRun = try checkpointEvidence(runIDs: runs.map(\.runID))

        var items = runs.compactMap { row -> AgentActivityItem? in
            guard let thread = threadByID[row.threadID.description] else { return nil }
            let result = resultByRun[row.runID.description]
            let state: AgentActivityState
            switch row.status {
            case "pending": state = .queued
            case "running": state = activeRunByThread[row.threadID.description] == row.runID ? .running : .needsYou
            case "completed": state = .completed
            case "failed": state = .failed
            case "interrupted": state = .interrupted
            case "cancelled": state = row.terminalReason == "userStop" ? .stopped : .interrupted
            default: return nil
            }
            let terminal = Self.isTerminal(state)
            let needsAction = state == .needsYou || ((state == .failed || state == .interrupted) && result?.attentionAcknowledgedAt == nil)
            let checkpoint = checkpointByRun[row.runID.description]
            let workspaceName = thread.workspaceId.flatMap { workspaceNames[$0] }
            return AgentActivityItem(
                id: "run:\(row.runID.description)", kind: .agent, runID: row.runID.value,
                workspaceID: thread.workspaceId?.value, threadID: thread.id.value, state: state,
                title: thread.title, workspaceName: workspaceName, provider: thread.provider.rawValue,
                summary: result?.summary ?? (terminal ? "No summary available for this run" : nil),
                occurredAt: row.finishedAt ?? row.startedAt, startedAt: row.startedAt, finishedAt: row.finishedAt,
                viewedAt: result?.viewedAt, attentionAcknowledgedAt: result?.attentionAcknowledgedAt,
                needsAction: needsAction, blocking: blockedRunIDs.contains(row.runID), finalMessageID: result?.finalMessageId?.value,
                checkpointTurnCount: checkpoint?.turnCount, changedFiles: checkpoint?.files ?? [], error: row.error,
                originLabel: origins.labelsByRunID[row.runID.description]
            )
        }

        for callback in callbacks {
            guard let thread = threadByID[callback.threadId.description] else { continue }
            let activeRun = callback.state == .pending ? activeRunByThread[callback.threadId.description] : nil
            let state: AgentActivityState
            if callback.state == .stale || activeRun == nil { state = .expired }
            else { state = callback.kind == .approval ? .waitingApproval : .waitingAnswer }
            let requestID = activeRun.map { "request:\($0.description):\(callback.requestId)" }
                ?? "request:\(callback.threadId.description):\(callback.requestId)"
            items.append(AgentActivityItem(
                id: requestID, kind: .request, runID: activeRun?.value, requestID: callback.requestId,
                workspaceID: thread.workspaceId?.value, threadID: thread.id.value, state: state,
                title: callback.kind == .approval ? "Approval needed" : "Information needed",
                workspaceName: thread.workspaceId.flatMap { workspaceNames[$0] },
                provider: thread.provider.rawValue, occurredAt: callback.createdAt,
                needsAction: true, blocking: activeRun != nil
            ))
        }

        let notifications = try NotificationRepository(db: readDB).list(
            workspaceId: filter.workspaceID.map(WorkspaceID.init), limit: Int.max
        )
        let knownRunIDs = Set(runs.map { $0.runID.description })
        let knownRequestIDs = Set(callbacks.map { "\($0.threadId.description):\($0.requestId)" })
        let notificationStates = try loadNotificationStates(db: readDB)
        let botNotificationMetadata = BotAttentionNotificationMetadataStore(db: readDB).all()
        let canonicalBotAttentionIDs = Set(origins.botRequests.map(\.id))
        for note in notifications {
            let category = note.category.flatMap(PetNotificationCategory.init(rawValue:))
            let payload = Self.notificationPayload(note.body)
            if payload.runID.map(knownRunIDs.contains) == true { continue }
            if let threadID = payload.threadID, let requestID = payload.requestID,
               knownRequestIDs.contains("\(threadID):\(requestID)") { continue }
            let title = category?.presentation.title ?? "Notification"
            let isFailure = category.map(Self.notificationFailureCategories.contains) ?? false
            let state = notificationStates[note.id]
            let botMetadata = botNotificationMetadata[note.id].flatMap { $0.notificationID == note.id ? $0 : nil }
            let canonicalRequestID = botMetadata.map { "bot-attention:\($0.attentionItemID.lowercased())" }
            if let canonicalRequestID, canonicalBotAttentionIDs.contains(canonicalRequestID) { continue }
            let isResolutionRequired = category?.classification == .needsYou && !isFailure && note.readAt == nil
            items.append(AgentActivityItem(
                id: "notification:\(note.id)", kind: .notification, notificationID: note.id, workspaceID: note.workspaceId?.value,
                surfaceID: note.surfaceId?.value, state: isFailure ? .failed : (isResolutionRequired ? .needsYou : .completed), title: title,
                workspaceName: note.workspaceId.flatMap { workspaceNames[$0] },
                summary: category == nil ? nil : (Self.notificationSummary(payload.activitySummary) ?? category?.presentation.detail),
                occurredAt: note.createdAt, finishedAt: isResolutionRequired ? nil : note.createdAt,
                viewedAt: state?.viewedAt,
                attentionAcknowledgedAt: isFailure ? state?.acknowledgedAt : nil,
                needsAction: isResolutionRequired || (isFailure && state?.acknowledgedAt == nil), blocking: false,
                botID: (botMetadata?.botID).flatMap(UUID.init(uuidString:))
            ))
        }

        items.append(contentsOf: registeredScripts)
        items.append(contentsOf: origins.botRequests)
        items.append(contentsOf: origins.scheduledOccurrences)
        items = items.filter { $0.occurredAt <= snapshotAt && filter.matches($0) }
        items.sort(by: Self.activityOrder)
        let counts = Self.counts(for: items)
        let byWorkspace = Dictionary(grouping: items.compactMap { item in
            item.workspaceID.map { ($0.uuidString, item) }
        }, by: { $0.0 }).mapValues { Self.counts(for: $0.map { $0.1 }) }
        let selected: [AgentActivityItem]
        switch filter.section {
        case "running": selected = items.filter { $0.state == .queued || ($0.state == .running && !$0.blocking) }
        case "needs_you": selected = items.filter(\.needsAction)
        case "finished": selected = items.filter { Self.isTerminal($0.state) }
        default: selected = items
        }
        let page = selected.filter { item in
            guard let cursor else { return true }
            return item.occurredAt < cursor.occurredAt || (item.occurredAt == cursor.occurredAt && item.id > cursor.id)
        }
        let limited = Array(page.prefix(filter.limit))
        let next = page.count > filter.limit
            ? limited.last.map { ActivityCursor(occurredAt: $0.occurredAt, id: $0.id, snapshotAt: snapshotAt).rawValue }
            : nil
        return try Self.json(AgentActivityPage(items: limited, nextCursor: next, counts: counts, generatedAt: snapshotAt, workspaceCounts: byWorkspace))
    }

    func setViewed(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let rawIDs = params["item_ids"]?.arrayValue, rawIDs.count <= 200,
              rawIDs.allSatisfy({ $0.stringValue != nil }), let viewed = params["viewed"]?.boolValue else {
            throw JSONRPCError.invalidParams
        }
        let ids = rawIDs.compactMap(\.stringValue)
        guard Set(ids).count == ids.count else { throw JSONRPCError.invalidParams }
        let runIDs = try ids.filter { $0.hasPrefix("run:") }.map { id -> AgentRunID in
            guard let uuid = UUID(uuidString: String(id.dropFirst(4))) else { throw JSONRPCError.invalidParams }
            return AgentRunID(uuid)
        }
        let notificationIDs = ids.filter { $0.hasPrefix("notification:") }.map { String($0.dropFirst("notification:".count)) }
        let scheduledIDs = ids.filter { $0.hasPrefix("scheduled-occurrence:") }.map { String($0.dropFirst("scheduled-occurrence:".count)) }
        guard runIDs.count + notificationIDs.count + scheduledIDs.count == ids.count else { throw JSONRPCError.invalidParams }
        var restoreRuns = [AgentRunID: Date?]()
        var restoreNotifications = [String: Date?]()
        var restoreScheduled = [String: Date?]()
        if let rawRestore = params["restore_viewed_at"] {
            guard let map = rawRestore.objectValue else { throw JSONRPCError.invalidParams }
            for (id, value) in map {
                guard ids.contains(id) else { throw JSONRPCError.invalidParams }
                let date: Date?
                if case .null = value { date = nil }
                else if let text = value.stringValue, let parsed = Self.parseDate(text) { date = parsed }
                else { throw JSONRPCError.invalidParams }
                if id.hasPrefix("run:") {
                    guard let uuid = UUID(uuidString: String(id.dropFirst(4))) else { throw JSONRPCError.invalidParams }
                    restoreRuns.updateValue(date, forKey: AgentRunID(uuid))
                } else if id.hasPrefix("notification:") {
                    restoreNotifications.updateValue(date, forKey: String(id.dropFirst("notification:".count)))
                } else if id.hasPrefix("scheduled-occurrence:") {
                    restoreScheduled.updateValue(date, forKey: String(id.dropFirst("scheduled-occurrence:".count)))
                } else { throw JSONRPCError.invalidParams }
            }
        }
        let operationAt = viewed ? Date() : nil
        let operationTimestamp = operationAt.map(Self.isoFractionalString)
        let changed = try db.performSync { database in
            try database.transaction {
                let runStatus = try database.prepare("SELECT status FROM agent_runs WHERE id = ?;")
                for runID in runIDs {
                    try runStatus.bind(1, runID.description)
                    guard try runStatus.step(), ["completed", "failed", "interrupted", "cancelled"].contains(runStatus.columnText(0) ?? "") else {
                        throw JSONRPCError.invalidParams
                    }
                    runStatus.reset()
                }
                let scheduledExists = try database.prepare("SELECT status FROM scheduled_task_runs WHERE id = ? AND agent_run_id IS NULL;")
                for id in scheduledIDs {
                    try scheduledExists.bind(1, id)
                    guard try scheduledExists.step(), ["completed", "failed", "cancelled"].contains(scheduledExists.columnText(0) ?? "") else { throw JSONRPCError.invalidParams }
                    scheduledExists.reset()
                }
                let notificationExists = try database.prepare("SELECT category FROM notifications WHERE id = ? AND dismissed_at IS NULL;")
                for id in notificationIDs {
                    try notificationExists.bind(1, id)
                    guard try notificationExists.step() else { throw JSONRPCError.invalidParams }
                    notificationExists.reset()
                }
                let ensureResult = try database.prepare("INSERT OR IGNORE INTO agent_run_results(run_id) SELECT id FROM agent_runs WHERE id = ?;")
                for runID in runIDs {
                    try ensureResult.bind(1, runID.description); _ = try ensureResult.step(); ensureResult.reset()
                }
                let stamp = operationTimestamp
                let runUpdate = try database.prepare("UPDATE agent_run_results SET viewed_at = ? WHERE run_id = ?;")
                for runID in runIDs where restoreRuns[runID] == nil {
                    try runUpdate.bind(1, stamp); try runUpdate.bind(2, runID.description); _ = try runUpdate.step(); runUpdate.reset()
                }
                for (runID, date) in restoreRuns {
                    try runUpdate.bind(1, date.map(Self.isoFractionalString)); try runUpdate.bind(2, runID.description)
                    _ = try runUpdate.step(); runUpdate.reset()
                }
                let notificationUpdate = try database.prepare("INSERT INTO activity_notification_state(viewed_at, item_id) VALUES (?, ?) ON CONFLICT(item_id) DO UPDATE SET viewed_at = excluded.viewed_at;")
                for id in notificationIDs where restoreNotifications[id] == nil {
                    try notificationUpdate.bind(1, stamp); try notificationUpdate.bind(2, id); _ = try notificationUpdate.step(); notificationUpdate.reset()
                }
                for (id, date) in restoreNotifications {
                    try notificationUpdate.bind(1, date.map(Self.isoFractionalString)); try notificationUpdate.bind(2, id)
                    _ = try notificationUpdate.step(); notificationUpdate.reset()
                }
                for id in scheduledIDs where restoreScheduled[id] == nil {
                    try notificationUpdate.bind(1, stamp); try notificationUpdate.bind(2, "activity:scheduled-occurrence:\(id)")
                    _ = try notificationUpdate.step(); notificationUpdate.reset()
                }
                for (id, date) in restoreScheduled {
                    try notificationUpdate.bind(1, date.map(Self.isoFractionalString)); try notificationUpdate.bind(2, "activity:scheduled-occurrence:\(id)")
                    _ = try notificationUpdate.step(); notificationUpdate.reset()
                }
                return ids
            }
        }
        return .object(["updated_ids": .array(changed.map(JSONValue.string)), "viewed_at": operationAt.map { .string(Self.isoFractionalString($0)) } ?? .null])
    }

    func acknowledge(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let id = params["item_id"]?.stringValue else { throw JSONRPCError.invalidParams }
        if id.hasPrefix("run:"), let uuid = UUID(uuidString: String(id.dropFirst(4))) {
            guard try AgentRunResultRepository(db: db).acknowledgeFailure(runId: AgentRunID(uuid)) else {
                throw JSONRPCError.invalidParams
            }
        } else if id.hasPrefix("scheduled-occurrence:") {
            let occurrenceID = String(id.dropFirst("scheduled-occurrence:".count))
            try db.performSync { database in
                try database.transaction {
                    let occurrence = try database.prepare("SELECT status FROM scheduled_task_runs WHERE id = ? AND agent_run_id IS NULL;")
                    try occurrence.bind(1, occurrenceID)
                    guard try occurrence.step(), occurrence.columnText(0) == "failed" else { throw JSONRPCError.invalidParams }
                    let acknowledge = try database.prepare("INSERT INTO activity_notification_state(item_id, acknowledged_at) VALUES (?, ?) ON CONFLICT(item_id) DO UPDATE SET acknowledged_at = excluded.acknowledged_at;")
                    try acknowledge.bind(1, "activity:scheduled-occurrence:\(occurrenceID)")
                    try acknowledge.bind(2, Self.isoFractionalString(Date()))
                    _ = try acknowledge.step()
                }
            }
        } else if id.hasPrefix("notification:") {
            let notificationID = String(id.dropFirst("notification:".count))
            try db.performSync { db in
                try db.transaction {
                    let note = try db.prepare("SELECT category, read_at FROM notifications WHERE id = ? AND dismissed_at IS NULL;")
                    try note.bind(1, notificationID)
                    guard try note.step(), let category = note.columnText(0).flatMap(PetNotificationCategory.init(rawValue:)),
                          Self.notificationFailureCategories.contains(category) else { throw JSONRPCError.invalidParams }
                    let priorViewed = note.columnText(1)
                    note.reset()
                    let acknowledge = try db.prepare("INSERT INTO activity_notification_state(item_id, viewed_at, acknowledged_at) VALUES (?, ?, ?) ON CONFLICT(item_id) DO UPDATE SET acknowledged_at = excluded.acknowledged_at;")
                    try acknowledge.bind(1, notificationID)
                    try acknowledge.bind(2, priorViewed)
                    try acknowledge.bind(3, Self.isoFractionalString(Date()))
                    _ = try acknowledge.step()
                }
            }
        } else {
            throw JSONRPCError.invalidParams
        }
        return .object(["acknowledged": .bool(true), "item_id": .string(id)])
    }

    private struct RunRow {
        let runID: AgentRunID
        let threadID: AgentThreadID
        let status: String
        let terminalReason: String
        let startedAt: Date
        let finishedAt: Date?
        let error: String?
    }

    private func allRuns(threadByID: [String: AgentThread]) throws -> [RunRow] {
        try readDB.performSync { db in
            let statement = try db.prepare("SELECT id, thread_id, status, started_at, finished_at, error_message, terminal_reason FROM agent_runs ORDER BY started_at DESC;")
            var rows = [RunRow]()
            while try statement.step() {
                guard let runRaw = statement.columnText(0), let runUUID = UUID(uuidString: runRaw),
                      let threadRaw = statement.columnText(1), let thread = threadByID[threadRaw],
                      let startedRaw = statement.columnText(3), let started = Self.parseDate(startedRaw),
                      let status = statement.columnText(2) else { continue }
                rows.append(RunRow(runID: AgentRunID(runUUID), threadID: thread.id, status: status,
                                   terminalReason: statement.columnText(6) ?? "", startedAt: started,
                                   finishedAt: statement.columnText(4).flatMap(Self.parseDate), error: statement.columnText(5)))
            }
            return rows
        }
    }

    private struct CheckpointEvidence { let turnCount: Int; let files: [String] }
    private func checkpointEvidence(runIDs: [AgentRunID]) throws -> [String: CheckpointEvidence] {
        guard !runIDs.isEmpty else { return [:] }
        return try readDB.performSync { db in
            var evidence = [String: CheckpointEvidence]()
            for start in stride(from: 0, to: runIDs.count, by: 500) {
                let batch = Array(runIDs[start..<min(start + 500, runIDs.count)])
                let statement = try db.prepare("SELECT run_id, checkpoint_turn_count, files_json FROM agent_turn_checkpoints WHERE run_id IN (\(Array(repeating: "?", count: batch.count).joined(separator: ","))) ORDER BY completed_at DESC;")
                for (offset, runID) in batch.enumerated() { try statement.bind(Int32(offset + 1), runID.description) }
                while try statement.step() {
                    guard let runID = statement.columnText(0), evidence[runID] == nil else { continue }
                    let turnCount = Int(statement.columnInt64(1))
                    let filesJSON = statement.columnText(2) ?? "[]"
                    let files = (try? JSONDecoder().decode([AgentTurnCheckpointFile].self, from: Data(filesJSON.utf8)))?.map(\.path) ?? []
                    evidence[runID] = CheckpointEvidence(turnCount: turnCount, files: files)
                }
            }
            return evidence
        }
    }

    private struct NotificationState { let viewedAt: Date?; let acknowledgedAt: Date? }

    private func loadNotificationStates(db: SQLiteDB) throws -> [String: NotificationState] {
        try db.performSync { database in
            let statement = try database.prepare("SELECT item_id, viewed_at, acknowledged_at FROM activity_notification_state;")
            defer { statement.reset() }
            var states = [String: NotificationState]()
            while try statement.step() {
                let id = statement.columnText(0) ?? ""
                states[id] = NotificationState(
                    viewedAt: statement.columnText(1).flatMap(Self.parseDate),
                    acknowledgedAt: statement.columnText(2).flatMap(Self.parseDate)
                )
            }
            return states
        }
    }

    private static let notificationFailureCategories: Set<PetNotificationCategory> = [
        .gitFailed, .projectScriptFailed, .sshTransferFailed, .providerUpdateFailed, .serverListenerFailed
    ]

    private static func notificationSummary(_ value: String?) -> String? {
        value.flatMap(AgentRunResultRepository.safeSummary)
    }

    private static func notificationPayload(_ body: String?) -> (runID: String?, requestID: String?, threadID: String?, activitySummary: String?) {
        guard let body, let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil, nil, nil) }
        let run = (object["run_id"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }
        let request = object["request_id"] as? String
        return (run, request, (object["thread_id"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }, object["activity_summary"] as? String)
    }
    private static func counts(for items: [AgentActivityItem]) -> AgentActivityCounts {
        AgentActivityCounts(
            running: items.filter { $0.state == .running && !$0.blocking }.count,
            queued: items.filter { $0.state == .queued }.count,
            needsYou: items.filter(\.needsAction).count,
            finished: items.filter { Self.isTerminal($0.state) }.count,
            newResults: items.filter { $0.finishedAt != nil && $0.viewedAt == nil }.count
        )
    }

    private static func isTerminal(_ state: AgentActivityState) -> Bool {
        [.completed, .failed, .interrupted, .stopped].contains(state)
    }
    private static func activityOrder(_ lhs: AgentActivityItem, _ rhs: AgentActivityItem) -> Bool {
        lhs.occurredAt == rhs.occurredAt ? lhs.id < rhs.id : lhs.occurredAt > rhs.occurredAt
    }
    nonisolated private static func isoFractionalString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    nonisolated fileprivate static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, output in
            var container = output.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}

private struct ActivityFilter {
    let workspaceID: UUID?
    let section: String
    let search: String
    let outcome: String?
    let since: Date?
    let cursor: String?
    let limit: Int
    init(params: [String: JSONValue]) throws {
        if let raw = params["workspace_id"]?.stringValue, let uuid = UUID(uuidString: raw) { workspaceID = uuid }
        else if params["workspace_id"] != nil { throw JSONRPCError.invalidParams }
        else { workspaceID = nil }
        section = params["section"]?.stringValue ?? "all"
        guard ["all", "running", "needs_you", "finished"].contains(section) else { throw JSONRPCError.invalidParams }
        search = params["search"]?.stringValue?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) ?? ""
        outcome = params["outcome"]?.stringValue
        guard outcome == nil || ["completed", "failed", "interrupted", "stopped"].contains(outcome!) else { throw JSONRPCError.invalidParams }
        if let value = params["since"]?.stringValue { since = ActivityService.parseDate(value); guard since != nil else { throw JSONRPCError.invalidParams } } else { since = nil }
        cursor = params["cursor"]?.stringValue
        let requested = params["limit"]?.intValue ?? 50
        guard requested > 0 else { throw JSONRPCError.invalidParams }
        limit = min(requested, 50)
    }
    func matches(_ item: AgentActivityItem) -> Bool {
        if let workspaceID, item.workspaceID != workspaceID { return false }
        if let since, item.occurredAt < since { return false }
        if let outcome, item.state.rawValue != outcome { return false }
        return search.isEmpty || item.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(search) || (item.summary?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(search) ?? false)
    }
}

private struct ActivityCursor {
    let occurredAt: Date
    let id: String
    let snapshotAt: Date
    init(occurredAt: Date, id: String, snapshotAt: Date) {
        self.occurredAt = occurredAt; self.id = id; self.snapshotAt = snapshotAt
    }
    init?(rawValue: String) {
        guard let data = Data(base64Encoded: rawValue),
              let object = try? JSONDecoder().decode(CursorWire.self, from: data) else { return nil }
        occurredAt = Date(timeIntervalSince1970: Double(bitPattern: object.occurredAtBits))
        snapshotAt = Date(timeIntervalSince1970: Double(bitPattern: object.snapshotBits))
        id = object.id
    }
    var rawValue: String {
        let wire = CursorWire(occurredAtBits: occurredAt.timeIntervalSince1970.bitPattern,
                              snapshotBits: snapshotAt.timeIntervalSince1970.bitPattern, id: id)
        return (try? JSONEncoder().encode(wire).base64EncodedString()) ?? ""
    }
    private struct CursorWire: Codable { let occurredAtBits: UInt64; let snapshotBits: UInt64; let id: String }
}
