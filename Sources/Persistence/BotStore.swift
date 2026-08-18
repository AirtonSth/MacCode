import Foundation
import CoreModel

public enum BotStoreError: Error, Equatable, CustomStringConvertible {
    case notFound
    case invalidRow(String)

    public var description: String {
        switch self {
        case .notFound: return "Bot was not found."
        case .invalidRow(let message): return "Invalid bot row: \(message)"
        }
    }
}

public final class BotStore: @unchecked Sendable {
    private let db: SQLiteDB
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let dates = LockedISO8601Formatter({
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }())

    public init(db: SQLiteDB) {
        self.db = db
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func list(includeHidden: Bool = false, includeDeleted: Bool = false) throws -> [BotDefinition] {
        try db.performSync { database in
            var sql = Self.botSelect + " WHERE 1=1"
            if !includeDeleted { sql += " AND deleted_at IS NULL" }
            if !includeHidden { sql += " AND (hidden = 0 OR deleted_at IS NOT NULL)" }
            sql += " ORDER BY updated_at DESC;"
            let statement = try database.prepare(sql)
            defer { statement.reset() }
            var result: [BotDefinition] = []
            while try statement.step() { result.append(try decodeBot(statement)) }
            return result
        }
    }

    public func get(id: BotID) throws -> BotDefinition? {
        try db.performSync { database in
            try loadBot(id: id, database: database)
        }
    }

    public func getRevision(id: BotRevisionID) throws -> BotRevision? {
        try db.performSync { database in
            let statement = try database.prepare(Self.revisionSelect + " WHERE id = ? LIMIT 1;")
            defer { statement.reset() }
            try statement.bind(1, id.value.uuidString.lowercased())
            return try statement.step() ? try decodeRevision(statement) : nil
        }
    }

    public func create(
        name: String,
        title: String,
        description: String,
        handle: String? = nil,
        avatarSymbol: String = "person.crop.circle",
        soul: String = "",
        provider: AgentProvider,
        providerInstanceID: String? = nil,
        model: String = "",
        reasoningEffort: AgentReasoningEffort = .medium,
        compatibleRouteSet: [String] = ["default"],
        desktopKind: BotDesktopKind = .logicalExecutionSpace,
        workspaceID: WorkspaceID? = nil,
        notificationsEnabled: Bool = true,
        now: Date = Date()
    ) throws -> BotDefinition {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw BotPublishError.invalidRevision }
        let routes = normalizedRoutes(compatibleRouteSet)
        guard !routes.isEmpty else { throw BotPublishError.invalidRevision }
        let draft = BotRevisionDraft(
            name: trimmedName,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            soul: soul,
            provider: provider,
            providerInstanceID: (providerInstanceID ?? provider.rawValue)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            reasoningEffort: reasoningEffort,
            compatibleRouteSet: routes,
            permissionMode: .supervised,
            desktopKind: desktopKind
        )
        let botID = BotID()
        let revisionID = BotRevisionID()
        let revision = makeRevision(
            id: revisionID,
            botID: botID,
            revisionNumber: 1,
            draft: draft,
            publishedAt: now,
            supersedes: nil
        )
        var created: BotDefinition!
        try db.transaction {
            try assertLiveCapacity(database: db, additional: 1)
            let resolvedHandle: String
            if let handle {
                resolvedHandle = try resolveHandle(handle, fallback: trimmedName)
                try assertHandleAvailable(resolvedHandle, database: db)
            } else {
                resolvedHandle = try allocateUniqueHandle(stem: trimmedName, database: db)
            }
            let bot = BotDefinition(
                id: botID,
                handle: resolvedHandle,
                name: draft.name,
                title: draft.title,
                description: draft.description,
                avatarSymbol: avatarSymbol,
                currentRevisionID: revisionID,
                directoryEpoch: 1,
                notificationsEnabled: notificationsEnabled,
                createdAt: now,
                updatedAt: now,
                workspaceID: workspaceID
            )
            created = bot
            try insertBot(bot, currentRevisionID: nil, database: db)
            try insertRevision(revision, database: db)
            try setCurrentRevision(
                botID: botID,
                revisionID: revisionID,
                name: draft.name,
                title: draft.title,
                description: draft.description,
                avatarSymbol: avatarSymbol,
                notificationsEnabled: notificationsEnabled,
                updatedAt: now,
                database: db
            )
            try insertLiveHandle(bot.handle, botID: botID, at: now, database: db)
        }
        return created
    }

