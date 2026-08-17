import Foundation
import CoreModel

public enum BotSelfConfigError: Error, Equatable, CustomStringConvertible {
    case callerMissing
    case crossBot
    case notFound
    case invalid(String)

    public var description: String {
        switch self {
        case .callerMissing:
            return "Bot self-config requires RC_REMOTE_CODE_BOT_ID on the calling run."
        case .crossBot:
            return "A bot can only read or change its own settings."
        case .notFound:
            return "Calling bot was not found."
        case .invalid(let message):
            return message
        }
    }
}

/// Live catalog. Handshake and dispatch must use these names.
public enum BotSelfConfigCatalog: Sendable {
    public static let serverName = "remotecode-bot-self-config"
    public static let cliArgument = "bot-self-config"
    public static let callerEnvironmentKey = "RC_REMOTE_CODE_BOT_ID"

    public static let getSettings = "bot_get_settings"
    public static let setSettings = "bot_set_settings"
    public static let putMemory = "bot_put_memory"
    public static let forgetMemory = "bot_forget_memory"
    public static let correctMemory = "bot_correct_memory"
    public static let setSkill = "bot_set_skill"
    public static let removeSkill = "bot_remove_skill"
    public static let saveRoutine = "bot_save_routine"
    public static let setRoutineEnabled = "bot_set_routine_enabled"

    public static var toolNames: [String] {
        [
            getSettings, setSettings, putMemory, forgetMemory, correctMemory,
            setSkill, removeSkill, saveRoutine, setRoutineEnabled,
        ]
    }

    public static func toolCatalog() -> [[String: Any]] {
        toolNames.map { name in
            [
                "name": name,
                "description": description(for: name),
                "inputSchema": schema(for: name),
            ]
        }
    }

    public static func description(for name: String) -> String {
        switch name {
        case getSettings:
            return "Read this bot's live identity, soul, route, desktop, notifications, memory, skills, and routines."
        case setSettings:
            return "Publish this bot's own name, Role, Instructions, description, Default route, Model, notifications, or avatar. Same path as Studio Save. \(BotRoute.fallbackOrderHonesty) \(BotBrainCompiler.handleCreateOnlyHonesty) \(BotBrainCompiler.workspaceHostAssignedHonesty) \(BotBrainCompiler.approvalsHonesty) \(BotPermission.honestyLabel) \(BotDesktopKind.logicalExecutionSpaceHonestyLabel) \(BotBrainCompiler.testRunHonesty) \(BotBrainCompiler.memoryHonesty) \(BotBrainCompiler.forgetHonesty) \(BotBrainCompiler.correctHonesty) \(BotBrainCompiler.skillsHonesty) \(BotBrainCompiler.removeHonesty) \(BotBrainCompiler.routinesHonesty) \(BotBrainCompiler.instructionHonesty) \(BotBrainCompiler.whenHonesty) \(BotBrainCompiler.activeHonesty) \(BotBrainCompiler.websiteHonesty) \(BotBrainCompiler.userRequestHonesty)"
        case putMemory:
            return "Remember a fact on this bot."
        case forgetMemory:
            return "Forget one of this bot's memory facts."
        case correctMemory:
            return "Correct one of this bot's memory facts. Writes a new revision. Same path as Studio Correct."
        case setSkill:
            return "Add a catalog skill or turn it Enabled or Off. Same path as Studio Add. Disable is not unbind."
        case removeSkill:
            return "Remove a catalog skill from this bot. Same path as Studio Remove. Disable is not unbind."
        case saveRoutine:
            return "Create or update a routine's name, instruction, or when. Same path as Studio Save routine."
        case setRoutineEnabled:
            return "Set a routine Active or Off. Same path as Studio Active."
        default:
            return name
        }
    }

    public static func schema(for name: String) -> [String: Any] {
        let botID: [String: Any] = ["bot_id": ["type": "string", "description": "Must match the calling bot or be omitted."]]
        switch name {
        case getSettings:
            return ["type": "object", "properties": botID]
        case setSettings:
            return [
                "type": "object",
                "properties": botID.merging([
                    "name": ["type": "string"],
                    "title": ["type": "string", "description": "Role / job. Same field as Studio Role."],
                    "description": ["type": "string"],
                    "soul": ["type": "string", "description": "Instructions. Same field as Studio Instructions."],
                    "provider": ["type": "string", "description": "Default route. Claude, Codex, or Grok. Same field as Studio Default route."],
                    "provider_instance_id": ["type": "string"],
                    "model": ["type": "string", "description": "Model. Same field as Studio Model."],
                    "notifications_enabled": ["type": "boolean", "description": "Notifications On/Off."],
                    "avatar_symbol": ["type": "string", "description": "Avatar. Same field as Studio Avatar."],
                ]) { _, new in new },
            ]
        case putMemory:
            return [
                "type": "object",
                "properties": botID.merging([
                    "content": ["type": "string", "description": "Fact. Same field as Studio Remember a fact."],
                ]) { _, new in new },
                "required": ["content"],
            ]
        case forgetMemory:
            return [
                "type": "object",
                "properties": botID.merging(["memory_id": ["type": "string"]]) { _, new in new },
                "required": ["memory_id"],
            ]
        case correctMemory:
            return [
                "type": "object",
                "properties": botID.merging([
                    "memory_id": ["type": "string"],
                    "content": ["type": "string", "description": "Fact. Same field as Studio Remember a fact."],
                ]) { _, new in new },
                "required": ["memory_id", "content"],
            ]
        case setSkill:
            return [
                "type": "object",
                "properties": botID.merging([
                    "skill_id": ["type": "string", "description": "Catalog id. Same field as Studio Add."],
                    "enabled": ["type": "boolean", "description": "Enabled. Omit to Add. Same field as Studio Skills."],
                ]) { _, new in new },
                "required": ["skill_id"],
            ]
        case removeSkill:
            return [
                "type": "object",
                "properties": botID.merging(["skill_id": ["type": "string"]]) { _, new in new },
                "required": ["skill_id"],
            ]
        case saveRoutine:
            return [
                "type": "object",
                "properties": botID.merging([
                    "name": ["type": "string"],
                    "prompt": ["type": "string", "description": "Instruction. Same field as Studio Instruction."],
                    "schedule_note": ["type": "string", "description": "When. Same field as Studio When."],
                    "routine_id": ["type": "string"],
                ]) { _, new in new },
                "required": ["name", "prompt"],
            ]
        case setRoutineEnabled:
            return [
                "type": "object",
                "properties": botID.merging([
                    "routine_id": ["type": "string"],
                    "enabled": ["type": "boolean", "description": "Active. Same field as Studio Active."],
                ]) { _, new in new },
                "required": ["routine_id", "enabled"],
            ]
        default:
            return ["type": "object", "properties": [String: Any]()]
        }
    }
}

