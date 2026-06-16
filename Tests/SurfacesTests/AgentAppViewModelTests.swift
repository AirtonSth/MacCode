import XCTest
import AppKit
import MachO
import SwiftUI
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// Behavioural coverage for thread rename/delete in the agent app view
/// model. Proves the sidebar contract: rename trims + persists, deleting
/// the selected thread never strands the UI on a dead selection.
@MainActor
final class AgentAppViewModelTests: XCTestCase {

    private func makeVM(provider: AgentProviderRunner? = nil) throws -> (AgentAppViewModel, AgentThreadRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: provider ?? FakeProviderRunner(provider: .codex),
                                                    .claude: FakeProviderRunner(provider: .claude)])
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coord, threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        return (vm, threadRepo)
    }

    private func makeVM(adapter: AgentProviderAdapter) throws -> (AgentAppViewModel, AgentThreadRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(runRepo: runRepo,
                                        messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providerAdapters: [.codex: adapter])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coord, threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        return (vm, threadRepo)
    }

    func test_renameThread_trimsUpdatesAndPersists() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "first")
        let id = vm.selectedThreadId!
        vm.renameThread(id, to: "  Renamed Thread  ")
        XCTAssertEqual(vm.threads.first(where: { $0.id == id })?.title, "Renamed Thread",
                       "rename must trim and update the in-memory list")
        XCTAssertEqual(try repo.get(id: id)?.title, "Renamed Thread",
                       "rename must persist to the repository, not just the view")
    }

    func test_providerLocked_onlyAfterConversationStarts() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        XCTAssertFalse(vm.providerLocked, "an empty thread can still switch source")
        let id = vm.selectedThreadId!
        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "hi"))
        XCTAssertTrue(vm.providerLocked, "once it has a message the source is fixed")
    }

    func test_modelChangePersistsAfterConversationStarts() throws {
        let (vm, repo) = try makeVM()
        vm.availableModels = [
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex),
            AgentModelDescriptor(id: "gpt-5.6", label: "GPT-5.6", provider: .codex)
        ]
        vm.createThread(title: "locked model")
        let id = try XCTUnwrap(vm.selectedThreadId)
        vm.setModel("gpt-5.5")
        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "first turn"))

        vm.setModel("gpt-5.6")

        XCTAssertEqual(vm.model, "gpt-5.6",
                       "provider/source locks after the first message, but model changes must still apply to the next run")
        XCTAssertEqual(try repo.get(id: id)?.model, "gpt-5.6",
                       "model changes after the first message must persist to the thread configuration")
    }

    func test_modelListLoadingAndRetryStateIsVisible() async throws {
        let (vm, _) = try makeVM()
        vm.modelListLoader = { _ in
            try await Task.sleep(nanoseconds: 20_000_000)
            return []
        }

        let load = Task { await vm.loadModels() }
        await waitAsync("model list loading state becomes visible") {
            vm.modelListLoading == true && vm.modelListStatusMessage == "Loading models..."
        }
        await load.value

        XCTAssertEqual(vm.modelListStatusMessage, "No models returned for Codex. Retry from the model menu.",
                       "an empty model list must leave visible retry guidance instead of a silent Default-only picker")
        XCTAssertFalse(vm.modelListLoading)
    }

    func test_modelSnapshotFailureFailsLoud() async throws {
        let (vm, _) = try makeVM()
        struct SnapshotFailure: Error {}
        vm.providerSnapshotLoader = { throw SnapshotFailure() }

        await vm.loadProviderSnapshots()

        XCTAssertEqual(vm.providerSnapshotStatusMessage, "Provider snapshot failed. Retry from the model menu.",
                       "provider/model snapshot fetch failures must be visible so the user can distinguish stale local models from a loaded provider list")
        XCTAssertTrue(vm.providerSnapshots.isEmpty)
    }

    func test_executionModeControlsPersistBeforeConversationAndLockAfterStart() throws {
        let (vm, repo) = try makeVM()
        vm.gitBranch = "main"
        vm.createThread(title: "isolated")
        vm.setExecutionMode(.worktree)
        vm.setBaseBranch("feature-base")

        let id = try XCTUnwrap(vm.selectedThreadId)
        var thread = try XCTUnwrap(try repo.get(id: id))
        XCTAssertEqual(thread.executionMode, .worktree,
                       "macOS Agent App must expose and persist worktree execution before the first provider turn")
        XCTAssertEqual(thread.baseBranch, "feature-base")

        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "started"))
        vm.setExecutionMode(.local)
        thread = try XCTUnwrap(try repo.get(id: id))
        XCTAssertEqual(thread.executionMode, .worktree,
                       "execution mode must lock after conversation start so a long-running agent cannot silently move between local and worktree cwd")
    }

    func test_providerStatusMessageComesFromSnapshot() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex Work",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: false,
                status: .unavailable,
                statusDetail: "Codex binary missing.",
                authenticated: true,
                accountLabel: "work@example.com",
                accountAuthMethod: "oauth",
                models: [],
                slashCommands: ["/goal"]
            )
        ]

        XCTAssertEqual(vm.providerDisplayName(.codex), "Codex Work")
        XCTAssertEqual(vm.providerStatusMessage, "Codex binary missing.",
                       "macOS Agent App must surface provider status from the host/provider snapshot before the user sends")
        XCTAssertEqual(vm.providerAccountStatusMessage, "Codex Work: work@example.com via oauth",
                       "macOS Agent App provider cards must surface account label and auth method before a long run starts")
        XCTAssertEqual(vm.providerRecoveryActionTitle, "Copy install command",
                       "provider cards must expose an immediate recovery action when the selected CLI is unavailable")
    }

    func test_providerRecoveryActionRunsInstanceScopedUpdateAndRefreshesSnapshots() async throws {
        let (vm, _) = try makeVM()
        vm.provider = .claude
        vm.providerInstanceId = "claude-work"
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "claude-work",
                provider: .claude,
                driverKind: .claudeCLI,
                displayName: "Claude Work",
                accentColor: "#D97706",
                continuationGroup: "anthropic-claude",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .warning,
                statusDetail: "Update available: Claude Code 2.2.0",
                authenticated: true,
                models: [AgentModelDescriptor(id: "claude-sonnet-4-5", label: "Claude Sonnet 4.5", provider: .claude)],
                slashCommands: ["/status"],
                advisory: "Update available: Claude Code 2.2.0",
                updateState: "update_available"
            )
        ]
        var updatedProvider: AgentProvider?
        var updatedInstance: String?
        vm.providerRecoveryAction = { provider, instanceId in
            updatedProvider = provider
            updatedInstance = instanceId
            return "updated claude\n"
        }
        vm.providerSnapshotLoader = {
            [AgentProviderSnapshot(
                id: "claude-work",
                provider: .claude,
                driverKind: .claudeCLI,
                displayName: "Claude Work",
                accentColor: "#D97706",
                continuationGroup: "anthropic-claude",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                statusDetail: nil,
                authenticated: true,
                models: [AgentModelDescriptor(id: "claude-sonnet-4-5", label: "Claude Sonnet 4.5", provider: .claude)],
                slashCommands: ["/status"],
                advisory: nil,
                updateState: nil
            )]
        }

        XCTAssertEqual(vm.providerRecoveryActionTitle, "Update Claude Work")

        await vm.performProviderRecoveryAction()

        XCTAssertEqual(updatedProvider, .claude)
        XCTAssertEqual(updatedInstance, "claude-work",
                       "provider recovery actions must stay instance-scoped so work/personal provider cards do not update the wrong account")
        XCTAssertEqual(vm.providerRecoveryStatusMessage, "updated claude")
        XCTAssertEqual(vm.selectedProviderSnapshot?.status, .available,
                       "provider cards must refresh after recovery so stale warnings do not remain before long runs")
    }

    func test_preparePullRequestThreadUsesCurrentAgentConfigAndSelectsWorktreeThread() async throws {
        let (vm, repo) = try makeVM()
        vm.provider = .codex
        vm.providerInstanceId = "codex-work"
        vm.availableModels = [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex, supportsReasoning: true, supportsServiceTier: true)]
        vm.model = "gpt-5.5"
        vm.permissionMode = .fullAccess
        vm.reasoningEffort = .high
        vm.serviceTier = .fast
        vm.pullRequestURL = " https://github.com/acme/widget/pull/7 "
        var captured: (String, AgentProvider, String, AgentPermissionMode, AgentReasoningEffort, AgentServiceTier, String?)?
        vm.pullRequestThreadPreparer = { url, provider, model, permission, reasoning, serviceTier, _, providerInstanceId in
            captured = (url, provider, model, permission, reasoning, serviceTier, providerInstanceId)
            let thread = AgentThread(
                workspaceId: vm.workspaceID,
                title: "PR #7: acme/widget",
                provider: provider,
                providerInstanceId: providerInstanceId,
                model: model,
                permissionMode: permission,
                reasoningEffort: reasoning,
                executionMode: .worktree,
                baseBranch: "rc-pr/github-com/acme-widget-7",
                worktreePath: "/tmp/rc-pr-7",
                serviceTier: serviceTier
            )
            try repo.upsert(thread)
            return thread
        }

        await vm.preparePullRequestThread()

        XCTAssertEqual(captured?.0, "https://github.com/acme/widget/pull/7")
        XCTAssertEqual(captured?.1, .codex)
        XCTAssertEqual(captured?.2, "gpt-5.5")
        XCTAssertEqual(captured?.3, .fullAccess)
        XCTAssertEqual(captured?.4, .high)
        XCTAssertEqual(captured?.5, .fast)
        XCTAssertEqual(captured?.6, "codex-work",
                       "opening a PR as an Agent thread must preserve the selected provider instance so work/personal sessions do not collapse")
        XCTAssertEqual(vm.selectedThreadId.flatMap { try? repo.get(id: $0) }?.worktreePath, "/tmp/rc-pr-7",
                       "the macOS Agent App must select the isolated PR worktree thread after preparation")
        XCTAssertEqual(vm.pullRequestURL, "")
    }

    func test_providerInstanceSelectionPersistsAndReachesProviderRun() async throws {
        let capture = CapturingProviderRunner(provider: .codex)
        let (vm, repo) = try makeVM(provider: capture)
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "codex-personal",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex Personal",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                slashCommands: ["/goal"]
            ),
            AgentProviderSnapshot(
                id: "codex-work",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex Work",
                accentColor: "#125A9C",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "gpt-5.4", label: "GPT-5.4", provider: .codex)],
                slashCommands: ["/goal"]
            )
        ]
        vm.providerLaunchConfig = { _, instanceId in
            ("/usr/bin/env", instanceId == "codex-work" ? ["CODEX_HOME": "/tmp/codex-work"] : [:])
        }

        vm.setProviderInstance("codex-work")
        vm.createThread(title: "instance")
        vm.prompt = "check instance routing"
        await vm.send()

        let thread = try XCTUnwrap(vm.selectedThreadId.flatMap { try? repo.get(id: $0) })
        XCTAssertEqual(thread.providerInstanceId, "codex-work",
                       "the selected provider instance must persist on the thread before the first turn starts")
        XCTAssertEqual(capture.providerInstanceIds.last, "codex-work",
                       "macOS Agent App must route the actual run by selected provider instance, not just provider type")
        XCTAssertEqual(capture.providerBinaries.last, "/usr/bin/env")
        XCTAssertEqual(capture.environments.last?["CODEX_HOME"], "/tmp/codex-work")
    }

    func test_restartedAgentAppSendsFollowupWithPersistedProviderThreadId() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-restart-continuity-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let history = PromptHistoryStore(db: db)
        let capture = CapturingProviderRunner(provider: .codex)
        let firstCoordinator = AgentRunCoordinator(runRepo: runRepo,
                                                   messageRepo: messageRepo,
                                                   threadRepo: threadRepo,
                                                   providers: [.codex: capture])
        let firstVM = AgentAppViewModel(workspaceID: workspaceID,
                                        cwd: tmp,
                                        coordinator: firstCoordinator,
                                        threadRepo: threadRepo,
                                        messageRepo: messageRepo,
                                        promptHistoryStore: history)

        firstVM.createThread(title: "restart continuity")
        let threadId = try XCTUnwrap(firstVM.selectedThreadId)
        firstVM.prompt = "first turn"
        await firstVM.send()
        await waitAsync("first turn persists provider cursor") {
            (try? threadRepo.get(id: threadId)?.providerThreadId)?.isEmpty == false
        }
        let persistedProviderThreadId = try XCTUnwrap(try threadRepo.get(id: threadId)?.providerThreadId)

        let secondCoordinator = AgentRunCoordinator(runRepo: runRepo,
                                                    messageRepo: messageRepo,
                                                    threadRepo: threadRepo,
                                                    providers: [.codex: capture])
        let restartedVM = AgentAppViewModel(workspaceID: workspaceID,
                                            cwd: tmp,
                                            coordinator: secondCoordinator,
                                            threadRepo: threadRepo,
                                            messageRepo: messageRepo,
                                            promptHistoryStore: history)

        XCTAssertEqual(restartedVM.selectedThreadId, threadId,
                       "after app restart, Agent App must reopen the persisted thread before follow-up sends")
        restartedVM.prompt = "second turn after restart"
        await restartedVM.send()
        await waitAsync("follow-up request captured") { capture.prompts.count >= 2 }

        XCTAssertEqual(capture.requestProviderThreadIds.first ?? nil, nil,
                       "the first turn should start a fresh provider session")
        XCTAssertEqual(capture.requestProviderThreadIds.dropFirst().first ?? nil, persistedProviderThreadId,
                       "after app restart, Agent App must send follow-ups with the persisted provider thread id instead of forking a disconnected agent session")
    }

    func test_contextHealthMessageShowsTokenBudgetAndCompaction() throws {
        let (vm, _) = try makeVM()
        vm.timeline.apply(.tokenUsage(AssistantTokenUsage(inputTokens: 400, outputTokens: 100, totalTokens: 500, contextWindow: 1_000, compactsAutomatically: true)))

        XCTAssertEqual(vm.contextHealthMessage, "Context 50% · 500 / 1000 tokens · auto-compacts",
                       "macOS Agent App must expose context usage and automatic compaction capability so long agent runs do not silently approach the context limit")

        vm.timeline.apply(.contextCompaction(summary: "older turns summarized"))
        XCTAssertEqual(vm.contextHealthMessage, "Context 50% · 500 / 1000 tokens · auto-compacts · compacted",
                       "macOS Agent App must surface compaction state so long-run behavior is visible")
    }

    func test_timelineItemPresentationKeepsProgressAndChannelsDistinct() {
        let running = AgentTimelineItemPresentation.make(for: AssistantItem(
            id: "cmd-1",
            turnId: "turn-1",
            type: .commandExecution,
            state: .streaming,
            summary: "swift test",
            startedAtMs: 1
        ))
        XCTAssertEqual(running.icon, "circle.dotted")
        XCTAssertEqual(running.verb, "Running")
        XCTAssertEqual(running.label, "swift test")

        let failed = AgentTimelineItemPresentation.make(for: AssistantItem(
            id: "cmd-2",
            turnId: "turn-1",
            type: .commandExecution,
            state: .failed,
            body: "xcodebuild test",
            startedAtMs: 2
        ))
        XCTAssertEqual(failed.icon, "xmark.octagon")
        XCTAssertEqual(failed.verb, "Failed")

        let changed = AgentTimelineItemPresentation.make(for: AssistantItem(
            id: "file-1",
            turnId: "turn-1",
            type: .fileChange,
            state: .completed,
            summary: "Edited AgentThreadView.swift",
            output: "1 file changed",
            startedAtMs: 3
        ))
        XCTAssertEqual(changed.icon, "doc.badge.gearshape")
        XCTAssertEqual(changed.verb, "Changed")
        XCTAssertEqual(changed.detail, "1 file changed")

        let reasoning = AgentTimelineItemPresentation.make(for: AssistantItem(
            id: "think-1",
            turnId: "turn-1",
            type: .reasoning,
            state: .completed,
            summary: "Need provider parity",
            startedAtMs: 4
        ))
        XCTAssertEqual(reasoning.detail, "Need provider parity",
                       "reasoning summaries must stay visible even when providers send summary-only deltas")

        let issue = AgentTimelineItemPresentation.make(for: AssistantItem(
            id: "err-1",
            turnId: "turn-1",
            type: .error,
            state: .completed,
            body: "Unsupported realtime event",
            startedAtMs: 5
        ))
        XCTAssertEqual(issue.icon, "exclamationmark.triangle")
        XCTAssertEqual(issue.verb, "Issue")
    }

    func test_composerSuggestsProviderSlashCommandsAndSkills() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: [],
                slashCommands: ["/goal", "/review"],
                skills: ["sam-fix-bug", "sam-review-code"]
            )
        ]

        vm.prompt = "/go"
        XCTAssertEqual(vm.composerSuggestions.map(\.insertText), ["/goal "],
                       "provider-owned slash commands must be discoverable instead of requiring memorized syntax")

        vm.prompt = "use $sam-f"
        XCTAssertEqual(vm.composerSuggestions.map(\.insertText), ["$sam-fix-bug "],
                       "Codex skills from the provider snapshot must be selectable from the composer")
    }

    func test_applyComposerSuggestionReplacesOnlyActiveToken() throws {
        let (vm, _) = try makeVM()
        vm.prompt = "before $sam-r"
        vm.applyComposerSuggestion(AgentComposerSuggestion(
            title: "$sam-review-code",
            subtitle: "Codex skill",
            insertText: "$sam-review-code ",
            kind: .skill
        ))

        XCTAssertEqual(vm.prompt, "before $sam-review-code ",
                       "selecting a composer suggestion must preserve surrounding prompt text")
    }

    func test_pendingProviderCallbacksExposeOnlyActionableRows() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "callbacks")
        vm.timeline.apply(.requestOpened(AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run command",
            detail: "swift test",
            createdAtMs: 1
        )))
        vm.timeline.apply(.requestOpened(AssistantPendingRequest(
            id: "approval-2",
            turnId: "turn-1",
            kind: .fileChange,
            title: "Edit file",
            state: .stale,
            createdAtMs: 2
        )))
        vm.timeline.apply(.userInputRequested(AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Pick mode",
            options: ["Plan", "Run"],
            createdAtMs: 3
        )))
        vm.timeline.apply(.requestResolved(requestId: "approval-1", state: .approved))

        XCTAssertEqual(vm.openPendingRequests.map(\.id), [],
                       "macOS Agent App must not render stale provider callbacks as actionable rows after the turn can no longer answer them")
        XCTAssertEqual(vm.openPendingUserInputs.map(\.id), ["question-1"],
                       "macOS Agent App must surface provider questions so the user can unblock Codex/Claude")
    }

    func test_selectThreadRehydratesPersistedStaleCallbacksIntoTimeline() throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-callback-rehydrate-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let callbackRepo = ProviderPendingCallbackRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "callbacks", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try callbackRepo.record(threadId: thread.id, request: AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run command",
            detail: "swift test",
            createdAtMs: 1_000
        ))
        try callbackRepo.record(threadId: thread.id, userInput: AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Continue?",
            options: ["Plan", "Run"],
            createdAtMs: 2_000
        ))
        _ = try callbackRepo.markOpenStale(reason: "Provider callback state does not survive app restart.")
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: FakeProviderRunner(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coord,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   pendingCallbackRepo: callbackRepo)

        vm.selectThread(thread.id)

        XCTAssertEqual(vm.timeline.pendingRequests.first?.state, .stale,
                       "persisted stale approvals must remain in timeline state for diagnostics after restart/reload")
        XCTAssertEqual(vm.timeline.pendingUserInputs.first?.state, .stale,
                       "persisted stale provider questions must remain in timeline state for diagnostics after restart/reload")
        XCTAssertEqual(vm.openPendingRequests, [],
                       "stale approvals must not reappear as actionable Agent App cards after restart/reload")
        XCTAssertEqual(vm.openPendingUserInputs, [],
                       "stale provider questions must not reappear as actionable Agent App cards after restart/reload")
    }

    func test_failedPendingCallbackResponsesBecomeStaleAndNonActionable() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-callback-fail-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FailingCallbackRunner()])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo)
        vm.createThread(title: "callbacks")
        vm.timeline.apply(.requestOpened(AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run command",
            detail: "swift test",
            createdAtMs: 1
        )))
        vm.timeline.apply(.userInputRequested(AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Continue?",
            options: ["Plan", "Run"],
            createdAtMs: 2
        )))

        vm.respondToPendingRequest(vm.openPendingRequests[0], response: .approve)
        vm.answerPendingUserInput(vm.openPendingUserInputs[0], answer: "Run")
        // respondToPendingRequest now drives the (async) coordinator.respondToRequest
        // off the main run loop; let that @MainActor task drain before asserting.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(vm.timeline.pendingRequests.first?.state, .stale,
                       "failed provider approval responses must be retained as stale diagnostics")
        XCTAssertEqual(vm.timeline.pendingUserInputs.first?.state, .stale,
                       "failed provider question responses must be retained as stale diagnostics")
        XCTAssertEqual(vm.openPendingRequests, [],
                       "failed provider approval responses must not leave a dead approve button")
        XCTAssertEqual(vm.openPendingUserInputs, [],
                       "failed provider question responses must not leave a dead answer card")
        XCTAssertTrue(vm.timeline.error?.contains("Provider user-input response failed") == true,
                      "callback loss must leave visible activity explaining why the user needs to restart the turn")
    }

    func test_multiSelectUserInputBuildsOneFinalAnswer() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "multi input")
        let request = AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Pick checks",
            options: ["Unit", "UI", "Docs"],
            allowsMultipleSelection: true,
            createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.toggleUserInputOption("UI", for: request)
        vm.toggleUserInputOption("Unit", for: request)
        let answer = vm.selectedUserInputAnswer(for: request)

        XCTAssertEqual(answer, "UI\nUnit",
                       "multi-select questions must submit one final answer atomically instead of resuming once per selected option")
    }

    // Claude AskUserQuestion screenshot bug: the card showed raw JSON / an empty
    // "Input required" box. A structured request must collect each question's choice
    // and submit ONE answer map keyed by question text (the shape the Claude SDK
    // expects), then clear the card so it does not linger on screen.
    func test_submitAskUserQuestionBuildsAnswersKeyedByQuestionText() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "ask user question")
        let request = AssistantUserInputRequest(
            id: "ask-1",
            turnId: "turn-1",
            prompt: "Framework: Pick the framework?\nTargets: Which targets?",
            questions: [
                AssistantUserInputQuestion(
                    prompt: "Pick the framework?",
                    header: "Framework",
                    options: [
                        AssistantUserInputOption(label: "SwiftUI", detail: "Declarative"),
                        AssistantUserInputOption(label: "AppKit", detail: "Imperative"),
                    ],
                    allowsMultipleSelection: false
                ),
                AssistantUserInputQuestion(
                    prompt: "Which targets?",
                    header: "Targets",
                    options: [
                        AssistantUserInputOption(label: "macOS"),
                        AssistantUserInputOption(label: "iPadOS"),
                    ],
                    allowsMultipleSelection: true
                ),
            ],
            createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        XCTAssertFalse(vm.askUserQuestionIsComplete(request),
                       "submit must stay disabled until every question is answered")
        vm.selectAskUserQuestionOption("SwiftUI", question: request.questions[0], request: request)
        XCTAssertFalse(vm.askUserQuestionIsComplete(request),
                       "one answered question is not enough — all are required")
        vm.selectAskUserQuestionOption("macOS", question: request.questions[1], request: request)
        vm.selectAskUserQuestionOption("iPadOS", question: request.questions[1], request: request)
        XCTAssertTrue(vm.askUserQuestionIsComplete(request))

        vm.submitAskUserQuestion(request)
        await waitAsync("structured answer reaches adapter") {
            adapter.lastUserInputResponse?.requestId == "ask-1"
        }

        let text = try XCTUnwrap(adapter.lastUserInputResponse?.text)
        let answers = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(answers["Pick the framework?"], "SwiftUI",
                       "single-select answers must be keyed by the question text the Claude SDK expects")
        XCTAssertEqual(answers["Which targets?"], "iPadOS, macOS",
                       "multi-select answers must be one deterministically-ordered, comma-joined string")
        await waitAsync("structured question card clears") { vm.openPendingUserInputs.isEmpty }
        XCTAssertEqual(vm.openPendingUserInputs, [],
                       "answering a structured question must clear the card instead of leaving a stuck Input-required box")
    }

    func test_askUserQuestionOtherFreeformOverridesSelection() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "ask other")
        let question = AssistantUserInputQuestion(
            prompt: "Which database?",
            header: "DB",
            options: [AssistantUserInputOption(label: "Postgres"), AssistantUserInputOption(label: "MySQL")],
            allowsMultipleSelection: false
        )
        let request = AssistantUserInputRequest(
            id: "ask-2", turnId: "turn-2", prompt: "Which database?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.userInputDrafts[vm.askUserQuestionKey(request, question)] = "SQLite"
        XCTAssertTrue(vm.askUserQuestionIsComplete(request),
                      "a freeform Other answer must satisfy the question even with no option selected")
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "SQLite",
                       "Other freeform text must be usable as the answer (the SDK auto-provides an Other option)")
    }

    func test_askUserQuestionOptionAndOtherAreMutuallyExclusive() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "ask exclusive")
        let question = AssistantUserInputQuestion(
            prompt: "Which database?",
            header: "DB",
            options: [AssistantUserInputOption(label: "Postgres"), AssistantUserInputOption(label: "MySQL")],
            allowsMultipleSelection: false
        )
        let request = AssistantUserInputRequest(
            id: "ask-3", turnId: "turn-3", prompt: "Which database?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        // Typing Other clears any prior option selection.
        vm.selectAskUserQuestionOption("Postgres", question: question, request: request)
        vm.setAskUserQuestionOther("SQLite", question: question, request: request)
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "SQLite")
        XCTAssertFalse(vm.askUserQuestionOptionIsSelected("Postgres", question: question, request: request),
                       "typing an Other answer must clear a stale option selection")

        // Re-selecting an option clears the Other draft — so toggling it back off
        // cannot resurrect stale Other text and falsely satisfy the question.
        vm.selectAskUserQuestionOption("MySQL", question: question, request: request)
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "MySQL",
                       "selecting an option must supersede and clear the Other draft")
        vm.selectAskUserQuestionOption("MySQL", question: question, request: request) // toggle off (single-select)
        XCTAssertNil(vm.askUserQuestionAnswer(for: question, in: request),
                     "deselecting the last option must leave the question unanswered, not fall back to stale Other text")
        XCTAssertFalse(vm.askUserQuestionIsComplete(request))
    }

    func test_freeTextUserInputDraftCanAnswerProviderQuestion() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "free text input")
        let request = AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Which branch should I inspect?",
            options: [],
            isSecret: true,
            createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.userInputDrafts[request.id] = "release/next"
        vm.answerPendingUserInput(request, answer: vm.userInputDrafts[request.id] ?? "")
        await waitAsync("free-text provider response reaches adapter") {
            adapter.lastUserInputResponse?.requestId == "question-1"
        }

        XCTAssertEqual(adapter.lastUserInputResponse?.requestId, "question-1")
        XCTAssertEqual(adapter.lastUserInputResponse?.text, "release/next",
                       "free-text provider questions must have an editable draft path so the user can unblock the waiting provider request")
        XCTAssertNil(vm.userInputDrafts[request.id],
                     "resolved provider questions must clear their local draft so stale text is not reused for a later request")
        XCTAssertTrue(request.isSecret,
                      "secret free-text questions use the same draft/submit path but must be distinguishable for masked rendering")
    }

    func test_approveForSessionPromotesThreadPermissionToFullAccess() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, repo) = try makeVM(adapter: adapter)
        vm.createThread(title: "approval")
        let threadId = try XCTUnwrap(vm.selectedThreadId)
        let request = AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run command",
            detail: "npm create vite",
            createdAtMs: 1
        )
        vm.timeline.apply(.requestOpened(request))

        vm.respondToPendingRequest(request, response: .approveForSession)
        // respondToPendingRequest now drives the (async) coordinator.respondToRequest
        // off the main run loop; let that @MainActor task drain before asserting.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(adapter.lastRequestResponse?.response, .approveForSession,
                       "Approve Session must still send the provider session-scoped decision so the current run stops asking")
        XCTAssertEqual(vm.permissionMode, .fullAccess,
                       "Approve Session must visibly move the macOS thread from Supervised to Full Access")
        XCTAssertEqual(try repo.get(id: threadId)?.permissionMode, .fullAccess,
                       "Approve Session must persist Full Access so later messages in the same thread auto-approve")
    }

    func test_selectThreadReplaysProviderReadThreadSnapshotWhenAvailable() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex, readEvents: [
            .threadStarted(threadId: "provider-thread-1", providerThreadId: "provider-thread-1"),
            .turnStarted(turnId: "provider-turn-1"),
            .itemStarted(item: AssistantItem(
                id: "provider-message-1",
                turnId: "provider-turn-1",
                type: .assistantMessage,
                state: .streaming,
                summary: "Assistant message",
                startedAtMs: 1
            )),
            .itemDelta(itemId: "provider-message-1", bodyAppend: "Recovered from provider snapshot", outputAppend: nil, summary: nil),
            .turnCompleted(turnId: "provider-turn-1", finalMessage: "Recovered from provider snapshot")
        ])
        let (vm, _) = try makeVM(adapter: adapter)

        vm.createThread(title: "recover")

        // PERF: selectThread now opens instantly from persisted events and replays
        // the provider readThread snapshot one main-actor hop later (the freeze
        // fix). The provider snapshot still REPLACES the stale local rows; we just
        // drain that one hop before asserting the final, identical timeline state.
        await waitAsync("provider snapshot replayed") {
            vm.timeline.turns.map(\.turnId) == ["provider-turn-1"]
        }

        XCTAssertEqual(vm.timeline.providerThreadId, "provider-thread-1")
        XCTAssertEqual(vm.timeline.turns.map(\.turnId), ["provider-turn-1"])
        XCTAssertEqual(vm.timeline.latestAssistantMessage, "Recovered from provider snapshot",
                       "selecting a thread with a live provider session must reload the provider snapshot instead of relying only on stale local stream rows")
    }

    func test_restartedAgentAppRehydratesCodexThreadFromProviderSnapshotAfterLocalEventLoss() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-provider-snapshot-restart-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "recovered provider thread",
            provider: .codex,
            model: "gpt-5.5",
            providerThreadId: "provider-thread-after-restart",
            status: .completed
        )
        try threadRepo.upsert(thread)
        try messageRepo.append(AgentMessage(threadId: thread.id, role: .assistant, content: "stale local final"))

        let adapter = CapturingProviderAdapter(provider: .codex, readEvents: [
            .threadStarted(threadId: "provider-thread-after-restart", providerThreadId: "provider-thread-after-restart"),
            .turnStarted(turnId: "provider-turn-after-restart"),
            .itemStarted(item: AssistantItem(
                id: "provider-message-after-restart",
                turnId: "provider-turn-after-restart",
                type: .assistantMessage,
                state: .streaming,
                summary: "Assistant message",
                startedAtMs: 1
            )),
            .itemDelta(itemId: "provider-message-after-restart", bodyAppend: "Recovered provider state after restart", outputAppend: nil, summary: nil),
            .turnCompleted(turnId: "provider-turn-after-restart", finalMessage: "Recovered provider state after restart")
        ])
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerAdapters: [.codex: adapter])

        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))

        XCTAssertEqual(vm.selectedThreadId, thread.id,
                       "after app restart, Agent App must reopen the persisted Codex thread")
        // PERF: the provider snapshot replay on auto-reopen is now deferred one
        // main-actor hop behind the instant local open (the freeze fix). Drain it
        // before asserting that the provider snapshot still REPLACED the stale
        // local final-message rows -- final timeline state is unchanged.
        await waitAsync("restart provider snapshot replayed") {
            vm.timeline.turns.map(\.turnId) == ["provider-turn-after-restart"]
        }
        XCTAssertEqual(vm.timeline.providerThreadId, "provider-thread-after-restart")
        XCTAssertEqual(vm.timeline.turns.map(\.turnId), ["provider-turn-after-restart"])
        XCTAssertEqual(vm.timeline.latestAssistantMessage, "Recovered provider state after restart",
                       "app restart must prefer provider readThread state over stale local final-message rows when the provider session is recoverable")
    }

    func test_persistThreadConfig_writesProviderModelPermissionAndReasoningToThread() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        vm.provider = .claude
        vm.model = "claude-opus-4-7"
        vm.permissionMode = .fullAccess
        vm.reasoningEffort = .high
        vm.persistThreadConfig()
        let t = try repo.get(id: id)
        XCTAssertEqual(t?.provider, .claude)
        XCTAssertEqual(t?.model, "claude-opus-4-7", "model change must persist for resume")
        XCTAssertEqual(t?.permissionMode, .fullAccess)
        XCTAssertEqual(t?.reasoningEffort, .high)

        vm.permissionMode = .supervised
        vm.reasoningEffort = .low
        vm.selectThread(id)
        XCTAssertEqual(vm.permissionMode, .fullAccess,
                       "reopening an existing thread must restore its saved permission mode")
        XCTAssertEqual(vm.reasoningEffort, .high,
                       "reopening an existing thread must restore its saved reasoning effort")
    }

    func test_settingPermissionPersistsImmediatelyBeforeAnyMessageIsSent() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!

        vm.setPermissionMode(.fullAccess)
        vm.permissionMode = .supervised
        vm.selectThread(id)

        XCTAssertEqual(try repo.get(id: id)?.permissionMode, .fullAccess,
                       "permission changes must persist immediately so app restart does not reset to supervised")
        XCTAssertEqual(vm.permissionMode, .fullAccess,
                       "reopening the thread must restore the saved permission mode before any message is sent")
    }

    func test_createThreadCopiesCurrentConfigFromLastThread() throws {
        let (vm, repo) = try makeVM()
        vm.provider = .codex
        vm.model = "gpt-5.5"
        vm.permissionMode = .fullAccess
        vm.reasoningEffort = .medium
        vm.createThread(title: "next")

        let id = try XCTUnwrap(vm.selectedThreadId)
        let t = try repo.get(id: id)
        XCTAssertEqual(t?.model, "gpt-5.5")
        XCTAssertEqual(t?.permissionMode, .fullAccess,
                       "new threads must inherit the last active permission mode")
        XCTAssertEqual(t?.reasoningEffort, .medium,
                       "new threads must inherit the last active reasoning effort")
    }

    func test_setThreadColor_persistsAndClears() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        vm.setThreadColor(id, "purple")
        XCTAssertEqual(try repo.get(id: id)?.color, "purple")
        vm.setThreadColor(id, "")
        XCTAssertNil(try repo.get(id: id)?.color, "empty selection clears the color")
    }

    func test_renameThread_blankIsNoOp() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "keep")
        let id = vm.selectedThreadId!
        vm.renameThread(id, to: "   ")
        XCTAssertEqual(vm.threads.first(where: { $0.id == id })?.title, "keep",
                       "a blank rename must not wipe an existing title")
    }

    func test_deleteSelectedThread_reselectsRemaining() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "a")
        let a = vm.selectedThreadId!
        vm.createThread(title: "b")
        let b = vm.selectedThreadId!
        XCTAssertNotEqual(a, b)
        vm.selectThread(a)
        vm.deleteThread(a)
        XCTAssertFalse(vm.threads.contains { $0.id == a }, "deleted thread must be gone")
        XCTAssertEqual(vm.selectedThreadId, b,
                       "deleting the selected thread must fall back to a remaining one")
    }

    func test_deleteLastThread_clearsSelectionAndMessages() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "only")
        let id = vm.selectedThreadId!
        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "hi"))
        vm.deleteThread(id)
        XCTAssertNil(vm.selectedThreadId, "deleting the last thread must clear selection")
        XCTAssertTrue(vm.messages.isEmpty, "stale messages must not linger after the thread is gone")
    }

    // MARK: B5 — draft title derivation

    func test_deriveTitle_preservesFullFirstMessageForPersistence() {
        let long = "  Fix the login bug and keep every detail in the persisted thread title.  "
        XCTAssertEqual(AgentAppViewModel.deriveTitle(from: long),
                       "Fix the login bug and keep every detail in the persisted thread title",
                       "the persisted title must keep the full first message; only display should truncate")
        XCTAssertEqual(AgentAppViewModel.deriveTitle(from: "### Heading"),
                       "Heading", "leading markdown punctuation must be stripped")
        XCTAssertEqual(AgentAppViewModel.deriveTitle(from: "   \n  "),
                       "New thread", "an empty prompt must fall back, never be blank")
        XCTAssertEqual(AgentThreadTitle.display(String(repeating: "x", count: 80)),
                       String(repeating: "x", count: AgentThreadTitle.displayLimit) + "...",
                       "thread rows must show a bounded title while the stored title remains complete")
    }

    func test_send_firstMessage_derivesThreadTitleFromDefault() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "New thread")
        let id = vm.selectedThreadId!
        vm.prompt = "Refactor the auth module please"
        await vm.send()
        XCTAssertEqual(try repo.get(id: id)?.title, "Refactor the auth module please",
                       "the first message must rename a still-default thread")
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content == "Refactor the auth module please" })
    }

    func test_send_emptyPendingThreadStartsRunInsteadOfQueueing() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-empty-pending-send-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runner = CapturingProviderRunner(provider: .codex)
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: runner])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coord,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   queuedMessageRepo: queuedRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        vm.createThread(title: "New thread")
        let id = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertEqual(try threadRepo.get(id: id)?.status, .pending,
                       "a newly created empty thread may be persisted as pending, but it is not an active provider run")

        vm.prompt = "Run this now"
        await vm.send()

        XCTAssertEqual(runner.prompts, ["Run this now"],
                       "when no provider run is active, the first prompt must start immediately instead of being stranded in the queue")
        XCTAssertTrue((try? queuedRepo.list(threadId: id))?.isEmpty ?? false,
                      "the queue is only for follow-up prompts while a real run is active")
        XCTAssertTrue(vm.queuedMessages.isEmpty,
                      "the empty-thread send path must not render a queued-message row")
    }

    func test_sendClearsStaleActivePlanAndRestoresBottomFollow() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "stale plan")
        vm.timeline.apply(.activePlanUpdated(AssistantActivePlan(
            explanation: "Done checklist",
            steps: [AssistantPlanStep(id: "step-1", title: "Report", status: .completed)],
            updatedAtMs: 42
        )))
        let initialFocusTick = vm.focusTick

        vm.prompt = "next message"
        await vm.send()

        XCTAssertNil(vm.activePlan,
                     "sending the next user message must remove the previous turn's active plan so the transcript bottom is the new message")
        XCTAssertGreaterThan(vm.focusTick, initialFocusTick,
                             "a user send must re-pin the timeline to the bottom instead of relying on a pre-layout message-count change")
        XCTAssertEqual(runner.prompts, ["next message"],
                       "clearing stale plan state must not block the provider run")
    }

    func test_send_runningThreadQueuesFollowupPrompt() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-running-queue-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runner = SlowStartRunner()
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: runner])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coord,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   queuedMessageRepo: queuedRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        vm.createThread(title: "busy")
        let id = try XCTUnwrap(vm.selectedThreadId)
        vm.prompt = "start slow run"

        Task { await vm.send() }
        await waitAsync("selected thread becomes a real active run") {
            vm.status == .running && vm.currentRunId != nil
        }
        vm.prompt = "follow up after current run"
        await vm.send()

        XCTAssertEqual((try? queuedRepo.list(threadId: id).map(\.text)) ?? [], ["follow up after current run"],
                       "follow-up prompts should queue only while a real provider run is active")
        vm.stop()
        await waitAsync("slow run can still be stopped after queueing") {
            runner.cancelled
        }
    }

    func test_reloadThreadsBackfillsPlaceholderTitleFromFirstUserMessage() throws {
        let (vm, repo) = try makeVM()
        let thread = AgentThread(workspaceId: vm.workspaceID, title: "Thread", provider: .claude, model: "fake-model")
        try repo.upsert(thread)
        let firstMessage = "git add commit and push all repos here with this long exact wording"
        try vm.messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: firstMessage))

        vm.reloadThreads()

        XCTAssertEqual(vm.threads.first(where: { $0.id == thread.id })?.title, firstMessage,
                       "existing placeholder threads must be repaired from the first user message")
        XCTAssertEqual(try repo.get(id: thread.id)?.title, firstMessage,
                       "the repair must persist the full title, not only update the visible rail")
    }

    func test_finishCallback_persistsAssistantReplyForRestart() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        let runId = AgentRunID()
        vm.runCoordinator(vm.coordinator, didFinish: runId, threadId: id, status: .completed,
                          finalMessage: "final answer", providerThreadId: "session-1")
        await waitAsync("assistant reply persisted") {
            ((try? vm.messageRepo.list(threadId: id)) ?? []).contains {
                $0.role == .assistant && $0.content == "final answer"
            }
        }
        vm.runCoordinator(vm.coordinator, didFinish: runId, threadId: id, status: .completed,
                          finalMessage: "final answer", providerThreadId: "session-1")
        await waitAsync("assistant reply remains deduplicated") {
            (((try? vm.messageRepo.list(threadId: id)) ?? []).filter {
                $0.role == .assistant && $0.content == "final answer"
            }.count) == 1
        }
    }

    func test_finishCallbackReloadsSelectedMessagesWhenLiveTimelineMissedFinal() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        try vm.messageRepo.append(AgentMessage(threadId: id, role: .user, content: "count"))
        vm.messages = (try? vm.messageRepo.list(threadId: id)) ?? []

        vm.runCoordinator(vm.coordinator, didFinish: AgentRunID(), threadId: id, status: .completed,
                          finalMessage: "O: 1 2 3", providerThreadId: nil)

        await waitAsync("selected messages include final assistant reply") {
            vm.messages.contains { $0.role == .assistant && $0.content == "O: 1 2 3" }
        }
    }

    func test_finishCallbackClearsActivePlanWhenFinalAssistantMessageArrives() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        vm.timeline.apply(.activePlanUpdated(AssistantActivePlan(
            explanation: "Done checklist",
            steps: [AssistantPlanStep(id: "step-1", title: "Report", status: .completed)],
            updatedAtMs: 42
        )))

        vm.runCoordinator(vm.coordinator, didFinish: AgentRunID(), threadId: id, status: .completed,
                          finalMessage: "O: completed", providerThreadId: nil)

        await waitAsync("final assistant message clears stale active plan") {
            vm.activePlan == nil &&
            vm.messages.contains { $0.role == .assistant && $0.content == "O: completed" }
        }
    }

    func test_turnViewRendersFinalWhenAssistantItemHasNoBody() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage, body: "", startedAtMs: 1)
            ],
            finalAssistantMessage: "O: I counted integers from 1 to 15.",
            finished: true
        )

        XCTAssertTrue(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                      "an empty assistant item must not hide the completed final answer")
    }

    func test_completedTurnCollapsesWorkAndKeepsFinalAssistantItemVisible() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "reason", turnId: "turn-1", type: .reasoning, state: .completed, body: "thinking", startedAtMs: 1_000, finishedAtMs: 2_000),
                AssistantItem(id: "tool", turnId: "turn-1", type: .tool, state: .completed, summary: "Bash", output: "ok", startedAtMs: 2_000, finishedAtMs: 3_000),
                AssistantItem(id: "final", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "Final answer", startedAtMs: 3_000, finishedAtMs: 4_000)
            ],
            finished: true
        )
        let renderable = AgentAppView.renderableItems(in: turn)

        XCTAssertEqual(AgentAppView.completedVisibleAssistantItems(in: turn, renderableItems: renderable).map(\.id), ["final"],
                       "when the provider has no separate final text, the last assistant message is the final answer and must stay outside the Worked disclosure")
        XCTAssertEqual(AgentAppView.completedWorkItems(in: turn, renderableItems: renderable).map(\.id), ["reason", "tool"],
                       "reasoning and tool rows from a completed turn must collapse into the Worked disclosure")
        XCTAssertEqual(AgentAppView.completedWorkLabel(turn), "Worked for 3s",
                       "completed work disclosure must show elapsed work time in the Codex-style label")
    }

    func test_completedTurnWithSeparateFinalCollapsesNonFinalAssistantDrafts() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "draft", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "I will inspect first.", startedAtMs: 1_000, finishedAtMs: 2_000),
                AssistantItem(id: "tool", turnId: "turn-1", type: .commandExecution, state: .completed, summary: "swift test", output: "PASS", startedAtMs: 2_000, finishedAtMs: 4_000)
            ],
            finalAssistantMessage: "Final answer",
            finished: true
        )
        let renderable = AgentAppView.renderableItems(in: turn)

        XCTAssertTrue(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                      "the separate final assistant message must remain the visible completed answer")
        XCTAssertTrue(AgentAppView.completedVisibleAssistantItems(in: turn, renderableItems: renderable).isEmpty,
                      "non-final assistant drafts must not stay as visible transcript rows after the turn completes")
        XCTAssertEqual(AgentAppView.completedWorkItems(in: turn, renderableItems: renderable).map(\.id), ["draft", "tool"],
                       "everything that is not the final answer, including assistant drafts, must move into the Worked disclosure")
    }

    func test_completedTurnWithLastMessageFinalDemotesEarlierPreamblesToWorkLog() {
        // A Codex turn emits several preamble messages before the real answer. Only
        // the LAST assistant message is the answer; the earlier preambles must
        // collapse into the Worked disclosure instead of stacking up as the visible
        // final answer (the bug this fix addresses).
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "Let me read the config first.", startedAtMs: 1_000, finishedAtMs: 2_000),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "Now running the test suite.", startedAtMs: 2_000, finishedAtMs: 3_000),
                AssistantItem(id: "msg-3", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "All checks passed and the build is green.", startedAtMs: 3_000, finishedAtMs: 4_000)
            ],
            finalAssistantMessage: "All checks passed and the build is green.",
            finished: true
        )
        let renderable = AgentAppView.renderableItems(in: turn)

        XCTAssertEqual(AgentAppView.completedVisibleAssistantItems(in: turn, renderableItems: renderable).map(\.id), ["msg-3"],
                       "only the last assistant message must remain the visible answer when a turn emits multiple preamble messages")
        XCTAssertEqual(AgentAppView.completedWorkItems(in: turn, renderableItems: renderable).map(\.id), ["msg-1", "msg-2"],
                       "earlier preamble assistant messages must collapse into the Worked disclosure, not show as the final answer")
    }

    func test_persistedLastMessageRendersOnceWhilePreamblesStayInWorkLog() {
        // After the run finishes, the durable persisted answer is the LAST message
        // only. The timeline shows the preambles in the Worked disclosure and the
        // persisted bubble shows the answer — the answer must render exactly once,
        // never duplicated between the persisted row and the timeline.
        let threadId = AgentThreadID()
        let persisted = AgentMessage(
            threadId: threadId,
            role: .assistant,
            content: "All checks passed and the build is green."
        )
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "Let me read the config first.", startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "Now running the test suite.", startedAtMs: 2),
                AssistantItem(id: "msg-3", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "All checks passed and the build is green.", startedAtMs: 3)
            ],
            finalAssistantMessage: "All checks passed and the build is green.",
            finished: true
        )

        XCTAssertTrue(
            AgentAppView.hiddenPersistedAssistantMessageIDs(messages: [persisted], timelineTurns: [turn]).isEmpty,
            "the persisted last message must stay visible: the timeline now shows only the preambles, never the answer, so there is nothing to dedup against"
        )

        // Once the persisted answer has filtered the matching last item out of the
        // renderable set, NO timeline item is the final answer, so every preamble
        // demotes to the work log and the persisted bubble is the sole answer.
        // (Before the fix this returned all preamble items, double-rendering them.)
        let renderableWithPersisted = AgentAppView.renderableItems(in: turn, persistedAssistantTexts: ["All checks passed and the build is green."])
        XCTAssertTrue(
            AgentAppView.completedFinalAssistantItemIDs(in: turn, renderableItems: renderableWithPersisted, persistedAssistantTexts: ["All checks passed and the build is green."]).isEmpty,
            "no preamble may be promoted to the visible final answer once the real answer is shown by the persisted bubble"
        )
    }

    func test_turnViewRendersFinalWhenAssistantItemBodyIsOnlyPartial() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "S count: 1 2 3 4 5 6 7 8 9 10 now count to 15",
                              startedAtMs: 1)
            ],
            finalAssistantMessage: "S count: 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15",
            finished: true
        )

        XCTAssertTrue(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                      "a partial live assistant body must not hide the completed final answer")
    }

    func test_turnViewDoesNotDuplicateFinalWhenAssistantItemAlreadyRenderedBody() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage, body: "final answer", startedAtMs: 1)
            ],
            finalAssistantMessage: "final answer",
            finished: true
        )

        XCTAssertFalse(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                       "a non-empty assistant item already renders the final answer")
    }

    func test_turnViewDoesNotDuplicateFinalWhenOnlyWhitespaceDiffers() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "D count only.\n\n1 2 3 4 5 6 7 8 9 10",
                              startedAtMs: 1)
            ],
            finalAssistantMessage: "D count only. 1 2 3 4 5 6 7 8 9 10",
            finished: true
        )

        XCTAssertFalse(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                       "formatting-only differences between live and final assistant text must not duplicate the visible answer")
    }

    func test_turnViewDoesNotDuplicateFinalWhenWhitespaceBeforeNumberDiffers() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "D count only.\n\n1 2 3 4 5 6 7 8 9 10",
                              startedAtMs: 1)
            ],
            finalAssistantMessage: "D count only.1 2 3 4 5 6 7 8 9 10",
            finished: true
        )

        XCTAssertFalse(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                       "streamed and final assistant text can differ only by a missing space before the first token; that must stay one visible answer")
    }

    func test_turnViewDoesNotDuplicateFinalWhenMultipleAssistantItemsAlreadyRenderedIt() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "S e2e-fullaccess-start. D run pwd.",
                              startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage,
                              body: "S e2e-fullaccess-after-pwd. D run git status.",
                              startedAtMs: 2),
                AssistantItem(id: "msg-3", turnId: "turn-1", type: .assistantMessage,
                              body: "O e2e-fullaccess-done.",
                              startedAtMs: 3)
            ],
            finalAssistantMessage: "S e2e-fullaccess-start. D run pwd.S e2e-fullaccess-after-pwd. D run git status.O e2e-fullaccess-done.",
            finished: true
        )

        XCTAssertFalse(AgentAppView.shouldRenderFinalAssistantMessage(turn),
                       "when a turn streams several assistant updates, the persisted final can equal their combined text and must not be rendered as a duplicate block")
    }

    func test_turnViewUsesPersistedAssistantMessageAsCompletedAnswer() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "tool-1", turnId: "turn-1", type: .mcpToolCall,
                              summary: "MCP server status", startedAtMs: 1)
            ],
            finalAssistantMessage: "1 2 3 4 5 6 7 8 9 10",
            finished: true
        )

        XCTAssertFalse(AgentAppView.shouldRenderFinalAssistantMessage(
            turn,
            persistedAssistantTexts: ["1 2 3 4 5 6 7 8 9 10"]
        ), "when the final answer is already persisted as a normal assistant row, timeline fallback must not duplicate it")
    }

    func test_turnViewKeepsAssistantPartialVisibleWhenPersistedAnswerContainsIt() {
        let persisted = """
        Dict: S=state C=context D=action R=risk O=outcome N=no-go P=proof
        S wrapper not git repo.
        C memory confirms wrapper workspace; git lives nested.
        D locate nested repos, then stage/commit/push each dirty repo.
        """

        XCTAssertTrue(AgentAppView.shouldRenderAssistantItemBody(
            """
            Dict: S=state C=context D=action R=risk O=outcome N=no-go P=proof
            S wrapper not git repo.
            """,
            persistedAssistantTexts: [persisted]
        ), "live partial updates must stay visible even when an older persisted answer contains the same prefix")
    }

    func test_turnViewHidesSR1ItemWhenHumanizedAnswerIsPersisted() {
        let sr1 = """
        SR1
        S: tests green
        C: user asked in Portuguese
        O: saved counter updated
        """
        let humanized = "Os testes passaram, e o contador de tokens salvos foi atualizado."

        XCTAssertFalse(AgentAppView.shouldRenderAssistantItemBody(
            sr1,
            persistedAssistantTexts: [humanized]
        ), "once the SR1 final answer has been humanized and persisted, the raw compressed item must not render as a second assistant response")
    }

    func test_turnViewHidesSpaceDelimitedSR1ItemWhenHumanizedAnswerIsPersisted() {
        let sr1 = """
        O Snake game criado.
        O file: /Users/samuelfajreldines/snake.html (single-file, zero deps)
        O feat: canvas 20x20 grid, score, wall+self collision, food respawn, game-over restart
        O ctrl: setas ou WASD; ESPACO reinicia
        P open: abrir snake.html no browser -> jogo roda
        """
        let humanized = "O Snake game foi criado em /Users/samuelfajreldines/snake.html e pode ser aberto no navegador."

        XCTAssertFalse(AgentAppView.shouldRenderAssistantItemBody(
            sr1,
            persistedAssistantTexts: [humanized]
        ), "space-delimited /distill output must be treated as SR1 so the raw compact item does not remain visible")
    }

    func test_turnViewHidesDuplicateAssistantItemBodiesWithinTurn() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "Pre-commit hooks passed. Push.",
                              startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage,
                              body: "Pre-commit hooks passed. Push.",
                              startedAtMs: 2),
                AssistantItem(id: "tool-1", turnId: "turn-1", type: .tool,
                              summary: "Ran Bash",
                              startedAtMs: 3)
            ],
            finished: true
        )

        let visibleAssistantBodies = AgentAppView.renderableItems(in: turn)
            .filter { $0.type == .assistantMessage }
            .map(\.body)
        XCTAssertEqual(visibleAssistantBodies, ["Pre-commit hooks passed. Push."],
                       "Claude can replay the same assistant text block with a new item id; the macOS transcript must still render that text once")
        XCTAssertTrue(AgentAppView.renderableItems(in: turn).contains { $0.type == .tool },
                      "deduping assistant text must not hide adjacent work-log/tool rows")
    }

    func test_persistedAssistantMessageHidesWhenLiveItemsAlreadyRenderCombinedText() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "S e2e-fullaccess2-start. D run pwd.",
                              startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage,
                              body: "S e2e-fullaccess2-after-pwd. D run git status in macos-app.",
                              startedAtMs: 2),
                AssistantItem(id: "msg-3", turnId: "turn-1", type: .assistantMessage,
                              body: "O e2e-fullaccess2-done.",
                              startedAtMs: 3)
            ],
            finalAssistantMessage: "S e2e-fullaccess2-start. D run pwd.S e2e-fullaccess2-after-pwd. D run git status in macos-app.O e2e-fullaccess2-done.",
            finished: true
        )

        XCTAssertFalse(AgentAppView.shouldRenderPersistedAssistantMessage(
            "S e2e-fullaccess2-start. D run pwd.S e2e-fullaccess2-after-pwd. D run git status in macos-app.O e2e-fullaccess2-done.",
            timelineTurns: [turn]
        ), "the persisted assistant row must not duplicate the live macOS timeline when all partial updates already render")
    }

    func test_persistedAssistantMessageRendersWhenOnlyLiveItemIsDuplicateFinal() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "1 2 3 4 5 6 7 8 9 10",
                              startedAtMs: 1)
            ],
            finalAssistantMessage: "1 2 3 4 5 6 7 8 9 10",
            finished: true
        )

        XCTAssertTrue(AgentAppView.shouldRenderPersistedAssistantMessage(
            "1 2 3 4 5 6 7 8 9 10",
            timelineTurns: [turn]
        ), "when the only live assistant item duplicates the persisted final, the live item is suppressed so the persisted answer must remain visible")
    }

    func test_persistedAssistantMessageRendersWhenLiveItemsAreOnlyPartial() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "S count: 1 2 3 4 5",
                              startedAtMs: 1)
            ],
            finalAssistantMessage: "S count: 1 2 3 4 5 6 7 8 9 10",
            finished: true
        )

        XCTAssertTrue(AgentAppView.shouldRenderPersistedAssistantMessage(
            "S count: 1 2 3 4 5 6 7 8 9 10",
            timelineTurns: [turn]
        ), "if the live timeline has only a partial response, the persisted assistant answer must still render")
    }

    func test_hiddenPersistedAssistantMessageIDsHidesCombinedLiveAnswerOnce() {
        let threadId = AgentThreadID()
        let persisted = AgentMessage(
            threadId: threadId,
            role: .assistant,
            content: "S start. D inspect. O done."
        )
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "S start. D inspect.",
                              startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage,
                              body: "O done.",
                              startedAtMs: 2)
            ],
            finished: true
        )

        XCTAssertEqual(
            AgentAppView.hiddenPersistedAssistantMessageIDs(messages: [persisted], timelineTurns: [turn]),
            [persisted.id],
            "persisted assistant rows must be hidden when the live timeline already renders the same combined answer"
        )
    }

    func test_hiddenPersistedAssistantMessageIDsKeepsPersistedAnswerWhenLiveDuplicateIsSuppressed() {
        let threadId = AgentThreadID()
        let persisted = AgentMessage(
            threadId: threadId,
            role: .assistant,
            content: "1 2 3 4 5 6 7 8 9 10"
        )
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "1 2 3 4 5 6 7 8 9 10",
                              startedAtMs: 1)
            ],
            finalAssistantMessage: "1 2 3 4 5 6 7 8 9 10",
            finished: true
        )

        XCTAssertTrue(
            AgentAppView.hiddenPersistedAssistantMessageIDs(messages: [persisted], timelineTurns: [turn]).isEmpty,
            "when the live assistant item is itself suppressed as a duplicate persisted final, the persisted answer must remain visible"
        )
    }

    func test_userMessageDisplayTextCapsLongPromptsForLayout() {
        let longPrompt = String(repeating: "a", count: AgentAppView.userMessagePreviewCharacterLimit + 50)
        let display = AgentAppView.userMessageDisplayText(longPrompt)

        XCTAssertLessThanOrEqual(display.count, AgentAppView.userMessagePreviewCharacterLimit + 160,
                                 "long user prompts must render as a bounded preview so transcript layout and accessibility snapshots stay responsive")
        XCTAssertTrue(display.contains("Copy message"),
                      "the preview must tell users the full prompt is still available through the existing copy action")
    }

    func test_visibleLiveTurnItemsKeepsOnlyRecentUpdatesWhileRunning() {
        let itemCount = 5_000
        let items = (0..<itemCount).map { index in
            AssistantItem(id: "item-\(index)", turnId: "turn-1", type: .assistantMessage, body: "\(index)", startedAtMs: Int64(index))
        }
        let visible = AgentAppView.visibleLiveTurnItems(items, running: true)

        XCTAssertEqual(visible.count, AgentAppView.liveTurnRenderableItemLimit,
                       "active turns must render a bounded tail so manual scrolling cannot force LazyVStack to place thousands of live rows")
        XCTAssertEqual(visible.first?.id, "item-\(itemCount - AgentAppView.liveTurnRenderableItemLimit)",
                       "the bounded tail must keep the newest live updates instead of the oldest ones")
        XCTAssertEqual(AgentAppView.visibleLiveTurnItems(items, running: false).count, items.count,
                       "completed or idle turns must retain full renderable history")
    }

    func test_visibleLiveTurnItemsCapsLargeLiveStringsOnlyForRendering() {
        let hugeBody = String(repeating: "b", count: AgentAppView.liveTurnBodyCharacterLimit + 5_000)
        let hugeOutput = String(repeating: "o", count: AgentAppView.liveTurnOutputCharacterLimit + 5_000)
        let hugeSummary = String(repeating: "s", count: AgentAppView.liveTurnSummaryCharacterLimit + 5_000)
        let item = AssistantItem(id: "huge", turnId: "turn-1", type: .commandExecution, summary: hugeSummary,
                                 body: hugeBody, output: hugeOutput, startedAtMs: 1)

        let visible = AgentAppView.visibleLiveTurnItems([item], running: true)

        XCTAssertEqual(visible.count, 1)
        XCTAssertLessThan(visible[0].body.count, hugeBody.count,
                          "live rendering must not carry full command bodies through SwiftUI layout")
        XCTAssertLessThan(visible[0].output?.count ?? 0, hugeOutput.count,
                          "live rendering must not carry full command outputs through SwiftUI layout")
        XCTAssertLessThan(visible[0].summary?.count ?? 0, hugeSummary.count,
                          "live rendering must not carry full summaries through SwiftUI layout")
        XCTAssertEqual(AgentAppView.visibleLiveTurnItems([item], running: false)[0].output, hugeOutput,
                       "stored/completed data remains full; only active live UI copies are capped")
    }

    func test_toolCommandPreviewCapsLongCommandsForCollapsedRows() {
        let command = "gh api graphql " + String(repeating: "x", count: AgentAppView.commandPreviewCharacterLimit + 200)
        let body = #"{"command":"\#(command)"}"#
        let item = AssistantItem(id: "cmd", turnId: "turn-1", type: .commandExecution, body: body, startedAtMs: 1)

        let preview = AgentAppView.toolCommandPreview(for: item)

        XCTAssertNotNil(preview)
        XCTAssertLessThan(preview?.count ?? 0, command.count,
                          "collapsed command rows should not feed huge command strings into SwiftUI text layout")
        XCTAssertTrue(preview?.contains("hidden from preview") == true)
    }

    func test_finishCallback_marksCompletedThreadUnreadUntilOpened() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "done")
        let id = vm.selectedThreadId!
        vm.runCoordinator(vm.coordinator, didFinish: AgentRunID(), threadId: id, status: .completed,
                          finalMessage: "done", providerThreadId: nil)

        await waitAsync("completed thread marked unread") {
            (try? repo.get(id: id)?.hasUnread) == true
        }
        vm.reloadThreads()
        XCTAssertTrue(vm.threads.first { $0.id == id }?.hasUnread ?? false,
                      "completed work must leave a visible unread indicator even for the currently selected thread")

        vm.selectThread(id)
        XCTAssertEqual(try repo.get(id: id)?.hasUnread, false,
                       "clicking/opening the completed thread must clear the indicator")
    }

    func test_runningThreadClearsPriorCompletedUnreadIndicator() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "rerun")
        let id = vm.selectedThreadId!
        vm.runCoordinator(vm.coordinator, didFinish: AgentRunID(), threadId: id, status: .completed,
                          finalMessage: "done", providerThreadId: nil)
        await waitAsync("completed thread marked unread") {
            (try? repo.get(id: id)?.hasUnread) == true
        }

        vm.runCoordinator(vm.coordinator, didChangeStatus: .running, runId: AgentRunID(), threadId: id)

        await waitAsync("running thread clears completed dot") {
            (try? repo.get(id: id)?.hasUnread) == false
        }
        XCTAssertFalse(vm.threads.first { $0.id == id }?.hasUnread ?? true,
                       "starting a new spinner must hide the prior completed dot until this run completes again")
    }

    func test_threadRowSelectionCheckNeverAppearsForClickedThread() {
        XCTAssertFalse(AgentThreadRowPresentation.showsSelectionCheck(
            threadStatus: .running,
            selected: false,
            surfaceStatus: .pending,
            multiSelected: true
        ), "running work must show the spinner without also implying completion")

        XCTAssertFalse(AgentThreadRowPresentation.showsSelectionCheck(
            threadStatus: .pending,
            selected: true,
            surfaceStatus: .running,
            multiSelected: true
        ), "the selected thread must suppress the check while its run is still active")

        XCTAssertFalse(AgentThreadRowPresentation.showsSelectionCheck(
            threadStatus: .completed,
            selected: true,
            surfaceStatus: .completed,
            multiSelected: true
        ), "clicking a thread selects it via highlight only; no trailing check icon")

        XCTAssertTrue(AgentThreadRowPresentation.showsSelectionCheck(
            threadStatus: .completed,
            selected: false,
            surfaceStatus: .completed,
            multiSelected: true
        ), "bulk-selected, non-open rows can still show the selection check")
    }

    func test_completedUnreadThreadShowsOnlyTrailingDot() {
        XCTAssertFalse(AgentThreadRowPresentation.showsLeadingStatus(
            threadStatus: .completed,
            selected: true,
            surfaceStatus: .completed,
            hasUnread: true,
            pinned: false
        ), "completed unread work must use the trailing dot only, without a second idle dot on the left")

        XCTAssertTrue(AgentThreadRowPresentation.showsLeadingStatus(
            threadStatus: .completed,
            selected: true,
            surfaceStatus: .completed,
            hasUnread: true,
            pinned: true
        ), "pinned rows keep their pin because it is not a completion indicator")
    }

    func test_runningStatusTracksRunIdBeforeStartRunReturnsSoStopWorks() async throws {
        let (vm, _) = try makeVM()
        let runner = SlowStartRunner()
        vm.coordinator.replaceProvider(.codex, runner: runner)
        vm.createThread(title: "slow")
        vm.prompt = "start slow run"

        Task { await vm.send() }
        await waitAsync("running status carries run id") {
            vm.status == .running && vm.currentRunId != nil
        }
        vm.stop()

        await waitAsync("pending stop cancels after handle registration") {
            runner.cancelled
        }
    }

    func test_streamEventsFanOutToEveryAgentSurfaceViewingTheThread() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-fanout-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: ImmediateStreamRunner()]
        )
        let workspaceID = WorkspaceID()
        let firstSurface = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                             coordinator: coordinator, threadRepo: threadRepo,
                                             messageRepo: messageRepo)
        let secondSurface = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                              coordinator: coordinator, threadRepo: threadRepo,
                                              messageRepo: messageRepo)
        firstSurface.createThread(title: "shared")
        let threadId = firstSurface.selectedThreadId!
        secondSurface.reloadThreads()
        secondSurface.selectThread(threadId)

        firstSurface.prompt = "stream please"
        await firstSurface.send()

        await waitAsync("sender surface receives live partial stream") {
            firstSurface.timeline.turns.flatMap(\.items).contains {
                $0.type == .assistantMessage && $0.body.contains("partial stream")
            }
        }
        await waitAsync("second surface viewing same thread receives live partial stream") {
            secondSurface.timeline.turns.flatMap(\.items).contains {
                $0.type == .assistantMessage && $0.body.contains("partial stream")
            }
        }
    }

    func test_timelineBuffersAssistantDeltaUntilItemStartedArrives() {
        var timeline = AssistantTimelineState()

        timeline.apply(.turnStarted(turnId: "turn-1"))
        timeline.apply(.itemDelta(itemId: "assistant-1", bodyAppend: "O: 1 2 3", outputAppend: nil, summary: nil))
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "assistant-1",
            turnId: "turn-1",
            type: .assistantMessage,
            startedAtMs: 1
        )))

        XCTAssertEqual(timeline.turns.first?.items.first?.body, "O: 1 2 3",
                       "provider notifications can reach the SwiftUI surface out of order; the first assistant delta must not be dropped or the user sees only tool/status rows")
    }

    func test_timelineIgnoresDuplicateTurnStartedForSameTurn() {
        var timeline = AssistantTimelineState()

        timeline.apply(.turnStarted(turnId: "turn-1"))
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "assistant-1",
            turnId: "turn-1",
            type: .assistantMessage,
            startedAtMs: 1
        )))
        timeline.apply(.itemDelta(itemId: "assistant-1", bodyAppend: "partial stream", outputAppend: nil, summary: nil))
        timeline.apply(.turnStarted(turnId: "turn-1"))

        XCTAssertEqual(timeline.turns.map(\.turnId), ["turn-1"],
                       "duplicate provider turn-start notifications must not duplicate the visible macOS transcript")
        XCTAssertEqual(timeline.turns.first?.items.first?.body, "partial stream",
                       "deduping the turn must preserve already streamed assistant text")
    }

    func test_promptComposerEnterSendsAndShiftEnterInsertsNewline() {
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "\r", charactersIgnoringModifiers: "\r",
                                     isARepeat: false, keyCode: 36)!
        let shiftEnter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "\r", charactersIgnoringModifiers: "\r",
                                          isARepeat: false, keyCode: 36)!

        XCTAssertEqual(PromptComposerKeyAction.action(for: enter), .send,
                       "plain Enter must send the prompt")
        XCTAssertEqual(PromptComposerKeyAction.action(for: shiftEnter), .insertNewline,
                       "Shift+Enter must keep editing and insert a line break")
    }

    func test_promptComposerArrowKeysRequestHistoryNavigation() {
        let up = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: 0, windowNumber: 0, context: nil,
                                  characters: "", charactersIgnoringModifiers: "",
                                  isARepeat: false, keyCode: 126)!
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: 125)!

        XCTAssertEqual(PromptComposerKeyAction.action(for: up), .previousHistory,
                       "Up arrow must behave like Terminal history when the composer is empty")
        XCTAssertEqual(PromptComposerKeyAction.action(for: down), .nextHistory,
                       "Down arrow must walk back toward the empty composer after history recall")
    }

    func test_emptyPromptRecallsSubmittedCommandHistoryLikeTerminal() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "history")
        vm.prompt = "/status"
        await vm.send()
        vm.prompt = "/model none"
        await vm.send()

        XCTAssertTrue(vm.recallPreviousPrompt())
        XCTAssertEqual(vm.prompt, "/model none",
                       "an empty composer Up arrow must restore the last submitted command")
        XCTAssertTrue(vm.recallPreviousPrompt())
        XCTAssertEqual(vm.prompt, "/status",
                       "a second Up arrow must continue through older submitted commands")
        XCTAssertTrue(vm.recallNextPrompt())
        XCTAssertEqual(vm.prompt, "/model none",
                       "Down arrow must move forward through recalled command history")
        XCTAssertTrue(vm.recallNextPrompt())
        XCTAssertEqual(vm.prompt, "",
                       "Down arrow after the newest recalled command must return to an empty composer")
    }

    func test_promptHistoryDoesNotOverwriteTypedDraft() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "history")
        vm.prompt = "/status"
        await vm.send()
        vm.prompt = "typed draft"

        XCTAssertFalse(vm.recallPreviousPrompt())

        XCTAssertEqual(vm.prompt, "typed draft",
                       "history recall must not replace text the user is already typing")
    }

    func test_unknownSlashCommandPassesThroughToProviderForAgentOwnedCommands() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .codex)
        vm.coordinator.replaceProvider(.codex, runner: runner)
        vm.createThread(title: "goal")
        vm.prompt = "/goal continue until the audit is implemented"

        await vm.send()

        await waitAsync("provider-owned slash command reaches runner") {
            runner.prompts.contains("/goal continue until the audit is implemented")
        }
        XCTAssertFalse(vm.messages.contains { $0.role == .system && $0.content.contains("Unknown command") },
                       "unknown slash commands must not be converted into local errors because providers own commands such as /goal")
    }

    func test_planCommandMakesNextProviderRunUsePlanInteractionMode() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .codex)
        vm.coordinator.replaceProvider(.codex, runner: runner)
        vm.createThread(title: "plan")
        vm.prompt = "/plan"
        await vm.send()
        XCTAssertFalse(vm.showPlanSidebar,
                       "plan mode must not open the side panel; proposed plans render in the main timeline")
        vm.prompt = "inspect before editing"

        await vm.send()

        await waitAsync("plan mode reaches runner") {
            runner.interactionModes.contains(.plan)
        }
        XCTAssertEqual(runner.prompts.last, "inspect before editing",
                       "plan mode must alter request metadata without corrupting the user-visible prompt")
    }

    func test_inlinePlanCommandSendsRemainingPromptInPlanMode() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .codex)
        vm.coordinator.replaceProvider(.codex, runner: runner)
        vm.createThread(title: "inline plan")

        vm.prompt = "/plan What's the best way to create the snake game?"
        await vm.send()
        XCTAssertFalse(vm.showPlanSidebar,
                       "inline /plan must keep the plan response in the main window instead of opening the side panel")

        await waitAsync("inline plan prompt reaches runner") {
            runner.interactionModes.contains(.plan)
        }
        XCTAssertEqual(runner.prompts.last, "What's the best way to create the snake game?",
                       "mobile and desktop users must be able to type /plan plus the actual question in one send without dropping the user prompt")
    }

    func test_inlinePlanCommandWorksForClaudeProvider() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .claude)
        vm.coordinator.replaceProvider(.claude, runner: runner)
        vm.createThread(title: "inline plan claude")
        vm.provider = .claude
        vm.model = "claude-sonnet-4-6"

        vm.prompt = "/plan What's the best way to create the snake game?"
        await vm.send()
        XCTAssertFalse(vm.showPlanSidebar,
                       "Claude inline /plan must keep the plan response in the main window instead of opening the side panel")

        await waitAsync("inline plan prompt reaches Claude runner") {
            runner.interactionModes.contains(.plan)
        }
        XCTAssertEqual(runner.prompts.last, "What's the best way to create the snake game?",
                       "Claude plan mode must receive the prompt text when /plan and the question are sent together")
    }

    func test_defaultCommandMakesNextProviderRunUseDefaultInteractionMode() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .claude)
        vm.coordinator.replaceProvider(.claude, runner: runner)
        vm.createThread(title: "default")
        vm.provider = .claude
        vm.model = "claude-sonnet-4-6"
        vm.prompt = "/plan"
        await vm.send()
        vm.prompt = "inspect before editing"
        await vm.send()
        await waitAsync("plan mode reaches runner and completes") {
            runner.interactionModes.contains(.plan) &&
            runner.prompts.last == "inspect before editing" &&
            vm.status == .completed
        }

        vm.prompt = "/default"
        await vm.send()
        vm.prompt = "now implement"
        await vm.send()

        await waitAsync("default mode reaches runner") {
            runner.interactionModes.last == .default &&
            runner.prompts.last == "now implement"
        }
        XCTAssertEqual(runner.prompts.last, "now implement",
                       "/default must restore provider runtime behavior without sending a local command as user prompt")
    }

    func test_typingAfterHistoryRecallTurnsRecalledPromptIntoEditableDraft() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "history")
        vm.prompt = "/status"
        await vm.send()

        XCTAssertTrue(vm.recallPreviousPrompt())
        vm.prompt += " now"
        vm.promptWasEdited()

        XCTAssertEqual(vm.prompt, "/status now",
                       "after history recall the restored command must remain editable")
        XCTAssertFalse(vm.recallNextPrompt(),
                       "typing after recall must stop history navigation from owning the draft")
        XCTAssertEqual(vm.prompt, "/status now",
                       "history navigation must not clear or replace a recalled prompt after the user edits it")
    }

    func test_promptHistoryPersistsPerWorkspaceAndReloads() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-history-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: FakeProviderRunner(provider: .codex)])
        let store = PromptHistoryStore(db: db)
        let firstWorkspace = WorkspaceID()
        let secondWorkspace = WorkspaceID()
        let first = AgentAppViewModel(workspaceID: firstWorkspace, cwd: tmp,
                                      coordinator: coord, threadRepo: threadRepo,
                                      messageRepo: messageRepo, promptHistoryStore: store)
        let second = AgentAppViewModel(workspaceID: secondWorkspace, cwd: tmp,
                                       coordinator: coord, threadRepo: threadRepo,
                                       messageRepo: messageRepo, promptHistoryStore: store)

        first.createThread(title: "first")
        first.prompt = "/status first"
        await first.send()
        second.createThread(title: "second")
        second.prompt = "/status second"
        await second.send()

        let reloadedFirst = AgentAppViewModel(workspaceID: firstWorkspace, cwd: tmp,
                                              coordinator: coord, threadRepo: threadRepo,
                                              messageRepo: messageRepo, promptHistoryStore: store)
        XCTAssertTrue(reloadedFirst.recallPreviousPrompt())
        XCTAssertEqual(reloadedFirst.prompt, "/status first",
                       "prompt history must persist by workspace and must not leak another workspace's commands")
    }

    func test_promptHistoryEvictsOldestBeyondCap() async throws {
        // WHY: history must retain the newest `PromptHistoryStore.limit` entries
        // and evict the oldest. Limit-relative so a future cap change (it was
        // raised 20 -> 200 in commit 43a126d for :93) does not silently rot this
        // test: send cap+1 commands, then `/status 1` must be the one evicted.
        let (vm, _) = try makeVM()
        vm.createThread(title: "history")
        let cap = PromptHistoryStore.limit
        for index in 1...(cap + 1) {
            vm.prompt = "/status \(index)"
            await vm.send()
        }

        for _ in 0..<cap {
            XCTAssertTrue(vm.recallPreviousPrompt())
        }
        XCTAssertEqual(vm.prompt, "/status 2",
                       "prompt history must retain the newest \(cap) entries and evict the oldest command")
        XCTAssertTrue(vm.recallPreviousPrompt())
        XCTAssertEqual(vm.prompt, "/status 2",
                       "pressing Up past the retained history must stay on the oldest retained command")
    }

    // MARK: B2 — slash commands

    func test_send_slashCommand_neverBecomesAUserMessageOrRun() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "keep")
        let before = vm.threads.count
        vm.prompt = "/clear"
        await vm.send()
        XCTAssertEqual(vm.prompt, "", "the composer must clear after a slash command")
        XCTAssertFalse(vm.messages.contains { $0.role == .user && $0.content == "/clear" },
                       "/clear must not be sent to the provider as a user message")
        XCTAssertEqual(vm.threads.count, before + 1, "/clear must open a fresh thread")
    }

    func test_slashFork_copiesHistoryIntoNewThread() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "source")
        let src = vm.selectedThreadId!
        try? vm.messageRepo.append(AgentMessage(threadId: src, role: .user, content: "q1"))
        try? vm.messageRepo.append(AgentMessage(threadId: src, role: .assistant, content: "a1"))
        XCTAssertTrue(vm.handleSlashCommand("/fork"))
        let forkedId = vm.selectedThreadId!
        XCTAssertNotEqual(forkedId, src, "/fork must select the new thread")
        XCTAssertEqual(vm.threads.first(where: { $0.id == forkedId })?.title, "source (fork)")
        let copied = (try? vm.messageRepo.list(threadId: forkedId)) ?? []
        XCTAssertEqual(copied.map(\.content), ["q1", "a1"],
                       "/fork must copy the source thread's history verbatim")
    }

    func test_slashModel_setsModelOnMatchAndListsOtherwise() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        vm.availableModels = [AgentModelDescriptor(id: "gpt-5", label: "GPT-5", provider: .codex),
                              AgentModelDescriptor(id: "o4", label: "O4 Mini", provider: .codex)]
        vm.handleSlashCommand("/model o4")
        XCTAssertEqual(vm.model, "o4", "/model <arg> must switch to the matching model")
        vm.handleSlashCommand("/model")
        XCTAssertTrue(vm.messages.last?.content.contains("GPT-5") ?? false,
                      "bare /model must list available models as a system note")
        XCTAssertEqual(vm.messages.last?.role, .system)
    }

    func test_slashStatus_appendsSystemSummary() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        vm.handleSlashCommand("/status")
        XCTAssertEqual(vm.messages.last?.role, .system)
        XCTAssertTrue(vm.messages.last?.content.contains("provider=") ?? false,
                      "/status must surface the run configuration")
    }

    func test_slashUnknown_returnsFalseSoProviderCanHandleIt() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        XCTAssertFalse(vm.handleSlashCommand("/wat"),
                       "unknown slash commands must be left for Codex or Claude instead of becoming local errors")
        XCTAssertFalse(vm.messages.contains { $0.content.contains("Unknown command") })
    }

    // MARK: B4 — read/unread, active count, provider-model coherence

    /// Async wait — `Task.sleep` yields the main-actor executor so the
    /// coordinator's observer callbacks (`Task { @MainActor … }`) run.
    /// RunLoop pumping does NOT service Swift concurrency, hence this.
    private func waitAsync(_ desc: String, timeout: TimeInterval = 6, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(cond(), "timed out waiting for: \(desc)")
    }

    private func runGit(_ args: [String], cwd: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "git failed"
            throw NSError(domain: "AgentAppViewModelTests.git", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    private func currentProcessFootprintKB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1024)
    }

    private func renderedPNGData<V: View>(for rootView: V, size: NSSize = NSSize(width: 1000, height: 720)) -> Data? {
        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: size)
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func test_selectThread_marksItRead() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "a")
        let a = vm.selectedThreadId!
        vm.createThread(title: "b")
        let b = vm.selectedThreadId!
        // Mark a unread out-of-band (as a background completion would).
        var ta = try repo.get(id: a)!; ta.hasUnread = true; try repo.upsert(ta)
        vm.reloadThreads()
        XCTAssertTrue(vm.threads.first { $0.id == a }?.hasUnread ?? false)
        vm.selectThread(b)
        vm.selectThread(a)
        XCTAssertEqual(try repo.get(id: a)?.hasUnread, false,
                       "opening a thread must clear its unread flag in the store")
        XCTAssertFalse(vm.threads.first { $0.id == a }?.hasUnread ?? true,
                       "the rail must drop the unread dot without a full requery")
    }

    func test_activeThreadCount_countsRunningThreads() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "idle")
        vm.createThread(title: "busy")
        let busy = vm.selectedThreadId!
        var t = try repo.get(id: busy)!; t.status = .running; try repo.upsert(t)
        vm.reloadThreads()
        XCTAssertEqual(vm.activeThreadCount, 1, "only running threads are 'active'")
    }

    func test_loadModels_keepsModelValidForProvider() async throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.model = "bogus-not-a-real-model"
        await vm.loadModels()
        if !vm.availableModels.isEmpty {
            XCTAssertTrue(vm.availableModels.contains { $0.id == vm.model },
                          "a provider switch must leave a model valid for that provider")
        }
    }

    func test_providerSwitchClearsStaleModelBeforeAsyncLoad() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.availableModels = [
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)
        ]
        vm.model = "gpt-5.5"

        vm.setProvider(.claude)

        XCTAssertEqual(vm.provider, .claude)
        XCTAssertEqual(vm.availableModels, [],
                       "macOS Source changes must clear stale Codex model rows immediately while Claude models load")
        XCTAssertEqual(vm.model, "",
                       "macOS must not keep sending the old Codex model after the user switches Source to Claude")
    }

    func test_providerInstancePickerCannotShowClaudeSourceWithCodexModels() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.providerInstanceId = "codex-cli"
        vm.availableModels = [
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)
        ]
        vm.model = "gpt-5.5"
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                authenticated: true,
                accountLabel: "codex@example.com",
                accountAuthMethod: "codex",
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                slashCommands: []
            ),
            AgentProviderSnapshot(
                id: "claude-cli",
                provider: .claude,
                driverKind: .claudeCLI,
                displayName: "Claude",
                accentColor: "#D97706",
                continuationGroup: "anthropic-claude",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                authenticated: true,
                accountLabel: "claude@example.com",
                accountAuthMethod: "claude.ai",
                models: [AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)],
                slashCommands: []
            )
        ]

        vm.providerInstanceId = "claude-cli"

        XCTAssertEqual(vm.selectedProviderSnapshot?.provider, .claude)
        XCTAssertEqual(vm.modelOptionsForSelectedProvider.map(\.provider), [.claude],
                       "the model menu must follow the selected Source snapshot immediately; otherwise the user sees Claude with Codex GPT models until changing Source twice")
        XCTAssertFalse(vm.modelOptionsForSelectedProvider.contains { $0.id.hasPrefix("gpt-") },
                       "the model menu must not keep Codex GPT rows after the selected Source snapshot is Claude")
    }

    func test_modelDescriptorControlsClampIllegalReasoningAndServiceTier() throws {
        let (vm, _) = try makeVM()
        vm.provider = .claude
        vm.availableModels = [
            AgentModelDescriptor(id: "haiku", label: "Haiku", provider: .claude, supportsReasoning: false, supportsCustomModel: true),
            AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude, supportsReasoning: true, supportedReasoningEfforts: [.high], supportsCustomModel: true)
        ]

        vm.model = "haiku"
        vm.reasoningEffort = .xhigh
        vm.serviceTier = .fast
        vm.normalizeSelectedModelOptions()

        XCTAssertFalse(vm.supportsReasoningForSelectedModel,
                       "models without thinking support must not render a reasoning picker")
        XCTAssertEqual(vm.reasoningEffort, .medium,
                       "unsupported reasoning selections must be clamped before persistence/send")
        XCTAssertEqual(vm.serviceTier, .auto,
                       "Claude/non-service-tier models must not preserve Codex fast mode")

        vm.setModel("opus")
        vm.setReasoningEffort(.xhigh)

        XCTAssertEqual(vm.supportedReasoningEffortsForSelectedModel, [.high])
        XCTAssertEqual(vm.reasoningEffort, .high,
                       "reasoning controls must use the selected model descriptor, not a global effort list")
    }

    func test_modelDescriptorControlsPreserveCustomModelAndContextWindow() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.availableModels = [
            AgentModelDescriptor(id: "", label: "Default", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true, contextWindowTokens: 400_000),
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true, contextWindowTokens: 1_000_000)
        ]

        vm.setCustomModel("gpt-experimental")

        XCTAssertEqual(vm.model, "gpt-experimental",
                       "custom-capable providers must not collapse a user-entered model back to the first known descriptor")
        XCTAssertTrue(vm.supportsCustomModelForSelectedProvider)
        XCTAssertEqual(vm.selectedModelContextWindowLabel, "400k ctx",
                       "custom model selections should inherit the provider custom descriptor's context-window metadata for the UI")
        XCTAssertTrue(vm.supportsServiceTierForSelectedModel,
                      "custom Codex model selections should preserve descriptor-specific service-tier controls")

        vm.availableModels = [
            AgentModelDescriptor(id: "haiku", label: "Haiku", provider: .claude, supportsReasoning: false, supportsCustomModel: false)
        ]
        vm.provider = .claude
        vm.setCustomModel("claude-custom")

        XCTAssertEqual(vm.model, "gpt-experimental",
                       "providers without custom-model support must ignore custom model entry instead of persisting an unsupported id")
    }

    func test_customModelSelectionPersistsForFutureAgentModelMenus() throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-custom-model-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let customStore = AgentCustomModelStore(db: db)
        let models = [
            AgentModelDescriptor(id: "", label: "Default", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.4", label: "GPT-5.4", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-5.4-mini", label: "GPT-5.4-Mini", provider: .codex, supportsReasoning: true, supportsServiceTier: true, supportsCustomModel: true)
        ]
        let first = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            customModelStore: customStore
        )
        first.availableModels = models

        first.setCustomModel("gpt-5.5-experimental")

        XCTAssertEqual(first.customModelsForSelectedProvider, ["gpt-5.5-experimental"],
                       "the Custom option must save the user-entered model so it appears in later model menus")
        XCTAssertEqual(first.currentModelSelection.customModelId, "gpt-5.5-experimental",
                       "custom selections must be sent as customModelId instead of masquerading as a built-in descriptor")

        let reloaded = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            customModelStore: customStore
        )
        reloaded.availableModels = models

        XCTAssertEqual(reloaded.customModelsForSelectedProvider, ["gpt-5.5-experimental"],
                       "custom model IDs must persist until the user edits or removes them in Settings")
    }

    // MARK: Full-thread message history (replaces the old viewport window)

    func test_selectingThreadLoadsEntireThreadWithBodiesRetained() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "long")
        let tid = vm.selectedThreadId!
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<100 {
            try vm.messageRepo.append(AgentMessage(threadId: tid, role: .user,
                content: "m\(i)", createdAt: base.addingTimeInterval(Double(i))))
        }
        vm.selectThread(tid)
        // The fix: the entire thread loads at once — no infinite-scroll paging and no
        // off-screen body eviction. Paging + evict flipped row heights mid-scroll, which
        // is what made auto-scroll jump. Full load makes every row's height stable.
        XCTAssertEqual(vm.messages.count, 100,
                       "the whole thread must load up front, not a 30-row viewport window")
        XCTAssertEqual(vm.messages.first?.content, "m0", "oldest message present and ordered first")
        XCTAssertEqual(vm.messages.last?.content, "m99", "newest message present and ordered last")
        XCTAssertTrue(vm.messages.allSatisfy { !$0.content.isEmpty },
                      "every body stays hydrated — no eviction that would change a row's height on scroll")
    }

    func test_applyBodyBudgetBlanksOldestBodiesOnPathologicalThread() {
        let tid = AgentThreadID()
        let base = Date(timeIntervalSince1970: 1)
        let rows = (0..<5).map { i in
            AgentMessage(threadId: tid, role: .user,
                         content: String(repeating: "x", count: 10),
                         createdAt: base.addingTimeInterval(Double(i)))
        }
        // 5 x 10 bytes = 50 > budget 25 -> blank oldest until <= 25 (blank 3 -> 20 bytes).
        let (out, blanked) = AgentAppViewModel.applyBodyBudget(rows, budget: 25)
        XCTAssertEqual(blanked, 3, "memory safety-valve blanks oldest bodies until total <= budget")
        XCTAssertEqual(out.prefix(3).map(\.content), ["", "", ""], "oldest bodies blanked first")
        XCTAssertEqual(out.suffix(2).map(\.content).filter { $0.count == 10 }.count, 2,
                       "newest bodies are retained in full — the user lands at the bottom")
    }

    func test_applyBodyBudgetKeepsEverythingForANormalThread() {
        let tid = AgentThreadID()
        let rows = (0..<3).map { _ in AgentMessage(threadId: tid, role: .user, content: "hi") }
        let (out, blanked) = AgentAppViewModel.applyBodyBudget(rows, budget: 1_000_000)
        XCTAssertEqual(blanked, 0, "a normal thread loads in full with nothing blanked")
        XCTAssertEqual(out.map(\.content), ["hi", "hi", "hi"])
    }

    private func startedItems(_ n: Int) -> [AssistantEvent] {
        (0..<n).map { .itemStarted(item: AssistantItem(id: "i\($0)", turnId: "t\($0)", type: .tool, startedAtMs: Int64($0))) }
    }

    func test_chooseReplayPrefersFullPersistedOverCompactedProviderSnapshot() {
        // The reported "thread cortado": the provider (Codex) thread/read is context-compacted
        // and returns only the recent tail; our persisted stream events are the full record.
        let persisted = startedItems(83)
        let compactedSnapshot = startedItems(20)
        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: persisted, snapshot: compactedSnapshot)
        XCTAssertEqual(AgentAppViewModel.renderableItemCount(chosen), 83,
                       "a context-compacted snapshot must not truncate the reopened thread — show 100% of persisted history")
    }

    func test_chooseReplayUsesSnapshotWhenPersistedIsThinner() {
        // Imported-from-external-session thread: persisted history is thin, the provider has it all.
        let chosen = AgentAppViewModel.chooseReplayEvents(persisted: startedItems(2), snapshot: startedItems(40))
        XCTAssertEqual(AgentAppViewModel.renderableItemCount(chosen), 40,
                       "when persisted history is thinner, the provider snapshot fills it in")
    }

    func test_chooseReplayFallsBackToPersistedWhenNoSnapshot() {
        let persisted = startedItems(5)
        XCTAssertEqual(AgentAppViewModel.chooseReplayEvents(persisted: persisted, snapshot: nil).count, 5)
    }

    func test_loadWindowClipsHugePersistedMessagesBeforeRendering() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "huge")
        let tid = vm.selectedThreadId!
        try vm.messageRepo.append(AgentMessage(
            threadId: tid,
            role: .assistant,
            content: String(repeating: "x", count: AssistantTimelineState.liveTextLimit + 10)
        ))

        vm.selectThread(tid)

        XCTAssertEqual(vm.messages.first?.content.count, AssistantTimelineState.liveTextLimit,
                       "a huge persisted transcript must be clipped before SwiftUI renders it")
    }

    func test_agentAppLongRunStressStaysBoundedAndReleasesRunState() async throws {
        let runner = LongRunStreamRunner(turns: 90, runtimeEvents: 650)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "long stress")
        let threadId = try XCTUnwrap(vm.selectedThreadId)
        let beforeKB = currentProcessFootprintKB()

        vm.prompt = "exercise a long running agent stream"
        await vm.send()

        await waitAsync("long Agent App stream completes", timeout: 15) {
            vm.status == .completed && vm.timeline.latestAssistantMessage == "LONG_ASSISTANT_89"
        }
        let afterKB = currentProcessFootprintKB()

        XCTAssertEqual(vm.currentRunId, nil,
                       "completed long runs must clear the selected Agent App run id instead of leaving Stop/Working state stuck")
        XCTAssertEqual(vm.runStartedAt, nil,
                       "completed long runs must clear the Working-for timer")
        XCTAssertTrue(vm.coordinator.activeThreadIdsSnapshot().isEmpty,
                      "the coordinator must release active thread handles after a long Agent App run")
        XCTAssertLessThanOrEqual(vm.timeline.turns.count, AssistantTimelineState.liveTurnLimit,
                                 "turns stay under the memory-ceiling backstop")
        XCTAssertEqual(vm.timeline.turns.last?.turnId, "long-turn-89",
                       "the newest long-run turn stays visible")
        XCTAssertTrue(vm.timeline.turns.contains { $0.turnId == "long-turn-0" },
                      "the WHOLE run is retained now (90 turns < 5000 ceiling) — no mid-thread truncation")
        XCTAssertEqual(vm.timeline.turns.count, 90,
                       "all 90 turns of the long run are kept (full thread, 100%)")
        XCTAssertLessThanOrEqual(vm.timeline.providerRuntimeEvents.count, AssistantTimelineState.providerRuntimeEventLimit,
                                 "raw provider runtime events must stay capped during long runs")
        XCTAssertLessThanOrEqual(vm.timeline.workActivities.count, AssistantTimelineState.workActivityLimit,
                                 "work-log rows must stay capped during long runs")
        XCTAssertTrue(vm.contextHealthMessage?.contains("compacted") ?? false,
                      "the Agent App must expose context compaction during long runs")

        // Reopen from a COLD state (fresh VM has no live timeline) — this exercises the
        // replay-from-persisted-events path, which used to cap at the last 500 events.
        vm.selectThread(threadId)
        let persistedCount = (try? vm.messageRepo.list(threadId: threadId).count) ?? -1
        XCTAssertEqual(vm.messages.count, persistedCount,
                       "reopening a long thread loads the ENTIRE thread (no infinite-scroll window)")
        XCTAssertGreaterThan(vm.timeline.turns.count, 80,
                             "reopen replays the WHOLE persisted thread (>500-event window, >80-turn cap) — the long run's turns must come back, not just the last few")

        // The full load must still stay bounded: the LazyVStack only realizes visible rows
        // and the turn ceiling/event-prune keep it bounded, so footprint can't balloon.
        if beforeKB >= 0 && afterKB >= 0 {
            XCTAssertLessThan(afterKB - beforeKB, 250_000,
                              "macOS Agent App long-run stress must not grow process footprint by more than 250 MB")
        }
    }

    func test_agentAppLongRunStressRendersMacSurfaceWithoutBlankingOrStuckRun() async throws {
        let runner = LongRunStreamRunner(turns: 50, runtimeEvents: 300)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "visual long stress")

        vm.prompt = "exercise a rendered long running agent stream"
        await vm.send()

        await waitAsync("rendered long Agent App stream completes", timeout: 15) {
            vm.status == .completed && vm.timeline.latestAssistantMessage == "LONG_ASSISTANT_49"
        }

        let png = try XCTUnwrap(renderedPNGData(for: AgentAppView(vm: vm)),
                                "the macOS Agent App SwiftUI surface must render to a non-empty bitmap after a long provider stream")
        XCTAssertGreaterThan(png.count, 25_000,
                             "long-run stress must leave a visible macOS Agent App surface instead of a blank or collapsed view")
        XCTAssertEqual(vm.currentRunId, nil,
                       "rendering after a long provider stream must not leave the macOS Agent App stuck in a selected run")
        XCTAssertEqual(vm.runStartedAt, nil,
                       "rendering after a long provider stream must not leave the Working timer active")
        XCTAssertEqual(vm.timeline.turns.last?.turnId, "long-turn-49",
                       "the rendered long-run surface must keep the newest assistant turn available")
        XCTAssertLessThanOrEqual(vm.timeline.providerRuntimeEvents.count, AssistantTimelineState.providerRuntimeEventLimit,
                                 "rendering must consume the bounded runtime-event window instead of retaining all provider events")
        XCTAssertLessThanOrEqual(vm.timeline.workActivities.count, AssistantTimelineState.workActivityLimit,
                                 "rendering must consume the bounded work-log window instead of retaining every long-run row")
        XCTAssertTrue(vm.contextHealthMessage?.contains("compacted") ?? false,
                      "rendering must keep long-run context/compaction telemetry visible")
    }

    // MARK: B3 — composer attachments

    func test_attachments_addDedupesAndRemove() throws {
        let (vm, _) = try makeVM()
        vm.addAttachments(["/a.txt", "/b.txt", "/a.txt"])
        XCTAssertEqual(vm.attachments, ["/a.txt", "/b.txt"], "duplicate paths must not stack")
        vm.removeAttachment("/a.txt")
        XCTAssertEqual(vm.attachments, ["/b.txt"])
    }

    func test_droppedFilePaths_insertIntoPromptWithoutAttaching() throws {
        let (vm, _) = try makeVM()
        vm.prompt = "review"

        vm.insertDroppedFilePaths(["/tmp/plain.txt", "/tmp/has space.txt"])

        XCTAssertEqual(vm.prompt, "review /tmp/plain.txt /tmp/has space.txt",
                       "dragging files into the composer must fill the input with file paths")
        XCTAssertTrue(vm.attachments.isEmpty,
                      "drop-to-input is text insertion, not the attachment-chip flow")
    }

    func test_send_withAttachments_composesPromptAndClears() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "t")
        let tid = vm.selectedThreadId!
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-attachment-\(UUID().uuidString).swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        vm.prompt = "review these"
        vm.addAttachments([file.path])
        await vm.send()

        XCTAssertTrue(vm.attachments.isEmpty, "attachments must clear after send")
        XCTAssertEqual(runner.prompts.last, "review these",
                       "attachment metadata must not be folded into provider prompt text")
        XCTAssertEqual(runner.attachments.last?.map(\.path), [file.path],
                       "provider runs must receive structured attachment metadata")
        let persistedMessages: [AgentMessage] = (try? vm.messageRepo.list(threadId: tid)) ?? []
        let user = persistedMessages.first { $0.role == .user }
        XCTAssertFalse(user?.content.contains(file.path) ?? true,
                       "persisted transcript must not leak raw attachment paths into prompt text")
        XCTAssertTrue(user?.content.contains(file.lastPathComponent) ?? false,
                      "the persisted transcript should keep a friendly attachment summary")
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content.contains("📎") },
                      "the transcript shows a friendly attachment summary, not raw paths")
    }

    func test_send_withMissingAttachmentFailsLoudAndDoesNotStartRun() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "t")
        vm.prompt = "review"
        vm.addAttachments(["/tmp/remote-code-missing-\(UUID().uuidString).png"])

        await vm.send()

        XCTAssertTrue(runner.prompts.isEmpty,
                      "missing attachments must fail before provider spawn instead of sending a bad path")
        XCTAssertTrue(vm.messages.contains { $0.role == .system && $0.content.contains("Attachment not found") },
                      "attachment resolution errors must be visible to the user")
    }

    func test_send_persistsExactlyOneUserAndOneAssistantMessage() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "convo")
        let tid = vm.selectedThreadId!
        vm.prompt = "hello there"
        await vm.send()
        // Deterministic: the coordinator persists the user message inside
        // (awaited) startRun; the VM must NOT also persist it.
        let afterSend = (try? vm.messageRepo.list(threadId: tid)) ?? []
        XCTAssertEqual(afterSend.filter { $0.role == .user && $0.content == "hello there" }.count, 1,
                       "the user message must be persisted exactly once (coordinator is the single writer)")
        await waitAsync("fake run completes") { vm.status == .completed }
        let assistants = ((try? vm.messageRepo.list(threadId: tid)) ?? []).filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1, "the assistant reply must be persisted exactly once, not double-written")
    }

    func test_completedSelectedRunKeepsLiveTimelineVisible() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-completed-timeline-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: HoldOpenStreamRunner()]
        )
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo)
        vm.createThread(title: "live")
        vm.prompt = "stream please"
        await vm.send()

        await waitAsync("run completes") { vm.status == .completed }

        XCTAssertTrue(vm.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage && $0.body.contains("partial stream")
        }, "the completed selected run must keep live stream/history items visible instead of collapsing to the final answer only")
    }

    func test_secondSendKeepsPriorTimelineHistoryVisible() async throws {
        let (vm, _) = try makeVM()
        vm.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(
            provider: .codex,
            scenario: .withTool(toolName: "Bash", output: "tool output", reply: "first answer")
        ))
        vm.createThread(title: "convo")

        vm.prompt = "first prompt"
        await vm.send()
        await waitAsync("first answer completes") { vm.status == .completed }
        XCTAssertTrue(vm.timeline.turns.flatMap(\.items).contains {
            $0.type == .tool && $0.output == "tool output"
        }, "after completion the selected thread may keep tools and updates in the live timeline")

        vm.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: "second answer")))
        vm.prompt = "second prompt"
        await vm.send()
        // The second run settles asynchronously: the user message is mirrored
        // in-memory immediately, but a trailing run-state callback can reload
        // `vm.messages` from the DB before the second prompt is durably
        // persisted. Wait for the second turn to fully settle so the assertions
        // observe a stable state instead of a mid-reload snapshot.
        await waitAsync("second turn settles with prior history intact") {
            vm.status == .completed &&
            vm.messages.contains { $0.role == .user && $0.content == "second prompt" } &&
            vm.messages.contains { $0.role == .assistant && $0.content == "first answer" }
        }

        XCTAssertTrue(vm.timeline.turns.flatMap(\.items).contains {
            $0.type == .tool && $0.output == "tool output"
        }, "sending a follow-up must not clear prior agent timeline history such as tool calls and outputs")
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content == "first prompt" })
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content == "second prompt" })
        let persistedAssistantTexts = vm.messages.compactMap { $0.role == .assistant ? $0.content : nil }
        XCTAssertTrue(persistedAssistantTexts.contains("first answer"),
                      "the persisted assistant answer must remain available as the durable completed response")
        XCTAssertFalse(vm.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage &&
            $0.body == "first answer" &&
            AgentAppView.shouldRenderAssistantItemBody($0.body, persistedAssistantTexts: persistedAssistantTexts)
        }, "the replayed assistant timeline must not render a duplicate of the persisted final answer")
    }

    func test_selectThreadReplaysPersistedStreamHistoryWithoutDuplicatingFinalAnswer() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-replay-timeline-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: HoldOpenStreamRunner()]
        )
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo)
        vm.createThread(title: "live")
        let streamedThread = vm.selectedThreadId!
        vm.prompt = "stream please"
        await vm.send()
        await waitAsync("run completes") { vm.status == .completed }
        await waitAsync("stream timeline is persisted before reload") {
            vm.timeline.turns.flatMap(\.items).contains {
                $0.type == .assistantMessage && $0.body.contains("partial stream")
            }
        }
        await waitAsync("stream event store contains assistant partial before reload") {
            coordinator.latestStreamEvents(threadId: streamedThread).contains { event in
                if case .itemDelta(let itemId, let bodyAppend, _, _) = event {
                    return !itemId.isEmpty && (bodyAppend ?? "").contains("partial stream")
                }
                return false
            }
        }

        vm.createThread(title: "other")
        let reloadedVM = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                           coordinator: coordinator, threadRepo: threadRepo,
                                           messageRepo: messageRepo)
        reloadedVM.selectThread(streamedThread)

        XCTAssertTrue(reloadedVM.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage && $0.body.contains("partial stream")
        }, "reopening a thread must replay persisted stream items, not just show the final answer")
        let persistedAssistantTexts = reloadedVM.messages.compactMap { $0.role == .assistant ? $0.content : nil }
        XCTAssertEqual(persistedAssistantTexts.filter { $0 == "partial stream final" }.count, 1,
                       "the persisted final answer must remain available as the durable completed response")
        XCTAssertFalse(reloadedVM.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage &&
            $0.body == "partial stream final" &&
            AgentAppView.shouldRenderAssistantItemBody($0.body, persistedAssistantTexts: persistedAssistantTexts)
        }, "the replayed assistant stream must not render a duplicate of the persisted final answer")
    }

    func test_selectThreadReplaysPersistedContextTelemetryAfterRestart() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-replay-context-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: ContextTelemetryRunner()]
        )
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo)
        vm.createThread(title: "telemetry")
        let streamedThread = vm.selectedThreadId!
        vm.prompt = "report context"
        await vm.send()
        await waitAsync("telemetry run completes") { vm.status == .completed }

        let reloadedVM = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                           coordinator: coordinator, threadRepo: threadRepo,
                                           messageRepo: messageRepo)
        reloadedVM.selectThread(streamedThread)

        XCTAssertEqual(reloadedVM.contextHealthMessage, "Context 50% · 500 / 1000 tokens · auto-compacts · compacted",
                       "reopening a thread after app restart must replay persisted token/compaction telemetry so long-run context pressure stays visible")
    }

    func test_realCodexAppServerAgentSurfaceSurvivesAppRestartAndRehydratesProviderHistory() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server Agent App surface E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-agent-app-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let workspaceID = WorkspaceID()

        let firstAdapter = CodexAppServerAdapter()
        let firstCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            providerAdapters: [.codex: firstAdapter]
        )
        let firstSurface = AgentAppViewModel(workspaceID: workspaceID,
                                             cwd: tmp,
                                             coordinator: firstCoordinator,
                                             threadRepo: threadRepo,
                                             messageRepo: messageRepo)
        firstSurface.createThread(title: "real codex")
        firstSurface.provider = .codex
        firstSurface.model = "gpt-5.5"
        firstSurface.reasoningEffort = .minimal
        firstSurface.permissionMode = .supervised
        firstSurface.prompt = "Reply exactly RC_AGENT_APP_REAL_1 and nothing else."

        await firstSurface.send()
        await waitAsync("first real Codex app-server Agent App turn completes", timeout: 240) {
            firstSurface.status == .completed
        }

        let threadId = try XCTUnwrap(firstSurface.selectedThreadId)
        let providerThreadId = try XCTUnwrap(try threadRepo.get(id: threadId)?.providerThreadId)
        XCTAssertTrue(firstSurface.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage && $0.body.contains("RC_AGENT_APP_REAL_1")
        }, "the macOS Agent App surface must render the first real Codex app-server response")

        firstAdapter.stopAll()

        let secondAdapter = CodexAppServerAdapter()
        let secondCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            providerAdapters: [.codex: secondAdapter]
        )
        let secondSurface = AgentAppViewModel(workspaceID: workspaceID,
                                              cwd: tmp,
                                              coordinator: secondCoordinator,
                                              threadRepo: threadRepo,
                                              messageRepo: messageRepo)
        secondSurface.selectThread(threadId)
        XCTAssertTrue(secondSurface.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage && $0.body.contains("RC_AGENT_APP_REAL_1")
        }, "after app/coordinator restart, selecting the thread must recover provider history through Codex thread/read")

        secondSurface.prompt = "Reply exactly RC_AGENT_APP_REAL_2 and nothing else."
        await secondSurface.send()
        await waitAsync("second real Codex app-server Agent App turn completes after restart", timeout: 240) {
            secondSurface.status == .completed
        }

        let resumedThread = try XCTUnwrap(try threadRepo.get(id: threadId))
        XCTAssertEqual(resumedThread.providerThreadId, providerThreadId,
                       "the app restart follow-up must resume the same Codex app-server provider thread instead of forking a disconnected session")
        XCTAssertTrue(secondSurface.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage && $0.body.contains("RC_AGENT_APP_REAL_2")
        }, "the macOS Agent App surface must render the real Codex follow-up after restart")

        secondAdapter.stopAll()

        let readbackAdapter = CodexAppServerAdapter()
        let readbackCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            providerAdapters: [.codex: readbackAdapter]
        )
        let readbackSurface = AgentAppViewModel(workspaceID: workspaceID,
                                                cwd: tmp,
                                                coordinator: readbackCoordinator,
                                                threadRepo: threadRepo,
                                                messageRepo: messageRepo)
        readbackSurface.selectThread(threadId)
        let renderedBodies = readbackSurface.timeline.turns.flatMap(\.items).map(\.body).joined(separator: "\n")
        XCTAssertTrue(renderedBodies.contains("RC_AGENT_APP_REAL_1"))
        XCTAssertTrue(renderedBodies.contains("RC_AGENT_APP_REAL_2"),
                      "final app restart readback must prove both real Codex app-server turns remain visible in provider history")
        readbackAdapter.stopAll()
    }

    func test_realCodexAppServerPlanModeSurfaceRendersAndImplementsProposedPlan() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server Plan Mode surface E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-plan-surface-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let sentinel = tmp + "/sentinel.txt"
        try "RC_PLAN_SENTINEL_ORIGINAL\n".write(toFile: sentinel, atomically: true, encoding: .utf8)

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp + "-db").run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let workspaceID = WorkspaceID()

        let adapter = CodexAppServerAdapter()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            providerAdapters: [.codex: adapter]
        )
        let surface = AgentAppViewModel(workspaceID: workspaceID,
                                        cwd: tmp,
                                        coordinator: coordinator,
                                        threadRepo: threadRepo,
                                        messageRepo: messageRepo)
        surface.createThread(title: "real plan")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        surface.permissionMode = .supervised
        surface.showPlanSidebar = true
        surface.prompt = """
        Create a proposed implementation plan only. Do not edit files.
        The plan must include this exact marker: RC_AGENT_APP_PLAN_SURFACE.
        The plan must include one implementation step that says to reply exactly RC_AGENT_APP_PLAN_IMPLEMENTED.
        """

        await surface.send()
        await waitAsync("real Codex Plan Mode surface completes", timeout: 240) {
            surface.status == .completed
        }
        let threadId = try XCTUnwrap(surface.selectedThreadId)
        await waitAsync("real Codex Plan Mode proposed plan is rendered", timeout: 20) {
            (surface.latestPlanText ?? "").contains("RC_AGENT_APP_PLAN_SURFACE")
        }

        XCTAssertEqual(try String(contentsOfFile: sentinel), "RC_PLAN_SENTINEL_ORIGINAL\n",
                       "Plan Mode through the macOS Agent App surface must not mutate workspace files")
        let providerThreadId = try XCTUnwrap(try threadRepo.get(id: threadId)?.providerThreadId)
        let proposedPlan = try XCTUnwrap(surface.latestProposedPlan,
                                         "the rendered plan card must be backed by a first-class proposed-plan artifact")
        XCTAssertTrue(proposedPlan.markdown.contains("RC_AGENT_APP_PLAN_SURFACE"))

        surface.showPlanSidebar = false
        await surface.implementLatestPlan()
        await waitAsync("real Codex proposed plan implementation completes", timeout: 240) {
            surface.status == .completed
        }

        let resumedThread = try XCTUnwrap(try threadRepo.get(id: threadId))
        XCTAssertEqual(resumedThread.providerThreadId, providerThreadId,
                       "implementing a rendered proposed-plan card must continue the same provider thread")
        let renderedText = surface.timeline.turns.flatMap(\.items).map(\.body).joined(separator: "\n")
        XCTAssertTrue(renderedText.contains("RC_AGENT_APP_PLAN_IMPLEMENTED") ||
                      (surface.messages.last?.content.contains("RC_AGENT_APP_PLAN_IMPLEMENTED") ?? false),
                      "the rendered proposed-plan card action must run through the real Codex app-server surface end-to-end")
        XCTAssertTrue(surface.timeline.proposedPlans.contains {
            $0.id == proposedPlan.id && $0.implementedAtMs != nil
        }, "acting on the proposed-plan card must mark the plan as implemented in the visible surface state")
        adapter.stopAll()
    }

    func test_realCodexAppServerTokenUsageSurfaceSurvivesReload() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server token telemetry E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-token-usage-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let workspaceID = WorkspaceID()

        let adapter = CodexAppServerAdapter()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            providerAdapters: [.codex: adapter]
        )
        let surface = AgentAppViewModel(workspaceID: workspaceID,
                                        cwd: tmp,
                                        coordinator: coordinator,
                                        threadRepo: threadRepo,
                                        messageRepo: messageRepo)
        surface.createThread(title: "real token usage")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        surface.permissionMode = .supervised
        surface.prompt = "Reply exactly RC_AGENT_APP_TOKEN_USAGE and nothing else."

        await surface.send()
        await waitAsync("real Codex token-usage turn completes", timeout: 240) {
            surface.status == .completed
        }
        let threadId = try XCTUnwrap(surface.selectedThreadId)
        await waitAsync("real Codex token usage reaches Agent App surface", timeout: 20) {
            surface.contextHealthMessage?.contains("Context ") == true &&
            surface.contextHealthMessage?.contains("tokens") == true
        }
        let liveContext = try XCTUnwrap(surface.contextHealthMessage)
        XCTAssertTrue(liveContext.contains("/"),
                      "real Codex app-server token usage must include used/context-window counts, not just a generic activity flag")
        XCTAssertTrue(liveContext.contains("auto-compacts"),
                      "real Codex app-server token usage must surface automatic compaction capability so long-run context pressure is not mistaken for a hard stop")
        adapter.stopAll()

        let reloadedCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            providerAdapters: [.codex: CodexAppServerAdapter()]
        )
        let reloadedSurface = AgentAppViewModel(workspaceID: workspaceID,
                                                cwd: tmp,
                                                coordinator: reloadedCoordinator,
                                                threadRepo: threadRepo,
                                                messageRepo: messageRepo)
        reloadedSurface.selectThread(threadId)

        XCTAssertEqual(reloadedSurface.contextHealthMessage, liveContext,
                       "reloading a real Codex app-server Agent App thread must replay persisted token usage so long-run context pressure stays visible")
    }

    func test_realCodexAppServerCheckpointRevertSurfaceRollsBackWorkspaceAndProviderAfterRestart() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server checkpoint/revert E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let repoDir = NSTemporaryDirectory() + "rc2-real-codex-checkpoint-repo-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: repoDir, withIntermediateDirectories: true)
        try "BASE\n".write(toFile: repoDir + "/tracked.txt", atomically: true, encoding: .utf8)
        try runGit(["init"], cwd: repoDir)
        try runGit(["config", "user.email", "remotecode@example.test"], cwd: repoDir)
        try runGit(["config", "user.name", "RemoteCode Test"], cwd: repoDir)
        try runGit(["add", "tracked.txt"], cwd: repoDir)
        try runGit(["commit", "-m", "base"], cwd: repoDir)

        let appSupport = NSTemporaryDirectory() + "rc2-real-codex-checkpoint-db-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let workspaceID = WorkspaceID()

        let adapter = CodexAppServerAdapter()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            checkpointRepo: checkpointRepo,
            providerAdapters: [.codex: adapter]
        )
        let surface = AgentAppViewModel(workspaceID: workspaceID,
                                        cwd: repoDir,
                                        coordinator: coordinator,
                                        threadRepo: threadRepo,
                                        messageRepo: messageRepo)
        surface.createThread(title: "real checkpoint")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        surface.permissionMode = .fullAccess

        surface.prompt = """
        Use shell to run:
        python3 - <<'PY'
        open('tracked.txt','w').write('RC_AGENT_APP_CHECKPOINT_ONE\\n')
        PY
        Then reply exactly RC_AGENT_APP_CHECKPOINT_ONE.
        """
        await surface.send()
        await waitAsync("first real checkpoint mutation completes", timeout: 240) {
            surface.status == .completed
        }
        let threadId = try XCTUnwrap(surface.selectedThreadId)
        await waitAsync("first checkpoint is captured", timeout: 20) {
            ((try? checkpointRepo.list(threadId: threadId)) ?? []).count >= 1
        }

        surface.prompt = """
        Use shell to run:
        python3 - <<'PY'
        open('tracked.txt','w').write('RC_AGENT_APP_CHECKPOINT_TWO\\n')
        open('new.txt','w').write('RC_AGENT_APP_CHECKPOINT_TWO\\n')
        PY
        Then reply exactly RC_AGENT_APP_CHECKPOINT_TWO.
        """
        await surface.send()
        await waitAsync("second real checkpoint mutation completes", timeout: 240) {
            surface.status == .completed
        }
        await waitAsync("second checkpoint is captured", timeout: 20) {
            ((try? checkpointRepo.list(threadId: threadId)) ?? []).count >= 2
        }
        XCTAssertEqual(try String(contentsOfFile: repoDir + "/tracked.txt"), "RC_AGENT_APP_CHECKPOINT_TWO\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoDir + "/new.txt"))
        adapter.stopAll()

        let restartedAdapter = CodexAppServerAdapter()
        let restartedCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            checkpointRepo: checkpointRepo,
            providerAdapters: [.codex: restartedAdapter]
        )
        _ = try await restartedCoordinator.revertThreadToCheckpoint(threadId: threadId, checkpointTurnCount: 1, cwd: repoDir)

        XCTAssertEqual(try String(contentsOfFile: repoDir + "/tracked.txt"), "RC_AGENT_APP_CHECKPOINT_ONE\n",
                       "checkpoint revert after app restart must restore the workspace to the selected real Codex turn")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoDir + "/new.txt"),
                       "checkpoint revert must remove files introduced after the selected real Codex turn")
        let readback = try await restartedCoordinator.readThread(threadId: threadId)
        let readbackText = readback.map { String(describing: $0) }.joined(separator: "\n")
        XCTAssertTrue(readbackText.contains("RC_AGENT_APP_CHECKPOINT_ONE"))
        XCTAssertFalse(readbackText.contains("RC_AGENT_APP_CHECKPOINT_TWO"),
                       "provider rollback after app restart must prune newer real Codex turns from provider history")
        restartedAdapter.stopAll()
    }

    func test_selectThreadRehydratesPersistedProposedPlansForMainTimeline() throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-rehydrate-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "plan", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")
        )
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   proposedPlanRepo: proposedPlanRepo)

        vm.selectThread(thread.id)

        XCTAssertEqual(vm.timeline.proposedPlans.map(\.id), ["plan-1"])
        XCTAssertEqual(vm.latestPlanText, "1. Inspect\n2. Patch",
                       "proposed plans must rehydrate into the Agent App main timeline after restart/reload")
    }

    func test_selectThreadRehydratesCheckpointsAndFileDiffPreview() throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-checkpoint-browser-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "checkpoint", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        let runId = AgentRunID()
        try runRepo.upsert(AgentRun(id: runId, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed))
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: runId,
            turnId: "turn-1",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:test:turn-1",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "Sources/App.swift", kind: "modified", additions: 2, deletions: 1)],
            diffPatch: "diff --git a/Sources/App.swift b/Sources/App.swift\n+visible checkpoint",
            fileDiffs: [AgentTurnCheckpointFileDiff(path: "Sources/App.swift", patch: "@@ file diff\n+visible file checkpoint")]
        ))
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   checkpointRepo: checkpointRepo)

        vm.selectThread(thread.id)

        XCTAssertEqual(vm.checkpoints.map(\.checkpointTurnCount), [1])
        XCTAssertTrue(vm.checkpointDiffPreview.contains("visible checkpoint"),
                      "selecting a thread must hydrate the checkpoint browser with a readable all-files diff")
        let checkpoint = try XCTUnwrap(vm.checkpoints.first)
        vm.selectCheckpoint(checkpoint, path: "Sources/App.swift")
        XCTAssertTrue(vm.checkpointDiffPreview.contains("visible file checkpoint"),
                      "the checkpoint browser must let users inspect the file-level diff before choosing rollback")
    }

    func test_implementLatestPlanStartsRunAndMarksPlanTraceability() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-implement-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "plan", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")
        )
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   proposedPlanRepo: proposedPlanRepo)
        vm.selectThread(thread.id)

        await vm.implementLatestPlan()

        let messages = try messageRepo.list(threadId: thread.id)
        XCTAssertTrue(messages.contains {
            $0.role == .user && $0.content.contains("Implement this proposed plan now") && $0.content.contains("1. Inspect")
        }, "implementing a plan must submit a concrete implementation prompt, not just toggle UI state")
        let storedPlan = try XCTUnwrap(proposedPlanRepo.list(threadId: thread.id).first { $0.plan.id == "plan-1" })
        XCTAssertEqual(storedPlan.implementationThreadId, thread.id,
                       "the source plan must keep a link to the thread that implements it")
        XCTAssertNotNil(storedPlan.plan.implementedAtMs,
                        "implemented plans must be marked so repeat actions are traceable")
        XCTAssertFalse(storedPlan.plan.showsImplementationActions,
                       "implemented plan cards must hide Implement and New thread instead of leaving disabled repeat actions visible")
        XCTAssertTrue(AssistantProposedPlan(id: "draft", turnId: "turn-1", markdown: "1. Inspect").showsImplementationActions,
                      "unimplemented plan cards must keep their implementation actions available")
    }

    func test_saveLatestProposedPlanWritesMarkdownFile() throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-save-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "plan", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        let markdown = "# Fix Agent Freeze\n\n1. Inspect\n2. Patch"
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-1", turnId: "turn-1", markdown: markdown)
        )
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])
        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   proposedPlanRepo: proposedPlanRepo)
        vm.selectThread(thread.id)

        let url = URL(fileURLWithPath: tmp).appendingPathComponent(vm.latestProposedPlan!.exportFileName)
        try vm.saveLatestProposedPlan(to: url)

        XCTAssertEqual(try String(contentsOf: url), markdown,
                       "saving a proposed plan must write the exact markdown artifact, not a truncated sidebar preview")
    }

    /// Regression: the VM defaulted to "gpt-5" — a dead id on codex
    /// 0.130.0, so a brand-new Codex thread's first run failed with no
    /// output. The default must be a model the CLI actually accepts.
    func test_defaultModel_isARealCodexModel() async throws {
        let (vm, _) = try makeVM()
        XCTAssertEqual(vm.model, "gpt-5.5", "fresh threads must start on a live codex model")
        await vm.loadModels()
        XCTAssertTrue(vm.availableModels.contains { $0.id == vm.model },
                      "the default model must be one the picker actually offers")
    }
}

