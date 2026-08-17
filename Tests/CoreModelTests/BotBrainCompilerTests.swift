import XCTest
@testable import CoreModel

final class BotBrainCompilerTests: XCTestCase {
    func test_effectivePayloadMatchesComposeAndExcludesForgottenMemory() {
        // WHY: Brain Inspector Effective must be the exact adapter payload.
        // A second compiler path would show Source/Effective that the model never saw.
        let bot = BotDefinition(
            handle: "piper",
            name: "Piper",
            title: "Scout",
            description: "Looks around"
        )
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let live = BotMemoryItem(
            botID: bot.id,
            currentRevisionID: UUID(),
            content: "Prefers dark mode",
            provenance: "user",
            trusted: true,
            source: "chat"
        )
        var forgotten = live
        forgotten.id = BotMemoryItemID()
        forgotten.content = "Old secret"
        forgotten.forgottenAt = Date()
        var untrusted = live
        untrusted.id = BotMemoryItemID()
        untrusted.content = "Rumor"
        untrusted.trusted = false
        let enabled = BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        let disabled = BotSkillBinding(botID: bot.id, skillID: "off-skill", enabled: false)

        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Summarize overnight",
            memory: [live, forgotten, untrusted],
            skills: [enabled, disabled]
        )
        let composed = BotBrainCompiler.composeRunPrompt(
            bot: bot,
            revision: revision,
            userText: "Summarize overnight",
            memory: [live, forgotten, untrusted],
            skills: [enabled, disabled]
        )