public struct BotSelfConfigSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var handle: String
    public var name: String
    public var title: String
    public var description: String
    public var avatarSymbol: String
    public var soul: String
    public var provider: String
    public var providerInstanceID: String
    public var model: String
    public var permissionMode: String
    public var desktopKind: String
    public var notificationsEnabled: Bool
    public var memory: [Item]
    public var skills: [Skill]
    public var routines: [Routine]

    // Tools require notifications_enabled / provider_instance_id. Snapshot
    // used Swift camelCase, so same-turn notify/account persist invented a hop.
    enum CodingKeys: String, CodingKey {
        case id
        case handle
        case name
        case title
        case description
        case avatarSymbol = "avatar_symbol"
        case soul
        case provider
        case providerInstanceID = "provider_instance_id"
        case model
        case permissionMode
        case desktopKind
        case notificationsEnabled = "notifications_enabled"
        case memory
        case skills
        case routines
    }

    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var content: String

        // Tools require memory_id. Snapshot used to say id, which collided
        // with the bot id, so same-turn forget invented a hop.
        enum CodingKeys: String, CodingKey {
            case id = "memory_id"
            case content
        }
    }

    public struct Skill: Codable, Equatable, Sendable {
        public var skillID: String
        public var enabled: Bool

        enum CodingKeys: String, CodingKey {
            case skillID = "skill_id"
            case enabled
        }
    }

    public struct Routine: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var prompt: String
        public var scheduleNote: String
        public var enabled: Bool

        enum CodingKeys: String, CodingKey {
            case id = "routine_id"
            case name
            case prompt
            case scheduleNote = "schedule_note"
            case enabled
        }
    }
}

public struct BotSelfConfigPatch: Equatable, Sendable {
    public var name: String?
    public var title: String?
    public var description: String?
    public var avatarSymbol: String?
    public var soul: String?
    public var provider: AgentProvider?
    public var providerInstanceID: String?
    public var model: String?
    public var permissionMode: AgentPermissionMode?
    public var desktopKind: BotDesktopKind?
    public var notificationsEnabled: Bool?

    public init(
        name: String? = nil,
        title: String? = nil,
        description: String? = nil,
        avatarSymbol: String? = nil,
        soul: String? = nil,
        provider: AgentProvider? = nil,
        providerInstanceID: String? = nil,
        model: String? = nil,
        permissionMode: AgentPermissionMode? = nil,
        desktopKind: BotDesktopKind? = nil,
        notificationsEnabled: Bool? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.avatarSymbol = avatarSymbol
        self.soul = soul
        self.provider = provider
        self.providerInstanceID = providerInstanceID
        self.model = model
        self.permissionMode = permissionMode
        self.desktopKind = desktopKind
        self.notificationsEnabled = notificationsEnabled
    }

    public var isEmpty: Bool {
        name == nil && title == nil && description == nil && avatarSymbol == nil && soul == nil
            && provider == nil && providerInstanceID == nil && model == nil
            && permissionMode == nil && desktopKind == nil && notificationsEnabled == nil
    }
}

/// Same persist path Studio uses. Bound to one calling bot.
public struct BotSelfConfigService: Sendable {
    public let callerBotID: BotID
    public let store: BotStore

    public init(callerBotID: BotID, store: BotStore) {
        self.callerBotID = callerBotID
        self.store = store
    }

    public static func make(environment: [String: String], store: BotStore) throws -> BotSelfConfigService {
        guard let caller = callerID(from: environment) else {
            throw BotSelfConfigError.callerMissing
        }
        return BotSelfConfigService(callerBotID: caller, store: store)
    }

    public static func callerID(from environment: [String: String]) -> BotID? {
        guard let raw = environment[BotSelfConfigCatalog.callerEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: raw) else { return nil }
        return BotID(uuid)
    }

    public static func openStore(environment: [String: String]) throws -> BotStore {
        let override = environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let override, !override.isEmpty else {
            throw BotSelfConfigError.invalid("Bot self-config requires RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY.")
        }
        let dbPath = URL(fileURLWithPath: override, isDirectory: true)
            .appendingPathComponent("remotecode.sqlite")
            .path
        let db = try SQLiteDB(path: dbPath)
        try Schema.migrate(db)
        return BotStore(db: db)
    }

    public func assertOwn(_ requested: BotID?) throws {
        if let requested, requested != callerBotID {
            throw BotSelfConfigError.crossBot
        }
    }

