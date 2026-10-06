import Foundation
import CoreModel
import AgentRuntime
import Persistence
import SocketServer
import RemoteCodeTreaty

/// Glanceable Token Saver card pushed to paired iOS clients for the Home Screen
/// widget and in-app modal. Mirrors the macOS sidebar details popover.
public enum TokenSaverWidgetDigest {
    public static let eventKind = RemoteCodeEventKind.tokenSaverDigest
    /// Posted by EventBus when a remote subscriber is added so AppShell can
    /// re-emit the latest digest (late-connecting iOS clients).
    public static let subscriberAddedNotification = Notification.Name(
        "io.remotecode.eventbus.subscriberAdded"
    )

    public enum Scope: String, Sendable, Codable, CaseIterable {
        case today
        case week
    }

    private static let lock = NSLock()
    private static var lastBody: [String: JSONValue]?

    /// Absolute green-ring goals: 100M today / 700M week.
    public static func savingsGoalTokens(scope: Scope) -> Int {
        scope == .today ? 100_000_000 : 700_000_000
    }

    public static func savingsProgress(savedTokens: Int, scope: Scope) -> Double {
        let saved = max(savedTokens, 0)
        let goal = max(savingsGoalTokens(scope: scope), 1)
        guard saved > 0 else { return 0 }
        return min(Double(saved) / Double(goal), 1)
    }

    /// Build the EventBus / iOS payload for one scope (default: today).
    public static func payload(
        enabled: Bool,
        subscribed: Bool,
        scope: Scope = .today,
        estimatedSaveTokens: Int,
        claudeUsedPercent: Double?,
        codexUsedPercent: Double?,
        grokUsedPercent: Double?,
        isRefreshing: Bool,
        updatedAt: Date = Date()
    ) -> [String: JSONValue] {
        let saved = max(0, estimatedSaveTokens)
        let progress = savingsProgress(savedTokens: saved, scope: scope)
        var body: [String: JSONValue] = [
            "enabled": .bool(enabled),
            "subscribed": .bool(subscribed),
            "scope": .string(scope.rawValue),
            "estimated_save_tokens": .number(Double(saved)),
            "token_saver_progress": .number(progress),
            "token_saver_ring_available": .bool(saved > 0 || progress > 0),
            "is_refreshing": .bool(isRefreshing),
            "updated_at_ms": .number((updatedAt.timeIntervalSince1970 * 1000).rounded())
        ]
        if let claudeUsedPercent {
            body["claude_used_percent"] = .number(clampedPercent(claudeUsedPercent))
        }
        if let codexUsedPercent {
            body["codex_used_percent"] = .number(clampedPercent(codexUsedPercent))
        }
        if let grokUsedPercent {
            body["grok_used_percent"] = .number(clampedPercent(grokUsedPercent))
        }
        return body
    }

    /// Publish both Today and Week digests so the iOS surfaces can flip scope
    /// without another round-trip. `primary` is the scope the card headlines.
    public static func publish(
        enabled: Bool,
        subscribed: Bool,
        primaryScope: Scope = .today,
        todaySavedTokens: Int,
        weekSavedTokens: Int,
        snapshot: TokenSaverUsageSnapshot,
        isRefreshing: Bool,
        updatedAt: Date = Date()
    ) {
        let claude = provider(from: snapshot, .claude)
        let codex = provider(from: snapshot, .codex)
        let grok = provider(from: snapshot, .grok)

        let weekPayload = payload(
            enabled: enabled,
            subscribed: subscribed,
            scope: .week,
            estimatedSaveTokens: weekSavedTokens,
            claudeUsedPercent: claude.effectiveWeeklyUsedPercent(),
            codexUsedPercent: codex.effectiveWeeklyUsedPercent(),
            grokUsedPercent: grok.effectiveWeeklyUsedPercent(),
            isRefreshing: isRefreshing,
            updatedAt: updatedAt
        )
        let todayPayload = payload(
            enabled: enabled,
            subscribed: subscribed,
            scope: .today,
            estimatedSaveTokens: todaySavedTokens,
            claudeUsedPercent: claude.effectiveSessionUsedPercent()
                ?? claude.effectiveWeeklyUsedPercent(),
            codexUsedPercent: codex.effectiveSessionUsedPercent()
                ?? codex.effectiveWeeklyUsedPercent(),
            grokUsedPercent: grok.effectiveSessionUsedPercent()
                ?? grok.effectiveWeeklyUsedPercent(),
            isRefreshing: isRefreshing,
            updatedAt: updatedAt
        )

        var body = primaryScope == .today ? todayPayload : weekPayload
        body["today"] = .object(todayPayload)
        body["week"] = .object(weekPayload)
        cacheAndPublish(body)
    }

