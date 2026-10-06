import Foundation
import CoreModel

/// Bot teams and group conversations (schema v88).
///
/// Writes run in one `db.transaction` and only use `db.prepare` inside it:
/// `performSync` inside a transaction would hop to the queue while this thread
/// holds the operation lock.
extension BotStore {
    // MARK: - Teams

    public func listTeams() throws -> [BotTeam] {
        try db.performSync { database in
            let statement = try database.prepare(Self.teamSelect + " ORDER BY sort_order, created_at, id;")
            defer { statement.reset() }
            var teams: [BotTeam] = []
            while try statement.step() { teams.append(try decodeTeam(statement)) }
            return teams
        }
    }

    public func team(id: BotTeamID) throws -> BotTeam? {
        try db.performSync { database in try loadTeam(id: id, database: database) }
    }

    /// Members of one team, or of every team when `teamID` is nil, in team then
    /// member order. A bot appears once per team it belongs to.
    public func listTeamMembers(teamID: BotTeamID? = nil) throws -> [BotTeamMember] {
        try db.performSync { database in
            let statement = try database.prepare("""
                SELECT m.team_id, m.bot_id, m.sort_order, m.added_at
                FROM bot_team_members m
                JOIN bot_teams t ON t.id = m.team_id
                \(teamID == nil ? "" : "WHERE m.team_id = ?")
                ORDER BY t.sort_order, t.created_at, t.id, m.sort_order, m.added_at;
                """)
            defer { statement.reset() }
            if let teamID { try statement.bind(1, Self.key(teamID.value)) }
            var members: [BotTeamMember] = []
            while try statement.step() { members.append(try decodeTeamMember(statement)) }
            return members
        }
    }

    @discardableResult
    public func createTeam(
        name: String,
        description: String = "",
        avatarSymbol: String = "person.3.fill",
        memberBotIDs: [BotID] = [],
        now: Date = Date()
    ) throws -> BotTeam {
        let name = try Self.requiredName(name, what: "Team name")
        return try db.transaction {
            let members = try liveBotIDs(memberBotIDs, database: db)
            let next = try db.prepare("SELECT COALESCE(MAX(sort_order) + 1, 0) FROM bot_teams;")
            defer { next.reset() }
            let sortOrder = try next.step() ? Int(next.columnInt64(0)) : 0
            next.reset()
            let team = BotTeam(
                name: name,
                description: description,
                avatarSymbol: avatarSymbol,
                sortOrder: sortOrder,
                revision: 1,
                createdAt: now,
                updatedAt: now
            )
            let insert = try db.prepare("""
                INSERT INTO bot_teams(id, name, description, avatar_symbol, sort_order, revision, created_at, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?);
                """)
            defer { insert.reset() }
            try insert.bind(1, Self.key(team.id.value))
            try insert.bind(2, team.name)
            try insert.bind(3, team.description)
            try insert.bind(4, team.avatarSymbol)
            try insert.bind(5, team.sortOrder)
            try insert.bind(6, team.revision)
            try insert.bind(7, string(now))
            try insert.bind(8, string(now))
            _ = try insert.step()
            try replaceTeamMembersLocked(teamID: team.id, botIDs: members, now: now)
            return team
        }
    }

    public func updateTeam(
        id: BotTeamID,
        expectedRevision: Int,
        name: String,
        description: String,
        avatarSymbol: String,
        now: Date = Date()
    ) throws -> BotTeam {
        let name = try Self.requiredName(name, what: "Team name")
        return try db.transaction {
            var team = try lockedTeam(id: id, expectedRevision: expectedRevision)
            team.name = name
            team.description = description
            team.avatarSymbol = avatarSymbol
            team.revision += 1
            team.updatedAt = now
            let update = try db.prepare("""
                UPDATE bot_teams SET name = ?, description = ?, avatar_symbol = ?, revision = ?, updated_at = ?
                WHERE id = ?;
                """)
            defer { update.reset() }
            try update.bind(1, team.name)
            try update.bind(2, team.description)
            try update.bind(3, team.avatarSymbol)
            try update.bind(4, team.revision)
            try update.bind(5, string(now))
            try update.bind(6, Self.key(id.value))
            _ = try update.step()
            return team
        }
    }

    /// Replaces the member list (order = `botIDs` order, duplicates dropped).
    public func setTeamMembers(
        id: BotTeamID,
        expectedRevision: Int,
        botIDs: [BotID],
        now: Date = Date()
    ) throws -> BotTeam {
        try db.transaction {
            var team = try lockedTeam(id: id, expectedRevision: expectedRevision)
            let members = try liveBotIDs(botIDs, database: db)
            try replaceTeamMembersLocked(teamID: id, botIDs: members, now: now)
            team.revision += 1
            team.updatedAt = now
            try bumpTeamLocked(team)
            return team
        }
    }