    public func snapshot() throws -> BotSelfConfigSnapshot {
        guard let bot = try store.get(id: callerBotID), bot.deletedAt == nil else {
            throw BotSelfConfigError.notFound
        }
        let revision = try bot.currentRevisionID.flatMap { try store.getRevision(id: $0) }
        let memory = try store.listMemory(botID: callerBotID)
        let skills = try store.listSkillBindings(botID: callerBotID)
        let routines = try store.listRoutines(botID: callerBotID)
        return BotSelfConfigSnapshot(
            id: bot.id.value.uuidString.lowercased(),
            handle: bot.handle,
            name: bot.name,
            title: bot.title,
            description: bot.description,
            avatarSymbol: bot.avatarSymbol,
            soul: revision?.soul ?? "",
            provider: (revision?.provider ?? .claude).rawValue,
            providerInstanceID: revision?.providerInstanceID ?? "",
            model: revision?.model ?? "",
            permissionMode: BotPermission.advertisedOrSupervised(revision?.permissionMode ?? .supervised).rawValue,
            desktopKind: (revision?.desktopKind ?? .logicalExecutionSpace).advertisedOrLogical.rawValue,
            notificationsEnabled: bot.notificationsEnabled,
            memory: memory.map { .init(id: $0.id.value.uuidString.lowercased(), content: $0.content) },
            skills: skills.map { .init(skillID: $0.skillID, enabled: $0.enabled) },
            routines: routines.map {
                .init(
                    id: $0.definition.id.value.uuidString.lowercased(),
                    name: $0.definition.name,
                    prompt: $0.definition.prompt,
                    scheduleNote: $0.definition.scheduleNote,
                    enabled: $0.activation.isEnabled
                )
            }
        )
    }

    @discardableResult
    public func apply(_ patch: BotSelfConfigPatch) throws -> BotSelfConfigSnapshot {
        guard let bot = try store.get(id: callerBotID), bot.deletedAt == nil else {
            throw BotSelfConfigError.notFound
        }
        guard let currentID = bot.currentRevisionID,
              let current = try store.getRevision(id: currentID) else {
            throw BotSelfConfigError.invalid("Bot has no published revision.")
        }
        let name = patch.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? current.name
        guard !name.isEmpty else { throw BotSelfConfigError.invalid("Name is required.") }
        let desktop = (patch.desktopKind ?? current.desktopKind).advertisedOrLogical
        let permission = BotPermission.advertisedOrSupervised(
            patch.permissionMode ?? current.permissionMode
        )
        let provider = patch.provider ?? current.provider
        let providerChanged = patch.provider != nil && patch.provider != current.provider
        let requestedModel = patch.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = if !requestedModel.isEmpty {
            requestedModel
        } else if providerChanged {
            BotRoute.defaultModel(for: provider)
        } else {
            current.model
        }
        let requestedInstance = patch.providerInstanceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let providerInstanceID = if !requestedInstance.isEmpty {
            requestedInstance
        } else if providerChanged {
            provider.rawValue
        } else {
            current.providerInstanceID
        }
        let draft = BotRevisionDraft(
            name: name,
            title: patch.title ?? current.title,
            description: patch.description ?? current.description,
            soul: patch.soul ?? current.soul,
            provider: provider,
            providerInstanceID: providerInstanceID,
            model: model,
            reasoningEffort: current.reasoningEffort,
            compatibleRouteSet: current.compatibleRouteSet,
            permissionMode: permission,
            desktopKind: desktop
        )
        _ = try store.publish(
            botID: callerBotID,
            expectedCurrentRevisionID: currentID,
            draft: draft,
            avatarSymbol: patch.avatarSymbol,
            notificationsEnabled: patch.notificationsEnabled
        )
        return try snapshot()
    }

