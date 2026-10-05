import XCTest
import CoreModel
@testable import Persistence
@testable import AgentRuntime
@testable import Surfaces

final class AgentComposerChromeTests: XCTestCase {
    func test_permissionDisplayNameIsAutoEdit_becauseDeskAndAgentAppMustShareOneLabel() {
        // WHY: Desk header used to say "Auto-accept edits" while the Agent App
        // chip said "Auto-edit". One displayName is the contract.
        XCTAssertEqual(AgentPermissionMode.supervised.displayName, "Supervised")
        XCTAssertEqual(AgentPermissionMode.autoAcceptEdits.displayName, "Auto-edit")
        XCTAssertEqual(AgentPermissionMode.fullAccess.displayName, "Full access")
        XCTAssertEqual(AgentPermissionMode.supervised.pickerHelpText, "Ask before tool actions")
        XCTAssertEqual(AgentPermissionMode.autoAcceptEdits.pickerHelpText, "Apply edits without asking")
        XCTAssertEqual(AgentPermissionMode.fullAccess.pickerHelpText, "Run tools without asking")
    }

    func test_modelPillAccessibilityNamesAutoAndManualParts() {
        let auto = AgentModelPillPresentation(title: "Auto", loading: true)
        XCTAssertEqual(auto.accessibilityLabel, "Auto model routing, loading")
        XCTAssertTrue(auto.isAuto)

        let manual = AgentModelPillPresentation(
            title: "gpt-5.5",
            effort: "Medium",
            serviceTier: "Fast",
            contextWindow: "272K"
        )
        XCTAssertEqual(manual.accessibilityLabel, "Model gpt-5.5, effort Medium, tier Fast")
        XCTAssertFalse(manual.isAuto)
    }

    func test_runAsPresentationLocksWhileRunningOrIdentityLocked() {
        XCTAssertTrue(
            AgentRunAsUserPresentation.isInteractive(userCount: 2, identityLocked: false, runLocked: false)
        )
        XCTAssertFalse(
            AgentRunAsUserPresentation.isInteractive(userCount: 1, identityLocked: false, runLocked: false)
        )
        XCTAssertFalse(
            AgentRunAsUserPresentation.isInteractive(userCount: 3, identityLocked: true, runLocked: false)
        )
        XCTAssertFalse(
            AgentRunAsUserPresentation.isInteractive(userCount: 3, identityLocked: false, runLocked: true)
        )
    }

    func test_actorChipTitleIconAndAccessibilityNameBotAndWhereItRuns() {
        // WHY: the chip is the only place the user sees which bot runs the thread and where.
        XCTAssertEqual(AgentRunAsUserPresentation.actorTitle(botName: "Piper", target: .vm), "Piper · VM")
        XCTAssertEqual(AgentRunAsUserPresentation.actorTitle(botName: "Piper", target: .mac), "Piper · Mac")
        XCTAssertEqual(AgentRunAsUserPresentation.actorIcon(identityLocked: false), AgentRunAsUserPresentation.botActorIcon)
        XCTAssertEqual(AgentRunAsUserPresentation.actorIcon(identityLocked: true), "lock.fill")
        XCTAssertEqual(
            AgentRunAsUserPresentation.actorAccessibilityLabel(botName: "Piper", target: .vm, identityLocked: false),
            "Run as bot Piper on VM"
        )
        XCTAssertEqual(
            AgentRunAsUserPresentation.actorAccessibilityLabel(botName: "Piper", target: .mac, identityLocked: true),
            "Locked to bot Piper"
        )
        XCTAssertEqual(AgentRunAsUserPresentation.noBotLabel, "No Bot")
    }

    func test_identityLockedWhenProviderLockedOrActorLockedAt() {
        // WHY: a bot choice locks at first send even if no message is painted yet.
        XCTAssertFalse(AgentRunAsUserPresentation.identityLocked(providerLocked: false, actorLockedAt: nil))
        XCTAssertTrue(AgentRunAsUserPresentation.identityLocked(providerLocked: true, actorLockedAt: nil))
        XCTAssertTrue(AgentRunAsUserPresentation.identityLocked(providerLocked: false, actorLockedAt: Date()))
    }

    func test_actorChipOpensWhenBotsExistEvenWithOneUserAndLockedBotOnlyOffersHandoff() {
        // WHY: with a single macOS user the old chip was static; bots must still be pickable,
        // and a locked bot thread must stay openable for "Continuar sem bot".
        let bot = RunActor.bot(BotID())
        XCTAssertTrue(AgentRunAsUserPresentation.isInteractive(
            userCount: 1, botsAvailable: true, actor: .none, identityLocked: false, runLocked: false))
        XCTAssertFalse(AgentRunAsUserPresentation.isInteractive(
            userCount: 1, botsAvailable: false, actor: .none, identityLocked: false, runLocked: false))
        XCTAssertTrue(AgentRunAsUserPresentation.isInteractive(
            userCount: 3, botsAvailable: true, actor: bot, identityLocked: true, runLocked: false))
        XCTAssertTrue(AgentRunAsUserPresentation.isInteractive(
            userCount: 3, botsAvailable: true, actor: .none, identityLocked: true, runLocked: false),
            "locked thread without a bot still offers hand-off to a bot")
        XCTAssertFalse(AgentRunAsUserPresentation.isInteractive(
            userCount: 3, botsAvailable: false, actor: .none, identityLocked: true, runLocked: false))
        XCTAssertFalse(AgentRunAsUserPresentation.isInteractive(
            userCount: 3, botsAvailable: true, actor: bot, identityLocked: false, runLocked: true))
    }

