import CryptoKit
import Foundation

public enum BotPublishError: Error, Equatable, CustomStringConvertible {
    case handleEmpty
    case handleConflict
    case revisionConflict
    case controlPlaneDisabled
    case invalidRevision
    case accountCap

    public var description: String {
        switch self {
        case .handleEmpty:
            return "Bot handle is empty or invalid."
        case .handleConflict:
            return "Bot handle is already used or retired."
        case .revisionConflict:
            return "Bot revision changed; publish again."
        case .controlPlaneDisabled:
            return "Bot control plane is off."
        case .invalidRevision:
            return "Bot revision is invalid."
        case .accountCap:
            return "Account limit of 50 live bots reached."
        }
    }
}

/// Fail-closed gates. Later capabilities cannot run if the control plane is off.
public struct BotControlPlaneFlags: Codable, Sendable, Equatable {
    public var botsControlPlaneEnabled: Bool
    public var botsMemoryEnabled: Bool
    public var botsEffectsEnabled: Bool
    public var botsAutonomyEnabled: Bool
    public var botsDesktopVMEnabled: Bool
    public var botsDesktopRemoteEnabled: Bool
    public var botsChannelsEnabled: Bool

    public init(
        botsControlPlaneEnabled: Bool = true,
        botsMemoryEnabled: Bool = true,
        botsEffectsEnabled: Bool = false,
        botsAutonomyEnabled: Bool = false,
        botsDesktopVMEnabled: Bool = false,
        botsDesktopRemoteEnabled: Bool = false,
        botsChannelsEnabled: Bool = false
    ) {
        self.botsControlPlaneEnabled = botsControlPlaneEnabled
        self.botsMemoryEnabled = botsMemoryEnabled
        self.botsEffectsEnabled = botsEffectsEnabled
        self.botsAutonomyEnabled = botsAutonomyEnabled
        self.botsDesktopVMEnabled = botsDesktopVMEnabled
        self.botsDesktopRemoteEnabled = botsDesktopRemoteEnabled
        self.botsChannelsEnabled = botsChannelsEnabled
    }

    public var isBotControlPlaneActive: Bool { botsControlPlaneEnabled }
    public var isBotMemoryActive: Bool { botsControlPlaneEnabled && botsMemoryEnabled }
    public var isBotEffectsActive: Bool { botsControlPlaneEnabled && botsEffectsEnabled }
    public var isBotAutonomyActive: Bool { botsControlPlaneEnabled && botsAutonomyEnabled }
    public var isBotDesktopVMActive: Bool { botsControlPlaneEnabled && botsDesktopVMEnabled }
    public var isBotDesktopRemoteActive: Bool { botsControlPlaneEnabled && botsDesktopRemoteEnabled }
    public var isBotChannelsActive: Bool { botsControlPlaneEnabled && botsChannelsEnabled }
}

public enum BotDesktopKind: String, Codable, Sendable, CaseIterable {
    case logicalExecutionSpace
    case dedicatedLocalVM
    case managedRemoteMac

    /// Honest P1a copy — this kind is not a VM or a dedicated Desktop.
    public static let logicalExecutionSpaceHonestyLabel =
        "Same macOS account; not isolated. Not a dedicated Desktop."

    /// Decode-only leftover. Display and publish resolve to Logical execution space.
    public static let dedicatedLocalVMHonestyLabel =
        "Guest is not running yet. Work still uses this Mac account; not isolated."

    public var honestyLabel: String {
        switch self {
        case .logicalExecutionSpace:
            return Self.logicalExecutionSpaceHonestyLabel
        case .dedicatedLocalVM:
            return Self.dedicatedLocalVMHonestyLabel
        case .managedRemoteMac:
            return "Managed remote Mac Desktop. Off until the remote flag is on."
        }
    }

    public var displayTitle: String {
        switch self {
        case .logicalExecutionSpace:
            return "Logical execution space"
        case .dedicatedLocalVM:
            return "Dedicated local VM"
        case .managedRemoteMac:
            return "Managed remote Mac"
        }
    }