    /// Deletes the team and its memberships. Bots and group conversations stay;
    /// groups created from this team keep their participants (team_id → NULL).
    public func deleteTeam(id: BotTeamID) throws {
        try db.transaction {
            guard try loadTeam(id: id, database: db) != nil else { throw BotStoreError.notFound }
            let delete = try db.prepare("DELETE FROM bot_teams WHERE id = ?;")
            defer { delete.reset() }
            try delete.bind(1, Self.key(id.value))
            _ = try delete.step()
        }
    }

    /// Persists sidebar order. `ids` must name every team exactly once.
    public func reorderTeams(_ ids: [BotTeamID], now: Date = Date()) throws {
        try db.transaction {
            let existing = try db.prepare("SELECT id FROM bot_teams;")
            defer { existing.reset() }
            var known = Set<String>()
            while try existing.step() { if let raw = existing.columnText(0) { known.insert(raw) } }
            existing.reset()
            let requested = ids.map { Self.key($0.value) }
            guard Set(requested) == known, requested.count == known.count else {
                throw BotStoreError.invalidInput("Team order must list every team exactly once.")
            }
            let update = try db.prepare("""
                UPDATE bot_teams SET sort_order = ?, revision = revision + 1, updated_at = ?
                WHERE id = ? AND sort_order != ?;
                """)
            defer { update.reset() }
            for (index, raw) in requested.enumerated() {
                update.reset()
                try update.bind(1, index)
                try update.bind(2, string(now))
                try update.bind(3, raw)
                try update.bind(4, index)
                _ = try update.step()
            }
            update.reset()
        }
    }

    // MARK: - Group conversations

    /// Creates the group row, one participant per bot and each participant's
    /// hidden member conversation (thread linked lazily on its first turn).
    /// The caller owns creating the quiet room thread `roomThreadID`.
    public func createGroup(
        title: String,
        teamID: BotTeamID? = nil,
        roomThreadID: AgentThreadID,
        policy: BotGroupPolicy = .roundtable,
        leadBotID: BotID? = nil,
        maxAutoHops: Int = BotGroupConversation.defaultMaxAutoHops,
        participantBotIDs: [BotID],
        now: Date = Date()
    ) throws -> BotGroupConversation {
        let title = try Self.requiredName(title, what: "Group title")
        return try db.transaction {
            let participants = try liveBotIDs(participantBotIDs, database: db)
            let group = BotGroupConversation(
                title: title,
                teamID: teamID,
                roomThreadID: roomThreadID,
                policy: policy,
                leadBotID: leadBotID,
                maxAutoHops: maxAutoHops,
                revision: 1,
                createdAt: now,
                updatedAt: now
            )
            try Self.validate(group, participants: participants)
            if let teamID, try loadTeam(id: teamID, database: db) == nil {
                throw BotStoreError.notFound
            }
            let insert = try db.prepare("""
                INSERT INTO bot_group_conversations(
                    id, title, team_id, room_thread_id, policy, lead_bot_id, max_auto_hops,
                    pinned, hidden, unread, attention_state, revision, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """)
            defer { insert.reset() }
            try insert.bind(1, Self.key(group.id.value))
            try insert.bind(2, group.title)
            try insert.bind(3, group.teamID.map { Self.key($0.value) })
            try insert.bind(4, Self.key(group.roomThreadID.value))
            try insert.bind(5, group.policy.rawValue)
            try insert.bind(6, group.leadBotID.map { Self.key($0.value) })
            try insert.bind(7, group.maxAutoHops)
            try insert.bind(8, group.pinned)
            try insert.bind(9, group.hidden)
            try insert.bind(10, group.unread)
            try insert.bind(11, group.attentionState.rawValue)
            try insert.bind(12, group.revision)
            try insert.bind(13, string(now))
            try insert.bind(14, string(now))
            _ = try insert.step()
            for (index, botID) in participants.enumerated() {
                try insertParticipantLocked(group: group, botID: botID, sortOrder: index, now: now)
            }
            return group
        }
    }

    public func group(id: BotGroupID) throws -> BotGroupConversation? {
        try db.performSync { database in try loadGroup(id: id, database: database) }
    }

    public func group(roomThreadID: AgentThreadID) throws -> BotGroupConversation? {
        try db.performSync { database in
            let statement = try database.prepare(Self.groupSelect + " WHERE room_thread_id = ? LIMIT 1;")
            defer { statement.reset() }
            try statement.bind(1, Self.key(roomThreadID.value))
            return try statement.step() ? try decodeGroup(statement) : nil
        }
    }

    public func listGroups(includeHidden: Bool = false) throws -> [BotGroupConversation] {
        try db.performSync { database in
            let statement = try database.prepare(
                Self.groupSelect
                    + (includeHidden ? "" : " WHERE hidden = 0")
                    + " ORDER BY pinned DESC, updated_at DESC, id;"
            )
            defer { statement.reset() }
            var groups: [BotGroupConversation] = []
            while try statement.step() { groups.append(try decodeGroup(statement)) }
            return groups
        }
    }

