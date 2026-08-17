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
    /// Studio already shows Workspace. set_settings cannot persist a folder,
    /// so first-chat "use this Workspace" invented a write. Hermes workspace
    /// is host-pinned. Compile that so the model does not invent a persist.
    public static let workspaceHostAssignedHonesty = "Host-assigned. Not a self-config write."

    /// Studio Handle is create-only after first save. Compile already shows
    /// @handle next to Role, so first-chat "change your handle" invented a
    /// write. Hermes address is identity, not self-rewritable. Compile that
    /// so the model does not invent a persist.
    public static let handleCreateOnlyHonesty = "Handle is create-only. Not a self-config write."

    /// Studio already says Approval mode. Compile listed Permission, so
    /// first-chat "what's your Approval mode?" invented a hop. Desk always
    /// launches supervised. Leftover permission_mode writes reject, so
    /// first-chat "set Approval mode to full access" cannot invent a write.
    /// Hermes permission is host-pinned. Compile that so the model does
    /// not invent a persist. Dest Source title stays Permission.
    public static let approvalModeHostAssignedHonesty = "Host-assigned. Not a self-config write."

    /// Studio Security already says Approvals and Allow once / Deny stay
    /// off until P1b. Compile listed Approval mode only, so first-chat
    /// "Allow once" invented a grant. Hermes grants are host-owned.
    /// Compile that so the model does not invent a persist. Dest Source
    /// title stays Permission.
    public static let approvalsHonesty = "Approvals: Allow once / Deny stay off until P1b."

    /// Studio already says Test run. Compile listed Active routines only,
    /// so first-chat "test this routine" invented a hop or a schedule fire.
    /// Hermes test runs are live work, not a fake cron. Compile that so
    /// the model does the Instruction now and does not set Active. Dest
    /// Source title stays Routine. Schema does not grow a test tool.
    public static let testRunHonesty =
        "Test run: do the Instruction now. Does not set Active. \(BotRoutineCopy.testRunHonestyCaption)"

    /// Studio already says Memory and Remember a fact. Compile already
    /// labels Memory / Fact. A leftover Memory / fact write on
    /// set_settings used to return an empty success, so first-chat
    /// invented a persist. Hermes memory writes stay on put_memory.
    /// Dest Source title stays Memory. Schema does not grow a memory key.
    public static let memoryHonesty =
        "Memory: call \(BotStandingInstructions.rememberFactTool). Same path as Studio Remember a fact. Not a set_settings write."

    /// Studio already says Forget. Compile already names bot_forget_memory.
    /// A leftover Forget / forget write on set_settings used to return an
    /// empty success, so first-chat invented a persist. Hermes memory
    /// deletes stay on forget_memory. Dest Source title stays Memory.
    /// Schema does not grow a forget key.
    public static let forgetHonesty =
        "Forget: call \(BotStandingInstructions.forgetFactTool). Same path as Studio Forget. Not a set_settings write."

    /// Studio already says Correct. Compile already names bot_correct_memory.
    /// A leftover Correct / correct write on set_settings used to return
    /// an empty success, so first-chat invented a persist. Hermes memory
    /// revisions stay on correct_memory. Dest Source title stays Memory.
    /// Schema does not grow a correct key.
    public static let correctHonesty =
        "Correct: call \(BotStandingInstructions.correctFactTool). Same path as Studio Correct. Not a set_settings write."

    /// Studio already says Skills. Compile already labels Skills.
    /// A leftover Skills / skill write on set_settings used to return an
    /// empty success, so first-chat invented a persist. Hermes skill
    /// writes stay on set_skill. Dest Source title stays Skills. Schema
    /// does not grow a skills key.
    public static let skillsHonesty =
        "Skills: call \(BotStandingInstructions.setSkillTool). Same path as Studio Add. Not a set_settings write."

    /// Studio already says Remove. Compile already names bot_remove_skill.
    /// A leftover Remove / remove write on set_settings used to return
    /// an empty success, so first-chat invented a persist. Hermes skill
    /// unbinds stay on remove_skill. Dest Source title stays Skills.
    /// Schema does not grow a remove key.
    public static let removeHonesty =
        "Remove: call \(BotStandingInstructions.removeSkillTool). Same path as Studio Remove. Not a set_settings write."

    /// Studio already says Routines. Compile already labels Routines.
    /// A leftover Routines / routine write on set_settings used to return
    /// an empty success, so first-chat invented a persist. Hermes cron
    /// writes stay on save_routine / set_routine_enabled. Dest Source
    /// title stays Routines. Schema does not grow a routines key.
    public static let routinesHonesty =
        "Routines: call \(BotStandingInstructions.saveRoutineTool). Same path as Studio Save routine. Not a set_settings write."

    /// Studio already says Instruction. Compile already labels Instruction.
    /// A leftover instruction write on set_settings used to return an
    /// empty success, so first-chat invented a persist. Hermes cron
    /// writes stay on save_routine. Plural Instructions still persist
    /// soul. Dest Source title stays Routine. Schema does not grow an
    /// instruction key.
    public static let instructionHonesty =
        "Instruction: call \(BotStandingInstructions.saveRoutineTool). Same path as Studio Save routine. Not a set_settings write."

    /// Studio already says When. Compile already labels When. A leftover
    /// when write on set_settings used to return an empty success, so
    /// first-chat invented a persist. Hermes cron writes stay on
    /// save_routine. Dest Source title stays Routine. Schema does not
    /// grow a when key.
    public static let whenHonesty =
        "When: call \(BotStandingInstructions.saveRoutineTool). Same path as Studio Save routine. Not a set_settings write."

    /// Studio already says Active. Compile already labels Active. A leftover
    /// active / enabled / on / off write on set_settings used to return an
    /// empty success, so first-chat invented a persist. Hermes cron
    /// writes stay on set_routine_enabled. Dest Source title stays Routine.
    /// Schema does not grow an active key.
    public static let activeHonesty =
        "Active: call \(BotStandingInstructions.setRoutineEnabledTool). Same path as Studio Active. Not a set_settings write."

    /// Studio already says last website. Compile already labels Browser.
    /// A leftover website / url write on set_settings used to return an
    /// empty success, so first-chat invented a persist. Hermes website
    /// writes stay on bot_browser_open. Dest Source title stays Browser.
    /// Schema does not grow a website key.
    public static let websiteHonesty =
        "Website: call \(BotStandingInstructions.openBrowserTool). Same path as last website. Not a set_settings write."

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
        // Studio already says Workspace. Compile that name so first-chat
        // "which Workspace?" cannot invent a hop. Host-assigned honesty
        // stays so first-chat cannot invent a set_settings write. Dest
        // Source title stays Working space.
        lines.append("Workspace: \(workingSpaceText(workspace))")
        // Studio already says Desktop. Compile that name so first-chat
        // "which Desktop?" cannot invent a hop. Isolation honesty lives
        // here, not on Workspace. Leftover VM kinds compile as logical.
        lines.append("Desktop: \(desktopText(for: revision))")
        // Studio already says Approval mode. Compile that name so first-chat
        // "what's your Approval mode?" cannot invent a hop. Studio Security
        // already says Approvals. Compile that name so first-chat "Allow
        // once" cannot invent a grant. Host-assigned honesty stays so
        // first-chat cannot invent a set_settings write. Dest Source
        // title stays Permission.
        lines.append("Approval mode: \(approvalModeText())")
        lines.append("Notifications: \(notificationsLine(enabled: bot.notificationsEnabled))")
        // Studio already says Default route. Compile that name so first-chat
        // "what's your Default route?" cannot invent a hop. Studio already
        // says Fallback order is not shipped. Compile that honesty so
        // first-chat "if Claude is down use Grok" cannot invent a second
        // route. Dest Source title stays Route.
        lines.append("Default route: \(routeLine(provider: revision.provider, model: revision.model))")
        // Studio already says Model. Compile that name so first-chat
        // "what's your Model?" cannot invent a hop. Empty stays omitted
        // (Desk hides the pill). Dest Source title stays Route.
        if let model = modelLine(revision.model) {
            lines.append(model)
        }
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
            // Studio already says Memory. Compile that name so first-chat
            // "what's in Memory?" cannot invent a hop. Forgotten and
            // untrusted stay out.
            lines.append("Memory:")
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
            // Studio already says Routines. Compile that name so first-chat
            // "what are your Routines?" cannot invent a hop. Studio already
            // says Active. Keep Active on each live line so first-chat
            // "which are Active?" cannot invent a hop. Off stays out.
            lines.append("Routines (not while the app is closed):")
            lines.append(contentsOf: liveRoutines.map(Self.routineLine))
        }
        // Studio already says Test run. Compile that name so first-chat
        // "test this routine" cannot invent a hop or a schedule fire.
        // Do the Instruction now. Does not set Active. Dest Source title
        // stays Routine. Schema does not grow a test tool.
        lines.append(testRunHonesty)
        lines.append("User request:")
        lines.append(userText)
        return lines.joined(separator: "\n\n")
    }

    static func workingSpaceText(_ workspace: BotWorkspaceHonesty? = nil) -> String {
        let place = workspace?.placeLabel ?? ""
        return place.isEmpty ? workspaceHostAssignedHonesty : "\(place). \(workspaceHostAssignedHonesty)"
    }

    /// Studio already says Approval mode. Compile supervised honesty plus
    /// Approvals Allow once / Deny stay off plus host-assigned so
    /// first-chat cannot invent a persist or a grant. Leftover
    /// full_access / auto_accept_edits still compile as supervised.
    static func approvalModeText() -> String {
        "\(BotPermission.honestyLabel) \(approvalsHonesty) \(approvalModeHostAssignedHonesty)"
    }

    /// Studio already says Desktop. Compile display title + isolation so
    /// first-chat "which Desktop?" cannot invent a hop or a VM. Leftover
    /// Dedicated local VM / Managed remote Mac compile as Logical
    /// execution space. Not a self-config write — schema omits it.
    static func desktopText(for revision: BotRevision) -> String {
        let kind = revision.desktopKind.advertisedOrLogical
        return "\(kind.displayTitle). \(kind.honestyLabel)"
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

    /// Studio already says Default route. Compile provider + model so
    /// first-chat "what's your Default route?" cannot invent a hop.
    /// Studio already says Fallback order is not shipped. Compile that
    /// so first-chat cannot invent a second route. Custom soul must not
    /// hide advertised routing. Dest Source title stays Route.
    static func routeLine(provider: AgentProvider, model: String) -> String {
        let title = BotRoute.advertisedTitle(for: provider)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = model.isEmpty ? title : "\(title) · \(model)"
        return "\(route). \(BotRoute.fallbackOrderHonesty)"
    }

    /// Studio already says Model. Compile that name so first-chat
    /// "what's your Model?" cannot invent a hop. Empty stays omitted
    /// (Desk hides the pill). Dest Source title stays Route.
    static func modelLine(_ model: String) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "Model: \(trimmed)"
    }

    /// Desk already shows `@handle`. Compile it so first-chat "what's your handle?"
    /// cannot invent one. Custom soul must not hide advertised identity.
    /// Studio Handle is create-only. Compile that honesty so first-chat
    /// "change your handle" cannot invent a set_settings write. Empty
    /// handle omits the suffix.
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
        if !handle.isEmpty { parts.append(handleCreateOnlyHonesty) }
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
    /// When stays omitted. Studio already says Active. Live lines keep
    /// that name so first-chat "which are Active?" cannot invent a hop.
    /// Off dest rows omit Active.
    static func routineLine(_ routine: BotRoutine) -> String {
        let name = routine.definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = routine.definition.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = routine.definition.scheduleNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = mutateKey(routine.definition.id.value)
        let active = routine.activation.isEnabled ? " Active." : ""
        if note.isEmpty {
            return "- \(name): Instruction: \(prompt).\(active) [\(key)]"
        }
        return "- \(name): Instruction: \(prompt). When: \(note).\(active) [\(key)]"
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
                text: workingSpaceText(workspace),
                included: true,
                reason: "Advertised workspace. Host-assigned. Leftover folder writes stay off."
            )
        )

        layers.append(
            BotContextLayer(
                id: "desktop-kind",
                kind: .desktop,
                title: "Desktop",
                text: desktopText(for: revision),
                included: true,
                reason: "Advertised execution space. Leftover VM kinds compile as logical space."
            )
        )

        layers.append(
            BotContextLayer(
                id: "permission",
                kind: .permission,
                title: "Permission",
                text: approvalModeText(),
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
