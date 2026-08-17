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
        forgotten.content = "Old secret"
        forgotten.forgottenAt = Date()
        var untrusted = live
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
        XCTAssertTrue(receipt.compiledPayload.contains("Prefers dark mode"))
        XCTAssertFalse(receipt.compiledPayload.contains("Old secret"))
        XCTAssertFalse(receipt.compiledPayload.contains("Rumor"))
        XCTAssertTrue(receipt.compiledPayload.contains("weekly-account-health"))
        XCTAssertFalse(receipt.compiledPayload.contains("off-skill"))
        XCTAssertTrue(receipt.compiledPayload.contains("Working space: \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertEqual(receipt.layers.first(where: { $0.text == "Old secret" })?.included, false)
        XCTAssertEqual(receipt.layers.first(where: { $0.text == "Rumor" })?.included, false)
        XCTAssertEqual(receipt.layers.first(where: { $0.text == "Prefers dark mode" })?.included, true)
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
        XCTAssertTrue(receipt.compiledPayload.contains("Working space: \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertTrue(receipt.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(receipt.compiledPayload.contains(BotStandingInstructions.generatedSignature))
        XCTAssertEqual(receipt.layers.first(where: { $0.kind == .desktop })?.included, true)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.kind == .desktop })?.reason,
            "Advertised execution space. Leftover VM kinds compile as logical space."
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
        XCTAssertTrue(receipt.compiledPayload.contains("Standing instructions:"))
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
        XCTAssertTrue(receipt.compiledPayload.contains("You are Piper — Reviews PRs."))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.rememberFactTool))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.forgetFactTool))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.setSkillTool))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.saveRoutineTool))
        XCTAssertTrue(receipt.compiledPayload.contains(BotStandingInstructions.setRoutineEnabledTool))
        XCTAssertFalse(receipt.compiledPayload.contains("You are Piper. Your job is:"))
        XCTAssertTrue(BotStandingInstructions.looksGenerated(starter))
        XCTAssertFalse(BotStandingInstructions.looksGenerated("Speak plainly."))
    }

    func test_enabledRoutineCompilesAndDisabledStaysOut_becauseSchedulesAreAuthority() {
        // WHY: Hermes/OpenClaw agents know their cron jobs. Studio Routines
        // were owner-authored but Desk compile never mentioned them, so
        // "what do you run in the morning?" invented work. Disabled rows
        // and app-closed honesty must stay — P1a has no autonomy.
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
                    definition: off,
                    activation: BotRoutineActivation(routineID: off.id, botID: bot.id, isEnabled: false)
                ),
            ]
        )
        XCTAssertTrue(receipt.compiledPayload.contains("Enabled routines (not while the app is closed):"))
        XCTAssertTrue(receipt.compiledPayload.contains("Morning scan (Weekdays 9:00): Scan overnight failures"))
        XCTAssertFalse(receipt.compiledPayload.contains("Nightly archive"))
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("Morning scan") })?.included, true)
        XCTAssertEqual(receipt.layers.first(where: { $0.text.contains("Nightly archive") })?.included, false)
        XCTAssertEqual(
            receipt.layers.first(where: { $0.text.contains("Nightly archive") })?.reason,
            "Disabled. Not injected."
        )
    }
}
