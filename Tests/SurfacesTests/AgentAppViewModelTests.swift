import XCTest
import AppKit
import MachO
import Combine
import SwiftUI
@testable import Surfaces
import CoreModel
@testable import Persistence
@testable import AgentRuntime

/// Behavioural coverage for thread rename/delete in the agent app view
/// model. Proves the sidebar contract: rename trims + persists, deleting
/// the selected thread never strands the UI on a dead selection.
@MainActor
final class AgentAppViewModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // AgentLastModelStore.shared persists to the test runner's
        // UserDefaults, so model choices remembered by EARLIER test runs leak
        // into preferredModelForCurrentProvider and make these tests
        // machine-dependent. Key literal mirrors AgentLastModelStore.key.
        UserDefaults.standard.removeObject(forKey: "agent.lastModel.byProvider.v1")
    }

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
                                   draftRepo: AgentThreadDraftRepository(db: db),
                                   attachmentStore: AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments")),
                                   promptHistoryStore: PromptHistoryStore(db: db))
        installRunnableProviderFixtures(on: vm)
        wireCanonicalThreadRead(vm, repo: threadRepo)
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
                                   draftRepo: AgentThreadDraftRepository(db: db),
                                   attachmentStore: AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments")),
                                   promptHistoryStore: PromptHistoryStore(db: db))
        installRunnableProviderFixtures(on: vm)
        wireCanonicalThreadRead(vm, repo: threadRepo)
        return (vm, threadRepo)
    }

    private func installRunnableProviderFixtures(on vm: AgentAppViewModel) {
        vm.providerSnapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true
            ),
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true
            )
        ]
    }

    private func wireCanonicalThreadRead(_ vm: AgentAppViewModel, repo: AgentThreadRepository) {
        vm.markThreadRead = { id in
            guard var thread = try repo.get(id: id) else {
                throw NSError(domain: "AgentAppViewModelTests", code: 404)
            }
            guard thread.hasUnread else { return }
            thread.hasUnread = false
            try repo.upsert(thread)
        }
    }

    private func crashSafeForkSnapshot() -> AgentProviderSnapshot {
        AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5", label: "GPT-5", provider: .codex)],
            // Runnable on any machine: send()'s fail-closed provider gate probes
            // the real binary path, so a fixture path that only exists on some
            // dev machines silently blocks the sends this test asserts on.
            binaryPath: "/usr/bin/true",
            authenticated: true,
            capabilitiesOverride: AgentProviderCapabilities(
                supportsAttachments: true,
                supportedAttachmentKinds: [.file, .image],
                supportedAttachmentMediaTypes: ["*/*"],
                supportsApprovals: true,
                supportsUserInput: true,
                supportsStreaming: true,
                supportsFork: true,
                supportsRollback: true,
                supportsPlanReview: true
            )
        )
    }

    func test_cancelPendingUserInputResolvesOnlyQuestionAndKeepsProviderSession() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "cancel question")
        let request = AssistantUserInputRequest(
            id: "ask-cancel",
            turnId: "turn-1",
            prompt: "Choose a target",
            options: ["macOS", "iOS"],
            createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.cancelPendingUserInput(request)
        await waitAsync("question cancellation reaches adapter") {
            adapter.cancelledUserInputs.contains { $0.requestId == request.id }
        }

        XCTAssertEqual(adapter.cancelledUserInputs.first?.threadId, vm.selectedThreadId,
                       "cancel must target the question's owning thread")
        XCTAssertEqual(adapter.stopSessionCount, 0,
                       "cancelling AskUserQuestion must not stop or discard the provider session")
        XCTAssertTrue(vm.openPendingUserInputs.isEmpty,
                      "a cancelled question must leave no actionable callback card")
    }

    func test_errorRecoveryClassifierMapsProviderFailuresToSafeActions() {
        XCTAssertEqual(AgentAppViewModel.errorRecoveryAction(
            provider: .codex,
            message: "[auth-required] 401 Unauthorized",
            recoverable: false
        ), .signIn, "expired Codex auth must expose Sign in instead of a dead generic error")
        XCTAssertEqual(AgentAppViewModel.errorRecoveryAction(
            provider: .grok,
            message: "Grok ACP RPC error: rate limit exceeded",
            recoverable: false
        ), .retry, "Grok rate limits must expose Retry")
        XCTAssertEqual(AgentAppViewModel.errorRecoveryAction(
            provider: .grok,
            message: "Grok ACP network connection timed out",
            recoverable: false
        ), .retry, "Grok network failures must expose Retry")
        XCTAssertEqual(AgentAppViewModel.errorRecoveryAction(
            provider: .grok,
            message: "Grok ACP session/load failed: session not found",
            recoverable: false
        ), .startFresh, "an invalid resume cursor must not retry the same broken session")
        XCTAssertNil(AgentAppViewModel.errorRecoveryAction(
            provider: .codex,
            message: "invalid request payload",
            recoverable: false
        ), "fatal non-recovery errors must not offer a misleading action")
    }

    func test_terminalCodexAuthFailureSurfacesSignInAction() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "expired auth")
        let threadId = try XCTUnwrap(vm.selectedThreadId)
        let runId = AgentRunID()

        vm.runCoordinator(
            vm.coordinator,
            didFinish: runId,
            threadId: threadId,
            status: .failed,
            finalMessage: "[auth-required] Unauthorized",
            providerThreadId: "codex-thread"
        )
        await waitAsync("terminal auth failure reaches timeline") {
            vm.timeline.error != nil
        }

        XCTAssertEqual(vm.displayedErrorRecoveryAction, .signIn,
                       "a terminal Codex auth marker must render an actionable Sign in CTA")
        XCTAssertEqual(vm.status, .failed)
    }

    func test_providerSnapshotSignInUsesHostActionAndOffersHonestRetry() async throws {
        let (vm, _) = try makeVM()
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)],
            binaryPath: "/usr/bin/true",
            authenticated: false
        )
        vm.provider = .claude
        vm.providerInstanceId = snapshot.id
        vm.providerSnapshots = [snapshot]
        var openedProvider: AgentProvider?
        vm.providerSignInAction = { openedProvider = $0 }

        XCTAssertEqual(vm.providerRecoveryActionTitle, "Sign in",
                       "an unauthenticated provider card must expose the real Sign in flow, not a clipboard action")

        await vm.performProviderRecoveryAction()

        XCTAssertEqual(openedProvider, .claude)
        XCTAssertEqual(vm.providerRecoveryActionTitle, "Retry",
                       "after Terminal opens, the next action must re-check authentication instead of claiming success")
        XCTAssertEqual(
            vm.providerRecoveryStatusMessage,
            "Opened Claude sign-in in Terminal. Complete sign-in there, then choose Retry."
        )
    }

    func test_nonAuthenticationErrorNeverLaunchesProviderSignIn() async throws {
        let (vm, _) = try makeVM()
        vm.timeline.apply(.error(message: "invalid request payload", recoverable: false))
        var launchCount = 0
        vm.providerSignInAction = { _ in launchCount += 1 }

        XCTAssertNil(vm.displayedErrorRecoveryAction)
        await vm.performDisplayedErrorRecoveryAction()

        XCTAssertEqual(launchCount, 0,
                       "non-authentication errors must never execute an authentication command")
    }

    func test_authErrorRetryWaitsForAuthenticatedSnapshotBeforeResending() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "auth retry")
        vm.prompt = "resume only after auth"
        await vm.send()
        await waitAsync("initial request completes") {
            runner.prompts == ["resume only after auth"] && vm.status == .completed
        }

        func authSnapshot(_ authenticated: Bool) -> AgentProviderSnapshot {
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: authenticated
            )
        }
        let unauthenticated = authSnapshot(false)
        vm.providerSnapshots = [unauthenticated]
        vm.providerInstanceId = unauthenticated.id
        vm.timeline.apply(.error(message: "[auth-required] token expired", recoverable: false))
        vm.providerSignInAction = { _ in }
        var authenticationConfirmed = false
        vm.providerAuthenticationRefresher = { _ in
            [authSnapshot(authenticationConfirmed)]
        }

        XCTAssertEqual(vm.displayedErrorRecoveryAction, .signIn)
        await vm.performDisplayedErrorRecoveryAction()
        XCTAssertEqual(vm.displayedErrorRecoveryAction, .retry)

        await vm.performDisplayedErrorRecoveryAction()
        XCTAssertEqual(runner.prompts, ["resume only after auth"],
                       "Retry must not reach the provider while the fresh snapshot remains unauthenticated")
        XCTAssertEqual(
            vm.providerRecoveryStatusMessage,
            "Sign-in is not confirmed yet. Complete it in Terminal, then choose Retry."
        )

        authenticationConfirmed = true
        await vm.performDisplayedErrorRecoveryAction()
        await waitAsync("authenticated retry reaches provider") {
            runner.prompts.filter { $0 == "resume only after auth" }.count == 2
        }
        XCTAssertNil(vm.timeline.error)
        XCTAssertEqual(vm.providerRecoveryStatusMessage, "Authentication confirmed. Retrying the request.")
    }

    func test_disabledUnavailableAndUnauthenticatedSnapshotsBlockRunStart() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "provider gate")
        let model = AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)
        let snapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex, models: [model], binaryPath: "/usr/bin/true", enabled: false
            ),
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex, models: [model], binaryPath: "/usr/bin/true", authenticated: false
            ),
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex, models: [model], binaryPath: ""
            )
        ]

        for snapshot in snapshots {
            vm.providerSnapshots = [snapshot]
            vm.providerInstanceId = snapshot.id
            vm.prompt = "must not send"
            await vm.send()
            XCTAssertFalse(vm.selectedProviderCanRun,
                           "snapshot state \(snapshot.status.rawValue) must disable provider-backed controls")
            XCTAssertNotNil(vm.providerExecutionUnavailableReason)
        }
        XCTAssertTrue(adapter.sentTurns.isEmpty,
                      "no disabled, unavailable, or unauthenticated provider snapshot may start a turn")
    }

    func test_attachmentCapabilityRejectsUnsupportedControlBeforeStaging() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "attachment capability")
        vm.providerSnapshots = [AgentProviderSnapshot(
            id: "codex-no-attachments",
            provider: .codex,
            driverKind: .codexCLI,
            displayName: "Codex Read-only",
            accentColor: "#2F80ED",
            continuationGroup: "codex",
            interactionModes: [.default],
            permissionModes: [.supervised],
            enabled: true,
            installed: true,
            status: .available,
            authenticated: true,
            models: [AgentModelDescriptor(id: "m", label: "M", provider: .codex)],
            slashCommands: [],
            capabilities: .conservative
        )]
        vm.providerInstanceId = "codex-no-attachments"

        vm.addAttachments(["/tmp/never-stage-this.txt"])

        XCTAssertTrue(vm.attachments.isEmpty)
        XCTAssertTrue(vm.statusMessage.contains("does not support attachments"),
                      "attachment controls must obey the selected instance capability before filesystem work")
    }

    func test_isAwaitingBackgroundWork_flagsCompletedStallButNotNormalCompletion() throws {
        // UX-MAC_AGENT-BG-AWAIT: a run that ends while the agent is still waiting on
        // a background job it launched must read "awaiting", not a green "completed".
        let (vm, _) = try makeVM()
        vm.status = .completed

        vm.timeline.apply(.turnStarted(turnId: "t1"))
        vm.timeline.apply(.turnCompleted(turnId: "t1", finalMessage: "Standing by for the demo recording to complete."))
        XCTAssertTrue(vm.isAwaitingBackgroundWork,
                      "a completed run whose final message is a background-await stall must surface as awaiting, so the user knows the task is not actually finished")

        vm.timeline.apply(.turnStarted(turnId: "t2"))
        vm.timeline.apply(.turnCompleted(turnId: "t2", finalMessage: "All four steps are done; the build is green and the PR is open."))
        XCTAssertFalse(vm.isAwaitingBackgroundWork,
                       "a completed run with a real final answer must not be flagged as awaiting")

        // A running thread is never 'awaiting a background task', even mid-narration.
        vm.timeline.apply(.turnStarted(turnId: "t3"))
        vm.timeline.apply(.turnCompleted(turnId: "t3", finalMessage: "Standing by for the demo recording to complete."))
        vm.status = .running
        XCTAssertFalse(vm.isAwaitingBackgroundWork,
                       "a running thread must not surface the awaiting badge")
    }

    func test_isAwaitingBackgroundWork_flagsClaudeFutureTenseDeployPollerStall() throws {
        // The reported Claude-provider stall: the agent ends its turn saying it will
        // wait for a deploy poller that "notifies me". This completed run must read
        // "awaiting" (warning) with the Continue banner, not a green "completed", so
        // the user can tell the task is not actually finished.
        let (vm, _) = try makeVM()
        vm.status = .completed

        vm.timeline.apply(.turnStarted(turnId: "t1"))
        vm.timeline.apply(.turnCompleted(turnId: "t1", finalMessage: "I'll wait for the deploy poller to complete (it notifies me), then run the summer-gate Chrome verification across multiple accounts."))
        XCTAssertTrue(vm.isAwaitingBackgroundWork,
                      "a completed Claude run waiting on a background deploy poller must surface as awaiting")
    }

    func test_isAwaitingBackgroundWork_marker_surfacesForAnyPhrasing() throws {
        // The deterministic path: when the agent self-declares the stall with the
        // marker, the badge must surface even for phrasing the heuristic misses.
        let (vm, _) = try makeVM()
        vm.status = .completed
        let novel = "Holding here until the canary bake finishes and the gate flips."
        vm.timeline.apply(.turnStarted(turnId: "t1"))
        vm.timeline.apply(.turnCompleted(turnId: "t1", finalMessage: novel))
        XCTAssertFalse(vm.isAwaitingBackgroundWork,
                       "control: novel phrasing without the marker is beyond the heuristic")
        vm.timeline.apply(.turnStarted(turnId: "t2"))
        vm.timeline.apply(.turnCompleted(turnId: "t2", finalMessage: "\(BackgroundAwaitContinuation.awaitingMarker)\n\(novel)"))
        XCTAssertTrue(vm.isAwaitingBackgroundWork,
                      "a marker-declared stall must surface as awaiting regardless of phrasing")
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

    func test_providerChangeIsIgnoredAfterConversationStarts() throws {
        let (vm, repo) = try makeVM()
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
        vm.setProviderInstance("codex-cli")
        // Pin the model the UI way (setModel remembers it for the provider) so
        // createThread's preferred-model re-resolution lands on it.
        vm.setModel("gpt-5.5")
        vm.createThread(title: "locked source")
        let id = try XCTUnwrap(vm.selectedThreadId)
        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "first turn"))

        vm.setProvider(.claude)
        vm.setProviderInstance("claude-cli")

        XCTAssertEqual(vm.provider, .codex,
                       "after the first user message, source changes must be ignored so a resumed run cannot switch provider mid-thread")
        XCTAssertEqual(vm.providerInstanceId, "codex-cli",
                       "provider instance must stay aligned with the locked source")
        XCTAssertEqual(vm.model, "gpt-5.5",
                       "blocking a source change must not clear the selected model")
        let persisted = try XCTUnwrap(repo.get(id: id))
        XCTAssertEqual(persisted.provider, .codex,
                       "a blocked source change must not persist into the thread configuration")
        XCTAssertEqual(persisted.providerInstanceId, "codex-cli")
        XCTAssertEqual(persisted.model, "gpt-5.5")
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
        // F35: progress is signalled by modelListLoading only — reusing the
        // error-styled status message rendered a red duplicate "Loading
        // models..." with a Retry row while the fetch was still in flight.
        await waitAsync("model list loading state becomes visible without an error-styled status") {
            vm.modelListLoading == true && vm.modelListStatusMessage == nil
        }
        await load.value

        XCTAssertEqual(vm.modelListStatusMessage, "No models returned for Codex. Retry from the model menu.",
                       "an empty model list must leave visible retry guidance instead of a silent Default-only picker")
        XCTAssertFalse(vm.modelListLoading)
    }

    func test_modelSnapshotFailureFailsLoud() async throws {
        let (vm, _) = try makeVM()
        vm.providerSnapshots = []
        struct SnapshotFailure: Error {}
        vm.providerSnapshotLoader = { throw SnapshotFailure() }

        await vm.loadProviderSnapshots()

        XCTAssertEqual(vm.providerSnapshotStatusMessage, "Provider snapshot failed. Retry from the model menu.",
                       "provider/model snapshot fetch failures must be visible so the user can distinguish stale local models from a loaded provider list")
        // Fail open for composer usability: seed a local fallback so send is not
        // stuck on missingSnapshot after a transient probe failure.
        XCTAssertFalse(vm.providerSnapshots.isEmpty,
                       "snapshot load failure must still seed local provider rows so Full access/Grok is not permanently blocked")
        XCTAssertNotNil(vm.providerSnapshots.first(where: { $0.provider == .grok }),
                        "fallback seed must include Grok, not only Codex/Claude")
    }

    /// WHY: new threads must reopen the last model the user used for that
    /// provider; Codex without history defaults to gpt-5.6-sol.
    func test_createThread_usesLastModelThenCodexBuiltInDefault() throws {
        let (vm, repo) = try makeVM()
        let suiteName = "rc2-last-model-" + UUID().uuidString
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = AgentLastModelStore(defaults: suite)
        vm.lastModelStore = store

        XCTAssertEqual(vm.preferredModelForCurrentProvider(), "gpt-5.6-sol",
                       "Codex with no last-used model defaults to gpt-5.6-sol")

        // Fixture snapshots expose gpt-5.5; remember only accepts known/custom ids.
        vm.setModel("gpt-5.5")
        XCTAssertEqual(store.model(for: .codex), "gpt-5.5")

        // Simulate browsing an older thread whose model differs from last-used.
        vm.model = "gpt-5.2"
        vm.createThread(title: "from last used")
        let id = try XCTUnwrap(vm.selectedThreadId)
        let thread = try XCTUnwrap(try repo.get(id: id))
        XCTAssertEqual(thread.model, "gpt-5.5",
                       "createThread must not inherit a stale selected-thread model")
        XCTAssertEqual(vm.model, "gpt-5.5")
    }

    /// WHY: council SC-ux-1 — auto-rebind must reset model like setProvider,
    /// not keep gpt-5.6-sol (Codex) after switching to Claude.
    func test_autoRebind_appliesPreferredModelForNewProvider() async throws {
        let (vm, _) = try makeVM()
        let suiteName = "rc2-rebind-model-" + UUID().uuidString
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        vm.lastModelStore = AgentLastModelStore(defaults: suite)
        vm.sourceSelectionUserPinned = false
        vm.provider = .codex
        vm.providerInstanceId = "codex"
        vm.model = "gpt-5.6-sol"
        let missingCodex = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "",
            id: "codex-cli"
        )
        let claude = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [
                AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude),
                AgentModelDescriptor(id: "sonnet", label: "Sonnet", provider: .claude)
            ],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "claude-cli"
        )
        vm.providerSnapshotLoader = { [missingCodex, claude] }
        await vm.loadProviderSnapshots()
        XCTAssertEqual(vm.provider, .claude)
        XCTAssertEqual(vm.model, "opus",
                       "auto-rebind must apply preferred Claude model, not keep Codex gpt-5.6-sol")
        XCTAssertNotEqual(vm.model, "gpt-5.6-sol")
    }

    /// WHY: explicit Source pick of an unrunnable provider must stay sticky so
    /// recovery UI is not thrashed by snapshot refresh.
    func test_userPinnedUnrunnableSource_notReboundOnSnapshotRefresh() async throws {
        let (vm, _) = try makeVM()
        let missingCodex = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "",
            id: "codex-cli"
        )
        let claude = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "claude-cli"
        )
        vm.providerSnapshotLoader = { [missingCodex, claude] }
        await vm.loadProviderSnapshots()
        XCTAssertEqual(vm.provider, .claude)
        vm.setProviderInstance("codex-cli")
        XCTAssertTrue(vm.sourceSelectionUserPinned)
        XCTAssertEqual(vm.provider, .codex)
        await vm.loadProviderSnapshots()
        XCTAssertEqual(vm.provider, .codex,
                       "pinned unrunnable Codex must survive snapshot refresh for recovery")
    }

    /// WHY: Airton had Claude + Grok installed, Codex path missing. Empty Agent
    /// App defaulted to Codex and blocked send — no provider is mandatory.
    func test_missingCodexDoesNotBlockClaudeOrGrokOnEmptyAgentApp() async throws {
        let (vm, _) = try makeVM()
        // Fresh empty surface defaults to Codex before discovery.
        vm.provider = .codex
        vm.providerInstanceId = "codex"
        vm.model = "gpt-5.5"
        let missingCodex = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "",
            id: "codex-cli"
        )
        let claude = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
            binaryPath: "/Users/airtonempath/.local/bin/claude",
            authenticated: true,
            id: "claude-cli"
        )
        let grok = AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok)],
            binaryPath: "/Users/airtonjunior/.grok/bin/grok",
            authenticated: true,
            id: "grok-cli"
        )
        vm.providerSnapshotLoader = { [missingCodex, claude, grok] }

        await vm.loadProviderSnapshots()

        XCTAssertNotEqual(vm.provider, .codex,
                          "missing Codex CLI must not remain selected when Claude/Grok can run")
        XCTAssertEqual(vm.provider, .claude,
                       "rebind to first runnable provider in allCases order (Claude before Grok)")
        XCTAssertEqual(vm.providerInstanceId, "claude-cli")
        XCTAssertTrue(vm.selectedProviderCanRun,
                      "composer send/controls must enable on a runnable non-Codex provider")
        XCTAssertEqual(vm.model, "opus",
                       "model list must follow the rebound provider")
    }

    /// WHY: nil snapshot used to look runnable (canRun true), so send hit
    /// preflight and only then showed "Provider capabilities are not loaded yet."
    func test_nilProviderSnapshotFailsClosedBeforeSend() async throws {
        let adapter = CapturingProviderAdapter(provider: .grok)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.provider = .grok
        vm.providerInstanceId = "grok"
        vm.providerSnapshots = []
        vm.providerSnapshotLoader = { [] }
        vm.prompt = "should not send without capabilities"

        XCTAssertEqual(
            AgentAppViewModel.providerExecutionUnavailableReason(for: nil),
            AgentProviderRunPreflightError.missingSnapshot.description,
            "nil snapshot must fail closed with the same user-facing capabilities message as preflight"
        )
        XCTAssertFalse(vm.selectedProviderCanRun)

        await vm.send()

        // send reloads snapshots; empty loader still leaves canRun false if no row.
        XCTAssertTrue(adapter.sentTurns.isEmpty,
                      "send must not start a provider turn while capabilities are unloaded")
        XCTAssertEqual(vm.statusMessage, AgentProviderRunPreflightError.missingSnapshot.description)
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
        vm.providerSnapshots = []
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
        let capture = CapturingProviderRunner(provider: .codex, completionDelayNanoseconds: 20_000_000)
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
        installRunnableProviderFixtures(on: firstVM)

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
        // Per-surface binding: restore reopens the surface's bound thread. The
        // host restore path (reinstantiateRestoredSurfaces) reads the persisted
        // `selected_thread` metadata and passes it as initialThreadId; we mirror
        // that here instead of relying on the removed auto-select-first behavior.
        let restartedVM = AgentAppViewModel(workspaceID: workspaceID,
                                            cwd: tmp,
                                            coordinator: secondCoordinator,
                                            threadRepo: threadRepo,
                                            messageRepo: messageRepo,
                                            promptHistoryStore: history,
                                            initialThreadId: threadId)
        installRunnableProviderFixtures(on: restartedVM)

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

        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "grok-cli",
                provider: .grok,
                driverKind: .grokCLI,
                displayName: "Grok",
                accentColor: "#1DA1F2",
                continuationGroup: "xai-grok",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                models: [],
                slashCommands: ["/status"],
                skills: ["sam-work", "sam-codex-advisor", "sam-fix-bug"]
            )
        ]
        vm.provider = .grok
        vm.providerInstanceId = "grok-cli"
        vm.prompt = "$sam-work"
        XCTAssertEqual(vm.composerSuggestions.map(\.insertText), ["$sam-work "],
                       "Grok skills must autocomplete from the provider snapshot with $ prefix")
        XCTAssertEqual(vm.composerSuggestions.first?.subtitle, "Grok skill",
                       "skill subtitle must use the active provider display name, not a hard-coded Codex label")
        vm.prompt = "$sam-codex"
        XCTAssertEqual(vm.composerSuggestions.map(\.insertText), ["$sam-codex-advisor "],
                       "partial $ skill queries must rank prefix matches for every provider")

        // Shared catalog: either trigger surfaces skills and modes with the typed prefix.
        vm.prompt = "/sam-work"
        XCTAssertEqual(vm.composerSuggestions.map(\.insertText), ["/sam-work "],
                       "/sam-work must autocomplete skills under the slash trigger")
        XCTAssertEqual(vm.composerSuggestions.first?.kind, .skill)
        vm.prompt = "$stat"
        XCTAssertEqual(vm.composerSuggestions.map(\.insertText), ["$status "],
                       "$status must autocomplete modes under the dollar trigger")
        XCTAssertEqual(vm.composerSuggestions.first?.kind, .slashCommand)
    }

    // WHY: real Codex/Grok skill dirs often have 50–80 skills. Ranking them with
    // modes under a shared limit of 8 buried /goal and /plan under ads-* on bare `/`.
    func test_composerPrioritizesCommandsOverSkillsUnderCatalogFlood() throws {
        let flood = (0..<40).map { "ads-skill-\($0)" }
        let suggestions = AgentComposerSuggestions.suggestions(
            for: "/",
            snapshot: AgentProviderSnapshot(
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
                skills: flood
            ),
            localSlashCommands: AgentAppViewModel.localSlashCommands,
            limit: 8
        )
        let titles = suggestions.map(\.title)
        XCTAssertTrue(titles.contains("/goal"),
                      "/goal must remain discoverable on bare / even when dozens of skills exist")
        XCTAssertTrue(titles.contains("/plan"),
                      "/plan must remain discoverable on bare / even when dozens of skills exist")
        XCTAssertTrue(suggestions.filter { $0.kind == .slashCommand }.count >= 6,
                      "the first page of bare-/ suggestions must be dominated by commands, not skills")
        // Commands are never truncated and always rank ahead; skills then get
        // their OWN bounded budget (they must stay discoverable, not banned —
        // the old page-exclusion hid every project/user skill on bare `/`).
        let lastCommandIndex = suggestions.lastIndex { $0.kind == .slashCommand }
        let firstSkillIndex = suggestions.firstIndex { $0.kind == .skill }
        if let lastCommandIndex, let firstSkillIndex {
            XCTAssertLessThan(lastCommandIndex, firstSkillIndex,
                              "every command must rank ahead of the first ads-* skill")
        }
        XCTAssertLessThanOrEqual(suggestions.filter { $0.kind == .skill }.count, 8,
                                 "flooding skills stay within their own page budget")
    }

    func test_normalizingComposerTriggerPrefix_commandsAndSkillsWithEitherTrigger() {
        let local = AgentAppViewModel.localSlashCommands
        let provider = ["/goal", "/review"]
        let skills = ["sam-work", "sam-codex-advisor"]

        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "$goal continue until done",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "/goal continue until done",
            "$goal must become /goal so providers receive a command token"
        )
        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "/goal continue until done",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "/goal continue until done",
            "/goal must stay a slash command"
        )
        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "$sam-work implement the fix",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "$sam-work implement the fix",
            "$skill must stay the canonical skill trigger"
        )
        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "/sam-work implement the fix",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "$sam-work implement the fix",
            "/skill must normalize to $skill so skills work with either trigger"
        )
        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "/sam-codex-advisor review this",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "$sam-codex-advisor review this",
            "any known skill under / must rewrite to $"
        )
        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "/plan ship it",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "/plan ship it",
            "commands win over skills on name collision — plan stays a mode"
        )
        XCTAssertEqual(
            AgentComposerSuggestions.normalizingComposerTriggerPrefix(
                "/unknown-thing keep me",
                localSlashCommands: local,
                providerSlashCommands: provider,
                skills: skills
            ),
            "/unknown-thing keep me",
            "unknown first tokens must not be rewritten"
        )
    }

    // WHY: users autocomplete skills under / or $; send must forward the canonical $ form.
    func test_slashSkillSendNormalizesToDollarSkillForProvider() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .grok)
        vm.coordinator.replaceProvider(.grok, runner: runner)
        vm.provider = .grok
        vm.providerSnapshots = [
            AgentProviderSnapshot(
                id: "grok-cli",
                provider: .grok,
                driverKind: .grokCLI,
                displayName: "Grok",
                accentColor: "#1DA1F2",
                continuationGroup: "xai-grok",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok)],
                slashCommands: ["/status", "/goal"],
                skills: ["sam-work", "sam-codex-advisor"]
            )
        ]
        vm.providerInstanceId = "grok-cli"
        vm.createThread(title: "slash-skill")
        vm.prompt = "/sam-work implement the fix"

        await vm.send()

        await waitAsync("slash skill normalizes to dollar skill") {
            runner.prompts.contains("$sam-work implement the fix")
        }
        XCTAssertFalse(runner.prompts.contains(where: { $0.hasPrefix("/sam-work") }),
                       "/sam-work must not be forwarded literally — skills use $")
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

    func test_providerCallbacksExposePendingAndStaleRowsForActionAndDiagnosis() throws {
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

        XCTAssertEqual(vm.openPendingRequests, [],
                       "resolved and stale callbacks must never remain actionable")
        XCTAssertEqual(vm.visiblePendingRequests.map(\.id), ["approval-2"],
                       "stale provider callbacks must remain visible as read-only diagnostics after the turn can no longer answer them")
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
                       "stale approvals must remain non-actionable after restart/reload")
        XCTAssertEqual(vm.openPendingUserInputs, [],
                       "stale provider questions must remain non-actionable after restart/reload")
        XCTAssertEqual(vm.visiblePendingRequests.map(\.id), ["approval-1"],
                       "stale approvals must reappear as read-only diagnostics after restart/reload")
        XCTAssertEqual(vm.visiblePendingUserInputs.map(\.id), ["question-1"],
                       "stale provider questions must reappear as read-only diagnostics after restart/reload")
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

    func test_callbackDraftsAndSelectionsAreIsolatedByThreadAndRequestId() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "A")
        let threadA = try XCTUnwrap(vm.selectedThreadId)
        let requestA = AssistantUserInputRequest(
            id: "shared-request",
            turnId: "turn-a",
            prompt: "Pick A",
            options: ["A", "B"],
            createdAtMs: 1
        )
        vm.toggleUserInputOption("A", for: requestA)
        vm.userInputDrafts[vm.userInputStateKey(requestA)] = "draft-a"

        vm.createThread(title: "B")
        let requestB = AssistantUserInputRequest(
            id: "shared-request",
            turnId: "turn-b",
            prompt: "Pick B",
            options: ["A", "B"],
            createdAtMs: 2
        )

        XCTAssertEqual(vm.selectedUserInputAnswer(for: requestB), "",
                       "thread B must not inherit thread A's selection when provider request ids collide")
        XCTAssertNil(vm.userInputDrafts[vm.userInputStateKey(requestB)],
                     "thread B must not inherit thread A's freeform draft when request ids collide")

        vm.selectThread(threadA)
        XCTAssertEqual(vm.selectedUserInputAnswer(for: requestA), "A",
                       "returning to thread A must restore A's selection under the composite key")
        XCTAssertEqual(vm.userInputDrafts[vm.userInputStateKey(requestA)], "draft-a")
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

    // Screenshot bug: with a single-select option already chosen, the user could not
    // move the selection to "Other" because the option radio stayed marked and the
    // bare "Other…" field had no radio to claim the selection. The Other field must
    // be a real member of the radio group: clicking its radio selects Other and
    // deselects any chosen option; an empty Other selection is not yet a submittable
    // answer; typing then satisfies it; and picking an option again clears Other.
    func test_askUserQuestionOtherRadioSelectsOtherAndIsExclusiveWithOptions() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "ask other radio")
        let question = AssistantUserInputQuestion(
            prompt: "Which database?",
            header: "DB",
            options: [AssistantUserInputOption(label: "Postgres"), AssistantUserInputOption(label: "MySQL")],
            allowsMultipleSelection: false
        )
        let request = AssistantUserInputRequest(
            id: "ask-other-radio", turnId: "turn-other-radio", prompt: "Which database?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        XCTAssertFalse(vm.askUserQuestionOtherIsSelected(question: question, request: request),
                       "Other must start unselected so its radio renders empty on first display")

        // A listed option is chosen first — this is the state the user was stuck in.
        vm.selectAskUserQuestionOption("Postgres", question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionOptionIsSelected("Postgres", question: question, request: request))

        // Clicking the Other radio moves the single selection to Other.
        vm.selectAskUserQuestionOther(question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionOtherIsSelected(question: question, request: request),
                      "clicking the Other radio must mark Other as the selected choice")
        XCTAssertFalse(vm.askUserQuestionOptionIsSelected("Postgres", question: question, request: request),
                       "selecting Other must deselect the previously chosen option (single-select group)")
        XCTAssertFalse(vm.askUserQuestionIsComplete(request),
                       "Other selected with no text is not yet a submittable answer")

        // Typing then satisfies the question with the freeform text.
        vm.setAskUserQuestionOther("SQLite", question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionOtherIsSelected(question: question, request: request))
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "SQLite")
        XCTAssertTrue(vm.askUserQuestionIsComplete(request))

        // Picking a listed option again must take selection back from Other.
        vm.selectAskUserQuestionOption("MySQL", question: question, request: request)
        XCTAssertFalse(vm.askUserQuestionOtherIsSelected(question: question, request: request),
                       "choosing a listed option must clear the Other selection and its draft")
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "MySQL")
    }

    func test_askUserQuestionOtherRadioToggleOffLeavesQuestionUnanswered() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "ask other toggle")
        let question = AssistantUserInputQuestion(
            prompt: "Which database?",
            header: "DB",
            options: [AssistantUserInputOption(label: "Postgres")],
            allowsMultipleSelection: false
        )
        let request = AssistantUserInputRequest(
            id: "ask-other-toggle", turnId: "turn-other-toggle", prompt: "Which database?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.selectAskUserQuestionOther(question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionOtherIsSelected(question: question, request: request))
        // Clicking the active Other radio again clears it, matching how listed options
        // toggle off — leaving nothing selected and the question unanswered.
        vm.selectAskUserQuestionOther(question: question, request: request)
        XCTAssertFalse(vm.askUserQuestionOtherIsSelected(question: question, request: request))
        XCTAssertNil(vm.askUserQuestionAnswer(for: question, in: request))
        XCTAssertFalse(vm.askUserQuestionIsComplete(request))
    }

    // The option radio and the Other radio must never both read as selected. Typing
    // directly into the field (without first tapping the Other radio) — including a
    // whitespace-only first keystroke that trims to empty — must still claim the
    // exclusive selection and drop the previously chosen option, so the UI cannot show
    // two filled radios while the answer silently stays the option.
    func test_askUserQuestionTypingOtherClearsOptionEvenForWhitespace() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "ask other whitespace")
        let question = AssistantUserInputQuestion(
            prompt: "Which database?",
            header: "DB",
            options: [AssistantUserInputOption(label: "Postgres"), AssistantUserInputOption(label: "MySQL")],
            allowsMultipleSelection: false
        )
        let request = AssistantUserInputRequest(
            id: "ask-other-ws", turnId: "turn-other-ws", prompt: "Which database?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.selectAskUserQuestionOption("Postgres", question: question, request: request)
        // A whitespace-only first keystroke into the Other field.
        vm.setAskUserQuestionOther(" ", question: question, request: request)
        XCTAssertFalse(vm.askUserQuestionOptionIsSelected("Postgres", question: question, request: request),
                       "editing the Other field must drop the chosen option so two radios are never both filled")
        XCTAssertTrue(vm.askUserQuestionOtherIsSelected(question: question, request: request),
                      "the Other radio must read as selected once its field is being edited")
        XCTAssertNil(vm.askUserQuestionAnswer(for: question, in: request),
                     "whitespace-only Other text trims empty, so the question is not yet answered")
        XCTAssertFalse(vm.askUserQuestionIsComplete(request))
    }

    // Multi-select: Other is exclusive by design (selecting Other replaces checked
    // options, and checking an option clears Other), so the Other control renders as a
    // radio rather than a checkbox. This pins the intended exclusivity so a later glyph
    // or model change cannot silently start dropping the user's combined choices without
    // a failing test.
    func test_askUserQuestionMultiSelectOtherIsExclusiveByDesign() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "ask multi other")
        let question = AssistantUserInputQuestion(
            prompt: "Which targets?",
            header: "Targets",
            options: [AssistantUserInputOption(label: "macOS"), AssistantUserInputOption(label: "iPadOS")],
            allowsMultipleSelection: true
        )
        let request = AssistantUserInputRequest(
            id: "ask-multi-other", turnId: "turn-multi-other", prompt: "Which targets?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))

        vm.selectAskUserQuestionOption("macOS", question: question, request: request)
        vm.selectAskUserQuestionOption("iPadOS", question: question, request: request)
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "iPadOS, macOS")

        // Selecting Other replaces the checked options (exclusive).
        vm.selectAskUserQuestionOther(question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionOtherIsSelected(question: question, request: request))
        XCTAssertFalse(vm.askUserQuestionOptionIsSelected("macOS", question: question, request: request))
        XCTAssertFalse(vm.askUserQuestionOptionIsSelected("iPadOS", question: question, request: request))
        vm.setAskUserQuestionOther("Linux", question: question, request: request)
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "Linux",
                       "in multi-select, an Other answer replaces the checked options by design")

        // Checking an option again clears Other.
        vm.selectAskUserQuestionOption("macOS", question: question, request: request)
        XCTAssertFalse(vm.askUserQuestionOtherIsSelected(question: question, request: request))
        XCTAssertEqual(vm.askUserQuestionAnswer(for: question, in: request), "macOS")
    }

    // End-to-end: an Other answer must reach the provider as the question's answer, and
    // submit must clear the draft so a re-displayed card never starts pre-filled.
    func test_submitAskUserQuestionDeliversOtherDraftAndClearsItAfterward() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "ask other submit")
        let question = AssistantUserInputQuestion(
            prompt: "Which database?",
            header: "DB",
            options: [AssistantUserInputOption(label: "Postgres"), AssistantUserInputOption(label: "MySQL")],
            allowsMultipleSelection: false
        )
        let request = AssistantUserInputRequest(
            id: "ask-other-submit", turnId: "turn-1", prompt: "Which database?",
            questions: [question], createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))
        let key = vm.askUserQuestionKey(request, question)

        // Empty Other (radio picked, no text) must NOT satisfy Submit.
        vm.selectAskUserQuestionOther(question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionOtherIsSelected(question: question, request: request))
        XCTAssertFalse(vm.askUserQuestionIsComplete(request),
                       "an empty Other selection must keep Submit disabled")

        // Typing through the Other path unblocks Submit.
        vm.setAskUserQuestionOther("SQLite", question: question, request: request)
        XCTAssertTrue(vm.askUserQuestionIsComplete(request))

        vm.submitAskUserQuestion(request)
        await waitAsync("Other answer reaches adapter") {
            adapter.lastUserInputResponse?.requestId == "ask-other-submit"
        }
        let text = try XCTUnwrap(adapter.lastUserInputResponse?.text)
        let answers = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(answers["Which database?"], "SQLite",
                       "Other freeform text must be delivered to the provider as the question's answer")
        XCTAssertNil(vm.userInputDrafts[key],
                     "submit must clear the Other draft so a re-shown card does not start pre-filled")
        XCTAssertFalse(vm.askUserQuestionOtherIsSelected(question: question, request: request))
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

        let stateKey = vm.userInputStateKey(request)
        vm.userInputDrafts[stateKey] = "release/next"
        vm.answerPendingUserInput(request, answer: vm.userInputDrafts[stateKey] ?? "")
        await waitAsync("free-text provider response reaches adapter") {
            adapter.lastUserInputResponse?.requestId == "question-1"
        }

        XCTAssertEqual(adapter.lastUserInputResponse?.requestId, "question-1")
        XCTAssertEqual(adapter.lastUserInputResponse?.text, "release/next",
                       "free-text provider questions must have an editable draft path so the user can unblock the waiting provider request")
        XCTAssertNil(vm.userInputDrafts[stateKey],
                     "resolved provider questions must clear their local draft so stale text is not reused for a later request")
        XCTAssertTrue(request.isSecret,
                      "secret free-text questions use the same draft/submit path but must be distinguishable for masked rendering")
    }

    func test_answeringProviderQuestionClearsStaleVisibleError() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "free text input retry")
        let request = AssistantUserInputRequest(
            id: "question-2",
            turnId: "turn-1",
            prompt: "Which branch should I inspect?",
            options: [],
            createdAtMs: 1
        )
        vm.timeline.apply(.userInputRequested(request))
        vm.timeline.apply(.error(message: "Provider user-input response failed: stale", recoverable: true))

        vm.answerPendingUserInput(request, answer: "main")

        XCTAssertNil(vm.timeline.error,
                     "submitting a new provider-answer message must immediately clear the stale error banner so the UI reflects the new attempt")
        await waitAsync("free-text provider response reaches adapter") {
            adapter.lastUserInputResponse?.requestId == "question-2"
        }
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

    func test_dynamicApproveForSessionKeepsThreadPermissionModeUnchanged() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, repo) = try makeVM(adapter: adapter)
        vm.createThread(title: "dynamic approval")
        let threadId = try XCTUnwrap(vm.selectedThreadId)
        let request = AssistantPendingRequest(
            id: "dynamic-permissions-1",
            turnId: "turn-1",
            kind: .dynamic,
            title: "Provider approval",
            detail: "Requested profile: network only",
            createdAtMs: 1
        )
        vm.timeline.apply(.requestOpened(request))

        vm.respondToPendingRequest(request, response: .approveForSession)
        await waitAsync("dynamic session response reaches adapter") {
            adapter.lastRequestResponse?.requestId == request.id
        }

        XCTAssertEqual(adapter.lastRequestResponse?.response, .approveForSession,
                       "the provider must receive its native session-scoped decision")
        XCTAssertEqual(vm.permissionMode, .supervised,
                       "a narrow dynamic permission profile must not widen the visible thread mode")
        XCTAssertEqual(try repo.get(id: threadId)?.permissionMode, .supervised,
                       "dynamic session scope must stay provider-native and leave durable thread authority unchanged")
    }

    func test_approveForSessionAfterThreadSwitchPromotesOnlyOriginThread() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex, responseDelayNanoseconds: 100_000_000)
        let (vm, repo) = try makeVM(adapter: adapter)
        vm.createThread(title: "A")
        let threadA = try XCTUnwrap(vm.selectedThreadId)
        vm.createThread(title: "B")
        let threadB = try XCTUnwrap(vm.selectedThreadId)
        vm.selectThread(threadA)
        let request = AssistantPendingRequest(
            id: "approval-shared",
            turnId: "turn-a",
            kind: .commandExecution,
            title: "Run A",
            createdAtMs: 1
        )
        vm.timeline.apply(.requestOpened(request))

        vm.respondToPendingRequest(request, response: .approveForSession)
        vm.selectThread(threadB)
        try await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(adapter.lastRequestResponse?.threadId, threadA,
                       "the provider decision must remain bound to the thread that owned the approval card")
        XCTAssertEqual(try repo.get(id: threadA)?.permissionMode, .fullAccess,
                       "Approve Session must promote the origin thread even if selection changes during await")
        XCTAssertEqual(try repo.get(id: threadB)?.permissionMode, .supervised,
                       "the newly selected thread must never inherit another thread's approval escalation")
        XCTAssertEqual(vm.permissionMode, .supervised,
                       "visible config must remain that of the newly selected thread")
        XCTAssertTrue(vm.timeline.pendingRequests.isEmpty,
                      "completion for thread A must not resolve or inject a callback into thread B's timeline")
    }

    func test_approveForSessionConfirmationAfterThreadSwitchRoutesToOriginThread() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, repo) = try makeVM(adapter: adapter)
        vm.createThread(title: "A")
        let threadA = try XCTUnwrap(vm.selectedThreadId)
        vm.createThread(title: "B")
        let threadB = try XCTUnwrap(vm.selectedThreadId)
        vm.selectThread(threadA)
        let request = AssistantPendingRequest(
            id: "approval-confirmation-a",
            turnId: "turn-a",
            kind: .commandExecution,
            title: "Run A",
            createdAtMs: 1
        )
        vm.timeline.apply(.requestOpened(request))

        // The confirmation dialog captures A when it opens. Selection may move
        // before the destructive confirmation callback runs.
        vm.selectThread(threadB)
        vm.respondToPendingRequest(
            request,
            response: .approveForSession,
            originThreadId: threadA
        )
        await waitAsync("session approval confirmation reaches origin thread") {
            adapter.lastRequestResponse?.threadId == threadA
        }

        XCTAssertEqual(adapter.lastRequestResponse?.threadId, threadA,
                       "confirming after a thread switch must route through the dialog's captured origin")
        XCTAssertEqual(try repo.get(id: threadA)?.permissionMode, .fullAccess,
                       "the approval escalation belongs to the thread that opened the dialog")
        XCTAssertEqual(try repo.get(id: threadB)?.permissionMode, .supervised,
                       "the currently selected thread must remain unchanged")
        XCTAssertEqual(vm.selectedThreadId, threadB,
                       "confirming an origin-bound approval must not force a selection change")
    }

    func test_staleCallbacksRehydratedAfterRelaunchAreNeverActionable() async throws {
        let adapter = CapturingProviderAdapter(provider: .codex)
        let (vm, _) = try makeVM(adapter: adapter)
        vm.createThread(title: "relaunch")
        let approval = AssistantPendingRequest(
            id: "stale-approval",
            turnId: "turn-old",
            kind: .commandExecution,
            title: "Old command",
            state: .stale,
            createdAtMs: 1
        )
        let question = AssistantUserInputRequest(
            id: "stale-question",
            turnId: "turn-old",
            prompt: "Old question",
            options: [],
            state: .stale,
            createdAtMs: 2
        )
        vm.timeline.apply(.requestOpened(approval))
        vm.timeline.apply(.userInputRequested(question))

        vm.respondToPendingRequest(approval, response: .approve)
        vm.answerPendingUserInput(question, answer: "should not send")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(adapter.lastRequestResponse,
                     "stale relaunch approvals are read-only diagnostics and must never reach the provider")
        XCTAssertNil(adapter.lastUserInputResponse,
                     "stale relaunch questions are read-only diagnostics and must never resume a dead continuation")
        XCTAssertEqual(vm.visiblePendingRequests.first?.state, .stale)
        XCTAssertEqual(vm.visiblePendingUserInputs.first?.state, .stale)
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

        // Per-surface binding: the host restore path passes the persisted
        // `selected_thread` as initialThreadId; mirror that here.
        let vm = AgentAppViewModel(workspaceID: workspaceID,
                                   cwd: tmp,
                                   coordinator: coordinator,
                                   threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db),
                                   initialThreadId: thread.id)

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

    func test_permissionChangeDuringRunDoesNotMisrepresentActiveAuthority() async throws {
        let runner = SlowStartRunner()
        let (vm, repo) = try makeVM(provider: runner)
        vm.createThread(title: "active authority")
        let id = try XCTUnwrap(vm.selectedThreadId)
        vm.setPermissionMode(.fullAccess)
        vm.prompt = "hold active authority"
        await vm.send()

        vm.setPermissionMode(.supervised)

        XCTAssertEqual(vm.permissionMode, .fullAccess,
                       "the visible permission chip must keep the authority captured by the active run")
        XCTAssertEqual(try repo.get(id: id)?.permissionMode, .fullAccess,
                       "a blocked mid-run gesture must not persist next-turn authority as if it were active")
        XCTAssertTrue(vm.activeRunConfigurationLocked)
        vm.stop()
    }

    func test_createThreadCopiesCurrentConfigFromLastThread() throws {
        let (vm, repo) = try makeVM()
        vm.provider = .codex
        vm.availableModels = [
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)
        ]
        // createThread re-resolves the model from the last one the USER chose
        // for the provider (setModel → rememberCurrentModel), not from whatever
        // an older selected thread left on the VM — so choose it the UI way.
        vm.setModel("gpt-5.5")
        vm.permissionMode = .fullAccess
        vm.reasoningEffort = .medium
        vm.createThread(title: "next")

        let id = try XCTUnwrap(vm.selectedThreadId)
        let t = try repo.get(id: id)
        XCTAssertEqual(t?.model, "gpt-5.5", "new threads must inherit the last model the user chose for the provider")
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

    func test_persistentThreadMutationsRollbackVisualStateAndDoNotPublishSuccessWhenSQLiteRejectsWrite() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "durable")
        let id = try XCTUnwrap(vm.selectedThreadId)
        let original = try XCTUnwrap(try repo.get(id: id))
        var lifecycleEvents: [AgentThreadLifecycleEvent] = []
        var configEvents: [AgentThread] = []
        vm.onThreadLifecycle = { lifecycleEvents.append($0) }
        vm.onThreadConfigPersisted = { configEvents.append($0) }
        try repo.db.execute("""
            CREATE TRIGGER reject_agent_thread_update
            BEFORE UPDATE ON agent_threads
            BEGIN SELECT RAISE(ABORT, 'simulated disk full'); END;
        """)

        vm.model = "model-that-must-rollback"
        XCTAssertFalse(vm.persistThreadConfig())
        XCTAssertEqual(vm.model, original.model,
                       "a failed config write must roll the picker back to the durable model")
        XCTAssertEqual(try repo.get(id: id)?.model, original.model)
        XCTAssertTrue(configEvents.isEmpty,
                      "failed persistence must not publish a config-success event to mirrors")

        vm.renameThread(id, to: "phantom rename")
        XCTAssertEqual(try repo.get(id: id)?.title, original.title)
        vm.setThreadColor(id, "purple")
        XCTAssertEqual(try repo.get(id: id)?.color, original.color)
        vm.setThreadPinned(id, true)
        XCTAssertEqual(try repo.get(id: id)?.pinned, original.pinned)
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "rename/color/pin failures must not announce phantom success")
        XCTAssertTrue(vm.statusMessage.contains("Could not"),
                      "every rejected persistent mutation must fail loud in the Agent App")
    }

    func test_createThreadDoesNotAppearOrPublishWhenSQLiteRejectsInsert() throws {
        let (vm, repo) = try makeVM()
        var lifecycleEvents: [AgentThreadLifecycleEvent] = []
        vm.onThreadLifecycle = { lifecycleEvents.append($0) }
        try repo.db.execute("""
            CREATE TRIGGER reject_agent_thread_insert
            BEFORE INSERT ON agent_threads
            BEGIN SELECT RAISE(ABORT, 'simulated read only database'); END;
        """)

        vm.createThread(title: "phantom")

        XCTAssertTrue(try repo.list(workspaceId: vm.workspaceID).isEmpty)
        XCTAssertTrue(vm.threads.isEmpty)
        XCTAssertNil(vm.selectedThreadId)
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "a rejected INSERT must never publish a created event")
        XCTAssertTrue(vm.statusMessage.contains("Could not create thread"))
    }

    func test_grokFallbackSnapshotDrivesBuiltInDefaultsWarning() async throws {
        let (vm, _) = try makeVM()
        let fallbackModels = GrokRunner.listModels(installedVersion: nil)
        let fallback = AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: fallbackModels,
            binaryPath: "/definitely/missing/grok",
            modelDiscoverySource: .builtInFallback,
            modelDiscoveryCacheKey: "opaque-test-key"
        )
        vm.providerSnapshotLoader = { [fallback] in [fallback] }
        vm.providerLaunchConfig = { _, _ in ("/definitely/missing/grok", [:]) }

        await vm.loadProviderSnapshots()
        vm.setProvider(.grok)
        await vm.loadModels()

        XCTAssertEqual(vm.modelOptionsForSelectedProvider.map(\.id), fallbackModels.map(\.id))
        XCTAssertTrue(vm.displayedModelListIsFallback,
                      "Grok discovery failure must drive the visible 'Using built-in defaults' warning")
    }

    func test_renameThread_blankIsNoOp() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "keep")
        let id = vm.selectedThreadId!
        vm.renameThread(id, to: "   ")
        XCTAssertEqual(vm.threads.first(where: { $0.id == id })?.title, "keep",
                       "a blank rename must not wipe an existing title")
    }

    func test_deleteSelectedThread_reselectsRemaining() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "a")
        let a = vm.selectedThreadId!
        vm.createThread(title: "b")
        let b = vm.selectedThreadId!
        XCTAssertNotEqual(a, b)
        vm.selectThread(a)
        await vm.deleteThread(a)
        XCTAssertFalse(vm.threads.contains { $0.id == a }, "deleted thread must be gone")
        XCTAssertEqual(vm.selectedThreadId, b,
                       "deleting the selected thread must fall back to a remaining one")
    }

    func test_deleteLastThread_clearsSelectionAndMessages() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "only")
        let id = vm.selectedThreadId!
        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "hi"))
        await vm.deleteThread(id)
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
        // send() and the didFinish fan-out each schedule an off-main history
        // reload; poll until the durable user row lands in the published array.
        await waitAsync("user message lands in reloaded history", timeout: 2) {
            vm.messages.contains { $0.role == .user && $0.content == "Refactor the auth module please" }
        }
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
        installRunnableProviderFixtures(on: vm)
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
        installRunnableProviderFixtures(on: vm)
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

    func test_send_runningThreadHandlesLocalSlashCommandInsteadOfQueueing() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-running-slash-" + UUID().uuidString
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
        installRunnableProviderFixtures(on: vm)
        vm.createThread(title: "busy slash")
        let id = try XCTUnwrap(vm.selectedThreadId)
        vm.prompt = "start slow run"

        Task { await vm.send() }
        await waitAsync("selected thread becomes a real active run") {
            vm.status == .running && vm.currentRunId != nil
        }
        vm.interactionMode = .plan
        vm.prompt = "/default"

        await vm.send()

        XCTAssertEqual(vm.interactionMode, .default,
                       "local slash commands must update composer run mode even while a provider run is active")
        XCTAssertEqual((try? queuedRepo.list(threadId: id).map(\.text)) ?? [], [],
                       "local slash commands must not be queued as follow-up provider prompts")
        XCTAssertEqual(vm.prompt, "", "handled local slash commands must clear the composer")
        vm.stop()
        await waitAsync("slow run can still be stopped after local slash command") {
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

    func test_completedLegacyGrokConcatenatedFinalKeepsLastAnswerVisible() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-grok-legacy",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-grok-legacy", type: .assistantMessage, state: .completed, body: "I'll inspect first.", startedAtMs: 1_000, finishedAtMs: 2_000),
                AssistantItem(id: "msg-2", turnId: "turn-grok-legacy", type: .assistantMessage, state: .completed, body: "Done.", startedAtMs: 2_000, finishedAtMs: 3_000)
            ],
            finalAssistantMessage: "I'll inspect first.Done.",
            finished: true
        )
        let renderable = AgentAppView.renderableItems(in: turn)

        XCTAssertEqual(
            AgentAppView.completedVisibleAssistantItems(in: turn, renderableItems: renderable).map(\.id),
            ["msg-2"],
            "legacy Grok concatenated finals must keep the last answer outside the Worked disclosure"
        )
        XCTAssertEqual(
            AgentAppView.completedWorkItems(in: turn, renderableItems: renderable).map(\.id),
            ["msg-1"],
            "legacy Grok preambles must remain in the Worked disclosure"
        )
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

    /// WHY: user messages must never be character-truncated in the bubble; long
    /// paths and full prompts stay intact (layout wraps / Show more by lines only).
    func test_userMessageDisplayTextPreservesFullPromptWithoutCharacterCap() {
        let longPrompt = String(repeating: "a", count: 2_500)
        let pathPrompt = "/Users/samuelfajreldines/Desktop/Screenshot 2026-07-18 at 5.23.56 PM.png"
        XCTAssertEqual(AgentAppView.userMessageDisplayText(longPrompt), longPrompt,
                       "user bubbles must show the full stored prompt, not a character-capped preview")
        XCTAssertEqual(AgentAppView.userMessageDisplayText(pathPrompt), pathPrompt,
                       "file-path prompts must keep the full path visible without ellipsis in the model text")
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

    /// Streaming Thought must show the *latest* tokens (terminal UX), not a frozen
    /// head of the chain-of-thought that freezes while later reasoning keeps growing.
    func test_streamingReasoningLiveCapKeepsTailNotHead() {
        let head = String(repeating: "A", count: 80)
        let tail = "LATEST-THOUGHT-TOKEN"
        let pad = String(repeating: "b", count: AgentAppView.liveTurnBodyCharacterLimit)
        let body = head + pad + tail
        let item = AssistantItem(id: "r1", turnId: "t1", type: .reasoning, state: .streaming,
                                 body: body, startedAtMs: 1)
        let visible = AgentAppView.visibleLiveTurnItems([item], running: true)
        XCTAssertEqual(visible.count, 1)
        XCTAssertTrue(visible[0].body.contains(tail),
                      "live Thinking… must show the newest reasoning tokens like the Grok TUI")
        XCTAssertFalse(visible[0].body.hasPrefix(head),
                       "capping the head freezes early thoughts while later ones rewrite 'on top' of the answer")
        let completed = AssistantItem(id: "r2", turnId: "t1", type: .reasoning, state: .completed,
                                      body: body, startedAtMs: 1)
        let completedVisible = AgentAppView.visibleLiveTurnItems([completed], running: true)
        XCTAssertTrue(completedVisible[0].body.hasPrefix(head),
                      "completed Thought rows keep the conventional head cap for stable collapsed previews")
        XCTAssertFalse(completedVisible[0].body.contains(tail),
                       "completed head-cap must not keep the tail window used only while streaming")
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

    func test_finishCallbackReflectsCoordinatorOwnedUnreadUntilOpened() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "done")
        let id = try XCTUnwrap(vm.selectedThreadId)
        var completed = try XCTUnwrap(repo.get(id: id))
        completed.status = .completed
        completed.hasUnread = true
        try repo.upsert(completed)
        let callbackFinished = expectation(description: "finish callback applied")
        vm.onRunCompleted = { callbackFinished.fulfill() }
        vm.runCoordinator(vm.coordinator, didFinish: AgentRunID(), threadId: id, status: .completed,
                          finalMessage: "done", providerThreadId: nil)
        await fulfillment(of: [callbackFinished], timeout: 2)

        // The rail reload is coalesced (scheduleReloadThreads, ~50ms) so many
        // open Agent Apps don't stampede on one finish fan-out — poll for it.
        await waitAsync("rail reflects coordinator-owned unread", timeout: 2) {
            vm.threads.first { $0.id == id }?.hasUnread == true
        }
        XCTAssertTrue(vm.threads.first { $0.id == id }?.hasUnread ?? false,
                      "the callback must reflect coordinator-owned unread state in the rail")

        vm.selectThread(id)
        XCTAssertEqual(try repo.get(id: id)?.hasUnread, false,
                       "clicking/opening the completed thread must clear the indicator")
    }

    func test_delayedFinishCallbackNeverResurrectsCoordinatorUnreadAfterRead() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "done")
        let id = try XCTUnwrap(vm.selectedThreadId)
        var completed = try XCTUnwrap(repo.get(id: id))
        completed.status = .completed
        completed.hasUnread = true
        try repo.upsert(completed)
        vm.reloadThreads()
        vm.selectThread(id)
        XCTAssertFalse(try XCTUnwrap(repo.get(id: id)).hasUnread,
            "the canonical read must clear coordinator-owned completion attention")
        let callbackFinished = expectation(description: "delayed finish callback applied")
        vm.onRunCompleted = { callbackFinished.fulfill() }

        vm.runCoordinator(
            vm.coordinator,
            didFinish: AgentRunID(),
            threadId: id,
            status: .completed,
            finalMessage: "done",
            providerThreadId: nil
        )
        await fulfillment(of: [callbackFinished], timeout: 2)

        XCTAssertFalse(try XCTUnwrap(repo.get(id: id)).hasUnread,
            "a delayed view callback must never overwrite a newer canonical read")
        vm.reloadThreads()
        XCTAssertFalse(vm.threads.first(where: { $0.id == id })?.hasUnread ?? true,
            "the local rail must keep the newer read state")
    }

    func test_runningStatusCallbackReflectsCoordinatorClearedUnreadIndicator() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "rerun")
        let id = try XCTUnwrap(vm.selectedThreadId)
        var completed = try XCTUnwrap(repo.get(id: id))
        completed.status = .completed
        completed.hasUnread = true
        try repo.upsert(completed)
        vm.runCoordinator(vm.coordinator, didFinish: AgentRunID(), threadId: id, status: .completed,
                          finalMessage: "done", providerThreadId: nil)
        await waitAsync("completion callback reflects coordinator unread") {
            vm.threads.first(where: { $0.id == id })?.hasUnread == true
        }
        var running = try XCTUnwrap(repo.get(id: id))
        running.status = .running
        running.hasUnread = false
        try repo.upsert(running)

        vm.runCoordinator(vm.coordinator, didChangeStatus: .running, runId: AgentRunID(), threadId: id)

        await waitAsync("running callback reflects coordinator read state") {
            vm.threads.first(where: { $0.id == id })?.hasUnread == false
        }
        XCTAssertFalse(vm.threads.first { $0.id == id }?.hasUnread ?? true,
                       "the rail must reflect the coordinator's running-state unread reset")
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

    func test_pendingStatusTracksRunIdBeforeStartRunReturnsSoStopWorks() async throws {
        let (vm, repo) = try makeVM()
        let runner = PendingStartRunner()
        vm.coordinator.replaceProvider(.codex, runner: runner)
        vm.createThread(title: "slow")
        vm.prompt = "start slow run"

        let sendTask = Task { await vm.send() }
        await waitAsync("provider start is blocked after pending state persists") {
            runner.enteredStart
        }

        XCTAssertEqual(vm.status, .pending,
                       "a provider start that has not returned must remain visibly stoppable")
        XCTAssertTrue(vm.selectedThreadRunIsStartingOrRunning,
                      "the pending start must render the same Stop affordance as a running turn")
        XCTAssertNotNil(vm.currentRunId,
                        "Stop needs the stable run id before the provider handle exists")
        XCTAssertEqual(try repo.get(id: vm.selectedThreadId!)?.status, .pending,
                       "the pending state must survive a surface or process restart")

        vm.stop()
        runner.releaseStart()

        await waitAsync("pending stop cancels after handle registration") {
            runner.cancelled
        }
        await sendTask.value
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
        installRunnableProviderFixtures(on: firstSurface)
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

    // WHY: autocomplete insert keeps the typed `$` trigger; every provider expects /goal.
    func test_dollarGoalSendNormalizesToSlashGoalForProvider() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .codex)
        vm.coordinator.replaceProvider(.codex, runner: runner)
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
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                slashCommands: ["/goal", "/review"],
                skills: ["sam-work"]
            )
        ]
        vm.providerInstanceId = "codex-cli"
        vm.createThread(title: "dollar-goal")
        vm.prompt = "$goal continue until the audit is implemented"

        await vm.send()

        await waitAsync("dollar-goal normalizes to slash-goal for the provider") {
            runner.prompts.contains("/goal continue until the audit is implemented")
        }
        XCTAssertFalse(runner.prompts.contains(where: { $0.hasPrefix("$goal") }),
                       "$goal must not be forwarded literally — providers expect /goal as the command")
    }

    // WHY: Grok/Claude snapshots previously omitted /goal; $goal must still normalize
    // and autocomplete must still surface /goal via the universal pass-through list.
    func test_goalWorksOnGrokAndClaudeEvenWhenSnapshotOmitsGoal() async throws {
        for provider in [AgentProvider.grok, .claude] {
            let (vm, _) = try makeVM()
            let runner = CapturingProviderRunner(provider: provider)
            vm.coordinator.replaceProvider(provider, runner: runner)
            vm.provider = provider
            let instanceId = "\(provider.rawValue)-cli"
            vm.providerSnapshots = [
                AgentProviderSnapshot(
                    id: instanceId,
                    provider: provider,
                    driverKind: provider == .grok ? .grokCLI : .claudeCLI,
                    displayName: provider.rawValue.capitalized,
                    accentColor: "#000000",
                    continuationGroup: provider.rawValue,
                    interactionModes: [.default],
                    enabled: true,
                    installed: true,
                    status: .available,
                    models: [AgentModelDescriptor(
                        id: "m",
                        label: "M",
                        provider: provider
                    )],
                    // Deliberately omit /goal — pass-through must still supply it.
                    slashCommands: ["/status"],
                    skills: ["sam-work"]
                )
            ]
            vm.providerInstanceId = instanceId

            vm.prompt = "/go"
            XCTAssertTrue(vm.composerSuggestions.map(\.insertText).contains("/goal "),
                          "\(provider.rawValue) must autocomplete /goal even when the snapshot omits it")

            vm.prompt = "$go"
            XCTAssertTrue(vm.composerSuggestions.map(\.insertText).contains("$goal "),
                          "\(provider.rawValue) must autocomplete $goal even when the snapshot omits it")

            vm.createThread(title: "goal-\(provider.rawValue)")
            vm.prompt = "$goal ship the fix"
            await vm.send()
            await waitAsync("\(provider.rawValue) $goal normalizes to /goal") {
                runner.prompts.contains("/goal ship the fix")
            }
        }
    }

    func test_sendingNewPromptClearsStaleVisibleError() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "retry prompt")
        vm.timeline.apply(.error(message: "Previous provider failure", recoverable: true))
        vm.prompt = "try again"

        await vm.send()

        XCTAssertNil(vm.timeline.error,
                     "sending a new prompt must clear the stale error banner immediately so the next attempt is not shown under an old failure")
        await waitAsync("new prompt reaches runner") {
            runner.prompts.contains("try again")
        }
    }

    func test_queueingNewPromptWhileRunningClearsStaleVisibleError() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "queue retry")
        vm.status = .running
        vm.timeline.apply(.error(message: "Previous provider failure", recoverable: true))
        vm.prompt = "queue this"

        await vm.send()

        XCTAssertNil(vm.timeline.error,
                     "queueing a new prompt is still a new user message and must clear the stale visible error before the queued turn runs")
    }

    func test_retryLastPromptClearsStaleVisibleError() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "retry button")
        vm.prompt = "first attempt"
        await vm.send()
        await waitAsync("first attempt reaches runner") {
            runner.prompts.contains("first attempt")
        }
        vm.timeline.apply(.error(message: "Previous provider failure", recoverable: true))

        await vm.retryLastPrompt()

        XCTAssertNil(vm.timeline.error,
                     "retrying the last prompt sends a new user message and must clear the stale error banner before the retried run starts")
        await waitAsync("retry reaches runner") {
            runner.prompts.filter { $0 == "first attempt" }.count >= 2
        }
    }

    func test_retryResendsValidatedManagedAttachments() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "retry attachment")
        let source = URL(fileURLWithPath: vm.cwd).appendingPathComponent("retry.txt")
        try Data("retry attachment bytes".utf8).write(to: source)
        vm.prompt = "inspect attachment"
        vm.addAttachments([source.path])
        await vm.send()
        await waitAsync("first attachment turn reaches runner") { runner.attachments.count == 1 }
        vm.timeline.apply(.error(message: "retryable provider failure", recoverable: true))

        await vm.retryLastPrompt()
        await waitAsync("retried attachment turn reaches runner") { runner.attachments.count == 2 }

        XCTAssertEqual(runner.attachments[1].map(\.sha256), runner.attachments[0].map(\.sha256),
                       "Retry must resend the exact content-addressed managed blob from the failed request")
        XCTAssertNil(vm.pendingAttachmentRetryConfirmation)
    }

    func test_retryWithMissingManagedAttachmentRequiresConfirmation() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "retry missing attachment")
        let source = URL(fileURLWithPath: vm.cwd).appendingPathComponent("missing-after-send.txt")
        try Data("temporary".utf8).write(to: source)
        vm.prompt = "inspect missing attachment"
        vm.addAttachments([source.path])
        await vm.send()
        await waitAsync("first missing-attachment turn reaches runner") { runner.attachments.count == 1 }
        let managedPath = try XCTUnwrap(runner.attachments.first?.first?.path)
        try FileManager.default.removeItem(atPath: managedPath)
        vm.timeline.apply(.error(message: "retryable provider failure", recoverable: true))

        await vm.retryLastPrompt()

        XCTAssertEqual(runner.prompts.filter { $0 == "inspect missing attachment" }.count, 1,
                       "Retry must pause before dropping an unavailable attachment")
        XCTAssertEqual(vm.pendingAttachmentRetryConfirmation?.unavailableAttachmentNames,
                       ["missing-after-send.txt"])
        XCTAssertNotNil(vm.timeline.error,
                        "the original error remains visible until the user confirms the lossy retry")

        await vm.confirmRetryWithoutUnavailableAttachments()
        await waitAsync("confirmed lossy retry reaches runner") {
            runner.prompts.filter { $0 == "inspect missing attachment" }.count == 2
        }
        XCTAssertEqual(runner.attachments.last, [])
        XCTAssertNil(vm.pendingAttachmentRetryConfirmation)
        XCTAssertTrue(vm.messages.contains { $0.role == .system && $0.content.contains("missing-after-send.txt") },
                      "the confirmed omission must remain explicit in the transcript")
    }

    func test_retryUsesFailedRunPromptWhenNewerPromptIsQueued() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-retry-envelope-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let queueRepo = AgentQueuedMessageRepository(db: db)
        let runner = SlowStartRunner()
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
                                              providers: [.codex: runner])
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp, coordinator: coordinator,
                                   threadRepo: threadRepo, messageRepo: messageRepo,
                                   queuedMessageRepo: queueRepo, promptHistoryStore: PromptHistoryStore(db: db))
        installRunnableProviderFixtures(on: vm)
        vm.createThread(title: "retry identity")
        vm.prompt = "failed request A"
        await vm.send()
        vm.prompt = "queued request B"
        await vm.send()
        vm.stop()
        vm.status = .failed

        await vm.retryLastPrompt()

        XCTAssertEqual(runner.prompts.last, "failed request A",
                       "Retry must replay the provider request that failed, not the newer workspace history tail")
        XCTAssertEqual(try queueRepo.list(threadId: XCTUnwrap(vm.selectedThreadId)).map(\.text), ["queued request B"],
                       "retrying A must neither duplicate nor consume queued request B")
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

    func test_inlinePlanCommandFailsClosedForProviderWithoutPlanCapability() async throws {
        let (vm, _) = try makeVM()
        let runner = CapturingProviderRunner(provider: .grok)
        vm.coordinator.replaceProvider(.grok, runner: runner)
        vm.createThread(title: "unsupported plan")
        vm.provider = .grok
        vm.providerInstanceId = "grok-cli"
        vm.interactionMode = .default
        vm.prompt = "/plan Inspect without editing"

        await vm.send()

        XCTAssertEqual(vm.interactionMode, .default)
        XCTAssertEqual(vm.prompt, "Inspect without editing",
                       "the user's question must remain editable after an unsupported /plan command")
        XCTAssertTrue(runner.prompts.isEmpty,
                      "an unsupported Plan request must not silently run in Default mode")
        XCTAssertTrue(vm.messages.contains { $0.role == .system && $0.content.contains("does not support Plan") })
    }

    func test_grokPermissionPickerFailsClosedForUnadvertisedMode() throws {
        let (vm, _) = try makeVM()
        let grok = AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-live", label: "Grok Live", provider: .grok)],
            binaryPath: "/tmp/grok",
            permissionModesOverride: [.supervised]
        )
        vm.providerSnapshots = [grok]
        vm.setProviderInstance(grok.id)

        vm.setPermissionMode(.fullAccess)

        XCTAssertEqual(vm.permissionMode, .supervised,
                       "the UI must not persist a Grok permission mode absent from ACP session modes")
        XCTAssertTrue(vm.statusMessage.contains("does not support Full access"))
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

    func test_slashFork_createsNativeProviderBranchAndCopiesVisibleHistory() async throws {
        let adapter = CapturingProviderAdapter(
            provider: .codex,
            forkThreadResult: "provider-child",
            forkSafety: .keyedIdempotent(compensationSupported: true)
        )
        let (vm, threadRepo) = try makeVM(adapter: adapter)
        vm.providerSnapshots = [crashSafeForkSnapshot()]
        vm.createThread(title: "source")
        let src = vm.selectedThreadId!
        var parent = try XCTUnwrap(try threadRepo.get(id: src))
        parent.providerThreadId = "provider-parent"
        try threadRepo.upsert(parent)
        vm.reloadThreads()
        vm.selectThread(src)
        try? vm.messageRepo.append(AgentMessage(threadId: src, role: .user, content: "q1"))
        try? vm.messageRepo.append(AgentMessage(threadId: src, role: .assistant, content: "a1"))
        XCTAssertTrue(vm.handleSlashCommand("/fork"))
        await waitAsync("provider-native fork") { vm.selectedThreadId != src }
        let forkedId = vm.selectedThreadId!
        XCTAssertNotEqual(forkedId, src, "/fork must select the new thread")
        XCTAssertEqual(vm.threads.first(where: { $0.id == forkedId })?.title, "source (fork)")
        XCTAssertEqual(vm.threads.first(where: { $0.id == forkedId })?.providerThreadId, "provider-child",
                       "the dependent child question must resume the provider-native branch")
        XCTAssertEqual(adapter.forkedThreadIds, [src])
        let copied = (try? vm.messageRepo.list(threadId: forkedId)) ?? []
        XCTAssertEqual(copied.map(\.content), ["q1", "a1"],
                       "the local transcript remains visible while provider context comes from native fork")

        vm.prompt = "dependent child question"
        await vm.send()
        vm.selectThread(src)
        vm.prompt = "parent-only follow-up"
        await vm.send()

        XCTAssertTrue(adapter.sentTurns.contains {
            $0.threadId == forkedId && $0.providerThreadId == "provider-child" && $0.prompt == "dependent child question"
        }, "the first dependent child question must run against the provider-native branch")
        XCTAssertTrue(adapter.sentTurns.contains {
            $0.threadId == src && $0.providerThreadId == "provider-parent" && $0.prompt == "parent-only follow-up"
        }, "later parent work must remain on the original provider session")
    }

    func test_forkCurrentThread_transcriptWriteFailureLeavesNoChildAndKeepsParentSelected() async throws {
        let adapter = CapturingProviderAdapter(
            provider: .codex,
            forkThreadResult: "provider-child",
            forkSafety: .keyedIdempotent(compensationSupported: true)
        )
        let (vm, threadRepo) = try makeVM(adapter: adapter)
        vm.providerSnapshots = [crashSafeForkSnapshot()]
        vm.createThread(title: "source")
        let parentId = try XCTUnwrap(vm.selectedThreadId)
        var parent = try XCTUnwrap(try threadRepo.get(id: parentId))
        parent.providerThreadId = "provider-parent"
        try threadRepo.upsert(parent)
        try vm.messageRepo.append(AgentMessage(threadId: parentId, role: .user, content: "must remain atomic"))
        try threadRepo.db.execute("""
            CREATE TRIGGER fail_fork_message_copy
            BEFORE INSERT ON agent_messages
            WHEN NEW.thread_id != '\(parentId.value.uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected child message failure'); END;
            """)
        vm.reloadThreads()
        vm.selectThread(parentId)

        await vm.forkCurrentThread()

        XCTAssertEqual(vm.selectedThreadId, parentId,
                       "a failed local fork transaction must never select a partial child")
        XCTAssertEqual(try threadRepo.list().map(\.id), [parentId],
                       "message-copy failure must roll back the child thread instead of leaving a partial rail item")
        XCTAssertTrue(vm.statusMessage.contains("Could not fork thread"),
                      "the parent surface must report the atomic fork failure")
    }

    func test_slashFork_isDisabledForGrokWithoutNegotiatedForkCapability() async throws {
        let adapter = CapturingProviderAdapter(provider: .grok, forkThreadResult: "must-not-fork")
        let (vm, _) = try makeVM(adapter: adapter)
        vm.provider = .grok
        vm.providerInstanceId = "grok-cli"
        vm.model = "grok-4.5"
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok", provider: .grok)],
            binaryPath: "/usr/local/bin/grok"
        )]
        vm.createThread(title: "grok source")
        let sourceId = try XCTUnwrap(vm.selectedThreadId)

        XCTAssertTrue(vm.handleSlashCommand("/fork"))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(vm.selectedThreadId, sourceId)
        XCTAssertTrue(adapter.forkedThreadIds.isEmpty,
                      "Grok ACP 0.2.101 must not receive fork until the negotiated capability advertises it")
        XCTAssertTrue(vm.messages.last?.content.contains("does not support provider-side fork") == true)
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

    func test_activeThreadCount_countsRunningThreads() async throws {
        let runner = SlowStartRunner()
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "idle")
        vm.createThread(title: "busy")
        vm.prompt = "keep this run active"
        await vm.send()

        XCTAssertEqual(vm.activeThreadCount, 1, "only threads with a real tracked run are active")
        vm.stop()
    }

    func test_chromeBusy_ignoresStaleLocalRunningStatusWithoutRunningWork() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "completed")
        let id = try XCTUnwrap(vm.selectedThreadId)
        var thread = try XCTUnwrap(repo.get(id: id))
        thread.status = .completed
        try repo.upsert(thread)
        vm.reloadThreads()
        vm.status = .running

        XCTAssertFalse(vm.hasRunningWorkForChrome,
                       "tab/sidebar spinners must reflect actual running work, not a stale local status after the selected thread completed")
    }

    func test_loadModels_keepsModelValidForProvider() async throws {
        // Auto-routing update: setProvider no longer clears the model — it
        // immediately resolves the provider's preferred model (last-used →
        // built-in default → first listed) so the composer never shows an
        // empty or foreign model while the async list loads.
        let (vm, _) = try makeVM()
        vm.providerSnapshots = []
        vm.setProvider(.codex)
        XCTAssertEqual(vm.model, AgentDefaultModelSelection.codexBuiltInDefault,
                       "a provider switch resolves the built-in default before the async load")
        await vm.loadModels()
        if !vm.availableModels.isEmpty {
            XCTAssertTrue(vm.availableModels.contains { $0.id == vm.model },
                          "a provider switch must leave a model valid for that provider")
        }
    }

    func test_providerSwitchClearsStaleModelBeforeAsyncLoad() throws {
        let (vm, _) = try makeVM()
        vm.providerSnapshots = []
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

    func test_providerSwitchToGrokClearsStaleCodexAndClaudeModels() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.availableModels = [
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)
        ]
        vm.model = "gpt-5.5"

        vm.setProvider(.grok)

        XCTAssertEqual(vm.provider, .grok)
        XCTAssertEqual(vm.providerInstanceId, AgentProvider.grok.rawValue)
        XCTAssertEqual(vm.availableModels, [],
                       "macOS Source→Grok must clear stale Codex model rows while Grok models load")
        XCTAssertEqual(vm.model, "",
                       "macOS must not keep sending a Codex model id after Source switches to Grok")

        vm.provider = .claude
        vm.availableModels = [
            AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)
        ]
        vm.model = "claude-sonnet-4-6"
        vm.setProvider(.grok)

        XCTAssertEqual(vm.provider, .grok)
        XCTAssertEqual(vm.availableModels, [])
        XCTAssertEqual(vm.model, "",
                       "macOS must not keep sending a Claude model id after Source switches to Grok")
    }

    func test_sourceAlwaysResolvesToASelectedSnapshotId() throws {
        let (vm, _) = try makeVM()
        // Simulate the common mismatch: thread/default stores "codex" while
        // host snapshots advertise "codex-cli".
        vm.provider = .codex
        vm.providerInstanceId = "codex"
        let snapshots = [
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
                models: [AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)],
                slashCommands: []
            ),
            AgentProviderSnapshot(
                id: "grok-cli",
                provider: .grok,
                driverKind: .grokCLI,
                displayName: "Grok",
                accentColor: "#1DA1F2",
                continuationGroup: "xai-grok",
                interactionModes: [.default],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok)],
                slashCommands: []
            )
        ]
        // applyProviderSnapshots is private; load through the public snapshot path
        // used by the UI by setting snapshots and re-applying via setProviderInstance
        // after remapping: first set snapshots, then use setProvider which remaps.
        vm.providerSnapshots = snapshots
        // Force remap the way applyProviderSnapshots does when id is stale:
        // setProvider on current provider should bind to the real snapshot id.
        vm.setProvider(.codex)

        XCTAssertEqual(vm.providerInstanceId, "codex-cli",
                       "Source must bind to a real snapshot id so the menu can mark one row")
        XCTAssertEqual(vm.selectedProviderSnapshot?.id, "codex-cli")
        XCTAssertEqual(vm.selectedProviderSnapshot?.provider, .codex)
        // Exactly one Source is selected for the checkmark.
        let selectedCount = snapshots.filter { $0.id == vm.selectedProviderSnapshot?.id }.count
        XCTAssertEqual(selectedCount, 1, "exactly one Source must be marked in the picker")

        vm.setProvider(.grok)
        XCTAssertEqual(vm.providerInstanceId, "grok-cli")
        XCTAssertEqual(vm.selectedProviderSnapshot?.displayName, "Grok")
        XCTAssertEqual(vm.model, "grok-4.5")
    }

    func test_providerInstanceSwitchToGrokReplacesForeignModels() throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.providerInstanceId = "codex-cli"
        vm.availableModels = [
            AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)
        ]
        vm.model = "gpt-5.5"
        let grokModels = [
            AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok, supportsReasoning: true)
        ]
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
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                slashCommands: []
            ),
            AgentProviderSnapshot(
                id: "grok-cli",
                provider: .grok,
                driverKind: .grokCLI,
                displayName: "Grok",
                accentColor: "#1DA1F2",
                continuationGroup: "xai-grok",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: grokModels,
                slashCommands: []
            )
        ]

        vm.setProviderInstance("grok-cli")

        XCTAssertEqual(vm.provider, .grok)
        XCTAssertEqual(vm.providerInstanceId, "grok-cli")
        XCTAssertEqual(vm.availableModels.map(\.id), ["grok-4.5"],
                       "instance switch to Grok must replace Codex model rows with Grok snapshot models")
        XCTAssertEqual(vm.model, "grok-4.5",
                       "foreign Codex model id must be replaced by the first Grok model after instance switch")
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

        // The Source picker row calls setProviderInstance (AgentAppSurface
        // :9484); a raw property write is not a product path.
        vm.setProviderInstance("claude-cli")

        XCTAssertEqual(vm.selectedProviderSnapshot?.provider, .claude)
        XCTAssertEqual(vm.modelOptionsForSelectedProvider.map(\.provider), [.claude],
                       "the model menu must follow the selected Source snapshot immediately; otherwise the user sees Claude with Codex GPT models until changing Source twice")
        XCTAssertFalse(vm.modelOptionsForSelectedProvider.contains { $0.id.hasPrefix("gpt-") },
                       "the model menu must not keep Codex GPT rows after the selected Source snapshot is Claude")
    }

    func test_modelDescriptorControlsClampIllegalReasoningAndServiceTier() throws {
        let (vm, _) = try makeVM()
        vm.providerSnapshots = []
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
        vm.providerSnapshots = []
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

    func test_selectingThreadLoadsEntireThreadWithBodiesRetained() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "long")
        let tid = vm.selectedThreadId!
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<100 {
            try vm.messageRepo.append(AgentMessage(threadId: tid, role: .user,
                content: "m\(i)", createdAt: base.addingTimeInterval(Double(i))))
        }
        vm.selectThread(tid)
        // selectThread hydrates history via a bounded off-main page (500 rows /
        // 24 MB budget) so thread-open never blocks MainActor; await it before
        // asserting. A 100-row thread fits the page, so the full-load contract
        // below is unchanged for normal threads.
        await vm.waitForMessageHistoryLoad()
        XCTAssertEqual(vm.messages.count, 100,
                       "a normal thread loads fully within one bounded page, not a 30-row viewport window")
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

    func test_loadWindowClipsHugePersistedMessagesBeforeRendering() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "huge")
        let tid = vm.selectedThreadId!
        try vm.messageRepo.append(AgentMessage(
            threadId: tid,
            role: .assistant,
            content: String(repeating: "x", count: AssistantTimelineState.liveTextLimit + 10)
        ))

        vm.selectThread(tid)
        await vm.waitForMessageHistoryLoad()

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
        await vm.waitForMessageHistoryLoad()
        let persistedCount = (try? vm.messageRepo.list(threadId: threadId).count) ?? -1
        XCTAssertEqual(vm.messages.count, persistedCount,
                       "reopening a long thread loads the whole persisted history within the bounded page")
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rc-attachment-dedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)

        vm.addAttachments([a.path, b.path, a.path])

        XCTAssertEqual(vm.attachments.map(\.displayName), ["a.txt", "b.txt"], "duplicate content must not stack")
        XCTAssertTrue(vm.attachments.allSatisfy { $0.path != a.path && $0.path != b.path },
                      "composer chips must point at managed storage instead of retaining private picker paths")
        vm.removeAttachment(vm.attachments[0])
        XCTAssertEqual(vm.attachments.map(\.displayName), ["b.txt"])
    }

    func test_droppedFilePaths_insertPathsIntoPromptWithoutCreatingAttachments() throws {
        let (vm, _) = try makeVM()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rc-attachment-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plain = root.appendingPathComponent("plain.txt")
        let spaced = root.appendingPathComponent("has space.txt")
        try "one".write(to: plain, atomically: true, encoding: .utf8)
        try "two".write(to: spaced, atomically: true, encoding: .utf8)
        vm.prompt = "review"

        vm.insertDroppedFilePaths([plain.path, spaced.path])

        XCTAssertEqual(vm.prompt, "review \(plain.path) \(spaced.path)",
                       "drop and paste must insert file paths as ordinary composer text so every provider can receive them")
        XCTAssertTrue(vm.attachments.isEmpty,
                      "drop and paste must not create provider-specific attachments")
    }

    func test_attachmentCapabilityErrorDoesNotBlockLaterTextSend() async throws {
        let runner = CapturingProviderRunner(provider: .grok)
        let (vm, _) = try makeVM(provider: runner)
        vm.coordinator.replaceProvider(.grok, runner: runner)
        vm.createThread(title: "send after attachment error")
        vm.provider = .grok
        vm.providerSnapshots = [AgentProviderSnapshot(
            id: "grok-no-attachments",
            provider: .grok,
            driverKind: .grokCLI,
            displayName: "Grok",
            accentColor: "#000000",
            continuationGroup: "grok",
            interactionModes: [.default],
            permissionModes: [.supervised],
            enabled: true,
            installed: true,
            status: .available,
            authenticated: true,
            models: [AgentModelDescriptor(id: "grok-4", label: "Grok 4", provider: .grok)],
            slashCommands: [],
            capabilities: .conservative
        )]
        vm.providerInstanceId = "grok-no-attachments"
        vm.model = "grok-4"
        vm.permissionMode = .supervised

        vm.addAttachments(["/tmp/unsupported.png"])
        vm.prompt = "send this text"
        await vm.send()

        XCTAssertEqual(runner.prompts, ["send this text"],
                       "a previous attachment error must never block a later ordinary text message")
        XCTAssertTrue(vm.statusMessage.isEmpty,
                      "a successful new send must clear the obsolete attachment error")
    }

    /// WHY: sqlite "database is locked" banners are durability noise. Once the
    /// thread streams more content, the outage is over — keep the banner and
    /// users think the run is still broken.
    func test_transientPersistenceError_autoClearsWhenStreamProgresses() {
        let locked = "Persistence failure during run.stream_event.append: sqlite step: database is locked"
        XCTAssertTrue(AgentAppViewModel.isTransientPersistenceTimelineError(locked),
                      "the exact banner text from stream_event.append must classify as transient")
        XCTAssertTrue(
            AgentAppViewModel.shouldAutoClearTransientTimelineError(
                errorAfterBatch: locked,
                appliedEvents: [
                    .error(message: locked, recoverable: false),
                    .itemDelta(itemId: "i1", bodyAppend: "ok", outputAppend: nil, summary: nil),
                ]
            ),
            "progress after a lock error must clear the banner"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldAutoClearTransientTimelineError(
                errorAfterBatch: locked,
                appliedEvents: [.turnStarted(turnId: "t2")]
            ),
            "a later batch with only progress must clear a sticky lock banner from an earlier batch"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldAutoClearTransientTimelineError(
                errorAfterBatch: locked,
                appliedEvents: [.error(message: locked, recoverable: false)]
            ),
            "a batch that is only the lock error must keep the banner visible"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldAutoClearTransientTimelineError(
                errorAfterBatch: "Provider request failed: 401 unauthorized",
                appliedEvents: [.itemDelta(itemId: "i1", bodyAppend: "x", outputAppend: nil, summary: nil)]
            ),
            "real provider failures must stay until the user dismisses or retries — not auto-clear on progress"
        )
    }

    func test_errorDismissActionsClearEachVisibleErrorChannel() throws {
        let (vm, _) = try makeVM()
        vm.timeline.apply(.error(message: "provider failed", recoverable: true))
        vm.statusMessage = "attachment failed"
        vm.queueStatusMessage = "queue failed"
        vm.modelListStatusMessage = "model load failed"
        vm.providerSnapshotStatusMessage = "provider load failed"
        vm.providerRecoveryStatusMessage = "provider recovery failed"
        vm.pullRequestStatusMessage = "PR preparation failed"
        vm.checkpointStatusMessage = "Revert failed"
        let unavailable = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: ""
        )
        vm.providerSnapshots = [unavailable]
        vm.providerInstanceId = unavailable.id
        XCTAssertNotNil(vm.providerStatusMessage,
                        "an unavailable selected provider must expose its error before dismissal")

        vm.dismissDisplayedError()
        vm.dismissStatusMessage()
        vm.dismissQueueStatusMessage()
        vm.dismissModelListStatusMessage()
        vm.dismissProviderSnapshotStatusMessage()
        vm.dismissProviderRecoveryStatusMessage()
        vm.dismissPullRequestStatusMessage()
        vm.dismissCheckpointStatusMessage()
        vm.dismissProviderStatusMessage()

        XCTAssertNil(vm.timeline.error, "the transcript error X must remove the visible error row")
        XCTAssertFalse(vm.lastErrorRecoverable, "dismissing the transcript error must remove its stale retry state")
        XCTAssertTrue(vm.statusMessage.isEmpty, "the status banner X must remove the visible status error")
        XCTAssertNil(vm.queueStatusMessage, "the queue banner X must remove the visible queue error")
        XCTAssertNil(vm.modelListStatusMessage, "the model-menu error X must clear its status")
        XCTAssertNil(vm.providerSnapshotStatusMessage, "the provider-load error X must clear its status")
        XCTAssertNil(vm.providerRecoveryStatusMessage, "the provider-recovery error X must clear its status")
        XCTAssertNil(vm.pullRequestStatusMessage, "the PR-menu error X must clear its status")
        XCTAssertNil(vm.checkpointStatusMessage, "the checkpoint error X must clear its status")
        XCTAssertNil(vm.providerStatusMessage, "the selected-provider error X must hide the derived status")
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
        let providerAttachment = try XCTUnwrap(runner.attachments.last?.first)
        XCTAssertNotEqual(providerAttachment.path, file.path,
                          "provider runs must receive the durable managed reference, not the original picker path")
        XCTAssertEqual(try String(contentsOfFile: providerAttachment.path), "let x = 1\n")
        let persistedMessages: [AgentMessage] = (try? vm.messageRepo.list(threadId: tid)) ?? []
        let user = persistedMessages.first { $0.role == .user }
        XCTAssertFalse(user?.content.contains(file.path) ?? true,
                       "persisted transcript must not leak raw attachment paths into prompt text")
        XCTAssertTrue(user?.content.contains(file.lastPathComponent) ?? false,
                      "the persisted transcript should keep a friendly attachment summary")
        XCTAssertEqual(user?.attachments.first?.sha256, providerAttachment.sha256,
                       "the persisted user message must retain durable attachment metadata for retry/relaunch")
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content.contains("📎") },
                      "the transcript shows a friendly attachment summary, not raw paths")
    }

    func test_send_withMissingAttachmentErrorStillSendsOrdinaryTextWithoutAttachment() async throws {
        let runner = CapturingProviderRunner(provider: .codex)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "t")
        vm.prompt = "review"
        vm.addAttachments(["/tmp/remote-code-missing-\(UUID().uuidString).png"])

        await vm.send()

        XCTAssertEqual(runner.prompts, ["review"],
                       "a missing attachment error must not block the user's ordinary text message")
        XCTAssertEqual(runner.attachments.last, [],
                       "the provider must receive no attachment rather than the invalid path")
        XCTAssertTrue(vm.statusMessage.isEmpty,
                      "the successful text send must clear the obsolete attachment error")
        XCTAssertTrue(vm.prompt.isEmpty,
                      "the text draft must clear after its successful send")
        XCTAssertTrue(vm.attachments.isEmpty,
                      "an invalid path must never become a misleading successful attachment chip")
    }

    func test_threadDraftRestoresTextAttachmentsAndModeAcrossRelaunch() throws {
        let tmp = NSTemporaryDirectory() + "rc2-agent-draft-relaunch-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let draftRepo = AgentThreadDraftRepository(db: db)
        let store = AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments"))
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])
        let a = AgentThread(workspaceId: workspaceID, title: "A", provider: .codex, model: "gpt", interactionMode: .plan)
        let b = AgentThread(workspaceId: workspaceID, title: "B", provider: .codex, model: "gpt", interactionMode: .default)
        try threadRepo.upsert(a)
        try threadRepo.upsert(b)
        let source = URL(fileURLWithPath: tmp).appendingPathComponent("private.png")
        try Data("image".utf8).write(to: source)

        let first = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp, coordinator: coordinator,
                                      threadRepo: threadRepo, messageRepo: messageRepo,
                                      draftRepo: draftRepo, attachmentStore: store, initialThreadId: a.id)
        installRunnableProviderFixtures(on: first)
        first.prompt = "private draft"
        first.promptWasEdited()
        first.addAttachments([source.path])
        first.interactionMode = .plan
        first.persistThreadConfig()
        first.selectThread(b.id)
        XCTAssertEqual(first.prompt, "")
        XCTAssertTrue(first.attachments.isEmpty, "thread B must not inherit thread A's private attachment")

        try FileManager.default.removeItem(at: source)
        let relaunched = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp, coordinator: coordinator,
                                           threadRepo: threadRepo, messageRepo: messageRepo,
                                           draftRepo: draftRepo, attachmentStore: store, initialThreadId: a.id)

        XCTAssertEqual(relaunched.prompt, "private draft")
        XCTAssertEqual(relaunched.attachments.map(\.displayName), ["private.png"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: relaunched.attachments[0].path),
                      "draft attachment must survive after the original picked file is removed")
        XCTAssertEqual(relaunched.interactionMode, .plan)
    }

    func test_sameThreadProviderSwitchRestoresOnlyMatchingProviderDraft() async throws {
        let (vm, _) = try makeVM()
        let codex = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-test", label: "GPT", provider: .codex)],
            binaryPath: "/tmp/codex",
            id: "codex-work"
        )
        let claude = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "claude-test", label: "Claude", provider: .claude)],
            binaryPath: "/tmp/claude",
            id: "claude-personal"
        )
        vm.providerSnapshotLoader = { [codex, claude] in [codex, claude] }
        await vm.loadProviderSnapshots()
        vm.createThread(title: "shared")
        vm.setProvider(.codex)
        vm.prompt = "codex-only draft"
        vm.interactionMode = .plan
        vm.promptWasEdited()

        vm.setProvider(.claude)
        XCTAssertEqual(vm.prompt, "",
                       "switching provider instances in one thread must not leak the prior provider's draft")
        XCTAssertEqual(vm.interactionMode, .default)
        vm.prompt = "claude-only draft"
        vm.promptWasEdited()

        vm.setProvider(.codex)
        XCTAssertEqual(vm.prompt, "codex-only draft")
        XCTAssertEqual(vm.interactionMode, .plan)
        vm.setProvider(.claude)
        XCTAssertEqual(vm.prompt, "claude-only draft")
        XCTAssertEqual(vm.interactionMode, .default)
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
        installRunnableProviderFixtures(on: vm)
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
        installRunnableProviderFixtures(on: vm)
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
        await reloadedVM.waitForMessageHistoryLoad()

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
        installRunnableProviderFixtures(on: vm)
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

    private func realCodexProviderSnapshot() -> AgentProviderSnapshot {
        AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: ProcessLocator.resolve("codex"),
            capabilitiesOverride: AgentProviderCapabilities(
                supportsAttachments: true,
                supportedAttachmentKinds: [.file, .image],
                supportedAttachmentMediaTypes: ["*/*", "image/jpeg", "image/png", "image/gif", "image/webp"],
                supportsApprovals: true,
                supportsUserInput: true,
                supportsStreaming: true,
                supportsFork: true,
                supportsRollback: true,
                supportsPlanReview: true
            )
        )
    }

    func test_realCodexAppServerAgentSurfaceSurvivesAppRestartAndRehydratesProviderHistory() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server Agent App surface E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-agent-app-" + UUID().uuidString
        let isolatedCodexHome = tmp + "-codex-home"
        let installedCodexAuth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path
        guard FileManager.default.fileExists(atPath: installedCodexAuth) else {
            throw XCTSkip("installed Codex auth.json is unavailable")
        }
        try FileManager.default.createDirectory(atPath: isolatedCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: isolatedCodexHome + "/auth.json",
            withDestinationPath: installedCodexAuth
        )
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: isolatedCodexHome)
        }
        let isolatedCodexLaunch: (AgentProvider, String?) -> (binary: String?, environment: [String: String]) = { provider, _ in
            provider == .codex
                ? (nil, ["CODEX_HOME": isolatedCodexHome])
                : (nil, [:])
        }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let workspaceID = WorkspaceID()

        let firstAdapter = CodexAppServerAdapter()
        defer { firstAdapter.stopAll() }
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
        firstSurface.providerLaunchConfig = isolatedCodexLaunch
        firstSurface.providerSnapshots = [realCodexProviderSnapshot()]
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

        firstAdapter.stopAllForAppTermination()

        let secondAdapter = CodexAppServerAdapter()
        defer { secondAdapter.stopAll() }
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
        secondSurface.providerLaunchConfig = isolatedCodexLaunch
        secondSurface.providerSnapshots = [realCodexProviderSnapshot()]
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
        defer { readbackAdapter.stopAll() }
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
        readbackSurface.providerLaunchConfig = isolatedCodexLaunch
        readbackSurface.selectThread(threadId)
        let renderedBodies = readbackSurface.timeline.turns.flatMap(\.items).map(\.body).joined(separator: "\n")
        XCTAssertTrue(renderedBodies.contains("RC_AGENT_APP_REAL_1"))
        XCTAssertTrue(renderedBodies.contains("RC_AGENT_APP_REAL_2"),
                      "final app restart readback must prove both real Codex app-server turns remain visible in provider history")
        readbackAdapter.stopAll()
    }

    func test_realCodexAppServerLocalImageAttachmentChangesTheAnswer() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server image E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-image-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let isolatedCodexHome = tmp + "-codex-home"
        defer { try? FileManager.default.removeItem(atPath: isolatedCodexHome) }
        let installedCodexAuth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path
        guard FileManager.default.fileExists(atPath: installedCodexAuth) else {
            throw XCTSkip("installed Codex auth.json is unavailable")
        }
        try FileManager.default.createDirectory(atPath: isolatedCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: isolatedCodexHome + "/auth.json",
            withDestinationPath: installedCodexAuth
        )

        let nonce = "RC_IMAGE_42A7"
        let image = NSImage(size: NSSize(width: 900, height: 240))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 240).fill()
        nonce.draw(
            at: NSPoint(x: 55, y: 80),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 72, weight: .bold),
                .foregroundColor: NSColor.black
            ]
        )
        image.unlockFocus()
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let imagePath = tmp + "/nonce.png"
        try png.write(to: URL(fileURLWithPath: imagePath))

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp + "-db").run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let adapter = CodexAppServerAdapter()
        defer { adapter.stopAll() }
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: ProviderSessionRuntimeRepository(db: db),
            providerAdapters: [.codex: adapter]
        )
        let surface = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        surface.providerLaunchConfig = { provider, _ in
            provider == .codex ? (nil, ["CODEX_HOME": isolatedCodexHome]) : (nil, [:])
        }
        surface.providerSnapshots = [realCodexProviderSnapshot()]
        surface.createThread(title: "real image")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        surface.permissionMode = .supervised
        surface.addAttachments([imagePath])
        XCTAssertEqual(surface.attachments.count, 1)
        surface.prompt = "Read the exact code shown in the attached image. Reply with only that code."

        await surface.send()
        await waitAsync("real Codex local-image turn completes", timeout: 240) {
            surface.status == .completed
        }
        let rendered = surface.timeline.turns.flatMap(\.items).map(\.body).joined(separator: "\n")
        XCTAssertTrue(rendered.contains(nonce) || (surface.messages.last?.content.contains(nonce) ?? false),
                      "the real Codex answer must depend on bytes delivered through localImage/path")
        XCTAssertFalse(rendered.contains(imagePath),
                       "the visible transcript must not expose the private absolute attachment path")
    }

    func test_realCodexAppServerMissingAuthSurfacesSignInRecovery() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server auth E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-no-auth-" + UUID().uuidString
        let emptyCodexHome = tmp + "-codex-home"
        try FileManager.default.createDirectory(atPath: emptyCodexHome, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: emptyCodexHome)
        }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let adapter = CodexAppServerAdapter()
        defer { adapter.stopAll() }
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: ProviderSessionRuntimeRepository(db: db),
            providerAdapters: [.codex: adapter]
        )
        let surface = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp, coordinator: coordinator,
            threadRepo: threadRepo, messageRepo: messageRepo
        )
        surface.providerLaunchConfig = { provider, _ in
            provider == .codex ? (nil, ["CODEX_HOME": emptyCodexHome]) : (nil, [:])
        }
        surface.providerSnapshots = [realCodexProviderSnapshot()]
        surface.createThread(title: "missing auth")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        surface.permissionMode = .supervised
        surface.prompt = "Reply exactly SHOULD_NOT_RUN."

        await surface.send()
        await waitAsync("real Codex auth failure reaches Agent App", timeout: 120) {
            surface.status == .failed && surface.timeline.error != nil
        }
        XCTAssertEqual(surface.displayedErrorRecoveryAction, .signIn,
                       "a real unauthenticated app-server turn must expose Sign in instead of a dead generic error")
        XCTAssertFalse(surface.messages.contains { $0.role == .assistant && $0.content.contains("SHOULD_NOT_RUN") },
                       "an unauthenticated turn must not be misrepresented as successful provider output")
    }

    func test_realCodexAppServerForkRetainsParentContextAndIsolatesChildChanges() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex app-server fork E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-fork-" + UUID().uuidString
        let isolatedCodexHome = tmp + "-codex-home"
        let installedCodexAuth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path
        guard FileManager.default.fileExists(atPath: installedCodexAuth) else {
            throw XCTSkip("installed Codex auth.json is unavailable")
        }
        try FileManager.default.createDirectory(atPath: isolatedCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: isolatedCodexHome + "/auth.json",
            withDestinationPath: installedCodexAuth
        )
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: isolatedCodexHome)
        }

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let adapter = CodexAppServerAdapter()
        defer { adapter.stopAll() }
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db), messageRepo: messageRepo, threadRepo: threadRepo,
            providerSessionRepo: ProviderSessionRuntimeRepository(db: db), providerAdapters: [.codex: adapter]
        )
        coordinator.recoveryEnvironmentProvider = { provider, _ in
            provider == .codex ? ["CODEX_HOME": isolatedCodexHome] : [:]
        }
        let surface = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp, coordinator: coordinator,
            threadRepo: threadRepo, messageRepo: messageRepo
        )
        surface.providerLaunchConfig = { provider, _ in
            provider == .codex ? (nil, ["CODEX_HOME": isolatedCodexHome]) : (nil, [:])
        }
        surface.providerSnapshots = [realCodexProviderSnapshot()]
        surface.createThread(title: "real fork parent")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        surface.permissionMode = .supervised
        surface.prompt = "Remember that the base label is RC_FORK_BASE_42A7. Reply exactly READY."
        await surface.send()
        await waitAsync("real Codex parent context turn completes", timeout: 240) {
            surface.status == .completed
        }
        let parentId = try XCTUnwrap(surface.selectedThreadId)
        let parentProviderId = try XCTUnwrap(try threadRepo.get(id: parentId)?.providerThreadId)

        await surface.forkCurrentThread()
        let childId = try XCTUnwrap(surface.selectedThreadId)
        XCTAssertNotEqual(childId, parentId)
        let childProviderId = try XCTUnwrap(try threadRepo.get(id: childId)?.providerThreadId)
        XCTAssertNotEqual(childProviderId, parentProviderId,
                          "a real fork must create a distinct provider-native branch identity")

        surface.prompt = "Remember that the child-only label is RC_FORK_CHILD_73B9. Reply exactly CHILD_SET."
        await surface.send()
        await waitAsync("real Codex child turn completes", timeout: 240) { surface.status == .completed }

        surface.selectThread(parentId)
        surface.prompt = "What is the base label? Did any prior message in this conversation set a child-only label? Reply BASE_LABEL|YES_OR_NO only."
        await surface.send()
        await waitAsync("real Codex parent isolation turn completes", timeout: 240) { surface.status == .completed }
        let parentReply = surface.messages.last(where: { $0.role == .assistant })?.content ?? ""
        XCTAssertTrue(parentReply.contains("RC_FORK_BASE_42A7") && parentReply.uppercased().contains("|NO"),
                      "the parent must retain its base context without receiving child-only mutations; got: \(parentReply)")

        surface.selectThread(childId)
        surface.prompt = "What are the base label and child-only label? Reply BASE_LABEL|CHILD_LABEL only."
        await surface.send()
        await waitAsync("real Codex fork context turn completes", timeout: 240) { surface.status == .completed }
        let childReply = surface.messages.last(where: { $0.role == .assistant })?.content ?? ""
        XCTAssertTrue(childReply.contains("RC_FORK_BASE_42A7") && childReply.contains("RC_FORK_CHILD_73B9"),
                      "the provider-native child must inherit parent context and retain its own later context; got: \(childReply)")
        XCTAssertEqual(try threadRepo.get(id: parentId)?.providerThreadId, parentProviderId)
        XCTAssertEqual(try threadRepo.get(id: childId)?.providerThreadId, childProviderId)
    }

    func test_realCodexRelaunchContinueUsesPersistedCursorAndContext() async throws {
        guard ProcessInfo.processInfo.environment["RC_REAL_CODEX_AGENT_APP_E2E"] == "1" else {
            throw XCTSkip("Set RC_REAL_CODEX_AGENT_APP_E2E=1 to run the installed Codex relaunch E2E.")
        }
        guard ProcessLocator.resolve("codex") != nil else {
            throw XCTSkip("codex binary is not available on PATH")
        }

        let tmp = NSTemporaryDirectory() + "rc2-real-codex-relaunch-" + UUID().uuidString
        let isolatedCodexHome = tmp + "-codex-home"
        let installedCodexAuth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path
        guard FileManager.default.fileExists(atPath: installedCodexAuth) else {
            throw XCTSkip("installed Codex auth.json is unavailable")
        }
        try FileManager.default.createDirectory(atPath: isolatedCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: isolatedCodexHome + "/auth.json",
            withDestinationPath: installedCodexAuth
        )
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: isolatedCodexHome)
        }

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let providerSnapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: ProcessLocator.resolve("codex")
        )

        let firstAdapter = CodexAppServerAdapter()
        let firstCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.codex: firstAdapter]
        )
        firstCoordinator.recoveryEnvironmentProvider = { provider, _ in
            provider == .codex ? ["CODEX_HOME": isolatedCodexHome] : [:]
        }
        let firstSurface = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: firstCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo
        )
        firstSurface.providerLaunchConfig = { provider, _ in
            provider == .codex ? (nil, ["CODEX_HOME": isolatedCodexHome]) : (nil, [:])
        }
        firstSurface.providerSnapshots = [providerSnapshot]
        firstSurface.createThread(title: "real relaunch")
        firstSurface.provider = .codex
        firstSurface.model = "gpt-5.5"
        firstSurface.reasoningEffort = .minimal
        firstSurface.permissionMode = .supervised
        firstSurface.prompt = "Remember RC_RELAUNCH_CONTEXT_91D4. If asked to continue interrupted work, reply exactly CONTINUED|RC_RELAUNCH_CONTEXT_91D4. For now reply exactly READY."

        await firstSurface.send()
        await waitAsync("real Codex pre-relaunch context turn completes", timeout: 240) {
            firstSurface.status == .completed
        }
        let threadId = try XCTUnwrap(firstSurface.selectedThreadId)
        let providerThreadId = try XCTUnwrap(try threadRepo.get(id: threadId)?.providerThreadId)
        firstSurface.permissionMode = .fullAccess
        firstSurface.prompt = "Run the shell command `sleep 60` now. After it finishes, reply exactly LONG_TURN_FINISHED."
        await firstSurface.send()
        await waitAsync("real Codex long turn is durably running", timeout: 30) {
            guard let runId = firstSurface.currentRunId else { return false }
            return (try? runRepo.get(id: runId)?.status) == .running
                && (try? sessionRepo.get(threadId: threadId)?.status) == .running
                && (try? sessionRepo.get(threadId: threadId)?.resumeCursor) == providerThreadId
        }
        let interruptedRunId = try XCTUnwrap(firstSurface.currentRunId)
        XCTAssertEqual(try runRepo.get(id: interruptedRunId)?.status, .running,
                       "precondition: force-quit must land inside a real active provider turn")
        let userMessageCount = try messageRepo.list(threadId: threadId).filter { $0.role == .user }.count

        // Simulate the app process disappearing: kill the real app-server without
        // delivering a synthetic terminal callback or rewriting durable statuses.
        firstAdapter.stopAllForAppTermination()

        let relaunchedAdapter = CodexAppServerAdapter()
        defer { relaunchedAdapter.stopAll() }
        let relaunchedCoordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.codex: relaunchedAdapter]
        )
        relaunchedCoordinator.recoveryEnvironmentProvider = { provider, _ in
            provider == .codex ? ["CODEX_HOME": isolatedCodexHome] : [:]
        }
        try relaunchedCoordinator.reconcileOnLaunch()
        XCTAssertEqual(try threadRepo.get(id: threadId)?.status, .interrupted)
        XCTAssertEqual(try runRepo.get(id: interruptedRunId)?.status, .interrupted)
        XCTAssertTrue(relaunchedCoordinator.hasRecoverableContext(threadId: threadId),
                      "relaunch reconciliation must retain a cursor-backed Codex session as recoverable")

        let relaunchedSurface = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: relaunchedCoordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            initialThreadId: threadId
        )
        relaunchedSurface.providerLaunchConfig = { provider, _ in
            provider == .codex ? (nil, ["CODEX_HOME": isolatedCodexHome]) : (nil, [:])
        }
        relaunchedSurface.providerSnapshots = [providerSnapshot]
        XCTAssertTrue(relaunchedSurface.selectedThreadHasRecoverableContext)

        await relaunchedSurface.continueInterruptedThread()
        await waitAsync("real Codex interrupted context continues after relaunch", timeout: 240) {
            relaunchedSurface.status == .completed
        }
        let reply = relaunchedSurface.messages.last(where: { $0.role == .assistant })?.content ?? ""
        XCTAssertTrue(reply.contains("CONTINUED|RC_RELAUNCH_CONTEXT_91D4"),
                      "Continue must resume the same real Codex context; got: \(reply)")
        XCTAssertEqual(try threadRepo.get(id: threadId)?.providerThreadId, providerThreadId,
                       "relaunch continuation must retain the original provider cursor")
        XCTAssertEqual(try messageRepo.list(threadId: threadId).filter { $0.role == .user }.count, userMessageCount,
                       "the provider-only Continue instruction must not invent a user transcript message")
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
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: tmp + "-db")
        }
        let sentinel = tmp + "/sentinel.txt"
        try "RC_PLAN_SENTINEL_ORIGINAL\n".write(toFile: sentinel, atomically: true, encoding: .utf8)

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp + "-db").run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let workspaceID = WorkspaceID()

        let adapter = CodexAppServerAdapter()
        defer { adapter.stopAll() }
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
        surface.providerSnapshots = [realCodexProviderSnapshot()]
        surface.createThread(title: "real plan")
        surface.provider = .codex
        surface.model = "gpt-5.5"
        surface.reasoningEffort = .minimal
        // Plan mode may inspect local instructions before proposing a plan. Keep
        // approvals out of this lifecycle gate; Plan's read-only collaboration
        // sandbox still proves the no-mutation contract below.
        surface.permissionMode = .fullAccess
        surface.showPlanSidebar = true
        surface.interactionMode = .plan
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
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let workspaceID = WorkspaceID()

        let adapter = CodexAppServerAdapter()
        defer { adapter.stopAll() }
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
        surface.providerSnapshots = [realCodexProviderSnapshot()]
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
        defer {
            try? FileManager.default.removeItem(atPath: repoDir)
            try? FileManager.default.removeItem(atPath: appSupport)
        }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let workspaceID = WorkspaceID()

        let adapter = CodexAppServerAdapter()
        defer { adapter.stopAll() }
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
        surface.providerSnapshots = [realCodexProviderSnapshot()]
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
        defer { restartedAdapter.stopAll() }
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
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "/usr/local/bin/codex"
        )]
        vm.selectThread(thread.id)
        vm.timeline.apply(.error(message: "Previous provider failure", recoverable: true))

        await vm.implementLatestPlan()

        XCTAssertNil(vm.timeline.error,
                     "implementing a proposed plan submits a new provider message and must clear any stale error banner")
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

    func test_implementLatestPlanDoesNotPublishImplementedStateWhenPersistenceFails() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-implement-failure-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let thread = AgentThread(workspaceId: WorkspaceID(), title: "plan", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-fail", turnId: "turn-1", markdown: "1. Persist")
        )
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: thread.workspaceId!,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            proposedPlanRepo: proposedPlanRepo
        )
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "/usr/local/bin/codex"
        )]
        vm.selectThread(thread.id)
        try db.execute("DROP TABLE agent_proposed_plans;")

        await vm.implementLatestPlan()

        XCTAssertTrue(vm.statusMessage.contains("implementation state could not be saved"))
        XCTAssertNil(vm.latestProposedPlan?.implementedAtMs,
                     "the plan card must remain actionable when its durable implemented state did not commit")
    }

    func test_fullAccessSuppressesProposedPlanReviewAndAutoImplements() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-fullaccess-auto-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let runner = SlowStartRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let workspaceID = WorkspaceID()
        var thread = AgentThread(
            workspaceId: workspaceID,
            title: "full-access-plan",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .fullAccess
        )
        try threadRepo.upsert(thread)
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: queuedRepo,
            proposedPlanRepo: proposedPlanRepo,
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        installRunnableProviderFixtures(on: vm)
        vm.selectThread(thread.id)
        vm.permissionMode = .fullAccess
        XCTAssertTrue(vm.suppressesProposedPlanReview,
                      "full access must suppress plan Approve/Reject review")

        // Start a long turn so auto-implement must queue rather than fail in-flight.
        vm.prompt = "plan while autonomous"
        Task { await vm.send() }
        await waitAsync("active run under full access") {
            vm.status == .running && vm.currentRunId != nil
        }

        vm.timeline.apply(.proposedPlan(AssistantProposedPlan(
            id: "auto-plan-1",
            turnId: "turn-1",
            markdown: "1. Inspect\n2. Patch"
        )))
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "auto-plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")
        )
        XCTAssertNil(vm.reviewableProposedPlan,
                     "full access must not expose a reviewable proposed plan card")
        vm.scheduleFullAccessPlanAutoImplementIfNeeded()

        await waitAsync("auto-implement queues the plan prompt") {
            ((try? queuedRepo.list(threadId: thread.id)) ?? []).contains {
                $0.text.contains("Implement this proposed plan now")
            }
        }
        let queued = try queuedRepo.list(threadId: thread.id)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued[0].interactionMode, .default)
        XCTAssertTrue(vm.queueStatusMessage?.contains("Queued") == true)
        XCTAssertFalse(vm.statusMessage.contains("in-flight"))
        // Dedup: second schedule must not enqueue again.
        vm.scheduleFullAccessPlanAutoImplementIfNeeded()
        XCTAssertEqual(try queuedRepo.list(threadId: thread.id).count, 1,
                       "auto-implement must not double-queue the same plan")
        vm.stop()
        await waitAsync("slow run stops") { runner.cancelled }
    }

    /// WHY: Pet / sidebar reopen calls selectThread. Full-access auto-implement
    /// must not fire on mere view open — that auto-sends "Implement this proposed
    /// plan now..." when the user only wanted to open Agent App.
    func test_selectThread_doesNotAutoImplementUnimplementedPlanUnderFullAccess() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-select-no-auto-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let runner = CapturingProviderRunner(provider: .codex)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "reopen-full-access",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .fullAccess
        )
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(
                id: "reopen-plan",
                turnId: "turn-1",
                markdown: "1. [completed] Phase\n2. [completed] Phase"
            )
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: queuedRepo,
            proposedPlanRepo: proposedPlanRepo,
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        installRunnableProviderFixtures(on: vm)

        // Pet / openAgentThread path: selectThread rehydrates plans but must not send.
        vm.selectThread(thread.id)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(runner.prompts.count, 0,
                       "reopening a full-access thread must not auto-start implement-plan")
        XCTAssertEqual(try queuedRepo.list(threadId: thread.id).count, 0,
                       "reopening must not queue Implement this proposed plan now")
        XCTAssertFalse(
            runner.prompts.contains(where: { $0.contains("Implement this proposed plan now") }),
            "pet/open path must never inject the implement-plan prompt"
        )
        XCTAssertNotNil(vm.latestProposedPlan,
                        "the proposed plan must still be visible after reopen")
        XCTAssertTrue(vm.latestProposedPlan?.showsImplementationActions == true,
                      "unimplemented plan stays reviewable for explicit Approve/auto paths")
    }

    func test_supervisedKeepsProposedPlanReviewable() throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-supervised-review-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "supervised-plan",
            provider: .codex,
            model: "gpt-5.5",
            permissionMode: .supervised
        )
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "sup-plan", turnId: "t1", markdown: "1. Review me")
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: AgentRunCoordinator(
                runRepo: AgentRunRepository(db: db),
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providers: [.codex: FakeProviderRunner(provider: .codex)]
            ),
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            proposedPlanRepo: proposedPlanRepo
        )
        installRunnableProviderFixtures(on: vm)
        vm.selectThread(thread.id)
        vm.permissionMode = .supervised
        XCTAssertFalse(vm.suppressesProposedPlanReview)
        XCTAssertNotNil(vm.reviewableProposedPlan)
        XCTAssertTrue(vm.reviewableProposedPlan?.showsImplementationActions == true)
    }

    func test_implementLatestPlanQueuesWhileProviderTurnIsRunning() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-implement-queue-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runner = SlowStartRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "plan-busy", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-queue", turnId: "turn-plan", markdown: "1. Inspect\n2. Patch")
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: queuedRepo,
            proposedPlanRepo: proposedPlanRepo,
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        installRunnableProviderFixtures(on: vm)
        vm.selectThread(thread.id)

        vm.prompt = "produce plan while running"
        Task { await vm.send() }
        await waitAsync("plan thread becomes a real active run") {
            vm.status == .running && vm.currentRunId != nil
        }

        await vm.implementLatestPlan()

        let queued = try queuedRepo.list(threadId: thread.id)
        XCTAssertEqual(queued.count, 1,
                       "Approve must queue implementation while the plan-producing turn is still open")
        XCTAssertTrue(queued[0].text.contains("Implement this proposed plan now"),
                      "queued follow-up must be the plan implementation prompt, not a silent no-op")
        XCTAssertEqual(queued[0].interactionMode, .default,
                       "Approve must leave Plan mode when the queued turn eventually starts")
        XCTAssertTrue(vm.queueStatusMessage?.contains("Queued") == true,
                      "user must see that Approve was accepted into the queue instead of a hard start failure")
        XCTAssertFalse(vm.statusMessage.contains("in-flight"),
                       "Approve while running must not surface the adapter concurrent-turn error")
        let stored = try XCTUnwrap(proposedPlanRepo.list(threadId: thread.id).first { $0.plan.id == "plan-queue" })
        XCTAssertNotNil(stored.plan.implementedAtMs,
                        "user intent to implement is durable once Approve queues successfully")
        XCTAssertEqual(runner.prompts, ["produce plan while running"],
                       "Approve must not open a concurrent provider turn while one is already in flight")
        vm.stop()
        await waitAsync("slow run can still be stopped after plan Approve queueing") {
            runner.cancelled
        }
    }

    func test_rejectLatestPlanQueuesWhileProviderTurnIsRunning() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-reject-queue-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedRepo = AgentQueuedMessageRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let runner = SlowStartRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "plan-reject", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-reject", turnId: "turn-plan", markdown: "1. Inspect")
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: queuedRepo,
            proposedPlanRepo: proposedPlanRepo,
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        installRunnableProviderFixtures(on: vm)
        vm.selectThread(thread.id)

        vm.prompt = "plan still open"
        Task { await vm.send() }
        await waitAsync("reject path waits for active run") {
            vm.status == .running && vm.currentRunId != nil
        }

        await vm.rejectLatestPlan()

        let queued = try queuedRepo.list(threadId: thread.id)
        XCTAssertEqual(queued.count, 1)
        XCTAssertTrue(queued[0].text.contains("Reject this proposed plan"))
        XCTAssertEqual(queued[0].interactionMode, .plan,
                       "Reject must keep Plan mode for the revised-plan turn")
        XCTAssertNil(try proposedPlanRepo.list(threadId: thread.id).first?.plan.implementedAtMs,
                     "Reject must not mark the plan implemented")
        vm.stop()
        await waitAsync("slow run stops after reject queueing") { runner.cancelled }
    }

    func test_sendKeepsVisibleDraftAndReportsFailureWhenDurableDraftDeletionFails() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-draft-delete-failure-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let draftRepo = AgentThreadDraftRepository(db: db)
        let workspaceID = WorkspaceID()
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: draftRepo
        )
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .codex,
            models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
            binaryPath: "/usr/local/bin/codex"
        )]
        vm.createThread(title: "draft failure")
        vm.prompt = "send exactly once"
        vm.promptWasEdited()
        try db.execute("DROP TABLE agent_thread_drafts;")

        await vm.send()

        XCTAssertEqual(vm.prompt, "send exactly once",
                       "a failed durable delete must not clear the visible recovery copy")
        XCTAssertTrue(vm.statusMessage.contains("draft cleanup failed"),
                      "the surface must not present silent send success when draft durability failed")
    }

    func test_rejectLatestPlanStartsAPlanRevisionWithoutMarkingImplementation() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-plan-reject-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let proposedPlanRepo = AgentProposedPlanRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(workspaceId: workspaceID, title: "plan", provider: .grok, model: "grok-4.5")
        try threadRepo.upsert(thread)
        try proposedPlanRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "grok-plan-1", turnId: "turn-1", markdown: "1. Inspect\n2. Patch")
        )
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.grok: FakeProviderRunner(provider: .grok)]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            proposedPlanRepo: proposedPlanRepo
        )
        vm.providerSnapshots = [AgentProviderSnapshotFactory.snapshot(
            provider: .grok,
            models: [AgentModelDescriptor(id: "grok-4.5", label: "Grok 4.5", provider: .grok)],
            binaryPath: "/usr/local/bin/grok",
            interactionModesOverride: [.default, .plan],
            capabilitiesOverride: AgentProviderCapabilities(supportsStreaming: true, supportsPlanReview: true)
        )]
        vm.selectThread(thread.id)

        await vm.rejectLatestPlan()

        let messages = try messageRepo.list(threadId: thread.id)
        XCTAssertTrue(messages.contains {
            $0.role == .user && $0.content.contains("Reject this proposed plan") && $0.content.contains("Stay in Plan mode")
        }, "Reject must start a provider-backed revision turn, not only hide the plan card locally")
        let storedPlan = try XCTUnwrap(proposedPlanRepo.list(threadId: thread.id).first?.plan)
        XCTAssertNil(storedPlan.implementedAtMs,
                     "rejecting a plan must not mark it implemented")
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
        XCTAssertEqual(vm.model, AgentDefaultModelSelection.codexBuiltInDefault,
                       "fresh threads must start on the product's built-in codex default")
        await vm.loadModels()
        XCTAssertTrue(vm.availableModels.contains { $0.id == vm.model },
                      "the default model must be one the picker actually offers")
    }

    // F6: the SR1 translation maps were additive-only and never cleared on a thread
    // switch, so they accumulated the union of every translated message (and its full
    // original text) across every thread visited for the whole session.
    @MainActor
    func test_sr1TranslationMaps_resetOnThreadSwitchButSurviveReselect() async throws {
        let (vm, threadRepo) = try makeVM()
        let a = AgentThread(title: "A", provider: .claude, model: "m")
        let b = AgentThread(title: "B", provider: .claude, model: "m")
        try threadRepo.upsert(a)
        try threadRepo.upsert(b)
        vm.reloadThreads()

        vm.selectThread(a.id)
        let msgId = AgentMessageID(UUID())
        vm.coordinator.onSR1TranslatedMessageId?(msgId)   // live badge -> Task { @MainActor }
        for _ in 0..<200 where !vm.sr1TranslatedMessageIds.contains(msgId) {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(vm.sr1TranslatedMessageIds.contains(msgId),
                      "a live SR1 translation must mark the message on the current thread")

        // Re-selecting the SAME thread must NOT wipe live translation state.
        vm.selectThread(a.id)
        XCTAssertTrue(vm.sr1TranslatedMessageIds.contains(msgId),
                      "re-selecting the same thread must keep its SR1 translation badges")

        // Switching to a DIFFERENT thread (no translations) must clear the maps.
        vm.selectThread(b.id)
        XCTAssertTrue(vm.sr1TranslatedMessageIds.isEmpty,
                      "switching threads must reset SR1 translation state (F6: no cross-thread accumulation)")
        XCTAssertTrue(vm.sr1OriginalTextsByMessageId.isEmpty,
                      "switching threads must also drop the retained original texts")
    }

    // F9: deleting a thread must evict its per-thread VM caches and the coordinator's
    // per-thread auto-continuation bookkeeping, which previously leaked one entry per
    // deleted thread for the life of the surface.
    @MainActor
    func test_deleteThread_evictsPerThreadVMCachesAndCoordinatorState() async throws {
        let (vm, threadRepo) = try makeVM()
        let a = AgentThread(title: "A", provider: .claude, model: "m")
        let b = AgentThread(title: "B", provider: .claude, model: "m")
        try threadRepo.upsert(a)
        try threadRepo.upsert(b)
        vm.reloadThreads()

        // Populate a per-thread VM cache: type a draft on A, then switch away so it
        // is stashed in composerDraftsByThread[A].
        vm.selectThread(a.id)
        vm.prompt = "unsent draft for A"
        vm.selectThread(b.id)
        // Seed the coordinator's per-thread auto-continuation state for A.
        vm.coordinator.seedAutoContinuationStateForTesting(a.id)

        XCTAssertTrue(vm.threadCacheResidueForTesting.contains(a.id),
                      "precondition: A is present in a per-thread VM cache")
        XCTAssertTrue(vm.coordinator.autoContinuationThreadIdsForTesting.contains(a.id),
                      "precondition: A is present in coordinator auto-continuation state")

        await vm.deleteThread(a.id)

        XCTAssertFalse(vm.threadCacheResidueForTesting.contains(a.id),
                       "deleting a thread must leave no residue in any per-thread VM cache (F9)")
        XCTAssertFalse(vm.coordinator.autoContinuationThreadIdsForTesting.contains(a.id),
                       "deleting a thread must drop its coordinator auto-continuation state (F9)")
    }

    // F2: computeTurnRenderInputs is the single per-turn derivation that replaced the
    // re-run-every-body-pass logic in turnView. It must produce EXACTLY what the prior
    // composition of the (independently tested) helpers produced.
    func test_computeTurnRenderInputs_matchesPriorHelperComposition() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "Let me read the config first.", startedAtMs: 1_000, finishedAtMs: 2_000),
                AssistantItem(id: "tool", turnId: "turn-1", type: .commandExecution, state: .completed, summary: "swift test", output: "PASS", startedAtMs: 2_000, finishedAtMs: 4_000),
                AssistantItem(id: "msg-3", turnId: "turn-1", type: .assistantMessage, state: .completed, body: "All checks passed.", startedAtMs: 4_000, finishedAtMs: 5_000)
            ],
            finalAssistantMessage: "All checks passed.",
            finished: true
        )
        let inputs = AgentAppView.computeTurnRenderInputs(
            turn: turn, persistedAssistantTexts: [], proposedPlans: [], running: false)

        let renderable = AgentAppView.renderableItems(in: turn)
        let expectedVisible = AgentAppView.turnRenderBlocks(
            AgentAppView.completedVisibleAssistantItems(in: turn, renderableItems: renderable))
        let expectedWork = AgentAppView.turnRenderBlocks(
            AgentAppView.completedWorkItems(in: turn, renderableItems: renderable))

        XCTAssertEqual(inputs.visibleBlocks, expectedVisible,
                       "visible blocks must match turnRenderBlocks(completedVisibleAssistantItems)")
        XCTAssertEqual(inputs.completedWorkBlocks, expectedWork,
                       "work blocks must match turnRenderBlocks(completedWorkItems) — the finalIDs split is computed once but identically")
        XCTAssertEqual(inputs.shouldRenderFinal,
                       AgentAppView.shouldRenderFinalAssistantMessage(turn, persistedAssistantTexts: []),
                       "shouldRenderFinal must match the helper — here the last item already renders the answer, so the separate final block is suppressed (no double answer)")
        XCTAssertFalse(inputs.shouldRenderFinal,
                       "when the final text equals the last visible assistant item, the separate final block must not render")
        XCTAssertEqual(inputs.hiddenLiveItemCount, 0, "finished turns hide nothing as live overflow")
    }

    func test_computeTurnRenderInputs_runningTurnKeepsLiveItemsAndNoFinal() {
        let turn = AssistantTurnSnapshot(
            turnId: "live",
            items: [AssistantItem(id: "t", turnId: "live", type: .tool, state: .streaming, startedAtMs: 1_000)],
            finished: false
        )
        let inputs = AgentAppView.computeTurnRenderInputs(
            turn: turn, persistedAssistantTexts: [], proposedPlans: [], running: true)
        XCTAssertEqual(inputs.visibleBlocks.count, 1, "a running turn shows its live item")
        XCTAssertTrue(inputs.completedWorkBlocks.isEmpty, "a running turn has no completed work disclosure")
        XCTAssertFalse(inputs.shouldRenderFinal, "a running turn has no final answer yet")
    }

    func test_computeTurnRenderInputs_filtersPlanItemsWhenPlanCardPresent() {
        let turn = AssistantTurnSnapshot(
            turnId: "turn-p",
            items: [AssistantItem(id: "plan", turnId: "turn-p", type: .plan, state: .completed, body: "1. step", startedAtMs: 1_000, finishedAtMs: 2_000)],
            finished: true
        )
        let plan = AssistantProposedPlan(id: "plan-1", turnId: "turn-p", markdown: "1. step")
        let inputs = AgentAppView.computeTurnRenderInputs(
            turn: turn, persistedAssistantTexts: [], proposedPlans: [plan], running: false)
        XCTAssertEqual(inputs.turnPlans.map(\.id), ["plan-1"], "the turn's proposed plan card is surfaced")
        XCTAssertTrue(inputs.visibleBlocks.isEmpty,
                      "an inline plan item is suppressed when a proposed-plan card already renders it")
    }

    // F2: the finished-turn render signature must invalidate the memo when any external
    // dependency changes (turn items, persisted texts, proposed plans) and stay stable
    // otherwise — so finished turns are served from cache without going stale.
    func test_finishedTurnRenderSignature_invalidationSemantics() {
        let turn = AssistantTurnSnapshot(turnId: "t", items: [
            AssistantItem(id: "a", turnId: "t", type: .tool, startedAtMs: 0)
        ], finished: true)
        let base = AgentAppView.finishedTurnRenderSignature(turn: turn, assistantTextsKey: "m1|x", plansKey: "0|-")
        XCTAssertEqual(base, AgentAppView.finishedTurnRenderSignature(turn: turn, assistantTextsKey: "m1|x", plansKey: "0|-"),
                       "identical inputs must yield an identical signature (a cache hit)")

        let turn2 = AssistantTurnSnapshot(turnId: "t", items: turn.items + [
            AssistantItem(id: "b", turnId: "t", type: .tool, startedAtMs: 1)
        ], finished: true)
        XCTAssertNotEqual(base, AgentAppView.finishedTurnRenderSignature(turn: turn2, assistantTextsKey: "m1|x", plansKey: "0|-"),
                          "an added item must invalidate the cache")
        XCTAssertNotEqual(base, AgentAppView.finishedTurnRenderSignature(turn: turn, assistantTextsKey: "m2|y", plansKey: "0|-"),
                          "a persisted-message change must invalidate the cache (it changes the answer/worklog split)")
        XCTAssertNotEqual(base, AgentAppView.finishedTurnRenderSignature(turn: turn, assistantTextsKey: "m1|x", plansKey: "1|p"),
                          "a proposed-plan change must invalidate the cache")
    }

    // F1: a composer keystroke must publish the composer state ONLY, never the
    // transcript-bearing view model — otherwise the whole transcript subtree
    // re-evaluates on every keypress on a long thread (the reported lag).
    @MainActor
    func test_promptChange_publishesComposerStateNotViewModel() throws {
        let (vm, _) = try makeVM()
        var vmEmissions = 0
        var composerEmissions = 0
        let vmSub = vm.objectWillChange.sink { _ in vmEmissions += 1 }
        let composerSub = vm.composerState.objectWillChange.sink { _ in composerEmissions += 1 }
        defer { vmSub.cancel(); composerSub.cancel() }

        // Simulate two keystrokes via the same proxy the composer binding writes to.
        vm.prompt = "h"
        vm.prompt = "hi"

        XCTAssertEqual(vmEmissions, 0,
                       "typing must NOT republish AgentAppViewModel — that would re-evaluate the whole transcript body per keystroke (F1)")
        XCTAssertGreaterThanOrEqual(composerEmissions, 2,
                                    "each composer text change must publish the composer state so the composer subtree updates")
        XCTAssertEqual(vm.prompt, "hi", "the prompt proxy still reads/writes the composer text")
    }

    // F5: the single-pass cap+budget that replaced `map(cap) + applyBodyBudget` on the
    // thread-open path must be byte-for-byte equivalent to the prior two-pass version.
    func test_cappedRowsWithinBudget_matchesMapThenBudgetComposition() {
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        func msg(_ i: Int, _ content: String) -> AgentMessage {
            AgentMessage(threadId: AgentThreadID(), role: .user, content: content, createdAt: base.addingTimeInterval(Double(i)))
        }
        func reference(_ rows: [AgentMessage], budget: Int) -> (rows: [AgentMessage], blanked: Int) {
            AgentAppViewModel.applyBodyBudget(rows.map { var m = $0; m.content = AssistantTimelineState.cappedText($0.content); return m }, budget: budget)
        }

        // Under budget: caps each body, blanks nothing.
        let small = (0..<5).map { msg($0, "row-\($0)") }
        let fused = AgentAppViewModel.cappedRowsWithinBudget(small, budget: 1_000_000)
        let ref = reference(small, budget: 1_000_000)
        XCTAssertEqual(fused.blanked, 0)
        XCTAssertEqual(fused.rows.map(\.content), ref.rows.map(\.content),
                       "single-pass cap+budget must equal map(cap)+applyBodyBudget under budget")

        // Over budget: blanks the oldest bodies, identically.
        let big = (0..<4).map { msg($0, String(repeating: "x", count: 10)) }
        let fusedBig = AgentAppViewModel.cappedRowsWithinBudget(big, budget: 25)
        let refBig = reference(big, budget: 25)
        XCTAssertGreaterThan(fusedBig.blanked, 0, "a pathological thread must blank oldest bodies")
        XCTAssertEqual(fusedBig.blanked, refBig.blanked)
        XCTAssertEqual(fusedBig.rows.map(\.content), refBig.rows.map(\.content),
                       "single-pass cap+budget must equal map(cap)+applyBodyBudget over budget (oldest blanked)")
    }
}

