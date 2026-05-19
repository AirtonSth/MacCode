import XCTest
@testable import AppShell
@testable import AgentRuntime
@testable import CoreModel
@testable import SocketServer
@testable import Persistence

/// Intent: v2 must be packaged as RemoteCode, with the legacy desktop
/// bundle identifier and icon, so users can install it as an update.
@MainActor
final class AppIdentityNotificationTests: XCTestCase {
    func testReleaseChannelUsesLegacyRemoteCodeDesktopIdentity() {
        XCTAssertEqual(ReleaseChannel.stable.bundleID, "io.remotecode.desktop")
        XCTAssertEqual(ReleaseChannel.stable.displayName, "RemoteCode")
        XCTAssertEqual(ReleaseChannel.debug.displayName, "RemoteCodeDebug")
    }

    func testPackageScriptBuildsRemoteCodeAppWithLegacyIcon() throws {
        let script = try String(contentsOf: packageScriptURL())

        XCTAssertTrue(script.contains("BUNDLE=\"RemoteCode.app\""))
        XCTAssertTrue(script.contains("BUNDLE_ID=\"${RC2_BUNDLE_ID:-io.remotecode.desktop}\""))
        XCTAssertTrue(script.contains("<key>CFBundleDisplayName</key><string>RemoteCode</string>"))
        XCTAssertTrue(script.contains("<key>CFBundleIconFile</key><string>AppIcon</string>"))
        XCTAssertTrue(script.contains("AppIcon.icns"))
    }

    func testThreadOutcomeNotificationContentMatchesLegacyActionablePhases() {
        XCTAssertNil(RemoteCodeNotificationContent.threadOutcome(
            threadId: "t1",
            title: "Build fix",
            phase: .running
        ))

        let completed = RemoteCodeNotificationContent.threadOutcome(
            threadId: "t1",
            title: "Build fix",
            phase: .completed
        )
        XCTAssertEqual(completed?.title, "Thread finished")
        XCTAssertEqual(completed?.body, "Build fix response is ready.")
        XCTAssertEqual(completed?.categoryIdentifier, "RemoteCodeThreadUpdate")
        XCTAssertEqual(completed?.userInfo["threadId"], "t1")
    }

    func testForegroundNotificationsStayInAppOnly() {
        XCTAssertEqual(SystemNotifier.presentationOptions(appIsForeground: true), [],
                       "foreground clients must update the in-app feed without showing a system push")
        XCTAssertEqual(SystemNotifier.presentationOptions(appIsForeground: false), [.banner, .list, .sound],
                       "push presentation is reserved for background or closed app states")
    }

    func testStreamingErrorsDoNotEmitTerminalRunNotificationsBeforeFinish() async throws {
        let dir = NSTemporaryDirectory() + "RC2Notify-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        ctx.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(provider: .codex, scenario: .error(message: "stderr chunk")))
        let thread = AgentThread(title: "Notify once", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)

        let startSeq = EventBus.shared.snapshot().lastSeq
        var events: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: startSeq) { event in
            if event.kind.hasPrefix("agent.run.") { events.append(event) }
        }
        defer { EventBus.shared.unsubscribe(token) }

        _ = try await ctx.coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: dir,
            prompt: "fail once"
        ))
        await waitAsync("fake failure finishes") {
            events.contains { $0.kind == "agent.run.finished" }
        }

        XCTAssertEqual(events.filter { $0.kind == "agent.run.failed" }.count, 1,
                       "thread notifications are driven by terminal outcomes; streaming errors must not look like extra finishes")
    }

    func testAgentMessageAppendEventsCarryDurableChatHistoryToMirrors() async throws {
        let dir = NSTemporaryDirectory() + "RC2MessageEvents-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        ctx.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: "persisted answer")))
        let thread = AgentThread(title: "Mirror history", provider: .codex, model: "fake-model")
        try ctx.threadRepo.upsert(thread)

        let startSeq = EventBus.shared.snapshot().lastSeq
        var events: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: startSeq) { event in
            if event.kind == "agent.message.appended" { events.append(event) }
        }
        defer { EventBus.shared.unsubscribe(token) }

        _ = try await ctx.coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: dir,
            prompt: "first prompt"
        ))
        await waitAsync("durable user and assistant messages are mirrored") {
            events.count >= 2
        }

        XCTAssertTrue(events.contains { event in
            guard case .object(let payload) = event.payload else { return false }
            return payload["role"] == .string("user") && payload["content"] == .string("first prompt")
        }, "the iOS mirror must receive the persisted user message, not only transient stream state")
        XCTAssertTrue(events.contains { event in
            guard case .object(let payload) = event.payload else { return false }
            return payload["role"] == .string("assistant") && payload["content"] == .string("persisted answer")
        }, "the iOS mirror must receive the persisted assistant answer before a follow-up clears live stream state")
    }

    func testHostSendTitlesPlaceholderThreadFromFullFirstUserMessage() async throws {
        let dir = NSTemporaryDirectory() + "RC2ThreadTitle-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        ctx.coordinator.replaceProvider(.claude, runner: FakeProviderRunner(provider: .claude, scenario: .simpleAssistant(reply: "ok")))
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let thread = AgentThread(title: "Thread", provider: .claude, model: "fake-model")
        try ctx.threadRepo.upsert(thread)

        let firstMessage = "git add commit and push all repos here with this long exact wording"
        _ = try await router.sendAgentMessage(
            thread: thread.id,
            text: firstMessage,
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil
        )

        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.title, firstMessage,
                       "if the agent/client never names a thread, the stored title must be the full first user message")
        XCTAssertEqual(AgentThreadTitle.display(firstMessage),
                       "git add commit and push all ...",
                       "display truncation must be separate from the stored full title")
    }

    func testCodexWarningsAreNotUserVisibleErrors() {
        let warning = "[codex stderr] 2026-05-18T19:27:58Z WARN codex_core_plugins::manifest: ignoring interface.defaultPrompt"

        XCTAssertFalse(CodexRunner.shouldDisplayStderr(warning),
                       "Codex WARN stderr is diagnostic noise; showing it in the transcript makes a healthy run look broken")
        XCTAssertFalse(CodexRunner.shouldDisplayStderr("[codex stderr] Reading additional input from stdin..."),
                       "Codex stdin diagnostics are run noise, not agent progress or a user-visible error")
        XCTAssertTrue(CodexRunner.shouldDisplayStderr("[codex stderr] fatal: authentication failed"),
                      "non-warning stderr must remain visible so real failures are not hidden")
    }

    private func packageScriptURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/package-app.sh")
    }

    private func waitAsync(_ desc: String, timeout: TimeInterval = 6, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(desc)")
    }
}