    @MainActor
    func test_typingInComposerNeverReadsBotList_becauseBotsLoadOnlyWhenChipOpens() throws {
        // WHY: the bot list is a store read; per-keystroke body passes must not trigger it.
        let (vm, rootURL) = try makeActorVM()
        defer { vm.dispose(); try? FileManager.default.removeItem(at: rootURL) }
        var providerCalls = 0
        vm.mentionableBotsProvider = { providerCalls += 1; return [] }
        for i in 0..<100 {
            vm.prompt = "typing \(i)"
            _ = vm.runActorLocked
            _ = vm.selectedRunActor
            _ = vm.composerSuggestions
        }
        XCTAssertEqual(providerCalls, 0)
    }

    @MainActor
    func test_setRunActorRefusedOnceThreadActorIsLocked_becauseBotCannotChangeMidThread() async throws {
        let (vm, rootURL) = try makeActorVM()
        defer { vm.dispose(); try? FileManager.default.removeItem(at: rootURL) }
        let botA = BotID()
        let botB = BotID()
        let thread = AgentThread(
            workspaceId: vm.workspaceID, title: "locked", provider: .codex, model: "gpt-5.5",
            actor: .bot(botA), actorLockedAt: Date(), executionTarget: .vm
        )
        try vm.threadRepo.upsert(thread)
        vm.reloadThreads()
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(vm.selectedRunActor, .bot(botA), "chip follows the thread's stored actor")
        XCTAssertTrue(vm.runActorLocked)
        vm.setRunActor(.bot(botB))
        XCTAssertEqual(vm.selectedRunActor, .bot(botA))
        vm.setRunActor(.none)
        XCTAssertEqual(vm.selectedRunActor, .bot(botA))
        vm.botExecutionTargetProvider = { _ in .mac }
        XCTAssertEqual(vm.executionTarget(for: botA), .vm, "locked thread reports its stored target, not the bot default")
    }

    @MainActor
    func test_setRunActorAcceptedOnUnlockedThreadAndUsesProviderTarget() async throws {
        let (vm, rootURL) = try makeActorVM()
        defer { vm.dispose(); try? FileManager.default.removeItem(at: rootURL) }
        let bot = BotID()
        vm.botExecutionTargetProvider = { _ in .vm }
        vm.setRunActor(.bot(bot))
        XCTAssertEqual(vm.selectedRunActor, .bot(bot))
        XCTAssertEqual(vm.executionTarget(for: bot), .vm)
        vm.setRunActor(.none)
        XCTAssertEqual(vm.selectedRunActor, .none)
    }

    @MainActor
    private func makeActorVM() throws -> (AgentAppViewModel, URL) {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-run-actor-chip-" + UUID().uuidString)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: rootURL.path).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: rootURL.path,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db)
        )
        return (vm, rootURL)
    }

    func test_agentAndBotsShareComposerChromeTypes() throws {
        // WHY: Desk used private deskChipLabel forks for the same controls
        // Agent App paints. Both call sites must mount the shared views.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chrome = try String(
            contentsOf: repo.appendingPathComponent("Sources/Surfaces/AgentComposerChrome.swift"),
            encoding: .utf8
        )
        let agent = try String(
            contentsOf: repo.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let bots = try String(
            contentsOf: repo.appendingPathComponent("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(chrome.contains("struct AgentSourceCapsule"))
        XCTAssertTrue(chrome.contains("struct AgentPermissionCapsule"))
        XCTAssertTrue(chrome.contains("struct AgentRunAsUserCapsule"))
        XCTAssertTrue(chrome.contains("struct AgentModelPillLabel"))
        XCTAssertTrue(chrome.contains("struct AgentCompactMenuRow"))
        XCTAssertTrue(chrome.contains("struct AgentQueuedHeader"))

        XCTAssertTrue(agent.contains("AgentSourceCapsule("))
        XCTAssertTrue(agent.contains("AgentPermissionCapsule("))
        XCTAssertTrue(agent.contains("AgentRunAsUserCapsule("))
        XCTAssertTrue(agent.contains("AgentModelPillLabel("))
        XCTAssertTrue(agent.contains("AgentQueuedHeader("))
        XCTAssertFalse(agent.contains("private func sourceCapsuleLabelView"))
        XCTAssertFalse(agent.contains("private var permissionLabel"))

        XCTAssertTrue(
            bots.contains("AgentAppView("),
            "Desk must mount the Agent App composer instead of painting its own capsules"
        )
        XCTAssertFalse(
            bots.contains("func deskChipLabel"),
            "Desk must not keep a private capsule fork after the shared chrome exists"
        )
        XCTAssertFalse(
            bots.contains("Auto-accept edits"),
            "Desk must use AgentPermissionMode.displayName, not a second permission string"
        )
    }
}
