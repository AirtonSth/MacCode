import Foundation
import CoreModel
import Darwin
import CryptoKit

// PERF: ISO8601DateFormatter is expensive and not thread-safe. The
// persistence layer shares one formatter per process to avoid per-row
// allocation, but Repositories are accessed from multiple queues. Wrap
// the shared formatters with a short NSLock so concurrent
// string(from:)/date(from:) are safe without per-call allocation.
final class LockedISO8601Formatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter
    init(_ formatter: ISO8601DateFormatter) { self.formatter = formatter }
    func string(from date: Date) -> String { lock.lock(); defer { lock.unlock() }; return formatter.string(from: date) }
    func date(from string: String) -> Date? { lock.lock(); defer { lock.unlock() }; return formatter.date(from: string) }
}

let iso = LockedISO8601Formatter(ISO8601DateFormatter())
/// Accept fractional ISO-8601 on read so checkpoint keyset timestamps that
/// store sub-second precision still decode correctly on legacy list/detail paths.
private let isoFractional = LockedISO8601Formatter({
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}())

public enum PersistenceDataError: Error, CustomStringConvertible {
    case corruptProviderEventLog(String)
    case corruptCheckpoint(String)
    case corruptStreamEvent(String)

    public var description: String {
        switch self {
        case .corruptProviderEventLog(let message):
            return "Corrupt provider event log: \(message)"
        case .corruptCheckpoint(let message):
            return "Corrupt agent checkpoint: \(message)"
        case .corruptStreamEvent(let message):
            return "Corrupt agent stream event: \(message)"
        }
    }
}

/// Typed failures for `agent.checkpoint.list` response_version 1 read path.
public enum AgentTurnCheckpointListError: Error, Equatable, CustomStringConvertible {
    /// Client `catalog_revision` does not match the live fence for this thread.
    /// Raised inside the read snapshot **before** page row scan/decode.
    case staleCatalogRevision(current: Int64)

    public var description: String {
        switch self {
        case .staleCatalogRevision(let current):
            return "checkpoint list catalog revision is stale (current=\(current))"
        }
    }
}

public enum AgentRoutingPersistenceError: Error, Equatable {
    case invalidConfigurationJSON
    case invalidMode(String)
    case modeConflict(column: AgentRoutingMode, configuration: AgentRoutingMode)
    case revisionConflict(column: Int, configuration: Int)
}

private func parseDate(_ s: String?) -> Date {
    guard let s else { return Date() }
    if let d = isoFractional.date(from: s) { return d }
    if let d = iso.date(from: s) { return d }
    return Date()
}

// PERF: agent-thread model selection / run-as-user / routing row fields each
// allocated JSONDecoder/JSONEncoder on every list/get/upsert. Shared process-
// wide pair under a short lock (codecs are not thread-safe); wire JSON
// formatting unchanged.
private let agentThreadJSONCodecLock = NSLock()
private let agentThreadJSONDecoder = JSONDecoder()
private let agentThreadJSONEncoder = JSONEncoder()

private func encodeModelSelection(_ selection: AgentModelSelection) -> String? {
    agentThreadJSONCodecLock.lock()
    let data = try? agentThreadJSONEncoder.encode(selection)
    agentThreadJSONCodecLock.unlock()
    guard let data else { return nil }
    return String(data: data, encoding: .utf8)
}

private func decodeModelSelection(
    _ json: String?,
    provider: AgentProvider,
    model: String,
    reasoningEffort: AgentReasoningEffort,
    serviceTier: AgentServiceTier
) -> AgentModelSelection {
    if let json,
       let data = json.data(using: .utf8) {
        agentThreadJSONCodecLock.lock()
        let selection = try? agentThreadJSONDecoder.decode(AgentModelSelection.self, from: data)
        agentThreadJSONCodecLock.unlock()
        if let selection { return selection }
    }
    return AgentModelSelection(
        provider: provider,
        modelId: model,
        reasoningEffort: reasoningEffort,
        serviceTier: serviceTier
    )
}

private func encodeRunAsUser(_ user: AgentRunAsUser?) -> String? {
    guard let user else { return nil }
    agentThreadJSONCodecLock.lock()
    let data = try? agentThreadJSONEncoder.encode(user)
    agentThreadJSONCodecLock.unlock()
    guard let data else { return nil }
    return String(data: data, encoding: .utf8)
}

private func decodeRunAsUser(_ json: String?) -> AgentRunAsUser? {
    guard let json,
          let data = json.data(using: .utf8) else {
        return nil
    }
    agentThreadJSONCodecLock.lock()
    let user = try? agentThreadJSONDecoder.decode(AgentRunAsUser.self, from: data)
    agentThreadJSONCodecLock.unlock()
    return user
}

private func encodeRoutingConfiguration(_ configuration: AgentRoutingConfiguration) throws -> String {
    agentThreadJSONCodecLock.lock()
    defer { agentThreadJSONCodecLock.unlock() }
    let data = try agentThreadJSONEncoder.encode(configuration)
    guard let json = String(data: data, encoding: .utf8) else {
        throw AgentRoutingPersistenceError.invalidConfigurationJSON
    }
    return json
}

private func decodeRoutingConfiguration(
    json: String?,
    storedMode: String?,
    storedRevision: Int?
) throws -> AgentRoutingConfiguration {
    guard let json,
          let data = json.data(using: .utf8) else {
        throw AgentRoutingPersistenceError.invalidConfigurationJSON
    }
    agentThreadJSONCodecLock.lock()
    let configuration = try? agentThreadJSONDecoder.decode(AgentRoutingConfiguration.self, from: data)
    agentThreadJSONCodecLock.unlock()
    guard let configuration else {
        throw AgentRoutingPersistenceError.invalidConfigurationJSON
    }
    guard let storedMode else { return configuration }
    guard let mode = AgentRoutingMode(rawValue: storedMode) else {
        throw AgentRoutingPersistenceError.invalidMode(storedMode)
    }
    guard mode == configuration.mode else {
        throw AgentRoutingPersistenceError.modeConflict(column: mode, configuration: configuration.mode)
    }
    if let storedRevision, storedRevision != configuration.revision {
        throw AgentRoutingPersistenceError.revisionConflict(column: storedRevision, configuration: configuration.revision)
    }
    return configuration
}

public final class ProjectRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public struct Project: Codable, Equatable {
        public let id: ProjectID
        public var name: String
        public var path: String
        public var favorite: Bool
        public var createdAt: Date
        public var updatedAt: Date
    }

    public func upsert(_ p: Project) throws {
        let st = try db.prepare("""
            INSERT INTO projects(id, name, path, favorite, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, path=excluded.path, favorite=excluded.favorite, updated_at=excluded.updated_at;
        """)
        try st.bind(1, p.id.value.uuidString)
        try st.bind(2, p.name)
        try st.bind(3, p.path)
        try st.bind(4, p.favorite)
        try st.bind(5, iso.string(from: p.createdAt))
        try st.bind(6, iso.string(from: p.updatedAt))
        _ = try st.step()
    }

    public func list() throws -> [Project] {
        let st = try db.prepare("SELECT id, name, path, favorite, created_at, updated_at FROM projects ORDER BY updated_at DESC;")
        var out: [Project] = []
        while try st.step() {
            let id = ProjectID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID())
            out.append(Project(
                id: id,
                name: st.columnText(1) ?? "",
                path: st.columnText(2) ?? "",
                favorite: st.columnInt64(3) != 0,
                createdAt: parseDate(st.columnText(4)),
                updatedAt: parseDate(st.columnText(5))
            ))
        }
        return out
    }
}

public enum AgentThreadForkIntentState: String, Codable, Sendable, Equatable {
    case prepared
    case providerCreated = "provider_created"
    case localCommitted = "local_committed"
    case compensating
    case compensated
    case abandoned
}

public struct AgentThreadForkIntent: Codable, Sendable, Equatable {
    public let sourceThreadId: AgentThreadID
    public let childThread: AgentThread
    public let sourceMessages: [AgentMessage]
    public let provider: AgentProvider
    public let idempotencyKey: String
    public let state: AgentThreadForkIntentState
    /// `prepared` alone is not proof that an adapter was never called: a crash
    /// can land after a provider accepts the stable key but before its child id
    /// is durably recorded. New intents start false and flip before that call;
    /// legacy rows migrate as true so they remain ambiguity-safe.
    public let providerCreationAttempted: Bool
    public let providerChildThreadId: String?
    public let lastError: String?
    public let createdAt: Date
    public let updatedAt: Date
}

public struct AgentThreadCapacityDiagnostics: Equatable, Sendable {
    public let protectedCounts: [String: Int]

    public init(protectedCounts: [String: Int] = [:]) {
        self.protectedCounts = protectedCounts.filter { $0.value > 0 }
    }

}

public enum AgentThreadCapacityError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case workspaceLimitExceeded(
        workspaceId: WorkspaceID,
        limit: Int,
        actualCount: Int,
        diagnostics: AgentThreadCapacityDiagnostics = AgentThreadCapacityDiagnostics()
    )

    public var description: String {
        switch self {
        case .workspaceLimitExceeded(_, let limit, let actualCount, let diagnostics):
            let categories = diagnostics.protectedCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            let detail = categories.isEmpty ? "" : " Protected: \(categories)."
            return "Agent thread capacity reached: \(actualCount) threads for a hard limit of \(limit). No reclaimable terminal thread is safe to remove (running, pinned, draft, worktree, or bound). Close or unpin a thread, then retry.\(detail)"
        }
    }

    public var errorDescription: String? { description }
}

public final class AgentThreadRepository {
    /// Best-effort retention cap: keep each workspace's disposable empty shells
    /// bounded without deleting user-owned or operational state.
    /// Hard product ceiling: at most 5 threads per workspace (storage pressure).
    public static let maxThreadsPerWorkspace = 5
    /// Each maintenance transaction processes at most this many historical
    /// terminal rows. This bounds work, not eligibility: recoverable rows are
    /// never candidates regardless of age or count.
    public static let terminalForkIntentCleanupBatchSize = 16

    public struct ForkIntentMaintenanceBatch: Equatable, Sendable {
        public let scrubbedCount: Int
        public let deletedCount: Int
        public let hasMore: Bool

        public var processedCount: Int { scrubbedCount + deletedCount }
    }

    let db: SQLiteDB
    // PERF: prepareForkIntent / getForkIntent allocated JSONEncoder (sortedKeys)
    // and JSONDecoder per fork admission/load. Shared pair under a short lock
    // (codecs are not thread-safe); sortedKeys formatting unchanged for wire
    // child/source-message snapshots.
    private let forkCodecLock = NSLock()
    private let forkDecoder = JSONDecoder()
    private let forkEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public init(db: SQLiteDB) { self.db = db }

    /// Live Agent App bindings are process state, not a new persistence model.
    /// Binding updates take this same lock before changing visible selection;
    /// cap victim selection holds it through the guarded DELETE transaction.
    public func setLiveSurfaceBinding(surfaceID: SurfaceID, threadID: AgentThreadID?) {
        db.setLiveAgentThreadBinding(surfaceID: surfaceID, threadID: threadID)
    }

    public var liveSurfaceBoundThreadIDsForTesting: Set<AgentThreadID> {
        db.withLiveAgentThreadBindings { $0 }
    }

    private func withLiveSurfaceBindingsLocked<T>(
        _ body: (Set<AgentThreadID>) throws -> T
    ) rethrows -> T {
        try db.withLiveAgentThreadBindings(body)
    }

    public func upsert(_ t: AgentThread) throws {
        let st = try db.prepare("""
            INSERT INTO agent_threads(id, project_id, workspace_id, title, provider, provider_instance_id, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread, color, pinned, sort_order, permission_mode, reasoning_effort, execution_mode, base_branch, worktree_path, service_tier, model_selection_json, interaction_mode, run_as_user_json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, provider=excluded.provider, provider_instance_id=excluded.provider_instance_id, model=excluded.model, provider_thread_id=excluded.provider_thread_id, status=excluded.status, updated_at=excluded.updated_at, diff_additions=excluded.diff_additions, diff_deletions=excluded.diff_deletions, has_unread=excluded.has_unread, color=excluded.color, pinned=excluded.pinned, sort_order=excluded.sort_order, permission_mode=excluded.permission_mode, reasoning_effort=excluded.reasoning_effort, execution_mode=excluded.execution_mode, base_branch=excluded.base_branch, worktree_path=excluded.worktree_path, service_tier=excluded.service_tier, model_selection_json=excluded.model_selection_json, interaction_mode=excluded.interaction_mode, run_as_user_json=excluded.run_as_user_json;
        """)
        try st.bind(1, t.id.value.uuidString)
        try st.bind(2, t.projectId?.value.uuidString)
        try st.bind(3, t.workspaceId?.value.uuidString)
        try st.bind(4, t.title)
        try st.bind(5, t.provider.rawValue)
        try st.bind(6, t.providerInstanceId ?? t.provider.rawValue)
        try st.bind(7, t.model)
        try st.bind(8, t.providerThreadId)
        try st.bind(9, t.status.rawValue)
        try st.bind(10, iso.string(from: t.createdAt))
        try st.bind(11, iso.string(from: t.updatedAt))
        try st.bind(12, Int64(t.diffAdditions))
        try st.bind(13, Int64(t.diffDeletions))
        try st.bind(14, t.hasUnread)
        try st.bind(15, t.color)
        try st.bind(16, t.pinned)
        try st.bind(17, Int64(t.sortOrder))
        try st.bind(18, t.permissionMode.rawValue)
        try st.bind(19, t.reasoningEffort.rawValue)
        try st.bind(20, t.executionMode.rawValue)
        try st.bind(21, t.baseBranch)
        try st.bind(22, t.worktreePath)
        try st.bind(23, t.serviceTier.rawValue)
        try st.bind(24, encodeModelSelection(t.modelSelection))
        try st.bind(25, t.effectiveInteractionMode.rawValue)
        try st.bind(26, encodeRunAsUser(t.runAsUser))
        _ = try st.step()

        if let routingConfiguration = t.routingConfiguration {
            let routing = try db.prepare("""
                INSERT INTO agent_thread_routing(thread_id, mode, configuration_json, revision, updated_at)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(thread_id) DO UPDATE SET
                    mode=excluded.mode,
                    configuration_json=excluded.configuration_json,
                    revision=excluded.revision,
                    updated_at=excluded.updated_at;
            """)
            try routing.bind(1, t.id.value.uuidString)
            try routing.bind(2, routingConfiguration.mode.rawValue)
            try routing.bind(3, try encodeRoutingConfiguration(routingConfiguration))
            try routing.bind(4, routingConfiguration.revision)
            try routing.bind(5, iso.string(from: routingConfiguration.updatedAt))
            _ = try routing.step()
        } else {
            let routing = try db.prepare("DELETE FROM agent_thread_routing WHERE thread_id = ?;")
            try routing.bind(1, t.id.value.uuidString)
            _ = try routing.step()
        }
    }

    /// Hard workspace cap: reclaim oldest *terminal* threads (including those with
    /// history) when over the limit. Protected and never auto-deleted:
    /// running/pending, pinned, durable drafts, worktrees, recoverable fork
    /// intents, and live surface bindings (excluded via the live-binding set).
    /// Keep this predicate shared by preflight, selection, and the guarded DELETE.
    private func workspaceThreadLimitEligibilityPredicate(candidateAlias: String) -> String {
        """
        -- Everything except an active run is reclaimable under the hard 5-thread
        -- ceiling (includes pending shells and completed history with messages).
        AND \(candidateAlias).status NOT IN ('running')
        AND \(candidateAlias).pinned = 0
        AND NULLIF(TRIM(COALESCE(\(candidateAlias).worktree_path, '')), '') IS NULL
        AND NOT EXISTS (
            SELECT 1 FROM agent_thread_drafts AS draft
            WHERE draft.thread_id = \(candidateAlias).id
              AND (
                  LENGTH(TRIM(COALESCE(draft.text, ''))) > 0
                  OR CASE
                      WHEN json_valid(COALESCE(draft.attachments_json, '')) = 1
                      THEN CASE
                          WHEN json_type(draft.attachments_json) = 'array'
                          THEN json_array_length(draft.attachments_json) > 0
                          ELSE 1
                      END
                      ELSE LENGTH(TRIM(COALESCE(draft.attachments_json, ''))) > 0
                  END
              )
        )
        AND NOT EXISTS (
            SELECT 1 FROM agent_thread_fork_intents AS intent
            WHERE intent.state IN ('prepared', 'provider_created', 'compensating')
              AND (intent.source_thread_id = \(candidateAlias).id
                   OR intent.child_thread_id = \(candidateAlias).id)
        )
        AND NOT EXISTS (
            SELECT 1
            FROM session_snapshots AS snapshot, json_tree(snapshot.payload_json) AS value
            WHERE snapshot.id = (SELECT MAX(id) FROM session_snapshots)
              AND json_valid(snapshot.payload_json) = 1
              AND value.type = 'text'
              AND value.atom = \(candidateAlias).id
        )
        """
    }

    private func workspaceThreadCapacityDiagnostics(
        workspaceId: WorkspaceID,
        liveSurfaceBindings: Set<AgentThreadID>
    ) throws -> AgentThreadCapacityDiagnostics {
        func count(_ predicate: String) throws -> Int {
            let statement = try db.prepare("""
                SELECT COUNT(*) FROM agent_threads AS candidate
                WHERE candidate.workspace_id = ? AND (\(predicate));
            """)
            try statement.bind(1, workspaceId.value.uuidString)
            return try statement.step() ? Int(statement.columnInt64(0)) : 0
        }

        var counts: [String: Int] = [:]
        counts["active"] = try count("candidate.status IN ('running', 'pending')")
        counts["pinned"] = try count("candidate.pinned != 0")
        counts["history"] = try count("EXISTS (SELECT 1 FROM agent_messages AS message WHERE message.thread_id = candidate.id)")
        counts["draft_or_worktree"] = try count("""
            NULLIF(TRIM(COALESCE(candidate.worktree_path, '')), '') IS NOT NULL
            OR EXISTS (
                SELECT 1 FROM agent_thread_drafts AS draft
                WHERE draft.thread_id = candidate.id
                  AND (LENGTH(TRIM(COALESCE(draft.text, ''))) > 0
                       OR LENGTH(TRIM(COALESCE(draft.attachments_json, '[]'))) > 2)
            )
        """)
        counts["fork_recovery"] = try count("""
            EXISTS (
                SELECT 1 FROM agent_thread_fork_intents AS intent
                WHERE intent.source_thread_id = candidate.id
                   OR intent.child_thread_id = candidate.id
            )
        """)
        counts["runtime_or_queue"] = try count("""
            EXISTS (SELECT 1 FROM agent_runs AS run WHERE run.thread_id = candidate.id)
            OR EXISTS (SELECT 1 FROM provider_session_runtime AS session WHERE session.thread_id = candidate.id)
            OR EXISTS (SELECT 1 FROM provider_pending_callbacks AS callback WHERE callback.thread_id = candidate.id)
            OR EXISTS (SELECT 1 FROM agent_queued_messages AS queued WHERE queued.thread_id = candidate.id)
        """)
        counts["plan_or_checkpoint"] = try count("""
            EXISTS (SELECT 1 FROM agent_proposed_plans AS plan WHERE plan.thread_id = candidate.id OR plan.implementation_thread_id = candidate.id)
            OR EXISTS (SELECT 1 FROM agent_turn_checkpoints AS checkpoint WHERE checkpoint.thread_id = candidate.id)
            OR EXISTS (SELECT 1 FROM agent_turn_checkpoint_catalog_meta AS catalog WHERE catalog.thread_id = candidate.id)
        """)

        var boundIDs = liveSurfaceBindings
        let persisted = try db.prepare("""
            SELECT DISTINCT candidate.id
            FROM agent_threads AS candidate,
                 session_snapshots AS snapshot,
                 json_tree(snapshot.payload_json) AS value
            WHERE candidate.workspace_id = ?
              AND snapshot.id = (SELECT MAX(id) FROM session_snapshots)
              AND json_valid(snapshot.payload_json) = 1
              AND value.type = 'text'
              AND value.atom = candidate.id;
        """)
        try persisted.bind(1, workspaceId.value.uuidString)
        while try persisted.step() {
            if let uuid = persisted.columnText(0).flatMap(UUID.init(uuidString:)) {
                boundIDs.insert(AgentThreadID(uuid))
            }
        }
        let workspaceThreadIDs = Set(try list(workspaceId: workspaceId).map(\.id))
        counts["surface_bound"] = boundIDs.intersection(workspaceThreadIDs).count
        return AgentThreadCapacityDiagnostics(protectedCounts: counts)
    }

    private func workspaceThreadCapacityError(
        workspaceId: WorkspaceID,
        limit: Int,
        actualCount: Int,
        liveSurfaceBindings: Set<AgentThreadID>
    ) throws -> AgentThreadCapacityError {
        .workspaceLimitExceeded(
            workspaceId: workspaceId,
            limit: limit,
            actualCount: actualCount,
            diagnostics: try workspaceThreadCapacityDiagnostics(
                workspaceId: workspaceId,
                liveSurfaceBindings: liveSurfaceBindings
            )
        )
    }

    /// Cheap fail-fast check before a producer performs irreversible or
    /// expensive work. The capped transaction remains authoritative for races.
    public func preflightWorkspaceThreadInsertion(
        workspaceId: WorkspaceID,
        prospectiveThreadId: AgentThreadID? = nil,
        excludedVictimIDs: Set<AgentThreadID> = [],
        limit: Int = AgentThreadRepository.maxThreadsPerWorkspace
    ) throws {
        let cap = max(1, limit)
        try withLiveSurfaceBindingsLocked { liveBindings in
            try db.performSync { _ in
                let total = try count(workspaceId: workspaceId)
                let prospectiveExists: Bool
                if let prospectiveThreadId {
                    prospectiveExists = try get(id: prospectiveThreadId)?.workspaceId == workspaceId
                } else {
                    prospectiveExists = false
                }
                let projectedCount = total + (prospectiveExists ? 0 : 1)
                let requiredVictims = max(0, projectedCount - cap)
                guard requiredVictims > 0 else { return }

                var excludedIDs = excludedVictimIDs.union(liveBindings)
                if let prospectiveThreadId { excludedIDs.insert(prospectiveThreadId) }
                let excludedRawIDs = excludedIDs.map { $0.value.uuidString }.sorted()
                let exclusion = excludedRawIDs.isEmpty
                    ? ""
                    : "AND candidate.id NOT IN (\(Array(repeating: "?", count: excludedRawIDs.count).joined(separator: ", ")))"
                let statement = try db.prepare("""
                    SELECT COUNT(*) FROM agent_threads AS candidate
                    WHERE candidate.workspace_id = ?
                      \(workspaceThreadLimitEligibilityPredicate(candidateAlias: "candidate"))
                      \(exclusion);
                """)
                try statement.bind(1, workspaceId.value.uuidString)
                for (index, id) in excludedRawIDs.enumerated() {
                    try statement.bind(Int32(index + 2), id)
                }
                let eligibleCount = try statement.step() ? Int(statement.columnInt64(0)) : 0
                guard eligibleCount >= requiredVictims else {
                    throw try workspaceThreadCapacityError(
                        workspaceId: workspaceId,
                        limit: cap,
                        actualCount: projectedCount,
                        liveSurfaceBindings: liveBindings
                    )
                }
            }
        }
    }

    /// Persists a thread and applies the workspace retention cap as one write.
    /// Any victim-delete failure rolls the upsert back with the transaction.
    @discardableResult
    public func upsertEnforcingWorkspaceThreadLimit(
        _ thread: AgentThread,
        limit: Int = AgentThreadRepository.maxThreadsPerWorkspace
    ) throws -> [AgentThreadID] {
        try transactionallyUpsertEnforcingWorkspaceThreadLimit(thread, limit: limit) {}
    }

    /// Persists a capped thread and its dependent graph writes atomically.
    /// Callers publish returned victim ids only after this method commits.
    @discardableResult
    public func transactionallyUpsertEnforcingWorkspaceThreadLimit(
        _ thread: AgentThread,
        limit: Int = AgentThreadRepository.maxThreadsPerWorkspace,
        excludedVictimIDs: Set<AgentThreadID> = [],
        additionalWrites: () throws -> Void
    ) throws -> [AgentThreadID] {
        return try db.performSync { database in
            try database.transaction {
                let victims = try upsertEnforcingWorkspaceThreadLimitInCurrentTransaction(
                    thread,
                    limit: limit,
                    excludedVictimIDs: excludedVictimIDs
                )
                try additionalWrites()
                return victims
            }
        }
    }

    private func upsertEnforcingWorkspaceThreadLimitInCurrentTransaction(
        _ thread: AgentThread,
        limit: Int,
        excludedVictimIDs: Set<AgentThreadID> = []
    ) throws -> [AgentThreadID] {
        try upsert(thread)
        guard let workspaceID = thread.workspaceId else { return [] }
        return try enforceWorkspaceThreadLimitInCurrentTransaction(
            workspaceId: workspaceID,
            limit: limit,
            excluding: excludedVictimIDs.union([thread.id])
        )
    }

    func enforceWorkspaceThreadLimitInCurrentTransaction(
        workspaceId: WorkspaceID,
        limit: Int,
        excluding excludedThreadIDs: Set<AgentThreadID>
    ) throws -> [AgentThreadID] {
        try withLiveSurfaceBindingsLocked { liveBindings in
            let cap = max(1, limit)
            let victims = try workspaceThreadLimitVictims(
                workspaceId: workspaceId,
                limit: cap,
                excluding: excludedThreadIDs.union(liveBindings)
            )
            for id in victims {
                guard try deleteWorkspaceThreadLimitVictimIfStillEligible(id) else {
                    throw try workspaceThreadCapacityError(
                        workspaceId: workspaceId,
                        limit: cap,
                        actualCount: try count(workspaceId: workspaceId),
                        liveSurfaceBindings: liveBindings
                    )
                }
            }
            let actualCount = try count(workspaceId: workspaceId)
            guard actualCount <= cap else {
                throw try workspaceThreadCapacityError(
                    workspaceId: workspaceId,
                    limit: cap,
                    actualCount: actualCount,
                    liveSurfaceBindings: liveBindings
                )
            }
            return victims
        }
    }