private final class SlowStartRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        onEvent(.status(.running))
        try? await Task.sleep(nanoseconds: 100_000_000)
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            self?.lock.lock()
            self?._cancelled = true
            self?.lock.unlock()
        }
    }
}

private final class FailingCallbackRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        throw AgentProviderAdapterError.unsupported("dead approval callback")
    }

    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        throw AgentProviderAdapterError.unsupported("dead user-input callback")
    }
}

private final class HoldOpenStreamRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        Task.detached {
            let turnId = UUID().uuidString
            let itemId = UUID().uuidString
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, startedAtMs: now))))
            onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: "partial stream", outputAppend: nil, summary: nil)))
            try? await Task.sleep(nanoseconds: 500_000_000)
            onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "partial stream final")))
            onEvent(.status(.completed))
            onEvent(.finished(.completed, finalMessage: "partial stream final", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class LongRunStreamRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    let turns: Int
    let runtimeEvents: Int

    init(turns: Int, runtimeEvents: Int) {
        self.turns = turns
        self.runtimeEvents = runtimeEvents
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let turns = self.turns
        let runtimeEvents = self.runtimeEvents
        Task.detached {
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            for index in 0..<turns {
                let turnId = "long-turn-\(index)"
                let itemId = "long-item-\(index)"
                onEvent(.event(.turnStarted(turnId: turnId)))
                onEvent(.event(.itemStarted(item: AssistantItem(
                    id: itemId,
                    turnId: turnId,
                    type: .commandExecution,
                    summary: "stress command \(index)",
                    startedAtMs: startedAt + Int64(index)
                ))))
                onEvent(.event(.itemProgress(itemId: itemId, progress: Double(index + 1) / Double(max(turns, 1)))))
                onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: "ok \(index)\n", summary: nil)))
                onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
                onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "LONG_ASSISTANT_\(index)")))
            }
            for index in 0..<runtimeEvents {
                onEvent(.event(.providerRuntime(ProviderRuntimeEvent(
                    id: "runtime-\(index)",
                    provider: .codex,
                    source: "long-run-test",
                    method: "stress.event",
                    providerTurnId: "long-turn-\(min(index, max(turns - 1, 0)))",
                    payloadJSON: "{\"index\":\(index)}",
                    receivedAtMs: startedAt + Int64(index)
                ))))
            }
            onEvent(.event(.tokenUsage(AssistantTokenUsage(
                inputTokens: 300_000,
                outputTokens: 20_000,
                totalTokens: 320_000,
                contextWindow: 400_000
            ))))
            onEvent(.event(.contextCompaction(summary: "long-run history compacted")))
            onEvent(.status(.completed))
            onEvent(.finished(.completed, finalMessage: "LONG_ASSISTANT_\(max(turns - 1, 0))", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class ContextTelemetryRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        Task.detached {
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let turnId = "context-turn"
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.tokenUsage(AssistantTokenUsage(
                inputTokens: 400,
                outputTokens: 100,
                totalTokens: 500,
                contextWindow: 1_000,
                compactsAutomatically: true
            ))))
            onEvent(.event(.contextCompaction(summary: "older turns summarized")))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "context ready")))
            onEvent(.status(.completed))
            onEvent(.finished(.completed, finalMessage: "context ready", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class ImmediateStreamRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let turnId = UUID().uuidString
        let itemId = UUID().uuidString
        let providerThreadId = request.providerThreadId ?? UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        onEvent(.status(.running))
        onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
        onEvent(.event(.turnStarted(turnId: turnId)))
        onEvent(.event(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, startedAtMs: now))))
        onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: "partial stream", outputAppend: nil, summary: nil)))
        onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
        onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "partial stream final")))
        onEvent(.status(.completed))
        onEvent(.finished(.completed, finalMessage: "partial stream final", providerThreadId: providerThreadId))
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class CapturingProviderAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider
    let readEvents: [AssistantEvent]
    private let lock = NSLock()
    private var _lastRequestResponse: (threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse)?
    private var _lastUserInputResponse: (threadId: AgentThreadID, requestId: String, text: String)?

    var lastRequestResponse: (threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse)? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequestResponse
    }

    var lastUserInputResponse: (threadId: AgentThreadID, requestId: String, text: String)? {
        lock.lock(); defer { lock.unlock() }
        return _lastUserInputResponse
    }

    init(provider: AgentProvider, readEvents: [AssistantEvent] = []) {
        self.provider = provider
        self.readEvents = readEvents
    }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        lock.lock()
        _lastRequestResponse = (threadId, requestId, response)
        lock.unlock()
    }
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        lock.lock()
        _lastUserInputResponse = (threadId, requestId, text)
        lock.unlock()
    }
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { true }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { readEvents }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}

