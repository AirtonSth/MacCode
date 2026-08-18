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
        let live = BotMemoryFileText(path: "MEMORY.md", body: "Prefers dark mode")
        let empty = BotMemoryFileText(path: "memory/2026-08-17.md", body: "   ")
        let enabled = BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        let disabled = BotSkillBinding(botID: bot.id, skillID: "off-skill", enabled: false)

        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Summarize overnight",
            memoryFiles: [live, empty],
            skills: [enabled, disabled]
        )
        let composed = BotBrainCompiler.composeRunPrompt(
            bot: bot,
            revision: revision,
            userText: "Summarize overnight",
            memoryFiles: [live, empty],
            skills: [enabled, disabled]
        )

        XCTAssertEqual(receipt.compiledPayload, composed)
        XCTAssertEqual(receipt.payloadDigest, BotDigest.sha256Hex(composed))
        XCTAssertEqual(receipt.compilerVersion, ContextAssemblyReceipt.compilerVersion)
        XCTAssertTrue(receipt.compiledPayload.contains("Memory:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Trusted memory:"))
        XCTAssertTrue(receipt.compiledPayload.contains("### MEMORY.md"))
        XCTAssertTrue(receipt.compiledPayload.contains("Prefers dark mode"))
        XCTAssertTrue(receipt.compiledPayload.contains("Role: Scout"))
        XCTAssertFalse(receipt.compiledPayload.contains("You are Piper (@piper) — Scout"))
        XCTAssertTrue(receipt.compiledPayload.contains("Description: Looks around"))
        XCTAssertFalse(receipt.compiledPayload.contains("Fact: Prefers dark mode"))
        XCTAssertFalse(receipt.compiledPayload.contains("memory/2026-08-17.md"))
        XCTAssertFalse(receipt.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(receipt.compiledPayload.contains("Enabled skills"))
        XCTAssertFalse(receipt.compiledPayload.contains("off-skill"))
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: \(BotBrainCompiler.workspaceHostAssignedHonesty)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Approval mode: \(BotBrainCompiler.approvalModeText())"))
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("memory/2026-08-17.md") })?.included, false)
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
        XCTAssertTrue(receipt.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Guest is not running"))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.title == "Working space" })?.text,
            BotBrainCompiler.workspaceHostAssignedHonesty
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.title == "Desktop" })?.text,
            "\(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"
        )
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
        XCTAssertTrue(receipt.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.title == "Desktop" })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.title == "Desktop" })?.reason,
            "Advertised execution space. Leftover VM kinds compile as logical space."
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
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: macos-app (/tmp/macos-app). \(BotBrainCompiler.workspaceHostAssignedHonesty)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Working space:"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.title == "Working space" })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.title == "Working space" })?.text,
            "macos-app (/tmp/macos-app). \(BotBrainCompiler.workspaceHostAssignedHonesty)"
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.title == "Desktop" })?.text,
            "\(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"
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
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: \(BotBrainCompiler.workspaceHostAssignedHonesty)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Workspace: None"))
        XCTAssertFalse(receipt.compiledPayload.contains("Working space:"))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.title == "Working space" })?.text,
            BotBrainCompiler.workspaceHostAssignedHonesty
        )
    }

    func test_workspaceHonestyNamesHostAssigned_becauseSetSettingsCannotPersistAFolder() {
        // WHY: Studio already shows Workspace. Compile listed it next to
        // Role/Route, so first-chat "use this Workspace" invented a
        // set_settings write. Hermes workspace is host-pinned. Empty stays
        // isolation-only plus this honesty. Dest Source title left.
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
            userText: "Use /tmp/other as your Workspace",
            workspace: workspace
        )
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.workspaceHostAssignedHonesty))
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: macos-app (/tmp/macos-app)."))
        XCTAssertFalse(receipt.compiledPayload.contains("Working space:"))
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Workspace"),
            "tools must not advertise a workspace write"
        )
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Desktop"),
            "tools must not advertise a Desktop write"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains(BotBrainCompiler.workspaceHostAssignedHonesty),
            "workspace honesty is a compiler layer, not starter soul"
        )
    }

    func test_desktopHonestyCompilesSeparateFromWorkspace_becauseStudioDesktopIsNotAHop() {
        // WHY: Studio already says Desktop. Compile folded isolation into
        // Workspace, so first-chat "which Desktop?" invented a hop. Hermes
        // agents know their execution space even when SOUL.md is custom.
        // Leftover VM kinds still compile as Logical execution space.
        // Dest Source title left on Working space.
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
            permissionMode: .supervised,
            desktopKind: .dedicatedLocalVM,
            digest: "x"
        )
        let workspace = BotWorkspaceHonesty(name: "macos-app", cwd: "/tmp/macos-app")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Which Desktop?",
            workspace: workspace
        )
        let leftoverReceipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: leftover,
            userText: "Which Desktop?"
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Workspace: macos-app (/tmp/macos-app). \(BotBrainCompiler.workspaceHostAssignedHonesty)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Workspace: macos-app (/tmp/macos-app). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertFalse(receipt.compiledPayload.contains("Working space:"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            leftoverReceipt.layers.first(where: { $0.title == "Desktop" })?.text,
            "\(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"
        )
        XCTAssertFalse(leftoverReceipt.compiledPayload.contains("Dedicated local VM"))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Desktop:"),
            "Desktop honesty is a compiler layer, not starter soul"
        )
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Desktop"),
            "tools must not advertise a Desktop write"
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
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Reviews PRs."))
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
        XCTAssertTrue(receipt.compiledPayload.contains("Approval mode: \(BotBrainCompiler.approvalModeText())"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.approvalModeHostAssignedHonesty))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.approvalsHonesty))
        XCTAssertFalse(receipt.compiledPayload.contains("Permission:"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains("full_access"))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .permission })?.included, true)
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .permission })?.title, "Permission")
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .permission })?.text, BotBrainCompiler.approvalModeText())
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .permission })?.reason,
            "Advertised supervised route. Leftover full-access kinds compile as supervised."
        )
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Approval mode"),
            "tools must not advertise an Approval mode write"
        )
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Approvals"),
            "tools must not advertise an Approvals write"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains(BotBrainCompiler.approvalModeHostAssignedHonesty),
            "approval-mode honesty is a compiler layer, not starter soul"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains(BotBrainCompiler.approvalsHonesty),
            "approvals honesty is a compiler layer, not starter soul"
        )
    }

    func test_approvalsHonestyCompilesForCustomSoul_becauseAllowOnceIsNotAnEscapeHatch() {
        // WHY: Studio Security already says Approvals and Allow once / Deny
        // stay off until P1b. Compile listed Approval mode only, so
        // first-chat "Allow once" invented a grant. Dest Source title stays
        // Permission. Tools do not advertise a write.
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
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Allow once")
        XCTAssertTrue(receipt.compiledPayload.contains("Approval mode: \(BotBrainCompiler.approvalModeText())"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.approvalsHonesty))
        XCTAssertTrue(receipt.compiledPayload.contains("Allow once / Deny stay off until P1b"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains("Permission:"))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .permission })?.title, "Permission")
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .permission })?.text, BotBrainCompiler.approvalModeText())
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Allow once"),
            "tools must not advertise an Allow once write"
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
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Scout."))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .identity })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.text,
            "You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Scout. Avatar: Person."
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .identity })?.reason,
            "Name, handle, role, and avatar compile into the identity line."
        )
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.handleCreateOnlyHonesty))
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("@piper"),
            "handle honesty is a compiler layer, not starter soul"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout")
                .contains(BotBrainCompiler.handleCreateOnlyHonesty),
            "create-only honesty is a compiler layer, not starter soul"
        )
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("handle,")
                || BotStandingInstructions.admittedToolsText.contains("or handle"),
            "handle stays create-only; tools must not persist it"
        )
    }

    func test_emptyHandleOmitsCreateOnlyHonesty_becauseCompileMustNotAdvertiseNone() {
        // WHY: Studio Handle can be blank before first save. Compile must
        // omit create-only honesty, not invent a handle persist story.
        let bot = BotDefinition(handle: "", name: "Piper", title: "Scout", description: "")
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
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Change your handle")
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper. Role: Scout."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotBrainCompiler.handleCreateOnlyHonesty))
        XCTAssertFalse(receipt.compiledPayload.contains("@"))
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
            "You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Scout. Avatar: Person."
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
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty)"))
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
            "You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Scout. Avatar: Star."
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

    func test_avatarHonestyCompilesBlobatar_becauseStudioComposerMustNotLeakTheToken() {
        // WHY: Studio writes blobatar:v1:cloud:…. First-chat "what's my
        // avatar?" must hear Cloud, never the token.
        var bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "")
        bot.avatarSymbol = "blobatar:v1:cloud:happy:none:coral"
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
        XCTAssertTrue(receipt.compiledPayload.contains("Avatar: Cloud"), "Avatar: Cloud")
        XCTAssertFalse(receipt.compiledPayload.contains("blobatar:"), "token stays out")
        XCTAssertFalse(receipt.compiledPayload.contains("star.fill"), "leftover SF")
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
            "You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Scout."
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

    func test_compileOmitsDefaultRoute() {
        // WHY: Studio no longer publishes a provider. Compiling Default
        // route would lock the teammate to Claude/Codex/Grok in every
        // provider turn.
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
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Hi")
        XCTAssertFalse(receipt.compiledPayload.contains("Default route:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Model: opus"))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .route })?.included, false)
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.macosHarnessTool))
    }

    func test_routeHonestyCompilesForCustomSoul_becauseDeskRouteIsNotAnEscapeHatch() {
        // WHY: Studio already says Default route. Compile listed Route, so
        // first-chat "what's your Default route?" invented a hop. Default
        // route is advertised identity — a written soul must not hide it.
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
        XCTAssertFalse(receipt.compiledPayload.contains("Default route:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Model: opus"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .route })?.included, false)
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Default route:"),
            "route layer owns the provider/model"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Model:"),
            "route layer owns Model"
        )
    }

    func test_modelHonestyCompilesForCustomSoul_becauseStudioModelIsNotAnEscapeHatch() {
        // WHY: Studio already says Model. Compile listed it unlabeled after
        // · on Default route, so first-chat "what's your Model?" invented a
        // hop. Model is advertised identity — a written soul must not hide it.
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
        let receipt = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "What's your Model?")
        XCTAssertFalse(receipt.compiledPayload.contains("Model: opus"))
        XCTAssertFalse(receipt.compiledPayload.contains("Default route:"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .route })?.included, false)
        XCTAssertEqual(BotBrainCompiler.modelLine("opus"), "Model: opus")
        XCTAssertNil(BotBrainCompiler.modelLine("  "))
    }

    func test_fallbackOrderHonestyCompilesForCustomSoul_becauseStudioFallbackIsNotAHop() {
        // WHY: Studio already says Fallback order is not shipped. Compile
        // listed Default route only, so first-chat "if Claude is down use
        // Grok" invented a second route. Hermes ships one published route.
        // Dest Source title stays Route. Schema does not grow a fallback tool.
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
            compatibleRouteSet: ["default", "grok"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "If Claude is down use Grok"
        )
        XCTAssertFalse(receipt.compiledPayload.contains("Default route:"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains("bot_set_fallback"))
        XCTAssertFalse(receipt.compiledPayload.contains("compatibleRouteSet"))
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Fallback order"),
            "tools must not advertise a Fallback write"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Fallback order"),
            "compiler layer owns Fallback order"
        )
        XCTAssertFalse(receipt.layers.contains { $0.title == "Fallback" })
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .route })?.included, false)
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
        // WHY: Studio already says Model. Tools named route only, so
        // first-chat "change your Model" invented a hop. A custom soul
        // must still see that advertised write.
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
        XCTAssertTrue(receipt.compiledPayload.contains("name, Role, Instructions, description, notifications, or avatar"))
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
        XCTAssertFalse(receipt.compiledPayload.contains("Default route:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Model:"), "Desk hides the pill")
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .route })?.included, false)
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
        XCTAssertTrue(receipt.compiledPayload.contains("Approval mode: \(BotBrainCompiler.approvalModeText())"))
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
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper (@piper). \(BotBrainCompiler.handleCreateOnlyHonesty) Role: Scout."))
        XCTAssertTrue(receipt.compiledPayload.contains("Routines (not while the app is closed):"))
        XCTAssertFalse(receipt.compiledPayload.contains("Active routines"))
        XCTAssertFalse(receipt.compiledPayload.contains("Enabled routines"))
        XCTAssertTrue(receipt.compiledPayload.contains("Morning scan: Instruction: Scan overnight failures. When: Weekdays 9:00. Active."))
        XCTAssertFalse(receipt.compiledPayload.contains("Morning scan (Weekdays 9:00):"))
        XCTAssertTrue(receipt.compiledPayload.contains("Inbox sweep: Instruction: Clear the inbox. Active."))
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
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.testRunHonesty))
        XCTAssertTrue(receipt.compiledPayload.contains("Test run: do the Instruction now"))
        XCTAssertTrue(receipt.compiledPayload.contains("Does not set Active"))
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("Morning scan") })?.title, "Routine")
    }

    func test_testRunHonestyCompilesForCustomSoul_becauseStudioTestRunIsNotAHop() {
        // WHY: Studio already says Test run. Compile listed Active routines
        // only, so first-chat "test this routine" invented a hop or a
        // schedule fire. Hermes test runs are live work, not a fake cron.
        // Dest Source title stays Routine. Schema does not grow a test tool.
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
        let morning = BotRoutineDefinition(
            botID: bot.id,
            name: "Morning scan",
            prompt: "Scan overnight failures"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Test this routine",
            routines: [
                BotRoutine(
                    definition: morning,
                    activation: BotRoutineActivation(routineID: morning.id, botID: bot.id, isEnabled: true)
                )
            ]
        )
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.testRunHonesty))
        XCTAssertTrue(receipt.compiledPayload.contains("Test run: do the Instruction now. Does not set Active."))
        XCTAssertTrue(receipt.compiledPayload.contains(BotRoutineCopy.testRunHonestyCaption))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertFalse(receipt.compiledPayload.contains("bot_test_routine"))
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Test run"),
            "tools must not advertise a Test run write"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Test run:"),
            "compiler layer owns Test run"
        )
        XCTAssertFalse(receipt.layers.contains { $0.title == "Test run" })
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .routine })?.title, "Routine")
        let empty = BotBrainCompiler.assemble(bot: bot, revision: revision, userText: "Test this routine")
        XCTAssertTrue(empty.compiledPayload.contains(BotBrainCompiler.testRunHonesty))
        XCTAssertFalse(empty.compiledPayload.contains("Routines (not while the app is closed):"))
        XCTAssertFalse(empty.compiledPayload.contains("Active routines"))
        XCTAssertNil(empty.layers.first(where: { $0.kind == .routine }))
    }

    func test_routinesHonestyCompilesForCustomSoul_becauseStudioRoutinesIsNotAHop() {
        // WHY: Studio already says Routines. Compile listed Active routines,
        // so first-chat "what are your Routines?" invented a hop. Hermes
        // agents see the advertised tab name. Active stays on each live
        // line. Dest Source title stays Routine. Schema does not grow a
        // routines tool.
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
        let morning = BotRoutineDefinition(
            botID: bot.id,
            name: "Morning scan",
            prompt: "Scan overnight failures",
            scheduleNote: "Weekdays 9:00"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What are your Routines?",
            routines: [
                BotRoutine(
                    definition: morning,
                    activation: BotRoutineActivation(routineID: morning.id, botID: bot.id, isEnabled: true)
                )
            ]
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Routines (not while the app is closed):"))
        XCTAssertTrue(receipt.compiledPayload.contains("Morning scan: Instruction: Scan overnight failures. When: Weekdays 9:00. Active."))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains("Active routines"))
        XCTAssertFalse(receipt.compiledPayload.contains("bot_list_routines"))
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText.contains("Routines (not while"),
            "tools must not advertise a Routines list write"
        )
        XCTAssertFalse(
            BotStandingInstructions.fallback(name: "Piper", title: "Scout").contains("Routines (not while"),
            "compiler layer owns Routines"
        )
        XCTAssertFalse(receipt.layers.contains { $0.title == "Routines" })
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .routine })?.title, "Routine")
        XCTAssertEqual(
            receipt.layers.first(where: { $0.text.contains("Morning scan") })?.reason,
            "Active. Runs only while the app is open."
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
        XCTAssertFalse(receipt.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(receipt.compiledPayload.contains("Enabled skills"))
        XCTAssertFalse(receipt.compiledPayload.contains("off-skill"))
        XCTAssertEqual(receipt.layers.first(where: { $0.text == "weekly-account-health" })?.included, false)
        XCTAssertEqual(receipt.layers.first(where: { $0.text == "off-skill" })?.included, false)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.text == "off-skill" })?.reason,
            "Leftover catalog binding. Skills are files."
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
        let live = BotMemoryFileText(path: "MEMORY.md", body: "Prefers dark mode")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Forget the dark-mode fact",
            memoryFiles: [live]
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Memory:"))
        XCTAssertFalse(receipt.compiledPayload.contains("Trusted memory:"))
        XCTAssertTrue(receipt.compiledPayload.contains("### MEMORY.md"))
        XCTAssertTrue(receipt.compiledPayload.contains("Prefers dark mode"))
        XCTAssertTrue(receipt.compiledPayload.contains(BotBrainCompiler.memoryFileLine(live)))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .memory })?.text, BotBrainCompiler.memoryFileLine(live))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .memory })?.included, true)
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.writeMemoryFileTool))
    }

    func test_fileMemoryCompilesFromMarkdownNotStoreFacts() {
        // WHY: Store Fact UUID lines hid the files the bot is supposed to
        // edit. Compile must inject MEMORY.md and today's note as files.
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
        let files = [
            BotMemoryFileText(path: "MEMORY.md", body: "- Prefers dark mode\n"),
            BotMemoryFileText(path: "memory/2026-08-18.md", body: "Shipped the overnight brief.\n"),
        ]
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "What do you remember?",
            memoryFiles: files
        )
        XCTAssertTrue(receipt.compiledPayload.contains("### MEMORY.md"))
        XCTAssertTrue(receipt.compiledPayload.contains("Prefers dark mode"))
        XCTAssertTrue(receipt.compiledPayload.contains("### memory/2026-08-18.md"))
        XCTAssertTrue(receipt.compiledPayload.contains("Shipped the overnight brief."))
        XCTAssertFalse(receipt.compiledPayload.contains("Fact: Prefers dark mode"))
        XCTAssertEqual(receipt.memoryLayers.count, 2)
        XCTAssertTrue(receipt.memoryLayers.allSatisfy(\.included))
    }

    func test_ownedSkillFilesCompileWithoutCatalogAdd() {
        // WHY: Catalog Add hid the markdown the bot is supposed to edit.
        // Compile must inject skills/<slug>/SKILL.md and leave leftover
        // bindings out of the payload.
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
        let leftover = BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        let owned = BotOwnedSkillText(
            slug: "weekly-invoice",
            body: "---\nname: weekly-invoice\n---\nInvoice the week.\n"
        )
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Run the invoice skill",
            skills: [leftover],
            ownedSkills: [owned]
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Skills:"))
        XCTAssertTrue(receipt.compiledPayload.contains("### skills/weekly-invoice/SKILL.md"))
        XCTAssertTrue(receipt.compiledPayload.contains("Invoice the week."))
        XCTAssertFalse(receipt.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(receipt.compiledPayload.contains("Bot skills:"))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.id == "skill-weekly-account-health" })?.included,
            false
        )
        XCTAssertEqual(
            receipt.layers.first(where: { $0.id == "owned-skill-weekly-invoice" })?.included,
            true
        )
        XCTAssertTrue(receipt.compiledPayload.contains("skills/<slug>/SKILL.md"))
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

    func test_compileIncludesBotOwnedSkillFiles() {
        // WHY: This-bot SKILL.md must reach the model. Installed Off binds
        // stay ids-only and out of Skills:.
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
        let enabled = BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        let disabled = BotSkillBinding(botID: bot.id, skillID: "off-skill", enabled: false)
        let owned = BotOwnedSkillText(slug: "weekly-invoice", body: "Invoice the week.")
        let receipt = BotBrainCompiler.assemble(
            bot: bot,
            revision: revision,
            userText: "Do the invoice",
            skills: [enabled, disabled],
            ownedSkills: [owned]
        )
        XCTAssertFalse(receipt.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(receipt.compiledPayload.contains("off-skill"))
        XCTAssertTrue(receipt.compiledPayload.contains("Bot skills:"))
        XCTAssertTrue(receipt.compiledPayload.contains("### weekly-invoice"))
        XCTAssertTrue(receipt.compiledPayload.contains("Invoice the week."))
        XCTAssertEqual(
            receipt.layers.first(where: { $0.id == "owned-skill-weekly-invoice" })?.included,
            true
        )
    }
}