    public func list(workspaceId: WorkspaceID? = nil) throws -> [AgentThread] {
        // Rail order is pure last activity: most recently updated/completed
        // threads float to the top. Pin is a visual/retention marker only —
        // it does not override recency. Manual sort_order is retained for
        // reorder APIs but no longer drives the visible rail.
        let sql = workspaceId == nil
            ? "SELECT id, project_id, workspace_id, title, provider, provider_instance_id, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread, color, pinned, sort_order, permission_mode, reasoning_effort, execution_mode, base_branch, worktree_path, service_tier, model_selection_json, interaction_mode, run_as_user_json FROM agent_threads ORDER BY updated_at DESC, id DESC;"
            : "SELECT id, project_id, workspace_id, title, provider, provider_instance_id, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread, color, pinned, sort_order, permission_mode, reasoning_effort, execution_mode, base_branch, worktree_path, service_tier, model_selection_json, interaction_mode, run_as_user_json FROM agent_threads WHERE workspace_id = ? ORDER BY updated_at DESC, id DESC;"
        let st = try db.prepare(sql)
        if let wid = workspaceId { try st.bind(1, wid.value.uuidString) }
        var out: [AgentThread] = []
        while try st.step() {
            let id = AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID())
            let pid = (st.columnText(1)).flatMap { UUID(uuidString: $0) }.map { ProjectID($0) }
            let wid = (st.columnText(2)).flatMap { UUID(uuidString: $0) }.map { WorkspaceID($0) }
            let provider = AgentProvider(rawValue: st.columnText(4) ?? "codex") ?? .codex
            let model = st.columnText(6) ?? ""
            let reasoningEffort = AgentReasoningEffort(rawValue: st.columnText(18) ?? "") ?? .medium
            let serviceTier = AgentServiceTier(rawValue: st.columnText(22) ?? "") ?? .auto
            out.append(AgentThread(
                id: id,
                projectId: pid,
                workspaceId: wid,
                title: st.columnText(3) ?? "",
                provider: provider,
                providerInstanceId: st.columnText(5) ?? provider.rawValue,
                model: model,
                providerThreadId: st.columnText(7),
                status: AgentRunStatus(rawValue: st.columnText(8) ?? "") ?? .pending,
                createdAt: parseDate(st.columnText(9)),
                updatedAt: parseDate(st.columnText(10)),
                diffAdditions: Int(st.columnInt64(11)),
                diffDeletions: Int(st.columnInt64(12)),
                hasUnread: st.columnInt64(13) != 0,
                color: st.columnText(14),
                pinned: st.columnInt64(15) != 0,
                sortOrder: Int(st.columnInt64(16)),
                permissionMode: AgentPermissionMode(rawValue: st.columnText(17) ?? "") ?? .supervised,
                reasoningEffort: reasoningEffort,
                executionMode: AgentExecutionMode(rawValue: st.columnText(19) ?? "") ?? .local,
                baseBranch: st.columnText(20),
                worktreePath: st.columnText(21),
                serviceTier: serviceTier,
                modelSelection: decodeModelSelection(st.columnText(23), provider: provider, model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier),
                interactionMode: AgentInteractionMode(rawValue: st.columnText(24) ?? "") ?? .default,
                runAsUser: decodeRunAsUser(st.columnText(25)),
                routingConfiguration: try loadRoutingConfiguration(threadId: id)
            ))
        }
        return out
    }

    public func get(id: AgentThreadID) throws -> AgentThread? {
        let st = try db.prepare("SELECT id, project_id, workspace_id, title, provider, provider_instance_id, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread, color, pinned, sort_order, permission_mode, reasoning_effort, execution_mode, base_branch, worktree_path, service_tier, model_selection_json, interaction_mode, run_as_user_json FROM agent_threads WHERE id = ?;")
        try st.bind(1, id.value.uuidString)
        if try st.step() {
            let idVal = AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID())
            let pid = (st.columnText(1)).flatMap { UUID(uuidString: $0) }.map { ProjectID($0) }
            let wid = (st.columnText(2)).flatMap { UUID(uuidString: $0) }.map { WorkspaceID($0) }
            let provider = AgentProvider(rawValue: st.columnText(4) ?? "codex") ?? .codex
            let model = st.columnText(6) ?? ""
            let reasoningEffort = AgentReasoningEffort(rawValue: st.columnText(18) ?? "") ?? .medium
            let serviceTier = AgentServiceTier(rawValue: st.columnText(22) ?? "") ?? .auto
            return AgentThread(
                id: idVal,
                projectId: pid,
                workspaceId: wid,
                title: st.columnText(3) ?? "",
                provider: provider,
                providerInstanceId: st.columnText(5) ?? provider.rawValue,
                model: model,
                providerThreadId: st.columnText(7),
                status: AgentRunStatus(rawValue: st.columnText(8) ?? "") ?? .pending,
                createdAt: parseDate(st.columnText(9)),
                updatedAt: parseDate(st.columnText(10)),
                diffAdditions: Int(st.columnInt64(11)),
                diffDeletions: Int(st.columnInt64(12)),
                hasUnread: st.columnInt64(13) != 0,
                color: st.columnText(14),
                pinned: st.columnInt64(15) != 0,
                sortOrder: Int(st.columnInt64(16)),
                permissionMode: AgentPermissionMode(rawValue: st.columnText(17) ?? "") ?? .supervised,
                reasoningEffort: reasoningEffort,
                executionMode: AgentExecutionMode(rawValue: st.columnText(19) ?? "") ?? .local,
                baseBranch: st.columnText(20),
                worktreePath: st.columnText(21),
                serviceTier: serviceTier,
                modelSelection: decodeModelSelection(st.columnText(23), provider: provider, model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier),
                interactionMode: AgentInteractionMode(rawValue: st.columnText(24) ?? "") ?? .default,
                runAsUser: decodeRunAsUser(st.columnText(25)),
                routingConfiguration: try loadRoutingConfiguration(threadId: idVal)
            )
        }
        return nil
    }

    public func setRoutingConfiguration(
        _ configuration: AgentRoutingConfiguration,
        threadId: AgentThreadID,
        expectedRevision: Int
    ) throws {
        guard var thread = try get(id: threadId) else { return }
        let actualRevision = thread.routingConfiguration?.revision ?? 0
        guard actualRevision == expectedRevision else {
            throw AgentRoutingRevisionError.conflict(expected: expectedRevision, actual: actualRevision)
        }
        thread.routingConfiguration = configuration
        thread.updatedAt = configuration.updatedAt
        try upsert(thread)
    }

    private func loadRoutingConfiguration(threadId: AgentThreadID) throws -> AgentRoutingConfiguration? {
        let statement = try db.prepare("""
            SELECT mode, configuration_json, revision
            FROM agent_thread_routing
            WHERE thread_id = ?;
        """)
        try statement.bind(1, threadId.value.uuidString)
        guard try statement.step() else { return nil }
        return try decodeRoutingConfiguration(
            json: statement.columnText(1),
            storedMode: statement.columnText(0),
            storedRevision: Int(statement.columnInt64(2))
        )
    }

    public func delete(id: AgentThreadID) throws {
        let st = try db.prepare("DELETE FROM agent_threads WHERE id = ?;")
        try st.bind(1, id.value.uuidString)
        _ = try st.step()
    }

    public func count(workspaceId: WorkspaceID) throws -> Int {
        let st = try db.prepare("SELECT COUNT(*) FROM agent_threads WHERE workspace_id = ?;")
        try st.bind(1, workspaceId.value.uuidString)
        guard try st.step() else { return 0 }
        return Int(st.columnInt64(0))
    }

    /// Deletes oldest eligible threads until the workspace is at or below
    /// `limit`. Never deletes `running`/`pending` threads. Prefers unpinned
    /// oldest-first, then pinned non-active. Cascades messages via FK.
    /// - Returns: ids that were deleted.
    @discardableResult
    public func enforceWorkspaceThreadLimit(
        workspaceId: WorkspaceID,
        limit: Int = AgentThreadRepository.maxThreadsPerWorkspace
    ) throws -> [AgentThreadID] {
        try db.performSync { database in
            try database.transaction {
                try enforceWorkspaceThreadLimitInCurrentTransaction(
                    workspaceId: workspaceId,
                    limit: limit,
                    excluding: []
                )
            }
        }
    }

    private func workspaceThreadLimitVictims(
        workspaceId: WorkspaceID,
        limit: Int,
        excluding excludedThreadIDs: Set<AgentThreadID> = []
    ) throws -> [AgentThreadID] {
        let cap = max(1, limit)
        let total = try count(workspaceId: workspaceId)
        guard total > cap else { return [] }
        let excess = total - cap
        // Prefer pruning idle unpinned history; never touch active runs.
        let excludedRawIDs = excludedThreadIDs.map { $0.value.uuidString }.sorted()
        let exclusion = excludedRawIDs.isEmpty
            ? ""
            : "AND candidate.id NOT IN (\(Array(repeating: "?", count: excludedRawIDs.count).joined(separator: ", ")))"
        let st = try db.prepare("""
            SELECT candidate.id FROM agent_threads AS candidate
            WHERE candidate.workspace_id = ?
              \(workspaceThreadLimitEligibilityPredicate(candidateAlias: "candidate"))
              \(exclusion)
            ORDER BY candidate.updated_at ASC, candidate.id ASC
            LIMIT ?;
        """)
        try st.bind(1, workspaceId.value.uuidString)
        for (index, id) in excludedRawIDs.enumerated() {
            try st.bind(Int32(index + 2), id)
        }
        try st.bind(Int32(excludedRawIDs.count + 2), Int64(excess))
        var victims: [AgentThreadID] = []
        while try st.step() {
            if let uuid = st.columnText(0).flatMap(UUID.init(uuidString:)) {
                victims.append(AgentThreadID(uuid))
            }
        }
        return victims
    }

    /// Victim selection is only advisory until this guarded DELETE executes.
    /// Recheck active status and recoverable fork participation so any change
    /// after selection aborts and rolls back the entire cap transaction.
    private func deleteWorkspaceThreadLimitVictimIfStillEligible(_ id: AgentThreadID) throws -> Bool {
        let deletion = try db.prepare("""
            DELETE FROM agent_threads
            WHERE id = ?
              \(workspaceThreadLimitEligibilityPredicate(candidateAlias: "agent_threads"));
        """)
        try deletion.bind(1, id.value.uuidString)
        _ = try deletion.step()
        let changes = try db.prepare("SELECT changes();")
        return try changes.step() && changes.columnInt64(0) == 1
    }

    /// Persists the complete local half of a provider-native fork as one graph.
    /// A child is locally valid only when its thread, transcript (including
    /// attachment identities), and optional provider runtime commit together.
    public func persistForkedChildGraph(
        sourceThreadId: AgentThreadID,
        childThread: AgentThread,
        providerSession: ProviderSessionRuntime?,
        forkIntentChildThreadId: AgentThreadID? = nil
    ) throws {
        _ = try persistForkedChildGraphReturningPrunedThreadIDs(
            sourceThreadId: sourceThreadId,
            childThread: childThread,
            providerSession: providerSession,
            forkIntentChildThreadId: forkIntentChildThreadId
        )
    }

    /// Result-returning fork commit used by surfaces that must apply and publish
    /// retention victims before selecting the newly committed child.
    public func persistForkedChildGraphReturningPrunedThreadIDs(
        sourceThreadId: AgentThreadID,
        childThread: AgentThread,
        providerSession: ProviderSessionRuntime?,
        forkIntentChildThreadId: AgentThreadID? = nil
    ) throws -> [AgentThreadID] {
        try db.performSync { database in
            try database.transaction {
                guard try get(id: sourceThreadId) != nil else {
                    throw AgentThreadForkPersistenceError.sourceThreadNotFound
                }
                let sourceMessages: [AgentMessage]
                if let forkIntentChildThreadId {
                    guard forkIntentChildThreadId == childThread.id,
                          let intent = try getForkIntent(childThreadId: forkIntentChildThreadId),
                          intent.sourceThreadId == sourceThreadId,
                          intent.provider == childThread.provider,
                          intent.providerChildThreadId == childThread.providerThreadId else {
                        throw AgentThreadForkPersistenceError.intentConflict
                    }
                    if intent.state == .localCommitted {
                        guard let existing = try get(id: childThread.id),
                              existing.providerThreadId == childThread.providerThreadId else {
                            throw AgentThreadForkPersistenceError.childThreadConflict
                        }
                        return []
                    }
                    guard intent.state == .providerCreated else {
                        throw AgentThreadForkPersistenceError.invalidIntentState(intent.state)
                    }
                    sourceMessages = intent.sourceMessages
                } else {
                    sourceMessages = try AgentMessageRepository(db: database).list(threadId: sourceThreadId)
                }
                if let existing = try get(id: childThread.id) {
                    guard existing.providerThreadId == childThread.providerThreadId else {
                        throw AgentThreadForkPersistenceError.childThreadConflict
                    }
                    throw AgentThreadForkPersistenceError.childThreadConflict
                }
                let messageRepo = AgentMessageRepository(db: database)
                let prunedThreadIDs = try upsertEnforcingWorkspaceThreadLimitInCurrentTransaction(
                    childThread,
                    limit: AgentThreadRepository.maxThreadsPerWorkspace,
                    excludedVictimIDs: [sourceThreadId]
                )

                let copyBaseDate = Date()
                for (index, message) in sourceMessages.enumerated() {
                    try messageRepo.append(AgentMessage(
                        threadId: childThread.id,
                        role: message.role,
                        content: message.content,
                        createdAt: copyBaseDate.addingTimeInterval(Double(index) / 1000),
                        attachments: message.attachments
                    ))
                }
                if let providerSession {
                    try ProviderSessionRuntimeRepository(db: database).upsert(providerSession)
                }
                if let forkIntentChildThreadId {
                    let update = try database.prepare("""
                        UPDATE agent_thread_fork_intents
                        SET state = 'local_committed', source_messages_json = '[]',
                            last_error = NULL, updated_at = ?
                        WHERE child_thread_id = ? AND state = 'provider_created';
                    """)
                    try update.bind(1, iso.string(from: Date()))
                    try update.bind(2, forkIntentChildThreadId.value.uuidString)
                    _ = try update.step()
                }
                return prunedThreadIDs
            }
        }
    }

    /// Creates the durable local identity before any provider mutation. The
    /// idempotency key is stable for the child identity, so a crash before the
    /// provider result is recorded can safely replay only on adapters that
    /// explicitly guarantee keyed idempotency.
    public func prepareForkIntent(
        sourceThreadId: AgentThreadID,
        childThread: AgentThread,
        idempotencyKey: String,
        at date: Date = Date()
    ) throws -> AgentThreadForkIntent {
        guard sourceThreadId != childThread.id else {
            throw AgentThreadForkPersistenceError.intentConflict
        }
        let childJSON = String(decoding: try encodeForkPayload(childThread), as: UTF8.self)
        return try db.performSync { database in
            try database.transaction {
                guard try get(id: sourceThreadId) != nil else {
                    throw AgentThreadForkPersistenceError.sourceThreadNotFound
                }

                // Same durable child/key is a retry, not a second snapshot. Any
                // mismatch is a conflict rather than an unsafe best-effort merge.
                if let existing = try getForkIntent(childThreadId: childThread.id) {
                    guard existing.sourceThreadId == sourceThreadId,
                          existing.provider == childThread.provider,
                          existing.idempotencyKey == idempotencyKey,
                          existing.childThread == childThread else {
                        throw AgentThreadForkPersistenceError.intentConflict
                    }
                    return existing
                }

                let keyCollision = try database.prepare("""
                    SELECT 1 FROM agent_thread_fork_intents
                    WHERE idempotency_key = ?
                    LIMIT 1;
                """)
                try keyCollision.bind(1, idempotencyKey)
                guard try keyCollision.step() == false else {
                    throw AgentThreadForkPersistenceError.intentConflict
                }

                // BEGIN IMMEDIATE serializes this admission across processes.
                // Check before reading/encoding the transcript so a distinct
                // child cannot inflate either retained payload or provider work.
                let recoverableSourceIntent = try database.prepare("""
                    SELECT 1 FROM agent_thread_fork_intents
                    WHERE source_thread_id = ?
                      AND state IN ('prepared', 'provider_created', 'compensating')
                    LIMIT 1;
                """)
                try recoverableSourceIntent.bind(1, sourceThreadId.value.uuidString)
                guard try recoverableSourceIntent.step() == false else {
                    throw AgentThreadForkPersistenceError.recoverableIntentExists
                }

                let sourceMessages = try AgentMessageRepository(db: database).list(threadId: sourceThreadId)
                let sourceMessagesJSON = String(decoding: try encodeForkPayload(sourceMessages), as: UTF8.self)
                let insert = try database.prepare("""
                    INSERT INTO agent_thread_fork_intents(
                        child_thread_id, source_thread_id, provider, idempotency_key,
                        state, child_thread_json, source_messages_json, provider_child_thread_id,
                        last_error, created_at, updated_at, provider_creation_attempted
                    ) VALUES(?, ?, ?, ?, 'prepared', ?, ?, NULL, NULL, ?, ?, 0);
                """)
                try insert.bind(1, childThread.id.value.uuidString)
                try insert.bind(2, sourceThreadId.value.uuidString)
                try insert.bind(3, childThread.provider.rawValue)
                try insert.bind(4, idempotencyKey)
                try insert.bind(5, childJSON)
                try insert.bind(6, sourceMessagesJSON)
                try insert.bind(7, iso.string(from: date))
                try insert.bind(8, iso.string(from: date))
                _ = try insert.step()
                guard let intent = try getForkIntent(childThreadId: childThread.id) else {
                    throw AgentThreadForkPersistenceError.intentConflict
                }
                return intent
            }
        }
    }

    public func getForkIntent(childThreadId: AgentThreadID) throws -> AgentThreadForkIntent? {
        let statement = try db.prepare("""
            SELECT source_thread_id, provider, idempotency_key, state,
                   child_thread_json, source_messages_json, provider_child_thread_id, last_error,
                   created_at, updated_at, provider_creation_attempted
            FROM agent_thread_fork_intents WHERE child_thread_id = ?;
        """)
        try statement.bind(1, childThreadId.value.uuidString)
        guard try statement.step() else { return nil }
        guard let sourceUUID = UUID(uuidString: statement.columnText(0) ?? ""),
              let provider = AgentProvider(rawValue: statement.columnText(1) ?? ""),
              let state = AgentThreadForkIntentState(rawValue: statement.columnText(3) ?? ""),
              let childJSON = statement.columnText(4)?.data(using: .utf8),
              let sourceMessagesJSON = statement.columnText(5)?.data(using: .utf8) else {
            throw AgentThreadForkPersistenceError.corruptIntent
        }
        forkCodecLock.lock()
        let childThread = try? forkDecoder.decode(AgentThread.self, from: childJSON)
        let sourceMessages = try? forkDecoder.decode([AgentMessage].self, from: sourceMessagesJSON)
        forkCodecLock.unlock()
        guard let childThread, let sourceMessages else {
            throw AgentThreadForkPersistenceError.corruptIntent
        }
        return AgentThreadForkIntent(
            sourceThreadId: AgentThreadID(sourceUUID),
            childThread: childThread,
            sourceMessages: sourceMessages,
            provider: provider,
            idempotencyKey: statement.columnText(2) ?? "",
            state: state,
            providerCreationAttempted: statement.columnInt64(10) != 0,
            providerChildThreadId: statement.columnText(6),
            lastError: statement.columnText(7),
            createdAt: parseDate(statement.columnText(8)),
            updatedAt: parseDate(statement.columnText(9))
        )
    }

    private func encodeForkPayload<T: Encodable>(_ value: T) throws -> Data {
        forkCodecLock.lock()
        defer { forkCodecLock.unlock() }
        return try forkEncoder.encode(value)
    }

    public func listRecoverableForkIntents() throws -> [AgentThreadForkIntent] {
        let statement = try db.prepare("""
            SELECT child_thread_id FROM agent_thread_fork_intents
            WHERE state IN ('prepared', 'provider_created', 'compensating')
            ORDER BY created_at ASC, child_thread_id ASC;
        """)
        var intents: [AgentThreadForkIntent] = []
        while try statement.step() {
            guard let uuid = UUID(uuidString: statement.columnText(0) ?? ""),
                  let intent = try getForkIntent(childThreadId: AgentThreadID(uuid)) else {
                throw AgentThreadForkPersistenceError.corruptIntent
            }
            intents.append(intent)
        }
        return intents
    }

    public func hasRecoverableForkIntent(sourceThreadId: AgentThreadID) throws -> Bool {
        let statement = try db.prepare("""
            SELECT 1 FROM agent_thread_fork_intents
            WHERE source_thread_id = ?
              AND state IN ('prepared', 'provider_created', 'compensating')
            LIMIT 1;
        """)
        try statement.bind(1, sourceThreadId.value.uuidString)
        return try statement.step()
    }

    /// Records the point after which `prepared` must be treated as provider-call
    /// ambiguous. The call is idempotent so a relaunch can retry the keyed
    /// adapter request without losing its exact transcript snapshot.
    @discardableResult
    public func markForkProviderCreationAttempted(
        childThreadId: AgentThreadID,
        at date: Date = Date()
    ) throws -> AgentThreadForkIntent {
        let update = try db.prepare("""
            UPDATE agent_thread_fork_intents
            SET provider_creation_attempted = 1, updated_at = ?
            WHERE child_thread_id = ?
              AND state = 'prepared'
              AND provider_creation_attempted = 0;
        """)
        try update.bind(1, iso.string(from: date))
        try update.bind(2, childThreadId.value.uuidString)
        _ = try update.step()
        guard let intent = try getForkIntent(childThreadId: childThreadId),
              intent.state == .prepared,
              intent.providerCreationAttempted else {
            throw AgentThreadForkPersistenceError.intentConflict
        }
        return intent
    }

    @discardableResult
    public func recordForkProviderCreated(
        childThreadId: AgentThreadID,
        providerChildThreadId: String,
        at date: Date = Date()
    ) throws -> AgentThreadForkIntent {
        let update = try db.prepare("""
            UPDATE agent_thread_fork_intents
            SET state = 'provider_created', provider_child_thread_id = ?,
                provider_creation_attempted = 1, last_error = NULL, updated_at = ?
            WHERE child_thread_id = ? AND state = 'prepared';
        """)
        try update.bind(1, providerChildThreadId)
        try update.bind(2, iso.string(from: date))
        try update.bind(3, childThreadId.value.uuidString)
        _ = try update.step()
        guard let intent = try getForkIntent(childThreadId: childThreadId),
              [.providerCreated, .localCommitted].contains(intent.state),
              intent.providerChildThreadId == providerChildThreadId else {
            throw AgentThreadForkPersistenceError.providerIdentityConflict
        }
        return intent
    }

    @discardableResult
    public func markForkCompensating(
        childThreadId: AgentThreadID,
        error: String,
        at date: Date = Date()
    ) throws -> AgentThreadForkIntent {
        let update = try db.prepare("""
            UPDATE agent_thread_fork_intents
            SET state = 'compensating', last_error = ?, updated_at = ?
            WHERE child_thread_id = ? AND state = 'provider_created';
        """)
        try update.bind(1, error)
        try update.bind(2, iso.string(from: date))
        try update.bind(3, childThreadId.value.uuidString)
        _ = try update.step()
        guard let intent = try getForkIntent(childThreadId: childThreadId),
              intent.state == .compensating else {
            throw AgentThreadForkPersistenceError.intentConflict
        }
        return intent
    }

    public func markForkCompensated(childThreadId: AgentThreadID, at _: Date = Date()) throws {
        let delete = try db.prepare("""
            DELETE FROM agent_thread_fork_intents
            WHERE child_thread_id = ?
              AND state = 'compensating'
              AND provider_child_thread_id IS NOT NULL;
        """)
        try delete.bind(1, childThreadId.value.uuidString)
        _ = try delete.step()
        let changes = try db.prepare("SELECT changes();")
        guard try changes.step(), changes.columnInt64(0) == 1,
              try getForkIntent(childThreadId: childThreadId) == nil else {
            throw AgentThreadForkPersistenceError.intentConflict
        }
    }

    /// A missing source is safe to retire only before the durable intent records
    /// that a provider call could have begun. The delete itself is the terminal
    /// outcome: retaining an `abandoned` tombstone would reintroduce row growth.
    public func markPreparedForkAbandoned(childThreadId: AgentThreadID, error _: String, at _: Date = Date()) throws {
        let delete = try db.prepare("""
            DELETE FROM agent_thread_fork_intents
            WHERE child_thread_id = ?
              AND state = 'prepared'
              AND provider_child_thread_id IS NULL
              AND provider_creation_attempted = 0
              AND NOT EXISTS (
                  SELECT 1 FROM agent_threads AS source
                  WHERE source.id = agent_thread_fork_intents.source_thread_id
              );
        """)
        try delete.bind(1, childThreadId.value.uuidString)
        _ = try delete.step()
        let changes = try db.prepare("SELECT changes();")
        guard try changes.step(), changes.columnInt64(0) == 1,
              try getForkIntent(childThreadId: childThreadId) == nil else {
            throw AgentThreadForkPersistenceError.intentConflict
        }
    }

    /// Scrubs or removes one bounded batch of historical terminal fork intents.
    /// A live locally-committed child keeps its tombstone but no longer needs a
    /// duplicated source transcript. Rows are deleted only when their terminal
    /// outcome is causally known. Recoverable and ambiguous rows are never
    /// selected, and a failed write rolls back this batch only.
    @discardableResult
    public func maintainHistoricalForkIntents(
        limit: Int = AgentThreadRepository.terminalForkIntentCleanupBatchSize
    ) throws -> ForkIntentMaintenanceBatch {
        let batchSize = min(
            AgentThreadRepository.terminalForkIntentCleanupBatchSize,
            max(0, limit)
        )
        let result = try db.performSync { database in
            try database.transaction {
                let candidates = try database.prepare("""
                    SELECT child_thread_id,
                           CASE WHEN state = 'local_committed' AND EXISTS (
                               SELECT 1 FROM agent_threads AS child
                               WHERE child.id = intent.child_thread_id
                           ) THEN 1 ELSE 0 END AS scrub_only
                    FROM agent_thread_fork_intents AS intent
                         INDEXED BY idx_agent_thread_fork_intents_maintenance
                    WHERE (intent.state = 'local_committed'
                           OR intent.state = 'compensated'
                           OR intent.state = 'abandoned')
                      AND ((intent.state = 'local_committed'
                            AND (intent.source_messages_json != '[]'
                                 OR NOT EXISTS (
                                     SELECT 1 FROM agent_threads AS child
                                     WHERE child.id = intent.child_thread_id
                                 )))
                           OR intent.state = 'compensated'
                           OR (intent.state = 'abandoned'
                               AND intent.provider_creation_attempted = 0))
                    ORDER BY intent.updated_at ASC, intent.child_thread_id ASC
                    LIMIT ?;
                """)
                try candidates.bind(1, batchSize + 1)
                var selected: [(childID: String, scrubOnly: Bool)] = []
                while try candidates.step() {
                    guard let childID = candidates.columnText(0) else {
                        throw AgentThreadForkPersistenceError.corruptIntent
                    }
                    selected.append((childID, candidates.columnInt64(1) != 0))
                }
                let hasMore = selected.count > batchSize

                let scrub = try database.prepare("""
                    UPDATE agent_thread_fork_intents
                    SET source_messages_json = '[]'
                    WHERE child_thread_id = ?
                      AND state = 'local_committed'
                      AND source_messages_json != '[]'
                      AND EXISTS (
                          SELECT 1 FROM agent_threads AS child
                          WHERE child.id = agent_thread_fork_intents.child_thread_id
                      );
                """)
                let delete = try database.prepare("""
                    DELETE FROM agent_thread_fork_intents
                    WHERE child_thread_id = ?
                      AND (
                          state = 'compensated'
                          OR (state = 'abandoned' AND provider_creation_attempted = 0)
                          OR (state = 'local_committed' AND NOT EXISTS (
                              SELECT 1 FROM agent_threads AS child
                              WHERE child.id = agent_thread_fork_intents.child_thread_id
                          ))
                      );
                """)
                var scrubbed = 0
                var deleted = 0
                for candidate in selected.prefix(batchSize) {
                    let mutation = candidate.scrubOnly ? scrub : delete
                    mutation.reset()
                    try mutation.bind(1, candidate.childID)
                    _ = try mutation.step()
                    let changes = try database.prepare("SELECT changes();")
                    guard try changes.step() else {
                        throw AgentThreadForkPersistenceError.intentConflict
                    }
                    if candidate.scrubOnly {
                        scrubbed += Int(changes.columnInt64(0))
                    } else {
                        deleted += Int(changes.columnInt64(0))
                    }
                }
                return (scrubbed, deleted, hasMore)
            }
        }
        return ForkIntentMaintenanceBatch(
            scrubbedCount: result.0,
            deletedCount: result.1,
            hasMore: result.2
        )
    }

    public func historicalForkIntentMaintenanceCandidateCount() throws -> Int {
        try db.performSync { database in
            let count = try database.prepare("""
                SELECT COUNT(*)
                FROM agent_thread_fork_intents AS intent
                WHERE (intent.state = 'local_committed'
                       AND (intent.source_messages_json != '[]'
                            OR NOT EXISTS (
                                SELECT 1 FROM agent_threads AS child
                                WHERE child.id = intent.child_thread_id
                            )))
                   OR intent.state = 'compensated'
                   OR (intent.state = 'abandoned'
                       AND intent.provider_creation_attempted = 0);
            """)
            guard try count.step() else { return 0 }
            return Int(count.columnInt64(0))
        }
    }

    public func recordForkIntentError(childThreadId: AgentThreadID, error: String, at date: Date = Date()) throws {
        let update = try db.prepare("""
            UPDATE agent_thread_fork_intents SET last_error = ?, updated_at = ?
            WHERE child_thread_id = ?
              AND state IN ('prepared', 'provider_created', 'compensating');
        """)
        try update.bind(1, error)
        try update.bind(2, iso.string(from: date))
        try update.bind(3, childThreadId.value.uuidString)
        _ = try update.step()
    }

    public func setPinned(id: AgentThreadID, pinned: Bool) throws {
        try db.performSync { database in try database.transaction {
                guard var t = try get(id: id) else { return }
                t.pinned = pinned
                t.updatedAt = Date()
                try upsert(t)
                if let wid = t.workspaceId { try normalizeOrder(workspaceId: wid) }
        } }
    }

    public func reorder(id: AgentThreadID, position: Int) throws {
        try db.performSync { database in try database.transaction {
                guard let t = try get(id: id), let wid = t.workspaceId else { return }
                var list = try list(workspaceId: wid)
                guard let current = list.firstIndex(where: { $0.id == id }) else { return }
                let item = list.remove(at: current)
                list.insert(item, at: max(0, min(position, list.count)))
                try normalizeOrder(workspaceId: wid, ordered: list)
        } }
    }

    public func delete(ids: [AgentThreadID]) throws {
        guard !ids.isEmpty else { return }
        try db.performSync { database in
            try database.transaction {
                let statement = try database.prepare("DELETE FROM agent_threads WHERE id = ?;")
                for id in ids {
                    statement.reset()
                    try statement.bind(1, id.value.uuidString)
                    _ = try statement.step()
                }
            }
        }
    }

    /// PERF-008: returns the subset of the given workspace ids that have at
    /// least one thread with status='running'. Single query with WHERE
    /// workspace_id IN (...) AND status='running'. Used by listWorkspaces()
    /// to compute the busy flag for every workspace without one query per workspace.
    public func runningWorkspaceIds(in ids: [WorkspaceID]) throws -> Set<WorkspaceID> {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let st = try db.prepare(
            "SELECT DISTINCT workspace_id FROM agent_threads WHERE workspace_id IN (\(placeholders)) AND status = 'running';"
        )
        for (i, wid) in ids.enumerated() {
            try st.bind(Int32(i + 1), wid.value.uuidString)
        }
        var out = Set<WorkspaceID>()
        while try st.step() {
            if let uuidStr = st.columnText(0), let uuid = UUID(uuidString: uuidStr) {
                out.insert(WorkspaceID(uuid))
            }
        }
        return out
    }

    private func normalizeOrder(workspaceId: WorkspaceID, ordered: [AgentThread]? = nil) throws {
        let list: [AgentThread]
        if let ordered {
            list = ordered
        } else {
            list = try self.list(workspaceId: workspaceId)
        }
        let sorted = list.filter(\.pinned) + list.filter { !$0.pinned }
        for (idx, var t) in sorted.enumerated() {
            t.sortOrder = idx
            try upsert(t)
        }
    }
}

public enum AgentThreadForkPersistenceError: Error, Equatable {
    case sourceThreadNotFound
    case intentConflict
    case recoverableIntentExists
    case providerIdentityConflict
    case childThreadConflict
    case invalidIntentState(AgentThreadForkIntentState)
    case corruptIntent
}

public struct AgentMessageBodyBudgetResult: Sendable, Equatable {
    public var rows: [AgentMessage]
    public var blanked: Int
    public var hasMoreOlder: Bool
    public var hasMoreNewer: Bool
    public var nextBefore: AgentMessageCursor?
    public var nextAfter: AgentMessageCursor?
    /// Original persisted UTF-8 body sizes keyed by message id (honest pre-truncation counts).
    public var originalByteCounts: [AgentMessageID: Int]
    /// Message ids whose returned `content` is shorter than the persisted body.
    public var truncatedIDs: Set<AgentMessageID>
    /// Exact number of persisted attachment objects, even when their JSON was
    /// too large to cross the SQLite decode boundary.
    public var attachmentCounts: [AgentMessageID: Int]
    /// Rows whose attachment array was omitted or count-capped.
    public var attachmentTruncatedIDs: Set<AgentMessageID>
    /// Default/before pages prioritize newest bodies; after pages prioritize
    /// the oldest rows immediately following their cursor.
    public var prefersNewestBodies: Bool

    public init(
        rows: [AgentMessage],
        blanked: Int,
        hasMoreOlder: Bool = false,
        nextBefore: AgentMessageCursor? = nil,
        hasMoreNewer: Bool = false,
        nextAfter: AgentMessageCursor? = nil,
        originalByteCounts: [AgentMessageID: Int] = [:],
        truncatedIDs: Set<AgentMessageID> = [],
        attachmentCounts: [AgentMessageID: Int] = [:],
        attachmentTruncatedIDs: Set<AgentMessageID> = [],
        prefersNewestBodies: Bool = true
    ) {
        self.rows = rows
        self.blanked = blanked
        self.hasMoreOlder = hasMoreOlder
        self.hasMoreNewer = hasMoreNewer
        self.nextBefore = nextBefore
        self.nextAfter = nextAfter
        self.originalByteCounts = originalByteCounts
        self.truncatedIDs = truncatedIDs
        self.attachmentCounts = attachmentCounts
        self.attachmentTruncatedIDs = attachmentTruncatedIDs
        self.prefersNewestBodies = prefersNewestBodies
    }
}

public enum AgentMessageBodyChunkError: Error, Equatable {
    case invalidOffset
    case bodyRevisionConflict
    case bodyDigestMismatch
    case bodyIdentityUnavailable
}

public enum AgentMessagePageCursorError: Error, Equatable {
    case staleOrInvalid
}

/// Full message metadata is deliberately available only on offset zero.
/// Continuation pages carry only immutable body identity plus content bytes.
public struct AgentMessageBodyChunkMetadata: Sendable, Equatable {
    public let threadId: AgentThreadID
    public let role: AgentMessageRole
    public let createdAt: Date
    public let attachments: [AgentAttachment]
    public let attachmentCount: Int
    public let attachmentsTruncated: Bool

    public init(
        threadId: AgentThreadID,
        role: AgentMessageRole,
        createdAt: Date,
        attachments: [AgentAttachment],
        attachmentCount: Int,
        attachmentsTruncated: Bool
    ) {
        self.threadId = threadId
        self.role = role
        self.createdAt = createdAt
        self.attachments = attachments
        self.attachmentCount = attachmentCount
        self.attachmentsTruncated = attachmentsTruncated
    }
}

public struct AgentMessageBodyChunk: Sendable, Equatable {
    public let id: AgentMessageID
    public let content: String
    public let bodyByteCount: Int
    public let bodySHA256: String
    public let bodyRevision: Int
    public let bodyOffset: Int
    public let metadata: AgentMessageBodyChunkMetadata?

    public init(
        id: AgentMessageID,
        content: String,
        bodyByteCount: Int,
        bodySHA256: String,
        bodyRevision: Int,
        bodyOffset: Int,
        metadata: AgentMessageBodyChunkMetadata?
    ) {
        self.id = id
        self.content = content
        self.bodyByteCount = bodyByteCount
        self.bodySHA256 = bodySHA256
        self.bodyRevision = bodyRevision
        self.bodyOffset = bodyOffset
        self.metadata = metadata
    }
}

public final class AgentMessageRepository: @unchecked Sendable {
    let db: SQLiteDB
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(db: SQLiteDB) { self.db = db }

    /// Durable transcript retention: keep only the newest N messages per thread
    /// so long-running agent sessions cannot grow `agent_messages` without bound.
    public static let maxMessagesPerThread = 100

    public func append(_ m: AgentMessage) throws {
        let bodyBytes = m.content.utf8.count
        let bodySHA256 = Self.bodySHA256Hex(m.content)
        let st = try db.prepare("""
            INSERT INTO agent_messages(
                id, thread_id, role, content, created_at, attachments_json,
                body_sha256, body_bytes, body_revision
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(id) DO UPDATE SET
                thread_id = excluded.thread_id,
                role = excluded.role,
                content = excluded.content,
                created_at = excluded.created_at,
                attachments_json = excluded.attachments_json,
                body_sha256 = excluded.body_sha256,
                body_bytes = excluded.body_bytes,
                body_revision = CASE
                    WHEN agent_messages.content IS excluded.content
                    THEN agent_messages.body_revision
                    ELSE agent_messages.body_revision + 1
                END;
            """)
        try st.bind(1, m.id.value.uuidString)
        try st.bind(2, m.threadId.value.uuidString)
        try st.bind(3, m.role.rawValue)
        try st.bind(4, m.content)
        try st.bind(5, iso.string(from: m.createdAt))
        try st.bind(6, try attachmentsJSON(m.attachments))
        try st.bind(7, bodySHA256)
        try st.bind(8, bodyBytes)
        _ = try st.step()
        try pruneMessagesKeepingLatest(threadId: m.threadId, limit: Self.maxMessagesPerThread)
    }

    /// Deletes oldest durable messages so only the newest `limit` remain.
    public func pruneMessagesKeepingLatest(
        threadId: AgentThreadID,
        limit: Int = AgentMessageRepository.maxMessagesPerThread
    ) throws {
        let keep = max(1, limit)
        // Nested SELECT required: SQLite rejects LIMIT directly inside DELETE … NOT IN.
        let st = try db.prepare("""
            DELETE FROM agent_messages
            WHERE thread_id = ?
              AND rowid NOT IN (
                SELECT rowid FROM (
                    SELECT rowid FROM agent_messages
                    WHERE thread_id = ?
                    ORDER BY created_at DESC, rowid DESC
                    LIMIT ?
                )
              );
            """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, threadId.value.uuidString)
        try st.bind(3, Int64(keep))
        _ = try st.step()
    }

    public func list(threadId: AgentThreadID) throws -> [AgentMessage] {
        let st = try db.prepare("SELECT id, thread_id, role, content, created_at, attachments_json FROM agent_messages WHERE thread_id = ? ORDER BY created_at ASC, rowid ASC;")
        try st.bind(1, threadId.value.uuidString)
        var out: [AgentMessage] = []
        while try st.step() {
            out.append(message(from: st))
        }
        return out
    }

    /// Full-history load with bounded body hydration. Older rows are still returned
    /// in order, but their bodies are blanked before SQLite reads the content blobs
    /// when the estimated capped body bytes exceed the budget.
    public func listWithinBodyBudget(
        threadId: AgentThreadID,
        budget: Int,
        contentLimit: Int = AssistantTimelineState.liveTextLimit
    ) throws -> AgentMessageBodyBudgetResult {
        let metadata = try db.prepare("""
            SELECT rowid, id, thread_id, role, created_at, length(CAST(content AS BLOB)), attachments_json
            FROM agent_messages
            WHERE thread_id = ?
            ORDER BY created_at ASC, rowid ASC;
            """)
        try metadata.bind(1, threadId.value.uuidString)

        struct MessageShell {
            let rowid: Int64
            let id: AgentMessageID
            let threadId: AgentThreadID
            let role: AgentMessageRole
            let createdAt: Date
            let estimatedBytes: Int
            let attachments: [AgentAttachment]
        }

        var shells: [MessageShell] = []
        var totalBytes = 0
        let cappedLimit = max(0, contentLimit)
        let cappedByteLimit = cappedLimit >= (Int.max - 128) / 4
            ? Int.max
            : (cappedLimit * 4) + 128
        while try metadata.step() {
            guard let idText = metadata.columnText(1),
                  let id = UUID(uuidString: idText),
                  let threadText = metadata.columnText(2),
                  let threadUUID = UUID(uuidString: threadText),
                  let roleText = metadata.columnText(3),
                  let role = AgentMessageRole(rawValue: roleText),
                  let createdText = metadata.columnText(4),
                  let createdAt = iso.date(from: createdText)
            else { continue }
            let estimatedBytes = min(Int(metadata.columnInt64(5)), cappedByteLimit)
            totalBytes += estimatedBytes
            shells.append(MessageShell(
                rowid: metadata.columnInt64(0),
                id: AgentMessageID(id),
                threadId: AgentThreadID(threadUUID),
                role: role,
                createdAt: createdAt,
                estimatedBytes: estimatedBytes,
                attachments: decodeAttachments(metadata.columnText(6))
            ))
        }

        let targetBudget = max(0, budget)
        var firstHydratedIndex = 0
        var blanked = 0
        var remainingBytes = totalBytes
        while remainingBytes > targetBudget && firstHydratedIndex < shells.count {
            let bytes = shells[firstHydratedIndex].estimatedBytes
            if bytes > 0 {
                remainingBytes -= bytes
                blanked += 1
            }
            firstHydratedIndex += 1
        }

        var rows = shells.map {
            AgentMessage(
                id: $0.id,
                threadId: $0.threadId,
                role: $0.role,
                content: "",
                createdAt: $0.createdAt,
                attachments: $0.attachments
            )
        }

        if firstHydratedIndex < shells.count {
            let cursor = shells[firstHydratedIndex]
            let content = try db.prepare("""
                SELECT id, content
                FROM agent_messages
                WHERE thread_id = ?
                  AND (created_at > ? OR (created_at = ? AND rowid >= ?))
                ORDER BY created_at ASC, rowid ASC;
                """)
            try content.bind(1, threadId.value.uuidString)
            let createdAtText = iso.string(from: cursor.createdAt)
            try content.bind(2, createdAtText)
            try content.bind(3, createdAtText)
            try content.bind(4, cursor.rowid)

            var contentByID: [AgentMessageID: String] = [:]
            while try content.step() {
                guard let idText = content.columnText(0),
                      let uuid = UUID(uuidString: idText)
                else { continue }
                contentByID[AgentMessageID(uuid)] = AssistantTimelineState.cappedText(content.columnText(1) ?? "")
            }

            for index in firstHydratedIndex..<rows.count {
                rows[index].content = contentByID[rows[index].id] ?? ""
            }
        }

        return AgentMessageBodyBudgetResult(rows: rows, blanked: blanked)
    }

    /// Keyset-bounded transcript page. Unlike `listWithinBodyBudget`, this never
    /// scans shells for the full thread and never asks SQLite to return more than
    /// `limit + 1` capped bodies. Repeated `before`/`after` cursors use the same
    /// (created_at,rowid) order as rendering, preventing page gaps/duplicates.
    ///
    /// - Parameters:
    ///   - appendEllipsisOnCap: When true (UI path), character-capped bodies may
    ///     gain a trailing ellipsis. Wire transport sets this false so truncation
    ///     is represented only by flags/byte counts.
    public func listPageWithinBodyBudget(
        threadId: AgentThreadID,
        limit requestedLimit: Int,
        before beforeCursor: AgentMessageCursor? = nil,
        after afterCursor: AgentMessageCursor? = nil,
        budget: Int,
        contentLimit: Int = AssistantTimelineState.liveTextLimit,
        appendEllipsisOnCap: Bool = true,
        attachmentsByteLimit: Int = 64 * 1_024,
        attachmentsCountLimit: Int = 32
    ) throws -> AgentMessageBodyBudgetResult {
        try db.performSync { database in
        let limit = max(1, min(requestedLimit, 500))
        let cappedByteLimit = max(1, contentLimit)
        let cappedAttachmentsByteLimit = max(2, attachmentsByteLimit)
        let cappedAttachmentsCountLimit = max(0, attachmentsCountLimit)
        guard beforeCursor == nil || afterCursor == nil else {
            throw AgentMessagePageCursorError.staleOrInvalid
        }
        let requestedCursor = afterCursor ?? beforeCursor
        let cursorRowID: Int64?
        if let requestedCursor {
            let validation = try database.prepare("""
                SELECT rowid, created_at, body_revision
                FROM agent_messages
                WHERE id = ? AND thread_id = ?
                LIMIT 1;
                """)
            try validation.bind(
                1,
                requestedCursor.id.value.uuidString
            )
            try validation.bind(2, threadId.value.uuidString)
            guard try validation.step(),
                  validation.columnText(1)
                    == iso.string(from: requestedCursor.createdAt),
                  validation.columnInt64(2) >= 1 else {
                throw AgentMessagePageCursorError.staleOrInvalid
            }
            cursorRowID = validation.columnInt64(0)
        } else {
            cursorRowID = nil
        }
        let afterDirection = afterCursor != nil
        let predicate: String
        let orderDesc: String
        let orderAsc: String
        let windowOrder: String
        if let _ = afterCursor {
            predicate = "thread_id = ? AND (created_at > ? OR (created_at = ? AND rowid > ?))"
            orderDesc = "created_at ASC, rowid ASC"
            orderAsc = "created_at ASC, rowid ASC"
            windowOrder = "created_at ASC, rowid ASC"
        } else if beforeCursor == nil {
            predicate = "thread_id = ?"
            orderDesc = "created_at DESC, rowid DESC"
            orderAsc = "created_at ASC, rowid ASC"
            windowOrder = "created_at DESC, rowid DESC"
        } else {
            predicate = "thread_id = ? AND (created_at < ? OR (created_at = ? AND rowid < ?))"
            orderDesc = "created_at DESC, rowid DESC"
            orderAsc = "created_at ASC, rowid ASC"
            windowOrder = "created_at DESC, rowid DESC"
        }
        let statement = try database.prepare("""
            WITH candidates AS (
                SELECT rowid, id, thread_id, role,
                       substr(CAST(content AS BLOB), 1, ?) AS capped_content,
                       length(CAST(content AS BLOB)) AS body_bytes,
                       created_at,
                       CASE
                         WHEN length(CAST(attachments_json AS BLOB)) <= ?
                         THEN attachments_json
                         ELSE '[]'
                       END AS capped_attachments_json,
                       CASE
                         WHEN json_valid(attachments_json)
                              AND json_type(attachments_json) = 'array'
                         THEN json_array_length(attachments_json)
                         ELSE 0
                       END AS attachment_count,
                       length(CAST(attachments_json AS BLOB)) AS attachment_bytes
                FROM agent_messages
                WHERE \(predicate)
                ORDER BY \(orderDesc)
                LIMIT ?
            ), ranked AS (
                SELECT *,
                       ROW_NUMBER() OVER (ORDER BY \(windowOrder)) AS row_number,
                       SUM(MIN(body_bytes, ?)) OVER (
                           ORDER BY \(windowOrder)
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                       ) AS running_bytes,
                       COUNT(*) OVER () AS candidate_count
                FROM candidates
            )
            SELECT id, thread_id, role, capped_content, created_at,
                   capped_attachments_json, body_bytes, candidate_count,
                   attachment_count, attachment_bytes
            FROM ranked
            WHERE row_number <= ?
              AND (running_bytes <= ? OR row_number = 1)
            ORDER BY \(orderAsc);
        """)
        var index: Int32 = 1
        try statement.bind(index, cappedByteLimit); index += 1
        try statement.bind(index, cappedAttachmentsByteLimit); index += 1
        try statement.bind(index, threadId.value.uuidString); index += 1
        if let cursor = afterCursor ?? beforeCursor {
            let created = iso.string(from: cursor.createdAt)
            try statement.bind(index, created); index += 1
            try statement.bind(index, created); index += 1
            guard let cursorRowID else {
                throw AgentMessagePageCursorError.staleOrInvalid
            }
            try statement.bind(index, cursorRowID); index += 1
        }
        try statement.bind(index, limit + 1); index += 1
        try statement.bind(index, cappedByteLimit); index += 1
        try statement.bind(index, limit); index += 1
        try statement.bind(index, max(1, budget))

        var rows: [AgentMessage] = []
        var originalByteCounts: [AgentMessageID: Int] = [:]
        var truncatedIDs: Set<AgentMessageID> = []
        var attachmentCounts: [AgentMessageID: Int] = [:]
        var attachmentTruncatedIDs: Set<AgentMessageID> = []
        var candidateCount = 0
        while try statement.step() {
            guard let idText = statement.columnText(0), let id = UUID(uuidString: idText),
                  let threadText = statement.columnText(1), let threadUUID = UUID(uuidString: threadText),
                  let roleText = statement.columnText(2), let role = AgentMessageRole(rawValue: roleText),
                  let createdText = statement.columnText(4), let createdAt = iso.date(from: createdText)
            else { continue }
            let rawContent = utf8Prefix(from: statement.columnBlob(3))
            let originalBytes = Int(statement.columnInt64(6))
            let messageID = AgentMessageID(id)
            originalByteCounts[messageID] = originalBytes
            let content: String
            if originalBytes > rawContent.utf8.count {
                truncatedIDs.insert(messageID)
                content = appendEllipsisOnCap
                    ? AssistantTimelineState.cappedText(rawContent + "…")
                    : rawContent
            } else {
                content = rawContent
            }
            candidateCount = max(candidateCount, Int(statement.columnInt64(7)))
            let attachmentCount = max(0, Int(statement.columnInt64(8)))
            let attachmentBytes = max(0, Int(statement.columnInt64(9)))
            attachmentCounts[messageID] = attachmentCount
            let decodedAttachments = decodeAttachments(statement.columnText(5))
            let attachments = Array(
                decodedAttachments.prefix(cappedAttachmentsCountLimit)
            )
            if attachmentBytes > cappedAttachmentsByteLimit
                || attachmentCount > attachments.count {
                attachmentTruncatedIDs.insert(messageID)
            }
            rows.append(AgentMessage(
                id: messageID,
                threadId: AgentThreadID(threadUUID),
                role: role,
                content: content,
                createdAt: createdAt,
                attachments: attachments
            ))
        }
        let budgetDropped = max(0, min(candidateCount, limit) - rows.count)
        let hasMoreFromLimit = candidateCount > limit
        let hasMoreOlder: Bool
        let hasMoreNewer: Bool
        if afterDirection {
            hasMoreOlder = true
            hasMoreNewer = hasMoreFromLimit || budgetDropped > 0 || candidateCount > rows.count
        } else {
            hasMoreOlder = hasMoreFromLimit || budgetDropped > 0 || candidateCount > rows.count
            hasMoreNewer = beforeCursor != nil
        }
        return AgentMessageBodyBudgetResult(
            rows: rows,
            blanked: max(0, candidateCount - rows.count),
            hasMoreOlder: hasMoreOlder,
            nextBefore: rows.first.map { AgentMessageCursor(createdAt: $0.createdAt, id: $0.id) },
            hasMoreNewer: hasMoreNewer,
            nextAfter: rows.last.map { AgentMessageCursor(createdAt: $0.createdAt, id: $0.id) },
            originalByteCounts: originalByteCounts,
            truncatedIDs: truncatedIDs,
            attachmentCounts: attachmentCounts,
            attachmentTruncatedIDs: attachmentTruncatedIDs,
            prefersNewestBodies: !afterDirection
        )
        }
    }

    /// SQLite returns a byte-capped BLOB so the full body never crosses the
    /// decode boundary. A cap can land inside the final scalar; remove at most
    /// three continuation bytes until the prefix is valid UTF-8.
    private func utf8Prefix(from blob: Data?) -> String {
        guard var bytes = blob else { return "" }
        for _ in 0..<4 {
            if let text = String(data: bytes, encoding: .utf8) {
                return text
            }
            guard !bytes.isEmpty else { break }
            bytes.removeLast()
        }
        return ""
    }

