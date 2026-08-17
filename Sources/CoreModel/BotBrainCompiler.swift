import Foundation

/// One RemoteCode-controlled layer in a Bot Brain compile.
public struct BotContextLayer: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: Kind
    public var title: String
    public var text: String
    public var included: Bool
    public var reason: String

    public enum Kind: String, Codable, Sendable {
        case identity
        case desktop
        case permission
        case route
        case notifications
        case tools
        case description
        case soul
        case memory
        case skill
        case routine
        case browser
        case user
    }

    public init(
        id: String,
        kind: Kind,
        title: String,
        text: String,
        included: Bool,
        reason: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.included = included
        self.reason = reason
    }
}

/// What a model call compiled, including exclusions. Preview uses the same
/// compiler as send so Source/Effective cannot drift from the adapter payload.
public struct ContextAssemblyReceipt: Codable, Sendable, Equatable, Identifiable {
    public static let compilerVersion = "bots.brain.v1"

    public var id: UUID
    public var botID: BotID
    public var conversationID: BotConversationID?
    public var runID: AgentRunID?
    public var revisionID: BotRevisionID
    public var revisionNumber: Int
    public var revisionDigest: String
    public var provider: AgentProvider
    public var model: String
    public var permissionMode: AgentPermissionMode
    public var desktopKind: BotDesktopKind
    public var compilerVersion: String
    public var compiledPayload: String
    public var payloadDigest: String
    public var layers: [BotContextLayer]
    public var assembledAt: Date

    public init(
        id: UUID = UUID(),
        botID: BotID,
        conversationID: BotConversationID? = nil,
        runID: AgentRunID? = nil,
        revisionID: BotRevisionID,
        revisionNumber: Int,
        revisionDigest: String,
        provider: AgentProvider,
        model: String,
        permissionMode: AgentPermissionMode,
        desktopKind: BotDesktopKind,
        compilerVersion: String = ContextAssemblyReceipt.compilerVersion,
        compiledPayload: String,
        payloadDigest: String,
        layers: [BotContextLayer],
        assembledAt: Date = Date()
    ) {
        self.id = id
        self.botID = botID
        self.conversationID = conversationID
        self.runID = runID
        self.revisionID = revisionID
        self.revisionNumber = revisionNumber
        self.revisionDigest = revisionDigest
        self.provider = provider
        self.model = model
        self.permissionMode = permissionMode
        self.desktopKind = desktopKind
        self.compilerVersion = compilerVersion
        self.compiledPayload = compiledPayload
        self.payloadDigest = payloadDigest
        self.layers = layers
        self.assembledAt = assembledAt
    }

    public var includedLayers: [BotContextLayer] { layers.filter(\.included) }
    public var excludedLayers: [BotContextLayer] { layers.filter { !$0.included } }
    public var memoryLayers: [BotContextLayer] { layers.filter { $0.kind == .memory } }
}

/// Studio already shows the workspace name. Compile name + cwd so
/// first-chat "which repo?" cannot invent a folder. Custom soul must
/// not hide advertised workspace. Blank name/cwd compile as isolation only.
public struct BotWorkspaceHonesty: Codable, Sendable, Equatable {
    public var name: String
    public var cwd: String

    public init(name: String, cwd: String = "") {
        self.name = name
        self.cwd = cwd
    }

    public var placeLabel: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return cwd }
        if cwd.isEmpty { return name }
        return "\(name) (\(cwd))"
    }
}

/// Compiles Source Brain layers into the Effective payload sent to a provider.
public enum BotBrainCompiler {
    public static func assemble(
        bot: BotDefinition,
        revision: BotRevision,
        userText: String,
        memory: [BotMemoryItem] = [],
        skills: [BotSkillBinding] = [],
        routines: [BotRoutine] = [],
        workspace: BotWorkspaceHonesty? = nil,
        browser: BotBrowserTarget? = nil,
        conversationID: BotConversationID? = nil,
        runID: AgentRunID? = nil,
        now: Date = Date()
    ) -> ContextAssemblyReceipt {
        let payload = composeRunPrompt(
            bot: bot,
            revision: revision,
            userText: userText,
            memory: memory,
            skills: skills,
            routines: routines,
            workspace: workspace,
            browser: browser
        )
        return ContextAssemblyReceipt(
            botID: bot.id,
            conversationID: conversationID,
            runID: runID,
            revisionID: revision.id,
            revisionNumber: revision.revisionNumber,
            revisionDigest: revision.digest,
            provider: revision.provider,
            model: revision.model,
            permissionMode: BotPermission.advertisedOrSupervised(revision.permissionMode),
            desktopKind: revision.desktopKind.advertisedOrLogical,
            compiledPayload: payload,
            payloadDigest: BotDigest.sha256Hex(payload),
            layers: sourceLayers(
                bot: bot,
                revision: revision,
                userText: userText,
                memory: memory,
                skills: skills,
                routines: routines,
                workspace: workspace,
                browser: browser
            ),
            assembledAt: now
        )
    }