    public func updateProfile(
        id: BotID,
        name: String? = nil,
        title: String? = nil,
        description: String? = nil,
        avatarSymbol: String? = nil,
        notificationsEnabled: Bool? = nil,
        now: Date = Date()
    ) throws -> BotDefinition {
        try db.transaction {
            guard let bot = try loadBot(id: id, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            guard let currentID = bot.currentRevisionID,
                  let current = try loadRevision(id: currentID, database: db) else {
                throw BotPublishError.invalidRevision
            }
            let nextName = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? bot.name
            guard !nextName.isEmpty else { throw BotPublishError.invalidRevision }
            let draft = BotRevisionDraft(
                name: nextName,
                title: title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? current.title,
                description: description.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? current.description,
                soul: current.soul,
                provider: current.provider,
                providerInstanceID: current.providerInstanceID,
                model: current.model,
                reasoningEffort: current.reasoningEffort,
                compatibleRouteSet: current.compatibleRouteSet,
                permissionMode: current.permissionMode,
                desktopKind: current.desktopKind
            )
            _ = try publishLocked(
                bot: bot,
                expectedCurrentRevisionID: currentID,
                draft: draft,
                avatarSymbol: avatarSymbol ?? bot.avatarSymbol,
                notificationsEnabled: notificationsEnabled ?? bot.notificationsEnabled,
                now: now,
                database: db
            )
            guard let updated = try loadBot(id: id, database: db) else { throw BotStoreError.notFound }
            return updated
        }
    }

    public func setPinned(id: BotID, pinned: Bool, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare(
                "UPDATE bots SET pinned = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;"
            )
            defer { statement.reset() }
            try statement.bind(1, pinned)
            try statement.bind(2, string(now))
            try statement.bind(3, id.value.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    public func setHidden(id: BotID, hidden: Bool, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE bots
                SET hidden = ?, directory_epoch = directory_epoch + 1, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL;
                """)
            defer { statement.reset() }
            try statement.bind(1, hidden)
            try statement.bind(2, string(now))
            try statement.bind(3, id.value.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    public func publish(
        botID: BotID,
        expectedCurrentRevisionID: BotRevisionID?,
        draft: BotRevisionDraft,
        avatarSymbol: String? = nil,
        notificationsEnabled: Bool? = nil,
        now: Date = Date()
    ) throws -> BotRevision {
        try db.transaction {
            guard let bot = try loadBot(id: botID, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            return try publishLocked(
                bot: bot,
                expectedCurrentRevisionID: expectedCurrentRevisionID,
                draft: draft,
                avatarSymbol: avatarSymbol ?? bot.avatarSymbol,
                notificationsEnabled: notificationsEnabled ?? bot.notificationsEnabled,
                now: now,
                database: db
            )
        }
    }

    public func duplicate(id: BotID, now: Date = Date()) throws -> BotDefinition {
        try db.transaction {
            guard let source = try loadBot(id: id, database: db), source.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            try assertLiveCapacity(database: db, additional: 1)
            guard let currentID = source.currentRevisionID,
                  let current = try loadRevision(id: currentID, database: db) else {
                throw BotPublishError.invalidRevision
            }
            let copyName = "\(source.name) copy"
            let handle = try allocateUniqueHandle(stem: source.handle + "-copy", database: db)
            let botID = BotID()
            let revisionID = BotRevisionID()
            let draft = BotRevisionDraft(
                name: copyName,
                title: current.title,
                description: current.description,
                soul: current.soul,
                provider: current.provider,
                providerInstanceID: current.providerInstanceID,
                model: current.model,
                reasoningEffort: current.reasoningEffort,
                compatibleRouteSet: current.compatibleRouteSet,
                permissionMode: current.permissionMode,
                desktopKind: current.desktopKind
            )
            let revision = makeRevision(
                id: revisionID,
                botID: botID,
                revisionNumber: 1,
                draft: draft,
                publishedAt: now,
                supersedes: nil
            )
            let copy = BotDefinition(
                id: botID,
                handle: handle,
                name: copyName,
                title: current.title,
                description: current.description,
                avatarSymbol: source.avatarSymbol,
                currentRevisionID: revisionID,
                directoryEpoch: 1,
                notificationsEnabled: source.notificationsEnabled,
                createdAt: now,
                updatedAt: now,
                workspaceID: source.workspaceID
            )
            try insertBot(copy, currentRevisionID: nil, database: db)
            try insertRevision(revision, database: db)
            try setCurrentRevision(
                botID: botID,
                revisionID: revisionID,
                name: copyName,
                title: current.title,
                description: current.description,
                avatarSymbol: source.avatarSymbol,
                notificationsEnabled: source.notificationsEnabled,
                updatedAt: now,
                database: db
            )
            try insertLiveHandle(handle, botID: botID, at: now, database: db)
            for binding in try loadSkillBindings(botID: source.id, database: db) {
                try upsertSkillBinding(
                    BotSkillBinding(
                        botID: botID,
                        skillID: binding.skillID,
                        enabled: binding.enabled,
                        digest: binding.digest,
                        updatedAt: now
                    ),
                    database: db
                )
            }
            let routines = try loadRoutines(botID: source.id, database: db)
            for routine in routines {
                let newID = BotRoutineID()
                let definition = BotRoutineDefinition(
                    id: newID,
                    botID: botID,
                    name: routine.definition.name,
                    prompt: routine.definition.prompt,
                    scheduleNote: routine.definition.scheduleNote,
                    createdAt: now,
                    updatedAt: now
                )
                try insertRoutine(definition, database: db)
                try upsertActivation(
                    BotRoutineActivation(
                        routineID: newID,
                        botID: botID,
                        isEnabled: routine.activation.isEnabled,
                        lastTestRunRequestedAt: nil,
                        updatedAt: now
                    ),
                    database: db
                )
            }
            return copy
        }
    }

    public func delete(id: BotID, now: Date = Date()) throws {
        try db.transaction {
            guard let bot = try loadBot(id: id, database: db) else { throw BotStoreError.notFound }
            if bot.deletedAt != nil { return }
            let update = try db.prepare("""
                UPDATE bots
                SET deleted_at = ?, hidden = 1, directory_epoch = directory_epoch + 1, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL;
                """)
            defer { update.reset() }
            try update.bind(1, string(now))
            try update.bind(2, string(now))
            try update.bind(3, id.value.uuidString.lowercased())
            _ = try update.step()

            let dropHandle = try db.prepare("DELETE FROM bot_handles WHERE bot_id = ?;")
            defer { dropHandle.reset() }
            try dropHandle.bind(1, id.value.uuidString.lowercased())
            _ = try dropHandle.step()

            let tombstone = try db.prepare("""
                INSERT OR IGNORE INTO bot_handle_tombstones(handle, bot_id, deleted_at)
                VALUES(?, ?, ?);
                """)
            defer { tombstone.reset() }
            try tombstone.bind(1, bot.handle)
            try tombstone.bind(2, id.value.uuidString.lowercased())
            try tombstone.bind(3, string(now))
            _ = try tombstone.step()

            try executeBound("DELETE FROM bot_conversations WHERE bot_id = ?;", id: id)
            try executeBound("DELETE FROM bot_skill_bindings WHERE bot_id = ?;", id: id)
            try executeBound("DELETE FROM bot_routine_activations WHERE bot_id = ?;", id: id)
            try executeBound("DELETE FROM bot_routine_definitions WHERE bot_id = ?;", id: id)
        }
    }

    public func conversationLinked(to threadID: AgentThreadID) throws -> BotConversation? {
        try db.performSync { database in
            let statement = try database.prepare(
                Self.conversationSelect + " WHERE linked_agent_thread_id = ? LIMIT 1;"
            )
            defer { statement.reset() }
            try statement.bind(1, threadID.value.uuidString.lowercased())
            return try statement.step() ? try decodeConversation(statement) : nil
        }
    }

    public func listConversations(botID: BotID) throws -> [BotConversation] {
        try db.performSync { database in
            let statement = try database.prepare(
                Self.conversationSelect + " WHERE bot_id = ? ORDER BY updated_at DESC;"
            )
            defer { statement.reset() }
            try statement.bind(1, botID.value.uuidString.lowercased())
            var result: [BotConversation] = []
            while try statement.step() { result.append(try decodeConversation(statement)) }
            return result
        }
    }

    public func upsertConversation(_ conversation: BotConversation) throws {
        try db.performSync { database in
            guard let bot = try loadBot(id: conversation.botID, database: database), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            let statement = try database.prepare("""
                INSERT INTO bot_conversations(
                    id, bot_id, title, pinned, hidden, unread, attention_state,
                    linked_agent_thread_id, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title=excluded.title, pinned=excluded.pinned, hidden=excluded.hidden,
                    unread=excluded.unread, attention_state=excluded.attention_state,
                    linked_agent_thread_id=excluded.linked_agent_thread_id,
                    updated_at=excluded.updated_at;
                """)
            defer { statement.reset() }
            try statement.bind(1, conversation.id.value.uuidString.lowercased())
            try statement.bind(2, conversation.botID.value.uuidString.lowercased())
            try statement.bind(3, conversation.title)
            try statement.bind(4, conversation.pinned)
            try statement.bind(5, conversation.hidden)
            try statement.bind(6, conversation.unread)
            try statement.bind(7, conversation.attentionState.rawValue)
            try statement.bind(8, conversation.linkedAgentThreadID?.value.uuidString.lowercased())
            try statement.bind(9, string(conversation.createdAt))
            try statement.bind(10, string(conversation.updatedAt))
            _ = try statement.step()
        }
    }

    public func listMemory(botID: BotID, includeForgotten: Bool = false) throws -> [BotMemoryItem] {
        try db.performSync { database in
            var sql = Self.memorySelect + " WHERE i.bot_id = ?"
            if !includeForgotten { sql += " AND i.forgotten_at IS NULL" }
            sql += " ORDER BY i.updated_at DESC;"
            let statement = try database.prepare(sql)
            defer { statement.reset() }
            try statement.bind(1, botID.value.uuidString.lowercased())
            var result: [BotMemoryItem] = []
            while try statement.step() { result.append(try decodeMemory(statement)) }
            return result
        }
    }

    public func getMemory(id: BotMemoryItemID) throws -> BotMemoryItem? {
        try db.performSync { database in
            let statement = try database.prepare(Self.memorySelect + " WHERE i.id = ? LIMIT 1;")
            defer { statement.reset() }
            try statement.bind(1, id.value.uuidString.lowercased())
            return try statement.step() ? try decodeMemory(statement) : nil
        }
    }

    public func listMemoryRevisions(itemID: BotMemoryItemID) throws -> [BotMemoryItemRevision] {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT id, item_id, bot_id, revision_number, content, provenance, trusted, source,
                       created_at, supersedes_revision_id
                FROM bot_memory_item_revisions
                WHERE item_id = ?
                ORDER BY revision_number ASC;
                """)
            defer { statement.reset() }
            try statement.bind(1, itemID.value.uuidString.lowercased())
            var result: [BotMemoryItemRevision] = []
            while try statement.step() { result.append(try decodeMemoryRevision(statement)) }
            return result
        }
    }

    public func putMemory(
        botID: BotID,
        content: String,
        provenance: String,
        trusted: Bool,
        source: String,
        expiresAt: Date? = nil,
        now: Date = Date()
    ) throws -> BotMemoryItem {
        try db.transaction {
            guard let bot = try loadBot(id: botID, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            let itemID = BotMemoryItemID()
            let revisionID = UUID()
            let insertItem = try db.prepare("""
                INSERT INTO bot_memory_items(
                    id, bot_id, current_revision_id, forgotten_at, expires_at, created_at, updated_at
                ) VALUES(?, ?, ?, NULL, ?, ?, ?);
                """)
            defer { insertItem.reset() }
            try insertItem.bind(1, itemID.value.uuidString.lowercased())
            try insertItem.bind(2, botID.value.uuidString.lowercased())
            try insertItem.bind(3, revisionID.uuidString.lowercased())
            try insertItem.bind(4, string(expiresAt))
            try insertItem.bind(5, string(now))
            try insertItem.bind(6, string(now))
            _ = try insertItem.step()
            try insertMemoryRevision(
                BotMemoryItemRevision(
                    id: revisionID,
                    itemID: itemID,
                    botID: botID,
                    revisionNumber: 1,
                    content: content,
                    provenance: provenance,
                    trusted: trusted,
                    source: source,
                    createdAt: now
                ),
                database: db
            )
            return BotMemoryItem(
                id: itemID,
                botID: botID,
                currentRevisionID: revisionID,
                content: content,
                provenance: provenance,
                trusted: trusted,
                source: source,
                expiresAt: expiresAt,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    public func correctMemory(
        id: BotMemoryItemID,
        content: String,
        provenance: String? = nil,
        trusted: Bool? = nil,
        source: String? = nil,
        now: Date = Date()
    ) throws -> BotMemoryItem {
        try db.transaction {
            guard var item = try loadMemory(id: id, database: db) else { throw BotStoreError.notFound }
            if item.forgottenAt != nil { throw BotStoreError.invalidRow("forgotten memory cannot be rewritten") }
            let nextNumber = try nextMemoryRevisionNumber(itemID: id, database: db)
            let revisionID = UUID()
            try insertMemoryRevision(
                BotMemoryItemRevision(
                    id: revisionID,
                    itemID: id,
                    botID: item.botID,
                    revisionNumber: nextNumber,
                    content: content,
                    provenance: provenance ?? item.provenance,
                    trusted: trusted ?? item.trusted,
                    source: source ?? item.source,
                    createdAt: now,
                    supersedesRevisionID: item.currentRevisionID
                ),
                database: db
            )
            let update = try db.prepare("""
                UPDATE bot_memory_items
                SET current_revision_id = ?, updated_at = ?
                WHERE id = ?;
                """)
            defer { update.reset() }
            try update.bind(1, revisionID.uuidString.lowercased())
            try update.bind(2, string(now))
            try update.bind(3, id.value.uuidString.lowercased())
            _ = try update.step()
            item.currentRevisionID = revisionID
            item.content = content
            item.provenance = provenance ?? item.provenance
            item.trusted = trusted ?? item.trusted
            item.source = source ?? item.source
            item.updatedAt = now
            return item
        }
    }

    public func forgetMemory(id: BotMemoryItemID, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE bot_memory_items
                SET forgotten_at = COALESCE(forgotten_at, ?), updated_at = ?
                WHERE id = ?;
                """)
            defer { statement.reset() }
            try statement.bind(1, string(now))
            try statement.bind(2, string(now))
            try statement.bind(3, id.value.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    public func listAttention(includeAcknowledged: Bool = false) throws -> [BotAttentionItem] {
        try db.performSync { database in
            var sql = Self.attentionSelect
            if !includeAcknowledged { sql += " WHERE acknowledged_at IS NULL" }
            sql += " ORDER BY created_at DESC;"
            let statement = try database.prepare(sql)
            defer { statement.reset() }
            var result: [BotAttentionItem] = []
            while try statement.step() { result.append(try decodeAttention(statement)) }
            return result
        }
    }

    public func upsertAttention(_ item: BotAttentionItem) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                INSERT INTO bot_attention_items(
                    id, bot_id, conversation_id, kind, title, detail, created_at, acknowledged_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    kind=excluded.kind, title=excluded.title, detail=excluded.detail,
                    conversation_id=excluded.conversation_id, acknowledged_at=excluded.acknowledged_at;
                """)
            defer { statement.reset() }
            try statement.bind(1, item.id.value.uuidString.lowercased())
            try statement.bind(2, item.botID.value.uuidString.lowercased())
            try statement.bind(3, item.conversationID?.value.uuidString.lowercased())
            try statement.bind(4, item.kind.rawValue)
            try statement.bind(5, item.title)
            try statement.bind(6, item.detail)
            try statement.bind(7, string(item.createdAt))
            try statement.bind(8, string(item.acknowledgedAt))
            _ = try statement.step()
        }
    }

    public func acknowledgeAttention(id: BotAttentionItemID, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE bot_attention_items
                SET acknowledged_at = COALESCE(acknowledged_at, ?)
                WHERE id = ?;
                """)
            defer { statement.reset() }
            try statement.bind(1, string(now))
            try statement.bind(2, id.value.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    public func listRoutines(botID: BotID) throws -> [BotRoutine] {
        try db.performSync { database in
            try loadRoutines(botID: botID, database: database)
        }
    }

    public func saveRoutine(_ definition: BotRoutineDefinition, now: Date = Date()) throws {
        try db.transaction {
            guard let bot = try loadBot(id: definition.botID, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            try insertRoutine(definition, database: db)
            if try loadActivation(routineID: definition.id, database: db) == nil {
                try upsertActivation(
                    BotRoutineActivation(
                        routineID: definition.id,
                        botID: definition.botID,
                        isEnabled: false,
                        updatedAt: now
                    ),
                    database: db
                )
            }
        }
    }

    public func setRoutineEnabled(id: BotRoutineID, enabled: Bool, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE bot_routine_activations
                SET is_enabled = ?, updated_at = ?
                WHERE routine_id = ?;
                """)
            defer { statement.reset() }
            try statement.bind(1, enabled)
            try statement.bind(2, string(now))
            try statement.bind(3, id.value.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    public func deleteRoutine(id: BotRoutineID) throws {
        try db.transaction {
            let key = id.value.uuidString.lowercased()
            let activation = try db.prepare("DELETE FROM bot_routine_activations WHERE routine_id = ?;")
            defer { activation.reset() }
            try activation.bind(1, key)
            _ = try activation.step()
            let definition = try db.prepare("DELETE FROM bot_routine_definitions WHERE id = ?;")
            defer { definition.reset() }
            try definition.bind(1, key)
            _ = try definition.step()
        }
    }

    public func requestRoutineTestRun(id: BotRoutineID, now: Date = Date()) throws {
        try db.performSync { database in
            let statement = try database.prepare("""
                UPDATE bot_routine_activations
                SET last_test_run_requested_at = ?, updated_at = ?
                WHERE routine_id = ?;
                """)
            defer { statement.reset() }
            try statement.bind(1, string(now))
            try statement.bind(2, string(now))
            try statement.bind(3, id.value.uuidString.lowercased())
            _ = try statement.step()
        }
    }

    public func listSkillBindings(botID: BotID) throws -> [BotSkillBinding] {
        try db.performSync { database in
            try loadSkillBindings(botID: botID, database: database)
        }
    }

    public func insertContextReceipt(_ receipt: ContextAssemblyReceipt) throws {
        try db.performSync { database in
            let data = try encoder.encode(receipt)
            guard let json = String(data: data, encoding: .utf8) else {
                throw BotStoreError.invalidRow("context receipt is not UTF-8")
            }
            let statement = try database.prepare("""
                INSERT INTO bot_context_receipts(
                    id, bot_id, conversation_id, run_id, revision_id, payload_digest,
                    receipt_json, assembled_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    run_id=excluded.run_id,
                    receipt_json=excluded.receipt_json;
                """)
            defer { statement.reset() }
            try statement.bind(1, receipt.id.uuidString.lowercased())
            try statement.bind(2, receipt.botID.value.uuidString.lowercased())
            try statement.bind(3, receipt.conversationID?.value.uuidString.lowercased())
            try statement.bind(4, receipt.runID?.value.uuidString.lowercased())
            try statement.bind(5, receipt.revisionID.value.uuidString.lowercased())
            try statement.bind(6, receipt.payloadDigest)
            try statement.bind(7, json)
            try statement.bind(8, string(receipt.assembledAt))
            _ = try statement.step()
        }
    }

    public func latestContextReceipt(
        botID: BotID,
        conversationID: BotConversationID? = nil
    ) throws -> ContextAssemblyReceipt? {
        try db.performSync { database in
            let sql: String
            if conversationID != nil {
                sql = """
                    SELECT receipt_json FROM bot_context_receipts
                    WHERE bot_id = ? AND conversation_id = ?
                    ORDER BY assembled_at DESC LIMIT 1;
                    """
            } else {
                sql = """
                    SELECT receipt_json FROM bot_context_receipts
                    WHERE bot_id = ?
                    ORDER BY assembled_at DESC LIMIT 1;
                    """
            }
            let statement = try database.prepare(sql)
            defer { statement.reset() }
            try statement.bind(1, botID.value.uuidString.lowercased())
            if let conversationID {
                try statement.bind(2, conversationID.value.uuidString.lowercased())
            }
            guard try statement.step(), let json = statement.columnText(0),
                  let data = json.data(using: .utf8) else { return nil }
            return try decoder.decode(ContextAssemblyReceipt.self, from: data)
        }
    }

    public func setSkillBinding(_ binding: BotSkillBinding) throws {
        let skillID = binding.skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skillID.isEmpty, !skillID.contains("/") else {
            throw BotStoreError.invalidRow("skill id must be a catalog id, not a path")
        }
        try db.transaction {
            guard let bot = try loadBot(id: binding.botID, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            try upsertSkillBinding(
                BotSkillBinding(
                    botID: binding.botID,
                    skillID: skillID,
                    enabled: binding.enabled,
                    digest: binding.digest,
                    updatedAt: binding.updatedAt
                ),
                database: db
            )
        }
    }

    public func removeSkillBinding(botID: BotID, skillID: String) throws {
        let skillID = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skillID.isEmpty, !skillID.contains("/") else {
            throw BotStoreError.invalidRow("skill id must be a catalog id, not a path")
        }
        try db.transaction {
            guard let bot = try loadBot(id: botID, database: db), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            let statement = try db.prepare(
                "DELETE FROM bot_skill_bindings WHERE bot_id = ? AND skill_id = ?;"
            )
            defer { statement.reset() }
            try statement.bind(1, botID.value.uuidString.lowercased())
            try statement.bind(2, skillID)
            _ = try statement.step()
        }
    }

    // MARK: - Internals

    private func publishLocked(
        bot: BotDefinition,
        expectedCurrentRevisionID: BotRevisionID?,
        draft: BotRevisionDraft,
        avatarSymbol: String,
        notificationsEnabled: Bool,
        now: Date,
        database: SQLiteDB
    ) throws -> BotRevision {
        if bot.currentRevisionID != expectedCurrentRevisionID {
            throw BotPublishError.revisionConflict
        }
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let routes = normalizedRoutes(draft.compatibleRouteSet)
        guard !trimmedName.isEmpty, !routes.isEmpty else { throw BotPublishError.invalidRevision }
        let nextNumber = try nextRevisionNumber(botID: bot.id, database: database)
        let revisionID = BotRevisionID()
        let normalized = BotRevisionDraft(
            name: trimmedName,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            soul: draft.soul,
            provider: draft.provider,
            providerInstanceID: draft.providerInstanceID,
            model: draft.model,
            reasoningEffort: draft.reasoningEffort,
            compatibleRouteSet: routes,
            permissionMode: draft.permissionMode,
            desktopKind: draft.desktopKind
        )
        let revision = makeRevision(
            id: revisionID,
            botID: bot.id,
            revisionNumber: nextNumber,
            draft: normalized,
            publishedAt: now,
            supersedes: bot.currentRevisionID
        )
        try insertRevision(revision, database: database)
        try setCurrentRevision(
            botID: bot.id,
            revisionID: revisionID,
            name: normalized.name,
            title: normalized.title,
            description: normalized.description,
            avatarSymbol: avatarSymbol,
            notificationsEnabled: notificationsEnabled,
            updatedAt: now,
            database: database
        )
        return revision
    }

    private func makeRevision(
        id: BotRevisionID,
        botID: BotID,
        revisionNumber: Int,
        draft: BotRevisionDraft,
        publishedAt: Date,
        supersedes: BotRevisionID?
    ) -> BotRevision {
        BotRevision(
            id: id,
            botID: botID,
            revisionNumber: revisionNumber,
            name: draft.name,
            title: draft.title,
            description: draft.description,
            soul: draft.soul,
            provider: draft.provider,
            providerInstanceID: draft.providerInstanceID,
            model: draft.model,
            reasoningEffort: draft.reasoningEffort,
            compatibleRouteSet: draft.compatibleRouteSet,
            permissionMode: draft.permissionMode,
            desktopKind: draft.desktopKind,
            digest: BotRevision.digest(botID: botID, draft: draft),
            publishedAt: publishedAt,
            supersedesRevisionID: supersedes
        )
    }

    private func resolveHandle(_ explicit: String?, fallback: String) throws -> String {
        if let explicit {
            guard let normalized = BotHandle.normalize(explicit) else { throw BotPublishError.handleEmpty }
            return normalized
        }
        guard let derived = BotHandle.derive(from: fallback) else { throw BotPublishError.handleEmpty }
        return derived
    }

    private func normalizedRoutes(_ routes: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for route in routes {
            let trimmed = route.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private func assertLiveCapacity(database: SQLiteDB, additional: Int) throws {
        let statement = try database.prepare("SELECT COUNT(*) FROM bots WHERE deleted_at IS NULL;")
        defer { statement.reset() }
        guard try statement.step() else { throw BotStoreError.invalidRow("live bot count") }
        if Int(statement.columnInt64(0)) + additional > BotDefinition.liveAccountCap {
            throw BotPublishError.accountCap
        }
    }

    private func assertHandleAvailable(_ handle: String, database: SQLiteDB) throws {
        if try handleIsTaken(handle, database: database) { throw BotPublishError.handleConflict }
    }

    private func handleIsTaken(_ handle: String, database: SQLiteDB) throws -> Bool {
        let live = try database.prepare("SELECT 1 FROM bot_handles WHERE handle = ? LIMIT 1;")
        defer { live.reset() }
        try live.bind(1, handle)
        if try live.step() { return true }
        let tombstone = try database.prepare("SELECT 1 FROM bot_handle_tombstones WHERE handle = ? LIMIT 1;")
        defer { tombstone.reset() }
        try tombstone.bind(1, handle)
        return try tombstone.step()
    }

    private func allocateUniqueHandle(stem: String, database: SQLiteDB) throws -> String {
        let base = BotHandle.derive(from: stem) ?? "bot"
        if try !handleIsTaken(base, database: database) { return base }
        for index in 2...999 {
            let suffix = "-\(index)"
            let prefix = String(base.prefix(BotHandle.maxLength - suffix.count))
            let candidate = prefix + suffix
            if try !handleIsTaken(candidate, database: database) { return candidate }
        }
        throw BotPublishError.handleConflict
    }

    private func insertBot(_ bot: BotDefinition, currentRevisionID: BotRevisionID?, database: SQLiteDB) throws {
        let statement = try database.prepare("""
            INSERT INTO bots(
                id, handle, name, title, description, avatar_symbol, pinned, hidden,
                current_revision_id, directory_epoch, notifications_enabled,
                created_at, updated_at, deleted_at, workspace_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { statement.reset() }
        try statement.bind(1, bot.id.value.uuidString.lowercased())
        try statement.bind(2, bot.handle)
        try statement.bind(3, bot.name)
        try statement.bind(4, bot.title)
        try statement.bind(5, bot.description)
        try statement.bind(6, bot.avatarSymbol)
        try statement.bind(7, bot.pinned)
        try statement.bind(8, bot.hidden)
        try statement.bind(9, currentRevisionID?.value.uuidString.lowercased())
        try statement.bind(10, bot.directoryEpoch)
        try statement.bind(11, bot.notificationsEnabled)
        try statement.bind(12, string(bot.createdAt))
        try statement.bind(13, string(bot.updatedAt))
        try statement.bind(14, string(bot.deletedAt))
        try statement.bind(15, bot.workspaceID?.value.uuidString.lowercased())
        _ = try statement.step()
    }

    private func insertRevision(_ revision: BotRevision, database: SQLiteDB) throws {
        let routes = try encodeRoutes(revision.compatibleRouteSet)
        let statement = try database.prepare("""
            INSERT INTO bot_revisions(
                id, bot_id, revision_number, name, title, description, soul, provider,
                provider_instance_id, model, reasoning_effort, compatible_route_set_json,
                permission_mode, desktop_kind, digest, published_at, supersedes_revision_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { statement.reset() }
        try statement.bind(1, revision.id.value.uuidString.lowercased())
        try statement.bind(2, revision.botID.value.uuidString.lowercased())
        try statement.bind(3, revision.revisionNumber)
        try statement.bind(4, revision.name)
        try statement.bind(5, revision.title)
        try statement.bind(6, revision.description)
        try statement.bind(7, revision.soul)
        try statement.bind(8, revision.provider.rawValue)
        try statement.bind(9, revision.providerInstanceID)
        try statement.bind(10, revision.model)
        try statement.bind(11, revision.reasoningEffort.rawValue)
        try statement.bind(12, routes)
        try statement.bind(13, revision.permissionMode.rawValue)
        try statement.bind(14, revision.desktopKind.rawValue)
        try statement.bind(15, revision.digest)
        try statement.bind(16, string(revision.publishedAt))
        try statement.bind(17, revision.supersedesRevisionID?.value.uuidString.lowercased())
        _ = try statement.step()
    }

    private func setCurrentRevision(
        botID: BotID,
        revisionID: BotRevisionID,
        name: String,
        title: String,
        description: String,
        avatarSymbol: String,
        notificationsEnabled: Bool,
        updatedAt: Date,
        database: SQLiteDB
    ) throws {
        let statement = try database.prepare("""
            UPDATE bots
            SET current_revision_id = ?, name = ?, title = ?, description = ?,
                avatar_symbol = ?, notifications_enabled = ?, updated_at = ?
            WHERE id = ?;
            """)
        defer { statement.reset() }
        try statement.bind(1, revisionID.value.uuidString.lowercased())
        try statement.bind(2, name)
        try statement.bind(3, title)
        try statement.bind(4, description)
        try statement.bind(5, avatarSymbol)
        try statement.bind(6, notificationsEnabled)
        try statement.bind(7, string(updatedAt))
        try statement.bind(8, botID.value.uuidString.lowercased())
        _ = try statement.step()
    }

    private func insertLiveHandle(_ handle: String, botID: BotID, at date: Date, database: SQLiteDB) throws {
        let statement = try database.prepare(
            "INSERT INTO bot_handles(handle, bot_id, created_at) VALUES(?, ?, ?);"
        )
        defer { statement.reset() }
        try statement.bind(1, handle)
        try statement.bind(2, botID.value.uuidString.lowercased())
        try statement.bind(3, string(date))
        _ = try statement.step()
    }

    private func insertRoutine(_ definition: BotRoutineDefinition, database: SQLiteDB) throws {
        let statement = try database.prepare("""
            INSERT INTO bot_routine_definitions(
                id, bot_id, name, prompt, schedule_note, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name=excluded.name, prompt=excluded.prompt, schedule_note=excluded.schedule_note,
                updated_at=excluded.updated_at;
            """)
        defer { statement.reset() }
        try statement.bind(1, definition.id.value.uuidString.lowercased())
        try statement.bind(2, definition.botID.value.uuidString.lowercased())
        try statement.bind(3, definition.name)
        try statement.bind(4, definition.prompt)
        try statement.bind(5, definition.scheduleNote)
        try statement.bind(6, string(definition.createdAt))
        try statement.bind(7, string(definition.updatedAt))
        _ = try statement.step()
    }

    private func upsertActivation(_ activation: BotRoutineActivation, database: SQLiteDB) throws {
        let statement = try database.prepare("""
            INSERT INTO bot_routine_activations(
                routine_id, bot_id, is_enabled, last_test_run_requested_at, updated_at
            ) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(routine_id) DO UPDATE SET
                is_enabled=excluded.is_enabled,
                last_test_run_requested_at=excluded.last_test_run_requested_at,
                updated_at=excluded.updated_at;
            """)
        defer { statement.reset() }
        try statement.bind(1, activation.routineID.value.uuidString.lowercased())
        try statement.bind(2, activation.botID.value.uuidString.lowercased())
        try statement.bind(3, activation.isEnabled)
        try statement.bind(4, string(activation.lastTestRunRequestedAt))
        try statement.bind(5, string(activation.updatedAt))
        _ = try statement.step()
    }

    private func insertMemoryRevision(_ revision: BotMemoryItemRevision, database: SQLiteDB) throws {
        let statement = try database.prepare("""
            INSERT INTO bot_memory_item_revisions(
                id, item_id, bot_id, revision_number, content, provenance, trusted, source,
                created_at, supersedes_revision_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        defer { statement.reset() }
        try statement.bind(1, revision.id.uuidString.lowercased())
        try statement.bind(2, revision.itemID.value.uuidString.lowercased())
        try statement.bind(3, revision.botID.value.uuidString.lowercased())
        try statement.bind(4, revision.revisionNumber)
        try statement.bind(5, revision.content)
        try statement.bind(6, revision.provenance)
        try statement.bind(7, revision.trusted)
        try statement.bind(8, revision.source)
        try statement.bind(9, string(revision.createdAt))
        try statement.bind(10, revision.supersedesRevisionID?.uuidString.lowercased())
        _ = try statement.step()
    }

    private func executeBound(_ sql: String, id: BotID) throws {
        let statement = try db.prepare(sql)
        defer { statement.reset() }
        try statement.bind(1, id.value.uuidString.lowercased())
        _ = try statement.step()
    }

    private func loadBot(id: BotID, database: SQLiteDB) throws -> BotDefinition? {
        let statement = try database.prepare(Self.botSelect + " WHERE id = ? LIMIT 1;")
        defer { statement.reset() }
        try statement.bind(1, id.value.uuidString.lowercased())
        return try statement.step() ? try decodeBot(statement) : nil
    }

    private func loadRevision(id: BotRevisionID, database: SQLiteDB) throws -> BotRevision? {
        let statement = try database.prepare(Self.revisionSelect + " WHERE id = ? LIMIT 1;")
        defer { statement.reset() }
        try statement.bind(1, id.value.uuidString.lowercased())
        return try statement.step() ? try decodeRevision(statement) : nil
    }

    private func loadMemory(id: BotMemoryItemID, database: SQLiteDB) throws -> BotMemoryItem? {
        let statement = try database.prepare(Self.memorySelect + " WHERE i.id = ? LIMIT 1;")
        defer { statement.reset() }
        try statement.bind(1, id.value.uuidString.lowercased())
        return try statement.step() ? try decodeMemory(statement) : nil
    }

    private func loadActivation(routineID: BotRoutineID, database: SQLiteDB) throws -> BotRoutineActivation? {
        let statement = try database.prepare("""
            SELECT routine_id, bot_id, is_enabled, last_test_run_requested_at, updated_at
            FROM bot_routine_activations WHERE routine_id = ? LIMIT 1;
            """)
        defer { statement.reset() }
        try statement.bind(1, routineID.value.uuidString.lowercased())
        return try statement.step() ? try decodeActivation(statement) : nil
    }

    private func upsertSkillBinding(_ binding: BotSkillBinding, database: SQLiteDB) throws {
        let statement = try database.prepare("""
            INSERT INTO bot_skill_bindings(bot_id, skill_id, enabled, digest, updated_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(bot_id, skill_id) DO UPDATE SET
                enabled=excluded.enabled,
                digest=excluded.digest,
                updated_at=excluded.updated_at;
            """)
        defer { statement.reset() }
        try statement.bind(1, binding.botID.value.uuidString.lowercased())
        try statement.bind(2, binding.skillID)
        try statement.bind(3, binding.enabled)
        try statement.bind(4, binding.digest)
        try statement.bind(5, string(binding.updatedAt))
        _ = try statement.step()
    }

    private func loadSkillBindings(botID: BotID, database: SQLiteDB) throws -> [BotSkillBinding] {
        let statement = try database.prepare("""
            SELECT bot_id, skill_id, enabled, digest, updated_at
            FROM bot_skill_bindings
            WHERE bot_id = ?
            ORDER BY skill_id ASC;
            """)
        defer { statement.reset() }
        try statement.bind(1, botID.value.uuidString.lowercased())
        var result: [BotSkillBinding] = []
        while try statement.step() {
            result.append(try decodeSkillBinding(statement))
        }
        return result
    }

    private func decodeSkillBinding(_ statement: SQLiteStatement) throws -> BotSkillBinding {
        guard let bot = UUID(uuidString: statement.columnText(0) ?? ""),
              let skillID = statement.columnText(1),
              !skillID.isEmpty,
              let updated = date(statement.columnText(4)) else {
            throw BotStoreError.invalidRow("skill binding")
        }
        return BotSkillBinding(
            botID: BotID(bot),
            skillID: skillID,
            enabled: statement.columnInt64(2) != 0,
            digest: statement.columnText(3),
            updatedAt: updated
        )
    }

    private func loadRoutines(botID: BotID, database: SQLiteDB) throws -> [BotRoutine] {
        let statement = try database.prepare("""
            SELECT d.id, d.bot_id, d.name, d.prompt, d.schedule_note, d.created_at, d.updated_at,
                   a.routine_id, a.bot_id, a.is_enabled, a.last_test_run_requested_at, a.updated_at
            FROM bot_routine_definitions d
            JOIN bot_routine_activations a ON a.routine_id = d.id
            WHERE d.bot_id = ?
            ORDER BY d.updated_at DESC;
            """)
        defer { statement.reset() }
        try statement.bind(1, botID.value.uuidString.lowercased())
        var result: [BotRoutine] = []
        while try statement.step() {
            let definition = try decodeRoutineDefinition(statement)
            let activation = try decodeActivation(statement, offset: 7)
            result.append(BotRoutine(definition: definition, activation: activation))
        }
        return result
    }

    private func nextRevisionNumber(botID: BotID, database: SQLiteDB) throws -> Int {
        let statement = try database.prepare(
            "SELECT COALESCE(MAX(revision_number), 0) FROM bot_revisions WHERE bot_id = ?;"
        )
        defer { statement.reset() }
        try statement.bind(1, botID.value.uuidString.lowercased())
        _ = try statement.step()
        return Int(statement.columnInt64(0)) + 1
    }

    private func nextMemoryRevisionNumber(itemID: BotMemoryItemID, database: SQLiteDB) throws -> Int {
        let statement = try database.prepare(
            "SELECT COALESCE(MAX(revision_number), 0) FROM bot_memory_item_revisions WHERE item_id = ?;"
        )
        defer { statement.reset() }
        try statement.bind(1, itemID.value.uuidString.lowercased())
        _ = try statement.step()
        return Int(statement.columnInt64(0)) + 1
    }

    private func decodeBot(_ statement: SQLiteStatement) throws -> BotDefinition {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let handle = statement.columnText(1),
            let name = statement.columnText(2),
            let title = statement.columnText(3),
            let description = statement.columnText(4),
            let avatar = statement.columnText(5),
            let created = date(statement.columnText(11)),
            let updated = date(statement.columnText(12))
        else { throw BotStoreError.invalidRow("bots") }
        let revision = statement.columnText(8).flatMap(UUID.init(uuidString:)).map(BotRevisionID.init)
        let workspace = statement.columnText(14).flatMap(UUID.init(uuidString:)).map(WorkspaceID.init)
        return BotDefinition(
            id: BotID(id),
            handle: handle,
            name: name,
            title: title,
            description: description,
            avatarSymbol: avatar,
            pinned: statement.columnInt64(6) != 0,
            hidden: statement.columnInt64(7) != 0,
            currentRevisionID: revision,
            directoryEpoch: Int(statement.columnInt64(9)),
            notificationsEnabled: statement.columnInt64(10) != 0,
            createdAt: created,
            updatedAt: updated,
            deletedAt: date(statement.columnText(13)),
            workspaceID: workspace
        )
    }

    private func decodeRevision(_ statement: SQLiteStatement) throws -> BotRevision {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let botRaw = statement.columnText(1), let bot = UUID(uuidString: botRaw),
            let name = statement.columnText(3),
            let title = statement.columnText(4),
            let description = statement.columnText(5),
            let soul = statement.columnText(6),
            let providerRaw = statement.columnText(7), let provider = AgentProvider(rawValue: providerRaw),
            let instance = statement.columnText(8),
            let model = statement.columnText(9),
            let effortRaw = statement.columnText(10), let effort = AgentReasoningEffort(rawValue: effortRaw),
            let routesRaw = statement.columnText(11),
            let permissionRaw = statement.columnText(12),
            let permission = AgentPermissionMode(rawValue: permissionRaw),
            let desktopRaw = statement.columnText(13),
            let desktop = BotDesktopKind(rawValue: desktopRaw),
            let digest = statement.columnText(14),
            let published = date(statement.columnText(15))
        else { throw BotStoreError.invalidRow("bot_revisions") }
        let supersedes = statement.columnText(16).flatMap(UUID.init(uuidString:)).map(BotRevisionID.init)
        return BotRevision(
            id: BotRevisionID(id),
            botID: BotID(bot),
            revisionNumber: Int(statement.columnInt64(2)),
            name: name,
            title: title,
            description: description,
            soul: soul,
            provider: provider,
            providerInstanceID: instance,
            model: model,
            reasoningEffort: effort,
            compatibleRouteSet: try decodeRoutes(routesRaw),
            permissionMode: permission,
            desktopKind: desktop,
            digest: digest,
            publishedAt: published,
            supersedesRevisionID: supersedes
        )
    }

    private func decodeConversation(_ statement: SQLiteStatement) throws -> BotConversation {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let botRaw = statement.columnText(1), let bot = UUID(uuidString: botRaw),
            let title = statement.columnText(2),
            let stateRaw = statement.columnText(6),
            let state = BotAttentionState(rawValue: stateRaw),
            let created = date(statement.columnText(8)),
            let updated = date(statement.columnText(9))
        else { throw BotStoreError.invalidRow("bot_conversations") }
        let thread = statement.columnText(7).flatMap(UUID.init(uuidString:)).map(AgentThreadID.init)
        return BotConversation(
            id: BotConversationID(id),
            botID: BotID(bot),
            title: title,
            pinned: statement.columnInt64(3) != 0,
            hidden: statement.columnInt64(4) != 0,
            unread: statement.columnInt64(5) != 0,
            attentionState: state,
            linkedAgentThreadID: thread,
            createdAt: created,
            updatedAt: updated
        )
    }

    private func decodeMemory(_ statement: SQLiteStatement) throws -> BotMemoryItem {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let botRaw = statement.columnText(1), let bot = UUID(uuidString: botRaw),
            let revisionRaw = statement.columnText(2), let revision = UUID(uuidString: revisionRaw),
            let content = statement.columnText(5),
            let provenance = statement.columnText(6),
            let source = statement.columnText(8),
            let created = date(statement.columnText(10)),
            let updated = date(statement.columnText(11))
        else { throw BotStoreError.invalidRow("bot_memory_items") }
        return BotMemoryItem(
            id: BotMemoryItemID(id),
            botID: BotID(bot),
            currentRevisionID: revision,
            content: content,
            provenance: provenance,
            trusted: statement.columnInt64(7) != 0,
            source: source,
            forgottenAt: date(statement.columnText(3)),
            expiresAt: date(statement.columnText(4)),
            createdAt: created,
            updatedAt: updated
        )
    }

    private func decodeMemoryRevision(_ statement: SQLiteStatement) throws -> BotMemoryItemRevision {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let itemRaw = statement.columnText(1), let item = UUID(uuidString: itemRaw),
            let botRaw = statement.columnText(2), let bot = UUID(uuidString: botRaw),
            let content = statement.columnText(4),
            let provenance = statement.columnText(5),
            let source = statement.columnText(7),
            let created = date(statement.columnText(8))
        else { throw BotStoreError.invalidRow("bot_memory_item_revisions") }
        return BotMemoryItemRevision(
            id: id,
            itemID: BotMemoryItemID(item),
            botID: BotID(bot),
            revisionNumber: Int(statement.columnInt64(3)),
            content: content,
            provenance: provenance,
            trusted: statement.columnInt64(6) != 0,
            source: source,
            createdAt: created,
            supersedesRevisionID: statement.columnText(9).flatMap(UUID.init(uuidString:))
        )
    }

    private func decodeAttention(_ statement: SQLiteStatement) throws -> BotAttentionItem {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let botRaw = statement.columnText(1), let bot = UUID(uuidString: botRaw),
            let kindRaw = statement.columnText(3), let kind = BotAttentionItemKind(rawValue: kindRaw),
            let title = statement.columnText(4),
            let detail = statement.columnText(5),
            let created = date(statement.columnText(6))
        else { throw BotStoreError.invalidRow("bot_attention_items") }
        let conversation = statement.columnText(2).flatMap(UUID.init(uuidString:)).map(BotConversationID.init)
        return BotAttentionItem(
            id: BotAttentionItemID(id),
            botID: BotID(bot),
            conversationID: conversation,
            kind: kind,
            title: title,
            detail: detail,
            createdAt: created,
            acknowledgedAt: date(statement.columnText(7))
        )
    }

    private func decodeRoutineDefinition(_ statement: SQLiteStatement) throws -> BotRoutineDefinition {
        guard
            let idRaw = statement.columnText(0), let id = UUID(uuidString: idRaw),
            let botRaw = statement.columnText(1), let bot = UUID(uuidString: botRaw),
            let name = statement.columnText(2),
            let prompt = statement.columnText(3),
            let note = statement.columnText(4),
            let created = date(statement.columnText(5)),
            let updated = date(statement.columnText(6))
        else { throw BotStoreError.invalidRow("bot_routine_definitions") }
        return BotRoutineDefinition(
            id: BotRoutineID(id),
            botID: BotID(bot),
            name: name,
            prompt: prompt,
            scheduleNote: note,
            createdAt: created,
            updatedAt: updated
        )
    }

    private func decodeActivation(_ statement: SQLiteStatement, offset: Int32 = 0) throws -> BotRoutineActivation {
        guard
            let idRaw = statement.columnText(offset), let id = UUID(uuidString: idRaw),
            let botRaw = statement.columnText(offset + 1), let bot = UUID(uuidString: botRaw),
            let updated = date(statement.columnText(offset + 4))
        else { throw BotStoreError.invalidRow("bot_routine_activations") }
        return BotRoutineActivation(
            routineID: BotRoutineID(id),
            botID: BotID(bot),
            isEnabled: statement.columnInt64(offset + 2) != 0,
            lastTestRunRequestedAt: date(statement.columnText(offset + 3)),
            updatedAt: updated
        )
    }

    private func encodeRoutes(_ routes: [String]) throws -> String {
        guard let string = String(data: try encoder.encode(routes), encoding: .utf8) else {
            throw BotStoreError.invalidRow("compatible_route_set is not UTF-8")
        }
        return string
    }

    private func decodeRoutes(_ string: String) throws -> [String] {
        guard let data = string.data(using: .utf8) else {
            throw BotStoreError.invalidRow("compatible_route_set is not UTF-8")
        }
        return try decoder.decode([String].self, from: data)
    }

    private func string(_ date: Date?) -> String? {
        date.map { dates.string(from: $0) }
    }

    private func date(_ string: String?) -> Date? {
        string.flatMap(dates.date(from:))
    }

    private static let botSelect = """
        SELECT id, handle, name, title, description, avatar_symbol, pinned, hidden,
               current_revision_id, directory_epoch, notifications_enabled,
               created_at, updated_at, deleted_at, workspace_id
        FROM bots
        """

    private static let revisionSelect = """
        SELECT id, bot_id, revision_number, name, title, description, soul, provider,
               provider_instance_id, model, reasoning_effort, compatible_route_set_json,
               permission_mode, desktop_kind, digest, published_at, supersedes_revision_id
        FROM bot_revisions
        """

    private static let conversationSelect = """
        SELECT id, bot_id, title, pinned, hidden, unread, attention_state,
               linked_agent_thread_id, created_at, updated_at
        FROM bot_conversations
        """

    private static let memorySelect = """
        SELECT i.id, i.bot_id, i.current_revision_id, i.forgotten_at, i.expires_at,
               r.content, r.provenance, r.trusted, r.source, r.id,
               i.created_at, i.updated_at
        FROM bot_memory_items i
        LEFT JOIN bot_memory_item_revisions r ON r.id = i.current_revision_id
        """

    private static let attentionSelect = """
        SELECT id, bot_id, conversation_id, kind, title, detail, created_at, acknowledged_at
        FROM bot_attention_items
        """
}
