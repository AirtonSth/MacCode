import XCTest
import AppKit
import CoreModel
@testable import AgentRuntime
import Persistence
import SocketServer
@testable import AppShell

/// Provider account usage (quota rings, `agent.account.usage`, the iOS digest):
/// refresh, partial-refresh clearing, periodic Grok coalescing and the
/// refresh watchdog.
@MainActor
final class AccountUsageAppContextTests: XCTestCase {
    private final class LockedEventCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private actor FakeAccountUsageRefresher: ProviderAccountUsageRefreshing {
        let response: [AssistantAccountUsage]
        private(set) var requests: [ProviderAccountUsageRefreshRequest] = []

        init(response: [AssistantAccountUsage]) {
            self.response = response
        }

        func refreshAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
            requests.append(request)
            return response
        }
    }

    private actor PeriodicAccountUsageRefresher: ProviderAccountUsageRefreshing {
        private let fullDelayNanoseconds: UInt64
        private let grokDelayNanoseconds: UInt64
        private let fullResponse: [AssistantAccountUsage]
        private let grokResponse: AssistantAccountUsage?
        private(set) var fullRequests: [ProviderAccountUsageRefreshRequest] = []
        private(set) var grokRequests: [ProviderAccountUsageRefreshRequest] = []

        init(
            fullDelayNanoseconds: UInt64 = 0,
            grokDelayNanoseconds: UInt64 = 0,
            fullResponse: [AssistantAccountUsage] = [],
            grokResponse: AssistantAccountUsage? = nil
        ) {
            self.fullDelayNanoseconds = fullDelayNanoseconds
            self.grokDelayNanoseconds = grokDelayNanoseconds
            self.fullResponse = fullResponse
            self.grokResponse = grokResponse
        }

        func refreshAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
            fullRequests.append(request)
            if fullDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: fullDelayNanoseconds)
            }
            return fullResponse
        }

        func grokAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
            grokRequests.append(request)
            if grokDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: grokDelayNanoseconds)
            }
            return grokResponse
        }
    }

    private actor OutOfOrderGrokAccountUsageRefresher: ProviderAccountUsageRefreshing {
        private var grokRequestCount = 0
        var requestCount: Int { grokRequestCount }

        func refreshAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
            []
        }

        func grokAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
            grokRequestCount += 1
            let ordinal = grokRequestCount
            try? await Task.sleep(nanoseconds: ordinal == 1 ? 150_000_000 : 20_000_000)
            return AssistantAccountUsage(
                provider: .grok,
                weeklyUsedPercent: ordinal == 1 ? 20 : 80,
                weeklyWindowDurationMinutes: 10_080
            )
        }
    }

    private actor CrossTickAccountUsageRefresher: ProviderAccountUsageRefreshing {
        private(set) var fullRequestCount = 0
        private(set) var grokRequestCount = 0

        func refreshAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
            fullRequestCount += 1
            let ordinal = fullRequestCount
            try? await Task.sleep(nanoseconds: ordinal == 1 ? 10_000_000 : 220_000_000)
            guard ordinal == 2 else { return [] }
            return [AssistantAccountUsage(
                provider: .codex,
                weeklyUsedPercent: 23,
                weeklyWindowDurationMinutes: 10_080
            )]
        }

        func grokAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
            grokRequestCount += 1
            try? await Task.sleep(nanoseconds: 120_000_000)
            return nil
        }
    }

    private actor OutOfOrderFullGrokAccountUsageRefresher: ProviderAccountUsageRefreshing {
        private(set) var fullRefreshStarted = false

        func refreshAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
            fullRefreshStarted = true
            try? await Task.sleep(nanoseconds: 150_000_000)
            return [AssistantAccountUsage(
                provider: .grok,
                weeklyUsedPercent: 20,
                weeklyWindowDurationMinutes: 10_080
            )]
        }

        func grokAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
            try? await Task.sleep(nanoseconds: 20_000_000)
            return AssistantAccountUsage(
                provider: .grok,
                weeklyUsedPercent: 80,
                weeklyWindowDurationMinutes: 10_080
            )
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func savePrivateSession(in context: AppContext, subscribed: Bool = true) {
        PrivateAccountSessionStore(repo: context.settingsRepo).save(PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: subscribed ? "paid@example.com" : "unpaid@example.com",
                id: subscribed ? "paid-user" : "unpaid-user",
                subscribed: subscribed
            )
        ))
    }

    func test_appContextRefreshesAccountUsageFromProviderCommands() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageAccountUsage-" + UUID().uuidString
        let refresher = FakeAccountUsageRefresher(response: [
            AssistantAccountUsage(provider: .claude, weeklyUsedPercent: 57, weeklyWindowDurationMinutes: 10_080, currentSessionUsedPercent: 3),
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 34, weeklyWindowDurationMinutes: 10_080, currentSessionUsedPercent: 13)
        ])
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshAccountUsage(reason: "test")

        let didPersist = await waitUntil {
            let snapshot = ProviderUsageStore(appSupportDirectory: context.appSupportDirectory).load()
            let claude = snapshot.providers.first { $0.provider == .claude }
            let codex = snapshot.providers.first { $0.provider == .codex }
            return claude?.weeklyUsedPercent == 57
                && claude?.currentSessionUsedPercent == 3
                && codex?.weeklyUsedPercent == 34
                && codex?.currentSessionUsedPercent == 13
        }
        XCTAssertTrue(didPersist,
                      "startup/details/periodic refresh must persist real provider weekly percentages for the usage rings")
        XCTAssertEqual(context.accountUsageRefreshCount, 1)
        let requests = await refresher.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.codexBinary, "codex")
        XCTAssertEqual(requests.first?.claudeBinary, "claude")
    }

    /// WHY: Claude left inactive must not keep a frozen weekly ring after a
    /// partial refresh still succeeds for Codex/Grok.
    func test_appContextClearsMissingProviderAccountUsageOnPartialRefresh() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageClearMissing-" + UUID().uuidString
        let store = ProviderUsageStore(appSupportDirectory: URL(fileURLWithPath: appSupport))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: appSupport).appendingPathComponent("TokenSaver", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try store.recordAccountUsage(provider: .claude, weeklyUsedPercent: 45, weeklyWindowDurationMinutes: 10_080)
        _ = try store.recordAccountUsage(provider: .codex, weeklyUsedPercent: 10, weeklyWindowDurationMinutes: 10_080)

        let refresher = FakeAccountUsageRefresher(response: [
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 23, weeklyWindowDurationMinutes: 10_080),
            AssistantAccountUsage(provider: .grok, weeklyUsedPercent: 59, weeklyWindowDurationMinutes: 10_080)
        ])
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshAccountUsage(reason: "test")

        let didClear = await waitUntil {
            let snapshot = ProviderUsageStore(appSupportDirectory: context.appSupportDirectory).load()
            let claude = snapshot.providers.first { $0.provider == .claude }
            let codex = snapshot.providers.first { $0.provider == .codex }
            let grok = snapshot.providers.first { $0.provider == .grok }
            return claude?.weeklyUsedPercent == 0
                && codex?.weeklyUsedPercent == 23
                && grok?.weeklyUsedPercent == 59
        }
        XCTAssertTrue(didClear,
                      "partial refresh without Claude must zero Claude's frozen weekly % while updating the live providers")
    }

    /// WHY: Grok frequently painted Used 0% after Codex-only partial refreshes
    /// even though the SuperGrok weekly window was still open. A flaky billing
    /// log miss must keep the last live percent until the window expires.
    func test_appContextKeepsUnexpiredGrokPercentWhenMissingFromPartialRefresh() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageKeepGrok-" + UUID().uuidString
        let store = ProviderUsageStore(appSupportDirectory: URL(fileURLWithPath: appSupport))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: appSupport).appendingPathComponent("TokenSaver", isDirectory: true),
            withIntermediateDirectories: true
        )
        let futureReset = Date().addingTimeInterval(3 * 24 * 3600)
        _ = try store.recordAccountUsage(
            provider: .grok,
            weeklyUsedPercent: 65,
            weeklyWindowDurationMinutes: 10_080,
            weeklyResetsAt: futureReset
        )
        _ = try store.recordAccountUsage(provider: .codex, weeklyUsedPercent: 10, weeklyWindowDurationMinutes: 10_080)

        let refresher = FakeAccountUsageRefresher(response: [
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 71, weeklyWindowDurationMinutes: 10_080)
        ])
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshAccountUsage(reason: "test")

        let didKeep = await waitUntil {
            let snapshot = ProviderUsageStore(appSupportDirectory: context.appSupportDirectory).load()
            let grok = snapshot.providers.first { $0.provider == .grok }
            let codex = snapshot.providers.first { $0.provider == .codex }
            return grok?.weeklyUsedPercent == 65 && codex?.weeklyUsedPercent == 71
        }
        XCTAssertTrue(didKeep,
                      "partial refresh that omits Grok must keep Grok's unexpired weekly % instead of painting 0%")
    }

    /// WHY: the `.accountUsage` event path and the 60 s periodic probe share the
    /// same write site (`AppContext.recordAccountUsage`), so a provider
    /// that re-reports the same percentages used to rewrite usage.json from the
    /// MainActor on every event. The ring must still follow a real change.
    func test_accountUsageEventsWithUnchangedPercentagesWriteUsageOnce() throws {
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageUsageNoop-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let threadId = AgentThreadID()
        let runId = AgentRunID()
        let file = context.appSupportDirectory
            .appendingPathComponent("TokenSaver", isDirectory: true)
            .appendingPathComponent("usage.json", isDirectory: false)
        let unchanged = AssistantAccountUsage(
            provider: .claude,
            weeklyUsedPercent: 57,
            weeklyWindowDurationMinutes: 10_080,
            currentSessionUsedPercent: 3
        )

        context.coordinator.onAssistantEvent?(.accountUsage(unchanged), threadId, runId)
        let writtenAt = try usageFileModificationDate(of: file)
        for _ in 0..<10 {
            context.coordinator.onAssistantEvent?(.accountUsage(unchanged), threadId, runId)
        }
        XCTAssertEqual(
            try usageFileModificationDate(of: file),
            writtenAt,
            "ten re-reported account-usage events must not rewrite usage.json ten times"
        )

        context.coordinator.onAssistantEvent?(
            .accountUsage(AssistantAccountUsage(
                provider: .claude,
                weeklyUsedPercent: 58,
                weeklyWindowDurationMinutes: 10_080,
                currentSessionUsedPercent: 3
            )),
            threadId,
            runId
        )
        XCTAssertGreaterThan(
            try usageFileModificationDate(of: file),
            writtenAt,
            "a changed percentage must reach usage.json"
        )
        XCTAssertEqual(
            ProviderUsageStore(appSupportDirectory: context.appSupportDirectory)
                .load().providers.first { $0.provider == .claude }?.weeklyUsedPercent,
            58
        )
    }

    private func usageFileModificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    func test_appContextSkipsAccountUsageRefreshWhenNotSignedIn() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageNoAccountUsage-" + UUID().uuidString
        let refresher = FakeAccountUsageRefresher(response: [
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 34)
        ])
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )

        context.refreshAccountUsage(reason: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(context.accountUsageRefreshCount, 0)
        let requests = await refresher.requests
        XCTAssertTrue(requests.isEmpty,
                      "provider limit commands must not run before a RemoteCode private account is signed in")
    }

    func test_accountUsageRefreshIntervalIsOneMinute() {
        XCTAssertEqual(AppDelegate.accountUsageRefreshInterval, 60)
    }

    func test_periodicAccountUsageRunsOneGrokProbeAndCoalescesAnOverlappingTick() async throws {
        // WHY: the periodic timer used to launch a dedicated Grok probe and then
        // include Grok again in the full refresh. An overlapping tick could add a
        // third probe. That wastes network/CPU while the purple ring only needs one.
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsagePeriodicUsage-" + UUID().uuidString
        let refresher = PeriodicAccountUsageRefresher(
            fullDelayNanoseconds: 100_000_000,
            grokDelayNanoseconds: 100_000_000
        )
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshPeriodicAccountUsage()
        context.refreshPeriodicAccountUsage()
        try? await Task.sleep(nanoseconds: 250_000_000)

        let fullRequests = await refresher.fullRequests
        let grokRequests = await refresher.grokRequests
        XCTAssertEqual(fullRequests.count, 1,
                       "the existing full-refresh single flight must coalesce an overlapping periodic tick")
        XCTAssertEqual(fullRequests.first?.includeGrok, false,
                       "the dedicated Grok probe must be the only Grok work in a periodic cycle")
        XCTAssertEqual(grokRequests.count, 1,
                       "the Grok-specific path must also be single flight across overlapping ticks")
    }

    func test_periodicCycleSurvivesSecondTickWhileFullRefreshIsStillBusy() async throws {
        // WHY: Grok often finishes before the full refresh. A new timer tick must
        // not orphan the successful full result that proves a Grok miss may clear.
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageCrossTickUsage-" + UUID().uuidString
        let store = ProviderUsageStore(appSupportDirectory: URL(fileURLWithPath: appSupport))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: appSupport).appendingPathComponent("TokenSaver", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try store.recordAccountUsage(
            provider: .grok,
            weeklyUsedPercent: 65,
            weeklyWindowDurationMinutes: 10_080
        )
        let refresher = PeriodicAccountUsageRefresher(
            fullDelayNanoseconds: 220_000_000,
            grokDelayNanoseconds: 10_000_000,
            fullResponse: [
                AssistantAccountUsage(
                    provider: .codex,
                    weeklyUsedPercent: 23,
                    weeklyWindowDurationMinutes: 10_080
                )
            ]
        )
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshPeriodicAccountUsage()
        try? await Task.sleep(nanoseconds: 60_000_000)
        context.refreshPeriodicAccountUsage()

        let didReconcile = await waitUntil {
            let providers = store.load().providers
            return providers.first { $0.provider == .codex }?.weeklyUsedPercent == 23
                && providers.first { $0.provider == .grok }?.weeklyUsedPercent == 0
        }
        XCTAssertTrue(didReconcile,
                      "the first full result must reconcile its Grok miss even after the next timer tick")
        let fullRequests = await refresher.fullRequests
        let grokRequests = await refresher.grokRequests
        XCTAssertEqual(fullRequests.count, 1,
                       "the second full refresh must coalesce while the first remains in flight")
        XCTAssertEqual(grokRequests.count, 2,
                       "each non-overlapping timer tick may still refresh Grok once")
    }

    func test_periodicCycleTracksAReplacementFullRefreshAcrossThirdTick() async throws {
        // WHY: a second full refresh can start while the first Grok probe is
        // still running. A third tick must not orphan that healthier full result.
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageCrossTickFull-" + UUID().uuidString
        let store = ProviderUsageStore(appSupportDirectory: URL(fileURLWithPath: appSupport))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: appSupport).appendingPathComponent("TokenSaver", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try store.recordAccountUsage(
            provider: .grok,
            weeklyUsedPercent: 65,
            weeklyWindowDurationMinutes: 10_080
        )
        let refresher = CrossTickAccountUsageRefresher()
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshPeriodicAccountUsage()
        try? await Task.sleep(nanoseconds: 40_000_000)
        context.refreshPeriodicAccountUsage()
        try? await Task.sleep(nanoseconds: 130_000_000)
        context.refreshPeriodicAccountUsage()

        let didReconcile = await waitUntil {
            let providers = store.load().providers
            return providers.first { $0.provider == .codex }?.weeklyUsedPercent == 23
                && providers.first { $0.provider == .grok }?.weeklyUsedPercent == 0
        }
        let fullRequestCount = await refresher.fullRequestCount
        XCTAssertTrue(didReconcile,
                      "the replacement full result must remain attached to the Grok miss across tick three")
        XCTAssertEqual(fullRequestCount, 2,
                       "the third full refresh must coalesce while replacement full work is in flight")
    }

    func test_periodicGrokResultRepublishesTheRemoteWidgetDigest() async throws {
        // WHY: the full periodic refresh deliberately excludes Grok. If that
        // faster branch publishes first, the later Grok result must replace the
        // cached remote digest instead of leaving iOS on the previous percent.
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageGrokDigest-" + UUID().uuidString
        let refresher = PeriodicAccountUsageRefresher(
            fullDelayNanoseconds: 10_000_000,
            grokDelayNanoseconds: 150_000_000,
            fullResponse: [
                AssistantAccountUsage(
                    provider: .codex,
                    weeklyUsedPercent: 23,
                    weeklyWindowDurationMinutes: 10_080
                )
            ],
            grokResponse: AssistantAccountUsage(
                provider: .grok,
                weeklyUsedPercent: 80,
                weeklyWindowDurationMinutes: 10_080
            )
        )
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshPeriodicAccountUsage()

        let didPublishFreshGrok = await waitUntil {
            guard let body = AccountUsageWidgetDigest.lastCachedBody(),
                  case .object(let week)? = body["week"] else { return false }
            return week["grok_used_percent"] == .number(80)
        }
        XCTAssertTrue(didPublishFreshGrok,
                      "the only Grok result in the tick must refresh the digest after the full branch")
    }

    func test_periodicFastGrokAndSlowFullPublishOneWidgetDigest() async throws {
        // WHY: the optimization must not trade one duplicate provider probe for
        // duplicate JSON/SQLite digest work on the MainActor.
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageDigestSingleFlight-" + UUID().uuidString
        let refresher = PeriodicAccountUsageRefresher(
            fullDelayNanoseconds: 150_000_000,
            grokDelayNanoseconds: 10_000_000,
            fullResponse: [
                AssistantAccountUsage(
                    provider: .codex,
                    weeklyUsedPercent: 23,
                    weeklyWindowDurationMinutes: 10_080
                )
            ],
            grokResponse: AssistantAccountUsage(
                provider: .grok,
                weeklyUsedPercent: 80,
                weeklyWindowDurationMinutes: 10_080
            )
        )
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)
        // EV-25: the digest dedupe is process-global; an identical body from an
        // earlier test must not suppress this test's single publish.
        AccountUsageWidgetDigest.resetLastBodyForTesting()
        let digestEvents = LockedEventCount()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == AccountUsageWidgetDigest.eventKind.rawValue {
                digestEvents.increment()
            }
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        context.refreshPeriodicAccountUsage()
        let didFinish = await waitUntil {
            ProviderUsageStore(appSupportDirectory: context.appSupportDirectory)
                .load().providers.first { $0.provider == .codex }?.weeklyUsedPercent == 23
        }

        XCTAssertTrue(didFinish)
        // EV-25 publishes from a detached task; wait for the first publish, then
        // give a duplicate a chance to show up before asserting exactly one.
        let published = await waitUntil { digestEvents.value >= 1 }
        XCTAssertTrue(published, "the final disk digest must be published")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(digestEvents.value, 1,
                       "Grok-first/full-second must publish the final disk digest exactly once")
    }

    func test_periodicFullRefreshDoesNotClearGrokThatItDeliberatelyExcluded() async throws {
        // WHY: omitting the duplicate Grok probe must not make the partial-result
        // cleanup interpret Grok as signed out before the dedicated probe returns.
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsagePeriodicKeepGrok-" + UUID().uuidString
        let store = ProviderUsageStore(appSupportDirectory: URL(fileURLWithPath: appSupport))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: appSupport).appendingPathComponent("TokenSaver", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try store.recordAccountUsage(
            provider: .grok,
            weeklyUsedPercent: 65,
            weeklyWindowDurationMinutes: 10_080
        )
        let refresher = FakeAccountUsageRefresher(response: [
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 23, weeklyWindowDurationMinutes: 10_080)
        ])
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshAccountUsage(reason: "periodic", includeGrok: false)

        let didPersist = await waitUntil {
            let providers = store.load().providers
            let codex = providers.first { $0.provider == .codex }
            let grok = providers.first { $0.provider == .grok }
            return codex?.weeklyUsedPercent == 23 && grok?.weeklyUsedPercent == 65
        }
        XCTAssertTrue(didPersist,
                      "cleanup may only clear providers included in the current probe set")
    }

    func test_totalPeriodicOutageKeepsAnUnprotectedStaleGrokRing() async throws {
        // WHY: a completely empty refresh is noise, not proof Grok signed out.
        // Removing the duplicate probe must preserve that baseline contract.
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageGrokMissUsage-" + UUID().uuidString
        let store = ProviderUsageStore(appSupportDirectory: URL(fileURLWithPath: appSupport))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: appSupport).appendingPathComponent("TokenSaver", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try store.recordAccountUsage(
            provider: .grok,
            weeklyUsedPercent: 65,
            weeklyWindowDurationMinutes: 10_080
        )
        let refresher = PeriodicAccountUsageRefresher()
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshPeriodicAccountUsage()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.load().providers.first { $0.provider == .grok }?.weeklyUsedPercent, 65,
                       "full empty plus dedicated nil must retain the last known value")
    }

    func test_partialPeriodicSuccessClearsAnUnprotectedGrokMiss() async throws {
        // WHY: when Codex/Claude prove the refresh is healthy but the one Grok
        // probe misses, preserve the old clear-if-no-live-window behavior.
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageGrokPartialUsage-" + UUID().uuidString
        let store = ProviderUsageStore(appSupportDirectory: URL(fileURLWithPath: appSupport))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: appSupport).appendingPathComponent("TokenSaver", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try store.recordAccountUsage(
            provider: .grok,
            weeklyUsedPercent: 65,
            weeklyWindowDurationMinutes: 10_080
        )
        let refresher = PeriodicAccountUsageRefresher(fullResponse: [
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 23, weeklyWindowDurationMinutes: 10_080)
        ])
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshPeriodicAccountUsage()

        let didClear = await waitUntil {
            let providers = store.load().providers
            return providers.first { $0.provider == .codex }?.weeklyUsedPercent == 23
                && providers.first { $0.provider == .grok }?.weeklyUsedPercent == 0
        }
        XCTAssertTrue(didClear,
                      "a partial healthy cycle may clear an unprotected Grok miss exactly once")
    }

    func test_newerRunFinishedGrokResultWinsWhenPeriodicCompletesLater() async throws {
        // WHY: run-finished is fresher than an already-running periodic probe.
        // Without a generation guard, the older 20% response overwrote 80% last.
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageRunFinishedUsage-" + UUID().uuidString
        let refresher = OutOfOrderGrokAccountUsageRefresher()
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshPeriodicAccountUsage()
        for _ in 0..<50 {
            if await refresher.requestCount > 0 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let periodicRequestCount = await refresher.requestCount
        XCTAssertEqual(periodicRequestCount, 1, "fixture must start the slow periodic probe first")
        context.refreshGrokAccountUsage(reason: "run_finished")
        try? await Task.sleep(nanoseconds: 250_000_000)

        let usage = ProviderUsageStore(appSupportDirectory: context.appSupportDirectory)
            .load().providers.first { $0.provider == .grok }
        XCTAssertEqual(usage?.weeklyUsedPercent, 80,
                       "an older periodic response must not overwrite the newer run-finished snapshot")
    }

    func test_newerRunFinishedGrokResultWinsWhenFullRefreshCompletesLater() async throws {
        // WHY: launch/details full refreshes also carry Grok. Their older result
        // must obey the same generation as the dedicated path.
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageFullGrokGeneration-" + UUID().uuidString
        let refresher = OutOfOrderFullGrokAccountUsageRefresher()
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            accountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshAccountUsage(reason: "details")
        for _ in 0..<50 {
            if await refresher.fullRefreshStarted { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let fullStarted = await refresher.fullRefreshStarted
        XCTAssertTrue(fullStarted, "fixture must start the slow full refresh first")
        context.refreshGrokAccountUsage(reason: "run_finished")
        try? await Task.sleep(nanoseconds: 250_000_000)

        let usage = ProviderUsageStore(appSupportDirectory: context.appSupportDirectory)
            .load().providers.first { $0.provider == .grok }
        XCTAssertEqual(usage?.weeklyUsedPercent, 80,
                       "an older full-refresh result must not overwrite newer Grok usage")
    }

    func test_appContextRefreshesGrokAccountUsageFromBillingLogAfterRun() async throws {
        // WHY: Grok ACP never emits live `.accountUsage`, so the usage
        // purple ring stayed stale between periodic probes. After
        // a Grok run finishes we re-read the local billing log; this pins that
        // the lightweight path persists creditUsagePercent without Claude/Codex.
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageGrokRunUsage-" + UUID().uuidString
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-billing-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDir) }
        let log = logDir.appendingPathComponent("unified.jsonl")
        let body = """
        {"msg":"noise"}
        {"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":61.0,"billingPeriodEnd":"2099-07-22T20:46:41.975270+00:00"}}}
        """
        try body.write(to: log, atomically: true, encoding: .utf8)

        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        savePrivateSession(in: context)

        context.refreshGrokAccountUsage(reason: "run_finished", billingLogURL: log)

        let didPersist = await waitUntil {
            let snapshot = ProviderUsageStore(appSupportDirectory: context.appSupportDirectory).load()
            return snapshot.providers.first(where: { $0.provider == .grok })?.weeklyUsedPercent == 61
        }
        XCTAssertTrue(didPersist,
                      "post-run Grok billing-log refresh must write weeklyUsedPercent so the purple ring updates without waiting for the periodic probe")
    }

    func test_appContextSkipsGrokBillingLogRefreshWhenNotSignedIn() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageGrokNoAccount-" + UUID().uuidString
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-billing-signedout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDir) }
        let log = logDir.appendingPathComponent("unified.jsonl")
        try #"{"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":88.0}}}"#
            .write(to: log, atomically: true, encoding: .utf8)

        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        context.refreshGrokAccountUsage(reason: "run_finished", billingLogURL: log)
        try? await Task.sleep(nanoseconds: 80_000_000)

        let snapshot = ProviderUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        XCTAssertNil(snapshot.providers.first(where: { $0.provider == .grok })?.weeklyUsedPercent,
                     "signed-out sessions must not probe or persist Grok billing usage")
    }


    func test_refreshAccountUsageWithTimeoutReturnsRealResultAndDoesNotReturnEmptyOnFastRefresher() async {
        // WHY: the watchdog task must be cancelled when the work completes normally.
        // Before this fix the watchdog lingered for 60 s per call; now it is cancelled
        // inside resume() on the first winner. This test pins that a fast refresher
        // returns the real result (not []) and completes well within the tight
        // timeoutNanoseconds budget, proving the normal-finish path is hit.
        let expected = [
            AssistantAccountUsage(provider: .claude, weeklyUsedPercent: 42)
        ]
        let refresher = FakeAccountUsageRefresher(response: expected)
        let request = ProviderAccountUsageRefreshRequest(codexBinary: "codex", claudeBinary: "claude")

        // 5-second timeout: more than enough for an in-process fake; tight enough that
        // a regression returning [] (watchdog fires first) would be caught quickly.
        let result = await AppContext.refreshAccountUsageWithTimeout(
            refresher: refresher,
            request: request,
            timeoutNanoseconds: 5_000_000_000
        )

        XCTAssertEqual(result.count, 1, "fast refresher must return the real result, not the timeout empty fallback")
        XCTAssertEqual(result.first?.provider, .claude)
        XCTAssertEqual(result.first?.weeklyUsedPercent, 42,
                       "watchdog cancellation on normal completion must not discard the real usage data")
    }

    func test_refreshAccountUsageWithTimeoutReturnsEmptyWhenWorkExceedsTimeout() async {
        // WHY: the timeout path must still fire if work hangs; returning [] is the
        // correct sentinel that the caller treats as "no data this cycle".
        struct HangingRefresher: ProviderAccountUsageRefreshing {
            func refreshAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
                // Simulate a hang; respect cooperative cancellation so the test finishes.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return [AssistantAccountUsage(provider: .claude, weeklyUsedPercent: 99)]
            }
        }

        // 10 ms timeout: work hangs => watchdog fires => returns [].
        let result = await AppContext.refreshAccountUsageWithTimeout(
            refresher: HangingRefresher(),
            request: ProviderAccountUsageRefreshRequest(codexBinary: "codex", claudeBinary: "claude"),
            timeoutNanoseconds: 10_000_000
        )

        XCTAssertTrue(result.isEmpty,
                      "when work exceeds the watchdog timeout the function must return [] so the caller skips this cycle")
    }

}