    public func count(threadId: AgentThreadID) throws -> Int {
        let st = try db.prepare("SELECT COUNT(*) FROM agent_messages WHERE thread_id = ?;")
        try st.bind(1, threadId.value.uuidString)
        return (try st.step()) ? Int(st.columnInt64(0)) : 0
    }

    /// PERF-006: the set of thread ids that have at least one message,
    /// computed in a single query. Lets thread-list payloads derive
    /// `provider_locked` for every thread without one query per thread.
    public func threadIdsWithMessages() throws -> Set<AgentThreadID> {
        let st = try db.prepare("SELECT DISTINCT thread_id FROM agent_messages;")
        var out: Set<AgentThreadID> = []
        while try st.step() {
            if let uuid = (st.columnText(0)).flatMap({ UUID(uuidString: $0) }) {
                out.insert(AgentThreadID(uuid))
            }
        }
        return out
    }

    /// The newest `limit` messages, returned oldest→newest for display.
    /// Backs the bounded message window (B4 pagination).
    public func listRecent(threadId: AgentThreadID, limit: Int) throws -> [AgentMessage] {
        let st = try db.prepare("SELECT id, thread_id, role, content, created_at, attachments_json FROM agent_messages WHERE thread_id = ? ORDER BY created_at DESC, id DESC LIMIT ?;")
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, max(0, limit))
        var out: [AgentMessage] = []
        while try st.step() {
            out.append(message(from: st))
        }
        // PERF: reverse() in-place avoids allocating a second Array copy.
        // Result is identical: rows were fetched newest-first (DESC), reversing
        // gives oldest-first display order, same as the previous out.reversed().
        out.reverse()
        return out
    }

    public func get(id: AgentMessageID) throws -> AgentMessage? {
        let st = try db.prepare("SELECT id, thread_id, role, content, created_at, attachments_json FROM agent_messages WHERE id = ? LIMIT 1;")
        try st.bind(1, id.value.uuidString)
        return (try st.step()) ? message(from: st) : nil
    }

    /// Reads one bounded UTF-8 body page directly from SQLite. Offset zero is
    /// the only page that crosses message metadata/attachment JSON. Later pages
    /// select immutable body identity plus `substr(CAST(content AS BLOB), …)`.
    ///
    /// Existing pre-v57 rows have their digest materialized once on the first
    /// offset-zero request. No continuation request reads or hashes the full
    /// body.
    public func bodyChunk(
        id: AgentMessageID,
        offsetBytes: Int,
        maxContentBytes: Int,
        expectedBodyRevision: Int?,
        expectedBodySHA256: String?
    ) throws -> AgentMessageBodyChunk? {
        guard offsetBytes >= 0, maxContentBytes > 0 else {
            throw AgentMessageBodyChunkError.invalidOffset
        }
        if offsetBytes == 0 {
            guard try materializeBodyIdentityIfNeeded(id: id) else {
                return nil
            }
            return try offsetZeroBodyChunk(
                id: id,
                maxContentBytes: maxContentBytes
            )
        }
        guard let expectedBodyRevision else {
            throw AgentMessageBodyChunkError.bodyRevisionConflict
        }
        guard let expectedBodySHA256 else {
            throw AgentMessageBodyChunkError.bodyDigestMismatch
        }
        return try continuationBodyChunk(
            id: id,
            offsetBytes: offsetBytes,
            maxContentBytes: maxContentBytes,
            expectedBodyRevision: expectedBodyRevision,
            expectedBodySHA256: expectedBodySHA256.lowercased()
        )
    }

    private func materializeBodyIdentityIfNeeded(
        id: AgentMessageID
    ) throws -> Bool {
        try db.transaction {
            let identity = try db.prepare("""
                SELECT body_sha256, body_bytes, body_revision
                FROM agent_messages
                WHERE id = ?
                LIMIT 1;
                """)
            try identity.bind(1, id.value.uuidString)
            guard try identity.step() else { return false }
            if !identity.columnIsNull(0), !identity.columnIsNull(1) {
                return true
            }
            let revision = max(1, Int(identity.columnInt64(2)))
            let body = try db.prepare("""
                SELECT content
                FROM agent_messages
                WHERE id = ? AND body_revision = ?
                LIMIT 1;
                """)
            try body.bind(1, id.value.uuidString)
            try body.bind(2, revision)
            guard try body.step(), let content = body.columnText(0) else {
                throw AgentMessageBodyChunkError.bodyIdentityUnavailable
            }
            let digest = Self.bodySHA256Hex(content)
            let bytes = content.utf8.count
            let update = try db.prepare("""
                UPDATE agent_messages
                SET body_sha256 = ?, body_bytes = ?
                WHERE id = ? AND body_revision = ?
                  AND body_sha256 IS NULL;
                """)
            try update.bind(1, digest)
            try update.bind(2, bytes)
            try update.bind(3, id.value.uuidString)
            try update.bind(4, revision)
            _ = try update.step()
            return true
        }
    }

    private func offsetZeroBodyChunk(
        id: AgentMessageID,
        maxContentBytes: Int
    ) throws -> AgentMessageBodyChunk? {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT thread_id, role, created_at,
                       CASE
                         WHEN length(CAST(attachments_json AS BLOB)) <= 16384
                         THEN attachments_json
                         ELSE '[]'
                       END,
                       CASE
                         WHEN json_valid(attachments_json)
                              AND json_type(attachments_json) = 'array'
                         THEN json_array_length(attachments_json)
                         ELSE 0
                       END,
                       length(CAST(attachments_json AS BLOB)),
                       body_bytes, body_sha256, body_revision,
                       substr(CAST(content AS BLOB), 1, ?)
                FROM agent_messages
                WHERE id = ?
                LIMIT 1;
                """)
            try statement.bind(1, maxContentBytes + 3)
            try statement.bind(2, id.value.uuidString)
            guard try statement.step() else { return nil }
            guard let threadText = statement.columnText(0),
                  let threadUUID = UUID(uuidString: threadText),
                  let roleText = statement.columnText(1),
                  let role = AgentMessageRole(rawValue: roleText),
                  let createdText = statement.columnText(2),
                  let createdAt = iso.date(from: createdText),
                  !statement.columnIsNull(6),
                  let digest = statement.columnText(7) else {
                throw AgentMessageBodyChunkError.bodyIdentityUnavailable
            }
            let bodyBytes = max(0, Int(statement.columnInt64(6)))
            let revision = max(1, Int(statement.columnInt64(8)))
            let rawAttachments = decodeAttachments(statement.columnText(3))
            let attachmentCount = max(0, Int(statement.columnInt64(4)))
            let attachmentBytes = max(0, Int(statement.columnInt64(5)))
            let attachments = Array(rawAttachments.prefix(32))
            let content = try Self.utf8Chunk(
                statement.columnBlob(9) ?? Data(),
                offsetBytes: 0,
                totalBytes: bodyBytes,
                maximumBytes: maxContentBytes
            )
            return AgentMessageBodyChunk(
                id: id,
                content: content,
                bodyByteCount: bodyBytes,
                bodySHA256: digest.lowercased(),
                bodyRevision: revision,
                bodyOffset: 0,
                metadata: AgentMessageBodyChunkMetadata(
                    threadId: AgentThreadID(threadUUID),
                    role: role,
                    createdAt: createdAt,
                    attachments: attachments,
                    attachmentCount: attachmentCount,
                    attachmentsTruncated:
                        attachmentBytes > 16 * 1_024
                        || attachments.count < attachmentCount
                )
            )
        }
    }

    private func continuationBodyChunk(
        id: AgentMessageID,
        offsetBytes: Int,
        maxContentBytes: Int,
        expectedBodyRevision: Int,
        expectedBodySHA256: String
    ) throws -> AgentMessageBodyChunk? {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT body_bytes, body_sha256, body_revision,
                       substr(CAST(content AS BLOB), ? + 1, ?)
                FROM agent_messages
                WHERE id = ?
                LIMIT 1;
                """)
            try statement.bind(1, offsetBytes)
            try statement.bind(2, maxContentBytes + 3)
            try statement.bind(3, id.value.uuidString)
            guard try statement.step() else { return nil }
            let revision = max(1, Int(statement.columnInt64(2)))
            guard revision == expectedBodyRevision else {
                throw AgentMessageBodyChunkError.bodyRevisionConflict
            }
            guard !statement.columnIsNull(0),
                  let digest = statement.columnText(1) else {
                throw AgentMessageBodyChunkError.bodyIdentityUnavailable
            }
            let bodyBytes = max(0, Int(statement.columnInt64(0)))
            guard digest.lowercased() == expectedBodySHA256 else {
                throw AgentMessageBodyChunkError.bodyDigestMismatch
            }
            guard offsetBytes <= bodyBytes else {
                throw AgentMessageBodyChunkError.invalidOffset
            }
            let content = try Self.utf8Chunk(
                statement.columnBlob(3) ?? Data(),
                offsetBytes: offsetBytes,
                totalBytes: bodyBytes,
                maximumBytes: maxContentBytes
            )
            return AgentMessageBodyChunk(
                id: id,
                content: content,
                bodyByteCount: bodyBytes,
                bodySHA256: digest.lowercased(),
                bodyRevision: revision,
                bodyOffset: offsetBytes,
                metadata: nil
            )
        }
    }

    /// F13: the earliest user message for a thread, fetched directly (LIMIT 1)
    /// instead of materializing the whole message history. Backs placeholder-title
    /// repair, which only needs the first user message's text and otherwise loaded
    /// every message + content blob per placeholder thread on the main actor.
    public func firstUserMessage(threadId: AgentThreadID) throws -> AgentMessage? {
        let st = try db.prepare("SELECT id, thread_id, role, content, created_at, attachments_json FROM agent_messages WHERE thread_id = ? AND role = 'user' ORDER BY created_at ASC, rowid ASC LIMIT 1;")
        try st.bind(1, threadId.value.uuidString)
        return (try st.step()) ? message(from: st) : nil
    }

    public func listPage(threadId: AgentThreadID, limit requestedLimit: Int, before cursor: AgentMessageCursor?) throws -> AgentMessagePage {
        try listPage(threadId: threadId, limit: requestedLimit, before: cursor, after: nil)
    }

    public func listPage(threadId: AgentThreadID, limit requestedLimit: Int, after cursor: AgentMessageCursor?) throws -> AgentMessagePage {
        try listPage(threadId: threadId, limit: requestedLimit, before: nil, after: cursor)
    }

    public func listPage(threadId: AgentThreadID, limit requestedLimit: Int, before beforeCursor: AgentMessageCursor?, after afterCursor: AgentMessageCursor?) throws -> AgentMessagePage {
        let limit = max(0, min(requestedLimit, 500))
        let sql: String
        // PERSISTENCE-DATA-004: the ORDER BY tiebreaks on rowid (insertion order,
        // a deliberate UX choice — see MessageOrderingTieBreakerTests), but the
        // keyset predicate tiebroke on `id` (UUID). UUID order is unrelated to
        // rowid order, so rows sharing a created_at (stored at second precision,
        // so ties are common) could be skipped or duplicated at a page boundary.
        // Fix: tiebreak the predicate on rowid too, resolving the cursor message's
        // rowid via subquery. This keeps the public {createdAt, id} cursor shape
        // unchanged while making WHERE and ORDER BY use the same key.
        if let _ = afterCursor {
            sql = """
            SELECT id, thread_id, role, content, created_at, attachments_json
            FROM agent_messages
            WHERE thread_id = ? AND (created_at > ? OR (created_at = ? AND rowid > (SELECT rowid FROM agent_messages WHERE id = ?)))
            ORDER BY created_at ASC, rowid ASC
            LIMIT ?;
            """
        } else if beforeCursor == nil {
            sql = "SELECT id, thread_id, role, content, created_at, attachments_json FROM agent_messages WHERE thread_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?;"
        } else {
            sql = """
            SELECT id, thread_id, role, content, created_at, attachments_json
            FROM agent_messages
            WHERE thread_id = ? AND (created_at < ? OR (created_at = ? AND rowid < (SELECT rowid FROM agent_messages WHERE id = ?)))
            ORDER BY created_at DESC, rowid DESC
            LIMIT ?;
            """
        }
        let st = try db.prepare(sql)
        try st.bind(1, threadId.value.uuidString)
        if let cursor = afterCursor {
            let created = iso.string(from: cursor.createdAt)
            try st.bind(2, created)
            try st.bind(3, created)
            try st.bind(4, cursor.id.value.uuidString)
            try st.bind(5, limit + 1)
        } else if let cursor = beforeCursor {
            let created = iso.string(from: cursor.createdAt)
            try st.bind(2, created)
            try st.bind(3, created)
            try st.bind(4, cursor.id.value.uuidString)
            try st.bind(5, limit + 1)
        } else {
            try st.bind(2, limit + 1)
        }
        var rows: [AgentMessage] = []
        while try st.step() {
            rows.append(message(from: st))
        }
        let pageRows = Array(rows.prefix(limit))
        let display = afterCursor == nil ? Array(pageRows.reversed()) : pageRows
        let next = display.first.map { AgentMessageCursor(createdAt: $0.createdAt, id: $0.id) }
        let after = display.last.map { AgentMessageCursor(createdAt: $0.createdAt, id: $0.id) }
        return AgentMessagePage(
            messages: display,
            hasMoreOlder: afterCursor != nil || rows.count > limit,
            nextBefore: next,
            hasMoreNewer: beforeCursor != nil || (afterCursor != nil && rows.count > limit),
            nextAfter: after
        )
    }

    /// SHA-256 hex of the full message body (durable `body_sha256` column / wire digest).
    ///
    /// Hashes contiguous UTF-8 storage without a `Data(text.utf8)` intermediate, and
    /// formats hex with a nibble table instead of per-byte `String(format:)`. Must stay
    /// byte-identical to `AgentMessageTransport.bodySHA256Hex` (same lowercase digest).
    private static func bodySHA256Hex(_ text: String) -> String {
        var hasher = SHA256()
        var copy = text
        copy.withUTF8 { buffer in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
        return hexDigest(hasher.finalize())
    }

    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    private static func utf8Chunk(
        _ source: Data,
        offsetBytes: Int,
        totalBytes: Int,
        maximumBytes: Int
    ) throws -> String {
        guard offsetBytes <= totalBytes else {
            throw AgentMessageBodyChunkError.invalidOffset
        }
        if offsetBytes < totalBytes,
           let first = source.first,
           first & 0xC0 == 0x80 {
            throw AgentMessageBodyChunkError.invalidOffset
        }
        var bytes = Data(source.prefix(maximumBytes))
        for _ in 0..<4 {
            if let text = String(data: bytes, encoding: .utf8) {
                if text.isEmpty, offsetBytes < totalBytes {
                    throw AgentMessageBodyChunkError.invalidOffset
                }
                return text
            }
            guard !bytes.isEmpty else { break }
            bytes.removeLast()
        }
        throw AgentMessageBodyChunkError.invalidOffset
    }

    private func message(from st: SQLiteStatement) -> AgentMessage {
        let id = AgentMessageID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID())
        let tid = AgentThreadID(UUID(uuidString: st.columnText(1) ?? "") ?? UUID())
        return AgentMessage(
            id: id,
            threadId: tid,
            role: AgentMessageRole(rawValue: st.columnText(2) ?? "") ?? .user,
            content: st.columnText(3) ?? "",
            createdAt: parseDate(st.columnText(4)),
            attachments: decodeAttachments(st.columnText(5))
        )
    }

    private func attachmentsJSON(_ attachments: [AgentAttachment]) throws -> String {
        let data = try encoder.encode(attachments)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SQLiteError.execute("Unable to encode message attachments as UTF-8 JSON.")
        }
        return json
    }

    private func decodeAttachments(_ json: String?) -> [AgentAttachment] {
        guard let json,
              let data = json.data(using: .utf8),
              let attachments = try? decoder.decode([AgentAttachment].self, from: data) else { return [] }
        return attachments
    }

    public func delete(ids: [AgentMessageID]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.transaction {
            let st = try db.prepare("DELETE FROM agent_messages WHERE id IN (\(placeholders));")
            for (index, id) in ids.enumerated() {
                try st.bind(Int32(index + 1), id.value.uuidString)
            }
            _ = try st.step()
        }
    }
}

public final class AgentThreadDraftRepository {
    let db: SQLiteDB
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(db: SQLiteDB) { self.db = db }

    public func upsert(_ draft: AgentThreadDraft) throws {
        let attachmentData = try encoder.encode(draft.attachments)
        guard let attachmentsJSON = String(data: attachmentData, encoding: .utf8) else {
            throw SQLiteError.execute("Unable to encode draft attachments as UTF-8 JSON.")
        }
        let statement = try db.prepare("""
            INSERT INTO agent_thread_drafts(
                thread_id, provider_instance_id, text, attachments_json, interaction_mode, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id, provider_instance_id) DO UPDATE SET
                text=excluded.text,
                attachments_json=excluded.attachments_json,
                interaction_mode=excluded.interaction_mode,
                updated_at=excluded.updated_at;
        """)
        try statement.bind(1, draft.threadId.value.uuidString)
        try statement.bind(2, draft.providerInstanceId)
        try statement.bind(3, draft.text)
        try statement.bind(4, attachmentsJSON)
        try statement.bind(5, draft.interactionMode.rawValue)
        try statement.bind(6, iso.string(from: draft.updatedAt))
        _ = try statement.step()
    }

    public func get(threadId: AgentThreadID) throws -> AgentThreadDraft? {
        try get(threadId: threadId, providerInstanceId: nil)
    }

    public func get(threadId: AgentThreadID, providerInstanceId: String) throws -> AgentThreadDraft? {
        try get(threadId: threadId, providerInstanceId: Optional(providerInstanceId))
    }

    private func get(threadId: AgentThreadID, providerInstanceId: String?) throws -> AgentThreadDraft? {
        let providerPredicate = providerInstanceId == nil ? "" : " AND provider_instance_id = ?"
        let statement = try db.prepare("""
            SELECT thread_id, provider_instance_id, text, attachments_json, interaction_mode, updated_at
            FROM agent_thread_drafts
            WHERE thread_id = ?\(providerPredicate)
            ORDER BY updated_at DESC
            LIMIT 1;
        """)
        try statement.bind(1, threadId.value.uuidString)
        if let providerInstanceId { try statement.bind(2, providerInstanceId) }
        guard try statement.step() else { return nil }
        let attachments: [AgentAttachment]
        if let json = statement.columnText(3),
           let data = json.data(using: .utf8),
           let decoded = try? decoder.decode([AgentAttachment].self, from: data) {
            attachments = decoded
        } else {
            attachments = []
        }
        return AgentThreadDraft(
            threadId: threadId,
            providerInstanceId: statement.columnText(1) ?? "",
            text: statement.columnText(2) ?? "",
            attachments: attachments,
            interactionMode: AgentInteractionMode(rawValue: statement.columnText(4) ?? "") ?? .default,
            updatedAt: parseDate(statement.columnText(5))
        )
    }

    public func delete(threadId: AgentThreadID) throws {
        let statement = try db.prepare("DELETE FROM agent_thread_drafts WHERE thread_id = ?;")
        try statement.bind(1, threadId.value.uuidString)
        _ = try statement.step()
    }

    public func delete(threadId: AgentThreadID, providerInstanceId: String) throws {
        let statement = try db.prepare("DELETE FROM agent_thread_drafts WHERE thread_id = ? AND provider_instance_id = ?;")
        try statement.bind(1, threadId.value.uuidString)
        try statement.bind(2, providerInstanceId)
        _ = try statement.step()
    }
}

public enum AgentQueuedMessageDispatchState: String, Sendable, Equatable {
    case queued
    case prepared
    case dispatched
}

public struct AgentQueuedMessageLease: Sendable, Equatable {
    public let message: AgentQueuedMessage
    public let leaseId: String
    public let dispatchState: AgentQueuedMessageDispatchState
    public let dispatchRunId: AgentRunID?

    init(
        message: AgentQueuedMessage,
        leaseId: String,
        dispatchState: AgentQueuedMessageDispatchState = .queued,
        dispatchRunId: AgentRunID? = nil
    ) {
        self.message = message
        self.leaseId = leaseId
        self.dispatchState = dispatchState
        self.dispatchRunId = dispatchRunId
    }
}

public struct AgentQueuedMessageDispatch: Sendable, Equatable {
    public let message: AgentQueuedMessage
    public let state: AgentQueuedMessageDispatchState
    public let runId: AgentRunID?
}

public enum AgentQueuedMessageMutationError: Error, Equatable {
    case queueIsLeased
}

public final class AgentQueuedMessageRepository {
    let db: SQLiteDB
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(db: SQLiteDB) { self.db = db }

    public func enqueue(
        threadId: AgentThreadID,
        text: String,
        attachments: [AgentAttachment],
        interactionMode: AgentInteractionMode,
        routingConfiguration: AgentRoutingConfiguration? = nil,
        routingSnapshot: AgentQueuedMessageRoutingSnapshot? = nil
    ) throws -> AgentQueuedMessage {
        let position = try nextPosition(threadId: threadId)
        let queued = AgentQueuedMessage(
            threadId: threadId,
            text: text,
            attachments: attachments,
            interactionMode: interactionMode,
            position: position,
            routingSnapshot: routingSnapshot ?? routingConfiguration.map { AgentQueuedMessageRoutingSnapshot(configuration: $0) }
        )
        try upsert(queued, routingConfiguration: routingConfiguration, routingSnapshot: routingSnapshot)
        return queued
    }

    /// Commits the queued work and consumes the matching composer draft in one
    /// transaction. A draft-delete failure rolls the queue insert back, so a
    /// relaunch cannot restore a prompt that was already reported as queued.
    public func enqueueConsumingDraft(
        threadId: AgentThreadID,
        providerInstanceId: String,
        text: String,
        attachments: [AgentAttachment],
        interactionMode: AgentInteractionMode,
        routingConfiguration: AgentRoutingConfiguration? = nil,
        queuedRoutingSnapshot: AgentQueuedMessageRoutingSnapshot? = nil
    ) throws -> AgentQueuedMessage {
        try db.performSync { database in
            try database.transaction {
                let positionStatement = try database.prepare(
                    "SELECT COALESCE(MAX(position), 0) + 1 FROM agent_queued_messages WHERE thread_id = ?;"
                )
                try positionStatement.bind(1, threadId.value.uuidString)
                let position = try positionStatement.step() ? Int(positionStatement.columnInt64(0)) : 1
                let queued = AgentQueuedMessage(
                    threadId: threadId,
                    text: text,
                    attachments: attachments,
                    interactionMode: interactionMode,
                    position: position,
                    routingSnapshot: queuedRoutingSnapshot ?? routingConfiguration.map { AgentQueuedMessageRoutingSnapshot(configuration: $0) }
                )
                let insert = try database.prepare("""
                    INSERT INTO agent_queued_messages(id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?);
                """)
                try insert.bind(1, queued.id.value.uuidString)
                try insert.bind(2, queued.threadId.value.uuidString)
                try insert.bind(3, queued.text)
                try insert.bind(4, attachmentsJSON(queued.attachments))
                try insert.bind(5, queued.interactionMode.rawValue)
                try insert.bind(6, Int64(queued.position))
                try insert.bind(7, iso.string(from: queued.createdAt))
                try insert.bind(8, iso.string(from: queued.updatedAt))
                _ = try insert.step()

                if let routingSnapshot = queued.routingSnapshot {
                    try persistRoutingSnapshot(routingSnapshot, queuedMessageId: queued.id, database: database)
                }

                let deleteDraft = try database.prepare(
                    "DELETE FROM agent_thread_drafts WHERE thread_id = ? AND provider_instance_id = ?;"
                )
                try deleteDraft.bind(1, threadId.value.uuidString)
                try deleteDraft.bind(2, providerInstanceId)
                _ = try deleteDraft.step()
                return queued
            }
        }
    }

    public func upsert(
        _ message: AgentQueuedMessage,
        routingConfiguration: AgentRoutingConfiguration? = nil,
        routingSnapshot: AgentQueuedMessageRoutingSnapshot? = nil
    ) throws {
        try db.performSync { database in try database.transaction {
                if try rowExists(message.id), try threadHasActiveLease(message.threadId) {
                    throw AgentQueuedMessageMutationError.queueIsLeased
                }
                let st = try database.prepare("""
                    INSERT INTO agent_queued_messages(id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET text=excluded.text, attachments_json=excluded.attachments_json, interaction_mode=excluded.interaction_mode, position=excluded.position, updated_at=excluded.updated_at;
                """)
                try st.bind(1, message.id.value.uuidString)
                try st.bind(2, message.threadId.value.uuidString)
                try st.bind(3, message.text)
                try st.bind(4, attachmentsJSON(message.attachments))
                try st.bind(5, message.interactionMode.rawValue)
                try st.bind(6, Int64(message.position))
                try st.bind(7, iso.string(from: message.createdAt))
                try st.bind(8, iso.string(from: message.updatedAt))
                _ = try st.step()
                if let routingSnapshot = routingSnapshot ?? message.routingSnapshot {
                    try persistRoutingSnapshot(routingSnapshot, queuedMessageId: message.id, database: database)
                } else if let routingConfiguration {
                    try persistRoutingSnapshot(
                        AgentQueuedMessageRoutingSnapshot(configuration: routingConfiguration),
                        queuedMessageId: message.id,
                        database: database
                    )
                }
        } }
    }

    public func routingConfiguration(id: AgentQueuedMessageID) throws -> AgentRoutingConfiguration? {
        try routingSnapshot(id: id)?.configuration
    }

    public func routingSnapshot(id: AgentQueuedMessageID) throws -> AgentQueuedMessageRoutingSnapshot? {
        let statement = try db.prepare("""
            SELECT configuration_json, revision, deadline_at, budget_tokens,
                   budget_cost_micros, reservation_id, reserved_tokens,
                   reserved_cost_micros, admission_receipt_id
            FROM agent_queued_message_routing
            WHERE queued_message_id = ?;
        """)
        try statement.bind(1, id.value.uuidString)
        guard try statement.step() else { return nil }
        let configuration = try decodeRoutingConfiguration(
            json: statement.columnText(0),
            storedMode: nil,
            storedRevision: Int(statement.columnInt64(1))
        )
        return AgentQueuedMessageRoutingSnapshot(
            configuration: configuration,
            deadlineAt: statement.columnText(2).flatMap(iso.date(from:)),
            budgetTokens: statement.columnIsNull(3) ? nil : Int(statement.columnInt64(3)),
            budgetCostMicros: statement.columnIsNull(4) ? nil : Int(statement.columnInt64(4)),
            reservationId: statement.columnText(5),
            reservedTokens: statement.columnIsNull(6) ? nil : Int(statement.columnInt64(6)),
            reservedCostMicros: statement.columnIsNull(7) ? nil : Int(statement.columnInt64(7)),
            admissionReceiptId: statement.columnText(8).flatMap(UUID.init(uuidString:))
        )
    }

    private func persistRoutingSnapshot(
        _ snapshot: AgentQueuedMessageRoutingSnapshot,
        queuedMessageId: AgentQueuedMessageID,
        database: SQLiteDB
    ) throws {
        let statement = try database.prepare("""
            INSERT INTO agent_queued_message_routing(
                queued_message_id, configuration_json, revision, created_at,
                deadline_at, budget_tokens, budget_cost_micros, reservation_id,
                reserved_tokens, reserved_cost_micros, admission_receipt_id
            )
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(queued_message_id) DO UPDATE SET
                configuration_json=excluded.configuration_json,
                revision=excluded.revision,
                deadline_at=excluded.deadline_at,
                budget_tokens=excluded.budget_tokens,
                budget_cost_micros=excluded.budget_cost_micros,
                reservation_id=excluded.reservation_id,
                reserved_tokens=excluded.reserved_tokens,
                reserved_cost_micros=excluded.reserved_cost_micros,
                admission_receipt_id=excluded.admission_receipt_id;
        """)
        try statement.bind(1, queuedMessageId.value.uuidString)
        try statement.bind(2, try encodeRoutingConfiguration(snapshot.configuration))
        try statement.bind(3, snapshot.configuration.revision)
        try statement.bind(4, iso.string(from: snapshot.configuration.updatedAt))
        try statement.bind(5, snapshot.deadlineAt.map(iso.string(from:)))
        try statement.bind(6, snapshot.budgetTokens)
        try statement.bind(7, snapshot.budgetCostMicros)
        try statement.bind(8, snapshot.reservationId)
        try statement.bind(9, snapshot.reservedTokens)
        try statement.bind(10, snapshot.reservedCostMicros)
        try statement.bind(11, snapshot.admissionReceiptId?.uuidString)
        _ = try statement.step()
    }