    /// Edits title, team, policy, lead, hop budget, pin/hide/unread/attention.
    /// `id`, room thread, revision and timestamps are not editable through
    /// `mutate`. Pass `expectedRevision` for user edits (compare-and-set); nil
    /// for host bookkeeping such as unread or attention.
    public func updateGroup(
        id: BotGroupID,
        expectedRevision: Int?,
        now: Date = Date(),
        _ mutate: (inout BotGroupConversation) -> Void
    ) throws -> BotGroupConversation {
        try db.transaction {
            guard let current = try loadGroup(id: id, database: db) else { throw BotStoreError.notFound }
            if let expectedRevision, expectedRevision != current.revision { throw BotStoreError.revisionConflict }
            var group = current
            mutate(&group)
            group.id = current.id
            group.roomThreadID = current.roomThreadID
            group.createdAt = current.createdAt
            group.title = try Self.requiredName(group.title, what: "Group title")
            group.revision = current.revision + 1
            group.updatedAt = now
            let active = try loadParticipants(groupID: id, includeLeft: false, database: db).map(\.botID)
            try Self.validate(group, participants: active)
            if let teamID = group.teamID, teamID != current.teamID,
               try loadTeam(id: teamID, database: db) == nil {
                throw BotStoreError.notFound
            }
            try writeGroupLocked(group)
            return group
        }
    }

    /// Replaces the active participant set (order = `botIDs` order). Removed
    /// bots get `left_at` and their planned/waiting turns in this group are
    /// cancelled; a returning bot reuses its member conversation.
    public func setGroupParticipants(
        id: BotGroupID,
        expectedRevision: Int,
        botIDs: [BotID],
        now: Date = Date()
    ) throws -> BotGroupConversation {
        try db.transaction {
            guard var group = try loadGroup(id: id, database: db) else { throw BotStoreError.notFound }
            guard group.revision == expectedRevision else { throw BotStoreError.revisionConflict }
            let wanted = try liveBotIDs(botIDs, database: db)
            if let lead = group.leadBotID, !wanted.contains(lead) {
                guard group.policy != .lead else {
                    throw BotStoreError.invalidInput("Choose another lead before removing the lead bot.")
                }
                group.leadBotID = nil
            }
            try Self.validate(group, participants: wanted)
            let all = try loadParticipants(groupID: id, includeLeft: true, database: db)
            let wantedSet = Set(wanted)
            for participant in all where participant.isActive && !wantedSet.contains(participant.botID) {
                try markParticipantLeftLocked(groupID: id, botID: participant.botID, now: now)
                try cancelPendingTurnsLocked(groupID: id, botID: participant.botID, now: now)
            }
            let existing = Dictionary(uniqueKeysWithValues: all.map { ($0.botID, $0) })
            for (index, botID) in wanted.enumerated() {
                if existing[botID] != nil {
                    let rejoin = try db.prepare("""
                        UPDATE bot_group_participants SET left_at = NULL, sort_order = ?
                        WHERE group_id = ? AND bot_id = ?;
                        """)
                    defer { rejoin.reset() }
                    try rejoin.bind(1, index)
                    try rejoin.bind(2, Self.key(id.value))
                    try rejoin.bind(3, Self.key(botID.value))
                    _ = try rejoin.step()
                } else {
                    try insertParticipantLocked(group: group, botID: botID, sortOrder: index, now: now)
                }
            }
            group.revision += 1
            group.updatedAt = now
            try writeGroupLocked(group)
            return group
        }
    }

    public func listGroupParticipants(
        groupID: BotGroupID,
        includeLeft: Bool = false
    ) throws -> [BotGroupParticipant] {
        try db.performSync { database in
            try loadParticipants(groupID: groupID, includeLeft: includeLeft, database: database)
        }
    }

    /// The hidden member conversations of one group (never in desk lists).
    public func listGroupMemberConversations(groupID: BotGroupID) throws -> [BotConversation] {
        try db.performSync { database in
            let statement = try database.prepare(Self.conversationSelect + " WHERE group_id = ? ORDER BY created_at, id;")
            defer { statement.reset() }
            try statement.bind(1, Self.key(groupID.value))
            var result: [BotConversation] = []
            while try statement.step() { result.append(try decodeConversation(statement)) }
            return result
        }
    }

    /// Records the last room message this bot has been shown.
    public func setGroupParticipantWatermark(
        groupID: BotGroupID,
        botID: BotID,
        messageID: AgentMessageID,
        createdAt: Date
    ) throws {
        try db.performSync { database in
            let update = try database.prepare("""
                UPDATE bot_group_participants SET seen_room_message_id = ?, seen_room_created_at = ?
                WHERE group_id = ? AND bot_id = ?;
                """)
            defer { update.reset() }
            try update.bind(1, Self.key(messageID.value))
            try update.bind(2, string(createdAt))
            try update.bind(3, Self.key(groupID.value))
            try update.bind(4, Self.key(botID.value))
            _ = try update.step()
        }
    }