    /// Load current Token Saver glanceable state from disk and publish.
    /// Independent of SidebarViewModel so remote clients get data even when
    /// the sidebar has not been shown this session.
    /// Off-main safe: reads usage.json + two economy rows, publishes through
    /// the thread-safe EventBus. (EV-25: used to be `@MainActor` and ran the
    /// file read + SQLite on main on every account-usage cycle.)
    public static func publishFromDisk(
        appSupportDirectory: URL,
        economyRepo: TokenSaverDailyEconomyRepository,
        tokenSaverEnabled: Bool,
        subscribed: Bool,
        isRefreshing: Bool = false,
        updatedAt: Date = Date()
    ) {
        let snapshot = TokenSaverUsageStore(appSupportDirectory: appSupportDirectory).load()
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let todayMs = Int64(todayStart.timeIntervalSince1970 * 1000)
        let weekStart = cal.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let weekStartMs = Int64(weekStart.timeIntervalSince1970 * 1000)
        let weekEndExclusive = cal.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let weekEndMs = Int64(weekEndExclusive.timeIntervalSince1970 * 1000)
        let economyToday = try? economyRepo.record(dayStartMs: todayMs)
        let weekTotal = (try? economyRepo.windowTotalCredible(
            fromDayStartMs: weekStartMs,
            toDayStartMs: todayMs,
            toDayEndMsExclusive: weekEndMs
        ).total) ?? 0
        publish(
            enabled: tokenSaverEnabled,
            subscribed: subscribed,
            primaryScope: .today,
            todaySavedTokens: economyToday?.totalCredible ?? 0,
            weekSavedTokens: weekTotal,
            snapshot: snapshot,
            isRefreshing: isRefreshing,
            updatedAt: updatedAt
        )
    }

    /// Re-emit the last cached body (no disk IO). Used when a remote client
    /// subscribes after the last live publish fell outside the replay window.
    public static func republishLast() {
        lock.lock()
        let body = lastBody
        lock.unlock()
        guard let body else { return }
        EventBus.shared.publish(kind: eventKind, payload: .object(body))
    }

    /// Latest cached body for RPC `token_saver.digest.get` (may be nil before
    /// the first publish this process).
    public static func lastCachedBody() -> [String: JSONValue]? {
        lock.lock()
        defer { lock.unlock() }
        return lastBody
    }

    public private(set) nonisolated(unsafe) static var suppressedDuplicatePublishCountForTesting = 0

    /// Tests that count digest publishes must start from a clean last body:
    /// the dedupe is process-global and an earlier test may have published an
    /// identical digest.
    public static func resetLastBodyForTesting() {
        lock.lock()
        lastBody = nil
        lock.unlock()
    }

    private static func cacheAndPublish(_ body: [String: JSONValue]) {
        lock.lock()
        let previous = lastBody
        lastBody = body
        lock.unlock()
        // EV-25: every account-usage cycle republished a structurally identical
        // digest (only `updated_at_ms` moved) — 155 persisted events + fan-out
        // per 10 min. Skip when nothing the client renders changed.
        if let previous, digestsEquivalent(previous, body) {
            lock.lock()
            suppressedDuplicatePublishCountForTesting += 1
            lock.unlock()
            return
        }
        EventBus.shared.publish(kind: eventKind, payload: .object(body))
    }

    static func digestsEquivalent(_ lhs: [String: JSONValue], _ rhs: [String: JSONValue]) -> Bool {
        func stripped(_ body: [String: JSONValue]) -> [String: JSONValue] {
            var out = body
            out["updated_at_ms"] = nil
            for scope in ["today", "week"] {
                if case .object(var nested)? = out[scope] {
                    nested["updated_at_ms"] = nil
                    out[scope] = .object(nested)
                }
            }
            return out
        }
        return stripped(lhs) == stripped(rhs)
    }

    private static func provider(
        from snapshot: TokenSaverUsageSnapshot,
        _ provider: AgentProvider
    ) -> TokenSaverProviderUsage {
        snapshot.providers.first { $0.provider == provider }
            ?? TokenSaverProviderUsage(provider: provider)
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