        XCTAssertEqual(receipt.compiledPayload, composed)
        XCTAssertEqual(receipt.payloadDigest, BotDigest.sha256Hex(composed))
        XCTAssertEqual(receipt.compilerVersion, ContextAssemblyReceipt.compilerVersion)
        XCTAssertTrue(receipt.compiledPayload.contains("Memory:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Trusted memory:"))
        XCTAssertTrue(receipt.compiledPayload.contains("Fact: Prefers dark mode"))
        XCTAssertTrue(receipt.compiledPayload.contains("Role: Scout"))
        XCTAssertFalse(receipt.compiledPayload.contains("You are Piper (@piper) — Scout"))
        XCTAssertTrue(receipt.compiledPayload.contains("Description: Looks around"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.mutateKey(live.id.value)))
        XCTAssertFalse(receipt.compiledPayload.contains("Old secret"))
        XCTAssertFalse(receipt.compiledPayload.contains("Rumor"))
        XCTAssertFalse(receipt.compiledPayload.contains(BotBrainCompiler.mutateKey(forgotten.id.value)))
        XCTAssertFalse(receipt.compiledPayload.contains(BotBrainCompiler.mutateKey(untrusted.id.value)))
        XCTAssertTrue(receipt.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(receipt.compiledPayload.contains("Enabled skills"))
        XCTAssertFalse(receipt.compiledPayload.contains("off-skill"))
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Permission: \(BotPermission.honestyLabel)"))
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("Old secret") })?.included, false)
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("Rumor") })?.included, false)
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("Prefers dark mode") })?.included, true)
        XCTAssertEqual(receipt.layers.first(where: { $0.text == "off-skill" })?.included, false)
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .user })?.text, "Summarize overnight")
        XCTAssertEqual(receipt.desktopKind, .logicalExecutionSpace)
    }

    func test_leftoverDedicatedLocalVMReceiptResolvesToLogicalSpace() {
        // WHY: A stored leftover kind must not appear as the live desktop on
        // Brain receipts after Dedicated local VM was removed from Studio.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let leftover = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .dedicatedLocalVM,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: leftover, userText: "Hi")
        XCTAssertEqual(receipt.desktopKind, .logicalExecutionSpace)
        XCTAssertEqual(receipt.desktopKind.honestyLabel, BotDesktopKind.logicalExecutionSpaceHonestyLabel)
        XCTAssertTrue(receipt.compiledPayload.contains(BotDesktopKind.logicalExecutionSpaceHonestyLabel))
        XCTAssertFalse(receipt.compiledPayload.contains("Guest is not running"))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .desktop })?.text, BotDesktopKind.logicalExecutionSpaceHonestyLabel)
    }

    func test_workingSpaceCompilesForCustomSoul_becauseIsolationHonestyIsNotAnEscapeHatch() {
        // WHY: Studio already shows desktop honesty to the owner. The model
        // never saw it, so "are you isolated?" invented a VM. A written soul
        // must not hide the advertised execution space — Hermes agents know
        // their sandbox even when SOUL.md is custom.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Are you isolated?")
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .desktop })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .desktop })?.reason,
            "Advertised workspace and execution space. Leftover VM kinds compile as logical space."
        )
    }

    func test_workspaceHonestyCompilesForCustomSoul_becauseStudioWorkspaceIsNotAnEscapeHatch() {
        // WHY: Studio already shows Workspace. The model never saw name or
        // cwd, so first-chat "which repo?" invented a folder. A written soul
        // must not hide the advertised workspace — Hermes agents know their
        // cwd even when SOUL.md is custom.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let workspace = BotWorkspaceHonesty(name: "macos-app", cwd: "/tmp/macos-app")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Which repo is this?",
            workspace: workspace
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: macos-app (/tmp/macos-app). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Working space:"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .desktop })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .desktop })?.text,
            "macos-app (/tmp/macos-app). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("macos-app"),
            "workspace honesty is a compiler layer, not starter soul"
        )
    }

    func test_emptyWorkspaceDoesNotInventAFolder_becauseCompileMustNotAdvertiseNone() {
        // WHY: Studio shows "None" when no workspace is bound. Compile must
        // not invent a folder name or emit "None" as if it were a repo.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let blank = BotWorkspaceHonesty(name: "  ", cwd: "  ")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Which repo is this?",
            workspace: blank
        )
        XCTAssertEqual(blank.placeLabel, "")
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Workspace: None"))
        XCTAssertFalse(receipt.compiledPayload.contains("Working space:"))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .desktop })?.text,
            BotDesktopKind.logicalExecutionSpaceHonestyLabel
        )
    }

    func test_emptySoulFallsBackToStandingDefault_becauseANewAgentMustNotCompileSoulless() {
        // WHY: Hermes seeds SOUL.md and falls back when it is empty. OpenClaw
        // seeds SOUL.md on first run. Live Desk Brain showed "No standing
        // instructions" / Excluded for New Agent — the model only saw
        // "You are New Agent." A jobless teammate still needs standing rules.
        let bot = BotDefinition(handle: "new-agent", name: "New Agent", title: "", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "New Agent",
            title: "",
            description: "",
            soul: "",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "qual seu nome?")
        let composed = BotBrainCompiler.composeRunPrompt(bot: bot, revision: revision, userText: "qual seu nome?")
        XCTAssertEqual(receipt.compiledPayload, composed)
        XCTAssertTrue(receipt.compiledPayload.contains("You are New Agent (@new-agent)."))
        XCTAssertTrue(receipt.compiledPayload.contains("Instructions:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Standing instructions:"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        let layer = receipt.layers.first { $0.kind == .soul }
        XCTAssertEqual(layer?.included, true)
        XCTAssertEqual(layer?.text, BotStandingInstructions.fallback(name: "New Agent", title: "", description: ""))
        XCTAssertTrue(layer?.reason.contains("Built-in teammate default") == true)
    }

    func test_publishedSoulReplacesFallback_becauseCustomInstructionsStayTheEscapeHatch() {
        // WHY: Auto-config must not hide power. A written soul is identity;
        // the starter must not leak into the payload beside it.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Hi")
        XCTAssertTrue(receipt.compiledPayload.contains("Be brief."))
        XCTAssertTrue(receipt.compiledPayload.contains("Instructions:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Standing instructions:"))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first { $0.kind == .soul }?.reason, "Standing instructions are published with the revision.")
    }

    func test_generatedSoulPicksUpRole_becauseJobIsAutoConfigNotASecondForm() {
        // WHY: Role still shapes identity. The starter must not repeat
        // "You are … Your job is" — that was a second identity form.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Reviews PRs", description: "")
        let starter = BotStandingInstructions.fallback(name: "Piper", title: "", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Reviews PRs",
            description: "",
            soul: starter,
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Go")
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper (@piper). Role: Reviews PRs."))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.admittedToolsText))
        XCTAssertFalse(starter.contains(BotStandingInstructions.rememberFactTool), "tools layer owns remember")
        XCTAssertFalse(receipt.compiledPayload.contains("You are Piper. Your job is:"))
        XCTAssertFalse(receipt.compiledPayload.contains("You are Piper (@piper) — Reviews PRs."))
        XCTAssertTrue(BotStandingInstructions.looksGenerated(starter))
        XCTAssertFalse(BotStandingInstructions.looksGenerated("Speak plainly."))
    }

    func test_leftoverFullAccessReceiptResolvesToSupervised_becauseDeskNeverLaunchesIt() {
        // WHY: Studio/Desk advertise Supervised. Self-config can persist
        // leftover full_access. Brain header used to show that leftover as
        // live power, and the model never saw the advertised route, so
        // "just write the file" invented unsupervised access.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let leftover = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .fullAccess,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: leftover, userText: "Just write the file")
        XCTAssertEqual(receipt.permissionMode, .supervised)
        XCTAssertTrue(receipt.compiledPayload.contains("Permission: \(BotPermission.honestyLabel)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains("full_access"))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .permission })?.included, true)
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .permission })?.text, BotPermission.honestyLabel)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .permission })?.reason,
            "Advertised supervised route. Leftover full-access kinds compile as supervised."
        )
    }

    func test_handleHonestyCompilesForCustomSoul_becauseDeskAddressIsNotAnEscapeHatch() {
        // WHY: Desk already shows @handle. Brain compile never sent it, so
        // first-chat "what's your handle?" invented one. Handle is advertised
        // identity — a written soul must not hide it.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's your handle?")
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper (@piper). Role: Scout."))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .identity })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.text,
            "You are Piper (@piper). Role: Scout. Avatar: Person."
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.reason,
            "Name, handle, role, and avatar compile into the identity line."
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("@piper"),
            "handle honesty is a compiler layer, not starter soul"
        )
    }

    func test_roleHonestyCompilesForCustomSoul_becauseStudioRoleIsNotAnEscapeHatch() {
        // WHY: Studio already says Role. Compile put the job unlabeled after
        // an em-dash, so first-chat "what's your Role?" invented a hop. A
        // written soul must not hide the advertised job.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's your Role?")
        XCTAssertTrue(receipt.compiledPayload.contains("Role: Scout"), "Role: Scout")
        XCTAssertFalse(receipt.compiledPayload.contains("You are Piper (@piper) — Scout"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .identity })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.text,
            "You are Piper (@piper). Role: Scout. Avatar: Person."
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Role:"),
            "role honesty is a compiler layer, not starter soul"
        )
    }

    func test_emptyRoleDoesNotInventAJob_becauseCompileMustNotAdvertiseNone() {
        // WHY: Studio Role can be empty. Compile must omit the label, not
        // invent "No job yet" from dest chrome.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "  ", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "  ",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's your Role?")
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper (@piper)."))
        XCTAssertFalse(receipt.compiledPayload.contains("Role:"))
        XCTAssertFalse(receipt.compiledPayload.contains("No job yet"))
    }

    func test_avatarHonestyCompilesForCustomSoul_becauseStudioAvatarIsNotAnEscapeHatch() {
        // WHY: Studio already picks Avatar and tools already persist it.
        // Brain compile never sent the chip, so first-chat "what's my avatar?"
        // invented a symbol. A written soul must not hide the advertised chip.
        var bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        bot.avatarSymbol = "star.fill"
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's my avatar?")
        XCTAssertTrue(receipt.compiledPayload.contains("Avatar: Star"), "Avatar: Star")
        XCTAssertFalse(receipt.compiledPayload.contains("star.fill"), "leftover SF")
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .identity })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.text,
            "You are Piper (@piper). Role: Scout. Avatar: Star."
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.reason,
            "Name, handle, role, and avatar compile into the identity line."
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Avatar:"),
            "avatar honesty is a compiler layer, not starter soul"
        )
    }

    func test_leftoverAvatarDoesNotCompileSFSymbol_becauseStudioNeverAdvertisedIt() {
        // WHY: Leftover store symbols are not Studio chips. Compile must not
        // teach the model an SF path the owner never picked.
        var bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        bot.avatarSymbol = "bird"
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's my avatar?")
        XCTAssertFalse(receipt.compiledPayload.contains("Avatar:"), "leftover avatar does not compile")
        XCTAssertFalse(receipt.compiledPayload.contains("bird"))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.text,
            "You are Piper (@piper). Role: Scout."
        )
    }

    func test_browserHonestyCompilesForCustomSoul_becauseLastWebsiteIsNotAnEscapeHatch() {
        // WHY: Tools already persist last website. Brain compile never sent
        // it, so first-chat "what's open?" invented a hop or a URL. A written
        // soul must not hide the advertised last website.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let browser = BotBrowserTarget(url: "https://github.com/remotecode", title: "GitHub")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What's open?",
            browser: browser
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Browser: GitHub (https://github.com/remotecode)"), "Browser: GitHub")
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .browser })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .browser })?.text,
            "Browser: GitHub (https://github.com/remotecode)"
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .browser })?.reason,
            "Advertised last website. Tools already persist it."
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Browser:"),
            "browser honesty is a compiler layer"
        )
    }

    func test_emptyBrowserDoesNotInventAURL_becauseCompileMustNotAdvertiseNone() {
        // WHY: No last website is not "None". Compile must omit the layer
        // so first-chat cannot treat an empty browser as a page.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let blank = BotBrowserTarget(url: "  ", title: "  ")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What's open?",
            browser: blank
        )
        XCTAssertFalse(receipt.compiledPayload.contains("Browser:"), "empty browser")
        XCTAssertNil(receipt.layers.first(where: { $0.kind == .browser }))
        XCTAssertFalse(receipt.compiledPayload.contains("None"))
    }

    func test_browserHonestyOmitsCookies_becauseWebsiteDataIsNotACompileLayer() {
        // WHY: get already returns website-data keys. Compile must not dump
        // cookies into the adapter payload.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let page = BotBrowserPageState(
            url: "https://github.com/remotecode",
            title: "GitHub",
            cookies: ["session": "secret-token"]
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What's open?",
            browser: BotBrowserTarget(url: page.url, title: page.title)
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Browser: GitHub (https://github.com/remotecode)"))
        XCTAssertFalse(receipt.compiledPayload.contains("secret-token"), "cookies stay out")
        XCTAssertFalse(receipt.compiledPayload.contains("session"))
    }

    func test_routeHonestyCompilesForCustomSoul_becauseDeskRouteIsNotAnEscapeHatch() {
        // WHY: Desk already shows provider + model. Brain compile never sent
        // them, so first-chat "what model are you?" invented a route. Route
        // is advertised identity — a written soul must not hide it.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What model are you?")
        XCTAssertTrue(receipt.compiledPayload.contains("Route: Claude · opus"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .route })?.included, true)
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .route })?.text, "Claude · opus")
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .route })?.reason,
            "Advertised provider and model. Desk already shows this route."
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Route:"),
            "route layer owns the provider/model"
        )
    }

    func test_admittedToolsCompileForCustomSoul_becauseDeskToolsAreNotAnEscapeHatch() {
        // WHY: Desk already admits remember/browse tools. Starter soul used
        // to own those names, so a custom soul hid them and first-chat
        // "remember this" invented a tool. Tools are advertised capability —
        // a written soul must not hide them.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Remember this")
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.admittedToolsText))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.getBrowserTool))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .tools })?.included, true)
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .tools })?.text, BotStandingInstructions.admittedToolsText)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .tools })?.reason,
            "Desk-admitted tools. Custom soul must not hide them."
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains(BotStandingInstructions.rememberFactTool),
            "tools layer owns the catalog names"
        )
    }

    func test_admittedToolsCompileNamesDescription_becauseCustomSoulMustNotHideThem() {
        // WHY: Studio already says Role and Instructions. Tools named
        // job/standing instructions, so first-chat "change your Role"
        // invented a hop. A custom soul must still see advertised writes.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "Looks around")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Change your description")
        XCTAssertTrue(receipt.compiledPayload.contains("name, Role, Instructions, description, route, notifications, or avatar"))
        XCTAssertFalse(receipt.compiledPayload.contains("job, standing instructions"), "leftover job is not advertised")
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.changeJobTool))
        XCTAssertTrue(receipt.compiledPayload.contains("Description: Looks around"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .tools })?.text,
            BotStandingInstructions.admittedToolsText
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .description })?.text,
            BotBrainCompiler.descriptionLine("Looks around")
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Description:"),
            "description honesty is a compiler layer, not starter soul"
        )
    }

    func test_emptyDescriptionDoesNotCompile_becauseBlankAboutMustNotInventCopy() {
        // WHY: Studio hides an empty Description. Compile must not invent
        // about text the owner never advertised.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "  ")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "  ",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's your description?")
        XCTAssertFalse(receipt.compiledPayload.contains("Description:"))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .description })?.included, false)
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
    }

    func test_routeOmitsEmptyModel_becauseDeskHidesAnUnsetModelPill() {
        // WHY: Desk modelLabel is hidden when the revision model is blank.
        // Compile must not invent a default the owner never advertised.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .grok,
            providerInstanceID: "grok",
            model: "  ",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Hi")
        XCTAssertTrue(receipt.compiledPayload.contains("Route: Grok"))
        XCTAssertFalse(receipt.compiledPayload.contains("Route: Grok ·"))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .route })?.text, "Grok")
    }

    func test_permissionHonestyCompilesForCustomSoul_becauseRouteHonestyIsNotAnEscapeHatch() {
        // WHY: Working-space honesty is a RemoteCode layer. Permission is
        // the same class of advertised fact — a written soul must not hide
        // that Desk launches supervised.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .autoAcceptEdits,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Can you just do it?")
        XCTAssertEqual(receipt.permissionMode, .supervised)
        XCTAssertTrue(receipt.compiledPayload.contains("Permission: \(BotPermission.honestyLabel)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains("auto_accept_edits"))
        XCTAssertFalse(BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains(BotPermission.honestyLabel))
    }

    func test_activeRoutineCompilesAndOffStaysOut_becauseSchedulesAreAuthority() {
        // WHY: Studio already says Active, Instruction, and When. Compile
        // listed unlabeled prompt + parenthetical note, so first-chat
        // "what's the Instruction?" invented a hop. Hermes agents see the
        // advertised field names. Off rows and app-closed honesty stay.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let morning = BotRoutineDefinition(
            botID: bot.id,
            name: "Morning scan",
            prompt: "Scan overnight failures",
            scheduleNote: "Weekdays 9:00"
        )
        let sweep = BotRoutineDefinition(
            botID: bot.id,
            name: "Inbox sweep",
            prompt: "Clear the inbox"
        )
        let off = BotRoutineDefinition(
            botID: bot.id,
            name: "Nightly archive",
            prompt: "Archive the inbox"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What do you run?",
            routines: [
                BotRoutine(
                    definition: morning,
                    activation: BotRoutineActivation(routineID: morning.id, botID: bot.id, isEnabled: true)
                ),
                BotRoutine(
                    definition: sweep,
                    activation: BotRoutineActivation(routineID: sweep.id, botID: bot.id, isEnabled: true)
                ),
                BotRoutine(
                    definition: off,
                    activation: BotRoutineActivation(routineID: off.id, botID: bot.id, isEnabled: false)
                ),
            ]
        )
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper (@piper). Role: Scout."))
        XCTAssertTrue(receipt.compiledPayload.contains("Active routines (not while the app is closed):"))
        XCTAssertFalse(receipt.compiledPayload.contains("Enabled routines"))
        XCTAssertTrue(receipt.compiledPayload.contains("Morning scan: Instruction: Scan overnight failures. When: Weekdays 9:00"))
        XCTAssertFalse(receipt.compiledPayload.contains("Morning scan (Weekdays 9:00):"))
        XCTAssertTrue(receipt.compiledPayload.contains("Inbox sweep: Instruction: Clear the inbox"))
        XCTAssertFalse(receipt.compiledPayload.contains("Inbox sweep: Instruction: Clear the inbox. When:"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.mutateKey(morning.id.value)))
        XCTAssertFalse(receipt.compiledPayload.contains("Nightly archive"))
        XCTAssertFalse(receipt.compiledPayload.contains(BotBrainCompiler.mutateKey(off.id.value)))
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("Morning scan") })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.text.contains("Morning scan") })?.reason,
            "Active. Runs only while the app is open."
        )
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("Nightly archive") })?.included, false)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.text.contains("Nightly archive") })?.reason,
            "Off. Not injected."
        )
    }

    func test_skillsCompileAndOffStaysOut_becauseStudioAlreadySaysSkills() {
        // WHY: Studio already says Skills. Compile listed Enabled skills, so
        // first-chat "which Skills?" invented a hop. Hermes agents see the
        // advertised catalog name. Off stays out.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let enabled = BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        let disabled = BotSkillBinding(botID: bot.id, skillID: "off-skill", enabled: false)
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Which Skills?",
            skills: [enabled, disabled]
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(receipt.compiledPayload.contains("Enabled skills"))
        XCTAssertFalse(receipt.compiledPayload.contains("off-skill"))
        XCTAssertEqual(receipt.layers.first(where: { $0.text == "weekly-account-health" })?.included, true)
        XCTAssertEqual(receipt.layers.first(where: { $0.text == "off-skill" })?.included, false)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.text == "off-skill" })?.reason,
            "Disabled. Not injected."
        )
    }

    func test_memoryMutateKeyCompilesForCustomSoul_becauseForgetMustNotInventAnId() {
        // WHY: Desk already admits bot_forget_memory and requires memory_id.
        // Compile listed the fact without the key, so first-chat "forget this"
        // invented a UUID or a hidden get-settings hop. Hermes memory is in
        // context with enough to act. A written soul must not hide the key.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let live = BotMemoryItem(
            botID: bot.id,
            currentRevisionID: UUID(),
            content: "Prefers dark mode",
            provenance: "user",
            trusted: true,
            source: "chat"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Forget the dark-mode fact",
            memory: [live]
        )
        let key = BotBrainCompiler.mutateKey(live.id.value)
        XCTAssertTrue(receipt.compiledPayload.contains("Memory:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Trusted memory:"))
        XCTAssertTrue(receipt.compiledPayload.contains("Fact: Prefers dark mode"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.memoryLine(live)))
        XCTAssertTrue(receipt.compiledPayload.contains(key))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .memory })?.text, BotBrainCompiler.memoryLine(live))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .memory })?.included, true)
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains(key),
            "mutate keys are a compiler layer, not starter soul"
        )
    }

    func test_forgottenMemoryDoesNotCompileMutateKey_becauseTombstonesAreNotAuthority() {
        // WHY: Forget must remove the key from the adapter payload. A custom
        // soul still sees live keys; a tombstone must not remain callable.
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        var forgotten = BotMemoryItem(
            botID: bot.id,
            currentRevisionID: UUID(),
            content: "Old secret",
            provenance: "user",
            trusted: true,
            source: "chat"
        )
        forgotten.forgottenAt = Date()
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What do you remember?",
            memory: [forgotten]
        )
        XCTAssertFalse(receipt.compiledPayload.contains("Memory:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Trusted memory:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Old secret"))
        XCTAssertFalse(receipt.compiledPayload.contains(BotBrainCompiler.mutateKey(forgotten.id.value)))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .memory })?.included, false)
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .memory })?.text, BotBrainCompiler.memoryLine(forgotten))
    }

    func test_notificationsHonestyCompilesForCustomSoul_becauseStudioToggleIsNotAnEscapeHatch() {
        // WHY: Studio already shows Notifications On/Off. The model never
        // saw it, so first-chat "will you notify me?" invented alerts. A
        // written soul must not hide advertised notification power.
        var bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        bot.notificationsEnabled = true
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Will you notify me?")
        XCTAssertTrue(receipt.compiledPayload.contains("Notifications: \(BotBrainCompiler.notificationsLine(enabled: true))"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .notifications })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .notifications })?.text,
            BotBrainCompiler.notificationsLine(enabled: true)
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Notifications:"),
            "notifications honesty is a compiler layer, not starter soul"
        )
    }

    func test_notificationsOffDoesNotCompileLiveAlerts_becauseOffMustStayOff() {
        // WHY: Off is advertised. Compiling On copy when the toggle is Off
        // would invent alerts the owner already turned off.
        var bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        bot.notificationsEnabled = false
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "",
            soul: "Own the inbox.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Ping me when you are blocked")
        XCTAssertTrue(receipt.compiledPayload.contains("Notifications: \(BotBrainCompiler.notificationsLine(enabled: false))"))
        XCTAssertFalse(receipt.compiledPayload.contains(BotBrainCompiler.notificationsLine(enabled: true)))
        XCTAssertFalse(receipt.compiledPayload.contains("Notifications: On"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .notifications })?.text,
            BotBrainCompiler.notificationsLine(enabled: false)
        )
    }
}