    /// Deletes the group, its participants, turns and member conversations.
    /// Returns the room thread and every linked member thread so the caller
    /// can remove those AgentThreads.
    @discardableResult
    public func deleteGroup(id: BotGroupID) throws -> [AgentThreadID] {
        let threads: [AgentThreadID] = try db.transaction {
            guard let group = try loadGroup(id: id, database: db) else { throw BotStoreError.notFound }
            let members = try db.prepare("""
                SELECT linked_agent_thread_id FROM bot_conversations
                WHERE group_id = ? AND linked_agent_thread_id IS NOT NULL
                ORDER BY created_at, id;
                """)
            defer { members.reset() }
            try members.bind(1, Self.key(id.value))
            var threads = [group.roomThreadID]
            while try members.step() {
                if let raw = members.columnText(0), let uuid = UUID(uuidString: raw) {
                    threads.append(AgentThreadID(uuid))
                }
            }
            members.reset()
            for sql in [
                "DELETE FROM bot_conversations WHERE group_id = ?;",
                "DELETE FROM bot_group_conversations WHERE id = ?;",
            ] {
                let statement = try db.prepare(sql)
                defer { statement.reset() }
                try statement.bind(1, Self.key(id.value))
                _ = try statement.step()
            }
            return threads
        }
        forgetLinkedThreads(threads)
        return threads
    }

    // MARK: - Turns

    /// Inserts a round's turns atomically. Each bot must be an active
    /// participant; (round, bot, hop) and room_message_id are unique.
    public func insertGroupTurns(_ turns: [BotGroupTurn]) throws {
        guard !turns.isEmpty else { return }
        try db.transaction {
            var activeByGroup: [BotGroupID: Set<BotID>] = [:]
            for turn in turns {
                if activeByGroup[turn.groupID] == nil {
                    guard try loadGroup(id: turn.groupID, database: db) != nil else { throw BotStoreError.notFound }
                    activeByGroup[turn.groupID] = Set(
                        try loadParticipants(groupID: turn.groupID, includeLeft: false, database: db).map(\.botID)
                    )
                }
                guard activeByGroup[turn.groupID]?.contains(turn.botID) == true else {
                    throw BotStoreError.invalidInput("That bot is not in this group.")
                }
                guard (0...BotGroupConversation.maxAutoHopsCap).contains(turn.hop) else {
                    throw BotStoreError.invalidInput("Hop must be between 0 and \(BotGroupConversation.maxAutoHopsCap).")
                }
                let insert = try db.prepare("""
                    INSERT INTO bot_group_turns(
                        id, group_id, round_id, trigger_message_id, bot_id, ordinal, hop, state,
                        room_message_id, member_run_id, submit_key, error, created_at, updated_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """)
                defer { insert.reset() }
                try insert.bind(1, Self.key(turn.id.value))
                try insert.bind(2, Self.key(turn.groupID.value))
                try insert.bind(3, Self.key(turn.roundID.value))
                try insert.bind(4, turn.triggerMessageID.map { Self.key($0.value) })
                try insert.bind(5, Self.key(turn.botID.value))
                try insert.bind(6, turn.ordinal)
                try insert.bind(7, turn.hop)
                try insert.bind(8, turn.state.rawValue)
                try insert.bind(9, Self.key(turn.roomMessageID.value))
                try insert.bind(10, turn.memberRunID.map { Self.key($0.value) })
                try insert.bind(11, turn.submitKey)
                try insert.bind(12, turn.error)
                try insert.bind(13, string(turn.createdAt))
                try insert.bind(14, string(turn.updatedAt))
                _ = try insert.step()
            }
        }
    }

    public func groupTurn(id: BotGroupTurnID) throws -> BotGroupTurn? {
        try db.performSync { database in try loadTurn(id: id, database: database) }
    }

    /// Turns of one group (or of every group when nil), optionally filtered by
    /// state, in ordinal order.
    public func listGroupTurns(
        groupID: BotGroupID?,
        states: [BotGroupTurn.State]? = nil
    ) throws -> [BotGroupTurn] {
        if let states, states.isEmpty { return [] }
        return try db.performSync { database in
            var clauses: [String] = []
            if groupID != nil { clauses.append("group_id = ?") }
            if let states {
                clauses.append("state IN (\(Array(repeating: "?", count: states.count).joined(separator: ",")))")
            }
            let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            let statement = try database.prepare(Self.turnSelect + filter + " ORDER BY group_id, ordinal, created_at, id;")
            defer { statement.reset() }
            var index: Int32 = 1
            if let groupID {
                try statement.bind(index, Self.key(groupID.value))
                index += 1
            }
            for state in states ?? [] {
                try statement.bind(index, state.rawValue)
                index += 1
            }
            var turns: [BotGroupTurn] = []
            while try statement.step() { turns.append(try decodeTurn(statement)) }
            return turns
        }
    }