    public func list(threadId: AgentThreadID) throws -> [AgentQueuedMessage] {
        let st = try db.prepare("""
            SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at,
                   dispatch_state
            FROM agent_queued_messages
            WHERE thread_id = ?
            ORDER BY position ASC, created_at ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        var out: [AgentQueuedMessage] = []
        while try st.step() {
            out.append(decodeRow(st, durableStateColumn: 8))
        }
        return out
    }

    public func first(threadId: AgentThreadID) throws -> AgentQueuedMessage? {
        let st = try db.prepare("""
            SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at,
                   dispatch_state
            FROM agent_queued_messages
            WHERE thread_id = ?
            ORDER BY position ASC, created_at ASC
            LIMIT 1;
        """)
        try st.bind(1, threadId.value.uuidString)
        return try st.step() ? decodeRow(st, durableStateColumn: 8) : nil
    }

    public func threadIdsWithQueuedMessages() throws -> [AgentThreadID] {
        let st = try db.prepare("""
            SELECT DISTINCT thread_id
            FROM agent_queued_messages
            ORDER BY thread_id ASC;
        """)
        var ids: [AgentThreadID] = []
        while try st.step() {
            guard let raw = st.columnText(0), let uuid = UUID(uuidString: raw) else { continue }
            ids.append(AgentThreadID(uuid))
        }
        return ids
    }

    public func claimFirst(
        threadId: AgentThreadID,
        leaseId: String = UUID().uuidString,
        now: Date = Date(),
        leaseTimeout: TimeInterval = 300
    ) throws -> AgentQueuedMessageLease? {
        var lease: AgentQueuedMessageLease?
        try db.performSync { database in try database.transaction {
            let cutoff = now.addingTimeInterval(-leaseTimeout)
            let activeLease = try database.prepare("""
                SELECT 1
                FROM agent_queued_messages
                WHERE thread_id = ? AND lease_id IS NOT NULL
                  AND lease_started_at IS NOT NULL AND lease_started_at > ?
                LIMIT 1;
            """)
            try activeLease.bind(1, threadId.value.uuidString)
            try activeLease.bind(2, iso.string(from: cutoff))
            guard try !activeLease.step() else { return }
            let select = try database.prepare("""
                SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at,
                       lease_id, lease_started_at, dispatch_state, dispatch_run_id
                FROM agent_queued_messages
                WHERE thread_id = ?
                ORDER BY position ASC, created_at ASC
                LIMIT 1;
            """)
            try select.bind(1, threadId.value.uuidString)
            guard try select.step() else { return }
            let message = decodeRow(select)
            let state = AgentQueuedMessageDispatchState(rawValue: select.columnText(10) ?? "") ?? .queued
            guard state == .queued else { return }
            if select.columnText(8) != nil,
               let started = select.columnText(9),
               started > iso.string(from: cutoff) {
                return
            }
            let update = try database.prepare("""
                UPDATE agent_queued_messages
                SET lease_id = ?, lease_started_at = ?
                WHERE id = ? AND dispatch_state = 'queued'
                  AND (lease_id IS NULL OR lease_started_at IS NULL OR lease_started_at <= ?);
            """)
            try update.bind(1, leaseId)
            try update.bind(2, iso.string(from: now))
            try update.bind(3, message.id.value.uuidString)
            try update.bind(4, iso.string(from: cutoff))
            _ = try update.step()
            guard try changedRowCount() == 1 else { return }
            lease = AgentQueuedMessageLease(message: message, leaseId: leaseId)
        } }
        return lease
    }

    public func claim(
        id: AgentQueuedMessageID,
        leaseId: String = UUID().uuidString,
        now: Date = Date(),
        leaseTimeout: TimeInterval = 300
    ) throws -> AgentQueuedMessageLease? {
        var lease: AgentQueuedMessageLease?
        try db.performSync { database in try database.transaction {
            let cutoff = now.addingTimeInterval(-leaseTimeout)
            let select = try database.prepare("""
                SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at,
                       lease_id, lease_started_at, dispatch_state, dispatch_run_id
                FROM agent_queued_messages
                WHERE id = ?;
            """)
            try select.bind(1, id.value.uuidString)
            guard try select.step() else { return }
            let message = decodeRow(select)
            let state = AgentQueuedMessageDispatchState(rawValue: select.columnText(10) ?? "") ?? .queued
            guard state == .queued else { return }
            if select.columnText(8) != nil,
               let started = select.columnText(9),
               started > iso.string(from: cutoff) {
                return
            }
            let update = try database.prepare("""
                UPDATE agent_queued_messages SET lease_id = ?, lease_started_at = ?
                WHERE id = ? AND dispatch_state = 'queued'
                  AND (lease_id IS NULL OR lease_started_at IS NULL OR lease_started_at <= ?);
            """)
            try update.bind(1, leaseId)
            try update.bind(2, iso.string(from: now))
            try update.bind(3, id.value.uuidString)
            try update.bind(4, iso.string(from: cutoff))
            _ = try update.step()
            guard try changedRowCount() == 1 else { return }
            lease = AgentQueuedMessageLease(message: message, leaseId: leaseId)
        } }
        return lease
    }

    @discardableResult
    public func release(_ lease: AgentQueuedMessageLease) throws -> Bool {
        try db.performSync { database in try database.transaction {
            let st = try database.prepare("UPDATE agent_queued_messages SET lease_id = NULL, lease_started_at = NULL WHERE id = ? AND lease_id = ? AND dispatch_state = 'queued';")
            try st.bind(1, lease.message.id.value.uuidString)
            try st.bind(2, lease.leaseId)
            _ = try st.step()
            guard try changedRowCount() == 1 else { return false }
            try normalizePositions(threadId: lease.message.threadId)
            return true
        } }
    }

    @discardableResult
    public func prepareDispatch(_ lease: AgentQueuedMessageLease, runId: AgentRunID, at date: Date = Date()) throws -> Bool {
        try db.performSync { database in
            let st = try database.prepare("""
                UPDATE agent_queued_messages
                SET dispatch_state = 'prepared', dispatch_run_id = ?, dispatch_updated_at = ?
                WHERE id = ? AND lease_id = ? AND dispatch_state = 'queued';
            """)
            try st.bind(1, runId.value.uuidString)
            try st.bind(2, iso.string(from: date))
            try st.bind(3, lease.message.id.value.uuidString)
            try st.bind(4, lease.leaseId)
            _ = try st.step()
            return try changedRowCount() == 1
        }
    }

    @discardableResult
    public func markDispatched(_ lease: AgentQueuedMessageLease, runId: AgentRunID, at date: Date = Date()) throws -> Bool {
        try db.performSync { database in
            let st = try database.prepare("""
                UPDATE agent_queued_messages
                SET dispatch_state = 'dispatched', dispatch_updated_at = ?
                WHERE id = ? AND lease_id = ? AND dispatch_state = 'prepared' AND dispatch_run_id = ?;
            """)
            try st.bind(1, iso.string(from: date))
            try st.bind(2, lease.message.id.value.uuidString)
            try st.bind(3, lease.leaseId)
            try st.bind(4, runId.value.uuidString)
            _ = try st.step()
            return try changedRowCount() == 1
        }
    }

    @discardableResult
    public func releasePrepared(
        _ lease: AgentQueuedMessageLease,
        runId: AgentRunID,
        promoting promotedId: AgentQueuedMessageID? = nil
    ) throws -> Bool {
        try db.performSync { database in try database.transaction {
            let st = try database.prepare("""
                UPDATE agent_queued_messages
                SET lease_id = NULL, lease_started_at = NULL,
                    dispatch_state = 'queued', dispatch_run_id = NULL, dispatch_updated_at = NULL
                WHERE id = ? AND lease_id = ? AND dispatch_state = 'prepared' AND dispatch_run_id = ?;
            """)
            try st.bind(1, lease.message.id.value.uuidString)
            try st.bind(2, lease.leaseId)
            try st.bind(3, runId.value.uuidString)
            _ = try st.step()
            guard try changedRowCount() == 1 else { return false }
            if let promotedId,
               let target = try get(id: promotedId),
               target.threadId == lease.message.threadId,
               target.id != lease.message.id,
               try !threadHasActiveLease(target.threadId) {
                let ordered = [target] + (try list(threadId: target.threadId))
                    .filter { $0.id != target.id }
                let now = Date()
                for (index, message) in ordered.enumerated() {
                    let update = try database.prepare("""
                        UPDATE agent_queued_messages
                        SET position = ?, updated_at = ?
                        WHERE id = ? AND lease_id IS NULL;
                    """)
                    try update.bind(1, Int64(index + 1))
                    try update.bind(2, iso.string(from: now))
                    try update.bind(3, message.id.value.uuidString)
                    _ = try update.step()
                }
            } else {
                try normalizePositions(threadId: lease.message.threadId)
            }
            return true
        } }
    }

    public func acknowledge(_ lease: AgentQueuedMessageLease) throws -> AgentQueuedMessage? {
        try db.performSync { database in
            try database.transaction {
            let select = try database.prepare("""
                SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at
                FROM agent_queued_messages
                WHERE id = ? AND lease_id = ? AND dispatch_state = 'dispatched';
            """)
            try select.bind(1, lease.message.id.value.uuidString)
            try select.bind(2, lease.leaseId)
            guard try select.step() else { return nil }
            let queued = decodeRow(select)

            let delete = try database.prepare("DELETE FROM agent_queued_messages WHERE id = ? AND lease_id = ? AND dispatch_state = 'dispatched';")
            try delete.bind(1, lease.message.id.value.uuidString)
            try delete.bind(2, lease.leaseId)
            _ = try delete.step()
            guard try changedRowCount() == 1 else { return nil }
            try normalizePositions(threadId: queued.threadId)
            return queued
            }
        }
    }

    public func dispatch(id: AgentQueuedMessageID) throws -> AgentQueuedMessageDispatch? {
        let st = try db.prepare("""
            SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at,
                   dispatch_state, dispatch_run_id
            FROM agent_queued_messages WHERE id = ?;
        """)
        try st.bind(1, id.value.uuidString)
        guard try st.step() else { return nil }
        let state = AgentQueuedMessageDispatchState(rawValue: st.columnText(8) ?? "") ?? .queued
        let runId = st.columnText(9).flatMap(UUID.init(uuidString:)).map(AgentRunID.init)
        return AgentQueuedMessageDispatch(
            message: decodeRow(st, durableStateColumn: 8),
            state: state,
            runId: runId
        )
    }

    /// Reconciles a crash after `prepareDispatch` only when the caller has proved
    /// that the deterministic run row does not exist. `AgentRunCoordinator`
    /// persists that row before crossing into `runner.sendTurn`, so this CAS can
    /// safely make the message claimable again without duplicating provider work.
    public func recoverPreparedBeforeProviderStart(
        id: AgentQueuedMessageID,
        runId: AgentRunID
    ) throws -> AgentQueuedMessage? {
        try db.performSync { database in try database.transaction {
            let select = try database.prepare("""
                SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at,
                       lease_id
                FROM agent_queued_messages
                WHERE id = ? AND dispatch_state = 'prepared' AND dispatch_run_id = ?;
            """)
            try select.bind(1, id.value.uuidString)
            try select.bind(2, runId.value.uuidString)
            guard try select.step(), let leaseId = select.columnText(8) else { return nil }
            let message = decodeRow(select)
            let update = try database.prepare("""
                UPDATE agent_queued_messages
                SET lease_id = NULL, lease_started_at = NULL,
                    dispatch_state = 'queued', dispatch_run_id = NULL, dispatch_updated_at = NULL
                WHERE id = ? AND lease_id = ?
                  AND dispatch_state = 'prepared' AND dispatch_run_id = ?;
            """)
            try update.bind(1, id.value.uuidString)
            try update.bind(2, leaseId)
            try update.bind(3, runId.value.uuidString)
            _ = try update.step()
            guard try changedRowCount() == 1 else { return nil }
            return message
        } }
    }

    /// A deterministic run row is durable proof that the coordinator accepted
    /// this queue identity. Remove only the matching prepared intent; never call
    /// the provider again. The existing run/thread remains the recovery surface.
    public func acknowledgePreparedWithRunEvidence(
        id: AgentQueuedMessageID,
        runId: AgentRunID
    ) throws -> AgentQueuedMessage? {
        try db.performSync { database in try database.transaction {
            let select = try database.prepare("""
                SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at,
                       lease_id
                FROM agent_queued_messages
                WHERE id = ? AND dispatch_state = 'prepared' AND dispatch_run_id = ?;
            """)
            try select.bind(1, id.value.uuidString)
            try select.bind(2, runId.value.uuidString)
            guard try select.step(), let leaseId = select.columnText(8) else { return nil }
            let message = decodeRow(select)
            let delete = try database.prepare("""
                DELETE FROM agent_queued_messages
                WHERE id = ? AND lease_id = ?
                  AND dispatch_state = 'prepared' AND dispatch_run_id = ?;
            """)
            try delete.bind(1, id.value.uuidString)
            try delete.bind(2, leaseId)
            try delete.bind(3, runId.value.uuidString)
            _ = try delete.step()
            guard try changedRowCount() == 1 else { return nil }
            try normalizePositions(threadId: message.threadId)
            return message
        } }
    }

    /// Recovery seam for a crash after provider acceptance but before queue ack.
    /// No lease takeover and no provider call: the durable dispatch proof is the
    /// delete predicate. Concurrent recovery yields the row to exactly one caller.
    public func acknowledgeDispatched(id: AgentQueuedMessageID, runId: AgentRunID) throws -> AgentQueuedMessage? {
        try db.performSync { database in try database.transaction {
            let select = try database.prepare("""
                SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at
                FROM agent_queued_messages
                WHERE id = ? AND dispatch_state = 'dispatched' AND dispatch_run_id = ?;
            """)
            try select.bind(1, id.value.uuidString)
            try select.bind(2, runId.value.uuidString)
            guard try select.step() else { return nil }
            let message = decodeRow(select)
            let delete = try database.prepare("""
                DELETE FROM agent_queued_messages
                WHERE id = ? AND dispatch_state = 'dispatched' AND dispatch_run_id = ?;
            """)
            try delete.bind(1, id.value.uuidString)
            try delete.bind(2, runId.value.uuidString)
            _ = try delete.step()
            guard try changedRowCount() == 1 else { return nil }
            try normalizePositions(threadId: message.threadId)
            return message
        } }
    }

    public func acknowledgeFirstDispatched(threadId: AgentThreadID) throws -> AgentQueuedMessage? {
        try db.performSync { database in try database.transaction {
            let select = try database.prepare("""
                SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at,
                       dispatch_run_id, dispatch_state
                FROM agent_queued_messages
                WHERE thread_id = ?
                ORDER BY position ASC, created_at ASC
                LIMIT 1;
            """)
            try select.bind(1, threadId.value.uuidString)
            guard try select.step(), select.columnText(9) == AgentQueuedMessageDispatchState.dispatched.rawValue,
                  let runId = select.columnText(8) else { return nil }
            let message = decodeRow(select)
            let delete = try database.prepare("""
                DELETE FROM agent_queued_messages
                WHERE id = ? AND dispatch_state = 'dispatched' AND dispatch_run_id = ?;
            """)
            try delete.bind(1, message.id.value.uuidString)
            try delete.bind(2, runId)
            _ = try delete.step()
            guard try changedRowCount() == 1 else { return nil }
            try normalizePositions(threadId: threadId)
            return message
        } }
    }

    public func get(id: AgentQueuedMessageID) throws -> AgentQueuedMessage? {
        let st = try db.prepare("""
            SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at,
                   dispatch_state
            FROM agent_queued_messages
            WHERE id = ?;
        """)
        try st.bind(1, id.value.uuidString)
        return try st.step() ? decodeRow(st, durableStateColumn: 8) : nil
    }

    public func update(id: AgentQueuedMessageID, text: String, attachments: [AgentAttachment]) throws -> AgentQueuedMessage? {
        try db.performSync { database in
            let update = try database.prepare("""
                UPDATE agent_queued_messages
                SET text = ?, attachments_json = ?, updated_at = ?
                WHERE id = ? AND lease_id IS NULL;
            """)
            try update.bind(1, text)
            try update.bind(2, attachmentsJSON(attachments))
            try update.bind(3, iso.string(from: Date()))
            try update.bind(4, id.value.uuidString)
            _ = try update.step()
            guard try changedRowCount() == 1 else { return nil }
            return try get(id: id)
        }
    }

    public func delete(id: AgentQueuedMessageID) throws -> AgentQueuedMessage? {
        try db.performSync { database in
            try database.transaction {
            let select = try database.prepare("""
                SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at
                FROM agent_queued_messages
                WHERE id = ? AND lease_id IS NULL;
            """)
            try select.bind(1, id.value.uuidString)
            guard try select.step() else { return nil }
            let queued = decodeRow(select)

            let delete = try database.prepare("DELETE FROM agent_queued_messages WHERE id = ? AND lease_id IS NULL;")
            try delete.bind(1, id.value.uuidString)
            _ = try delete.step()
            guard try changedRowCount() == 1 else { return nil }
            try normalizePositions(threadId: queued.threadId)
            return queued
            }
        }
    }

    /// Explicitly abandons an ambiguous prepared intent. Unlike generic queue
    /// deletion, this CAS cannot remove queued or provider-confirmed dispatched
    /// work and requires the exact durable lease/run identity observed here.
    public func abandonPrepared(id: AgentQueuedMessageID) throws -> AgentQueuedMessage? {
        try db.performSync { database in
            try database.transaction {
                let select = try database.prepare("""
                    SELECT id, thread_id, text, attachments_json, interaction_mode,
                           position, created_at, updated_at, lease_id, dispatch_run_id
                    FROM agent_queued_messages
                    WHERE id = ? AND dispatch_state = 'prepared';
                """)
                try select.bind(1, id.value.uuidString)
                guard try select.step(),
                      let leaseId = select.columnText(8),
                      let runId = select.columnText(9) else {
                    return nil
                }
                var queued = decodeRow(select)
                queued.durableState = .prepared

                let delete = try database.prepare("""
                    DELETE FROM agent_queued_messages
                    WHERE id = ? AND lease_id = ? AND dispatch_state = 'prepared'
                      AND dispatch_run_id = ?;
                """)
                try delete.bind(1, id.value.uuidString)
                try delete.bind(2, leaseId)
                try delete.bind(3, runId)
                _ = try delete.step()
                guard try changedRowCount() == 1 else { return nil }
                try normalizePositions(threadId: queued.threadId)
                return queued
            }
        }
    }

    public func promoteToFront(id: AgentQueuedMessageID) throws -> AgentQueuedMessage? {
        try db.performSync { database in
            try database.transaction {
            guard let target = try get(id: id) else { return nil }
            guard try !threadHasActiveLease(target.threadId) else { return nil }
            let ordered = [target] + (try list(threadId: target.threadId)).filter { $0.id != id }
            let now = Date()
            for (index, message) in ordered.enumerated() {
                let st = try database.prepare("UPDATE agent_queued_messages SET position = ?, updated_at = ? WHERE id = ? AND lease_id IS NULL;")
                try st.bind(1, Int64(index + 1))
                try st.bind(2, iso.string(from: now))
                try st.bind(3, message.id.value.uuidString)
                _ = try st.step()
            }
            return try get(id: id)
            }
        }
    }

    private func nextPosition(threadId: AgentThreadID) throws -> Int {
        let st = try db.prepare("SELECT COALESCE(MAX(position), 0) + 1 FROM agent_queued_messages WHERE thread_id = ?;")
        try st.bind(1, threadId.value.uuidString)
        return (try st.step()) ? Int(st.columnInt64(0)) : 1
    }

    private func rowExists(_ id: AgentQueuedMessageID) throws -> Bool {
        let st = try db.prepare("SELECT 1 FROM agent_queued_messages WHERE id = ? LIMIT 1;")
        try st.bind(1, id.value.uuidString)
        return try st.step()
    }

    private func threadHasActiveLease(_ threadId: AgentThreadID) throws -> Bool {
        let st = try db.prepare("SELECT 1 FROM agent_queued_messages WHERE thread_id = ? AND lease_id IS NOT NULL LIMIT 1;")
        try st.bind(1, threadId.value.uuidString)
        return try st.step()
    }

    private func changedRowCount() throws -> Int {
        let st = try db.prepare("SELECT changes();")
        guard try st.step() else { return 0 }
        return Int(st.columnInt64(0))
    }

    private func normalizePositions(threadId: AgentThreadID) throws {
        let queued = try list(threadId: threadId)
        let leased = try db.prepare("SELECT id, position FROM agent_queued_messages WHERE thread_id = ? AND lease_id IS NOT NULL;")
        try leased.bind(1, threadId.value.uuidString)
        var leasedIDs = Set<AgentQueuedMessageID>()
        var reservedPositions = Set<Int>()
        while try leased.step() {
            guard let idText = leased.columnText(0), let id = UUID(uuidString: idText) else { continue }
            leasedIDs.insert(AgentQueuedMessageID(id))
            reservedPositions.insert(Int(leased.columnInt64(1)))
        }
        var nextPosition = 1
        let now = Date()
        for message in queued where !leasedIDs.contains(message.id) {
            while reservedPositions.contains(nextPosition) { nextPosition += 1 }
            let assignedPosition = nextPosition
            nextPosition += 1
            guard message.position != assignedPosition else { continue }
            let st = try db.prepare("UPDATE agent_queued_messages SET position = ?, updated_at = ? WHERE id = ? AND lease_id IS NULL;")
            try st.bind(1, Int64(assignedPosition))
            try st.bind(2, iso.string(from: now))
            try st.bind(3, message.id.value.uuidString)
            _ = try st.step()
        }
    }

    private func attachmentsJSON(_ attachments: [AgentAttachment]) -> String {
        guard let data = try? encoder.encode(attachments),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private func decodeAttachments(_ json: String?) -> [AgentAttachment] {
        guard let json,
              let data = json.data(using: .utf8),
              let attachments = try? decoder.decode([AgentAttachment].self, from: data) else { return [] }
        return attachments
    }

    private func decodeRow(
        _ st: SQLiteStatement,
        durableStateColumn: Int32? = nil
    ) -> AgentQueuedMessage {
        var message = AgentQueuedMessage(
            id: AgentQueuedMessageID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID()),
            threadId: AgentThreadID(UUID(uuidString: st.columnText(1) ?? "") ?? UUID()),
            text: st.columnText(2) ?? "",
            attachments: decodeAttachments(st.columnText(3)),
            interactionMode: AgentInteractionMode(rawValue: st.columnText(4) ?? "") ?? .default,
            position: Int(st.columnInt64(5)),
            createdAt: parseDate(st.columnText(6)),
            updatedAt: parseDate(st.columnText(7))
        )
        if let durableStateColumn {
            message.durableState = AgentQueuedMessageDurableState(
                rawValue: st.columnText(durableStateColumn) ?? ""
            ) ?? .queued
        }
        message.routingSnapshot = try? routingSnapshot(id: message.id)
        return message
    }
}

public final class AgentRunRepository: @unchecked Sendable {
    /// Absolute per-row ceiling for a 16 GB MacBook class machine. Frames under
    /// this always admit; thread/global retention prunes oldest rows when the
    /// cumulative budget is near full. Only pathological frames above this are
    /// soft-truncated (no recoverable "omitted" banner).
    public static let maximumPersistedEventRowBytes = 16 * 1_024 * 1_024
    let db: SQLiteDB
    private let globalRetentionStateLock = NSLock()
    private let globalRetentionQueue = DispatchQueue(
        label: "rc2.agent.global-retention",
        qos: .utility
    )
    private var globalRetentionScheduled = false
    private var globalRetentionRequested = false
    private var globalRetentionCompletions: [@Sendable (Bool) -> Void] = []
    // PERF: listLatestStreamEvents / listStreamEventsByIds allocated JSONDecoder
    // on every agent reload/replay read (up to hundreds of events). Shared under
    // a short lock so concurrent thread reads avoid per-call codec construction.
    private let streamEventCodecLock = NSLock()
    private let streamEventDecoder = JSONDecoder()
    /// Highest durable `seq` observed for a run on this repository instance.
    /// Token-rate flushes used to SELECT `(run_id, seq)` before every INSERT
    /// even when the coordinator had just allocated a never-written sequence.
    /// Seed from `MAX(seq)` on cache miss so a new instance / relaunch still
    /// probes retries of already-written identities.
    private let committedStreamSeqLock = NSLock()
    private var lastCommittedStreamSeqByRun: [String: Int] = [:]
    private static let committedStreamSeqCacheLimit = 128
    /// Durable `event_id`s already written for a thread on this instance.
    /// Token-rate flushes used to SELECT the full provider row (payload
    /// included) before every INSERT even when the coordinator had just
    /// minted a new UUID. Seed the set from `event_id` on first touch so a
    /// new instance still probes retries.
    private let committedProviderEventLock = NSLock()
    private var knownProviderEventIdsByThread: [String: Set<String>] = [:]
    private static let committedProviderEventCacheLimit = 128
    public init(db: SQLiteDB) { self.db = db }
#if DEBUG
    /// `iso.string(from:)` calls from `persistStreamBatch` (one per flush).
    private(set) var streamBatchISO8601FormatCountForTesting = 0
    /// Identity `SELECT` probes from `persistStreamEventIdempotently`.
    private(set) var streamEventIdentitySelectCountForTesting = 0
    /// Identity `SELECT` probes from `persistProviderEventIdempotently`.
    private(set) var providerEventIdentitySelectCountForTesting = 0
#endif

    /// Store-before-loss soft bound used by coordinator + repository (S3).
    public func boundPayloadForPersistence(
        _ payloadJSON: String,
        byteLimit: Int = maximumPersistedEventRowBytes
    ) throws -> String {
        try Self.softTruncateUTF8Payload(
            payloadJSON,
            byteLimit: byteLimit,
            reversibleStore: ReversibleContentStore(db: db)
        )
    }

    private func boundedStreamRow(kind: String, payloadJSON: String) throws -> (kind: String, payloadJSON: String) {
        let kindBytes = kind.utf8.count
        let payloadBudget = max(1, Self.maximumPersistedEventRowBytes - kindBytes)
        let store = ReversibleContentStore(db: db)
        let boundedPayload = try Self.softTruncateUTF8Payload(
            payloadJSON,
            byteLimit: payloadBudget,
            reversibleStore: store
        )
        return (kind, boundedPayload)
    }

    private func boundedProviderPayload(_ payloadJSON: String) throws -> String {
        let store = ReversibleContentStore(db: db)
        return try Self.softTruncateUTF8Payload(
            payloadJSON,
            byteLimit: Self.maximumPersistedEventRowBytes,
            reversibleStore: store
        )
    }

    /// Character-safe soft truncate. Shared with coordinator so persist + buffer
    /// share one admission policy. When `reversibleStore` is provided and the
    /// payload exceeds the limit, the exact original is stored first and a
    /// recoverable `[[rc:handle]]` marker is embedded (S3 / T-003).
    public nonisolated static func softTruncateUTF8Payload(
        _ payloadJSON: String,
        byteLimit: Int,
        reversibleStore: ReversibleContentStore? = nil
    ) throws -> String {
        let limit = max(1, byteLimit)
        let originalBytes = payloadJSON.utf8.count
        guard originalBytes > limit else { return payloadJSON }
        // Already an owned S3 presentation (true suffix): re-trim prefix only.
        // Anchor with \\z and slice from the regex match range so an earlier
        // lookalike token inside provider content cannot steal the cut point.
        let ownedSuffixPattern = #"…\[truncated rc_oversized_v1 \d+→\d+ bytes\]\[\[rc:[0-9a-fA-F]+\]\]\z"#
        if let regex = try? NSRegularExpression(pattern: ownedSuffixPattern),
           let match = regex.firstMatch(
            in: payloadJSON,
            options: [],
            range: NSRange(payloadJSON.startIndex..., in: payloadJSON)
           ),
           let trailerRange = Range(match.range, in: payloadJSON) {
            let trailer = String(payloadJSON[trailerRange])
            if originalBytes <= limit { return payloadJSON }
            let headBudget = max(0, limit - trailer.utf8.count)
            if headBudget == 0 { return trailer }
            var utf8End = payloadJSON.utf8.index(
                payloadJSON.utf8.startIndex,
                offsetBy: headBudget,
                limitedBy: payloadJSON.utf8.endIndex
            ) ?? payloadJSON.utf8.endIndex
            while utf8End > payloadJSON.utf8.startIndex {
                if let end = utf8End.samePosition(in: payloadJSON) {
                    return String(payloadJSON[..<end]) + trailer
                }
                payloadJSON.utf8.formIndex(before: &utf8End)
            }
            return trailer
        }
        // S3: store-before-loss is mandatory when a store is provided. Fail open
        // only by raising — callers must not silently drop the original.
        if let reversibleStore {
            // Store-before-loss: failures propagate; never replace original with
            // an unrecoverable substitute under a provided store.
            return try AuthoritativePayloadRecovery.prepareForPresentation(
                text: payloadJSON,
                store: reversibleStore,
                limit: limit
            ).presentationText
        }
        let trailer = "…[truncated \(originalBytes)→\(limit) bytes]"
        let headBudget = max(0, limit - trailer.utf8.count)
        guard headBudget > 0 else { return trailer }
        var utf8End = payloadJSON.utf8.index(
            payloadJSON.utf8.startIndex,
            offsetBy: headBudget,
            limitedBy: payloadJSON.utf8.endIndex
        ) ?? payloadJSON.utf8.endIndex
        while utf8End > payloadJSON.utf8.startIndex {
            if let end = utf8End.samePosition(in: payloadJSON) {
                return String(payloadJSON[..<end]) + trailer
            }
            payloadJSON.utf8.formIndex(before: &utf8End)
        }
        return trailer
    }

    /// Rehydrate a store-before-loss presentation form back to the original UTF-8 payload.
    /// Recognizes `[[rc:handle]]` markers and legacy `rc_oversized` JSON envelopes.
    public func rehydrateOversizedPayloadIfNeeded(_ payloadJSON: String) throws -> String {
        // Require owned trailer as a true suffix (\\z, not $) so a trailing newline
        // cannot promote a mid-payload lookalike into recovery.
        let pattern = #"…\[truncated rc_oversized_v1 (\d+)→(\d+) bytes\]\[\[rc:([0-9a-fA-F]+)\]\]\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return payloadJSON }
        let ns = payloadJSON as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: payloadJSON, options: [], range: full),
              match.numberOfRanges >= 4,
              let handleRange = Range(match.range(at: 3), in: payloadJSON) else {
            return payloadJSON
        }
        let handle = ReversibleContentStore.normalize(String(payloadJSON[handleRange]))
        guard !handle.isEmpty else {
            throw PersistenceDataError.corruptStreamEvent("owned oversized trailer empty handle")
        }
        let store = ReversibleContentStore(db: db)
        let original = try AuthoritativePayloadRecovery.rehydrate(handle: handle, store: store)
        guard let text = String(data: original, encoding: .utf8) else {
            throw PersistenceDataError.corruptStreamEvent("oversized original is not UTF-8")
        }
        return text
    }

    public func upsert(_ r: AgentRun) throws {
        let st = try db.prepare("""
            INSERT INTO agent_runs(id, thread_id, provider, provider_instance_id, model, status, started_at, finished_at, error_message)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET status=excluded.status, finished_at=excluded.finished_at, error_message=excluded.error_message;
        """)
        try st.bind(1, r.id.value.uuidString)
        try st.bind(2, r.threadId.value.uuidString)
        try st.bind(3, r.provider.rawValue)
        try st.bind(4, r.providerInstanceId ?? r.provider.rawValue)
        try st.bind(5, r.model)
        try st.bind(6, r.status.rawValue)
        try st.bind(7, iso.string(from: r.startedAt))
        try st.bind(8, r.finishedAt.map { iso.string(from: $0) })
        try st.bind(9, r.errorMessage)
        _ = try st.step()
    }

    public func get(id: AgentRunID) throws -> AgentRun? {
        let st = try db.prepare("""
            SELECT id, thread_id, provider, provider_instance_id, model, status, started_at, finished_at, error_message
            FROM agent_runs
            WHERE id = ?;
        """)
        try st.bind(1, id.value.uuidString)
        guard try st.step() else { return nil }
        return AgentRun(
            id: AgentRunID(UUID(uuidString: st.columnText(0) ?? "") ?? id.value),
            threadId: AgentThreadID(UUID(uuidString: st.columnText(1) ?? "") ?? UUID()),
            provider: AgentProvider(rawValue: st.columnText(2) ?? "") ?? .codex,
            providerInstanceId: st.columnText(3) ?? (AgentProvider(rawValue: st.columnText(2) ?? "") ?? .codex).rawValue,
            model: st.columnText(4) ?? "",
            status: AgentRunStatus(rawValue: st.columnText(5) ?? "") ?? .pending,
            startedAt: parseDate(st.columnText(6)),
            finishedAt: st.columnText(7).map(parseDate),
            errorMessage: st.columnText(8)
        )
    }

    /// Latest non-terminal run for a thread, including LaunchAgent-owned rows.
    ///
    /// WHY: the main app's in-memory coordinator has no session for Path B
    /// scheduled runs, but `agent_runs` is shared SQLite. UI needs this for
    /// "Working for Xs" and Stop targeting without inventing a local session.
    public func latestActive(for threadId: AgentThreadID) throws -> AgentRun? {
        let st = try db.prepare("""
            SELECT id, thread_id, provider, provider_instance_id, model, status, started_at, finished_at, error_message
            FROM agent_runs
            WHERE thread_id = ? AND status IN ('pending', 'running')
            ORDER BY started_at DESC
            LIMIT 1;
        """)
        try st.bind(1, threadId.value.uuidString)
        guard try st.step() else { return nil }
        return AgentRun(
            id: AgentRunID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID()),
            threadId: AgentThreadID(UUID(uuidString: st.columnText(1) ?? "") ?? threadId.value),
            provider: AgentProvider(rawValue: st.columnText(2) ?? "") ?? .codex,
            providerInstanceId: st.columnText(3) ?? (AgentProvider(rawValue: st.columnText(2) ?? "") ?? .codex).rawValue,
            model: st.columnText(4) ?? "",
            status: AgentRunStatus(rawValue: st.columnText(5) ?? "") ?? .pending,
            startedAt: parseDate(st.columnText(6)),
            finishedAt: st.columnText(7).map(parseDate),
            errorMessage: st.columnText(8)
        )
    }

    /// All pending/running runs (for launch reconcile ledger stamping).
    public func listActive() throws -> [AgentRun] {
        let st = try db.prepare("""
            SELECT id, thread_id, provider, provider_instance_id, model, status, started_at, finished_at, error_message
            FROM agent_runs
            WHERE status IN ('pending', 'running')
            ORDER BY started_at DESC;
            """)
        var rows: [AgentRun] = []
        while try st.step() {
            rows.append(AgentRun(
                id: AgentRunID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID()),
                threadId: AgentThreadID(UUID(uuidString: st.columnText(1) ?? "") ?? UUID()),
                provider: AgentProvider(rawValue: st.columnText(2) ?? "") ?? .codex,
                providerInstanceId: st.columnText(3) ?? (AgentProvider(rawValue: st.columnText(2) ?? "") ?? .codex).rawValue,
                model: st.columnText(4) ?? "",
                status: AgentRunStatus(rawValue: st.columnText(5) ?? "") ?? .pending,
                startedAt: parseDate(st.columnText(6)),
                finishedAt: st.columnText(7).map(parseDate),
                errorMessage: st.columnText(8)
            ))
        }
        return rows
    }

    /// Recent terminal runs for Active Threads → Last Finished.
    ///
    /// WHY: live ActiveRunProjection only holds in-flight runs. The shell
    /// history tab needs durable finished rows without inventing a second
    /// event bus. Cap keeps the list scannable (mirrors Pet active prefix 50).
    public func listRecentFinished(limit: Int = 50) throws -> [AgentRun] {
        let capped = max(1, min(limit, 500))
        let st = try db.prepare("""
            SELECT id, thread_id, provider, provider_instance_id, model, status, started_at, finished_at, error_message
            FROM agent_runs
            WHERE finished_at IS NOT NULL
              AND status NOT IN ('pending', 'running')
            ORDER BY finished_at DESC
            LIMIT ?;
            """)
        try st.bind(1, Int64(capped))
        var rows: [AgentRun] = []
        while try st.step() {
            rows.append(AgentRun(
                id: AgentRunID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID()),
                threadId: AgentThreadID(UUID(uuidString: st.columnText(1) ?? "") ?? UUID()),
                provider: AgentProvider(rawValue: st.columnText(2) ?? "") ?? .codex,
                providerInstanceId: st.columnText(3) ?? (AgentProvider(rawValue: st.columnText(2) ?? "") ?? .codex).rawValue,
                model: st.columnText(4) ?? "",
                status: AgentRunStatus(rawValue: st.columnText(5) ?? "") ?? .completed,
                startedAt: parseDate(st.columnText(6)),
                finishedAt: st.columnText(7).map(parseDate),
                errorMessage: st.columnText(8)
            ))
        }
        return rows
    }

    public func reconcileRunningOnLaunch(preservingThreadIDs: Set<AgentThreadID> = []) throws -> Int {
        let countBefore = try countRunning()
        // Always stamp a durable reason so relaunch is never an unexplained terminal
        // (plan-final W1: process_death/relaunch_reconcile ≠ provider_completed).
        let reason = "Interrupted by app restart."
        if preservingThreadIDs.isEmpty {
            let st = try db.prepare("""
                UPDATE agent_runs
                SET status='interrupted', finished_at=?,
                    error_message=COALESCE(error_message, ?)
                WHERE status IN ('pending', 'running');
                """)
            try st.bind(1, iso.string(from: Date()))
            try st.bind(2, reason)
            _ = try st.step()
            return countBefore
        }
        // Preserve LaunchAgent-owned scheduled runs so opening the UI does not
        // false-interrupt a still-live provider session in the other process.
        let placeholders = preservingThreadIDs.map { _ in "?" }.joined(separator: ",")
        let st = try db.prepare("""
            UPDATE agent_runs
            SET status='interrupted', finished_at=?,
                error_message=COALESCE(error_message, ?)
            WHERE status IN ('pending', 'running') AND thread_id NOT IN (\(placeholders));
            """)
        try st.bind(1, iso.string(from: Date()))
        try st.bind(2, reason)
        for (offset, threadID) in preservingThreadIDs.enumerated() {
            try st.bind(Int32(offset + 3), threadID.value.uuidString)
        }
        _ = try st.step()
        return countBefore
    }

    public func markStopped(id: AgentRunID, status: AgentRunStatus = .cancelled, at date: Date = Date()) throws {
        let st = try db.prepare("UPDATE agent_runs SET status=?, finished_at=? WHERE id=? AND status IN ('pending', 'running');")
        try st.bind(1, status.rawValue)
        try st.bind(2, iso.string(from: date))
        try st.bind(3, id.value.uuidString)
        _ = try st.step()
    }

    private func countRunning() throws -> Int {
        let st = try db.prepare("SELECT COUNT(*) FROM agent_runs WHERE status='running';")
        if try st.step() { return Int(st.columnInt64(0)) }
        return 0
    }

    public func appendStreamEvent(runId: AgentRunID, seq: Int, kind: String, payloadJSON: String) throws {
        let bounded = try boundedStreamRow(kind: kind, payloadJSON: payloadJSON)
        let st = try db.prepare("INSERT INTO agent_stream_events(run_id, seq, event_kind, payload_json, created_at) VALUES(?, ?, ?, ?, ?);")
        try st.bind(1, runId.value.uuidString)
        try st.bind(2, Int64(seq))
        try st.bind(3, bounded.kind)
        try st.bind(4, bounded.payloadJSON)
        try st.bind(5, iso.string(from: Date()))
        _ = try st.step()
        rememberCommittedStreamSeq(runId: runId, seq: seq)
        // Single-path writers (tests + rare direct callers) must also reclaim so
        // a large admit never relies on the batch prune cadence alone.
        if let run = try get(id: runId) {
            try db.performSync { database in
                let pruned = try pruneStreamEvents(
                    db: database,
                    threadId: run.threadId,
                    keepLatest: AgentEventRetentionPolicy.production.streamEventCountPerThread,
                    maxPayloadBytes: AgentEventRetentionPolicy.production.streamEventBytesPerThread
                )
                if pruned {
                    try markAgentHistoryPartial(db: database, threadId: run.threadId)
                }
            }
        }
    }

    /// Highest durable sequence already committed for `runId`, or `0` when none.
    /// Used to seed in-memory allocation after process relaunch or ownership repair
    /// so a retry cannot reuse seq 1 for a different event kind.
    public func maxStreamEventSeq(runId: AgentRunID) throws -> Int {
        try maxStreamEventSeq(db: db, runId: runId)
    }

    private func maxStreamEventSeq(db: SQLiteDB, runId: AgentRunID) throws -> Int {
        let st = try db.prepare(
            "SELECT COALESCE(MAX(seq), 0) FROM agent_stream_events WHERE run_id = ?;"
        )
        try st.bind(1, runId.value.uuidString)
        return (try st.step()) ? Int(st.columnInt64(0)) : 0
    }

    private func rememberedCommittedStreamSeq(runId: AgentRunID) -> Int? {
        committedStreamSeqLock.lock()
        defer { committedStreamSeqLock.unlock() }
        return lastCommittedStreamSeqByRun[runId.value.uuidString]
    }

    private func rememberCommittedStreamSeq(runId: AgentRunID, seq: Int) {
        let key = runId.value.uuidString
        committedStreamSeqLock.lock()
        defer { committedStreamSeqLock.unlock() }
        if lastCommittedStreamSeqByRun.count >= Self.committedStreamSeqCacheLimit,
           lastCommittedStreamSeqByRun[key] == nil {
            lastCommittedStreamSeqByRun.removeAll(keepingCapacity: true)
        }
        lastCommittedStreamSeqByRun[key] = max(lastCommittedStreamSeqByRun[key] ?? 0, seq)
    }

    /// Known high-water seq for `runId`. Cache miss reads durable `MAX(seq)`
    /// once so INSERT-first never duplicates a row written by another instance.
    private func knownCommittedStreamSeq(db: SQLiteDB, runId: AgentRunID) throws -> Int {
        if let cached = rememberedCommittedStreamSeq(runId: runId) {
            return cached
        }
        let maxSeq = try maxStreamEventSeq(db: db, runId: runId)
        rememberCommittedStreamSeq(runId: runId, seq: maxSeq)
        return maxSeq
    }

    /// One ordered mirror write. A provider runtime event shares the transaction
    /// with its AssistantEvent row so retries cannot expose a partial pair.
    public struct StreamWriteIntent: Sendable {
        public let seq: Int
        public let kind: String
        public let payloadJSON: String
        public let providerEvent: ProviderRuntimeEvent?

        public init(seq: Int, kind: String, payloadJSON: String, providerEvent: ProviderRuntimeEvent?) {
            self.seq = seq
            self.kind = kind
            self.payloadJSON = payloadJSON
            self.providerEvent = providerEvent
        }
    }

    /// Whether `persistStreamBatch` should run per-thread window retention.
    /// Token-rate flushes pass `shouldPruneStreamEvents: false`; a single
    /// oversize frame still reclaims immediately so older history drops first.
    nonisolated public static func streamBatchNeedsRetentionReclaim(
        shouldPruneStreamEvents: Bool,
        itemPayloadBytes: [Int],
        providerPayloadBytes: [Int],
        streamEventBytesPerThread: Int64,
        providerLogBytesPerThread: Int64
    ) -> Bool {
        if shouldPruneStreamEvents { return true }
        if itemPayloadBytes.contains(where: { Int64($0) > streamEventBytesPerThread }) {
            return true
        }
        return providerPayloadBytes.contains(where: { Int64($0) > providerLogBytesPerThread })
    }

    public struct TerminalCommitResult: Sendable {
        public let assistantMessageId: AgentMessageID?
        public let insertedAssistantMessage: Bool

        public init(assistantMessageId: AgentMessageID?, insertedAssistantMessage: Bool) {
            self.assistantMessageId = assistantMessageId
            self.insertedAssistantMessage = insertedAssistantMessage
        }
    }

    /// Moves the durable run/thread/provider-session projection between
    /// non-terminal lifecycle states as one transaction. The UI must never see
    /// a thread marked running while its run or resumable session still says
    /// pending (or the inverse).
    public func persistActiveGraph(
        run: AgentRun,
        thread: AgentThread?,
        providerSession: ProviderSessionRuntime?
    ) throws {
        try db.performSync { database in
            try database.transaction {
                try AgentRunRepository(db: database).upsert(run)
                if let thread {
                    try AgentThreadRepository(db: database).upsert(thread)
                }
                if let providerSession {
                    try ProviderSessionRuntimeRepository(db: database).upsert(providerSession)
                }
            }
        }
    }

    /// Commits the user-visible terminal graph as one SQLite transaction.
    ///
    /// Terminal fanout is safe only after the optional final assistant message,
    /// run, thread, provider-session, and synthesized terminal event agree. A
    /// failure at any statement rolls back the complete graph. Retrying with the
    /// same assistant/event identities is idempotent.
    public func persistTerminalGraph(
        assistantMessage: AgentMessage?,
        run: AgentRun,
        thread: AgentThread?,
        providerSession: ProviderSessionRuntime?,
        streamEvent: StreamWriteIntent? = nil
    ) throws -> TerminalCommitResult {
        try db.performSync { database in
            try database.transaction {
                var assistantMessageId: AgentMessageID?
                var insertedAssistantMessage = false
                if let assistantMessage {
                    let existing = try database.prepare("""
                        SELECT thread_id, role, content
                        FROM agent_messages
                        WHERE id = ?
                        LIMIT 1;
                    """)
                    try existing.bind(1, assistantMessage.id.value.uuidString)
                    if try existing.step() {
                        guard existing.columnText(0) == assistantMessage.threadId.value.uuidString,
                              existing.columnText(1) == assistantMessage.role.rawValue,
                              existing.columnText(2) == assistantMessage.content else {
                            throw SQLiteError.execute(
                                "Conflicting terminal assistant identity \(assistantMessage.id.value.uuidString)."
                            )
                        }
                        assistantMessageId = assistantMessage.id
                    } else {
                        try AgentMessageRepository(db: database).append(assistantMessage)
                        assistantMessageId = assistantMessage.id
                        insertedAssistantMessage = true
                    }
                }

                try upsert(run)

                if let thread {
                    let threadRepo = AgentThreadRepository(db: database)
                    guard try threadRepo.get(id: thread.id) != nil else {
                        throw SQLiteError.execute(
                            "Thread row missing while committing terminal run \(run.id.value.uuidString)."
                        )
                    }
                    try threadRepo.upsert(thread)
                }

                if let providerSession {
                    try ProviderSessionRuntimeRepository(db: database).upsert(providerSession)
                }

                if let streamEvent {
                    try persistStreamEventIdempotently(db: database, runId: run.id, item: streamEvent)
                }

                return TerminalCommitResult(
                    assistantMessageId: assistantMessageId,
                    insertedAssistantMessage: insertedAssistantMessage
                )
            }
        }
    }

    /// Persist a complete stream batch atomically and idempotently.
    ///
    /// A failed transaction commits no prefix. A retry accepts an already-matching
    /// `(run_id, seq)` row but fails loudly if the same identity has different
    /// bytes. Provider-event logs use the same rule keyed by `(thread_id, event_id)`.
    public func persistStreamBatch(
        runId: AgentRunID,
        threadId: AgentThreadID,
        items: [StreamWriteIntent],
        shouldPruneStreamEvents: Bool,
        retentionPolicy policy: AgentEventRetentionPolicy = .production
    ) throws {
        guard !items.isEmpty || shouldPruneStreamEvents else { return }
        // Inserts never fail-closed (store-before-loss). The coordinator already
        // asks for prune every `streamEventPruneInterval` events. Running the
        // JOIN + ROW_NUMBER + running-SUM DELETE on every 16-event / 250ms flush
        // rescanned up to 8 MiB of blobs while the thread was still under cap.
        // Reclaim on the caller's cadence, or immediately when a single frame
        // already exceeds the per-thread byte budget.
        let shouldReclaim = Self.streamBatchNeedsRetentionReclaim(
            shouldPruneStreamEvents: shouldPruneStreamEvents,
            itemPayloadBytes: items.map(\.payloadJSON.utf8.count),
            providerPayloadBytes: items.compactMap { $0.providerEvent?.payloadJSON.utf8.count },
            streamEventBytesPerThread: policy.streamEventBytesPerThread,
            providerLogBytesPerThread: policy.providerLogBytesPerThread
        )
        try db.performSync { db in
            try db.transaction {
                // ISO8601DateFormatter is second-precision. A 16-event / 250ms
                // flush already stores the same created_at on every row; format
                // once instead of lock+calendar per INSERT (stream + provider).
                let createdAt = items.isEmpty ? nil : iso.string(from: Date())
#if DEBUG
                if createdAt != nil { streamBatchISO8601FormatCountForTesting += 1 }
#endif
                for item in items {
                    try persistStreamEventIdempotently(
                        db: db, runId: runId, item: item, createdAt: createdAt
                    )
                    if let providerEvent = item.providerEvent {
                        try persistProviderEventIdempotently(
                            db: db,
                            threadId: threadId,
                            runId: runId,
                            event: providerEvent,
                            createdAt: createdAt
                        )
                    }
                }
                if shouldReclaim {
                    let streamPruned = try pruneStreamEvents(
                        db: db,
                        threadId: threadId,
                        keepLatest: policy.streamEventCountPerThread,
                        maxPayloadBytes: policy.streamEventBytesPerThread
                    )
                    if streamPruned {
                        try markAgentHistoryPartial(db: db, threadId: threadId)
                    }
                    _ = try pruneProviderEventLogs(
                        db: db,
                        threadId: threadId,
                        keepLatest: policy.providerLogCountPerThread,
                        maxPayloadBytes: policy.providerLogBytesPerThread
                    )
                }
            }
        }
        if shouldReclaim {
            scheduleGlobalEventPayloadPruning(policy: policy)
        }
    }

    public func appendProviderEventLog(threadId: AgentThreadID, runId: AgentRunID?, event: ProviderRuntimeEvent) throws {
        let boundedPayload = try boundedProviderPayload(event.payloadJSON)
        let st = try db.prepare("""
            INSERT INTO agent_provider_event_logs(
                thread_id, run_id, event_id, provider, source, method,
                provider_turn_id, provider_item_id, provider_request_id,
                payload_json, received_at_ms, created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, runId?.value.uuidString)
        try st.bind(3, event.id)
        try st.bind(4, event.provider.rawValue)
        try st.bind(5, event.source)
        try st.bind(6, event.method)
        try st.bind(7, event.providerTurnId)
        try st.bind(8, event.providerItemId)
        try st.bind(9, event.providerRequestId)
        try st.bind(10, boundedPayload)
        try st.bind(11, Int64(event.receivedAtMs))
        try st.bind(12, iso.string(from: Date()))
        _ = try st.step()
        _ = try pruneProviderEventLogs(
            threadId: threadId,
            keepLatest: AgentEventRetentionPolicy.production.providerLogCountPerThread,
            maxPayloadBytes: AgentEventRetentionPolicy.production.providerLogBytesPerThread
        )
    }

    public func countProviderEventLogs(threadId: AgentThreadID) throws -> Int {
        let st = try db.prepare("SELECT COUNT(*) FROM agent_provider_event_logs WHERE thread_id = ?;")
        try st.bind(1, threadId.value.uuidString)
        if try st.step() { return Int(st.columnInt64(0)) }
        return 0
    }

    public func listLatestProviderEventLogs(threadId: AgentThreadID, limit: Int = 500) throws -> [ProviderRuntimeEvent] {
        let st = try db.prepare("""
            SELECT event_id, provider, source, method, provider_turn_id, provider_item_id,
                   provider_request_id, payload_json, received_at_ms
            FROM (
                SELECT id, event_id, provider, source, method, provider_turn_id, provider_item_id,
                       provider_request_id, payload_json, received_at_ms
                FROM agent_provider_event_logs
                WHERE thread_id = ?
                ORDER BY id DESC
                LIMIT ?
            )
            ORDER BY id ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(limit))
        var events: [ProviderRuntimeEvent] = []
        while try st.step() {
            guard let id = st.columnText(0) else {
                throw PersistenceDataError.corruptProviderEventLog("missing event id")
            }
            guard let providerRaw = st.columnText(1),
                  let provider = AgentProvider(rawValue: providerRaw) else {
                throw PersistenceDataError.corruptProviderEventLog("invalid provider for event \(id)")
            }
            guard let source = st.columnText(2), !source.isEmpty else {
                throw PersistenceDataError.corruptProviderEventLog("missing source for event \(id)")
            }
            guard let method = st.columnText(3), !method.isEmpty else {
                throw PersistenceDataError.corruptProviderEventLog("missing method for event \(id)")
            }
            guard let payload = st.columnText(7) else {
                throw PersistenceDataError.corruptProviderEventLog("missing payload for event \(id)")
            }
            // S3: rehydrate store-before-loss presentation (or fail loud on store_failed).
            let resolvedPayload: String
            do {
                resolvedPayload = try rehydrateOversizedPayloadIfNeeded(payload)
            } catch {
                throw PersistenceDataError.corruptProviderEventLog(
                    "event \(id) oversized recovery failed: \(error)"
                )
            }
            events.append(ProviderRuntimeEvent(
                id: id,
                provider: provider,
                source: source,
                method: method,
                providerTurnId: st.columnText(4),
                providerItemId: st.columnText(5),
                providerRequestId: st.columnText(6),
                payloadJSON: resolvedPayload,
                receivedAtMs: Int64(st.columnInt64(8))
            ))
        }
        return events
    }

    public func pruneProviderEventLogs(
        threadId: AgentThreadID,
        keepLatest limit: Int = AgentEventRetentionPolicy.production.providerLogCountPerThread
    ) throws {
        try pruneProviderEventLogs(
            threadId: threadId,
            keepLatest: limit,
            maxPayloadBytes: AgentEventRetentionPolicy.production.providerLogBytesPerThread
        )
    }

    public func pruneProviderEventLogs(
        threadId: AgentThreadID,
        keepLatest limit: Int,
        maxPayloadBytes: Int64
    ) throws {
        try pruneProviderEventLogs(
            db: db,
            threadId: threadId,
            keepLatest: limit,
            maxPayloadBytes: maxPayloadBytes
        )
    }

    @discardableResult
    private func pruneProviderEventLogs(
        db: SQLiteDB,
        threadId: AgentThreadID,
        keepLatest limit: Int,
        maxPayloadBytes: Int64
    ) throws -> Bool {
        guard limit > 0, maxPayloadBytes > 0 else { return false }
        if try providerRetentionIsUnderBudget(
            db: db,
            threadId: threadId,
            limit: limit,
            maxPayloadBytes: maxPayloadBytes
        ) {
            return false
        }
        let st = try db.prepare("""
            WITH ranked AS (
                SELECT id,
                       ROW_NUMBER() OVER (ORDER BY id DESC) AS row_number,
                       SUM(LENGTH(CAST(payload_json AS BLOB))) OVER (
                           ORDER BY id DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                       ) AS running_bytes
                FROM agent_provider_event_logs
                WHERE thread_id = ?
            )
            DELETE FROM agent_provider_event_logs
            WHERE id IN (
                SELECT id FROM ranked
                -- Always keep the newest row so a large fresh event can enter;
                -- reclaim budget by deleting older rows only.
                WHERE row_number > ? OR (row_number > 1 AND running_bytes > ?)
            );
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(limit))
        try st.bind(3, maxPayloadBytes)
        _ = try st.step()
        return try changedRowCount(db) > 0
    }

    public func pruneStreamEvents(
        threadId: AgentThreadID,
        keepLatest limit: Int = AgentEventRetentionPolicy.production.streamEventCountPerThread
    ) throws {
        try pruneStreamEvents(
            threadId: threadId,
            keepLatest: limit,
            maxPayloadBytes: AgentEventRetentionPolicy.production.streamEventBytesPerThread
        )
    }

    public func pruneStreamEvents(
        threadId: AgentThreadID,
        keepLatest limit: Int,
        maxPayloadBytes: Int64
    ) throws {
        try pruneStreamEvents(
            db: db,
            threadId: threadId,
            keepLatest: limit,
            maxPayloadBytes: maxPayloadBytes
        )
    }

    private func persistStreamEventIdempotently(
        db: SQLiteDB,
        runId: AgentRunID,
        item: StreamWriteIntent,
        createdAt: String? = nil
    ) throws {
        let bounded = try boundedStreamRow(kind: item.kind, payloadJSON: item.payloadJSON)
        let lastCommitted = try knownCommittedStreamSeq(db: db, runId: runId)
        // First write of a freshly allocated seq cannot collide. Retry and
        // relaunch still SELECT so matching bytes stay idempotent and a
        // different identity still fails loud.
        if item.seq <= lastCommitted {
            try probeExistingStreamEventIdentity(
                db: db,
                runId: runId,
                item: item,
                bounded: bounded,
                createdAt: createdAt
            )
            return
        }

        let insert = try db.prepare("INSERT INTO agent_stream_events(run_id, seq, event_kind, payload_json, created_at) VALUES(?, ?, ?, ?, ?);")
        try insert.bind(1, runId.value.uuidString)
        try insert.bind(2, Int64(item.seq))
        try insert.bind(3, bounded.kind)
        try insert.bind(4, bounded.payloadJSON)
        try insert.bind(5, createdAt ?? iso.string(from: Date()))
        _ = try insert.step()
        rememberCommittedStreamSeq(runId: runId, seq: item.seq)
    }

    private func probeExistingStreamEventIdentity(
        db: SQLiteDB,
        runId: AgentRunID,
        item: StreamWriteIntent,
        bounded: (kind: String, payloadJSON: String),
        createdAt: String?
    ) throws {
#if DEBUG
        streamEventIdentitySelectCountForTesting += 1
#endif
        let existing = try db.prepare("SELECT event_kind, payload_json FROM agent_stream_events WHERE run_id = ? AND seq = ? LIMIT 1;")
        try existing.bind(1, runId.value.uuidString)
        try existing.bind(2, Int64(item.seq))
        if try existing.step() {
            let existingKind = existing.columnText(0)
            let existingPayload = existing.columnText(1)
            guard existingKind == bounded.kind,
                  existingPayload == bounded.payloadJSON else {
                let existingKindDescription = existingKind ?? "nil"
                throw SQLiteError.execute(
                    "Conflicting stream event identity for run \(runId.value.uuidString) seq \(item.seq) " +
                    "(existing kind: \(existingKindDescription), retry kind: \(item.kind))."
                )
            }
            return
        }

        let insert = try db.prepare("INSERT INTO agent_stream_events(run_id, seq, event_kind, payload_json, created_at) VALUES(?, ?, ?, ?, ?);")
        try insert.bind(1, runId.value.uuidString)
        try insert.bind(2, Int64(item.seq))
        try insert.bind(3, bounded.kind)
        try insert.bind(4, bounded.payloadJSON)
        try insert.bind(5, createdAt ?? iso.string(from: Date()))
        _ = try insert.step()
        rememberCommittedStreamSeq(runId: runId, seq: item.seq)
    }

    private func persistProviderEventIdempotently(
        db: SQLiteDB,
        threadId: AgentThreadID,
        runId: AgentRunID,
        event: ProviderRuntimeEvent,
        createdAt: String? = nil
    ) throws {
        let boundedPayload = try boundedProviderPayload(event.payloadJSON)
        let known = try knownProviderEventIds(db: db, threadId: threadId)
        // First write of a freshly minted event_id cannot collide. Retry and
        // relaunch still SELECT so matching bytes stay idempotent and a
        // different identity still fails loud.
        if known.contains(event.id) {
            try probeExistingProviderEventIdentity(
                db: db,
                threadId: threadId,
                runId: runId,
                event: event,
                boundedPayload: boundedPayload,
                createdAt: createdAt
            )
            return
        }
        try insertProviderEvent(
            db: db,
            threadId: threadId,
            runId: runId,
            event: event,
            boundedPayload: boundedPayload,
            createdAt: createdAt
        )
        rememberProviderEventId(threadId: threadId, eventId: event.id)
    }

    private func knownProviderEventIds(db: SQLiteDB, threadId: AgentThreadID) throws -> Set<String> {
        let key = threadId.value.uuidString
        committedProviderEventLock.lock()
        if let cached = knownProviderEventIdsByThread[key] {
            let copy = cached
            committedProviderEventLock.unlock()
            return copy
        }
        committedProviderEventLock.unlock()

        let st = try db.prepare(
            "SELECT event_id FROM agent_provider_event_logs WHERE thread_id = ?;"
        )
        try st.bind(1, key)
        var ids = Set<String>()
        while try st.step() {
            if let id = st.columnText(0) { ids.insert(id) }
        }

        committedProviderEventLock.lock()
        defer { committedProviderEventLock.unlock() }
        if knownProviderEventIdsByThread.count >= Self.committedProviderEventCacheLimit,
           knownProviderEventIdsByThread[key] == nil {
            knownProviderEventIdsByThread.removeAll(keepingCapacity: true)
        }
        if var existing = knownProviderEventIdsByThread[key] {
            existing.formUnion(ids)
            knownProviderEventIdsByThread[key] = existing
            return existing
        }
        knownProviderEventIdsByThread[key] = ids
        return ids
    }

    private func rememberProviderEventId(threadId: AgentThreadID, eventId: String) {
        let key = threadId.value.uuidString
        committedProviderEventLock.lock()
        defer { committedProviderEventLock.unlock() }
        guard knownProviderEventIdsByThread[key] != nil else { return }
        knownProviderEventIdsByThread[key]?.insert(eventId)
    }

    private func probeExistingProviderEventIdentity(
        db: SQLiteDB,
        threadId: AgentThreadID,
        runId: AgentRunID,
        event: ProviderRuntimeEvent,
        boundedPayload: String,
        createdAt: String?
    ) throws {
#if DEBUG
        providerEventIdentitySelectCountForTesting += 1
#endif
        let existing = try db.prepare("""
            SELECT provider, source, method, provider_turn_id, provider_item_id,
                   provider_request_id, payload_json, received_at_ms
            FROM agent_provider_event_logs
            WHERE thread_id = ? AND event_id = ?
            LIMIT 1;
        """)
        try existing.bind(1, threadId.value.uuidString)
        try existing.bind(2, event.id)
        if try existing.step() {
            guard existing.columnText(0) == event.provider.rawValue,
                  existing.columnText(1) == event.source,
                  existing.columnText(2) == event.method,
                  existing.columnText(3) == event.providerTurnId,
                  existing.columnText(4) == event.providerItemId,
                  existing.columnText(5) == event.providerRequestId,
                  existing.columnText(6) == boundedPayload,
                  existing.columnInt64(7) == Int64(event.receivedAtMs) else {
                throw SQLiteError.execute("Conflicting provider event identity for thread \(threadId.value.uuidString) event \(event.id).")
            }
            return
        }

        try insertProviderEvent(
            db: db,
            threadId: threadId,
            runId: runId,
            event: event,
            boundedPayload: boundedPayload,
            createdAt: createdAt
        )
        rememberProviderEventId(threadId: threadId, eventId: event.id)
    }

    private func insertProviderEvent(
        db: SQLiteDB,
        threadId: AgentThreadID,
        runId: AgentRunID,
        event: ProviderRuntimeEvent,
        boundedPayload: String,
        createdAt: String?
    ) throws {
        let insert = try db.prepare("""
            INSERT INTO agent_provider_event_logs(
                thread_id, run_id, event_id, provider, source, method,
                provider_turn_id, provider_item_id, provider_request_id,
                payload_json, received_at_ms, created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try insert.bind(1, threadId.value.uuidString)
        try insert.bind(2, runId.value.uuidString)
        try insert.bind(3, event.id)
        try insert.bind(4, event.provider.rawValue)
        try insert.bind(5, event.source)
        try insert.bind(6, event.method)
        try insert.bind(7, event.providerTurnId)
        try insert.bind(8, event.providerItemId)
        try insert.bind(9, event.providerRequestId)
        try insert.bind(10, boundedPayload)
        try insert.bind(11, Int64(event.receivedAtMs))
        try insert.bind(12, createdAt ?? iso.string(from: Date()))
        _ = try insert.step()
    }

    @discardableResult
    private func pruneStreamEvents(
        db: SQLiteDB,
        threadId: AgentThreadID,
        keepLatest limit: Int,
        maxPayloadBytes: Int64
    ) throws -> Bool {
        guard limit > 0, maxPayloadBytes > 0 else { return false }
        if try streamRetentionIsUnderBudget(
            db: db,
            threadId: threadId,
            limit: limit,
            maxPayloadBytes: maxPayloadBytes
        ) {
            return false
        }
        let st = try db.prepare("""
            WITH ranked AS (
                SELECT e.id,
                       ROW_NUMBER() OVER (
                           ORDER BY r.started_at DESC, e.seq DESC, e.id DESC
                       ) AS row_number,
                       SUM(LENGTH(CAST(e.payload_json AS BLOB))) OVER (
                           ORDER BY r.started_at DESC, e.seq DESC, e.id DESC
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                       ) AS running_bytes
                FROM agent_stream_events e
                JOIN agent_runs r ON r.id = e.run_id
                WHERE r.thread_id = ?
            )
            DELETE FROM agent_stream_events
            WHERE id IN (
                SELECT id FROM ranked
                -- Always keep the newest row so a large fresh event can enter;
                -- reclaim budget by deleting older rows only.
                WHERE row_number > ? OR (row_number > 1 AND running_bytes > ?)
            );
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(limit))
        try st.bind(3, maxPayloadBytes)
        _ = try st.step()
        return try changedRowCount(db) > 0
    }

    /// COUNT first; SUM payloads only while still under the row cap so a
    /// long stream at the 100-row ceiling does not rescan 8 MiB just to
    /// decide it must window-DELETE.
    private func streamRetentionIsUnderBudget(
        db: SQLiteDB,
        threadId: AgentThreadID,
        limit: Int,
        maxPayloadBytes: Int64
    ) throws -> Bool {
        let countSt = try db.prepare("""
            SELECT COUNT(*)
            FROM agent_stream_events e
            JOIN agent_runs r ON r.id = e.run_id
            WHERE r.thread_id = ?;
        """)
        try countSt.bind(1, threadId.value.uuidString)
        let count = try countSt.step() ? countSt.columnInt64(0) : 0
        guard count <= Int64(limit) else { return false }
        let bytesSt = try db.prepare("""
            SELECT COALESCE(SUM(LENGTH(CAST(e.payload_json AS BLOB))), 0)
            FROM agent_stream_events e
            JOIN agent_runs r ON r.id = e.run_id
            WHERE r.thread_id = ?;
        """)
        try bytesSt.bind(1, threadId.value.uuidString)
        let bytes = try bytesSt.step() ? bytesSt.columnInt64(0) : 0
        return bytes <= maxPayloadBytes
    }

    private func providerRetentionIsUnderBudget(
        db: SQLiteDB,
        threadId: AgentThreadID,
        limit: Int,
        maxPayloadBytes: Int64
    ) throws -> Bool {
        let countSt = try db.prepare("""
            SELECT COUNT(*) FROM agent_provider_event_logs WHERE thread_id = ?;
        """)
        try countSt.bind(1, threadId.value.uuidString)
        let count = try countSt.step() ? countSt.columnInt64(0) : 0
        guard count <= Int64(limit) else { return false }
        let bytesSt = try db.prepare("""
            SELECT COALESCE(SUM(LENGTH(CAST(payload_json AS BLOB))), 0)
            FROM agent_provider_event_logs WHERE thread_id = ?;
        """)
        try bytesSt.bind(1, threadId.value.uuidString)
        let bytes = try bytesSt.step() ? bytesSt.columnInt64(0) : 0
        return bytes <= maxPayloadBytes
    }

    private func changedRowCount(_ db: SQLiteDB) throws -> Int {
        let statement = try db.prepare("SELECT changes();")
        return try statement.step() ? Int(statement.columnInt64(0)) : 0
    }

    private func markAgentHistoryPartial(db: SQLiteDB, threadId: AgentThreadID) throws {
        let statement = try db.prepare("""
            INSERT INTO settings(key, value, updated_at) VALUES(?, '1', ?)
            ON CONFLICT(key) DO UPDATE SET value='1', updated_at=excluded.updated_at;
        """)
        try statement.bind(1, "agent.history.partial.\(threadId.value.uuidString)")
        try statement.bind(2, iso.string(from: Date()))
        _ = try statement.step()
    }

    public func streamHistoryWasPruned(threadId: AgentThreadID) throws -> Bool {
        let statement = try db.prepare("SELECT 1 FROM settings WHERE key = ? LIMIT 1;")
        try statement.bind(1, "agent.history.partial.\(threadId.value.uuidString)")
        return try statement.step()
    }

    /// Global write-time quota. One bounded quantum is removed per retention
    /// cadence, which drains legacy databases without a single long DELETE while
    /// always deleting faster than the bounded ingress batch can grow.
    @discardableResult
    public func pruneGlobalEventPayloads(policy: AgentEventRetentionPolicy = .production) throws -> (
        streamThreads: Set<AgentThreadID>,
        providerRows: Int,
        remainsOverBudget: Bool,
        deletedPayloadBytes: Int64
    ) {
        try db.performSync { database in
            try database.transaction {
                let streamBefore = try storageUsageCounter(database, storageClass: "stream_events")
                let providerBefore = try storageUsageCounter(database, storageClass: "provider_logs")
                let streamThreads = try pruneGlobalStreamEvents(
                    db: database,
                    maxPayloadBytes: policy.streamEventBytesGlobal,
                    maxRows: policy.pruneQuantumRows,
                    maxDeleteBytes: policy.pruneQuantumBytes
                )
                for threadId in streamThreads {
                    try markAgentHistoryPartial(db: database, threadId: threadId)
                }
                let providerRows = try pruneGlobalProviderEventLogs(
                    db: database,
                    maxPayloadBytes: policy.providerLogBytesGlobal,
                    maxRows: policy.pruneQuantumRows,
                    maxDeleteBytes: policy.pruneQuantumBytes
                )
                let streamAfter = try storageUsageCounter(database, storageClass: "stream_events")
                let providerAfter = try storageUsageCounter(database, storageClass: "provider_logs")
                return (
                    streamThreads,
                    providerRows,
                    streamAfter > policy.streamEventBytesGlobal || providerAfter > policy.providerLogBytesGlobal,
                    max(0, streamBefore - streamAfter) + max(0, providerBefore - providerAfter)
                )
            }
        }
    }

    /// Starts one idempotent utility-queue drainer. Each turn performs one
    /// bounded transaction and yields before the next, so legacy/backlogged
    /// data converges without extending the stream-write transaction.
    public func scheduleGlobalEventPayloadPruning(
        policy: AgentEventRetentionPolicy = .production,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        globalRetentionStateLock.lock()
        globalRetentionRequested = true
        if let completion { globalRetentionCompletions.append(completion) }
        guard !globalRetentionScheduled else {
            globalRetentionStateLock.unlock()
            return
        }
        globalRetentionScheduled = true
        globalRetentionStateLock.unlock()
        scheduleGlobalEventPayloadPruningQuantum(policy: policy)
    }

    private func scheduleGlobalEventPayloadPruningQuantum(policy: AgentEventRetentionPolicy) {
        globalRetentionQueue.asyncAfter(deadline: .now() + 0.01) { [self] in
            globalRetentionStateLock.lock()
            globalRetentionRequested = false
            globalRetentionStateLock.unlock()
            do {
                let result = try pruneGlobalEventPayloads(policy: policy)
                if result.remainsOverBudget, result.deletedPayloadBytes > 0 {
                    scheduleGlobalEventPayloadPruningQuantum(policy: policy)
                    return
                }
                finishGlobalEventPayloadPruning(
                    policy: policy,
                    success: !result.remainsOverBudget
                )
            } catch {
                finishGlobalEventPayloadPruning(policy: policy, success: false)
            }
        }
    }

    private func finishGlobalEventPayloadPruning(
        policy: AgentEventRetentionPolicy,
        success: Bool
    ) {
        globalRetentionStateLock.lock()
        if globalRetentionRequested {
            globalRetentionRequested = false
            globalRetentionStateLock.unlock()
            scheduleGlobalEventPayloadPruningQuantum(policy: policy)
            return
        }
        globalRetentionScheduled = false
        let completions = globalRetentionCompletions
        globalRetentionCompletions.removeAll(keepingCapacity: true)
        globalRetentionStateLock.unlock()
        for completion in completions { completion(success) }
    }

    private func pruneGlobalStreamEvents(
        db: SQLiteDB,
        maxPayloadBytes: Int64,
        maxRows: Int,
        maxDeleteBytes: Int64
    ) throws -> Set<AgentThreadID> {
        let total = try storageUsageCounter(db, storageClass: "stream_events")
        guard total > maxPayloadBytes else { return [] }
        let candidates = try db.prepare("""
            SELECT e.id, r.thread_id,
                   LENGTH(CAST(e.event_kind AS BLOB)) + LENGTH(CAST(e.payload_json AS BLOB))
            FROM agent_stream_events e
            JOIN agent_runs r ON r.id = e.run_id
            ORDER BY e.id ASC
            LIMIT ?;
        """)
        try candidates.bind(1, max(1, maxRows))
        var ids: [Int64] = []
        var threads = Set<AgentThreadID>()
        var bytes: Int64 = 0
        let needed = min(total - maxPayloadBytes, max(1, maxDeleteBytes))
        while try candidates.step() {
            ids.append(candidates.columnInt64(0))
            if let raw = candidates.columnText(1), let uuid = UUID(uuidString: raw) {
                threads.insert(AgentThreadID(uuid))
            }
            bytes += max(0, candidates.columnInt64(2))
            if bytes >= needed { break }
        }
        try deleteRows(db, table: "agent_stream_events", ids: ids)
        return threads
    }

    private func pruneGlobalProviderEventLogs(
        db: SQLiteDB,
        maxPayloadBytes: Int64,
        maxRows: Int,
        maxDeleteBytes: Int64
    ) throws -> Int {
        let total = try storageUsageCounter(db, storageClass: "provider_logs")
        guard total > maxPayloadBytes else { return 0 }
        let candidates = try db.prepare("""
            SELECT id,
                   LENGTH(CAST(source AS BLOB)) + LENGTH(CAST(method AS BLOB)) + LENGTH(CAST(payload_json AS BLOB))
            FROM agent_provider_event_logs
            ORDER BY id ASC
            LIMIT ?;
        """)
        try candidates.bind(1, max(1, maxRows))
        var ids: [Int64] = []
        var bytes: Int64 = 0
        let needed = min(total - maxPayloadBytes, max(1, maxDeleteBytes))
        while try candidates.step() {
            ids.append(candidates.columnInt64(0))
            bytes += max(0, candidates.columnInt64(1))
            if bytes >= needed { break }
        }
        try deleteRows(db, table: "agent_provider_event_logs", ids: ids)
        return ids.count
    }

    private func storageUsageCounter(_ db: SQLiteDB, storageClass: String) throws -> Int64 {
        let statement = try db.prepare(
            "SELECT payload_bytes FROM storage_usage_counters WHERE storage_class = ? LIMIT 1;"
        )
        try statement.bind(1, storageClass)
        return try statement.step() ? statement.columnInt64(0) : 0
    }

    private func deleteRows(_ db: SQLiteDB, table: String, ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let statement = try db.prepare("DELETE FROM \(table) WHERE id IN (\(placeholders));")
        for (index, id) in ids.enumerated() {
            try statement.bind(Int32(index + 1), id)
        }
        _ = try statement.step()
    }

    public func streamEventPayloadBytes(threadId: AgentThreadID) throws -> Int64 {
        let st = try db.prepare("""
            SELECT COALESCE(SUM(LENGTH(CAST(e.payload_json AS BLOB))), 0)
            FROM agent_stream_events e
            JOIN agent_runs r ON r.id = e.run_id
            WHERE r.thread_id = ?;
        """)
        try st.bind(1, threadId.value.uuidString)
        return try st.step() ? st.columnInt64(0) : 0
    }

    public func providerEventPayloadBytes(threadId: AgentThreadID) throws -> Int64 {
        let st = try db.prepare("""
            SELECT COALESCE(SUM(LENGTH(CAST(payload_json AS BLOB))), 0)
            FROM agent_provider_event_logs WHERE thread_id = ?;
        """)
        try st.bind(1, threadId.value.uuidString)
        return try st.step() ? st.columnInt64(0) : 0
    }

    public func countStreamEvents(threadId: AgentThreadID) throws -> Int {
        let st = try db.prepare("""
            SELECT COUNT(*)
            FROM agent_stream_events e
            JOIN agent_runs r ON r.id = e.run_id
            WHERE r.thread_id = ?;
        """)
        try st.bind(1, threadId.value.uuidString)
        if try st.step() { return Int(st.columnInt64(0)) }
        return 0
    }

    public func listLatestStreamEvents(
        threadId: AgentThreadID,
        limit: Int = 500,
        maxPayloadBytes: Int64? = nil,
        strictDecoding: Bool = false
    ) throws -> [AssistantEvent] {
        let sql: String
        if maxPayloadBytes != nil {
            sql = """
            WITH ranked AS (
                SELECT e.payload_json, r.started_at, e.seq, e.id,
                       ROW_NUMBER() OVER (
                           ORDER BY r.started_at DESC, e.seq DESC, e.id DESC
                       ) AS row_number,
                       SUM(LENGTH(CAST(e.payload_json AS BLOB))) OVER (
                           ORDER BY r.started_at DESC, e.seq DESC, e.id DESC
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                       ) AS running_bytes
                FROM agent_stream_events e
                JOIN agent_runs r ON r.id = e.run_id
                WHERE r.thread_id = ?
            )
            SELECT payload_json, id
            FROM (
                SELECT payload_json, started_at, seq, id
                FROM ranked
                WHERE row_number <= ? AND (row_number = 1 OR running_bytes <= ?)
            )
            ORDER BY started_at ASC, seq ASC, id ASC;
            """
        } else {
            sql = """
            SELECT payload_json, id
            FROM (
                SELECT e.payload_json, r.started_at, e.seq, e.id
                FROM agent_stream_events e
                JOIN agent_runs r ON r.id = e.run_id
                WHERE r.thread_id = ?
                ORDER BY r.started_at DESC, e.seq DESC, e.id DESC
                LIMIT ?
            )
            ORDER BY started_at ASC, seq ASC, id ASC;
            """
        }
        let st = try db.prepare(sql)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(limit))
        if let maxPayloadBytes { try st.bind(3, max(1, maxPayloadBytes)) }
        var payloads: [(eventId: Int64, data: Data)] = []
        while try st.step() {
            let eventId = st.columnInt64(1)
            guard let json = st.columnText(0),
                  let data = json.data(using: .utf8) else {
                if strictDecoding {
                    throw PersistenceDataError.corruptStreamEvent("row \(eventId) has no UTF-8 payload")
                }
                continue
            }
            payloads.append((eventId, data))
        }
        // When a byte budget is set, re-admit using original sizes so rehydrate
        // cannot expand past the hot-replay ceiling.
        if let maxPayloadBytes {
            var admitted: [(eventId: Int64, data: Data)] = []
            var used: Int64 = 0
            // payloads are chronological (oldest→newest); admit newest-first.
            for payload in payloads.reversed() {
                let text = String(decoding: payload.data, as: UTF8.self)
                let original = Int64(AuthoritativePayloadRecovery.authoritativeByteCount(forStoredPayload: text))
                if admitted.isEmpty && original > maxPayloadBytes {
                    // Newest alone exceeds budget: return empty (same as ThreadReadV1).
                    return []
                }
                if used + original > maxPayloadBytes { break }
                admitted.append(payload)
                used += original
            }
            payloads = admitted.reversed()
            return try decodeStreamEventPayloads(
                payloads,
                strictDecoding: strictDecoding,
                remainingByteBudget: maxPayloadBytes
            )
        }
        // Legacy / unbounded callers: keep full history (no aggregate 16 MiB cut
        // that would silently discard older events while reporting complete).
        // Per-frame original size is still gated inside decode to the presentation
        // ceiling so a single recovery blob cannot expand unboundedly.
        return try decodeStreamEventPayloads(payloads, strictDecoding: strictDecoding)
    }

