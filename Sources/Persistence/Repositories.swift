import Foundation
import CoreModel
import Darwin

let iso = ISO8601DateFormatter()

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

public enum AgentRoutingPersistenceError: Error, Equatable {
    case invalidConfigurationJSON
    case invalidMode(String)
    case modeConflict(column: AgentRoutingMode, configuration: AgentRoutingMode)
    case revisionConflict(column: Int, configuration: Int)
}

private func parseDate(_ s: String?) -> Date {
    guard let s, let d = iso.date(from: s) else { return Date() }
    return d
}

private func encodeModelSelection(_ selection: AgentModelSelection) -> String? {
    guard let data = try? JSONEncoder().encode(selection) else { return nil }
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
       let data = json.data(using: .utf8),
       let selection = try? JSONDecoder().decode(AgentModelSelection.self, from: data) {
        return selection
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
    guard let data = try? JSONEncoder().encode(user) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func decodeRunAsUser(_ json: String?) -> AgentRunAsUser? {
    guard let json,
          let data = json.data(using: .utf8),
          let user = try? JSONDecoder().decode(AgentRunAsUser.self, from: data) else {
        return nil
    }
    return user
}

private func encodeRoutingConfiguration(_ configuration: AgentRoutingConfiguration) throws -> String {
    let data = try JSONEncoder().encode(configuration)
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
          let data = json.data(using: .utf8),
          let configuration = try? JSONDecoder().decode(AgentRoutingConfiguration.self, from: data) else {
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
    public let providerChildThreadId: String?
    public let lastError: String?
    public let createdAt: Date
    public let updatedAt: Date
}

public final class AgentThreadRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

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

    public func list(workspaceId: WorkspaceID? = nil) throws -> [AgentThread] {
        let sql = workspaceId == nil
            ? "SELECT id, project_id, workspace_id, title, provider, provider_instance_id, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread, color, pinned, sort_order, permission_mode, reasoning_effort, execution_mode, base_branch, worktree_path, service_tier, model_selection_json, interaction_mode, run_as_user_json FROM agent_threads ORDER BY pinned DESC, sort_order ASC, updated_at DESC;"
            : "SELECT id, project_id, workspace_id, title, provider, provider_instance_id, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread, color, pinned, sort_order, permission_mode, reasoning_effort, execution_mode, base_branch, worktree_path, service_tier, model_selection_json, interaction_mode, run_as_user_json FROM agent_threads WHERE workspace_id = ? ORDER BY pinned DESC, sort_order ASC, updated_at DESC;"
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

    /// Persists the complete local half of a provider-native fork as one graph.
    /// A child is locally valid only when its thread, transcript (including
    /// attachment identities), and optional provider runtime commit together.
    public func persistForkedChildGraph(
        sourceThreadId: AgentThreadID,
        childThread: AgentThread,
        providerSession: ProviderSessionRuntime?,
        forkIntentChildThreadId: AgentThreadID? = nil
    ) throws {
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
                        return
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
                try upsert(childThread)

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
                        SET state = 'local_committed', last_error = NULL, updated_at = ?
                        WHERE child_thread_id = ? AND state = 'provider_created';
                    """)
                    try update.bind(1, iso.string(from: Date()))
                    try update.bind(2, forkIntentChildThreadId.value.uuidString)
                    _ = try update.step()
                }
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let childJSON = String(decoding: try encoder.encode(childThread), as: UTF8.self)
        try db.performSync { database in
            try database.transaction {
                guard try get(id: sourceThreadId) != nil else {
                    throw AgentThreadForkPersistenceError.sourceThreadNotFound
                }
                let sourceMessages = try AgentMessageRepository(db: database).list(threadId: sourceThreadId)
                let sourceMessagesJSON = String(decoding: try encoder.encode(sourceMessages), as: UTF8.self)
                let insert = try database.prepare("""
                    INSERT OR IGNORE INTO agent_thread_fork_intents(
                        child_thread_id, source_thread_id, provider, idempotency_key,
                        state, child_thread_json, source_messages_json, provider_child_thread_id,
                        last_error, created_at, updated_at
                    ) VALUES(?, ?, ?, ?, 'prepared', ?, ?, NULL, NULL, ?, ?);
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
            }
        }
        guard let intent = try getForkIntent(childThreadId: childThread.id),
              intent.sourceThreadId == sourceThreadId,
              intent.provider == childThread.provider,
              intent.idempotencyKey == idempotencyKey else {
            throw AgentThreadForkPersistenceError.intentConflict
        }
        return intent
    }

    public func getForkIntent(childThreadId: AgentThreadID) throws -> AgentThreadForkIntent? {
        let statement = try db.prepare("""
            SELECT source_thread_id, provider, idempotency_key, state,
                   child_thread_json, source_messages_json, provider_child_thread_id, last_error,
                   created_at, updated_at
            FROM agent_thread_fork_intents WHERE child_thread_id = ?;
        """)
        try statement.bind(1, childThreadId.value.uuidString)
        guard try statement.step() else { return nil }
        guard let sourceUUID = UUID(uuidString: statement.columnText(0) ?? ""),
              let provider = AgentProvider(rawValue: statement.columnText(1) ?? ""),
              let state = AgentThreadForkIntentState(rawValue: statement.columnText(3) ?? ""),
              let childJSON = statement.columnText(4)?.data(using: .utf8),
              let sourceMessagesJSON = statement.columnText(5)?.data(using: .utf8),
              let childThread = try? JSONDecoder().decode(AgentThread.self, from: childJSON),
              let sourceMessages = try? JSONDecoder().decode([AgentMessage].self, from: sourceMessagesJSON) else {
            throw AgentThreadForkPersistenceError.corruptIntent
        }
        return AgentThreadForkIntent(
            sourceThreadId: AgentThreadID(sourceUUID),
            childThread: childThread,
            sourceMessages: sourceMessages,
            provider: provider,
            idempotencyKey: statement.columnText(2) ?? "",
            state: state,
            providerChildThreadId: statement.columnText(6),
            lastError: statement.columnText(7),
            createdAt: parseDate(statement.columnText(8)),
            updatedAt: parseDate(statement.columnText(9))
        )
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

    @discardableResult
    public func recordForkProviderCreated(
        childThreadId: AgentThreadID,
        providerChildThreadId: String,
        at date: Date = Date()
    ) throws -> AgentThreadForkIntent {
        let update = try db.prepare("""
            UPDATE agent_thread_fork_intents
            SET state = 'provider_created', provider_child_thread_id = ?,
                last_error = NULL, updated_at = ?
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

    public func markForkCompensated(childThreadId: AgentThreadID, at date: Date = Date()) throws {
        let update = try db.prepare("""
            UPDATE agent_thread_fork_intents
            SET state = 'compensated', last_error = NULL, updated_at = ?
            WHERE child_thread_id = ? AND state = 'compensating';
        """)
        try update.bind(1, iso.string(from: date))
        try update.bind(2, childThreadId.value.uuidString)
        _ = try update.step()
        guard try getForkIntent(childThreadId: childThreadId)?.state == .compensated else {
            throw AgentThreadForkPersistenceError.intentConflict
        }
    }

    public func markPreparedForkAbandoned(childThreadId: AgentThreadID, error: String, at date: Date = Date()) throws {
        let update = try db.prepare("""
            UPDATE agent_thread_fork_intents
            SET state = 'abandoned', last_error = ?, updated_at = ?
            WHERE child_thread_id = ? AND state = 'prepared' AND provider_child_thread_id IS NULL;
        """)
        try update.bind(1, error)
        try update.bind(2, iso.string(from: date))
        try update.bind(3, childThreadId.value.uuidString)
        _ = try update.step()
        guard try getForkIntent(childThreadId: childThreadId)?.state == .abandoned else {
            throw AgentThreadForkPersistenceError.intentConflict
        }
    }

    public func recordForkIntentError(childThreadId: AgentThreadID, error: String, at date: Date = Date()) throws {
        let update = try db.prepare("""
            UPDATE agent_thread_fork_intents SET last_error = ?, updated_at = ?
            WHERE child_thread_id = ? AND state != 'local_committed' AND state != 'compensated';
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
        for id in ids { try delete(id: id) }
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
    case providerIdentityConflict
    case childThreadConflict
    case invalidIntentState(AgentThreadForkIntentState)
    case corruptIntent
}

public struct AgentMessageBodyBudgetResult: Sendable, Equatable {
    public var rows: [AgentMessage]
    public var blanked: Int

    public init(rows: [AgentMessage], blanked: Int) {
        self.rows = rows
        self.blanked = blanked
    }
}

public final class AgentMessageRepository {
    let db: SQLiteDB
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(db: SQLiteDB) { self.db = db }

    public func append(_ m: AgentMessage) throws {
        let st = try db.prepare("INSERT OR REPLACE INTO agent_messages(id, thread_id, role, content, created_at, attachments_json) VALUES(?, ?, ?, ?, ?, ?);")
        try st.bind(1, m.id.value.uuidString)
        try st.bind(2, m.threadId.value.uuidString)
        try st.bind(3, m.role.rawValue)
        try st.bind(4, m.content)
        try st.bind(5, iso.string(from: m.createdAt))
        try st.bind(6, try attachmentsJSON(m.attachments))
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
            SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at
            FROM agent_queued_messages
            WHERE thread_id = ?
            ORDER BY position ASC, created_at ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        var out: [AgentQueuedMessage] = []
        while try st.step() {
            out.append(decodeRow(st))
        }
        return out
    }

    public func first(threadId: AgentThreadID) throws -> AgentQueuedMessage? {
        let st = try db.prepare("""
            SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at
            FROM agent_queued_messages
            WHERE thread_id = ?
            ORDER BY position ASC, created_at ASC
            LIMIT 1;
        """)
        try st.bind(1, threadId.value.uuidString)
        return try st.step() ? decodeRow(st) : nil
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
    public func releasePrepared(_ lease: AgentQueuedMessageLease, runId: AgentRunID) throws -> Bool {
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
            try normalizePositions(threadId: lease.message.threadId)
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
        return AgentQueuedMessageDispatch(message: decodeRow(st), state: state, runId: runId)
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
            SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at
            FROM agent_queued_messages
            WHERE id = ?;
        """)
        try st.bind(1, id.value.uuidString)
        return try st.step() ? decodeRow(st) : nil
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

    public func promoteToFront(id: AgentQueuedMessageID) throws -> AgentQueuedMessage? {
        try db.performSync { database in
            try database.transaction {
            guard let target = try get(id: id),
                  try !threadHasActiveLease(target.threadId) else { return nil }
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

    private func decodeRow(_ st: SQLiteStatement) -> AgentQueuedMessage {
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
        message.routingSnapshot = try? routingSnapshot(id: message.id)
        return message
    }
}

public final class AgentRunRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

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

    public func reconcileRunningOnLaunch() throws -> Int {
        let countBefore = try countRunning()
        let st = try db.prepare("UPDATE agent_runs SET status='interrupted', finished_at=? WHERE status='running';")
        try st.bind(1, iso.string(from: Date()))
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
        let st = try db.prepare("INSERT INTO agent_stream_events(run_id, seq, event_kind, payload_json, created_at) VALUES(?, ?, ?, ?, ?);")
        try st.bind(1, runId.value.uuidString)
        try st.bind(2, Int64(seq))
        try st.bind(3, kind)
        try st.bind(4, payloadJSON)
        try st.bind(5, iso.string(from: Date()))
        _ = try st.step()
    }

    /// Highest durable sequence already committed for `runId`, or `0` when none.
    /// Used to seed in-memory allocation after process relaunch or ownership repair
    /// so a retry cannot reuse seq 1 for a different event kind.
    public func maxStreamEventSeq(runId: AgentRunID) throws -> Int {
        let st = try db.prepare(
            "SELECT COALESCE(MAX(seq), 0) FROM agent_stream_events WHERE run_id = ?;"
        )
        try st.bind(1, runId.value.uuidString)
        return (try st.step()) ? Int(st.columnInt64(0)) : 0
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
        shouldPruneStreamEvents: Bool
    ) throws {
        guard !items.isEmpty || shouldPruneStreamEvents else { return }
        try db.performSync { db in
            try db.transaction {
                for item in items {
                    try persistStreamEventIdempotently(db: db, runId: runId, item: item)
                    if let providerEvent = item.providerEvent {
                        try persistProviderEventIdempotently(
                            db: db,
                            threadId: threadId,
                            runId: runId,
                            event: providerEvent
                        )
                    }
                }
                if shouldPruneStreamEvents {
                    try pruneStreamEvents(db: db, threadId: threadId, keepLatest: 5_000)
                }
            }
        }
    }

    public func appendProviderEventLog(threadId: AgentThreadID, runId: AgentRunID?, event: ProviderRuntimeEvent) throws {
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
        try st.bind(10, event.payloadJSON)
        try st.bind(11, Int64(event.receivedAtMs))
        try st.bind(12, iso.string(from: Date()))
        _ = try st.step()
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
            events.append(ProviderRuntimeEvent(
                id: id,
                provider: provider,
                source: source,
                method: method,
                providerTurnId: st.columnText(4),
                providerItemId: st.columnText(5),
                providerRequestId: st.columnText(6),
                payloadJSON: payload,
                receivedAtMs: Int64(st.columnInt64(8))
            ))
        }
        return events
    }

    public func pruneProviderEventLogs(threadId: AgentThreadID, keepLatest limit: Int = 10_000) throws {
        guard limit > 0 else { return }
        let st = try db.prepare("""
            DELETE FROM agent_provider_event_logs
            WHERE id IN (
                SELECT id FROM (
                    SELECT id
                    FROM agent_provider_event_logs
                    WHERE thread_id = ?
                    ORDER BY id DESC
                    LIMIT -1 OFFSET ?
                )
            );
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(limit))
        _ = try st.step()
    }

    public func pruneStreamEvents(threadId: AgentThreadID, keepLatest limit: Int = 5_000) throws {
        guard limit > 0 else { return }
        try pruneStreamEvents(db: db, threadId: threadId, keepLatest: limit)
    }

    private func persistStreamEventIdempotently(
        db: SQLiteDB,
        runId: AgentRunID,
        item: StreamWriteIntent
    ) throws {
        let existing = try db.prepare("SELECT event_kind, payload_json FROM agent_stream_events WHERE run_id = ? AND seq = ? LIMIT 1;")
        try existing.bind(1, runId.value.uuidString)
        try existing.bind(2, Int64(item.seq))
        if try existing.step() {
            let existingKind = existing.columnText(0)
            let existingPayload = existing.columnText(1)
            guard existingKind == item.kind,
                  existingPayload == item.payloadJSON else {
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
        try insert.bind(3, item.kind)
        try insert.bind(4, item.payloadJSON)
        try insert.bind(5, iso.string(from: Date()))
        _ = try insert.step()
    }

    private func persistProviderEventIdempotently(
        db: SQLiteDB,
        threadId: AgentThreadID,
        runId: AgentRunID,
        event: ProviderRuntimeEvent
    ) throws {
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
                  existing.columnText(6) == event.payloadJSON,
                  existing.columnInt64(7) == Int64(event.receivedAtMs) else {
                throw SQLiteError.execute("Conflicting provider event identity for thread \(threadId.value.uuidString) event \(event.id).")
            }
            return
        }

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
        try insert.bind(10, event.payloadJSON)
        try insert.bind(11, Int64(event.receivedAtMs))
        try insert.bind(12, iso.string(from: Date()))
        _ = try insert.step()
    }

    private func pruneStreamEvents(db: SQLiteDB, threadId: AgentThreadID, keepLatest limit: Int) throws {
        guard limit > 0 else { return }
        let st = try db.prepare("""
            DELETE FROM agent_stream_events
            WHERE id IN (
                SELECT id FROM (
                    SELECT e.id
                    FROM agent_stream_events e
                    JOIN agent_runs r ON r.id = e.run_id
                    WHERE r.thread_id = ?
                    ORDER BY r.started_at DESC, e.seq DESC, e.id DESC
                    LIMIT -1 OFFSET ?
                )
            );
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(limit))
        _ = try st.step()
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
        strictDecoding: Bool = false
    ) throws -> [AssistantEvent] {
        let st = try db.prepare("""
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
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(limit))
        var events: [AssistantEvent] = []
        let decoder = JSONDecoder()
        while try st.step() {
            let eventId = st.columnInt64(1)
            guard let json = st.columnText(0),
                  let data = json.data(using: .utf8) else {
                if strictDecoding {
                    throw PersistenceDataError.corruptStreamEvent("row \(eventId) has no UTF-8 payload")
                }
                continue
            }
            do {
                events.append(try decoder.decode(AssistantEvent.self, from: data))
            } catch {
                if strictDecoding {
                    throw PersistenceDataError.corruptStreamEvent("row \(eventId) has an invalid AssistantEvent payload")
                }
            }
        }
        return events
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

    public init(db: SQLiteDB) { self.db = db }

    public func upsert(_ checkpoint: AgentTurnCheckpointSummary) throws {
        let filesData = try encoder.encode(checkpoint.files)
        let filesJSON = String(data: filesData, encoding: .utf8) ?? "[]"
        let snapshotsData = try encoder.encode(checkpoint.fileSnapshots)
        let snapshotsJSON = String(data: snapshotsData, encoding: .utf8) ?? "[]"
        let fileDiffsData = try encoder.encode(checkpoint.fileDiffs)
        let fileDiffsJSON = String(data: fileDiffsData, encoding: .utf8) ?? "[]"
        let now = iso.string(from: Date())
        let st = try db.prepare("""
            INSERT INTO agent_turn_checkpoints(thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status, files_json, assistant_message_id, error_message, completed_at, created_at, file_snapshots_json, diff_patch, file_diffs_json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id, turn_id) DO UPDATE SET
                run_id=excluded.run_id,
                checkpoint_turn_count=excluded.checkpoint_turn_count,
                checkpoint_ref=excluded.checkpoint_ref,
                status=excluded.status,
                files_json=excluded.files_json,
                file_snapshots_json=excluded.file_snapshots_json,
                diff_patch=excluded.diff_patch,
                file_diffs_json=excluded.file_diffs_json,
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
        try st.bind(10, iso.string(from: checkpoint.completedAt))
        try st.bind(11, now)
        try st.bind(12, snapshotsJSON)
        try st.bind(13, checkpoint.diffPatch)
        try st.bind(14, fileDiffsJSON)
        _ = try st.step()
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
    public init(db: SQLiteDB) { self.db = db }

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
        guard var session = try get(threadId: threadId) else { return }
        session.lastEventKind = lastEventKind ?? session.lastEventKind
        session.lastErrorMessage = lastErrorMessage ?? session.lastErrorMessage
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
            try atomicWrite(JSONEncoder().encode(anchor), to: url)
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
                JSONEncoder().encode(pending),
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
                JSONEncoder().encode(TerminalHistoryPendingDelete(
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
        guard let anchor = try? JSONDecoder().decode(
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
        guard let pending = try? JSONDecoder().decode(
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

    private static func totalBytes(surfaceID: String, database: SQLiteDB) throws -> Int {
        let st = try database.prepare(
            "SELECT COALESCE(SUM(byte_count), 0) FROM terminal_output_chunks WHERE surface_id = ?;"
        )
        try st.bind(1, surfaceID)
        return (try st.step()) ? Int(st.columnInt64(0)) : 0
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
        guard let data = value.data(using: .utf8),
              let state = try? JSONDecoder().decode(TerminalHistoryPartialState.self, from: data) else {
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
        let encoded = try JSONEncoder().encode(state)
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
        var total = try totalBytes(surfaceID: surfaceID, database: database)
        var pruned = false
        while total > maxBytes {
            let oldest = try database.prepare("""
                SELECT id, byte_count
                FROM terminal_output_chunks
                WHERE surface_id = ?
                ORDER BY id ASC
                LIMIT 1;
            """)
            try oldest.bind(1, surfaceID)
            guard try oldest.step() else { return pruned }
            let id = oldest.columnInt64(0)
            let bytes = Int(oldest.columnInt64(1))
            let delete = try database.prepare("""
                DELETE FROM terminal_output_chunks
                WHERE surface_id = ? AND id = ?;
            """)
            try delete.bind(1, surfaceID)
            try delete.bind(2, id)
            _ = try delete.step()
            let nextTotal = max(0, total - max(0, bytes))
            guard nextTotal < total else { return pruned }
            total = nextTotal
            pruned = true
        }
        return pruned
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
    public init(db: SQLiteDB) { self.db = db }

    public func save(_ snap: SessionSnapshot) throws {
        let data = try JSONEncoder().encode(snap)
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
        guard let found = SessionSnapshotRepository.firstDecodable(blobs, decode: { data in
            try? JSONDecoder().decode(SessionSnapshot.self, from: data)
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