    /// Single-winner state change: applies only while the turn is in one of
    /// `expected` states and returns the updated turn, else nil (a stale or
    /// duplicate settle changes nothing). `memberRunID` / `error` are written
    /// only when non-nil.
    @discardableResult
    public func transitionGroupTurn(
        id: BotGroupTurnID,
        from expected: [BotGroupTurn.State],
        to state: BotGroupTurn.State,
        memberRunID: AgentRunID? = nil,
        error: String? = nil,
        now: Date = Date()
    ) throws -> BotGroupTurn? {
        try db.transaction {
            guard var turn = try loadTurn(id: id, database: db) else { throw BotStoreError.notFound }
            guard expected.contains(turn.state) else { return nil }
            turn.state = state
            if let memberRunID { turn.memberRunID = memberRunID }
            if let error { turn.error = error }
            turn.updatedAt = now
            let update = try db.prepare("""
                UPDATE bot_group_turns SET state = ?, member_run_id = ?, error = ?, updated_at = ?
                WHERE id = ?;
                """)
            defer { update.reset() }
            try update.bind(1, turn.state.rawValue)
            try update.bind(2, turn.memberRunID.map { Self.key($0.value) })
            try update.bind(3, turn.error)
            try update.bind(4, string(now))
            try update.bind(5, Self.key(id.value))
            _ = try update.step()
            return turn
        }
    }

    /// Cancels every planned or waiting turn of a group (new round supersedes
    /// the old one; Stop). Returns the cancelled turns.
    @discardableResult
    public func cancelPendingGroupTurns(groupID: BotGroupID, now: Date = Date()) throws -> [BotGroupTurn] {
        try db.transaction {
            let pending = try loadTurns(groupID: groupID, states: BotGroupTurn.State.pending, database: db)
            try cancelPendingTurnsLocked(groupID: groupID, botID: nil, now: now)
            return pending.map {
                var turn = $0
                turn.state = .cancelled
                turn.updatedAt = now
                return turn
            }
        }
    }

    // MARK: - Bot delete cascade

    /// Runs inside `delete(id:)`'s transaction. Group history (room rows) is
    /// kept; the bot leaves every group and team and its unstarted turns are
    /// cancelled. A lead-policy group that loses its lead falls back to
    /// roundtable so it keeps working with the remaining bots.
    func removeFromTeamsAndGroupsLocked(botID: BotID, now: Date) throws {
        let bot = Self.key(botID.value)
        let stamp = string(now)
        let steps: [(String, [String?])] = [
            ("""
            UPDATE bot_teams SET revision = revision + 1, updated_at = ?
            WHERE id IN (SELECT team_id FROM bot_team_members WHERE bot_id = ?);
            """, [stamp, bot]),
            ("DELETE FROM bot_team_members WHERE bot_id = ?;", [bot]),
            ("""
            UPDATE bot_group_conversations
            SET revision = revision + 1, updated_at = ?,
                policy = CASE WHEN lead_bot_id = ? AND policy = 'lead' THEN 'roundtable' ELSE policy END,
                lead_bot_id = CASE WHEN lead_bot_id = ? THEN NULL ELSE lead_bot_id END
            WHERE lead_bot_id = ?
               OR id IN (SELECT group_id FROM bot_group_participants WHERE bot_id = ? AND left_at IS NULL);
            """, [stamp, bot, bot, bot, bot]),
            ("UPDATE bot_group_participants SET left_at = ? WHERE bot_id = ? AND left_at IS NULL;", [stamp, bot]),
            ("""
            UPDATE bot_group_turns SET state = 'cancelled', updated_at = ?
            WHERE bot_id = ? AND state IN ('planned', 'waiting_for_bot');
            """, [stamp, bot]),
        ]
        for (sql, values) in steps {
            let statement = try db.prepare(sql)
            defer { statement.reset() }
            for (index, value) in values.enumerated() { try statement.bind(Int32(index + 1), value) }
            _ = try statement.step()
        }
    }

    // MARK: - Internals

    private static func key(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    private static func requiredName(_ raw: String, what: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BotStoreError.invalidInput("\(what) cannot be empty.") }
        return trimmed
    }

    private static func validate(_ group: BotGroupConversation, participants: [BotID]) throws {
        guard !participants.isEmpty else {
            throw BotStoreError.invalidInput("A group needs at least one bot.")
        }
        guard participants.count <= BotGroupConversation.maxParticipants else {
            throw BotStoreError.invalidInput(
                "A group can have at most \(BotGroupConversation.maxParticipants) bots."
            )
        }
        guard (0...BotGroupConversation.maxAutoHopsCap).contains(group.maxAutoHops) else {
            throw BotStoreError.invalidInput(
                "Hand-offs must be between 0 and \(BotGroupConversation.maxAutoHopsCap)."
            )
        }
        if group.policy == .lead, group.leadBotID == nil {
            throw BotStoreError.invalidInput("Choose a lead bot for a lead-policy group.")
        }
        if let lead = group.leadBotID, !participants.contains(lead) {
            throw BotStoreError.invalidInput("The lead bot must be in the group.")
        }
    }