    /// Exact adapter payload. Keep this body stable — Desk turns already persist it.
    public static func composeRunPrompt(
        bot: BotDefinition,
        revision: BotRevision,
        userText: String,
        memory: [BotMemoryItem] = [],
        skills: [BotSkillBinding] = [],
        routines: [BotRoutine] = [],
        workspace: BotWorkspaceHonesty? = nil,
        browser: BotBrowserTarget? = nil
    ) -> String {
        var lines: [String] = []
        if let identity = identityLine(
            name: bot.name,
            handle: bot.handle,
            title: revision.title,
            avatarSymbol: bot.avatarSymbol
        ) {
            lines.append(identity)
        }
        lines.append("Working space: \(workingSpaceText(for: revision, workspace: workspace))")
        lines.append("Permission: \(BotPermission.honestyLabel)")
        lines.append("Notifications: \(notificationsLine(enabled: bot.notificationsEnabled))")
        lines.append("Route: \(routeLine(provider: revision.provider, model: revision.model))")
        lines.append(BotStandingInstructions.admittedToolsText)
        if let browser = browserLine(browser) {
            lines.append(browser)
        }
        if let description = descriptionLine(revision.description) {
            lines.append(description)
        }
        let soul = BotStandingInstructions.resolved(
            name: bot.name,
            title: revision.title,
            description: revision.description,
            soul: revision.soul
        )
        if !soul.isEmpty {
            // Studio already says Instructions. Compile that name so
            // first-chat "what are your Instructions?" cannot invent a hop.
            // Custom soul still wins the body.
            lines.append("Instructions:")
            lines.append(soul)
        }
        let liveMemory = memory.filter { $0.forgottenAt == nil && $0.trusted }
        if !liveMemory.isEmpty {
            lines.append("Trusted memory:")
            lines.append(contentsOf: liveMemory.map(Self.memoryLine))
        }
        let enabled = skills.filter(\.enabled).map(\.skillID).sorted()
        if !enabled.isEmpty {
            // Studio already says Skills. Compile that name so first-chat
            // "which Skills?" cannot invent a hop. Off stays out.
            lines.append("Skills: \(enabled.joined(separator: ", "))")
        }
        let liveRoutines = routines.filter(\.activation.isEnabled)
            .sorted { $0.definition.name.localizedCaseInsensitiveCompare($1.definition.name) == .orderedAscending }
        if !liveRoutines.isEmpty {
            // Studio already says Active. Compile that name so first-chat
            // "which are Active?" cannot invent a hop. Off stays out.
            lines.append("Active routines (not while the app is closed):")
            lines.append(contentsOf: liveRoutines.map(Self.routineLine))
        }
        lines.append("User request:")
        lines.append(userText)
        return lines.joined(separator: "\n\n")
    }

    static func workingSpaceText(
        for revision: BotRevision,
        workspace: BotWorkspaceHonesty? = nil
    ) -> String {
        let isolation = revision.desktopKind.advertisedOrLogical.honestyLabel
        let place = workspace?.placeLabel ?? ""
        return place.isEmpty ? isolation : "\(place). \(isolation)"
    }

    /// Tools already persist last website. Compile it labeled so first-chat
    /// "what's open?" cannot invent a URL. Empty stays omitted. Custom soul
    /// must not hide the advertised last website. Cookies stay out.
    static func browserLine(_ target: BotBrowserTarget?) -> String? {
        let url = target?.url.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !url.isEmpty else { return nil }
        let title = target?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Browser: \(url)" : "Browser: \(title) (\(url))"
    }