    public var statusPill: String {
        switch self {
        case .logicalExecutionSpace:
            return "Logical space"
        case .dedicatedLocalVM:
            return "Local VM · not running"
        case .managedRemoteMac:
            return "Remote Mac · not shipped"
        }
    }

    /// Kinds Studio may offer. Dedicated local VM and Managed remote Mac stay persist-only leftovers.
    public static let advertisedKinds: [BotDesktopKind] = [
        .logicalExecutionSpace,
    ]

    public var isAdvertised: Bool { Self.advertisedKinds.contains(self) }

    /// Leftover Dedicated local VM / Managed remote Mac still decode; display and publish use Logical execution space.
    public var advertisedOrLogical: BotDesktopKind {
        isAdvertised ? self : .logicalExecutionSpace
    }

    public func isSelectable(flags: BotControlPlaneFlags) -> Bool {
        switch self {
        case .logicalExecutionSpace:
            return flags.isBotControlPlaneActive
        case .dedicatedLocalVM, .managedRemoteMac:
            return false
        }
    }
}

public enum BotAttentionState: String, Codable, Sendable, Equatable {
    case none
    case working
    case unreadActivity
    case needsAttention
}

public enum BotAttentionItemKind: String, Codable, Sendable, Equatable {
    case question
    case approval
    case handoff
    case unread
    case blocked
    case unknownEffect
}

public enum BotRoutineCopy {
    public static let testRunHonestyCaption =
        "Test runs are real work. App-closed schedules stay off until autonomy is enabled."
}

/// Desk always launches supervised. Self-config can persist leftover
/// `full_access` / `auto_accept_edits`. Those must not compile as live power.
public enum BotPermission {
    public static let advertisedModes: [AgentPermissionMode] = [.supervised]

    public static let honestyLabel =
        "Supervised. Ask before tool actions. Host-brokered writes stay off."

    public static func advertisedOrSupervised(_ mode: AgentPermissionMode) -> AgentPermissionMode {
        advertisedModes.contains(mode) ? mode : .supervised
    }
}

/// Hermes seeds `SOUL.md` and falls back when it is empty. OpenClaw seeds
/// `SOUL.md` / `IDENTITY.md` on first run. An empty Bot soul used to compile
/// as "No standing instructions." — a New Agent then only saw "You are New Agent."
///
/// Identity (name/role) is its own compile layer. Admitted tools are too —
/// a custom soul must not hide Desk-admitted tools. The starter is replaceable
/// standing rules.
public enum BotStandingInstructions {
    /// Unique last line so Studio can refresh the starter without overwriting a custom soul.
    public static let generatedSignature =
        "Do not invent tools, files, accounts, or access you do not have."

    /// Must stay identical to `BotSelfConfigCatalog` mutate tools.
    public static let rememberFactTool = "bot_put_memory"
    public static let changeJobTool = "bot_set_settings"
    public static let forgetFactTool = "bot_forget_memory"
    public static let setSkillTool = "bot_set_skill"
    public static let saveRoutineTool = "bot_save_routine"
    public static let setRoutineEnabledTool = "bot_set_routine_enabled"
    /// Must stay identical to `BotBrowserCatalog.open` / `get` / `waitLogin`.
    public static let openBrowserTool = "bot_browser_open"
    public static let getBrowserTool = "bot_browser_get"
    public static let waitLoginTool = "bot_browser_wait_login"

    public static let generatedCapabilityLine =
        "When asked to remember a fact, call \(rememberFactTool). When asked to change your name, job, standing instructions, description, route, or notifications, call \(changeJobTool)."

    public static let generatedMutateLine =
        "When asked to forget a fact, call \(forgetFactTool). When asked to enable or disable a skill, call \(setSkillTool). When asked to create or change a routine, call \(saveRoutineTool). When asked to turn a routine on or off, call \(setRoutineEnabledTool)."

    public static let generatedBrowserLine =
        "When asked to open a website, call \(openBrowserTool). When asked what is open in that browser, call \(getBrowserTool). When asked to wait for a login, call \(waitLoginTool). That browser is this teammate's, not the user's."