    // MARK: - agent.thread.read response_version=1 (metadata-first)

    /// Metadata for one persisted stream row without transferring `payload_json`.
    public struct StreamEventRowMeta: Sendable, Equatable {
        public let id: Int64
        public let seq: Int
        public let payloadBytes: Int64

        public init(id: Int64, seq: Int, payloadBytes: Int64) {
            self.id = id
            self.seq = seq
            self.payloadBytes = payloadBytes
        }
    }

    /// Newest event blocked because its stored payload alone exceeds the byte cap.
    public struct BlockedStreamEvent: Sendable, Equatable {
        public let id: Int64
        public let payloadBytes: Int64
        public let reason: String

        public init(id: Int64, payloadBytes: Int64, reason: String = "byte_limit") {
            self.id = id
            self.payloadBytes = payloadBytes
            self.reason = reason
        }
    }

    /// Contiguous newest suffix selected without decoding rejected rows.
    public struct BoundedStreamEventSelection: Sendable, Equatable {
        public let events: [AssistantEvent]
        /// True when older rows exist beyond this window (count probe and/or byte cut).
        public let hasMoreOlder: Bool
        public let blockedNewest: BlockedStreamEvent?
        /// Row ids whose `payload_json` was transferred and decoded (testable).
        public let decodedRowIds: [Int64]
        /// Metadata rows inspected (at most `eventLimit + 1`).
        public let inspectedRowCount: Int

        public init(
            events: [AssistantEvent],
            hasMoreOlder: Bool,
            blockedNewest: BlockedStreamEvent?,
            decodedRowIds: [Int64],
            inspectedRowCount: Int
        ) {
            self.events = events
            self.hasMoreOlder = hasMoreOlder
            self.blockedNewest = blockedNewest
            self.decodedRowIds = decodedRowIds
            self.inspectedRowCount = inspectedRowCount
        }
    }

    /// Metadata-only newest rows: `id`, `seq`, and authoritative payload bytes.
    /// For owned oversized trailers, uses the original byte count from a **bounded
    /// trailer suffix** (not the full payload) so metadata-first reads stay small.
    public func listLatestStreamEventMetadata(
        threadId: AgentThreadID,
        limit: Int
    ) throws -> [StreamEventRowMeta] {
        let safeLimit = max(0, limit)
        guard safeLimit > 0 else { return [] }
        // Project LENGTH(blob) + last ~240 characters only. Never SELECT full payload_json.
        let st = try db.prepare("""
            SELECT id, seq, presentation_bytes, trailer_suffix
            FROM (
                SELECT e.id AS id,
                       e.seq AS seq,
                       r.started_at AS started_at,
                       LENGTH(CAST(e.payload_json AS BLOB)) AS presentation_bytes,
                       substr(e.payload_json, -240) AS trailer_suffix
                FROM agent_stream_events e
                JOIN agent_runs r ON r.id = e.run_id
                WHERE r.thread_id = ?
                ORDER BY r.started_at DESC, e.seq DESC, e.id DESC
                LIMIT ?
            )
            ORDER BY started_at ASC, seq ASC, id ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(safeLimit))
        var rows: [StreamEventRowMeta] = []
        while try st.step() {
            let id = st.columnInt64(0)
            let seq = Int(st.columnInt64(1))
            let presentation = st.columnInt64(2)
            let trailer = st.columnText(3) ?? ""
            let authoritative = Int64(
                AuthoritativePayloadRecovery.authoritativeByteCount(
                    forStoredPayload: trailer,
                    presentationFallback: Int(presentation)
                )
            )
            rows.append(StreamEventRowMeta(id: id, seq: seq, payloadBytes: authoritative))
        }
        return rows
    }

    /// Fetch + decode only the given row ids (chronological). Does not scan peers.
    public func listStreamEventsByIds(
        _ ids: [Int64],
        strictDecoding: Bool = true,
        remainingByteBudget: Int64? = nil
    ) throws -> [AssistantEvent] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let st = try db.prepare("""
            SELECT e.id, e.payload_json
            FROM agent_stream_events e
            JOIN agent_runs r ON r.id = e.run_id
            WHERE e.id IN (\(placeholders))
            ORDER BY r.started_at ASC, e.seq ASC, e.id ASC;
        """)
        for (offset, id) in ids.enumerated() {
            try st.bind(Int32(offset + 1), id)
        }
        var payloads: [(eventId: Int64, data: Data)] = []
        while try st.step() {
            let eventId = st.columnInt64(0)
            guard let json = st.columnText(1),
                  let data = json.data(using: .utf8) else {
                if strictDecoding {
                    throw PersistenceDataError.corruptStreamEvent("row \(eventId) has no UTF-8 payload")
                }
                continue
            }
            payloads.append((eventId, data))
        }
        return try decodeStreamEventPayloads(
            payloads,
            strictDecoding: strictDecoding,
            remainingByteBudget: remainingByteBudget
        )
    }

    private func decodeStreamEventPayloads(
        _ payloads: [(eventId: Int64, data: Data)],
        strictDecoding: Bool,
        remainingByteBudget: Int64? = nil
    ) throws -> [AssistantEvent] {
        streamEventCodecLock.lock()
        defer { streamEventCodecLock.unlock() }
        var events: [AssistantEvent] = []
        events.reserveCapacity(payloads.count)
        var budget = remainingByteBudget
        for payload in payloads {
            do {
                // S3: rehydrate oversized recovery envelopes before AssistantEvent decode.
                // Admission already used original size when budget was provided; re-check
                // before expanding the recovery blob.
                let rawText = String(decoding: payload.data, as: UTF8.self)
                let originalBytes = Int64(AuthoritativePayloadRecovery.authoritativeByteCount(forStoredPayload: rawText))
                // Always enforce the absolute presentation ceiling on a single
                // original so rehydrate cannot expand one recovery blob unboundedly.
                let singleCeiling = Int64(Self.maximumPersistedEventRowBytes)
                if originalBytes > singleCeiling {
                    if strictDecoding {
                        throw PersistenceDataError.corruptStreamEvent(
                            "row \(payload.eventId) original \(originalBytes) exceeds presentation ceiling \(singleCeiling)"
                        )
                    }
                    continue
                }
                if let remaining = budget {
                    if originalBytes > remaining {
                        if strictDecoding {
                            throw PersistenceDataError.corruptStreamEvent(
                                "row \(payload.eventId) original \(originalBytes) exceeds remaining budget \(remaining)"
                            )
                        }
                        continue
                    }
                    budget = remaining - originalBytes
                }
                let resolvedText = try rehydrateOversizedPayloadIfNeeded(rawText)
                let resolvedData = Data(resolvedText.utf8)
                events.append(try streamEventDecoder.decode(AssistantEvent.self, from: resolvedData))
            } catch {
                if strictDecoding {
                    throw PersistenceDataError.corruptStreamEvent(
                        "row \(payload.eventId) has an invalid AssistantEvent payload"
                    )
                }
            }
        }
        return events
    }

    /// agent.thread.read v1 source path: inspect lengths first, decode only the
    /// contiguous newest suffix that fits both `eventLimit` and `maxPayloadBytes`.
    /// A newest row over the byte cap is never transferred or decoded.
    public func listLatestStreamEventsForThreadReadV1(
        threadId: AgentThreadID,
        eventLimit: Int,
        maxPayloadBytes: Int64,
        strictDecoding: Bool = true
    ) throws -> BoundedStreamEventSelection {
        let safeEventLimit = max(1, eventLimit)
        let safeMaxBytes = max(1, maxPayloadBytes)
        // +1 probe for honest has_more without materializing full history.
        let meta = try listLatestStreamEventMetadata(
            threadId: threadId,
            limit: safeEventLimit + 1
        )
        guard !meta.isEmpty else {
            return BoundedStreamEventSelection(
                events: [],
                hasMoreOlder: false,
                blockedNewest: nil,
                decodedRowIds: [],
                inspectedRowCount: 0
            )
        }

        // meta is chronological (oldest→newest). Walk newest-first for suffix.
        let newest = meta[meta.count - 1]
        if newest.payloadBytes > safeMaxBytes {
            // Do not fetch/decode the oversized newest (or any older) row.
            return BoundedStreamEventSelection(
                events: [],
                hasMoreOlder: true,
                blockedNewest: BlockedStreamEvent(
                    id: newest.id,
                    payloadBytes: newest.payloadBytes,
                    reason: "byte_limit"
                ),
                decodedRowIds: [],
                inspectedRowCount: meta.count
            )
        }

        var selectedNewestFirst: [StreamEventRowMeta] = []
        var usedBytes: Int64 = 0
        for row in meta.reversed() {
            if selectedNewestFirst.count >= safeEventLimit { break }
            if usedBytes + row.payloadBytes > safeMaxBytes { break }
            selectedNewestFirst.append(row)
            usedBytes += row.payloadBytes
        }
        let selected = Array(selectedNewestFirst.reversed())
        let selectedIds = selected.map(\.id)

        // has_more: +1 probe row, or we dropped any inspected row for count/bytes.
        let droppedFromInspected = selected.count < meta.count
        let hasMoreOlder = droppedFromInspected

        let events = try listStreamEventsByIds(
            selectedIds,
            strictDecoding: strictDecoding,
            remainingByteBudget: safeMaxBytes
        )
        return BoundedStreamEventSelection(
            events: events,
            hasMoreOlder: hasMoreOlder,
            blockedNewest: nil,
            decodedRowIds: selectedIds,
            inspectedRowCount: meta.count
        )
    }
}

public struct AgentProposedPlanRecord: Equatable, Sendable {
    public var threadId: AgentThreadID
    public var plan: AssistantProposedPlan
    public var implementationThreadId: AgentThreadID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(threadId: AgentThreadID, plan: AssistantProposedPlan, implementationThreadId: AgentThreadID? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.threadId = threadId
        self.plan = plan
        self.implementationThreadId = implementationThreadId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public final class AgentProposedPlanRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func upsert(threadId: AgentThreadID, plan: AssistantProposedPlan) throws {
        let now = iso.string(from: Date())
        let st = try db.prepare("""
            INSERT INTO agent_proposed_plans(thread_id, plan_id, turn_id, markdown, implemented_at, implementation_thread_id, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, NULL, ?, ?)
            ON CONFLICT(thread_id, plan_id) DO UPDATE SET
                turn_id=excluded.turn_id,
                markdown=excluded.markdown,
                implemented_at=excluded.implemented_at,
                updated_at=excluded.updated_at;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, plan.id)
        try st.bind(3, plan.turnId)
        try st.bind(4, plan.markdown)
        try st.bind(5, plan.implementedAtMs.map { iso.string(from: Date(timeIntervalSince1970: Double($0) / 1000.0)) })
        try st.bind(6, now)
        try st.bind(7, now)
        _ = try st.step()
    }

