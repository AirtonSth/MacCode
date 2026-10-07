import XCTest
import AgentRuntime
import CoreModel
import RemoteCodeTreaty
@testable import SocketServer
@testable import AppShell

/// WHY: on connect the iPhone asks the Mac for the account usage it already
/// stored so the rings fill at once. The real host must serve it from this
/// app's own support directory (the file the live usage events write), not
/// throw "not supported" or read another install's data.
@MainActor
final class AgentAccountUsageGetRemoteTests: XCTestCase {
    func test_hostServesUsageStoredByThisApp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2AccountUsageRemote-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let resetsAt = Date().addingTimeInterval(86_400)
        _ = try ProviderUsageStore(appSupportDirectory: ctx.appSupportDirectory).recordAccountUsage(
            provider: .grok, weeklyUsedPercent: 31, weeklyResetsAt: resetsAt
        )

        let response = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: AgentAccountUsageGet.method, params: nil
        ))
        XCTAssertNil(response.error)
        let result = try JSONDecoder().decode(
            AgentAccountUsageGet.Result.self,
            from: JSONEncoder().encode(XCTUnwrap(response.result))
        )
        let grok = try XCTUnwrap(result.providers.first { $0.provider == "grok" })
        XCTAssertEqual(grok.weeklyUsedPercent, 31)
        XCTAssertNotNil(result.storedAtMs)
    }

    // MARK: - Clears reach a paired client

    private actor StubRefresher: ProviderAccountUsageRefreshing {
        let full: [AssistantAccountUsage]
        init(full: [AssistantAccountUsage]) { self.full = full }
        func refreshAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> [AssistantAccountUsage] { full }
        func grokAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? { nil }
    }

    /// A paired client exactly as the contract tells iOS to behave: start from
    /// `agent.account.usage.get`, fold each live `agent.account.usage` event
    /// (non-null replaces, null keeps), read rings with the expiry rules.
    private struct PairedClient {
        var rows: [String: [String: JSONValue]] = [:]

        mutating func apply(get result: JSONValue) {
            for row in result.objectValue?["providers"]?.arrayValue ?? [] {
                guard let object = row.objectValue, let provider = object["provider"]?.stringValue else { continue }
                rows[provider] = object
            }
        }

        mutating func fold(event payload: JSONValue) {
            guard let object = payload.objectValue, let provider = object["provider"]?.stringValue else { return }
            var row = rows[provider] ?? [:]
            for (key, value) in object where value != .null { row[key] = value }
            rows[provider] = row
        }

        func shortRing(_ provider: String, now: Date = Date()) -> Double? {
            let row = rows[provider] ?? [:]
            let nowMs = now.timeIntervalSince1970 * 1000
            var weekly = row["weekly_used_percent"]?.usageNumber
            if weekly != nil, let reset = row["weekly_resets_at_ms"]?.usageNumber, reset <= nowMs { weekly = 0 }
            var session = row["current_session_used_percent"]?.usageNumber
            if let reset = row["current_session_resets_at_ms"]?.usageNumber {
                if reset <= nowMs { session = nil }
            } else if let value = session, value <= 0 {
                session = nil
            }
            return session ?? weekly
        }
    }

    private func makeSignedInContext(refresher: StubRefresher, root: URL) throws -> AppContext {
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path,
            accountUsageRefresher: refresher
        )
        ctx.router = AppCommandRouter(context: ctx)
        PrivateAccountSessionStore(repo: ctx.settingsRepo).save(PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: nil, daysRemaining: 30, email: "paid@example.com", id: "paid-user", subscribed: true
            )
        ))
        return ctx
    }

    private func usageEvents(since cursor: Int64) -> [JSONValue] {
        EventBus.shared.recentEvents(since: cursor, maxBytes: nil).events
            .filter { $0.kind == "agent.account.usage" }
            .map(\.payload)
    }

    private func waitForEvent(
        since cursor: Int64,
        provider: String,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if usageEvents(since: cursor).contains(where: { $0.objectValue?["provider"] == .string(provider) }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// WHY: a partial refresh zeroes a provider that stopped answering. The
    /// Mac sidebar then shows 0%; an iPhone that only folds events kept
    /// showing the pre-clear 45% until it reconnected.
    func test_partialRefreshClearIsVisibleToAPairedClient() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2AccountUsageClear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try makeSignedInContext(
            refresher: StubRefresher(full: [AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 23)]),
            root: root
        )
        let store = ProviderUsageStore(appSupportDirectory: ctx.appSupportDirectory)
        _ = try store.recordAccountUsage(provider: .claude, weeklyUsedPercent: 45, currentSessionUsedPercent: 30)
        _ = try store.recordAccountUsage(provider: .codex, weeklyUsedPercent: 10)

        var client = PairedClient()
        client.apply(get: AgentAccountUsageWire.load(appSupportDirectory: ctx.appSupportDirectory))
        XCTAssertEqual(client.shortRing("claude"), 30)
        let cursor = EventBus.shared.currentSeq

        ctx.refreshAccountUsage(reason: "test")
        let cleared = await waitForEvent(since: cursor, provider: "claude")
        XCTAssertTrue(cleared, "the clear must be announced to paired devices")
        for payload in usageEvents(since: cursor) { client.fold(event: payload) }

        let macClaude = try XCTUnwrap(store.load().providers.first { $0.provider == .claude })
        let macRing = macClaude.effectiveSessionUsedPercent() ?? macClaude.effectiveWeeklyUsedPercent()
        XCTAssertEqual(macRing, 0)
        XCTAssertEqual(client.shortRing("claude"), macRing, "phone ring must match the Mac after the clear")
        XCTAssertEqual(client.shortRing("codex"), 23)
    }

    /// WHY: the periodic cycle clears a Grok miss after the cycle's own
    /// `agent.account.usage.refresh` finished events; the clear still has to
    /// reach the phone.
    func test_periodicGrokMissClearIsVisibleToAPairedClient() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2AccountUsageGrokClear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try makeSignedInContext(
            refresher: StubRefresher(full: [AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 23)]),
            root: root
        )
        let store = ProviderUsageStore(appSupportDirectory: ctx.appSupportDirectory)
        _ = try store.recordAccountUsage(provider: .grok, weeklyUsedPercent: 65)

        var client = PairedClient()
        client.apply(get: AgentAccountUsageWire.load(appSupportDirectory: ctx.appSupportDirectory))
        XCTAssertEqual(client.shortRing("grok"), 65)
        let cursor = EventBus.shared.currentSeq

        ctx.refreshPeriodicAccountUsage()
        let cleared = await waitForEvent(since: cursor, provider: "grok")
        XCTAssertTrue(cleared, "the periodic Grok clear must be announced to paired devices")
        for payload in usageEvents(since: cursor) { client.fold(event: payload) }

        XCTAssertEqual(store.load().providers.first { $0.provider == .grok }?.weeklyUsedPercent, 0)
        XCTAssertEqual(client.shortRing("grok"), 0)
        XCTAssertEqual(
            usageEvents(since: cursor).first { $0.objectValue?["provider"] == .string("grok") }?
                .objectValue?["reason"],
            .string("periodic")
        )
    }
}

private extension JSONValue {
    var usageNumber: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