    /// Compiler layer. Starter soul must not own these names.
    public static let admittedToolsText = [
        generatedCapabilityLine,
        generatedMutateLine,
        generatedBrowserLine,
    ].joined(separator: "\n")

    public static func fallback(name _: String, title _: String, description _: String = "") -> String {
        [
            "Do the job. Ask when blocked. Prefer concrete work over ceremony.",
            generatedSignature,
        ].joined(separator: "\n")
    }

    public static func looksGenerated(_ soul: String) -> Bool {
        let trimmed = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasSuffix(generatedSignature)
    }

    /// Custom soul wins. Empty or starter text resolves to the built-in default.
    public static func resolved(
        name: String,
        title: String,
        description: String = "",
        soul: String
    ) -> String {
        if looksGenerated(soul) {
            return fallback(name: name, title: title, description: description)
        }
        return soul.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct BotDefinition: Codable, Sendable, Equatable {
    public static let liveAccountCap = 50

    public var id: BotID
    public var handle: String
    public var name: String
    public var title: String
    public var description: String
    public var avatarSymbol: String
    public var pinned: Bool
    public var hidden: Bool
    public var currentRevisionID: BotRevisionID?
    public var directoryEpoch: Int
    public var notificationsEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var workspaceID: WorkspaceID?

    public init(
        id: BotID = BotID(),
        handle: String,
        name: String,
        title: String,
        description: String,
        avatarSymbol: String = "person.crop.circle",
        pinned: Bool = false,
        hidden: Bool = false,
        currentRevisionID: BotRevisionID? = nil,
        directoryEpoch: Int = 1,
        notificationsEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        workspaceID: WorkspaceID? = nil
    ) {
        self.id = id
        self.handle = handle
        self.name = name
        self.title = title
        self.description = description
        self.avatarSymbol = avatarSymbol
        self.pinned = pinned
        self.hidden = hidden
        self.currentRevisionID = currentRevisionID
        self.directoryEpoch = directoryEpoch
        self.notificationsEnabled = notificationsEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.workspaceID = workspaceID
    }
}

public struct BotRevisionDraft: Codable, Sendable, Equatable {
    public var name: String
    public var title: String
    public var description: String
    public var soul: String
    public var provider: AgentProvider
    public var providerInstanceID: String
    public var model: String
    public var reasoningEffort: AgentReasoningEffort
    public var compatibleRouteSet: [String]
    public var permissionMode: AgentPermissionMode
    public var desktopKind: BotDesktopKind

    public init(
        name: String,
        title: String,
        description: String,
        soul: String = "",
        provider: AgentProvider,
        providerInstanceID: String,
        model: String,
        reasoningEffort: AgentReasoningEffort = .medium,
        compatibleRouteSet: [String] = ["default"],
        permissionMode: AgentPermissionMode = .supervised,
        desktopKind: BotDesktopKind = .logicalExecutionSpace
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.soul = soul
        self.provider = provider
        self.providerInstanceID = providerInstanceID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.compatibleRouteSet = compatibleRouteSet
        self.permissionMode = permissionMode
        self.desktopKind = desktopKind
    }
}

public struct BotRevision: Codable, Sendable, Equatable {
    public var id: BotRevisionID
    public var botID: BotID
    public var revisionNumber: Int
    public var name: String
    public var title: String
    public var description: String
    public var soul: String
    public var provider: AgentProvider
    public var providerInstanceID: String
    public var model: String
    public var reasoningEffort: AgentReasoningEffort
    public var compatibleRouteSet: [String]
    public var permissionMode: AgentPermissionMode
    public var desktopKind: BotDesktopKind
    public var digest: String
    public var publishedAt: Date
    public var supersedesRevisionID: BotRevisionID?

    public init(
        id: BotRevisionID = BotRevisionID(),
        botID: BotID,
        revisionNumber: Int,
        name: String,
        title: String,
        description: String,
        soul: String,
        provider: AgentProvider,
        providerInstanceID: String,
        model: String,
        reasoningEffort: AgentReasoningEffort,
        compatibleRouteSet: [String],
        permissionMode: AgentPermissionMode,
        desktopKind: BotDesktopKind,
        digest: String,
        publishedAt: Date = Date(),
        supersedesRevisionID: BotRevisionID? = nil
    ) {
        self.id = id
        self.botID = botID
        self.revisionNumber = revisionNumber
        self.name = name
        self.title = title
        self.description = description
        self.soul = soul
        self.provider = provider
        self.providerInstanceID = providerInstanceID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.compatibleRouteSet = compatibleRouteSet
        self.permissionMode = permissionMode
        self.desktopKind = desktopKind
        self.digest = digest
        self.publishedAt = publishedAt
        self.supersedesRevisionID = supersedesRevisionID
    }

    public static func digest(
        botID: BotID,
        name: String,
        title: String,
        description: String,
        soul: String,
        provider: AgentProvider,
        providerInstanceID: String,
        model: String,
        reasoningEffort: AgentReasoningEffort,
        compatibleRouteSet: [String],
        permissionMode: AgentPermissionMode,
        desktopKind: BotDesktopKind
    ) -> String {
        let routes = compatibleRouteSet.sorted().joined(separator: ",")
        let payload = [
            "bot_id=\(botID.value.uuidString.lowercased())",
            "name=\(name)",
            "title=\(title)",
            "description=\(description)",
            "soul=\(soul)",
            "provider=\(provider.rawValue)",
            "provider_instance_id=\(providerInstanceID)",
            "model=\(model)",
            "reasoning_effort=\(reasoningEffort.rawValue)",
            "compatible_route_set=\(routes)",
            "permission_mode=\(permissionMode.rawValue)",
            "desktop_kind=\(desktopKind.rawValue)",
        ].joined(separator: "\n")
        return BotDigest.sha256Hex(payload)
    }

    public static func digest(botID: BotID, draft: BotRevisionDraft) -> String {
        digest(
            botID: botID,
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
            desktopKind: draft.desktopKind
        )
    }
}

public struct BotMemoryItem: Codable, Sendable, Equatable {
    public var id: BotMemoryItemID
    public var botID: BotID
    public var currentRevisionID: UUID
    public var content: String
    public var provenance: String
    public var trusted: Bool
    public var source: String
    public var forgottenAt: Date?
    public var expiresAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: BotMemoryItemID = BotMemoryItemID(),
        botID: BotID,
        currentRevisionID: UUID,
        content: String,
        provenance: String,
        trusted: Bool,
        source: String,
        forgottenAt: Date? = nil,
        expiresAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.botID = botID
        self.currentRevisionID = currentRevisionID
        self.content = content
        self.provenance = provenance
        self.trusted = trusted
        self.source = source
        self.forgottenAt = forgottenAt
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BotMemoryItemRevision: Codable, Sendable, Equatable {
    public var id: UUID
    public var itemID: BotMemoryItemID
    public var botID: BotID
    public var revisionNumber: Int
    public var content: String
    public var provenance: String
    public var trusted: Bool
    public var source: String
    public var createdAt: Date
    public var supersedesRevisionID: UUID?

    public init(
        id: UUID = UUID(),
        itemID: BotMemoryItemID,
        botID: BotID,
        revisionNumber: Int,
        content: String,
        provenance: String,
        trusted: Bool,
        source: String,
        createdAt: Date = Date(),
        supersedesRevisionID: UUID? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.botID = botID
        self.revisionNumber = revisionNumber
        self.content = content
        self.provenance = provenance
        self.trusted = trusted
        self.source = source
        self.createdAt = createdAt
        self.supersedesRevisionID = supersedesRevisionID
    }
}

public struct BotConversation: Codable, Sendable, Equatable {
    public var id: BotConversationID
    public var botID: BotID
    public var title: String
    public var pinned: Bool
    public var hidden: Bool
    public var unread: Bool
    public var attentionState: BotAttentionState
    public var linkedAgentThreadID: AgentThreadID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: BotConversationID = BotConversationID(),
        botID: BotID,
        title: String,
        pinned: Bool = false,
        hidden: Bool = false,
        unread: Bool = false,
        attentionState: BotAttentionState = .none,
        linkedAgentThreadID: AgentThreadID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.botID = botID
        self.title = title
        self.pinned = pinned
        self.hidden = hidden
        self.unread = unread
        self.attentionState = attentionState
        self.linkedAgentThreadID = linkedAgentThreadID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BotAttentionItem: Codable, Sendable, Equatable {
    public var id: BotAttentionItemID
    public var botID: BotID
    public var conversationID: BotConversationID?
    public var kind: BotAttentionItemKind
    public var title: String
    public var detail: String
    public var createdAt: Date
    public var acknowledgedAt: Date?

    public init(
        id: BotAttentionItemID = BotAttentionItemID(),
        botID: BotID,
        conversationID: BotConversationID? = nil,
        kind: BotAttentionItemKind,
        title: String,
        detail: String = "",
        createdAt: Date = Date(),
        acknowledgedAt: Date? = nil
    ) {
        self.id = id
        self.botID = botID
        self.conversationID = conversationID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.acknowledgedAt = acknowledgedAt
    }
}

public struct BotRoutineDefinition: Codable, Sendable, Equatable {
    public var id: BotRoutineID
    public var botID: BotID
    public var name: String
    public var prompt: String
    public var scheduleNote: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: BotRoutineID = BotRoutineID(),
        botID: BotID,
        name: String,
        prompt: String,
        scheduleNote: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.botID = botID
        self.name = name
        self.prompt = prompt
        self.scheduleNote = scheduleNote
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BotRoutineActivation: Codable, Sendable, Equatable {
    public var routineID: BotRoutineID
    public var botID: BotID
    public var isEnabled: Bool
    public var lastTestRunRequestedAt: Date?
    public var updatedAt: Date

    public init(
        routineID: BotRoutineID,
        botID: BotID,
        isEnabled: Bool = false,
        lastTestRunRequestedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.routineID = routineID
        self.botID = botID
        self.isEnabled = isEnabled
        self.lastTestRunRequestedAt = lastTestRunRequestedAt
        self.updatedAt = updatedAt
    }
}

public struct BotRoutine: Codable, Sendable, Equatable {
    public var definition: BotRoutineDefinition
    public var activation: BotRoutineActivation

    public init(definition: BotRoutineDefinition, activation: BotRoutineActivation) {
        self.definition = definition
        self.activation = activation
    }
}

/// Per-Bot enablement of a catalog skill. Duplicate copies these; conversation
/// history and memory do not. `skillID` is a catalog id, never a filesystem path.
public struct BotSkillBinding: Codable, Sendable, Equatable {
    public var botID: BotID
    public var skillID: String
    public var enabled: Bool
    public var digest: String?
    public var updatedAt: Date

    public init(
        botID: BotID,
        skillID: String,
        enabled: Bool,
        digest: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.botID = botID
        self.skillID = skillID
        self.enabled = enabled
        self.digest = digest
        self.updatedAt = updatedAt
    }
}

extension BotHandle {
    public static let maxLength = 32

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")

    /// Trim, drop a leading `@`, lowercase. `nil` if empty, longer than 32, or not `[a-z0-9_-]`.
    public static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        value = value.lowercased()
        guard (1...maxLength).contains(value.count) else { return nil }
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    public static func derive(from raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("@") { value.removeFirst() }
        var out = ""
        out.reserveCapacity(min(value.count, maxLength))
        for character in value {
            if character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-") {
                out.append(character)
            } else if character.isWhitespace || character == "." {
                if out.last != "-" { out.append("-") }
            }
        }
        while out.contains("--") {
            out = out.replacingOccurrences(of: "--", with: "-")
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if out.count > maxLength { out = String(out.prefix(maxLength)) }
        return normalize(out)
    }
}

enum BotDigest {
    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    static func sha256Hex(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data(raw.utf8))
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }
}