    /// Order-preserving, de-duplicated, and every bot must exist and be live.
    private func liveBotIDs(_ ids: [BotID], database: SQLiteDB) throws -> [BotID] {
        var seen = Set<BotID>()
        var result: [BotID] = []
        for id in ids where seen.insert(id).inserted {
            guard let bot = try loadBot(id: id, database: database), bot.deletedAt == nil else {
                throw BotStoreError.notFound
            }
            result.append(id)
        }
        return result
    }

    private func lockedTeam(id: BotTeamID, expectedRevision: Int) throws -> BotTeam {
        guard let team = try loadTeam(id: id, database: db) else { throw BotStoreError.notFound }
        guard team.revision == expectedRevision else { throw BotStoreError.revisionConflict }
        return team
    }

    private func bumpTeamLocked(_ team: BotTeam) throws {
        let update = try db.prepare("UPDATE bot_teams SET revision = ?, updated_at = ? WHERE id = ?;")
        defer { update.reset() }
        try update.bind(1, team.revision)
        try update.bind(2, string(team.updatedAt))
        try update.bind(3, Self.key(team.id.value))
        _ = try update.step()
    }

    private func replaceTeamMembersLocked(teamID: BotTeamID, botIDs: [BotID], now: Date) throws {
        let previous = try db.prepare("SELECT bot_id, added_at FROM bot_team_members WHERE team_id = ?;")
        defer { previous.reset() }
        try previous.bind(1, Self.key(teamID.value))
        var addedAt: [String: String] = [:]
        while try previous.step() {
            if let bot = previous.columnText(0), let added = previous.columnText(1) { addedAt[bot] = added }
        }
        previous.reset()
        let clear = try db.prepare("DELETE FROM bot_team_members WHERE team_id = ?;")
        defer { clear.reset() }
        try clear.bind(1, Self.key(teamID.value))
        _ = try clear.step()
        clear.reset()
        let insert = try db.prepare("""
            INSERT INTO bot_team_members(team_id, bot_id, sort_order, added_at) VALUES(?, ?, ?, ?);
            """)
        defer { insert.reset() }
        for (index, botID) in botIDs.enumerated() {
            insert.reset()
            let bot = Self.key(botID.value)
            try insert.bind(1, Self.key(teamID.value))
            try insert.bind(2, bot)
            try insert.bind(3, index)
            try insert.bind(4, addedAt[bot] ?? string(now))
            _ = try insert.step()
        }
        insert.reset()
    }

    private func insertParticipantLocked(
        group: BotGroupConversation,
        botID: BotID,
        sortOrder: Int,
        now: Date
    ) throws {
        let conversation = BotConversation(
            botID: botID,
            title: group.title,
            hidden: true,
            createdAt: now,
            updatedAt: now,
            groupID: group.id
        )
        let insertConversation = try db.prepare("""
            INSERT INTO bot_conversations(
                id, bot_id, title, pinned, hidden, unread, attention_state,
                linked_agent_thread_id, created_at, updated_at, group_id
            ) VALUES(?, ?, ?, 0, 1, 0, 'none', NULL, ?, ?, ?);
            """)
        defer { insertConversation.reset() }
        try insertConversation.bind(1, Self.key(conversation.id.value))
        try insertConversation.bind(2, Self.key(botID.value))
        try insertConversation.bind(3, conversation.title)
        try insertConversation.bind(4, string(now))
        try insertConversation.bind(5, string(now))
        try insertConversation.bind(6, Self.key(group.id.value))
        _ = try insertConversation.step()

        let insertParticipant = try db.prepare("""
            INSERT INTO bot_group_participants(group_id, bot_id, member_conversation_id, sort_order, joined_at)
            VALUES(?, ?, ?, ?, ?);
            """)
        defer { insertParticipant.reset() }
        try insertParticipant.bind(1, Self.key(group.id.value))
        try insertParticipant.bind(2, Self.key(botID.value))
        try insertParticipant.bind(3, Self.key(conversation.id.value))
        try insertParticipant.bind(4, sortOrder)
        try insertParticipant.bind(5, string(now))
        _ = try insertParticipant.step()
    }

    private func markParticipantLeftLocked(groupID: BotGroupID, botID: BotID, now: Date) throws {
        let update = try db.prepare("""
            UPDATE bot_group_participants SET left_at = ? WHERE group_id = ? AND bot_id = ? AND left_at IS NULL;
            """)
        defer { update.reset() }
        try update.bind(1, string(now))
        try update.bind(2, Self.key(groupID.value))
        try update.bind(3, Self.key(botID.value))
        _ = try update.step()
    }

