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
    }
}