    public func markImplemented(threadId: AgentThreadID, planId: String, implementationThreadId: AgentThreadID, at date: Date = Date()) throws {
        try db.performSync { database in
            try database.transaction {
                let st = try database.prepare("""
                    UPDATE agent_proposed_plans
                    SET implemented_at = ?, implementation_thread_id = ?, updated_at = ?
                    WHERE thread_id = ? AND plan_id = ?;
                """)
                let now = iso.string(from: date)
                try st.bind(1, now)
                try st.bind(2, implementationThreadId.value.uuidString)
                try st.bind(3, now)
                try st.bind(4, threadId.value.uuidString)
                try st.bind(5, planId)
                _ = try st.step()
                let changes = try database.prepare("SELECT changes();")
                guard try changes.step(), changes.columnInt64(0) == 1 else {
                    throw SQLiteError.execute("Proposed plan was not found or could not be marked implemented.")
                }
            }
        }
    }

    public func list(threadId: AgentThreadID) throws -> [AgentProposedPlanRecord] {
        let st = try db.prepare("""
            SELECT thread_id, plan_id, turn_id, markdown, implemented_at, implementation_thread_id, created_at, updated_at
            FROM agent_proposed_plans
            WHERE thread_id = ?
            ORDER BY created_at ASC, plan_id ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        var out: [AgentProposedPlanRecord] = []
        while try st.step() {
            let storedThreadId = AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? threadId.value)
            let implementedAt = st.columnText(4).map(parseDate)
            let implementationThreadId = st.columnText(5).flatMap(UUID.init(uuidString:)).map(AgentThreadID.init)
            out.append(AgentProposedPlanRecord(
                threadId: storedThreadId,
                plan: AssistantProposedPlan(
                    id: st.columnText(1) ?? "",
                    turnId: st.columnText(2),
                    markdown: st.columnText(3) ?? "",
                    implementedAtMs: implementedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                ),
                implementationThreadId: implementationThreadId,
                createdAt: parseDate(st.columnText(6)),
                updatedAt: parseDate(st.columnText(7))
            ))
        }
        return out
    }
}

public final class AgentTurnCheckpointRepository {
    let db: SQLiteDB
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Checkpoint list keyset timestamps must round-trip sub-second values so
    /// iOS item equality and DB continuation use the same bound string.
    private static let completedAtFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(db: SQLiteDB) { self.db = db }

    public func upsert(_ checkpoint: AgentTurnCheckpointSummary) throws {
        let filesData = try encoder.encode(checkpoint.files)
        let filesJSON = String(data: filesData, encoding: .utf8) ?? "[]"
        let fileSummary = try boundedFileSummary(checkpoint.files)
        let listProjection = AgentTurnCheckpointListWireProjection.capture(
            turnId: checkpoint.turnId,
            checkpointRef: checkpoint.checkpointRef,
            errorMessage: checkpoint.errorMessage
        )
        let snapshotsData = try encoder.encode(checkpoint.fileSnapshots)
        let snapshotsJSON = String(data: snapshotsData, encoding: .utf8) ?? "[]"
        let fileDiffsData = try encoder.encode(checkpoint.fileDiffs)
        let fileDiffsJSON = String(data: fileDiffsData, encoding: .utf8) ?? "[]"
        let now = iso.string(from: Date())
        let st = try db.prepare("""
            INSERT INTO agent_turn_checkpoints(
                thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status,
                files_json, assistant_message_id, error_message, completed_at, created_at,
                file_snapshots_json, diff_patch, file_diffs_json,
                files_summary_json, files_summary_truncated,
                list_turn_id, list_turn_id_encoded_bytes, list_turn_id_sha256, list_turn_id_truncated,
                list_checkpoint_ref, list_checkpoint_ref_encoded_bytes, list_checkpoint_ref_sha256, list_checkpoint_ref_truncated,
                list_error_message, list_error_message_encoded_bytes, list_error_message_sha256, list_error_message_truncated,
                list_completed_at, list_metadata_unavailable
            )
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id, turn_id) DO UPDATE SET
                run_id=excluded.run_id,
                checkpoint_turn_count=excluded.checkpoint_turn_count,
                checkpoint_ref=excluded.checkpoint_ref,
                status=excluded.status,
                files_json=excluded.files_json,
                file_snapshots_json=excluded.file_snapshots_json,
                diff_patch=excluded.diff_patch,
                file_diffs_json=excluded.file_diffs_json,
                files_summary_json=excluded.files_summary_json,
                files_summary_truncated=excluded.files_summary_truncated,
                list_turn_id=excluded.list_turn_id,
                list_turn_id_encoded_bytes=excluded.list_turn_id_encoded_bytes,
                list_turn_id_sha256=excluded.list_turn_id_sha256,
                list_turn_id_truncated=excluded.list_turn_id_truncated,
                list_checkpoint_ref=excluded.list_checkpoint_ref,
                list_checkpoint_ref_encoded_bytes=excluded.list_checkpoint_ref_encoded_bytes,
                list_checkpoint_ref_sha256=excluded.list_checkpoint_ref_sha256,
                list_checkpoint_ref_truncated=excluded.list_checkpoint_ref_truncated,
                list_error_message=excluded.list_error_message,
                list_error_message_encoded_bytes=excluded.list_error_message_encoded_bytes,
                list_error_message_sha256=excluded.list_error_message_sha256,
                list_error_message_truncated=excluded.list_error_message_truncated,
                list_completed_at=excluded.list_completed_at,
                list_metadata_unavailable=excluded.list_metadata_unavailable,
                assistant_message_id=excluded.assistant_message_id,
                error_message=excluded.error_message,
                completed_at=excluded.completed_at;
        """)
        try st.bind(1, checkpoint.threadId.value.uuidString)
        try st.bind(2, checkpoint.runId.value.uuidString)
        try st.bind(3, checkpoint.turnId)
        try st.bind(4, Int64(checkpoint.checkpointTurnCount))
        try st.bind(5, checkpoint.checkpointRef)
        try st.bind(6, checkpoint.status.rawValue)
        try st.bind(7, filesJSON)
        try st.bind(8, checkpoint.assistantMessageId?.value.uuidString)
        try st.bind(9, checkpoint.errorMessage)
        try st.bind(10, formatCompletedAt(checkpoint.completedAt))
        try st.bind(11, now)
        try st.bind(12, snapshotsJSON)
        try st.bind(13, checkpoint.diffPatch)
        try st.bind(14, fileDiffsJSON)
        try st.bind(15, fileSummary.json)
        try st.bind(16, fileSummary.truncated ? Int64(1) : Int64(0))
        try st.bind(17, listProjection.turnId.value ?? "")
        try st.bind(18, Int64(listProjection.turnId.totalEncodedBytes))
        try st.bind(19, listProjection.turnId.sha256)
        try st.bind(20, listProjection.turnId.truncated ? Int64(1) : Int64(0))
        try st.bind(21, listProjection.checkpointRef.value ?? "")
        try st.bind(22, Int64(listProjection.checkpointRef.totalEncodedBytes))
        try st.bind(23, listProjection.checkpointRef.sha256)
        try st.bind(24, listProjection.checkpointRef.truncated ? Int64(1) : Int64(0))
        try st.bind(25, listProjection.errorMessage.value)
        try st.bind(26, Int64(listProjection.errorMessage.totalEncodedBytes))
        try st.bind(27, listProjection.errorMessage.sha256)
        try st.bind(28, listProjection.errorMessage.truncated ? Int64(1) : Int64(0))
        try st.bind(29, formatCompletedAt(checkpoint.completedAt))
        try st.bind(30, Int64(0))
        _ = try st.step()
    }

    private func boundedFileSummary(
        _ files: [AgentTurnCheckpointFile]
    ) throws -> (json: String, truncated: Bool) {
        let maxFiles = AgentTurnCheckpointListWireProjection.maxFiles
        let maxBytes = AgentTurnCheckpointListWireProjection.maxEncodedFilesBytes
        var kept: [AgentTurnCheckpointFile] = []
        kept.reserveCapacity(min(files.count, maxFiles))
        var encoded = try encoder.encode(kept)
        for file in files {
            guard kept.count < maxFiles else { break }
            let candidate = kept + [file]
            let candidateData = try encoder.encode(candidate)
            guard candidateData.count <= maxBytes else {
                break
            }
            kept = candidate
            encoded = candidateData
        }
        return (
            String(data: encoded, encoding: .utf8) ?? "[]",
            kept.count < files.count
        )
    }

    private func formatCompletedAt(_ date: Date) -> String {
        Self.completedAtFractional.string(from: date)
    }

    private func parseCompletedAt(_ raw: String?) -> Date {
        parseDate(raw)
    }

    /// List v1 keysets may only use the fixed-width capture token persisted by
    /// the checkpoint-list schema step / upsert. Unlike the legacy detail decoder,
    /// this path must never replace corrupt storage with wall-clock `Date()`
    /// because that would make pagination change between identical reads.
    private func parseListCompletedAt(_ raw: String?) throws -> (token: String, date: Date) {
        guard let raw,
              raw.utf8.count == 24,
              let date = Self.completedAtFractional.date(from: raw) else {
            throw PersistenceDataError.corruptCheckpoint(
                "invalid bounded list_completed_at token"
            )
        }
        return (raw, date)
    }

    public func nextTurnCount(threadId: AgentThreadID) throws -> Int {
        let st = try db.prepare("""
            SELECT COALESCE(MAX(checkpoint_turn_count), 0) + 1
            FROM agent_turn_checkpoints
            WHERE thread_id = ?;
        """)
        try st.bind(1, threadId.value.uuidString)
        guard try st.step() else { return 1 }
        return Int(st.columnInt64(0))
    }

    // MARK: - Tolerant list

    /// Partition decode attempts into healthy results and a corrupt count.
    /// Pure function: no I/O, no side-effects. Preserves order of healthy rows.
    ///
    /// WHY: one corrupt checkpoint row must not hide the user's other good checkpoints.
    static func decodableCheckpoints(
        _ attempts: [Result<AgentTurnCheckpointSummary, Error>]
    ) -> (healthy: [AgentTurnCheckpointSummary], corruptCount: Int) {
        var healthy: [AgentTurnCheckpointSummary] = []
        var corruptCount = 0
        for result in attempts {
            switch result {
            case .success(let cp): healthy.append(cp)
            case .failure: corruptCount += 1
            }
        }
        return (healthy, corruptCount)
    }

    /// List checkpoints for a thread, skipping any rows that fail to decode.
    /// Returns healthy checkpoints in ascending checkpoint_turn_count order,
    /// plus the number of corrupt rows that were skipped (never silently zero'd).
    public func listTolerant(threadId: AgentThreadID) throws -> (healthy: [AgentTurnCheckpointSummary], corruptCount: Int) {
        let st = try db.prepare("""
            SELECT thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status, files_json, assistant_message_id, error_message, completed_at, file_snapshots_json, diff_patch, file_diffs_json
            FROM agent_turn_checkpoints
            WHERE thread_id = ?
            ORDER BY checkpoint_turn_count ASC, completed_at ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        var attempts: [Result<AgentTurnCheckpointSummary, Error>] = []
        while try st.step() {
            do {
                attempts.append(.success(try decodeCheckpoint(from: st, fallbackThreadId: threadId)))
            } catch {
                attempts.append(.failure(error))
            }
        }
        return AgentTurnCheckpointRepository.decodableCheckpoints(attempts)
    }

    public func list(threadId: AgentThreadID) throws -> [AgentTurnCheckpointSummary] {
        let st = try db.prepare("""
            SELECT thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status, files_json, assistant_message_id, error_message, completed_at, file_snapshots_json, diff_patch, file_diffs_json
            FROM agent_turn_checkpoints
            WHERE thread_id = ?
            ORDER BY checkpoint_turn_count ASC, completed_at ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        var attempts: [Result<AgentTurnCheckpointSummary, Error>] = []
        while try st.step() {
            do {
                attempts.append(.success(try decodeCheckpoint(from: st, fallbackThreadId: threadId)))
            } catch {
                attempts.append(.failure(error))
            }
        }
        return AgentTurnCheckpointRepository.decodableCheckpoints(attempts).healthy
    }

    public func get(threadId: AgentThreadID, checkpointTurnCount: Int) throws -> AgentTurnCheckpointSummary? {
        let st = try db.prepare("""
            SELECT thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status, files_json, assistant_message_id, error_message, completed_at, file_snapshots_json, diff_patch, file_diffs_json
            FROM agent_turn_checkpoints
            WHERE thread_id = ? AND checkpoint_turn_count = ?
            ORDER BY completed_at DESC
            LIMIT 1;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(checkpointTurnCount))
        guard try st.step() else { return nil }
        return try decodeCheckpoint(from: st, fallbackThreadId: threadId)
    }

    public func listAfterTolerant(threadId: AgentThreadID, checkpointTurnCount: Int) throws -> (healthy: [AgentTurnCheckpointSummary], corruptCount: Int) {
        let st = try db.prepare("""
            SELECT thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status, files_json, assistant_message_id, error_message, completed_at, file_snapshots_json, diff_patch, file_diffs_json
            FROM agent_turn_checkpoints
            WHERE thread_id = ? AND checkpoint_turn_count > ?
            ORDER BY checkpoint_turn_count ASC, completed_at ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(checkpointTurnCount))
        var attempts: [Result<AgentTurnCheckpointSummary, Error>] = []
        while try st.step() {
            do {
                attempts.append(.success(try decodeCheckpoint(from: st, fallbackThreadId: threadId)))
            } catch {
                attempts.append(.failure(error))
            }
        }
        return AgentTurnCheckpointRepository.decodableCheckpoints(attempts)
    }

    public func listAfter(threadId: AgentThreadID, checkpointTurnCount: Int) throws -> [AgentTurnCheckpointSummary] {
        let st = try db.prepare("""
            SELECT thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status, files_json, assistant_message_id, error_message, completed_at, file_snapshots_json, diff_patch, file_diffs_json
            FROM agent_turn_checkpoints
            WHERE thread_id = ? AND checkpoint_turn_count > ?
            ORDER BY checkpoint_turn_count ASC, completed_at ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(checkpointTurnCount))
        var attempts: [Result<AgentTurnCheckpointSummary, Error>] = []
        while try st.step() {
            do {
                attempts.append(.success(try decodeCheckpoint(from: st, fallbackThreadId: threadId)))
            } catch {
                attempts.append(.failure(error))
            }
        }
        return AgentTurnCheckpointRepository.decodableCheckpoints(attempts).healthy
    }

    public func deleteAfter(threadId: AgentThreadID, checkpointTurnCount: Int) throws {
        let st = try db.prepare("""
            DELETE FROM agent_turn_checkpoints
            WHERE thread_id = ? AND checkpoint_turn_count > ?;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(checkpointTurnCount))
        _ = try st.step()
    }

    /// Metadata-only page for mobile/3G clients (`agent.checkpoint.list` response_version 1).
    ///
    /// Selects only capture-time bounded list projections, files_summary, and
    /// scalar metadata. Never selects authoritative raw `turn_id`,
    /// `checkpoint_ref`, `error_message`, `files_json`, `file_snapshots_json`,
    /// `diff_patch`, or `file_diffs_json` for page rows. Uses descending keyset
    /// pagination on bounded `(checkpoint_turn_count, list_completed_at,
    /// list_turn_id)` with `LIMIT maxEntries + 1`.
    ///
    /// When `expectedCatalogRevision` is set (continuation pages), it is
    /// preclaimed inside the same read snapshot **before** any page row
    /// query/decode. A stale fence fails closed with no page work.
    public func listMetadataPage(
        threadId: AgentThreadID,
        maxEntries: Int,
        before cursor: AgentTurnCheckpointCursor?,
        expectedCatalogRevision: Int64? = nil
    ) throws -> AgentTurnCheckpointPage {
        let limit = max(1, min(maxEntries, AgentTurnCheckpointListWireProjection.maxEntries))
        // Snapshot revision + page rows under one **read** transaction so a
        // concurrent mutation cannot splice two catalog generations into one
        // response, without reserving the writer (BEGIN DEFERRED).
        return try db.readTransaction {
            let catalogRevision = try AgentTurnCheckpointCatalogRevision.current(
                db: db,
                threadId: threadId
            )
            if let expectedCatalogRevision,
               expectedCatalogRevision != catalogRevision {
                throw AgentTurnCheckpointListError.staleCatalogRevision(
                    current: catalogRevision
                )
            }
            // WHY: only capture-bounded list_* fields and explicitly capped small
            // scalars may cross the SQLite/Swift boundary. Authoritative raw metadata
            // must stay untouched even for ordering/cursors.
            let selectList = """
                SELECT
                       CASE WHEN length(CAST(thread_id AS BLOB)) <= 36 THEN thread_id END,
                       length(CAST(thread_id AS BLOB)),
                       CASE WHEN length(CAST(run_id AS BLOB)) <= 36 THEN run_id END,
                       length(CAST(run_id AS BLOB)),
                       CASE WHEN length(CAST(list_turn_id AS BLOB)) <= \(AgentTurnCheckpointWireIdentity.maximumEncodedTurnIDBytes) THEN list_turn_id END,
                       length(CAST(list_turn_id AS BLOB)),
                       list_turn_id_encoded_bytes,
                       CASE WHEN length(CAST(list_turn_id_sha256 AS BLOB)) <= 64 THEN list_turn_id_sha256 END,
                       COALESCE(length(CAST(list_turn_id_sha256 AS BLOB)), 0),
                       list_turn_id_truncated,
                       checkpoint_turn_count,
                       CASE WHEN length(CAST(list_checkpoint_ref AS BLOB)) <= \(AgentTurnCheckpointListWireProjection.maxEncodedCheckpointRefBytes) THEN list_checkpoint_ref END,
                       length(CAST(list_checkpoint_ref AS BLOB)),
                       list_checkpoint_ref_encoded_bytes,
                       CASE WHEN length(CAST(list_checkpoint_ref_sha256 AS BLOB)) <= 64 THEN list_checkpoint_ref_sha256 END,
                       COALESCE(length(CAST(list_checkpoint_ref_sha256 AS BLOB)), 0),
                       list_checkpoint_ref_truncated,
                       CASE WHEN length(CAST(status AS BLOB)) <= 16 THEN status END,
                       length(CAST(status AS BLOB)),
                       CASE WHEN length(CAST(files_summary_json AS BLOB)) <= \(AgentTurnCheckpointListWireProjection.maxEncodedFilesBytes) THEN files_summary_json END,
                       length(CAST(files_summary_json AS BLOB)),
                       files_summary_truncated,
                       CASE WHEN length(CAST(assistant_message_id AS BLOB)) <= 36 THEN assistant_message_id END,
                       COALESCE(length(CAST(assistant_message_id AS BLOB)), 0),
                       CASE WHEN length(CAST(list_error_message AS BLOB)) <= \(AgentTurnCheckpointListWireProjection.maxEncodedErrorMessageBytes) THEN list_error_message END,
                       COALESCE(length(CAST(list_error_message AS BLOB)), 0),
                       list_error_message_encoded_bytes,
                       CASE WHEN length(CAST(list_error_message_sha256 AS BLOB)) <= 64 THEN list_error_message_sha256 END,
                       COALESCE(length(CAST(list_error_message_sha256 AS BLOB)), 0),
                       list_error_message_truncated,
                       CASE WHEN length(CAST(list_completed_at AS BLOB)) <= 24 THEN list_completed_at END,
                       length(CAST(list_completed_at AS BLOB)),
                       list_metadata_unavailable
                FROM agent_turn_checkpoints
                """
            let sql: String
            if cursor == nil {
                sql = """
                \(selectList)
                WHERE thread_id = ?
                ORDER BY checkpoint_turn_count DESC, list_completed_at DESC, list_turn_id DESC
                LIMIT ?;
                """
            } else {
                sql = """
                \(selectList)
                WHERE thread_id = ?
                  AND (
                    checkpoint_turn_count < ?
                    OR (checkpoint_turn_count = ? AND list_completed_at < ?)
                    OR (checkpoint_turn_count = ? AND list_completed_at = ? AND list_turn_id < ?)
                  )
                ORDER BY checkpoint_turn_count DESC, list_completed_at DESC, list_turn_id DESC
                LIMIT ?;
                """
            }
            let st = try db.prepare(sql)
            try st.bind(1, threadId.value.uuidString)
            if let cursor {
                let completed = completedAtKeysetToken(for: cursor)
                try st.bind(2, Int64(cursor.checkpointTurnCount))
                try st.bind(3, Int64(cursor.checkpointTurnCount))
                try st.bind(4, completed)
                try st.bind(5, Int64(cursor.checkpointTurnCount))
                try st.bind(6, completed)
                try st.bind(7, cursor.turnId)
                try st.bind(8, Int64(limit + 1))
            } else {
                try st.bind(2, Int64(limit + 1))
            }
            var rows: [(
                summary: AgentTurnCheckpointSummary,
                filesTruncated: Bool,
                listMetadata: AgentTurnCheckpointListWireProjection.Capture,
                completedAtToken: String
            )] = []
            while try st.step() {
                rows.append(try decodeCheckpointMetadata(from: st, fallbackThreadId: threadId))
            }
            let truncated = rows.count > limit
            let pageRows = Array(rows.prefix(limit))
            let items = pageRows.map(\.summary)
            let nextBefore: AgentTurnCheckpointCursor? = {
                guard truncated, let last = pageRows.last else { return nil }
                return AgentTurnCheckpointCursor(
                    checkpointTurnCount: last.summary.checkpointTurnCount,
                    completedAt: last.summary.completedAt,
                    turnId: last.summary.turnId,
                    completedAtToken: last.completedAtToken
                )
            }()
            return AgentTurnCheckpointPage(
                items: items,
                filesTruncated: pageRows.map(\.filesTruncated),
                listMetadata: pageRows.map(\.listMetadata),
                completedAtTokens: pageRows.map(\.completedAtToken),
                truncated: truncated,
                nextBefore: nextBefore,
                catalogRevision: catalogRevision
            )
        }
    }

    /// Prefer the exact echoed/storage token; fall back to fractional format for
    /// older in-process callers that only supply a Date.
    private func completedAtKeysetToken(for cursor: AgentTurnCheckpointCursor) -> String {
        if !cursor.completedAtToken.isEmpty {
            return cursor.completedAtToken
        }
        return formatCompletedAt(cursor.completedAt)
    }

    /// Decode a metadata projection row. Heavy payload columns and raw
    /// turn_id/checkpoint_ref/error_message are never present; always emit empty
    /// snapshots/diffs so callers cannot accidentally ship them.
    private func decodeCheckpointMetadata(
        from st: SQLiteStatement,
        fallbackThreadId: AgentThreadID
    ) throws -> (
        summary: AgentTurnCheckpointSummary,
        filesTruncated: Bool,
        listMetadata: AgentTurnCheckpointListWireProjection.Capture,
        completedAtToken: String
    ) {
        try requireBoundedStorageField(
            st.columnText(0),
            storedBytes: st.columnInt64(1),
            maximumBytes: 36,
            field: "thread_id",
            nullable: false
        )
        try requireBoundedStorageField(
            st.columnText(2),
            storedBytes: st.columnInt64(3),
            maximumBytes: 36,
            field: "run_id",
            nullable: false
        )
        try requireBoundedStorageField(
            st.columnText(4),
            storedBytes: st.columnInt64(5),
            maximumBytes:
                AgentTurnCheckpointWireIdentity.maximumEncodedTurnIDBytes,
            field: "list_turn_id",
            nullable: false
        )
        try requireBoundedStorageField(
            st.columnText(7),
            storedBytes: st.columnInt64(8),
            maximumBytes: 64,
            field: "list_turn_id_sha256",
            nullable: true
        )
        try requireBoundedStorageField(
            st.columnText(11),
            storedBytes: st.columnInt64(12),
            maximumBytes:
                AgentTurnCheckpointListWireProjection.maxEncodedCheckpointRefBytes,
            field: "list_checkpoint_ref",
            nullable: false
        )
        try requireBoundedStorageField(
            st.columnText(14),
            storedBytes: st.columnInt64(15),
            maximumBytes: 64,
            field: "list_checkpoint_ref_sha256",
            nullable: true
        )
        try requireBoundedStorageField(
            st.columnText(17),
            storedBytes: st.columnInt64(18),
            maximumBytes: 16,
            field: "status",
            nullable: false
        )
        try requireBoundedStorageField(
            st.columnText(19),
            storedBytes: st.columnInt64(20),
            maximumBytes:
                AgentTurnCheckpointListWireProjection.maxEncodedFilesBytes,
            field: "files_summary_json",
            nullable: false
        )
        try requireBoundedStorageField(
            st.columnText(22),
            storedBytes: st.columnInt64(23),
            maximumBytes: 36,
            field: "assistant_message_id",
            nullable: true
        )
        try requireBoundedStorageField(
            st.columnText(24),
            storedBytes: st.columnInt64(25),
            maximumBytes:
                AgentTurnCheckpointListWireProjection.maxEncodedErrorMessageBytes,
            field: "list_error_message",
            nullable: true
        )
        try requireBoundedStorageField(
            st.columnText(27),
            storedBytes: st.columnInt64(28),
            maximumBytes: 64,
            field: "list_error_message_sha256",
            nullable: true
        )
        try requireBoundedStorageField(
            st.columnText(30),
            storedBytes: st.columnInt64(31),
            maximumBytes: 24,
            field: "list_completed_at",
            nullable: false
        )

        let filesJSON = st.columnText(19) ?? "[]"
        let files: [AgentTurnCheckpointFile]
        do {
            files = try decoder.decode([AgentTurnCheckpointFile].self, from: Data(filesJSON.utf8))
        } catch {
            throw PersistenceDataError.corruptCheckpoint(
                "invalid files_summary_json for turn \(st.columnText(4) ?? "<unknown>"): \(error)"
            )
        }
        guard files.count <= AgentTurnCheckpointListWireProjection.maxFiles,
              let encodedFiles = try? encoder.encode(files),
              encodedFiles.count
                <= AgentTurnCheckpointListWireProjection.maxEncodedFilesBytes else {
            throw PersistenceDataError.corruptCheckpoint(
                "invalid bounded files_summary_json projection"
            )
        }
        guard let storedThreadUUID = st.columnText(0).flatMap(UUID.init(uuidString:)),
              storedThreadUUID == fallbackThreadId.value else {
            throw PersistenceDataError.corruptCheckpoint(
                "invalid bounded checkpoint thread_id"
            )
        }
        guard let runUUID = st.columnText(2).flatMap(UUID.init(uuidString:)) else {
            throw PersistenceDataError.corruptCheckpoint(
                "invalid bounded checkpoint run_id"
            )
        }
        guard let status = st.columnText(17)
            .flatMap(AgentTurnCheckpointStatus.init(rawValue:)) else {
            throw PersistenceDataError.corruptCheckpoint(
                "invalid bounded checkpoint status"
            )
        }
        let completed = try parseListCompletedAt(st.columnText(30))
        let checkpointTurnCount = st.columnInt64(10)
        guard checkpointTurnCount >= 0,
              checkpointTurnCount <= 9_007_199_254_740_991 else {
            throw PersistenceDataError.corruptCheckpoint(
                "invalid bounded checkpoint_turn_count"
            )
        }
        let assistantMessageId: AgentMessageID?
        if let rawAssistantMessageID = st.columnText(22) {
            guard let uuid = UUID(uuidString: rawAssistantMessageID) else {
                throw PersistenceDataError.corruptCheckpoint(
                    "invalid bounded assistant_message_id"
                )
            }
            assistantMessageId = AgentMessageID(uuid)
        } else {
            assistantMessageId = nil
        }
        let listMetadata = AgentTurnCheckpointListWireProjection.Capture(
            turnId: .init(
                value: st.columnText(4),
                totalEncodedBytes: try boundedListTotal(
                    st.columnInt64(6),
                    field: "list_turn_id_encoded_bytes"
                ),
                sha256: st.columnText(7),
                truncated: try boundedListFlag(
                    st.columnInt64(9),
                    field: "list_turn_id_truncated"
                )
            ),
            checkpointRef: .init(
                value: st.columnText(11),
                totalEncodedBytes: try boundedListTotal(
                    st.columnInt64(13),
                    field: "list_checkpoint_ref_encoded_bytes"
                ),
                sha256: st.columnText(14),
                truncated: try boundedListFlag(
                    st.columnInt64(16),
                    field: "list_checkpoint_ref_truncated"
                )
            ),
            errorMessage: .init(
                value: st.columnText(24),
                totalEncodedBytes: try boundedListTotal(
                    st.columnInt64(26),
                    field: "list_error_message_encoded_bytes"
                ),
                sha256: st.columnText(27),
                truncated: try boundedListFlag(
                    st.columnInt64(29),
                    field: "list_error_message_truncated"
                )
            ),
            metadataUnavailable: try boundedListFlag(
                st.columnInt64(32),
                field: "list_metadata_unavailable"
            )
        )
        try validateListMetadataProjection(listMetadata)
        guard let turnID = listMetadata.turnId.value,
              !turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersistenceDataError.corruptCheckpoint(
                "invalid empty bounded list_turn_id"
            )
        }
        let summary = AgentTurnCheckpointSummary(
            threadId: AgentThreadID(storedThreadUUID),
            runId: AgentRunID(runUUID),
            turnId: turnID,
            checkpointTurnCount: Int(checkpointTurnCount),
            checkpointRef: listMetadata.checkpointRef.value ?? "",
            status: status,
            files: files,
            fileSnapshots: [],
            diffPatch: nil,
            fileDiffs: [],
            assistantMessageId: assistantMessageId,
            errorMessage: listMetadata.errorMessage.value,
            completedAt: completed.date
        )
        return (
            summary,
            try boundedListFlag(
                st.columnInt64(21),
                field: "files_summary_truncated"
            ),
            listMetadata,
            completed.token
        )
    }

    private func requireBoundedStorageField(
        _ value: String?,
        storedBytes: Int64,
        maximumBytes: Int,
        field: String,
        nullable: Bool
    ) throws {
        guard storedBytes >= 0,
              storedBytes <= Int64(maximumBytes),
              value?.utf8.count == Int(storedBytes)
                || (nullable && value == nil && storedBytes == 0) else {
            throw PersistenceDataError.corruptCheckpoint(
                "oversized or invalid bounded \(field)"
            )
        }
    }

    private func boundedListFlag(_ raw: Int64, field: String) throws -> Bool {
        guard raw == 0 || raw == 1 else {
            throw PersistenceDataError.corruptCheckpoint(
                "invalid bounded \(field)"
            )
        }
        return raw == 1
    }

    private func boundedListTotal(_ raw: Int64, field: String) throws -> Int {
        guard raw >= 0, raw <= 9_007_199_254_740_991 else {
            throw PersistenceDataError.corruptCheckpoint(
                "invalid bounded \(field)"
            )
        }
        return Int(raw)
    }

    private func validateListMetadataProjection(
        _ capture: AgentTurnCheckpointListWireProjection.Capture
    ) throws {
        if capture.metadataUnavailable {
            let prefix = "rc2-legacy-row:"
            let turnID = capture.turnId.value ?? ""
            let suffix = turnID.dropFirst(prefix.count)
            guard turnID.hasPrefix(prefix),
                  suffix.utf8.count == 32,
                  suffix.utf8.allSatisfy({
                      (0x30...0x39).contains($0)
                        || (0x61...0x66).contains($0)
                  }),
                  capture.turnId.truncated,
                  capture.turnId.totalEncodedBytes == 0,
                  capture.turnId.sha256 == nil,
                  capture.checkpointRef.value == "",
                  capture.checkpointRef.truncated,
                  capture.checkpointRef.totalEncodedBytes == 0,
                  capture.checkpointRef.sha256 == nil,
                  capture.errorMessage.value == nil,
                  capture.errorMessage.truncated,
                  capture.errorMessage.totalEncodedBytes == 0,
                  capture.errorMessage.sha256 == nil else {
                throw PersistenceDataError.corruptCheckpoint(
                    "invalid unavailable bounded metadata sentinel"
                )
            }
            return
        }
        try validateListProjectionField(
            capture.turnId,
            maximumEncodedBytes:
                AgentTurnCheckpointWireIdentity.maximumEncodedTurnIDBytes,
            digestIdentity: true,
            field: "list_turn_id"
        )
        try validateListProjectionField(
            capture.checkpointRef,
            maximumEncodedBytes:
                AgentTurnCheckpointListWireProjection.maxEncodedCheckpointRefBytes,
            digestIdentity: false,
            field: "list_checkpoint_ref"
        )
        try validateListProjectionField(
            capture.errorMessage,
            maximumEncodedBytes:
                AgentTurnCheckpointListWireProjection.maxEncodedErrorMessageBytes,
            digestIdentity: false,
            field: "list_error_message"
        )
    }

    private func validateListProjectionField(
        _ projection: AgentTurnCheckpointListWireProjection.Field,
        maximumEncodedBytes: Int,
        digestIdentity: Bool,
        field: String
    ) throws {
        guard let value = projection.value else {
            guard !projection.truncated,
                  projection.totalEncodedBytes == 0,
                  projection.sha256 == nil else {
                throw PersistenceDataError.corruptCheckpoint(
                    "invalid bounded \(field) null projection"
                )
            }
            return
        }
        let projectedBytes =
            AgentTurnCheckpointWireIdentity.encodedJSONStringByteCount(value)
        guard projectedBytes <= maximumEncodedBytes else {
            throw PersistenceDataError.corruptCheckpoint(
                "oversized encoded bounded \(field)"
            )
        }
        if !projection.truncated {
            guard projection.totalEncodedBytes == projectedBytes,
                  projection.sha256 == nil else {
                throw PersistenceDataError.corruptCheckpoint(
                    "inconsistent bounded \(field) projection"
                )
            }
            return
        }
        guard projection.totalEncodedBytes > maximumEncodedBytes,
              let hash = projection.sha256,
              hash.utf8.count == 64,
              hash.utf8.allSatisfy({
                  (0x30...0x39).contains($0)
                    || (0x61...0x66).contains($0)
              }),
              !digestIdentity
                || value == "sha256:\(hash):\(projection.totalEncodedBytes)" else {
            throw PersistenceDataError.corruptCheckpoint(
                "invalid truncated bounded \(field) projection"
            )
        }
    }

    private func decodeCheckpoint(from st: SQLiteStatement, fallbackThreadId: AgentThreadID) throws -> AgentTurnCheckpointSummary {
        let filesJSON = st.columnText(6) ?? "[]"
        let files: [AgentTurnCheckpointFile]
        do {
            files = try decoder.decode([AgentTurnCheckpointFile].self, from: Data(filesJSON.utf8))
        } catch {
            throw PersistenceDataError.corruptCheckpoint("invalid files_json for turn \(st.columnText(2) ?? "<unknown>"): \(error)")
        }
        let snapshotsJSON = st.columnText(10) ?? "[]"
        let snapshots: [AgentTurnCheckpointFileSnapshot]
        do {
            snapshots = try decoder.decode([AgentTurnCheckpointFileSnapshot].self, from: Data(snapshotsJSON.utf8))
        } catch {
            throw PersistenceDataError.corruptCheckpoint("invalid file_snapshots_json for turn \(st.columnText(2) ?? "<unknown>"): \(error)")
        }
        let fileDiffsJSON = st.columnText(12) ?? "[]"
        let fileDiffs: [AgentTurnCheckpointFileDiff]
        do {
            fileDiffs = try decoder.decode([AgentTurnCheckpointFileDiff].self, from: Data(fileDiffsJSON.utf8))
        } catch {
            throw PersistenceDataError.corruptCheckpoint("invalid file_diffs_json for turn \(st.columnText(2) ?? "<unknown>"): \(error)")
        }
        return AgentTurnCheckpointSummary(
            threadId: AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? fallbackThreadId.value),
            runId: AgentRunID(UUID(uuidString: st.columnText(1) ?? "") ?? UUID()),
            turnId: st.columnText(2) ?? "",
            checkpointTurnCount: Int(st.columnInt64(3)),
            checkpointRef: st.columnText(4) ?? "",
            status: AgentTurnCheckpointStatus(rawValue: st.columnText(5) ?? "") ?? .error,
            files: files,
            fileSnapshots: snapshots,
            diffPatch: st.columnText(11),
            fileDiffs: fileDiffs,
            assistantMessageId: st.columnText(7).flatMap(UUID.init(uuidString:)).map(AgentMessageID.init),
            errorMessage: st.columnText(8),
            completedAt: parseDate(st.columnText(9))
        )
    }
}

public final class ProviderSessionRuntimeRepository {
    let db: SQLiteDB
    /// lastEventKind/lastErrorMessage last written or loaded on this instance.
    /// persistStreamBatch calls updateDiagnostics every flush with the same
    /// `itemDelta(id)`; skip the SELECT of runtime_payload_json when we already
    /// know both diagnostic fields match.
    private var diagnosticsByThread: [String: (kind: String?, error: String?)] = [:]
#if DEBUG
    private(set) var diagnosticsLoadCountForTesting = 0
#endif
    public init(db: SQLiteDB) { self.db = db }

    private func rememberDiagnostics(threadId: AgentThreadID, kind: String?, error: String?) {
        let key = threadId.value.uuidString
        if diagnosticsByThread.count >= 128, diagnosticsByThread[key] == nil {
            diagnosticsByThread.removeAll(keepingCapacity: true)
        }
        diagnosticsByThread[key] = (kind, error)
    }

    public func upsert(_ session: ProviderSessionRuntime) throws {
        let st = try db.prepare("""
            INSERT INTO provider_session_runtime(thread_id, provider, provider_instance_id, adapter_key, binary_identity, status, resume_cursor, runtime_payload_json, updated_at, cwd, model, service_tier, runtime_mode, last_run_id, last_event_kind, last_error_message)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET
                provider=excluded.provider,
                provider_instance_id=excluded.provider_instance_id,
                adapter_key=excluded.adapter_key,
                binary_identity=excluded.binary_identity,
                status=excluded.status,
                resume_cursor=excluded.resume_cursor,
                runtime_payload_json=excluded.runtime_payload_json,
                updated_at=excluded.updated_at,
                cwd=excluded.cwd,
                model=excluded.model,
                service_tier=excluded.service_tier,
                runtime_mode=excluded.runtime_mode,
                last_run_id=excluded.last_run_id,
                last_event_kind=excluded.last_event_kind,
                last_error_message=excluded.last_error_message;
        """)
        try st.bind(1, session.threadId.value.uuidString)
        try st.bind(2, session.provider.rawValue)
        try st.bind(3, session.providerInstanceId)
        try st.bind(4, session.adapterKey)
        try st.bind(5, session.binaryIdentity)
        try st.bind(6, session.status.rawValue)
        try st.bind(7, session.resumeCursor)
        try st.bind(8, session.runtimePayloadJSON)
        try st.bind(9, iso.string(from: session.updatedAt))
        try st.bind(10, session.cwd)
        try st.bind(11, session.model)
        try st.bind(12, session.serviceTier.rawValue)
        try st.bind(13, session.runtimeMode.rawValue)
        try st.bind(14, session.lastRunId?.value.uuidString)
        try st.bind(15, session.lastEventKind)
        try st.bind(16, session.lastErrorMessage)
        _ = try st.step()
        rememberDiagnostics(
            threadId: session.threadId,
            kind: session.lastEventKind,
            error: session.lastErrorMessage
        )
    }

    public func get(threadId: AgentThreadID) throws -> ProviderSessionRuntime? {
        let st = try db.prepare("""
            SELECT thread_id, provider, provider_instance_id, adapter_key, binary_identity, status, resume_cursor, runtime_payload_json, updated_at, cwd, model, service_tier, runtime_mode, last_run_id, last_event_kind, last_error_message
            FROM provider_session_runtime
            WHERE thread_id = ?;
        """)
        try st.bind(1, threadId.value.uuidString)
        guard try st.step() else { return nil }
        return ProviderSessionRuntime(
            threadId: AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? threadId.value),
            provider: AgentProvider(rawValue: st.columnText(1) ?? "") ?? .codex,
            providerInstanceId: st.columnText(2),
            adapterKey: st.columnText(3),
            binaryIdentity: st.columnText(4),
            status: AgentRunStatus(rawValue: st.columnText(5) ?? "") ?? .pending,
            resumeCursor: st.columnText(6),
            cwd: st.columnText(9),
            model: st.columnText(10),
            serviceTier: AgentServiceTier(rawValue: st.columnText(11) ?? "") ?? .auto,
            runtimeMode: AgentPermissionMode(rawValue: st.columnText(12) ?? "") ?? .supervised,
            lastRunId: st.columnText(13).flatMap(UUID.init(uuidString:)).map(AgentRunID.init),
            lastEventKind: st.columnText(14),
            lastErrorMessage: st.columnText(15),
            runtimePayloadJSON: st.columnText(7),
            updatedAt: parseDate(st.columnText(8))
        )
    }

    public func list(status: AgentRunStatus, updatedBefore cutoff: Date) throws -> [ProviderSessionRuntime] {
        let st = try db.prepare("""
            SELECT thread_id, provider, provider_instance_id, adapter_key, binary_identity, status, resume_cursor, runtime_payload_json, updated_at, cwd, model, service_tier, runtime_mode, last_run_id, last_event_kind, last_error_message
            FROM provider_session_runtime
            WHERE status = ? AND updated_at < ?
            ORDER BY updated_at ASC;
        """)
        try st.bind(1, status.rawValue)
        try st.bind(2, iso.string(from: cutoff))
        var sessions: [ProviderSessionRuntime] = []
        while try st.step() {
            sessions.append(ProviderSessionRuntime(
                threadId: AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID()),
                provider: AgentProvider(rawValue: st.columnText(1) ?? "") ?? .codex,
                providerInstanceId: st.columnText(2),
                adapterKey: st.columnText(3),
                binaryIdentity: st.columnText(4),
                status: AgentRunStatus(rawValue: st.columnText(5) ?? "") ?? .pending,
                resumeCursor: st.columnText(6),
                cwd: st.columnText(9),
                model: st.columnText(10),
                serviceTier: AgentServiceTier(rawValue: st.columnText(11) ?? "") ?? .auto,
                runtimeMode: AgentPermissionMode(rawValue: st.columnText(12) ?? "") ?? .supervised,
                lastRunId: st.columnText(13).flatMap(UUID.init(uuidString:)).map(AgentRunID.init),
                lastEventKind: st.columnText(14),
                lastErrorMessage: st.columnText(15),
                runtimePayloadJSON: st.columnText(7),
                updatedAt: parseDate(st.columnText(8))
            ))
        }
        return sessions
    }

    public func markStopped(
        threadId: AgentThreadID,
        status: AgentRunStatus = .cancelled,
        at date: Date = Date()
    ) throws {
        guard var session = try get(threadId: threadId) else { return }
        session.status = status
        session.updatedAt = date
        try upsert(session)
    }

    public func updateDiagnostics(threadId: AgentThreadID, lastEventKind: String?, lastErrorMessage: String?, at date: Date = Date()) throws {
        let key = threadId.value.uuidString
        if let cached = diagnosticsByThread[key] {
            let nextKind = lastEventKind ?? cached.kind
            let nextError = lastErrorMessage ?? cached.error
            if cached.kind == nextKind, cached.error == nextError {
                return
            }
        }
#if DEBUG
        diagnosticsLoadCountForTesting += 1
#endif
        guard var session = try get(threadId: threadId) else { return }
        rememberDiagnostics(
            threadId: threadId,
            kind: session.lastEventKind,
            error: session.lastErrorMessage
        )
        let nextKind = lastEventKind ?? session.lastEventKind
        let nextError = lastErrorMessage ?? session.lastErrorMessage
        // Stream flushes (~16 events / 250 ms) call this with the last
        // buffered kind. Token deltas on one item keep `itemDelta(id)`
        // unchanged, but the previous path still SELECT+UPSERT-ed the whole
        // row (including runtime_payload_json) just to bump updatedAt.
        // After an upsert/get on this instance, skip the SELECT too.
        guard session.lastEventKind != nextKind || session.lastErrorMessage != nextError else {
            return
        }
        session.lastEventKind = nextKind
        session.lastErrorMessage = nextError
        session.updatedAt = date
        try upsert(session)
    }
}

public enum CommandReceiptClaimResult: Sendable, Equatable {
    case claimed
    case inProgress
    case committed(resultJSON: String)
    case unknown
    case ownerMismatch
    case requestMismatch
    case legacyUnverifiable
}

public enum CommandReceiptStatusResult: Sendable, Equatable {
    case absent
    case inProgress
    case committed
    case unknown
    case ownerMismatch
    case legacyUnverifiable
}

public struct CommandReceiptEventIntent: Sendable, Equatable {
    public let kind: String
    public let payloadJSON: String
    public let createdAt: Date

    public init(kind: String, payloadJSON: String, createdAt: Date) {
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

public struct PersistedCommandReceiptEvent: Sendable, Equatable {
    public let seq: Int64
    public let ordinal: Int
    public let kind: String
    public let payloadJSON: String
    public let createdAt: Date
}

public final class CommandReceiptRepository {
    let db: SQLiteDB
    private let eventRetentionCap: Int
    public init(db: SQLiteDB, eventRetentionCap: Int = 5_000) {
        self.db = db
        self.eventRetentionCap = max(0, eventRetentionCap)
    }

    /// A process that exits after the durable claim but before finalization
    /// leaves an unprovable outcome. Recovery is permanent and runs before
    /// command admission during bootstrap; claims are never leased or replayed.
    public func recoverInterruptedClaims() throws {
        try db.performSync { db in
            let update = try db.prepare("""
                UPDATE command_receipts
                SET state = 'unknown', result_json = '', updated_at = ?
                WHERE state = 'claimed';
            """)
            try update.bind(1, iso.string(from: Date()))
            _ = try update.step()
        }
    }

    public func get(method: String, clientRequestId: String) throws -> String? {
        let st = try db.prepare("""
            SELECT result_json
            FROM command_receipts
            WHERE method = ? AND client_request_id = ?;
        """)
        try st.bind(1, method)
        try st.bind(2, clientRequestId)
        guard try st.step() else { return nil }
        return st.columnText(0)
    }

    public func record(method: String, clientRequestId: String, resultJSON: String) throws {
        let st = try db.prepare("""
            INSERT OR IGNORE INTO command_receipts(method, client_request_id, result_json, created_at)
            VALUES(?, ?, ?, ?);
        """)
        try st.bind(1, method)
        try st.bind(2, clientRequestId)
        try st.bind(3, resultJSON)
        try st.bind(4, iso.string(from: Date()))
        _ = try st.step()
    }

    public func claim(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws -> CommandReceiptClaimResult {
        try db.performSync { db in
            try db.transaction {
                if let existing = try receipt(
                    db: db,
                    method: method,
                    clientRequestId: clientRequestId
                ) {
                    guard let existingOwner = existing.ownerFingerprint,
                          let existingHash = existing.paramsHash,
                          let state = existing.state else {
                        return .legacyUnverifiable
                    }
                    guard existingOwner == ownerFingerprint else { return .ownerMismatch }
                    guard existingHash == paramsHash else { return .requestMismatch }
                    switch state {
                    case "claimed": return .inProgress
                    case "committed": return .committed(resultJSON: existing.resultJSON)
                    case "unknown": return .unknown
                    default: return .legacyUnverifiable
                    }
                }

                let now = iso.string(from: Date())
                let insert = try db.prepare("""
                    INSERT INTO command_receipts(
                        method, client_request_id, result_json, created_at,
                        owner_fingerprint, params_hash, state, updated_at
                    ) VALUES(?, ?, '', ?, ?, ?, 'claimed', ?);
                """)
                try insert.bind(1, method)
                try insert.bind(2, clientRequestId)
                try insert.bind(3, now)
                try insert.bind(4, ownerFingerprint)
                try insert.bind(5, paramsHash)
                try insert.bind(6, now)
                _ = try insert.step()
                return .claimed
            }
        }
    }

    public func commit(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        resultJSON: String
    ) throws {
        _ = try finalize(
            method: method,
            clientRequestId: clientRequestId,
            ownerFingerprint: ownerFingerprint,
            paramsHash: paramsHash,
            resultJSON: resultJSON,
            events: []
        )
    }

    /// Atomically persists the exact command outcome, its ordered event outbox,
    /// the allocated durable sequence range, and the claimed -> committed
    /// transition. A failed transaction is reread; an unchanged claim retries
    /// finalization once with the captured outcome/events and never reruns the
    /// domain effect.
    public func finalize(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        resultJSON: String,
        events: [CommandReceiptEventIntent],
        minimumEventSequence: Int64 = 0
    ) throws -> [PersistedCommandReceiptEvent] {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                return try finalizeOnce(
                    method: method,
                    clientRequestId: clientRequestId,
                    ownerFingerprint: ownerFingerprint,
                    paramsHash: paramsHash,
                    resultJSON: resultJSON,
                    events: events,
                    minimumEventSequence: minimumEventSequence
                )
            } catch {
                lastError = error
                switch try claim(
                    method: method,
                    clientRequestId: clientRequestId,
                    ownerFingerprint: ownerFingerprint,
                    paramsHash: paramsHash
                ) {
                case .committed:
                    return try persistedEvents(method: method, clientRequestId: clientRequestId)
                case .inProgress where attempt == 0:
                    continue
                default:
                    throw error
                }
            }
        }
        throw lastError ?? SQLiteError.execute("Command receipt finalization failed.")
    }

    public func markUnknown(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws {
        try transition(
            method: method,
            clientRequestId: clientRequestId,
            ownerFingerprint: ownerFingerprint,
            paramsHash: paramsHash,
            state: "unknown",
            resultJSON: ""
        )
    }

    public func status(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String
    ) throws -> CommandReceiptStatusResult {
        try db.performSync { db in
            guard let existing = try receipt(
                db: db,
                method: method,
                clientRequestId: clientRequestId
            ) else { return .absent }
            guard let existingOwner = existing.ownerFingerprint,
                  let state = existing.state else {
                return .legacyUnverifiable
            }
            guard existingOwner == ownerFingerprint else { return .ownerMismatch }
            switch state {
            case "claimed": return .inProgress
            case "committed": return .committed
            case "unknown": return .unknown
            default: return .legacyUnverifiable
            }
        }
    }

    private func transition(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        state: String,
        resultJSON: String
    ) throws {
        try db.performSync { db in
            try db.transaction {
                guard let existing = try receipt(
                    db: db,
                    method: method,
                    clientRequestId: clientRequestId
                ), existing.ownerFingerprint == ownerFingerprint,
                   existing.paramsHash == paramsHash,
                   existing.state == "claimed" else {
                    throw SQLiteError.execute("Command receipt transition lost its immutable claim.")
                }
                let update = try db.prepare("""
                    UPDATE command_receipts
                    SET state = ?, result_json = ?, updated_at = ?
                    WHERE method = ? AND client_request_id = ? AND state = 'claimed';
                """)
                try update.bind(1, state)
                try update.bind(2, resultJSON)
                try update.bind(3, iso.string(from: Date()))
                try update.bind(4, method)
                try update.bind(5, clientRequestId)
                _ = try update.step()
            }
        }
    }

    private func finalizeOnce(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        resultJSON: String,
        events: [CommandReceiptEventIntent],
        minimumEventSequence: Int64
    ) throws -> [PersistedCommandReceiptEvent] {
        try db.performSync { db in
            try db.transaction {
                guard let existing = try receipt(
                    db: db,
                    method: method,
                    clientRequestId: clientRequestId
                ), existing.ownerFingerprint == ownerFingerprint,
                   existing.paramsHash == paramsHash,
                   existing.state == "claimed" else {
                    throw SQLiteError.execute("Command receipt finalization lost its immutable claim.")
                }

                let sequence = try db.prepare(
                    "SELECT last_seq FROM event_sequence WHERE singleton = 1;"
                )
                guard try sequence.step() else {
                    throw SQLiteError.execute("Durable event sequence is unavailable.")
                }
                let previousSequence = max(sequence.columnInt64(0), minimumEventSequence)
                var persisted: [PersistedCommandReceiptEvent] = []
                persisted.reserveCapacity(events.count)

                for (ordinal, event) in events.enumerated() {
                    let eventSequence = previousSequence + Int64(ordinal) + 1
                    let createdAt = iso.string(from: event.createdAt)
                    let insertEvent = try db.prepare("""
                        INSERT INTO events(
                            seq, kind, request_id, origin_client_id, payload_json, created_at
                        ) VALUES(?, ?, ?, ?, ?, ?);
                    """)
                    try insertEvent.bind(1, eventSequence)
                    try insertEvent.bind(2, event.kind)
                    try insertEvent.bind(3, clientRequestId)
                    try insertEvent.bind(4, ownerFingerprint)
                    try insertEvent.bind(5, event.payloadJSON)
                    try insertEvent.bind(6, createdAt)
                    _ = try insertEvent.step()

                    let link = try db.prepare("""
                        INSERT INTO command_receipt_events(
                            method, client_request_id, ordinal, seq
                        ) VALUES(?, ?, ?, ?);
                    """)
                    try link.bind(1, method)
                    try link.bind(2, clientRequestId)
                    try link.bind(3, ordinal)
                    try link.bind(4, eventSequence)
                    _ = try link.step()
                    persisted.append(PersistedCommandReceiptEvent(
                        seq: eventSequence,
                        ordinal: ordinal,
                        kind: event.kind,
                        payloadJSON: event.payloadJSON,
                        createdAt: event.createdAt
                    ))
                }

                let finalSequence = previousSequence + Int64(events.count)
                let updateSequence = try db.prepare("""
                    UPDATE event_sequence SET last_seq = ? WHERE singleton = 1;
                """)
                try updateSequence.bind(1, finalSequence)
                _ = try updateSequence.step()

                let updateReceipt = try db.prepare("""
                    UPDATE command_receipts
                    SET state = 'committed', result_json = ?, updated_at = ?,
                        event_start_seq = ?, event_end_seq = ?
                    WHERE method = ? AND client_request_id = ? AND state = 'claimed';
                """)
                try updateReceipt.bind(1, resultJSON)
                try updateReceipt.bind(2, iso.string(from: Date()))
                try updateReceipt.bind(3, persisted.first?.seq)
                try updateReceipt.bind(4, persisted.last?.seq)
                try updateReceipt.bind(5, method)
                try updateReceipt.bind(6, clientRequestId)
                _ = try updateReceipt.step()
                if !persisted.isEmpty {
                    // The just-finalized events are newest and therefore remain
                    // available to `persistedEvents` for ambiguous-commit reread.
                    // Only old replay payloads and their now-useless links prune.
                    try EventRetentionPolicy.prune(db: db, cap: eventRetentionCap)
                }
                return persisted
            }
        }
    }

    private func persistedEvents(
        method: String,
        clientRequestId: String
    ) throws -> [PersistedCommandReceiptEvent] {
        try db.performSync { db in
            let statement = try db.prepare("""
                SELECT e.seq, cre.ordinal, e.kind, e.payload_json, e.created_at
                FROM command_receipt_events cre
                JOIN events e ON e.seq = cre.seq
                WHERE cre.method = ? AND cre.client_request_id = ?
                ORDER BY cre.ordinal ASC;
            """)
            try statement.bind(1, method)
            try statement.bind(2, clientRequestId)
            var events: [PersistedCommandReceiptEvent] = []
            while try statement.step() {
                events.append(PersistedCommandReceiptEvent(
                    seq: statement.columnInt64(0),
                    ordinal: Int(statement.columnInt64(1)),
                    kind: statement.columnText(2) ?? "",
                    payloadJSON: statement.columnText(3) ?? "null",
                    createdAt: parseDate(statement.columnText(4))
                ))
            }
            return events
        }
    }

    private struct StoredReceipt {
        let resultJSON: String
        let ownerFingerprint: String?
        let paramsHash: String?
        let state: String?
    }

    private func receipt(
        db: SQLiteDB,
        method: String,
        clientRequestId: String
    ) throws -> StoredReceipt? {
        let statement = try db.prepare("""
            SELECT result_json, owner_fingerprint, params_hash, state
            FROM command_receipts
            WHERE method = ? AND client_request_id = ?;
        """)
        try statement.bind(1, method)
        try statement.bind(2, clientRequestId)
        guard try statement.step() else { return nil }
        return StoredReceipt(
            resultJSON: statement.columnText(0) ?? "",
            ownerFingerprint: statement.columnText(1),
            paramsHash: statement.columnText(2),
            state: statement.columnText(3)
        )
    }
}

public enum ProviderPendingCallbackKind: String, Codable, Sendable, Equatable {
    case approval
    case userInput
}

public struct ProviderPendingCallback: Codable, Sendable, Equatable {
    public let threadId: AgentThreadID
    public let requestId: String
    public let kind: ProviderPendingCallbackKind
    public var state: AssistantRequestState
    public var payloadJSON: String
    public var createdAt: Date
    public var resolvedAt: Date?
    public var staleReason: String?

    public init(
        threadId: AgentThreadID,
        requestId: String,
        kind: ProviderPendingCallbackKind,
        state: AssistantRequestState = .pending,
        payloadJSON: String,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil,
        staleReason: String? = nil
    ) {
        self.threadId = threadId
        self.requestId = requestId
        self.kind = kind
        self.state = state
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.staleReason = staleReason
    }
}

public final class ProviderPendingCallbackRepository {
    let db: SQLiteDB
    private let encoder = JSONEncoder()
    public init(db: SQLiteDB) { self.db = db }

    public func record(threadId: AgentThreadID, request: AssistantPendingRequest) throws {
        let data = try encoder.encode(request)
        try upsert(ProviderPendingCallback(
            threadId: threadId,
            requestId: request.id,
            kind: .approval,
            state: request.state,
            payloadJSON: String(decoding: data, as: UTF8.self),
            createdAt: Date(timeIntervalSince1970: Double(request.createdAtMs) / 1000.0)
        ))
    }

    public func record(threadId: AgentThreadID, userInput: AssistantUserInputRequest) throws {
        let data = try encoder.encode(userInput)
        try upsert(ProviderPendingCallback(
            threadId: threadId,
            requestId: userInput.id,
            kind: .userInput,
            state: userInput.state,
            payloadJSON: String(decoding: data, as: UTF8.self),
            createdAt: Date(timeIntervalSince1970: Double(userInput.createdAtMs) / 1000.0)
        ))
    }

    public func resolve(threadId: AgentThreadID, requestId: String, kind: ProviderPendingCallbackKind, state: AssistantRequestState, at date: Date = Date()) throws {
        let st = try db.prepare("""
            UPDATE provider_pending_callbacks
            SET state = ?, resolved_at = ?, stale_reason = NULL
            WHERE thread_id = ? AND request_id = ? AND callback_kind = ?;
        """)
        try st.bind(1, state.rawValue)
        try st.bind(2, iso.string(from: date))
        try st.bind(3, threadId.value.uuidString)
        try st.bind(4, requestId)
        try st.bind(5, kind.rawValue)
        _ = try st.step()
    }

    public func markStale(threadId: AgentThreadID, requestId: String, kind: ProviderPendingCallbackKind, reason: String, at date: Date = Date()) throws {
        let st = try db.prepare("""
            UPDATE provider_pending_callbacks
            SET state = ?, resolved_at = ?, stale_reason = ?
            WHERE thread_id = ? AND request_id = ? AND callback_kind = ?;
        """)
        try st.bind(1, AssistantRequestState.stale.rawValue)
        try st.bind(2, iso.string(from: date))
        try st.bind(3, reason)
        try st.bind(4, threadId.value.uuidString)
        try st.bind(5, requestId)
        try st.bind(6, kind.rawValue)
        _ = try st.step()
    }

    public func markOpenStale(reason: String, at date: Date = Date()) throws -> Int {
        let open = try listOpen()
        let st = try db.prepare("""
            UPDATE provider_pending_callbacks
            SET state = ?, resolved_at = ?, stale_reason = ?
            WHERE state = ?;
        """)
        try st.bind(1, AssistantRequestState.stale.rawValue)
        try st.bind(2, iso.string(from: date))
        try st.bind(3, reason)
        try st.bind(4, AssistantRequestState.pending.rawValue)
        _ = try st.step()
        return open.count
    }

    public func get(threadId: AgentThreadID, requestId: String, kind: ProviderPendingCallbackKind) throws -> ProviderPendingCallback? {
        let st = try db.prepare("""
            SELECT thread_id, request_id, callback_kind, state, payload_json, created_at, resolved_at, stale_reason
            FROM provider_pending_callbacks
            WHERE thread_id = ? AND request_id = ? AND callback_kind = ?;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, requestId)
        try st.bind(3, kind.rawValue)
        guard try st.step() else { return nil }
        return row(st)
    }