    private func cancelPendingTurnsLocked(groupID: BotGroupID, botID: BotID?, now: Date) throws {
        let update = try db.prepare("""
            UPDATE bot_group_turns SET state = 'cancelled', updated_at = ?
            WHERE group_id = ? AND state IN ('planned', 'waiting_for_bot')
            \(botID == nil ? "" : "AND bot_id = ?");
            """)
        defer { update.reset() }
        try update.bind(1, string(now))
        try update.bind(2, Self.key(groupID.value))
        if let botID { try update.bind(3, Self.key(botID.value)) }
        _ = try update.step()
    }

    private func writeGroupLocked(_ group: BotGroupConversation) throws {
        let update = try db.prepare("""
            UPDATE bot_group_conversations
            SET title = ?, team_id = ?, policy = ?, lead_bot_id = ?, max_auto_hops = ?,
                pinned = ?, hidden = ?, unread = ?, attention_state = ?, revision = ?, updated_at = ?
            WHERE id = ?;
            """)
        defer { update.reset() }
        try update.bind(1, group.title)
        try update.bind(2, group.teamID.map { Self.key($0.value) })
        try update.bind(3, group.policy.rawValue)
        try update.bind(4, group.leadBotID.map { Self.key($0.value) })
        try update.bind(5, group.maxAutoHops)
        try update.bind(6, group.pinned)
        try update.bind(7, group.hidden)
        try update.bind(8, group.unread)
        try update.bind(9, group.attentionState.rawValue)
        try update.bind(10, group.revision)
        try update.bind(11, string(group.updatedAt))
        try update.bind(12, Self.key(group.id.value))
        _ = try update.step()
    }

    private func loadTeam(id: BotTeamID, database: SQLiteDB) throws -> BotTeam? {
        let statement = try database.prepare(Self.teamSelect + " WHERE id = ? LIMIT 1;")
        defer { statement.reset() }
        try statement.bind(1, Self.key(id.value))
        return try statement.step() ? try decodeTeam(statement) : nil
    }

    private func loadGroup(id: BotGroupID, database: SQLiteDB) throws -> BotGroupConversation? {
        let statement = try database.prepare(Self.groupSelect + " WHERE id = ? LIMIT 1;")
        defer { statement.reset() }
        try statement.bind(1, Self.key(id.value))
        return try statement.step() ? try decodeGroup(statement) : nil
    }

    private func loadParticipants(
        groupID: BotGroupID,
        includeLeft: Bool,
        database: SQLiteDB
    ) throws -> [BotGroupParticipant] {
        let statement = try database.prepare("""
            SELECT group_id, bot_id, member_conversation_id, sort_order, joined_at, left_at,
                   seen_room_message_id, seen_room_created_at
            FROM bot_group_participants
            WHERE group_id = ?\(includeLeft ? "" : " AND left_at IS NULL")
            ORDER BY sort_order, joined_at, bot_id;
            """)
        defer { statement.reset() }
        try statement.bind(1, Self.key(groupID.value))
        var participants: [BotGroupParticipant] = []
        while try statement.step() { participants.append(try decodeParticipant(statement)) }
        return participants
    }

    private func loadTurn(id: BotGroupTurnID, database: SQLiteDB) throws -> BotGroupTurn? {
        let statement = try database.prepare(Self.turnSelect + " WHERE id = ? LIMIT 1;")
        defer { statement.reset() }
        try statement.bind(1, Self.key(id.value))
        return try statement.step() ? try decodeTurn(statement) : nil
    }

    private func loadTurns(
        groupID: BotGroupID,
        states: [BotGroupTurn.State],
        database: SQLiteDB
    ) throws -> [BotGroupTurn] {
        let marks = Array(repeating: "?", count: states.count).joined(separator: ",")
        let statement = try database.prepare(
            Self.turnSelect + " WHERE group_id = ? AND state IN (\(marks)) ORDER BY ordinal, created_at, id;"
        )
        defer { statement.reset() }
        try statement.bind(1, Self.key(groupID.value))
        for (index, state) in states.enumerated() { try statement.bind(Int32(index + 2), state.rawValue) }
        var turns: [BotGroupTurn] = []
        while try statement.step() { turns.append(try decodeTurn(statement)) }
        return turns
    }

    private static func uuid(_ raw: String?) -> UUID? { raw.flatMap(UUID.init(uuidString:)) }

    private func decodeTeam(_ statement: SQLiteStatement) throws -> BotTeam {
        guard let id = Self.uuid(statement.columnText(0)),
              let name = statement.columnText(1),
              let created = date(statement.columnText(6)),
              let updated = date(statement.columnText(7))
        else { throw BotStoreError.invalidRow("bot_teams") }
        return BotTeam(
            id: BotTeamID(id),
            name: name,
            description: statement.columnText(2) ?? "",
            avatarSymbol: statement.columnText(3) ?? "person.3.fill",
            sortOrder: Int(statement.columnInt64(4)),
            revision: Int(statement.columnInt64(5)),
            createdAt: created,
            updatedAt: updated
        )
    }