private final class SlowStartRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var _cancelled = false
    private var _prompts: [String] = []
    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    var prompts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _prompts
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock()
        _prompts.append(request.prompt)
        lock.unlock()
        onEvent(.status(.running))
        try? await Task.sleep(nanoseconds: 100_000_000)
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            self?.lock.lock()
            self?._cancelled = true
            self?.lock.unlock()
        }
    }
}

private final class PendingStartRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var _enteredStart = false
    private var _cancelled = false

    var enteredStart: Bool {
        lock.lock(); defer { lock.unlock() }
        return _enteredStart
    }

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        await withCheckedContinuation { continuation in
            lock.lock()
            _enteredStart = true
            startContinuation = continuation
            lock.unlock()
        }
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            self?.lock.lock()
            self?._cancelled = true
            self?.lock.unlock()
        }
    }

    func releaseStart() {
        lock.lock()
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        continuation?.resume()
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
    let forkSafety: AgentProviderForkSafety
    let readEvents: [AssistantEvent]
    let responseDelayNanoseconds: UInt64
    let forkThreadResult: String
    private let lock = NSLock()
    private var _lastRequestResponse: (threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse)?
    private var _lastUserInputResponse: (threadId: AgentThreadID, requestId: String, text: String)?
    private var _cancelledUserInputs: [(threadId: AgentThreadID, requestId: String)] = []
    private var _stopSessionCount = 0
    private var _forkedThreadIds: [AgentThreadID] = []
    private var _sentTurns: [(threadId: AgentThreadID, providerThreadId: String?, prompt: String)] = []

    var lastRequestResponse: (threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse)? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequestResponse
    }

    var lastUserInputResponse: (threadId: AgentThreadID, requestId: String, text: String)? {
        lock.lock(); defer { lock.unlock() }
        return _lastUserInputResponse
    }

    var cancelledUserInputs: [(threadId: AgentThreadID, requestId: String)] {
        lock.lock(); defer { lock.unlock() }
        return _cancelledUserInputs
    }

    var stopSessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _stopSessionCount
    }

    var forkedThreadIds: [AgentThreadID] {
        lock.lock(); defer { lock.unlock() }
        return _forkedThreadIds
    }

    var sentTurns: [(threadId: AgentThreadID, providerThreadId: String?, prompt: String)] {
        lock.lock(); defer { lock.unlock() }
        return _sentTurns
    }

    init(
        provider: AgentProvider,
        readEvents: [AssistantEvent] = [],
        responseDelayNanoseconds: UInt64 = 0,
        forkThreadResult: String = "provider-child",
        forkSafety: AgentProviderForkSafety = .unsupported
    ) {
        self.provider = provider
        self.readEvents = readEvents
        self.responseDelayNanoseconds = responseDelayNanoseconds
        self.forkThreadResult = forkThreadResult
        self.forkSafety = forkSafety
    }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        recordTurn(request)
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        recordTurn(request)
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        if responseDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: responseDelayNanoseconds)
        }
        lock.lock()
        _lastRequestResponse = (threadId, requestId, response)
        lock.unlock()
    }
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        lock.lock()
        _lastUserInputResponse = (threadId, requestId, text)
        lock.unlock()
    }
    func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {
        lock.lock()
        _cancelledUserInputs.append((threadId, requestId))
        lock.unlock()
    }
    func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        _stopSessionCount += 1
        lock.unlock()
    }
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { true }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { readEvents }
    func forkThread(threadId: AgentThreadID) async throws -> String {
        lock.withLock { _forkedThreadIds.append(threadId) }
        return forkThreadResult
    }
    func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
        lock.withLock { _forkedThreadIds.append(request.sourceThreadId) }
        return forkThreadResult
    }
    func compensateFork(_ request: AgentProviderForkRequest, providerChildThreadId: String) async throws {}
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}

    private func recordTurn(_ request: AgentRunRequest) {
        lock.lock()
        _sentTurns.append((request.threadId, request.providerThreadId, request.prompt))
        lock.unlock()
    }
}

private final class CapturingProviderRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let completionDelayNanoseconds: UInt64
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
    init(provider: AgentProvider, completionDelayNanoseconds: UInt64 = 0) {
        self.provider = provider
        self.completionDelayNanoseconds = completionDelayNanoseconds
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
        let completionDelayNanoseconds = self.completionDelayNanoseconds
        Task.detached {
            if completionDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: completionDelayNanoseconds)
            }
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            onEvent(.status(.completed))
            onEvent(.finished(.completed, finalMessage: nil, providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}