    public func listOpen(threadId: AgentThreadID? = nil) throws -> [ProviderPendingCallback] {
        try list(states: [.pending], threadId: threadId)
    }

    public func listVisible(threadId: AgentThreadID) throws -> [ProviderPendingCallback] {
        try list(states: [.pending, .stale], threadId: threadId)
    }

    public func list(states: [AssistantRequestState], threadId: AgentThreadID? = nil) throws -> [ProviderPendingCallback] {
        let sql: String
        if threadId == nil {
            sql = """
                SELECT thread_id, request_id, callback_kind, state, payload_json, created_at, resolved_at, stale_reason
                FROM provider_pending_callbacks
                WHERE state IN (\(states.map { _ in "?" }.joined(separator: ",")))
                ORDER BY created_at ASC;
            """
        } else {
            sql = """
                SELECT thread_id, request_id, callback_kind, state, payload_json, created_at, resolved_at, stale_reason
                FROM provider_pending_callbacks
                WHERE state IN (\(states.map { _ in "?" }.joined(separator: ","))) AND thread_id = ?
                ORDER BY created_at ASC;
            """
        }
        let st = try db.prepare(sql)
        for (offset, state) in states.enumerated() {
            try st.bind(Int32(offset + 1), state.rawValue)
        }
        if let threadId { try st.bind(Int32(states.count + 1), threadId.value.uuidString) }
        var out: [ProviderPendingCallback] = []
        while try st.step() { out.append(row(st)) }
        return out
    }

    private func upsert(_ callback: ProviderPendingCallback) throws {
        let st = try db.prepare("""
            INSERT INTO provider_pending_callbacks(thread_id, request_id, callback_kind, state, payload_json, created_at, resolved_at, stale_reason)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id, request_id, callback_kind) DO UPDATE SET
                state=excluded.state,
                payload_json=excluded.payload_json,
                created_at=excluded.created_at,
                resolved_at=excluded.resolved_at,
                stale_reason=excluded.stale_reason;
        """)
        try st.bind(1, callback.threadId.value.uuidString)
        try st.bind(2, callback.requestId)
        try st.bind(3, callback.kind.rawValue)
        try st.bind(4, callback.state.rawValue)
        try st.bind(5, callback.payloadJSON)
        try st.bind(6, iso.string(from: callback.createdAt))
        try st.bind(7, callback.resolvedAt.map(iso.string))
        try st.bind(8, callback.staleReason)
        _ = try st.step()
    }

    private func row(_ st: SQLiteStatement) -> ProviderPendingCallback {
        ProviderPendingCallback(
            threadId: AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID()),
            requestId: st.columnText(1) ?? "",
            kind: ProviderPendingCallbackKind(rawValue: st.columnText(2) ?? "") ?? .approval,
            state: AssistantRequestState(rawValue: st.columnText(3) ?? "") ?? .pending,
            payloadJSON: st.columnText(4) ?? "{}",
            createdAt: parseDate(st.columnText(5)),
            resolvedAt: st.columnText(6).flatMap(parseDate),
            staleReason: st.columnText(7)
        )
    }
}

public enum ProviderSessionRecoveryState: Equatable {
    case active(ProviderSessionRuntime)
    case recoverable(ProviderSessionRuntime)
    case stopped(ProviderSessionRuntime)
    case unrecoverable(String)
}

public extension ProviderSessionRuntimeRepository {
    func recoveryState(threadId: AgentThreadID) throws -> ProviderSessionRecoveryState {
        guard let session = try get(threadId: threadId) else {
            return .unrecoverable("No provider session runtime row for thread.")
        }
        switch session.status {
        case .running:
            return .active(session)
        case .completed:
            if session.resumeCursor?.isEmpty == false {
                return .recoverable(session)
            }
            return .unrecoverable("Provider session has no resume cursor.")
        case .cancelled:
            return .stopped(session)
        case .interrupted:
            if session.resumeCursor?.isEmpty == false {
                return .recoverable(session)
            }
            return .stopped(session)
        case .failed:
            return .unrecoverable("Provider session failed.")
        case .pending:
            return .unrecoverable("Provider session has not started.")
        }
    }
}

public struct TerminalOutputChunk: Equatable {
    public let id: Int64
    public let surfaceID: String
    public let workspaceID: String?
    public let chunkIndex: Int64
    public let data: Data
    public let createdAt: Date

    public init(id: Int64, surfaceID: String, workspaceID: String?, chunkIndex: Int64, data: Data, createdAt: Date) {
        self.id = id
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.chunkIndex = chunkIndex
        self.data = data
        self.createdAt = createdAt
    }

    public var text: String {
        String(decoding: data, as: UTF8.self)
    }
}

public struct TerminalOutputWindow: Equatable {
    public let chunks: [TerminalOutputChunk]
    public let hasMoreOlder: Bool
    public let nextBeforeChunkID: Int64?

    public init(chunks: [TerminalOutputChunk], hasMoreOlder: Bool, nextBeforeChunkID: Int64?) {
        self.chunks = chunks
        self.hasMoreOlder = hasMoreOlder
        self.nextBeforeChunkID = nextBeforeChunkID
    }

    public var text: String {
        String(decoding: chunks.reduce(into: Data()) { $0.append($1.data) }, as: UTF8.self)
    }
}

public struct TerminalHistoryGlobalPruneResult: Equatable, Sendable {
    public let deletedRows: Int
    public let deletedBytes: Int
    public let truncatedSurfaceIDs: Set<String>
    public let remainsOverBudget: Bool

    public init(deletedRows: Int, deletedBytes: Int, truncatedSurfaceIDs: Set<String>, remainsOverBudget: Bool) {
        self.deletedRows = deletedRows
        self.deletedBytes = deletedBytes
        self.truncatedSurfaceIDs = truncatedSurfaceIDs
        self.remainsOverBudget = remainsOverBudget
    }
}

public struct TerminalHistoryPartialState: Codable, Equatable, Sendable {
    public let reason: String
    public let nextChunkIndex: Int64

    public init(reason: String, nextChunkIndex: Int64) {
        self.reason = reason
        self.nextChunkIndex = max(1, nextChunkIndex)
    }
}

public struct TerminalHistoryPreparation: Equatable, Sendable {
    public let nextChunkIndex: Int64
    public let partialState: TerminalHistoryPartialState?
    public let writerGeneration: String

    public init(
        nextChunkIndex: Int64,
        partialState: TerminalHistoryPartialState?,
        writerGeneration: String
    ) {
        self.nextChunkIndex = max(1, nextChunkIndex)
        self.partialState = partialState
        self.writerGeneration = writerGeneration
    }
}

public enum TerminalHistoryRepositoryError: Error, Equatable, CustomStringConvertible {
    case staleWriterGeneration
    case unresolvedWriteReservation

    public var description: String {
        switch self {
        case .staleWriterGeneration:
            return "stale terminal history writer generation"
        case .unresolvedWriteReservation:
            return "unresolved terminal history write reservation"
        }
    }
}

public struct TerminalHistoryFailureAnchor: Codable, Equatable, Sendable {
    public let surfaceID: String
    public let writerGeneration: String
    public let reason: String
    public let minimumNextChunkIndex: Int64

    public init(
        surfaceID: String,
        writerGeneration: String,
        reason: String,
        minimumNextChunkIndex: Int64
    ) {
        self.surfaceID = surfaceID
        self.writerGeneration = writerGeneration
        self.reason = reason
        self.minimumNextChunkIndex = max(1, minimumNextChunkIndex)
    }
}

public struct TerminalHistoryPendingDelete: Codable, Equatable, Hashable, Sendable {
    public enum Disposition: String, Codable, Sendable {
        case finalDelete
        case clearForReuse
    }

    public enum Phase: String, Codable, Sendable {
        case pending
        case finished
    }

    public let id: String
    public let surfaceID: String
    public let expectedWriterGeneration: String?
    public let disposition: Disposition
    public let phase: Phase

    public init(
        id: String = UUID().uuidString,
        surfaceID: String,
        expectedWriterGeneration: String?,
        disposition: Disposition = .finalDelete,
        phase: Phase = .pending
    ) {
        self.id = id
        self.surfaceID = surfaceID
        self.expectedWriterGeneration = expectedWriterGeneration
        self.disposition = disposition
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case surfaceID
        case expectedWriterGeneration
        case disposition
        case phase
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        surfaceID = try values.decode(String.self, forKey: .surfaceID)
        expectedWriterGeneration = try values.decodeIfPresent(
            String.self,
            forKey: .expectedWriterGeneration
        )
        disposition = try values.decodeIfPresent(
            Disposition.self,
            forKey: .disposition
        ) ?? .finalDelete
        phase = try values.decodeIfPresent(Phase.self, forKey: .phase) ?? .pending
    }
}

public enum TerminalHistoryFailureLedgerError: Error, Equatable {
    case invalidIdentifier
    case corruptAnchor
}

enum TerminalHistoryFileDescriptorFlags {
    @discardableResult
    static func enableCloseOnExec(
        _ descriptor: Int32,
        getFlags: (Int32) -> Int32 = { Darwin.fcntl($0, F_GETFD) },
        setFlags: (Int32, Int32) -> Int32 = { Darwin.fcntl($0, F_SETFD, $1) }
    ) -> Bool {
        guard descriptor >= 0 else { return false }
        let flags = getFlags(descriptor)
        guard flags >= 0 else { return false }
        guard flags & FD_CLOEXEC == 0 else { return true }
        return setFlags(descriptor, flags | FD_CLOEXEC) == 0
    }
}

/// A process-durable pre-write fence outside SQLite. SQLite can reject even the
/// first high-water reservation while another process owns BEGIN IMMEDIATE, so
/// one metadata-only sidecar per surface/generation is atomically committed
/// before the payload attempt. No terminal bytes or user content are stored.
private final class TerminalHistoryProcessLockPool: @unchecked Sendable {
    static let shared = TerminalHistoryProcessLockPool()

    private let registryLock = NSLock()
    private let locks = NSMapTable<NSString, NSLock>(
        keyOptions: .copyIn,
        valueOptions: .weakMemory
    )

    func lock(for rootURL: URL) -> NSLock {
        let key = rootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path as NSString
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks.object(forKey: key) { return existing }
        let created = NSLock()
        locks.setObject(created, forKey: key)
        return created
    }
}

private final class TerminalHistoryFailureLedger: @unchecked Sendable {
    let rootURL: URL
    private let fileManager = FileManager.default
    private let processLock: NSLock
    // PERF: record/decode of failure anchors and pending-delete tombstones each
    // allocated JSONDecoder/JSONEncoder. Mutations run under withLedgerLock, so
    // one pair is safe and avoids per-mutation codec construction.
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let descriptorOpenedForTesting: (@Sendable (String, Int32) -> Void)?

    init(
        databasePath: String,
        rootOverride: URL? = nil,
        descriptorOpenedForTesting: (@Sendable (String, Int32) -> Void)? = nil
    ) {
        self.descriptorOpenedForTesting = descriptorOpenedForTesting
        let resolvedRoot: URL
        if let rootOverride {
            resolvedRoot = rootOverride
        } else {
            let databaseURL = URL(fileURLWithPath: databasePath)
            resolvedRoot = databaseURL.deletingLastPathComponent().appendingPathComponent(
                ".\(databaseURL.lastPathComponent).terminal-history-failures",
                isDirectory: true
            )
        }
        rootURL = resolvedRoot
        processLock = TerminalHistoryProcessLockPool.shared.lock(for: resolvedRoot)
    }

    func record(_ incoming: TerminalHistoryFailureAnchor) throws {
        let surfaceID = try normalizedUUID(incoming.surfaceID)
        let writerGeneration = try normalizedUUID(incoming.writerGeneration)
        try ensureRootDirectory()
        try withLedgerLock {
            let url = try anchorURL(
                surfaceID: surfaceID,
                writerGeneration: writerGeneration
            )
            let existing: TerminalHistoryFailureAnchor?
            if fileManager.fileExists(atPath: url.path) {
                existing = try decodeAnchor(at: url)
            } else {
                existing = nil
            }
            let anchor = TerminalHistoryFailureAnchor(
                surfaceID: surfaceID,
                writerGeneration: writerGeneration,
                reason: existing?.reason ?? incoming.reason,
                minimumNextChunkIndex: max(
                    existing?.minimumNextChunkIndex ?? 1,
                    incoming.minimumNextChunkIndex
                )
            )
            try atomicWrite(try encoder.encode(anchor), to: url)
        }
    }

    func anchors(surfaceID rawSurfaceID: String) throws -> [TerminalHistoryFailureAnchor] {
        let surfaceID = try normalizedUUID(rawSurfaceID)
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        return try withLedgerLock {
            let prefix = surfaceID.lowercased() + "-"
            return try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .map { try decodeAnchor(at: $0) }
            .filter { $0.surfaceID == surfaceID }
        }
    }

    func clear(
        surfaceID rawSurfaceID: String,
        writerGeneration rawWriterGeneration: String,
        throughNextChunkIndex: Int64? = nil
    ) throws {
        let surfaceID = try normalizedUUID(rawSurfaceID)
        let writerGeneration = try normalizedUUID(rawWriterGeneration)
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try withLedgerLock {
            let url = try anchorURL(
                surfaceID: surfaceID,
                writerGeneration: writerGeneration
            )
            guard fileManager.fileExists(atPath: url.path) else { return }
            if let throughNextChunkIndex {
                let anchor = try decodeAnchor(at: url)
                guard anchor.minimumNextChunkIndex <= throughNextChunkIndex else { return }
            }
            try fileManager.removeItem(at: url)
            try syncDirectory()
        }
    }

