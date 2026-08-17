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
        case description
        case soul
        case memory
        case skill
        case routine
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

/// Compiles Source Brain layers into the Effective payload sent to a provider.
public enum BotBrainCompiler {
    public static func assemble(
        bot: BotDefinition,
        revision: BotRevision,
        userText: String,
        memory: [BotMemoryItem] = [],
        skills: [BotSkillBinding] = [],
        routines: [BotRoutine] = [],
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
            routines: routines
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
            permissionMode: revision.permissionMode,
            desktopKind: revision.desktopKind.advertisedOrLogical,
            compiledPayload: payload,
            payloadDigest: BotDigest.sha256Hex(payload),
            layers: sourceLayers(
                bot: bot,
                revision: revision,
                userText: userText,
                memory: memory,
                skills: skills,
                routines: routines
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
        routines: [BotRoutine] = []
    ) -> String {
        var lines: [String] = []
        let job = [bot.name, revision.title].filter { !$0.isEmpty }.joined(separator: " — ")
        if !job.isEmpty {
            lines.append("You are \(job).")
        }
        lines.append("Working space: \(workingSpaceText(for: revision))")
        let description = revision.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            lines.append(description)
        }
        let soul = BotStandingInstructions.resolved(
            name: bot.name,
            title: revision.title,
            description: revision.description,
            soul: revision.soul
        )
        if !soul.isEmpty {
            lines.append("Standing instructions:")
            lines.append(soul)
        }
        let liveMemory = memory.filter { $0.forgottenAt == nil && $0.trusted }
        if !liveMemory.isEmpty {
            lines.append("Trusted memory:")
            lines.append(contentsOf: liveMemory.map { "- \($0.content)" })
        }
        let enabled = skills.filter(\.enabled).map(\.skillID).sorted()
        if !enabled.isEmpty {
            lines.append("Enabled skills: \(enabled.joined(separator: ", "))")
        }
        let liveRoutines = routines.filter(\.activation.isEnabled)
            .sorted { $0.definition.name.localizedCaseInsensitiveCompare($1.definition.name) == .orderedAscending }
        if !liveRoutines.isEmpty {
            lines.append("Enabled routines (not while the app is closed):")
            lines.append(contentsOf: liveRoutines.map(Self.routineLine))
        }
        lines.append("User request:")
        lines.append(userText)
        return lines.joined(separator: "\n\n")
    }

    static func workingSpaceText(for revision: BotRevision) -> String {
        revision.desktopKind.advertisedOrLogical.honestyLabel
    }

    static func routineLine(_ routine: BotRoutine) -> String {
        let name = routine.definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = routine.definition.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = routine.definition.scheduleNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if note.isEmpty {
            return "- \(name): \(prompt)"
        }
        return "- \(name) (\(note)): \(prompt)"
    }

    static func sourceLayers(
        bot: BotDefinition,
        revision: BotRevision,
        userText: String,
        memory: [BotMemoryItem],
        skills: [BotSkillBinding],
        routines: [BotRoutine]
    ) -> [BotContextLayer] {
        var layers: [BotContextLayer] = []
        let job = [bot.name, revision.title].filter { !$0.isEmpty }.joined(separator: " — ")
        if job.isEmpty {
            layers.append(
                BotContextLayer(
                    id: "identity",
                    kind: .identity,
                    title: "Identity",
                    text: "",
                    included: false,
                    reason: "Name and role are empty."
                )
            )
        } else {
            layers.append(
                BotContextLayer(
                    id: "identity",
                    kind: .identity,
                    title: "Identity",
                    text: "You are \(job).",
                    included: true,
                    reason: "Name and role compile into the identity line."
                )
            )
        }

        layers.append(
            BotContextLayer(
                id: "desktop",
                kind: .desktop,
                title: "Working space",
                text: workingSpaceText(for: revision),
                included: true,
                reason: "Advertised execution space. Leftover VM kinds compile as logical space."
            )
        )

        let description = revision.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.isEmpty {
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
        } else {
            layers.append(
                BotContextLayer(
                    id: "description",
                    kind: .description,
                    title: "Description",
                    text: description,
                    included: true,
                    reason: "Published description is RemoteCode-controlled text."
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
                    text: item.content,
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
                        ? "Enabled. Runs only while the app is open."
                        : "Disabled. Not injected."
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