private final class CapturingProviderRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var _prompts: [String] = []
    private var _interactionModes: [AgentInteractionMode] = []
    private var _attachments: [[AgentAttachment]] = []
    private var _providerInstanceIds: [String?] = []
    private var _providerBinaries: [String?] = []
    private var _environments: [[String: String]] = []
    private var _requestProviderThreadIds: [String?] = []

    var prompts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _prompts
    }
    var interactionModes: [AgentInteractionMode] {
        lock.lock(); defer { lock.unlock() }
        return _interactionModes
    }
    var attachments: [[AgentAttachment]] {
        lock.lock(); defer { lock.unlock() }
        return _attachments
    }
    var providerInstanceIds: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _providerInstanceIds
    }
    var providerBinaries: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _providerBinaries
    }
    var environments: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return _environments
    }
    var requestProviderThreadIds: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _requestProviderThreadIds
    }
    init(provider: AgentProvider) {
        self.provider = provider
    }

    func listModels() async -> [AgentModelDescriptor] {
        [AgentModelDescriptor(id: "capture-model", label: "Capture Model", provider: provider)]
    }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock()
        _prompts.append(request.prompt)
        _interactionModes.append(request.interactionMode)
        _attachments.append(request.attachments)
        _providerInstanceIds.append(request.providerInstanceId)
        _providerBinaries.append(request.providerBinary)
        _environments.append(request.environment)
        _requestProviderThreadIds.append(request.providerThreadId)
        lock.unlock()
        Task.detached {
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            onEvent(.status(.completed))
            onEvent(.finished(.completed, finalMessage: nil, providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}
