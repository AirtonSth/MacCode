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
            return "Publish this bot's own name, job, standing instructions, description, route, or notifications. Same path as Studio Save."
        case putMemory:
            return "Remember a fact on this bot."
        case forgetMemory:
            return "Forget one of this bot's memory facts."
        case correctMemory:
            return "Correct one of this bot's memory facts. Writes a new revision. Same path as Studio Correct."
        case setSkill:
            return "Enable or disable a catalog skill on this bot."
        case removeSkill:
            return "Remove a catalog skill from this bot. Same path as Studio Remove. Disable is not unbind."
        case saveRoutine:
            return "Create or update a routine's name, instruction, or when. Same path as Studio Save routine."
        case setRoutineEnabled:
            return "Enable or disable one of this bot's routines."
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
                    "soul": ["type": "string", "description": "Standing instructions."],
                    "provider": ["type": "string", "description": "Route. Claude, Codex, or Grok."],
                    "provider_instance_id": ["type": "string"],
                    "model": ["type": "string"],
                    "notifications_enabled": ["type": "boolean", "description": "Notifications On/Off."],
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
                    "skill_id": ["type": "string"],
                    "enabled": ["type": "boolean"],
                ]) { _, new in new },
                "required": ["skill_id", "enabled"],
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
                    "enabled": ["type": "boolean"],
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

    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var content: String
    }

    public struct Skill: Codable, Equatable, Sendable {
        public var skillID: String
        public var enabled: Bool
    }

    public struct Routine: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var prompt: String
        public var scheduleNote: String
        public var enabled: Bool
    }
}

public struct BotSelfConfigPatch: Equatable, Sendable {
    public var name: String?
    public var title: String?
    public var description: String?
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
        self.soul = soul
        self.provider = provider
        self.providerInstanceID = providerInstanceID
        self.model = model
        self.permissionMode = permissionMode
        self.desktopKind = desktopKind
        self.notificationsEnabled = notificationsEnabled
    }

    public var isEmpty: Bool {
        name == nil && title == nil && description == nil && soul == nil
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
            return try setSkill(skillID: skillID, enabled: try Self.parseBool(arguments["enabled"], label: "enabled"))
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
            return try setRoutineEnabled(
                id: BotRoutineID(try Self.parseUUID(arguments["routine_id"], label: "routine_id")),
                enabled: try Self.parseBool(arguments["enabled"], label: "enabled")
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
        var patch = BotSelfConfigPatch()
        if let name = arguments["name"] as? String { patch.name = name }
        // Tools and Studio say job / Role. Schema key stays title.
        if let title = firstString(arguments, keys: ["title", "job", "role"]) {
            patch.title = title
        }
        if let description = arguments["description"] as? String { patch.description = description }
        // Tools say standing instructions. Schema key stays soul.
        if let soul = firstString(arguments, keys: ["soul", "standing_instructions"]) {
            patch.soul = soul
        }
        if let model = arguments["model"] as? String { patch.model = model }
        if let instance = arguments["provider_instance_id"] as? String { patch.providerInstanceID = instance }
        // Tools and Studio say route / Grok. Schema key stays provider.
        if let raw = firstString(arguments, keys: ["provider", "route"]) {
            guard let parsed = BotRoute.parse(raw) else {
                throw BotSelfConfigError.invalid("Unknown provider: \(raw)")
            }
            patch.provider = parsed.provider
            if patch.model == nil, let model = parsed.model {
                patch.model = model
            }
        }
        if let raw = arguments["permission_mode"] as? String {
            guard let mode = AgentPermissionMode(rawValue: raw) else {
                throw BotSelfConfigError.invalid("Unknown permission mode: \(raw)")
            }
            patch.permissionMode = mode
        }
        if let raw = arguments["desktop_kind"] as? String {
            guard let kind = BotDesktopKind(rawValue: raw) else {
                throw BotSelfConfigError.invalid("Unknown desktop kind: \(raw)")
            }
            patch.desktopKind = kind
        }
        if arguments["notifications_enabled"] != nil || arguments["notifications"] != nil {
            let value = arguments["notifications_enabled"] ?? arguments["notifications"]
            patch.notificationsEnabled = try parseBool(value, label: "notifications_enabled")
        }
        return patch
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
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: break
            }
        }
        throw BotSelfConfigError.invalid("\(label) is required.")
    }
}