    private func decodeTeamMember(_ statement: SQLiteStatement) throws -> BotTeamMember {
        guard let team = Self.uuid(statement.columnText(0)),
              let bot = Self.uuid(statement.columnText(1)),
              let added = date(statement.columnText(3))
        else { throw BotStoreError.invalidRow("bot_team_members") }
        return BotTeamMember(
            teamID: BotTeamID(team),
            botID: BotID(bot),
            sortOrder: Int(statement.columnInt64(2)),
            addedAt: added
        )
    }

    private func decodeGroup(_ statement: SQLiteStatement) throws -> BotGroupConversation {
        guard let id = Self.uuid(statement.columnText(0)),
              let title = statement.columnText(1),
              let room = Self.uuid(statement.columnText(3)),
              let policy = statement.columnText(4).flatMap(BotGroupPolicy.init(rawValue:)),
              let attention = statement.columnText(10).flatMap(BotAttentionState.init(rawValue:)),
              let created = date(statement.columnText(12)),
              let updated = date(statement.columnText(13))
        else { throw BotStoreError.invalidRow("bot_group_conversations") }
        return BotGroupConversation(
            id: BotGroupID(id),
            title: title,
            teamID: Self.uuid(statement.columnText(2)).map(BotTeamID.init),
            roomThreadID: AgentThreadID(room),
            policy: policy,
            leadBotID: Self.uuid(statement.columnText(5)).map(BotID.init),
            maxAutoHops: Int(statement.columnInt64(6)),
            pinned: statement.columnInt64(7) != 0,
            hidden: statement.columnInt64(8) != 0,
            unread: statement.columnInt64(9) != 0,
            attentionState: attention,
            revision: Int(statement.columnInt64(11)),
            createdAt: created,
            updatedAt: updated
        )
    }

    private func decodeParticipant(_ statement: SQLiteStatement) throws -> BotGroupParticipant {
        guard let group = Self.uuid(statement.columnText(0)),
              let bot = Self.uuid(statement.columnText(1)),
              let conversation = Self.uuid(statement.columnText(2)),
              let joined = date(statement.columnText(4))
        else { throw BotStoreError.invalidRow("bot_group_participants") }
        return BotGroupParticipant(
            groupID: BotGroupID(group),
            botID: BotID(bot),
            memberConversationID: BotConversationID(conversation),
            sortOrder: Int(statement.columnInt64(3)),
            joinedAt: joined,
            leftAt: date(statement.columnText(5)),
            seenRoomMessageID: Self.uuid(statement.columnText(6)).map(AgentMessageID.init),
            seenRoomCreatedAt: date(statement.columnText(7))
        )
    }

    private func decodeTurn(_ statement: SQLiteStatement) throws -> BotGroupTurn {
        guard let id = Self.uuid(statement.columnText(0)),
              let group = Self.uuid(statement.columnText(1)),
              let round = Self.uuid(statement.columnText(2)),
              let bot = Self.uuid(statement.columnText(4)),
              let state = statement.columnText(7).flatMap(BotGroupTurn.State.init(rawValue:)),
              let roomMessage = Self.uuid(statement.columnText(8)),
              let created = date(statement.columnText(12)),
              let updated = date(statement.columnText(13))
        else { throw BotStoreError.invalidRow("bot_group_turns") }
        return BotGroupTurn(
            id: BotGroupTurnID(id),
            groupID: BotGroupID(group),
            roundID: BotGroupRoundID(round),
            triggerMessageID: Self.uuid(statement.columnText(3)).map(AgentMessageID.init),
            botID: BotID(bot),
            ordinal: Int(statement.columnInt64(5)),
            hop: Int(statement.columnInt64(6)),
            state: state,
            roomMessageID: AgentMessageID(roomMessage),
            memberRunID: Self.uuid(statement.columnText(9)).map(AgentRunID.init),
            submitKey: statement.columnText(10),
            error: statement.columnText(11),
            createdAt: created,
            updatedAt: updated
        )
    }

    private static let teamSelect = """
        SELECT id, name, description, avatar_symbol, sort_order, revision, created_at, updated_at
        FROM bot_teams
        """

    private static let groupSelect = """
        SELECT id, title, team_id, room_thread_id, policy, lead_bot_id, max_auto_hops,
               pinned, hidden, unread, attention_state, revision, created_at, updated_at
        FROM bot_group_conversations
        """

    private static let turnSelect = """
        SELECT id, group_id, round_id, trigger_message_id, bot_id, ordinal, hop, state,
               room_message_id, member_run_id, submit_key, error, created_at, updated_at
        FROM bot_group_turns
        """
}
