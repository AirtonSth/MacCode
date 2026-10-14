import XCTest
import CoreModel
@testable import AgentRuntime
import SocketServer
@testable import AppShell

/// What the 60 s account-usage timer costs while the app sits idle: Claude CLI
/// launches and durable `events` rows. Both used to scale with uptime (one
/// `claude -p /usage` of ~3 s CPU / ~450 MB every minute, and six event-log
/// rows a minute that evicted real events from the 5,000-row replay log).
@MainActor
final class AccountUsagePollingCostTests: XCTestCase {
    private actor ScriptedRefresher: ProviderAccountUsageRefreshing {
        var full: [AssistantAccountUsage]
        private(set) var fullRequests: [ProviderAccountUsageRefreshRequest] = []

        init(full: [AssistantAccountUsage]) {
            self.full = full
        }

        func setFull(_ usages: [AssistantAccountUsage]) {
            full = usages
        }

        func refreshAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
            fullRequests.append(request)
            return full
        }

        func grokAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
            nil
        }
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [EventBus.Event] = []

        func append(_ event: EventBus.Event) {
            lock.withLock { storage.append(event) }
        }

        var events: [EventBus.Event] {
            lock.withLock { storage }
        }
    }

    private func savePrivateSession(in context: AppContext) {
        PrivateAccountSessionStore(repo: context.settingsRepo).save(PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid-user",
                subscribed: true
            )
        ))
    }

    /// Runs one periodic tick and waits until its full refresh settles, the
    /// way consecutive timer ticks a minute apart never overlap.
    private func runPeriodicTick(_ context: AppContext) async -> Bool {
        var settled = false
        let observer = NotificationCenter.default.addObserver(
            forName: .rc2AccountUsageRefreshSettled,
            object: nil,
            queue: nil
        ) { _ in settled = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        context.refreshPeriodicAccountUsage()
        let deadline = Date().addingTimeInterval(20)
        while !settled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // Let the Grok half publish its own finished event before the next tick.
        try? await Task.sleep(nanoseconds: 30_000_000)
        return settled
    }

    private func makeSignedInContext(
        refresher: ProviderAccountUsageRefreshing,
        name: String
    ) throws -> AppContext {
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsage\(name)-" + UUID().uuidString
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)
        return context
    }

    /// WHY: with no `~/.claude/.credentials.json` (the macOS norm: Claude Code
    /// keeps its token in the Keychain, which RemoteCode must not read), every
    /// 60 s tick launched a full `claude -p /usage`. Ten idle ticks are ten
    /// minutes of uptime; they may launch the CLI once, not ten times.
    func test_tenIdlePeriodicTicksLaunchTheClaudeUsageCLIOnce() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-claude-usage-ticks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("launches")
        let script = dir.appendingPathComponent("fake-claude")
        try """
        #!/bin/sh
        if [ "$1" = "-p" ]; then
          echo launch >> '\(counter.path)'
          printf 'Current week (all models): 7%% used\\n'
          exit 0
        fi
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // The real refresher, offline: no HTTP, no Codex app-server, no Grok files.
        let context = try makeSignedInContext(
            refresher: ProviderAccountUsageRefresher(timeoutSeconds: 3, jsonAPIFetcher: { _, _ in nil }),
            name: "CLITicks"
        )
        // Never Claude Code's real cache: a fresh one answers without the CLI.
        context.claudeUsageCacheURL = dir.appendingPathComponent("missing-claude.json")
        try context.settingsRepo.set("cli.claude.path", script.path)
        try context.settingsRepo.set("cli.codex.path", dir.appendingPathComponent("missing-codex").path)

        var settledTicks = 0
        for _ in 0..<10 {
            if await runPeriodicTick(context) { settledTicks += 1 }
        }
        let launches = ((try? String(contentsOf: counter, encoding: .utf8)) ?? "")
            .split(separator: "\n").count
        print("[perf-proof] claudeUsageCLI periodic_ticks=\(settledTicks) cli_launches=\(launches)")
        XCTAssertEqual(settledTicks, 10)
        XCTAssertEqual(launches, 1,
                       "ten idle minutes may launch `claude -p /usage` once, not once per tick")
        let claude = ProviderUsageStore(appSupportDirectory: context.appSupportDirectory)
            .load().providers.first { $0.provider == .claude }
        XCTAssertEqual(claude?.weeklyUsedPercent, 7,
                       "the one launch must still land the real Claude percent in the ring")
    }

    /// WHY: the CLI interval must still let a periodic tick reach Claude every
    /// 15 minutes, back off while Claude keeps not answering (signed out, CLI
    /// broken), recover after an answer, and never offer the interactive PTY.
    func test_periodicClaudeCLIProbeRunsEveryIntervalAndBacksOffAfterMisses() async throws {
        let refresher = ScriptedRefresher(full: [
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 10, weeklyWindowDurationMinutes: 10_080)
        ])
        let context = try makeSignedInContext(refresher: refresher, name: "CLIInterval")
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        context.accountUsageNow = { now }
        func tick(atMinute minute: Double) async -> Bool? {
            now = Date(timeIntervalSince1970: 1_800_000_000 + minute * 60)
            let before = await refresher.fullRequests.count
            guard await runPeriodicTick(context) else { return nil }
            let requests = await refresher.fullRequests
            XCTAssertEqual(requests.count, before + 1)
            XCTAssertEqual(requests.last?.allowClaudeUsageScreen, false,
                           "a timer tick never opens the interactive Claude PTY")
            return requests.last?.allowClaudeCLIProbe
        }

        // Claude never answers: each miss doubles the 15 minute gap, capped at 60.
        var allowedAt: [Double] = []
        for minute in stride(from: 0.0, through: 180, by: 5) {
            if await tick(atMinute: minute) == true { allowedAt.append(minute) }
        }
        XCTAssertEqual(allowedAt, [0, 30, 90, 150])

        // One answer resets the interval to 15 minutes.
        await refresher.setFull([
            AssistantAccountUsage(provider: .claude, weeklyUsedPercent: 20, weeklyWindowDurationMinutes: 10_080)
        ])
        let answered = await tick(atMinute: 225)
        XCTAssertEqual(answered, true)
        let early = await tick(atMinute: 235)
        XCTAssertEqual(early, false)
        let next = await tick(atMinute: 240)
        XCTAssertEqual(next, true)

        // An explicit refresh always may probe, with the PTY fallback.
        context.refreshAccountUsage(reason: "details")
        try? await Task.sleep(nanoseconds: 200_000_000)
        let details = await refresher.fullRequests.last
        XCTAssertEqual(details?.allowClaudeCLIProbe, true)
        XCTAssertEqual(details?.allowClaudeUsageScreen, true)
        XCTAssertEqual(details?.claudeUsageCacheURL?.lastPathComponent, ".claude.json")
    }

    /// WHY: a periodic tick that skipped the Claude CLI never asked Claude, so
    /// Claude's missing answer is not proof the account went inactive. Reading
    /// it that way would zero the ring on the Mac and on paired phones.
    func test_periodicTickThatSkipsTheClaudeCLIKeepsClaudesPercent() async throws {
        let refresher = ScriptedRefresher(full: [
            AssistantAccountUsage(provider: .claude, weeklyUsedPercent: 45, weeklyWindowDurationMinutes: 10_080),
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 10, weeklyWindowDurationMinutes: 10_080)
        ])
        let context = try makeSignedInContext(refresher: refresher, name: "SkipKeepsClaude")
        let store = ProviderUsageStore(appSupportDirectory: context.appSupportDirectory)

        // An explicit refresh probes Claude now, so the next ticks fall inside
        // the CLI interval and must skip it.
        var settled = false
        let observer = NotificationCenter.default.addObserver(
            forName: .rc2AccountUsageRefreshSettled, object: nil, queue: nil
        ) { _ in settled = true }
        context.refreshAccountUsage(reason: "details")
        let deadline = Date().addingTimeInterval(5)
        while !settled, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        NotificationCenter.default.removeObserver(observer)
        XCTAssertEqual(store.load().providers.first { $0.provider == .claude }?.weeklyUsedPercent, 45)

        // Claude is absent from the answer, as the real refresher returns it
        // when the CLI is skipped and Claude Code's own cache is stale.
        await refresher.setFull([
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 11, weeklyWindowDurationMinutes: 10_080)
        ])
        for _ in 0..<3 {
            let tickSettled = await runPeriodicTick(context)
            XCTAssertTrue(tickSettled)
        }

        XCTAssertEqual(store.load().providers.first { $0.provider == .codex }?.weeklyUsedPercent, 11)
        XCTAssertEqual(store.load().providers.first { $0.provider == .claude }?.weeklyUsedPercent, 45,
                       "a tick that never ran the Claude CLI must keep Claude's last real percent")
    }

    /// WHY: PL-05. Each idle minute wrote four `agent.account.usage.refresh`
    /// rows and two unchanged `agent.account.usage` rows to the durable,
    /// 5,000-row `events` log: about half of it, evicting the real events a
    /// phone needs for reconnect replay after about 6.5 h. Live subscribers must
    /// still see every refresh and every real change.
    func test_idlePeriodicTicksDoNotFloodTheDurableEventLog() async throws {
        let unchanged = [
            AssistantAccountUsage(provider: .claude, weeklyUsedPercent: 45, weeklyWindowDurationMinutes: 10_080),
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 10, weeklyWindowDurationMinutes: 10_080)
        ]
        let refresher = ScriptedRefresher(full: unchanged)
        let context = try makeSignedInContext(refresher: refresher, name: "EventFlood")

        let log = EventLog()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind.hasPrefix("agent.account.usage"),
                  case .object(let payload) = event.payload,
                  payload["reason"] == .string("periodic") else { return }
            log.append(event)
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        for _ in 0..<10 {
            let settled = await runPeriodicTick(context)
            XCTAssertTrue(settled)
        }
        await refresher.setFull([
            AssistantAccountUsage(provider: .claude, weeklyUsedPercent: 46, weeklyWindowDurationMinutes: 10_080),
            unchanged[1]
        ])
        let changedSettled = await runPeriodicTick(context)
        XCTAssertTrue(changedSettled)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let events = log.events
        let persisted = events.filter { AppDelegate.shouldPersistEvent($0) }
        let refreshFinished = events.filter {
            $0.kind == "agent.account.usage.refresh"
                && $0.payload.objectValue?["state"] == .string("finished")
        }
        let usage = events.filter { $0.kind == "agent.account.usage" }
        print("[perf-proof] accountUsageEvents ticks=11 live=\(events.count) persisted=\(persisted.count) usage=\(usage.count) refresh_finished=\(refreshFinished.count)")

        XCTAssertEqual(refreshFinished.count, 22,
                       "live subscribers still see both halves of every tick finish")
        // First tick: Claude, Codex and the clear of the Grok miss. Then only
        // the one real Claude change.
        XCTAssertEqual(usage.count, 4,
                       "usage is published for the first value per provider and for the one real change")
        XCTAssertEqual(usage.last?.payload.objectValue?["weekly_used_percent"], .number(46))
        XCTAssertEqual(persisted.count, 4,
                       "only real usage changes reach the durable event log")
    }

    /// WHY: a clear tells paired phones the ring is 0%. If the same percent
    /// comes back afterwards, skipping it as "unchanged" would leave the phone
    /// at 0% while the Mac shows the real value.
    func test_usageEqualToTheValueBeforeAClearIsPublishedAgain() async throws {
        let claude = AssistantAccountUsage(provider: .claude, weeklyUsedPercent: 45, weeklyWindowDurationMinutes: 10_080)
        let codex = AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 10, weeklyWindowDurationMinutes: 10_080)
        let refresher = ScriptedRefresher(full: [claude, codex])
        let context = try makeSignedInContext(refresher: refresher, name: "ClearRepublish")

        let log = EventLog()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.account.usage",
                  event.payload.objectValue?["provider"] == .string("claude") else { return }
            log.append(event)
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        let first = await runPeriodicTick(context)
        XCTAssertTrue(first)
        // An explicit refresh that probed Claude and got no answer clears it.
        await refresher.setFull([codex])
        var settled = false
        let observer = NotificationCenter.default.addObserver(
            forName: .rc2AccountUsageRefreshSettled, object: nil, queue: nil
        ) { _ in settled = true }
        context.refreshAccountUsage(reason: "details")
        let deadline = Date().addingTimeInterval(5)
        while !settled, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        NotificationCenter.default.removeObserver(observer)

        await refresher.setFull([claude, codex])
        let again = await runPeriodicTick(context)
        XCTAssertTrue(again)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let percents = log.events.compactMap { $0.payload.objectValue?["weekly_used_percent"] }
        XCTAssertEqual(percents, [.number(45), .number(0), .number(45)],
                       "after a clear the same percent must reach paired devices again")
    }
}