    public func putMemory(content: String) throws -> BotSelfConfigSnapshot {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BotSelfConfigError.invalid("Memory content is required.") }
        _ = try store.putMemory(
            botID: callerBotID,
            content: trimmed,
            provenance: "bot-self-config",
            trusted: true,
            source: "self"
        )
        return try snapshot()
    }

    public func forgetMemory(id: BotMemoryItemID) throws -> BotSelfConfigSnapshot {
        let items = try store.listMemory(botID: callerBotID, includeForgotten: true)
        guard let item = items.first(where: { $0.id == id }) else {
            throw BotSelfConfigError.notFound
        }
        guard item.botID == callerBotID else { throw BotSelfConfigError.crossBot }
        try store.forgetMemory(id: id)
        return try snapshot()
    }

    public func correctMemory(id: BotMemoryItemID, content: String) throws -> BotSelfConfigSnapshot {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BotSelfConfigError.invalid("Memory content is required.") }
        let items = try store.listMemory(botID: callerBotID, includeForgotten: true)
        guard let item = items.first(where: { $0.id == id }) else {
            throw BotSelfConfigError.notFound
        }
        guard item.botID == callerBotID else { throw BotSelfConfigError.crossBot }
        _ = try store.correctMemory(id: id, content: trimmed)
        return try snapshot()
    }

    public func setSkill(skillID: String, enabled: Bool) throws -> BotSelfConfigSnapshot {
        try store.setSkillBinding(
            BotSkillBinding(botID: callerBotID, skillID: skillID, enabled: enabled)
        )
        return try snapshot()
    }

    public func removeSkill(skillID: String) throws -> BotSelfConfigSnapshot {
        let trimmed = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw BotStoreError.invalidRow("skill id must be a catalog id, not a path")
        }
        let existing = try store.listSkillBindings(botID: callerBotID)
        guard existing.contains(where: { $0.skillID == trimmed }) else {
            throw BotSelfConfigError.notFound
        }
        try store.removeSkillBinding(botID: callerBotID, skillID: trimmed)
        return try snapshot()
    }

    public func saveRoutine(name: String, prompt: String, scheduleNote: String, id: BotRoutineID?) throws -> BotSelfConfigSnapshot {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else {
            throw BotSelfConfigError.invalid("Routine name and instruction are required.")
        }
        if let id {
            let existing = try store.listRoutines(botID: callerBotID)
            guard existing.contains(where: { $0.definition.id == id }) else {
                throw BotSelfConfigError.crossBot
            }
        }
        try store.saveRoutine(
            BotRoutineDefinition(
                id: id ?? BotRoutineID(),
                botID: callerBotID,
                name: trimmedName,
                prompt: trimmedPrompt,
                scheduleNote: scheduleNote
            )
        )
        return try snapshot()
    }

    public func setRoutineEnabled(id: BotRoutineID, enabled: Bool) throws -> BotSelfConfigSnapshot {
        let existing = try store.listRoutines(botID: callerBotID)
        guard existing.contains(where: { $0.definition.id == id }) else {
            throw BotSelfConfigError.crossBot
        }
        try store.setRoutineEnabled(id: id, enabled: enabled)
        return try snapshot()
    }

    /// Single dispatch table used by the MCP handler and tests.
    public func call(name: String, arguments: [String: Any] = [:]) throws -> BotSelfConfigSnapshot {
        try assertOwn(Self.parseOptionalBotID(arguments["bot_id"]))
        switch name {
        case BotSelfConfigCatalog.getSettings:
            return try snapshot()
        case BotSelfConfigCatalog.setSettings:
            let patch = try Self.parsePatch(arguments)
            if patch.isEmpty { return try snapshot() }
            return try apply(patch)
        case BotSelfConfigCatalog.putMemory:
            // Tools and Studio say Remember a fact. Schema key stays content.
            guard let content = Self.firstString(arguments, keys: ["content", "fact"]) else {
                throw BotSelfConfigError.invalid("Memory content is required.")
            }
            return try putMemory(content: content)
        case BotSelfConfigCatalog.forgetMemory:
            return try forgetMemory(id: BotMemoryItemID(try Self.parseUUID(arguments["memory_id"], label: "memory_id")))
        case BotSelfConfigCatalog.correctMemory:
            guard let content = Self.firstString(arguments, keys: ["content", "fact"]) else {
                throw BotSelfConfigError.invalid("Memory content is required.")
            }
            return try correctMemory(
                id: BotMemoryItemID(try Self.parseUUID(arguments["memory_id"], label: "memory_id")),
                content: content
            )
        case BotSelfConfigCatalog.setSkill:
            guard let skillID = arguments["skill_id"] as? String else {
                throw BotSelfConfigError.invalid("skill_id is required.")
            }
            // Studio Add only sends the catalog id. Omit enabled to bind it Enabled.
            let enabled = arguments["enabled"] == nil
                ? true
                : try Self.parseBool(arguments["enabled"], label: "enabled")
            return try setSkill(skillID: skillID, enabled: enabled)
        case BotSelfConfigCatalog.removeSkill:
            guard let skillID = arguments["skill_id"] as? String else {
                throw BotSelfConfigError.invalid("skill_id is required.")
            }
            return try removeSkill(skillID: skillID)
        case BotSelfConfigCatalog.saveRoutine:
            // Tools and Studio say Instruction / When. Schema keys stay prompt / schedule_note.
            guard let name = arguments["name"] as? String,
                  let prompt = Self.firstString(arguments, keys: ["prompt", "instruction"]) else {
                throw BotSelfConfigError.invalid("Routine name and instruction are required.")
            }
            let routineID = Self.parseOptionalUUID(arguments["routine_id"]).map(BotRoutineID.init)
            let note = Self.firstString(arguments, keys: ["schedule_note", "when"]) ?? ""
            return try saveRoutine(name: name, prompt: prompt, scheduleNote: note, id: routineID)
        case BotSelfConfigCatalog.setRoutineEnabled:
            // Tools and Studio say Active. Schema key stays enabled.
            let enabledValue = arguments["enabled"] ?? arguments["active"]
            return try setRoutineEnabled(
                id: BotRoutineID(try Self.parseUUID(arguments["routine_id"], label: "routine_id")),
                enabled: try Self.parseBool(enabledValue, label: "enabled")
            )
        default:
            throw BotSelfConfigError.invalid("unknown tool: \(name)")
        }
    }

    public func encodeSnapshot(_ snapshot: BotSelfConfigSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BotSelfConfigError.invalid("Could not encode settings.")
        }
        return text
    }

    static func parseOptionalBotID(_ value: Any?) -> BotID? {
        parseOptionalUUID(value).map(BotID.init)
    }

    static func parsePatch(_ arguments: [String: Any]) throws -> BotSelfConfigPatch {
        // Studio already says Fallback order is not shipped. Compile
        // already labels that honesty. A leftover fallback_order write
        // used to return an empty success, so first-chat invented a
        // persist. Schema does not grow a fallback key.
        if arguments.keys.contains(where: Self.isAdvertisedFallbackOrderKey) {
            throw BotSelfConfigError.invalid(BotRoute.fallbackOrderHonesty)
        }
        // Studio Handle is create-only after first save. Compile already
        // labels that honesty. A leftover handle write used to return an
        // empty success, so first-chat invented a persist. Schema does
        // not grow a handle key. Name still persists.
        if arguments.keys.contains(where: Self.isAdvertisedHandleKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.handleCreateOnlyHonesty)
        }
        // Snapshot still encodes leftover id. A leftover id write used
        // to return an empty success, so first-chat invented a persist
        // from the last get_settings key. leftover identity still
        // succeeded empty after id rejected, so first-chat invented a
        // persist from the dest title and get_settings "live identity".
        // Schema does not grow an id or identity write key. bot_id still
        // owns the caller check. Name still persists. Dest title stays
        // Identity.
        if arguments.keys.contains(where: Self.isAdvertisedIdentityKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.workspaceHostAssignedHonesty)
        }
        // Studio already shows Workspace. Compile already labels that
        // honesty. A leftover workspace / cwd write used to return an
        // empty success, so first-chat invented a persist. Schema does
        // not grow a workspace key. Name still persists.
        if arguments.keys.contains(where: Self.isAdvertisedWorkspaceKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.workspaceHostAssignedHonesty)
        }
        // Studio already says Approval mode. Compile already labels that
        // honesty. A leftover Approval mode / approval / permission_mode
        // write used to coerce to supervised and return success, so
        // first-chat invented a persist. Snapshot camelCase permissionMode
        // used to return an empty success, so first-chat invented a
        // persist from the last get_settings key. leftover supervised
        // still succeeded empty after permission_mode rejected, so
        // first-chat invented a persist from the Desk pill and compile
        // "Supervised." Schema does not grow an approval_mode,
        // permission_mode, permissionMode, or supervised key. Leftover
        // desktop_kind now rejects. Dest title stays Permission.
        if arguments.keys.contains(where: Self.isAdvertisedApprovalModeKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.approvalModeHostAssignedHonesty)
        }
        // Studio already says Desktop. Compile already labels isolation
        // honesty. A leftover Desktop / desktop / desktop_kind write
        // used to coerce to logical and return success, so first-chat
        // invented a persist. Snapshot camelCase desktopKind used to
        // return an empty success, so first-chat invented a persist
        // from the last get_settings key. leftover logical_execution_space
        // still succeeded empty after desktop rejected, so first-chat
        // invented a persist from the compile title. Schema does not
        // grow a desktop, desktop_kind, desktopKind, or
        // logical_execution_space key. Dest title stays Desktop.
        if arguments.keys.contains(where: Self.isAdvertisedDesktopKey) {
            throw BotSelfConfigError.invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel)
        }
        // Studio already says Same macOS account. Compile already labels
        // that honesty. leftover desktop / logical_execution_space already
        // reject. leftover same_macos_account still succeeded empty, so
        // first-chat invented a persist from the advertised honesty
        // phrase. Schema does not grow a same_macos_account write key.
        // leftover desktop still rejects. Name still persists. Dest
        // title stays Desktop.
        if arguments.keys.contains(where: Self.isAdvertisedSameMacOSAccountKey) {
            throw BotSelfConfigError.invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel)
        }
        // Studio already says not isolated. Compile already labels
        // that honesty. leftover desktop / same_macos_account already
        // reject. leftover isolated still succeeded empty, so
        // first-chat invented a persist from the advertised honesty
        // phrase. Schema does not grow an isolated write key.
        // leftover desktop still rejects. leftover same_macos_account
        // still rejects. Name still persists. Dest title stays Desktop.
        if arguments.keys.contains(where: Self.isAdvertisedIsolatedKey) {
            throw BotSelfConfigError.invalid(BotDesktopKind.logicalExecutionSpaceHonestyLabel)
        }
        // Studio Security already says Approvals. Compile already labels
        // Allow once / Deny stay off. A leftover Approvals / allow_once
        // / deny write used to return an empty success, so first-chat
        // invented a persist. Schema does not grow an approvals key.
        // Leftover permission_mode now rejects. Dest title stays
        // Permission.
        if arguments.keys.contains(where: Self.isAdvertisedApprovalsKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.approvalsHonesty)
        }
        // Studio Security already says Host-brokered writes. Compile
        // already labels they stay off. A leftover Host-brokered writes
        // / effects write used to return an empty success, so first-chat
        // invented a persist. Schema does not grow a host_brokered_writes
        // or effects key. Leftover permission_mode now rejects. Dest
        // title stays Permission.
        if arguments.keys.contains(where: Self.isAdvertisedHostBrokeredWritesKey) {
            throw BotSelfConfigError.invalid(BotPermission.honestyLabel)
        }
        // Studio already says Ask before tool actions. Compile already
        // labels that honesty. leftover supervised / host_brokered_writes
        // already reject. leftover ask_before_tool_actions still
        // succeeded empty, so first-chat invented a persist from the
        // advertised honesty phrase. Schema does not grow an
        // ask_before_tool_actions write key. leftover supervised still
        // rejects. Name still persists. Dest title stays Permission.
        if arguments.keys.contains(where: Self.isAdvertisedAskBeforeToolActionsKey) {
            throw BotSelfConfigError.invalid(BotPermission.honestyLabel)
        }
        // Studio Routines already says Test run. Compile already labels
        // do the Instruction now. A leftover Test run / test_run write
        // used to return an empty success, so first-chat invented a
        // persist. Schema does not grow a test_run key. Dest title stays
        // Routine. The owner Test run button stays.
        if arguments.keys.contains(where: Self.isAdvertisedTestRunKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.testRunHonesty)
        }
        // Studio already says Memory. Compile already labels Fact.
        // A leftover Memory / fact write used to return an empty
        // success, so first-chat invented a persist. Snapshot leftover
        // memory_id / content used to return an empty success, so
        // first-chat invented a persist from the last get_settings
        // key. Schema does not grow a memory, memory_id, or content
        // write key. put_memory still persists Fact. forget/correct
        // still own memory_id. Dest title stays Memory.
        if arguments.keys.contains(where: Self.isAdvertisedMemoryKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.memoryHonesty)
        }
        // Studio already says Forget. Compile already names
        // bot_forget_memory. A leftover Forget / forget write used to
        // return an empty success, so first-chat invented a persist.
        // Schema does not grow a forget key. forget_memory still
        // persists Forget. leftover Memory / fact / memory_id still
        // reject. Dest title stays Memory.
        if arguments.keys.contains(where: Self.isAdvertisedForgetKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.forgetHonesty)
        }
        // Studio already says Correct. Compile already names
        // bot_correct_memory. A leftover Correct / correct write used to
        // return an empty success, so first-chat invented a persist.
        // Schema does not grow a correct key. correct_memory still
        // persists Correct. leftover Memory / fact / memory_id / forget
        // still reject. Dest title stays Memory.
        if arguments.keys.contains(where: Self.isAdvertisedCorrectKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.correctHonesty)
        }
        // Studio already says Skills and Add. Compile already labels
        // Skills and names set_skill / Studio Add. A leftover Skills /
        // skill write used to return an empty success, so first-chat
        // invented a persist. leftover add / set_skill still succeeded
        // empty after add_skill rejected, so first-chat invented an
        // Add persist. Schema does not grow a skills or add key.
        // set_skill still persists Add. Dest title stays Skills.
        if arguments.keys.contains(where: Self.isAdvertisedSkillsKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.skillsHonesty)
        }
        // Studio already says Remove. Compile already names
        // bot_remove_skill. A leftover Remove / remove write used to
        // return an empty success, so first-chat invented a persist.
        // Schema does not grow a remove key. remove_skill still
        // persists Remove. leftover Skills / skill / skill_id / add_skill
        // still reject. Dest title stays Skills.
        if arguments.keys.contains(where: Self.isAdvertisedRemoveKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.removeHonesty)
        }
        // Studio already says Routines. Compile already labels Routines.
        // A leftover Routines / routine write used to return an empty
        // success, so first-chat invented a persist. Schema does not
        // grow a routines key. save_routine still persists Instruction
        // / When. set_routine_enabled still persists Active. Dest
        // title stays Routines.
        if arguments.keys.contains(where: Self.isAdvertisedRoutinesKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.routinesHonesty)
        }
        // Studio already says Instruction. Compile already labels
        // Instruction. A leftover instruction write used to return an
        // empty success, so first-chat invented a persist. Snapshot
        // leftover prompt used to return an empty success, so
        // first-chat invented a persist from the last get_settings
        // key. Schema does not grow an instruction or prompt write
        // key. Plural Instructions still persist soul. save_routine
        // still persists Instruction / When. set_routine_enabled
        // still persists Active. Dest title stays Routine.
        if arguments.keys.contains(where: Self.isAdvertisedInstructionKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.instructionHonesty)
        }
        // Studio already says When. Compile already labels When. A
        // leftover when write used to return an empty success, so
        // first-chat invented a persist. Snapshot leftover
        // schedule_note used to return an empty success, so
        // first-chat invented a persist from the last get_settings
        // key. Schema does not grow a when or schedule_note write
        // key. save_routine still persists Instruction / When.
        // set_routine_enabled still persists Active. Dest title stays
        // Routine.
        if arguments.keys.contains(where: Self.isAdvertisedWhenKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.whenHonesty)
        }
        // Studio already says Active. Compile already labels Active. A
        // leftover active / enabled / on / off write used to return an
        // empty success, so first-chat invented a persist. Schema does
        // not grow an active key. save_routine still persists
        // Instruction / When. set_routine_enabled still persists Active.
        // Dest title stays Routine.
        if arguments.keys.contains(where: Self.isAdvertisedActiveKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.activeHonesty)
        }
        // Studio already says last website. Compile already labels
        // Browser. A leftover website / url write used to return an
        // empty success, so first-chat invented a persist. leftover
        // browser still succeeded empty after website rejected, so
        // first-chat invented a persist from the compile heading.
        // Schema does not grow a website or browser key.
        // bot_browser_open still persists Website. Dest title stays
        // Browser.
        if arguments.keys.contains(where: Self.isAdvertisedWebsiteKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.websiteHonesty)
        }
        // Studio dest title already says Admitted tools. Compile already
        // labels Admitted tools. leftover identity already rejects. leftover
        // admitted_tools still succeeded empty, so first-chat invented a
        // persist from the dest title. Schema does not grow an
        // admitted_tools write key. Desk admits the list. Name still
        // persists. Dest title stays Admitted tools.
        if arguments.keys.contains(where: Self.isAdvertisedAdmittedToolsKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.workspaceHostAssignedHonesty)
        }
        // Studio dest title already says User request. Compile already
        // labels User request. leftover admitted_tools already rejects.
        // leftover user_request still succeeded empty, so first-chat
        // invented a persist from the dest title. Schema does not grow
        // a user_request write key. The user request is this turn.
        // Name still persists. Dest title stays User request.
        if arguments.keys.contains(where: Self.isAdvertisedUserRequestKey) {
            throw BotSelfConfigError.invalid(BotBrainCompiler.userRequestHonesty)
        }
        var patch = BotSelfConfigPatch()
        if let name = arguments["name"] as? String { patch.name = name }
        // Tools and Studio say Avatar. Schema key stays avatar_symbol.
        if let raw = firstString(arguments, keys: ["avatar_symbol", "avatar"]) {
            guard let symbol = BotAvatar.parse(raw) else {
                throw BotSelfConfigError.invalid("Unknown avatar: \(raw)")
            }
            patch.avatarSymbol = symbol
        }
        // Tools and Studio say job / Role. Schema key stays title.
        if let title = firstString(arguments, keys: ["title", "job", "role"]) {
            patch.title = title
        }
        if let description = arguments["description"] as? String { patch.description = description }
        // Tools and Studio say Instructions. Schema key stays soul.
        if let soul = firstString(arguments, keys: ["soul", "standing_instructions", "instructions"]) {
            patch.soul = soul
        }
        if let model = arguments["model"] as? String { patch.model = model }
        if let instance = arguments["provider_instance_id"] as? String { patch.providerInstanceID = instance }
        // Tools and Studio say Default route / Grok. Schema key stays provider.
        if let raw = firstString(arguments, keys: ["provider", "route", "default_route"]) {
            guard let parsed = BotRoute.parse(raw) else {
                throw BotSelfConfigError.invalid("Unknown provider: \(raw)")
            }
            patch.provider = parsed.provider
            if patch.model == nil, let model = parsed.model {
                patch.model = model
            }
        }
        if arguments["notifications_enabled"] != nil || arguments["notifications"] != nil {
            let value = arguments["notifications_enabled"] ?? arguments["notifications"]
            patch.notificationsEnabled = try parseBool(value, label: "notifications_enabled")
        }
        return patch
    }

    /// fallback_order is not a schema key. Studio / compile advertise the
    /// name, so parse must fail loud instead of succeeding empty.
    static func isAdvertisedFallbackOrderKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "fallback" || normalized == "fallback_order"
    }

    /// handle is not a schema key. Studio / compile advertise the name,
    /// so parse must fail loud instead of succeeding empty.
    static func isAdvertisedHandleKey(_ key: String) -> Bool {
        var normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        if normalized.hasPrefix("@") {
            normalized.removeFirst()
        }
        return normalized == "handle"
    }

    /// id is not a schema write key. Snapshot still encodes leftover
    /// id, so parse must fail loud instead of succeeding empty.
    /// leftover identity is the same write — compile dest title Identity
    /// and get_settings "live identity" are the advertised names.
    /// bot_id stays the caller-ownership argument.
    static func isAdvertisedIdentityKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "id"
            || normalized == "identity"
    }

    /// workspace is not a schema key. Studio / compile advertise the
    /// name, so parse must fail loud instead of succeeding empty.
    static func isAdvertisedWorkspaceKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "workspace"
            || normalized == "working_space"
            || normalized == "cwd"
    }

    /// approval_mode is not a schema key. Studio / compile advertise the
    /// name, so parse must fail loud instead of succeeding empty.
    /// Leftover permission_mode is the same host-assigned write.
    /// Snapshot camelCase permissionMode is the same write —
    /// get_settings still encodes that leftover name, so parse must
    /// reject it instead of succeeding empty. leftover supervised is
    /// the same write — Desk pill, Studio summary, and compile
    /// "Supervised." are the advertised dest values. Snapshot still
    /// encodes that leftover raw value.
    static func isAdvertisedApprovalModeKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "approval"
            || normalized == "approval_mode"
            || normalized == "permission"
            || normalized == "permission_mode"
            || normalized == "permissionmode"
            || normalized == "supervised"
    }

    /// desktop is not a schema key. Studio / compile advertise the name,
    /// so parse must fail loud instead of succeeding empty. Leftover
    /// desktop_kind is the same host-assigned write. Snapshot camelCase
    /// desktopKind is the same write — get_settings still encodes that
    /// leftover name, so parse must reject it instead of succeeding empty.
    /// leftover logical_execution_space / logical_space are the same
    /// write — compile title Logical execution space and the Logical
    /// space pill are the advertised dest values.
    static func isAdvertisedDesktopKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "desktop"
            || normalized == "desktop_kind"
            || normalized == "desktopkind"
            || normalized == "logical_execution_space"
            || normalized == "logical_space"
    }

    /// same_macos_account is not a schema write key. Studio / compile
    /// advertise Same macOS account, so parse must fail loud instead of
    /// succeeding empty. leftover desktop stays on the Desktop reject.
    /// leftover logical_execution_space stays on the Desktop reject.
    /// Schema does not grow a same_macos_account write key.
    static func isAdvertisedSameMacOSAccountKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "same_macos_account"
            || normalized == "macos_account"
            || normalized == "same_account"
    }

    /// isolated is not a schema write key. Studio / compile advertise
    /// not isolated, so parse must fail loud instead of succeeding
    /// empty. leftover desktop stays on the Desktop reject. leftover
    /// same_macos_account stays on the Same macOS account reject.
    /// Schema does not grow an isolated write key.
    static func isAdvertisedIsolatedKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "isolated"
            || normalized == "not_isolated"
            || normalized == "isolated_desktop"
    }

    /// approvals is not a schema key. Studio / compile advertise the
    /// name, so parse must fail loud instead of succeeding empty.
    /// Leftover permission_mode and advertised Approval mode stay on
    /// the Approval mode reject, not this path.
    static func isAdvertisedApprovalsKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "approvals"
            || normalized == "allow_once"
            || normalized == "deny"
            || normalized == "allow_once_/_deny"
    }

    /// host_brokered_writes is not a schema key. Studio / compile
    /// advertise the name, so parse must fail loud instead of succeeding
    /// empty. Leftover permission_mode stays on the Approval mode
    /// reject. Settings Effects is the same advertised field.
    static func isAdvertisedHostBrokeredWritesKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        return normalized == "host_brokered_writes"
            || normalized == "host_brokered"
            || normalized == "effects"
    }

    /// ask_before_tool_actions is not a schema write key. Studio /
    /// compile advertise Ask before tool actions, so parse must fail
    /// loud instead of succeeding empty. leftover supervised stays
    /// on the Approval mode reject. leftover host_brokered_writes
    /// stays on the Host-brokered writes reject. Schema does not
    /// grow an ask_before_tool_actions write key.
    static func isAdvertisedAskBeforeToolActionsKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "ask_before_tool_actions"
            || normalized == "ask_before"
            || normalized == "tool_actions"
    }

    /// test_run is not a schema key. Studio / compile advertise the
    /// name, so parse must fail loud instead of succeeding empty.
    /// Schema does not grow a test tool. Dest title stays Routine.
    static func isAdvertisedTestRunKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "test_run"
            || normalized == "test_run_requested"
            || normalized == "last_test_run_requested_at"
    }

    /// memory is not a schema key. Studio / compile advertise the
    /// name, so parse must fail loud instead of succeeding empty.
    /// Snapshot leftover memory_id / content are the same write —
    /// get_settings still encodes those leftover names, so parse
    /// must reject them instead of succeeding empty. put_memory
    /// still persists Fact. forget/correct still own memory_id.
    /// Schema does not grow a memory, memory_id, or content write key.
    static func isAdvertisedMemoryKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "memory"
            || normalized == "fact"
            || normalized == "remember"
            || normalized == "remember_a_fact"
            || normalized == "memory_id"
            || normalized == "content"
    }

    /// forget is not a set_settings schema key. Studio / compile
    /// advertise Forget, so parse must fail loud instead of succeeding
    /// empty. forget_memory still persists Forget. Schema does not
    /// grow a forget write key. leftover Memory / fact / memory_id
    /// stay on the Memory reject.
    static func isAdvertisedForgetKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "forget"
            || normalized == "forget_memory"
            || normalized == "forgotten"
    }

    /// correct is not a set_settings schema key. Studio / compile
    /// advertise Correct, so parse must fail loud instead of succeeding
    /// empty. correct_memory still persists Correct. Schema does not
    /// grow a correct write key. leftover Memory / fact / memory_id
    /// stay on the Memory reject. leftover Forget stays on the Forget
    /// reject.
    static func isAdvertisedCorrectKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "correct"
            || normalized == "correct_memory"
            || normalized == "correct_fact"
    }

    /// skills is not a schema key. Studio / compile advertise Skills
    /// and Add, so parse must fail loud instead of succeeding empty.
    /// leftover add / set_skill are the same write — Studio Add and
    /// the catalog name. set_skill still persists Add. Schema does
    /// not grow a skills or add write key.
    static func isAdvertisedSkillsKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "skills"
            || normalized == "skill"
            || normalized == "skill_id"
            || normalized == "add_skill"
            || normalized == "add"
            || normalized == "set_skill"
    }

    /// remove is not a set_settings schema key. Studio / compile
    /// advertise Remove, so parse must fail loud instead of succeeding
    /// empty. remove_skill still persists Remove. Schema does not
    /// grow a remove write key. leftover Skills / skill / skill_id
    /// stay on the Skills reject.
    static func isAdvertisedRemoveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "remove"
            || normalized == "remove_skill"
            || normalized == "unbind"
    }

    /// routines is not a schema key. Studio / compile advertise the
    /// name, so parse must fail loud instead of succeeding empty.
    /// save_routine still persists Instruction / When. Schema does not
    /// grow a routines key.
    static func isAdvertisedRoutinesKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "routines"
            || normalized == "routine"
            || normalized == "routine_id"
            || normalized == "save_routine"
    }

    /// instruction is not a set_settings schema key. Studio / compile
    /// advertise the name, so parse must fail loud instead of succeeding
    /// empty. Snapshot leftover prompt is the same write —
    /// get_settings still encodes that leftover name, so parse must
    /// reject it instead of succeeding empty. Plural instructions still
    /// persist soul. save_routine still persists Instruction. Schema
    /// does not grow an instruction or prompt write key.
    static func isAdvertisedInstructionKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "instruction"
            || normalized == "prompt"
    }

    /// when is not a set_settings schema key. Studio / compile
    /// advertise the name, so parse must fail loud instead of succeeding
    /// empty. Snapshot leftover schedule_note is the same write —
    /// get_settings still encodes that leftover name, so parse must
    /// reject it instead of succeeding empty. save_routine still
    /// persists When. Schema does not grow a when or schedule_note
    /// write key.
    static func isAdvertisedWhenKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "when"
            || normalized == "schedule_note"
    }

    /// active is not a schema key. Studio / compile advertise the name,
    /// so parse must fail loud instead of succeeding empty.
    /// set_routine_enabled still persists Active. Schema does not grow
    /// an active key. Leftover enabled / on / off are the same write.
    static func isAdvertisedActiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "active"
            || normalized == "enabled"
            || normalized == "on"
            || normalized == "off"
    }

    /// website is not a schema key. Studio / compile advertise last
    /// website and label Browser, so parse must fail loud instead of
    /// succeeding empty. bot_browser_open still persists Website.
    /// Schema does not grow a website or browser write key. Leftover
    /// url / last_website / browser are the same write — compile
    /// heading Browser is the advertised dest title.
    static func isAdvertisedWebsiteKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "website"
            || normalized == "url"
            || normalized == "last_website"
            || normalized == "browser"
    }

    /// admitted_tools is not a schema write key. Studio / compile dest
    /// title Admitted tools, so parse must fail loud instead of succeeding
    /// empty. leftover tools / admitted are the same write — layer id
    /// tools and dest title first word. Desk admits the list. Schema
    /// does not grow an admitted_tools write key.
    static func isAdvertisedAdmittedToolsKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "admitted_tools"
            || normalized == "tools"
            || normalized == "admitted"
    }

    /// user_request is not a schema write key. Studio / compile dest
    /// title User request, so parse must fail loud instead of succeeding
    /// empty. leftover user_text is the same write — compose argument
    /// name. The user request is this turn. Schema does not grow a
    /// user_request write key.
    static func isAdvertisedUserRequestKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: " ", with: "_")
        return normalized == "user_request"
            || normalized == "user_text"
    }

    static func firstString(_ arguments: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = arguments[key] as? String { return value }
        }
        return nil
    }

    static func parseUUID(_ value: Any?, label: String) throws -> UUID {
        guard let uuid = parseOptionalUUID(value) else {
            throw BotSelfConfigError.invalid("\(label) is required.")
        }
        return uuid
    }

    static func parseOptionalUUID(_ value: Any?) -> UUID? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return UUID(uuidString: raw)
    }

    static func parseBool(_ value: Any?, label: String) throws -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let raw = value as? String {
            switch raw.lowercased() {
            // Studio already says Active and Enabled. Parse only read
            // on/true, so first-chat "set this Active" invented a hop.
            case "true", "1", "yes", "on", "active", "enabled": return true
            case "false", "0", "no", "off": return false
            default: break
            }
        }
        throw BotSelfConfigError.invalid("\(label) is required.")
    }
}