    func clear(surfaceID rawSurfaceID: String) throws {
        let surfaceID = try normalizedUUID(rawSurfaceID)
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try withLedgerLock {
            let prefix = surfaceID.lowercased() + "-"
            for url in try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json" {
                try fileManager.removeItem(at: url)
            }
            try syncDirectory()
        }
    }

    func recordPendingDelete(
        surfaceID rawSurfaceID: String,
        expectedWriterGeneration rawWriterGeneration: String?,
        disposition: TerminalHistoryPendingDelete.Disposition
    ) throws -> TerminalHistoryPendingDelete {
        let surfaceID = try normalizedUUID(rawSurfaceID)
        let writerGeneration = try rawWriterGeneration.map(normalizedUUID)
        try ensureRootDirectory()
        return try withLedgerLock {
            if let existing = try pendingDeletesLocked().first(where: {
                $0.surfaceID == surfaceID
                    && $0.expectedWriterGeneration == writerGeneration
                    && $0.disposition == disposition
                    && $0.phase == .pending
            }) {
                return existing
            }
            let pending = TerminalHistoryPendingDelete(
                surfaceID: surfaceID,
                expectedWriterGeneration: writerGeneration,
                disposition: disposition
            )
            try atomicWrite(
                try encoder.encode(pending),
                to: try pendingDeleteURL(surfaceID: surfaceID, id: pending.id)
            )
            return pending
        }
    }

    func pendingDeletes() throws -> [TerminalHistoryPendingDelete] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        return try withLedgerLock { try pendingDeletesLocked() }
    }

    func pendingDelete(
        surfaceID rawSurfaceID: String,
        id rawID: String
    ) throws -> TerminalHistoryPendingDelete? {
        let surfaceID = try normalizedUUID(rawSurfaceID)
        let id = try normalizedUUID(rawID)
        guard fileManager.fileExists(atPath: rootURL.path) else { return nil }
        return try withLedgerLock {
            let url = try pendingDeleteURL(surfaceID: surfaceID, id: id)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try decodePendingDelete(at: url)
        }
    }

    func markPendingDeleteFinished(_ incoming: TerminalHistoryPendingDelete) throws {
        let surfaceID = try normalizedUUID(incoming.surfaceID)
        let id = try normalizedUUID(incoming.id)
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try withLedgerLock {
            let url = try pendingDeleteURL(surfaceID: surfaceID, id: id)
            guard fileManager.fileExists(atPath: url.path) else { return }
            let current = try decodePendingDelete(at: url)
            guard current.surfaceID == surfaceID, current.id == id else {
                throw TerminalHistoryFailureLedgerError.corruptAnchor
            }
            guard current.phase != .finished else { return }
            try atomicWrite(
                try encoder.encode(TerminalHistoryPendingDelete(
                    id: id,
                    surfaceID: surfaceID,
                    expectedWriterGeneration: current.expectedWriterGeneration,
                    disposition: current.disposition,
                    phase: .finished
                )),
                to: url
            )
        }
    }

    func clearPendingDelete(_ incoming: TerminalHistoryPendingDelete) throws {
        let surfaceID = try normalizedUUID(incoming.surfaceID)
        let id = try normalizedUUID(incoming.id)
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try withLedgerLock {
            let url = try pendingDeleteURL(surfaceID: surfaceID, id: id)
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
            try syncDirectory()
        }
    }

    func anchorURL(surfaceID: String, writerGeneration: String) throws -> URL {
        let surface = try normalizedUUID(surfaceID).lowercased()
        let generation = try normalizedUUID(writerGeneration).lowercased()
        return rootURL.appendingPathComponent("\(surface)-\(generation).json", isDirectory: false)
    }

    func pendingDeleteURL(surfaceID: String, id: String) throws -> URL {
        let surface = try normalizedUUID(surfaceID).lowercased()
        let token = try normalizedUUID(id).lowercased()
        return rootURL.appendingPathComponent(
            "delete-\(surface)-\(token).tombstone",
            isDirectory: false
        )
    }

    private func normalizedUUID(_ raw: String) throws -> String {
        guard let uuid = UUID(uuidString: raw) else {
            throw TerminalHistoryFailureLedgerError.invalidIdentifier
        }
        return uuid.uuidString
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
    }

    private func withLedgerLock<T>(_ body: () throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        let lockURL = rootURL.appendingPathComponent(".lock", isDirectory: false)
        let descriptor = try openDescriptor(
            at: lockURL,
            flags: O_RDWR | O_CREAT,
            permissions: S_IRUSR | S_IWUSR,
            operation: "open ledger lock",
            kind: "lock"
        )
        defer { Darwin.close(descriptor) }
        var fileLock = Darwin.flock()
        fileLock.l_start = 0
        fileLock.l_len = 0
        fileLock.l_pid = 0
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLKW, &fileLock) != -1 else {
            throw posixError("lock ledger")
        }
        defer {
            fileLock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw posixError("chmod ledger lock")
        }
        return try body()
    }

    private func decodeAnchor(at url: URL) throws -> TerminalHistoryFailureAnchor {
        let data = try Data(contentsOf: url)
        guard let anchor = try? decoder.decode(
            TerminalHistoryFailureAnchor.self,
            from: data
        ),
        UUID(uuidString: anchor.surfaceID) != nil,
        UUID(uuidString: anchor.writerGeneration) != nil else {
            throw TerminalHistoryFailureLedgerError.corruptAnchor
        }
        return anchor
    }

    private func pendingDeletesLocked() throws -> [TerminalHistoryPendingDelete] {
        try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("delete-") && $0.pathExtension == "tombstone" }
        .map { try decodePendingDelete(at: $0) }
        .sorted { $0.id < $1.id }
    }

    private func decodePendingDelete(at url: URL) throws -> TerminalHistoryPendingDelete {
        let data = try Data(contentsOf: url)
        guard let pending = try? decoder.decode(
            TerminalHistoryPendingDelete.self,
            from: data
        ),
        UUID(uuidString: pending.id) != nil,
        UUID(uuidString: pending.surfaceID) != nil,
        pending.expectedWriterGeneration.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw TerminalHistoryFailureLedgerError.corruptAnchor
        }
        return pending
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = rootURL.appendingPathComponent(
            ".tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        let descriptor: Int32
        do {
            descriptor = try openDescriptor(
                at: temporary,
                flags: O_WRONLY | O_CREAT | O_EXCL,
                permissions: S_IRUSR | S_IWUSR,
                operation: "open ledger temp",
                kind: "temp"
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        var descriptorNeedsClose = true
        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard written > 0 else { throw posixError("write ledger temp") }
                    offset += written
                }
            }
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw posixError("chmod ledger temp")
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw posixError("sync ledger temp")
            }
            let closeResult = Darwin.close(descriptor)
            descriptorNeedsClose = false
            guard closeResult == 0 else {
                throw posixError("close ledger temp")
            }
        } catch {
            if descriptorNeedsClose {
                Darwin.close(descriptor)
            }
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        let renamed = temporary.path.withCString { source in
            destination.path.withCString { target in
                Darwin.rename(source, target)
            }
        }
        guard renamed == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw posixError("rename ledger anchor")
        }
        try syncDirectory()
    }

    private func syncDirectory() throws {
        let descriptor = try openDescriptor(
            at: rootURL,
            flags: O_RDONLY,
            operation: "open ledger directory",
            kind: "directory"
        )
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("sync ledger directory")
        }
    }

    private func openDescriptor(
        at url: URL,
        flags: Int32,
        permissions: mode_t? = nil,
        operation: String,
        kind: String
    ) throws -> Int32 {
        let descriptor = url.path.withCString { path in
            if let permissions {
                return Darwin.open(path, flags | O_CLOEXEC, permissions)
            }
            return Darwin.open(path, flags | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError(operation) }
        guard TerminalHistoryFileDescriptorFlags.enableCloseOnExec(descriptor) else {
            let savedErrno = errno == 0 ? EIO : errno
            Darwin.close(descriptor)
            errno = savedErrno
            throw posixError("mark \(kind) close-on-exec")
        }
        descriptorOpenedForTesting?(kind, descriptor)
        return descriptor
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"]
        )
    }
}

public final class TerminalOutputRepository {
    let db: SQLiteDB
    private let failureLedger: TerminalHistoryFailureLedger?
    // PERF: partial/dirty history state load/merge allocated JSONDecoder/JSONEncoder
    // on every terminal chunk durability write. Shared process-wide pair under a
    // short lock (codecs are not thread-safe); wire JSON formatting unchanged.
    private static let partialStateCodecLock = NSLock()
    private static let partialStateDecoder = JSONDecoder()
    private static let partialStateEncoder = JSONEncoder()

    public init(db: SQLiteDB) {
        self.db = db
        failureLedger = db.path == ":memory:"
            ? nil
            : TerminalHistoryFailureLedger(databasePath: db.path)
    }

    init(
        db: SQLiteDB,
        terminalHistoryFailureLedgerRootForTesting rootURL: URL,
        descriptorOpenedForTesting: (@Sendable (String, Int32) -> Void)? = nil
    ) {
        self.db = db
        failureLedger = TerminalHistoryFailureLedger(
            databasePath: db.path,
            rootOverride: rootURL,
            descriptorOpenedForTesting: descriptorOpenedForTesting
        )
    }

    private static func partialHistoryKey(surfaceID: String) -> String {
        "terminal.history.partial.\(surfaceID)"
    }

    private static func dirtyHistoryKey(surfaceID: String) -> String {
        "terminal.history.dirty.\(surfaceID)"
    }

    private static func writerGenerationKey(surfaceID: String) -> String {
        "terminal.history.writer_generation.\(surfaceID)"
    }

    private static func pendingDeleteCommitKey(surfaceID: String) -> String {
        "terminal.history.pending_delete_commit.\(surfaceID)"
    }

    public func recordFailureAnchor(
        surfaceID: String,
        writerGeneration: String,
        reason: String,
        minimumNextChunkIndex: Int64
    ) throws {
        try failureLedger?.record(TerminalHistoryFailureAnchor(
            surfaceID: surfaceID,
            writerGeneration: writerGeneration,
            reason: reason,
            minimumNextChunkIndex: minimumNextChunkIndex
        ))
    }

    public func failureAnchors(
        surfaceID: String
    ) throws -> [TerminalHistoryFailureAnchor] {
        try failureLedger?.anchors(surfaceID: surfaceID) ?? []
    }

    public func clearFailureAnchor(
        surfaceID: String,
        writerGeneration: String,
        throughNextChunkIndex: Int64? = nil
    ) throws {
        try failureLedger?.clear(
            surfaceID: surfaceID,
            writerGeneration: writerGeneration,
            throughNextChunkIndex: throughNextChunkIndex
        )
    }

    public func clearFailureAnchors(surfaceID: String) throws {
        try failureLedger?.clear(surfaceID: surfaceID)
    }

    public func recordPendingDelete(
        surfaceID: String,
        expectedWriterGeneration: String?,
        disposition: TerminalHistoryPendingDelete.Disposition = .finalDelete
    ) throws -> TerminalHistoryPendingDelete {
        if let failureLedger {
            return try failureLedger.recordPendingDelete(
                surfaceID: surfaceID,
                expectedWriterGeneration: expectedWriterGeneration,
                disposition: disposition
            )
        }
        return TerminalHistoryPendingDelete(
            surfaceID: surfaceID,
            expectedWriterGeneration: expectedWriterGeneration,
            disposition: disposition
        )
    }

    public func recordPendingClearForReuse(
        surfaceID: String
    ) throws -> TerminalHistoryPendingDelete {
        try recordPendingDelete(
            surfaceID: surfaceID,
            expectedWriterGeneration: writerGeneration(surfaceID: surfaceID),
            disposition: .clearForReuse
        )
    }

    public func pendingDeletes() throws -> [TerminalHistoryPendingDelete] {
        try failureLedger?.pendingDeletes() ?? []
    }

    /// Executes a durable final-delete tombstone. The SQLite commit marker is
    /// written in the same transaction as the destructive phase. The finished
    /// file phase is then committed before removing that marker, closing both
    /// crash gaps without allowing a replay to erase a successor generation.
    public func performPendingDelete(_ recorded: TerminalHistoryPendingDelete) throws {
        let pending = try failureLedger?.pendingDelete(
            surfaceID: recorded.surfaceID,
            id: recorded.id
        ) ?? recorded
        if pending.phase == .pending {
            let shouldCleanAnchors = try db.performSync { database in
                try database.transaction {
                    if try Self.settingValue(
                        key: Self.pendingDeleteCommitKey(surfaceID: pending.surfaceID),
                        database: database
                    ) == pending.id {
                        return true
                    }
                    let currentGeneration = try Self.writerGeneration(
                        surfaceID: pending.surfaceID,
                        database: database
                    )
                    switch pending.disposition {
                    case .finalDelete:
                        if let expected = pending.expectedWriterGeneration,
                           currentGeneration != expected {
                            return false
                        }
                    case .clearForReuse:
                        guard currentGeneration == pending.expectedWriterGeneration else {
                            return false
                        }
                    }
                    try Self.deleteHistoryState(
                        surfaceID: pending.surfaceID,
                        database: database
                    )
                    switch pending.disposition {
                    case .finalDelete:
                        try Self.deleteSetting(
                            key: Self.writerGenerationKey(surfaceID: pending.surfaceID),
                            database: database
                        )
                    case .clearForReuse:
                        try Self.upsertSetting(
                            key: Self.writerGenerationKey(surfaceID: pending.surfaceID),
                            value: UUID().uuidString,
                            database: database
                        )
                    }
                    try Self.upsertSetting(
                        key: Self.pendingDeleteCommitKey(surfaceID: pending.surfaceID),
                        value: pending.id,
                        database: database
                    )
                    return true
                }
            }
            if let expected = pending.expectedWriterGeneration {
                try clearFailureAnchor(
                    surfaceID: pending.surfaceID,
                    writerGeneration: expected
                )
            } else if shouldCleanAnchors {
                try clearFailureAnchors(surfaceID: pending.surfaceID)
            }
            try failureLedger?.markPendingDeleteFinished(pending)
        }

        try db.performSync { database in
            try database.transaction {
                let key = Self.pendingDeleteCommitKey(surfaceID: pending.surfaceID)
                guard try Self.settingValue(key: key, database: database) == pending.id else {
                    return
                }
                try Self.deleteSetting(key: key, database: database)
            }
        }
        try failureLedger?.clearPendingDelete(pending)
    }

    public func failureAnchorIsCovered(
        _ anchor: TerminalHistoryFailureAnchor
    ) throws -> Bool {
        if let partial = try partialHistoryState(
            surfaceID: anchor.surfaceID,
            expectedWriterGeneration: anchor.writerGeneration
        ),
        partial.nextChunkIndex >= anchor.minimumNextChunkIndex {
            return true
        }
        let chunkIndex = max(1, anchor.minimumNextChunkIndex - 1)
        return try db.performSync { database in
            let statement = try database.prepare("""
                SELECT 1
                FROM terminal_output_chunks
                WHERE surface_id = ? AND chunk_index = ?
                LIMIT 1;
            """)
            try statement.bind(1, anchor.surfaceID)
            try statement.bind(2, chunkIndex)
            return try statement.step()
        }
    }

    var failureLedgerRootURLForTesting: URL? { failureLedger?.rootURL }

    func failureAnchorURLForTesting(
        surfaceID: String,
        writerGeneration: String
    ) throws -> URL? {
        try failureLedger?.anchorURL(
            surfaceID: surfaceID,
            writerGeneration: writerGeneration
        )
    }

    func pendingDeleteURLForTesting(
        surfaceID: String,
        id: String
    ) throws -> URL? {
        try failureLedger?.pendingDeleteURL(surfaceID: surfaceID, id: id)
    }

    public func append(surfaceID: String, workspaceID: String?, chunkIndex: Int64, data: Data) throws {
        guard !data.isEmpty else { return }
        try db.performSync { database in
            let st = try database.prepare("""
                INSERT INTO terminal_output_chunks(surface_id, workspace_id, chunk_index, data, byte_count, created_at)
                VALUES(?, ?, ?, ?, ?, ?);
            """)
            try st.bind(1, surfaceID)
            try st.bind(2, workspaceID)
            try st.bind(3, chunkIndex)
            try st.bind(4, data)
            try st.bind(5, Int64(data.count))
            try st.bind(6, iso.string(from: Date()))
            _ = try st.step()

            let changes = try database.prepare("SELECT changes();")
            guard try changes.step(), changes.columnInt64(0) == 1 else {
                throw SQLiteError.execute(
                    "Terminal history append did not insert exactly one row for surface \(surfaceID) chunk \(chunkIndex)."
                )
            }
        }
    }

    public func nextChunkIndex(surfaceID: String) throws -> Int64 {
        let st = try db.prepare("SELECT COALESCE(MAX(chunk_index), 0) + 1 FROM terminal_output_chunks WHERE surface_id = ?;")
        try st.bind(1, surfaceID)
        return (try st.step()) ? st.columnInt64(0) : 1
    }

    public func writerGeneration(surfaceID: String) throws -> String? {
        try db.performSync { database in
            try Self.writerGeneration(surfaceID: surfaceID, database: database)
        }
    }

    public func prepareHistory(surfaceID: String) throws -> TerminalHistoryPreparation {
        for pending in try pendingDeletes() where
            pending.surfaceID == surfaceID && pending.disposition == .clearForReuse {
            try performPendingDelete(pending)
        }
        return try db.performSync { database in
            try database.transaction {
                let writerGeneration: String
                if let existing = try Self.settingValue(
                    key: Self.writerGenerationKey(surfaceID: surfaceID),
                    database: database
                ) {
                    writerGeneration = existing
                } else {
                    writerGeneration = UUID().uuidString
                    try Self.upsertSetting(
                        key: Self.writerGenerationKey(surfaceID: surfaceID),
                        value: writerGeneration,
                        database: database
                    )
                }

                // A dirty reservation means a prior process could have exited
                // between reserving and committing a chunk. Promote it to the
                // durable partial marker before this writer can reserve another
                // chunk, so a later successful append can never erase the gap.
                if let dirty = try Self.partialState(
                    key: Self.dirtyHistoryKey(surfaceID: surfaceID),
                    database: database
                ) {
                    try Self.mergePartialState(
                        key: Self.partialHistoryKey(surfaceID: surfaceID),
                        incoming: dirty,
                        database: database
                    )
                    try Self.deleteSetting(
                        key: Self.dirtyHistoryKey(surfaceID: surfaceID),
                        database: database
                    )
                }

                let storedNextIndex = try Self.nextChunkIndex(
                    surfaceID: surfaceID,
                    database: database
                )
                let partial = try Self.partialState(
                    key: Self.partialHistoryKey(surfaceID: surfaceID),
                    database: database
                )
                return TerminalHistoryPreparation(
                    nextChunkIndex: max(storedNextIndex, partial?.nextChunkIndex ?? 1),
                    partialState: partial,
                    writerGeneration: writerGeneration
                )
            }
        }
    }

    public func partialHistoryState(surfaceID: String) throws -> TerminalHistoryPartialState? {
        try db.performSync { database in
            try Self.combinedPartialState(
                surfaceID: surfaceID,
                database: database
            )
        }
    }

    public func partialHistoryState(
        surfaceID: String,
        expectedWriterGeneration: String
    ) throws -> TerminalHistoryPartialState? {
        try db.performSync { database in
            try Self.requireWriterGeneration(
                expectedWriterGeneration,
                surfaceID: surfaceID,
                database: database
            )
            return try Self.combinedPartialState(
                surfaceID: surfaceID,
                database: database
            )
        }
    }

    public func markHistoryPartial(
        surfaceID: String,
        reason: String,
        nextChunkIndex: Int64
    ) throws {
        try db.performSync { database in
            try database.transaction {
                try Self.mergePartialState(
                    key: Self.partialHistoryKey(surfaceID: surfaceID),
                    incoming: TerminalHistoryPartialState(
                        reason: reason,
                        nextChunkIndex: nextChunkIndex
                    ),
                    database: database
                )
            }
        }
    }

    public func markHistoryPartial(
        surfaceID: String,
        reason: String,
        nextChunkIndex: Int64,
        expectedWriterGeneration: String
    ) throws {
        try db.performSync { database in
            try database.transaction {
                try Self.requireWriterGeneration(
                    expectedWriterGeneration,
                    surfaceID: surfaceID,
                    database: database
                )
                try Self.mergePartialState(
                    key: Self.partialHistoryKey(surfaceID: surfaceID),
                    incoming: TerminalHistoryPartialState(
                        reason: reason,
                        nextChunkIndex: nextChunkIndex
                    ),
                    database: database
                )
            }
        }
    }

    /// Commits a fail-closed high-water reservation before attempting the
    /// corresponding chunk insert. The insert and reservation removal then
    /// commit atomically. If the insert fails or the process exits, the dirty
    /// reservation survives and prevents index reuse on relaunch.
    public func appendWithHighWaterReservation(
        surfaceID: String,
        workspaceID: String?,
        chunkIndex: Int64,
        data: Data,
        expectedWriterGeneration: String
    ) throws {
        guard !data.isEmpty else { return }
        let reservedNextIndex = chunkIndex + 1
        try db.performSync { database in
            try database.transaction {
                try Self.requireWriterGeneration(
                    expectedWriterGeneration,
                    surfaceID: surfaceID,
                    database: database
                )
                let dirtyKey = Self.dirtyHistoryKey(surfaceID: surfaceID)
                if let existing = try Self.partialState(key: dirtyKey, database: database) {
                    guard existing.nextChunkIndex == reservedNextIndex else {
                        throw TerminalHistoryRepositoryError.unresolvedWriteReservation
                    }
                } else {
                    try Self.mergePartialState(
                        key: dirtyKey,
                        incoming: TerminalHistoryPartialState(
                            reason: "history_persistence_failed",
                            nextChunkIndex: reservedNextIndex
                        ),
                        database: database
                    )
                }
            }
        }

        try db.performSync { database in
            try database.transaction {
                try Self.requireWriterGeneration(
                    expectedWriterGeneration,
                    surfaceID: surfaceID,
                    database: database
                )
                let st = try database.prepare("""
                    INSERT INTO terminal_output_chunks(surface_id, workspace_id, chunk_index, data, byte_count, created_at)
                    VALUES(?, ?, ?, ?, ?, ?);
                """)
                try st.bind(1, surfaceID)
                try st.bind(2, workspaceID)
                try st.bind(3, chunkIndex)
                try st.bind(4, data)
                try st.bind(5, Int64(data.count))
                try st.bind(6, iso.string(from: Date()))
                _ = try st.step()

                let changes = try database.prepare("SELECT changes();")
                guard try changes.step(), changes.columnInt64(0) == 1 else {
                    throw SQLiteError.execute(
                        "Terminal history append did not insert exactly one row for surface \(surfaceID) chunk \(chunkIndex)."
                    )
                }
                try Self.deleteSetting(
                    key: Self.dirtyHistoryKey(surfaceID: surfaceID),
                    database: database
                )
            }
        }
    }

    public func readWindow(
        surfaceID: String,
        beforeChunkID: Int64? = nil,
        maxBytes: Int = 256 * 1024,
        beforeChunkIndex: Int64? = nil
    ) throws -> TerminalOutputWindow {
        let byteLimit = max(1, maxBytes)
        var predicates = ["surface_id = ?"]
        if beforeChunkID != nil { predicates.append("id < ?") }
        if beforeChunkIndex != nil { predicates.append("chunk_index < ?") }
        let sql = """
            SELECT id, surface_id, workspace_id, chunk_index, data, created_at
            FROM terminal_output_chunks
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY id DESC;
        """
        let st = try db.prepare(sql)
        try st.bind(1, surfaceID)
        var bindingIndex: Int32 = 2
        if let beforeChunkID {
            try st.bind(bindingIndex, beforeChunkID)
            bindingIndex += 1
        }
        if let beforeChunkIndex {
            try st.bind(bindingIndex, beforeChunkIndex)
        }

        var reversed: [TerminalOutputChunk] = []
        var bytes = 0
        var hasMoreOlder = false
        while try st.step() {
            guard let data = st.columnBlob(4) else { continue }
            if !reversed.isEmpty && bytes + data.count > byteLimit {
                hasMoreOlder = true
                break
            }
            reversed.append(TerminalOutputChunk(
                id: st.columnInt64(0),
                surfaceID: st.columnText(1) ?? "",
                workspaceID: st.columnText(2),
                chunkIndex: st.columnInt64(3),
                data: data,
                createdAt: parseDate(st.columnText(5))
            ))
            bytes += data.count
            if bytes >= byteLimit { break }
        }
        let chunks = Array(reversed.reversed())
        return TerminalOutputWindow(
            chunks: chunks,
            hasMoreOlder: hasMoreOlder || hasOlder(surfaceID: surfaceID, before: chunks.first?.id),
            nextBeforeChunkID: chunks.first?.id
        )
    }

    /// Prune oldest chunks for `surfaceID` so total stored bytes ≤ `maxBytes`.
    /// Deletes rows with the smallest `id` values (oldest) until the byte sum fits.
    public func pruneByteCap(surfaceID: String, maxBytes: Int) throws {
        guard maxBytes > 0 else { return }
        try db.performSync { database in
            _ = try Self.pruneByteCap(
                surfaceID: surfaceID,
                maxBytes: maxBytes,
                database: database
            )
        }
    }

    /// Production retention disposition. Chunk deletion and the durable
    /// partial/high-water marker share one transaction: either both become
    /// visible or SQLite rolls both back.
    @discardableResult
    public func pruneByteCapAndMarkHistoryPartial(
        surfaceID: String,
        maxBytes: Int,
        reason: String,
        nextChunkIndex: Int64,
        expectedWriterGeneration: String
    ) throws -> Bool {
        guard maxBytes > 0 else { return false }
        return try db.performSync { database in
            try database.transaction {
                try Self.requireWriterGeneration(
                    expectedWriterGeneration,
                    surfaceID: surfaceID,
                    database: database
                )
                let pruned = try Self.pruneByteCap(
                    surfaceID: surfaceID,
                    maxBytes: maxBytes,
                    database: database
                )
                guard pruned else { return false }
                try Self.mergePartialState(
                    key: Self.partialHistoryKey(surfaceID: surfaceID),
                    incoming: TerminalHistoryPartialState(
                        reason: reason,
                        nextChunkIndex: nextChunkIndex
                    ),
                    database: database
                )
                return true
            }
        }
    }

    public func totalBytes(surfaceID: String) throws -> Int {
        try db.performSync { database in
            try Self.totalBytes(surfaceID: surfaceID, database: database)
        }
    }

    public func totalBytesAllSurfaces() throws -> Int {
        try db.performSync { database in
            try Self.totalBytesAllSurfaces(database: database)
        }
    }

    /// Deletes at most one bounded oldest-first quantum across inactive
    /// histories. The writing surface is protected; its independent 8 MiB cap is
    /// enforced first by the coordinator. Every affected surface receives its
    /// durable partial marker in the same transaction as the chunk deletion.
    public func pruneGlobalByteCapAndMarkHistoryPartial(
        maxBytes: Int,
        protectedSurfaceID: String,
        maxRows: Int = 256,
        maxDeleteBytes: Int = 8 * 1_024 * 1_024
    ) throws -> TerminalHistoryGlobalPruneResult {
        guard maxBytes > 0 else {
            return TerminalHistoryGlobalPruneResult(deletedRows: 0, deletedBytes: 0, truncatedSurfaceIDs: [], remainsOverBudget: false)
        }
        return try db.performSync { database in
            try database.transaction {
                let total = try Self.totalBytesAllSurfaces(database: database)
                guard total > maxBytes else {
                    return TerminalHistoryGlobalPruneResult(deletedRows: 0, deletedBytes: 0, truncatedSurfaceIDs: [], remainsOverBudget: false)
                }
                let needed = min(total - maxBytes, max(1, maxDeleteBytes))
                let candidates = try database.prepare("""
                    SELECT id, surface_id, byte_count
                    FROM terminal_output_chunks
                    WHERE surface_id <> ?
                    ORDER BY id ASC
                    LIMIT ?;
                """)
                try candidates.bind(1, protectedSurfaceID)
                try candidates.bind(2, max(1, maxRows))
                var ids: [Int64] = []
                var deletedBytes = 0
                var surfaces = Set<String>()
                while try candidates.step() {
                    ids.append(candidates.columnInt64(0))
                    if let surface = candidates.columnText(1) { surfaces.insert(surface) }
                    deletedBytes += max(0, Int(candidates.columnInt64(2)))
                    if deletedBytes >= needed { break }
                }
                guard !ids.isEmpty else {
                    return TerminalHistoryGlobalPruneResult(deletedRows: 0, deletedBytes: 0, truncatedSurfaceIDs: [], remainsOverBudget: true)
                }
                var nextIndexes: [String: Int64] = [:]
                for surface in surfaces {
                    nextIndexes[surface] = try Self.nextChunkIndex(surfaceID: surface, database: database)
                }
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                let deletion = try database.prepare("DELETE FROM terminal_output_chunks WHERE id IN (\(placeholders));")
                for (index, id) in ids.enumerated() {
                    try deletion.bind(Int32(index + 1), id)
                }
                _ = try deletion.step()
                for surface in surfaces {
                    try Self.mergePartialState(
                        key: Self.partialHistoryKey(surfaceID: surface),
                        incoming: TerminalHistoryPartialState(
                            reason: "history_global_retention_cap",
                            nextChunkIndex: nextIndexes[surface] ?? 1
                        ),
                        database: database
                    )
                }
                let remaining = max(0, total - deletedBytes)
                return TerminalHistoryGlobalPruneResult(
                    deletedRows: ids.count,
                    deletedBytes: deletedBytes,
                    truncatedSurfaceIDs: surfaces,
                    remainsOverBudget: remaining > maxBytes
                )
            }
        }
    }

    private static func totalBytes(surfaceID: String, database: SQLiteDB) throws -> Int {
        let st = try database.prepare(
            "SELECT COALESCE(SUM(byte_count), 0) FROM terminal_output_chunks WHERE surface_id = ?;"
        )
        try st.bind(1, surfaceID)
        return (try st.step()) ? Int(st.columnInt64(0)) : 0
    }

    private static func totalBytesAllSurfaces(database: SQLiteDB) throws -> Int {
        let statement = try database.prepare(
            "SELECT COALESCE(SUM(byte_count), 0) FROM terminal_output_chunks;"
        )
        return try statement.step() ? Int(statement.columnInt64(0)) : 0
    }

    /// Live clear rotates the writer generation in the same transaction as the
    /// delete. A retired runtime holding the previous generation can no longer
    /// repopulate the cleared surface.
    public func clearForReuse(
        surfaceID: String,
        expectedWriterGeneration: String
    ) throws -> String {
        try db.performSync { database in
            try database.transaction {
                try Self.requireWriterGeneration(
                    expectedWriterGeneration,
                    surfaceID: surfaceID,
                    database: database
                )
                try Self.deleteHistoryState(surfaceID: surfaceID, database: database)
                let nextGeneration = UUID().uuidString
                try Self.upsertSetting(
                    key: Self.writerGenerationKey(surfaceID: surfaceID),
                    value: nextGeneration,
                    database: database
                )
                return nextGeneration
            }
        }
    }

    public func delete(surfaceID: String) throws {
        try deletePersistedState(surfaceID: surfaceID)
        // Unconditional deletion is the terminal ownership boundary used when
        // no live coordinator remains (router/SSH fallbacks). Only clear the
        // file-backed failure ledger after SQLite committed successfully. Old
        // databases may contain opaque pre-SurfaceID values; those can be bound
        // safely in SQLite but must never become filesystem paths.
        if UUID(uuidString: surfaceID) != nil {
            try clearFailureAnchors(surfaceID: surfaceID)
        }
    }

    /// SQLite phase of an unconditional delete. Retryable ownerless
    /// dispositions use this once, then retry only the file-backed cleanup so
    /// a replacement writer created after commit cannot be erased later.
    public func deletePersistedState(surfaceID: String) throws {
        try db.performSync { database in
            try database.transaction {
                try Self.deleteHistoryState(surfaceID: surfaceID, database: database)
                try Self.deleteSetting(
                    key: Self.writerGenerationKey(surfaceID: surfaceID),
                    database: database
                )
            }
        }
    }

    /// Conditional final delete used by runtimes that may retire behind a newer
    /// runtime with the same stable surface ID. A stale owner becomes a no-op.
    @discardableResult
    public func delete(
        surfaceID: String,
        expectedWriterGeneration: String
    ) throws -> Bool {
        try db.performSync { database in
            try database.transaction {
                guard try Self.writerGeneration(
                    surfaceID: surfaceID,
                    database: database
                ) == expectedWriterGeneration else { return false }
                try Self.deleteHistoryState(surfaceID: surfaceID, database: database)
                try Self.deleteSetting(
                    key: Self.writerGenerationKey(surfaceID: surfaceID),
                    database: database
                )
                return true
            }
        }
    }

    private static func nextChunkIndex(
        surfaceID: String,
        database: SQLiteDB
    ) throws -> Int64 {
        let statement = try database.prepare(
            "SELECT COALESCE(MAX(chunk_index), 0) + 1 FROM terminal_output_chunks WHERE surface_id = ?;"
        )
        try statement.bind(1, surfaceID)
        return try statement.step() ? statement.columnInt64(0) : 1
    }

    private static func settingValue(key: String, database: SQLiteDB) throws -> String? {
        let statement = try database.prepare("SELECT value FROM settings WHERE key = ?;")
        try statement.bind(1, key)
        guard try statement.step() else { return nil }
        return statement.columnText(0)
    }

    private static func partialState(
        key: String,
        database: SQLiteDB
    ) throws -> TerminalHistoryPartialState? {
        guard let value = try settingValue(key: key, database: database) else { return nil }
        guard let data = value.data(using: .utf8) else {
            throw SQLiteError.execute("Corrupt terminal history state for key \(key).")
        }
        partialStateCodecLock.lock()
        let state = try? partialStateDecoder.decode(TerminalHistoryPartialState.self, from: data)
        partialStateCodecLock.unlock()
        guard let state else {
            throw SQLiteError.execute("Corrupt terminal history state for key \(key).")
        }
        return state
    }

    private static func combinedPartialState(
        surfaceID: String,
        database: SQLiteDB
    ) throws -> TerminalHistoryPartialState? {
        let partial = try partialState(
            key: partialHistoryKey(surfaceID: surfaceID),
            database: database
        )
        let dirty = try partialState(
            key: dirtyHistoryKey(surfaceID: surfaceID),
            database: database
        )
        guard let partial else { return dirty }
        guard let dirty else { return partial }
        return TerminalHistoryPartialState(
            reason: partial.reason,
            nextChunkIndex: max(partial.nextChunkIndex, dirty.nextChunkIndex)
        )
    }

    private static func mergePartialState(
        key: String,
        incoming: TerminalHistoryPartialState,
        database: SQLiteDB
    ) throws {
        let existing = try partialState(key: key, database: database)
        let state = TerminalHistoryPartialState(
            reason: existing?.reason ?? incoming.reason,
            nextChunkIndex: max(existing?.nextChunkIndex ?? 1, incoming.nextChunkIndex)
        )
        let encoded: Data = try {
            partialStateCodecLock.lock()
            defer { partialStateCodecLock.unlock() }
            return try partialStateEncoder.encode(state)
        }()
        guard let value = String(data: encoded, encoding: .utf8) else {
            throw SQLiteError.execute("Could not encode terminal history state for key \(key).")
        }
        try upsertSetting(key: key, value: value, database: database)
    }

    private static func upsertSetting(
        key: String,
        value: String,
        database: SQLiteDB
    ) throws {
        let statement = try database.prepare("""
            INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;
        """)
        try statement.bind(1, key)
        try statement.bind(2, value)
        try statement.bind(3, iso.string(from: Date()))
        _ = try statement.step()
    }

    private static func deleteSetting(key: String, database: SQLiteDB) throws {
        let statement = try database.prepare("DELETE FROM settings WHERE key = ?;")
        try statement.bind(1, key)
        _ = try statement.step()
    }

    private static func writerGeneration(
        surfaceID: String,
        database: SQLiteDB
    ) throws -> String? {
        try settingValue(
            key: writerGenerationKey(surfaceID: surfaceID),
            database: database
        )
    }

    private static func requireWriterGeneration(
        _ expected: String,
        surfaceID: String,
        database: SQLiteDB
    ) throws {
        guard try writerGeneration(surfaceID: surfaceID, database: database) == expected else {
            throw TerminalHistoryRepositoryError.staleWriterGeneration
        }
    }

    @discardableResult
    private static func pruneByteCap(
        surfaceID: String,
        maxBytes: Int,
        database: SQLiteDB
    ) throws -> Bool {
        let total = try totalBytes(surfaceID: surfaceID, database: database)
        guard total > maxBytes else { return false }
        let overflow = total - maxBytes
        let candidates = try database.prepare("""
            SELECT id, byte_count
            FROM terminal_output_chunks
            WHERE surface_id = ?
            ORDER BY id ASC
            LIMIT 512;
        """)
        try candidates.bind(1, surfaceID)
        var ids: [Int64] = []
        var bytes = 0
        while try candidates.step() {
            ids.append(candidates.columnInt64(0))
            bytes += max(0, Int(candidates.columnInt64(1)))
            if bytes >= overflow { break }
        }
        guard !ids.isEmpty else { return false }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let deletion = try database.prepare(
            "DELETE FROM terminal_output_chunks WHERE surface_id = ? AND id IN (\(placeholders));"
        )
        try deletion.bind(1, surfaceID)
        for (index, id) in ids.enumerated() {
            try deletion.bind(Int32(index + 2), id)
        }
        _ = try deletion.step()
        return true
    }

    private static func deleteHistoryState(
        surfaceID: String,
        database: SQLiteDB
    ) throws {
        let chunks = try database.prepare(
            "DELETE FROM terminal_output_chunks WHERE surface_id = ?;"
        )
        try chunks.bind(1, surfaceID)
        _ = try chunks.step()
        try deleteSetting(
            key: partialHistoryKey(surfaceID: surfaceID),
            database: database
        )
        try deleteSetting(
            key: dirtyHistoryKey(surfaceID: surfaceID),
            database: database
        )
    }

    private func hasOlder(surfaceID: String, before id: Int64?) -> Bool {
        guard let id else { return false }
        guard let st = try? db.prepare("SELECT 1 FROM terminal_output_chunks WHERE surface_id = ? AND id < ? LIMIT 1;") else { return false }
        try? st.bind(1, surfaceID)
        try? st.bind(2, id)
        return ((try? st.step()) ?? false)
    }
}

extension TerminalOutputRepository: @unchecked Sendable {}

public final class SessionSnapshotRepository {
    let db: SQLiteDB
    // PERF: save/latest allocated JSONEncoder/JSONDecoder per call (and latest
    // constructed a decoder per fallback blob). Shared pair under a short lock
    // so debounced autosave and startup restore avoid per-call codec construction.
    private let codecLock = NSLock()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(db: SQLiteDB) { self.db = db }

    public func save(_ snap: SessionSnapshot) throws {
        let data: Data = try {
            codecLock.lock()
            defer { codecLock.unlock() }
            return try encoder.encode(snap)
        }()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let st = try db.prepare("INSERT INTO session_snapshots(version, payload_json, created_at) VALUES(?, ?, ?);")
        try st.bind(1, Int64(snap.version))
        try st.bind(2, json)
        try st.bind(3, iso.string(from: snap.createdAt))
        _ = try st.step()
        // prune old
        try db.execute("DELETE FROM session_snapshots WHERE id NOT IN (SELECT id FROM session_snapshots ORDER BY id DESC LIMIT 20);")
    }

    /// Pure seam: given blobs newest-first, returns the first that decodes successfully
    /// and its zero-based index. Index 0 means the newest snapshot decoded fine (common
    /// case). Index > 0 means that many newer snapshots were corrupt and were skipped.
    /// Returns nil when every blob fails to decode (all-corrupt or empty input).
    /// Bound: callers pass at most 10 blobs so startup cannot stall on a fully-corrupt DB.
    public static func firstDecodable(
        _ blobs: [Data],
        decode: (Data) -> SessionSnapshot?
    ) -> (index: Int, state: SessionSnapshot)? {
        for (index, blob) in blobs.enumerated() {
            if let snap = decode(blob) {
                return (index, snap)
            }
        }
        return nil
    }

    public func latest() throws -> SessionSnapshot? {
        // Fetch up to 10 newest rows (prune keeps at most 20; 10 is a startup-latency
        // bound so a fully-corrupt DB does not block launch noticeably).
        let st = try db.prepare("SELECT payload_json FROM session_snapshots ORDER BY id DESC LIMIT 10;")
        var blobs: [Data] = []
        while try st.step() {
            guard let json = st.columnText(0), let data = json.data(using: .utf8) else { continue }
            blobs.append(data)
        }
        guard let found = SessionSnapshotRepository.firstDecodable(blobs, decode: { [self] data in
            codecLock.lock()
            let snap = try? decoder.decode(SessionSnapshot.self, from: data)
            codecLock.unlock()
            return snap
        }) else {
            return nil
        }
        if found.index > 0 {
            NSLog("RemoteCode SessionSnapshot: newest %d snapshot(s) failed to decode; restored from snapshot at fallback index %d", found.index, found.index)
        }
        return found.state
    }
}

public final class SettingsRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func get(_ key: String) throws -> String? {
        let st = try db.prepare("SELECT value FROM settings WHERE key = ?;")
        try st.bind(1, key)
        if try st.step() { return st.columnText(0) }
        return nil
    }

    public func set(_ key: String, _ value: String) throws {
        let st = try db.prepare("""
            INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;
        """)
        try st.bind(1, key)
        try st.bind(2, value)
        try st.bind(3, iso.string(from: Date()))
        _ = try st.step()
    }

    /// Delete a single settings row by exact key. No-op if absent.
    public func delete(key: String) throws {
        let st = try db.prepare("DELETE FROM settings WHERE key = ?;")
        try st.bind(1, key)
        _ = try st.step()
    }

    /// Delete every settings row whose key starts with `prefix`. Used to clean
    /// up per-entity blobs (e.g. prompt-history, plan-notes) when the owning
    /// entity is removed.
    public func deleteByPrefix(_ prefix: String) throws {
        // Use '!' as the LIKE escape character to avoid backslash quoting
        // ambiguity.  Workspace UUIDs contain only hex digits and hyphens so
        // the only characters that need escaping are '%' and '_'.
        let st = try db.prepare("DELETE FROM settings WHERE key LIKE ? ESCAPE '!';")
        let escaped = prefix
            .replacingOccurrences(of: "!", with: "!!")
            .replacingOccurrences(of: "%", with: "!%")
            .replacingOccurrences(of: "_", with: "!_")
        try st.bind(1, escaped + "%")
        _ = try st.step()
    }
}
