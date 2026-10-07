import Foundation

// Cached provider account usage for paired devices (host capability
// `agent.account_usage_get_v1`).
//
// - Read: `agent.account.usage.get` (batchable, `read` scope, no params)
//   returns the host's last stored rate-limit usage for every managed provider
//   (`claude`, `codex`, `grok`, always all three, in that order). It never
//   probes a provider: call it on connect to fill usage rings at once, then
//   fold live `agent.account.usage` events (same per-provider field names)
//   and `agent.account.usage.refresh` progress events on top.
// - Fold each event into that provider's row the way the host store does: a
//   non-null field replaces the stored one, a null field keeps it. Then read
//   the row with the expiry rules below (apply them to event values too).
// - Every percent change the host stores is announced as an
//   `agent.account.usage` event, including the host clearing a provider that
//   stopped answering a refresh: that event carries `weekly_used_percent` 0
//   and `current_session_used_percent` 0 (numbers, so they overwrite), with
//   the window fields kept. No re-get is needed after a refresh.
// - Values are the stored ones after expiry: `weekly_used_percent` reads 0
//   once `weekly_resets_at_ms` has passed, and `current_session_used_percent`
//   is null once `current_session_resets_at_ms` has passed or when it is a
//   bare 0 with no session window. Null means "unknown", not 0%. A
//   short-window ring shows `current_session_used_percent ?? weekly_used_percent`;
//   a weekly ring shows `weekly_used_percent` (the Mac sidebar rule).
// - `stored_at_ms` is when the host last wrote its usage store. Token-count
//   writes touch it too, so it is NOT when the percentages were last updated:
//   never show it as "usage updated at". It only says no value is newer than
//   it; a percent next to a fresh `stored_at_ms` can still be old. Null when
//   nothing has been stored yet (then every percent is null too).

public enum AgentAccountUsageGet: RemoteCodeRPCContract {
    public static let method = "agent.account.usage.get"

    public struct Params: Codable, Equatable, Sendable {
        public init() {}
    }

    public struct ProviderUsage: Codable, Equatable, Sendable {
        public let provider: String
        public let weeklyUsedPercent: Double?
        public let weeklyWindowDurationMinutes: Int?
        public let weeklyResetsAtMs: Int64?
        public let currentSessionUsedPercent: Double?
        public let currentSessionResetsAtMs: Int64?

        public init(
            provider: String,
            weeklyUsedPercent: Double? = nil,
            weeklyWindowDurationMinutes: Int? = nil,
            weeklyResetsAtMs: Int64? = nil,
            currentSessionUsedPercent: Double? = nil,
            currentSessionResetsAtMs: Int64? = nil
        ) {
            self.provider = provider
            self.weeklyUsedPercent = weeklyUsedPercent
            self.weeklyWindowDurationMinutes = weeklyWindowDurationMinutes
            self.weeklyResetsAtMs = weeklyResetsAtMs
            self.currentSessionUsedPercent = currentSessionUsedPercent
            self.currentSessionResetsAtMs = currentSessionResetsAtMs
        }

        private enum CodingKeys: String, CodingKey {
            case provider
            case weeklyUsedPercent = "weekly_used_percent"
            case weeklyWindowDurationMinutes = "weekly_window_duration_minutes"
            case weeklyResetsAtMs = "weekly_resets_at_ms"
            case currentSessionUsedPercent = "current_session_used_percent"
            case currentSessionResetsAtMs = "current_session_resets_at_ms"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let providers: [ProviderUsage]
        public let storedAtMs: Int64?

        public init(providers: [ProviderUsage], storedAtMs: Int64?) {
            self.providers = providers
            self.storedAtMs = storedAtMs
        }

        private enum CodingKeys: String, CodingKey {
            case providers
            case storedAtMs = "stored_at_ms"
        }
    }
}