    /// Studio already shows Description. Compile it labeled so first-chat
    /// "what's your description?" cannot treat unlabeled prose as soul.
    /// Empty stays omitted. Custom soul must not hide advertised about text.
    static func descriptionLine(_ description: String) -> String? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "Description: \(trimmed)"
    }

    /// Studio already shows Notifications On/Off. Compile them so
    /// first-chat "will you notify me?" cannot invent alerts. Custom soul
    /// must not hide advertised notification power.
    static func notificationsLine(enabled: Bool) -> String {
        enabled
            ? "On. Alerts stay on this Mac; not an isolated Desktop."
            : "Off. This Mac will not alert the owner."
    }

    /// Desk already shows provider + model. Compile them so first-chat
    /// "what model are you?" cannot invent a route. Custom soul must not
    /// hide advertised routing.
    static func routeLine(provider: AgentProvider, model: String) -> String {
        let title = BotRoute.advertisedTitle(for: provider)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? title : "\(title) · \(model)"
    }

    /// Desk already shows `@handle`. Compile it so first-chat "what's your handle?"
    /// cannot invent one. Custom soul must not hide advertised identity.
    /// Studio already says Role. Compile that name so first-chat "what's your
    /// Role?" cannot invent a hop. Empty Role stays omitted. Custom soul
    /// must not hide the advertised job.
    /// Studio already picks Avatar. Compile the advertised chip so first-chat
    /// "what's my avatar?" cannot invent a symbol. Leftover SF paths stay out.
    static func identityLine(
        name: String,
        handle: String,
        title: String,
        avatarSymbol: String = ""
    ) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        var who = name
        if !handle.isEmpty {
            let tagged = "@\(handle)"
            who = who.isEmpty ? tagged : "\(who) (\(tagged))"
        }
        let role = roleLine(title)
        let avatar = avatarLine(avatarSymbol)
        var parts: [String] = []
        if !who.isEmpty {
            parts.append("You are \(who).")
        }
        if let role {
            parts.append("\(role).")
        }
        if let avatar {
            parts.append("\(avatar).")
        }
        if parts.isEmpty { return nil }
        return parts.joined(separator: " ")
    }

    /// Studio says Role. Compile that name, never an unlabeled job after an em-dash.
    static func roleLine(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "Role: \(trimmed)"
    }

    /// Studio says Star / Person. Compile that name, never the SF Symbol.
    static func avatarLine(_ symbol: String) -> String? {
        guard let parsed = BotAvatar.parse(symbol) else { return nil }
        let name = BotAvatar.advertisedName(for: parsed)
        guard !name.contains(".") else { return nil }
        return "Avatar: \(name)"
    }

    /// Desk forget/toggle tools require these keys. Snapshot already
    /// lowercases them. Compile them so first-chat cannot invent a UUID
    /// or a hidden get-settings hop. Custom soul must not hide them.
    static func mutateKey(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    /// Studio already says Remember a fact. Compile that name so first-chat
    /// "what's the Fact?" cannot invent a hop. Forgotten and untrusted stay
    /// out of the payload. Off-path tombstones still use this line in Source.
    static func memoryLine(_ item: BotMemoryItem) -> String {
        "- Fact: \(item.content) [\(mutateKey(item.id.value))]"
    }

    /// Studio already says Instruction and When. Compile those names so
    /// first-chat "what's the Instruction?" cannot invent a hop. Empty
    /// When stays omitted. Off stays out of this line.
    static func routineLine(_ routine: BotRoutine) -> String {
        let name = routine.definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = routine.definition.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = routine.definition.scheduleNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = mutateKey(routine.definition.id.value)
        if note.isEmpty {
            return "- \(name): Instruction: \(prompt) [\(key)]"
        }
        return "- \(name): Instruction: \(prompt). When: \(note) [\(key)]"
    }

    static func sourceLayers(
        bot: BotDefinition,
        revision: BotRevision,
        userText: String,
        memory: [BotMemoryItem],
        skills: [BotSkillBinding],
        routines: [BotRoutine],
        workspace: BotWorkspaceHonesty? = nil,
        browser: BotBrowserTarget? = nil
    ) -> [BotContextLayer] {
        var layers: [BotContextLayer] = []
        if let identity = identityLine(
            name: bot.name,
            handle: bot.handle,
            title: revision.title,
            avatarSymbol: bot.avatarSymbol
        ) {
            layers.append(
                BotContextLayer(
                    id: "identity",
                    kind: .identity,
                    title: "Identity",
                    text: identity,
                    included: true,
                    reason: "Name, handle, role, and avatar compile into the identity line."
                )
            )
        } else {
            layers.append(
                BotContextLayer(
                    id: "identity",
                    kind: .identity,
                    title: "Identity",
                    text: "",
                    included: false,
                    reason: "Name, handle, role, and avatar are empty."
                )
            )
        }

        layers.append(
            BotContextLayer(
                id: "desktop",
                kind: .desktop,
                title: "Working space",
                text: workingSpaceText(for: revision, workspace: workspace),
                included: true,
                reason: "Advertised workspace and execution space. Leftover VM kinds compile as logical space."
            )
        )

        layers.append(
            BotContextLayer(
                id: "permission",
                kind: .permission,
                title: "Permission",
                text: BotPermission.honestyLabel,
                included: true,
                reason: "Advertised supervised route. Leftover full-access kinds compile as supervised."
            )
        )

        layers.append(
            BotContextLayer(
                id: "notifications",
                kind: .notifications,
                title: "Notifications",
                text: notificationsLine(enabled: bot.notificationsEnabled),
                included: true,
                reason: "Advertised notification toggle. Studio already shows On or Off."
            )
        )

        layers.append(
            BotContextLayer(
                id: "route",
                kind: .route,
                title: "Route",
                text: routeLine(provider: revision.provider, model: revision.model),
                included: true,
                reason: "Advertised provider and model. Desk already shows this route."
            )
        )

        layers.append(
            BotContextLayer(
                id: "tools",
                kind: .tools,
                title: "Admitted tools",
                text: BotStandingInstructions.admittedToolsText,
                included: true,
                reason: "Desk-admitted tools. Custom soul must not hide them."
            )
        )

        if let browser = browserLine(browser) {
            layers.append(
                BotContextLayer(
                    id: "browser",
                    kind: .browser,
                    title: "Browser",
                    text: browser,
                    included: true,
                    reason: "Advertised last website. Tools already persist it."
                )
            )
        }

        if let description = descriptionLine(revision.description) {
            layers.append(
                BotContextLayer(
                    id: "description",
                    kind: .description,
                    title: "Description",
                    text: description,
                    included: true,
                    reason: "Advertised about text. Studio already shows Description."
                )
            )
        } else {
            layers.append(
                BotContextLayer(
                    id: "description",
                    kind: .description,
                    title: "Description",
                    text: "",
                    included: false,
                    reason: "No description."
                )
            )
        }

        let publishedSoul = revision.soul.trimmingCharacters(in: .whitespacesAndNewlines)
        let soul = BotStandingInstructions.resolved(
            name: bot.name,
            title: revision.title,
            description: revision.description,
            soul: revision.soul
        )
        let soulReason = BotStandingInstructions.looksGenerated(publishedSoul)
            ? "Built-in teammate default. Write standing instructions to replace it."
            : "Standing instructions are published with the revision."
        layers.append(
            BotContextLayer(
                id: "soul",
                kind: .soul,
                title: "Standing instructions",
                text: soul,
                included: true,
                reason: soulReason
            )
        )

        for item in memory {
            let forgotten = item.forgottenAt != nil
            let included = !forgotten && item.trusted
            let reason: String
            if forgotten {
                reason = "Forgotten. Tombstone stays out of the payload."
            } else if !item.trusted {
                reason = "Untrusted candidate. Not authority until review."
            } else {
                reason = "Trusted and not forgotten."
            }
            layers.append(
                BotContextLayer(
                    id: "memory-\(item.id.value.uuidString.lowercased())",
                    kind: .memory,
                    title: "Memory",
                    text: memoryLine(item),
                    included: included,
                    reason: reason
                )
            )
        }

        for binding in skills.sorted(by: { $0.skillID < $1.skillID }) {
            layers.append(
                BotContextLayer(
                    id: "skill-\(binding.skillID)",
                    kind: .skill,
                    title: "Skill",
                    text: binding.skillID,
                    included: binding.enabled,
                    reason: binding.enabled
                        ? "Enabled catalog binding."
                        : "Disabled. Not injected."
                )
            )
        }

        for routine in routines.sorted(by: {
            $0.definition.name.localizedCaseInsensitiveCompare($1.definition.name) == .orderedAscending
        }) {
            layers.append(
                BotContextLayer(
                    id: "routine-\(routine.definition.id.value.uuidString.lowercased())",
                    kind: .routine,
                    title: "Routine",
                    text: routineLine(routine),
                    included: routine.activation.isEnabled,
                    reason: routine.activation.isEnabled
                        ? "Active. Runs only while the app is open."
                        : "Off. Not injected."
                )
            )
        }

        layers.append(
            BotContextLayer(
                id: "user",
                kind: .user,
                title: "User request",
                text: userText,
                included: true,
                reason: "User request for this call."
            )
        )
        return layers
    }
}
