import XCTest
import CoreModel
@testable import AppShell

/// Golden-JSON contract tests for the `agent.account.usage` and
/// `agent.account.usage.refresh` event payloads.
///
/// WHY: the payload field names are the wire contract between the mac host and
/// the iOS account usage rings. No test pinned them before this file; silent
/// schema drift (e.g. renaming `weekly_used_percent` to `weeklyUsedPercent`)
/// would produce a broken iOS surface with no mac-side failure. These tests
/// assert the exact field names and value encoding so any drift is intentional
/// and visible in diff.
final class AgentAccountUsageGoldenTests: XCTestCase {

    // MARK: - agent.account.usage (run-time variant, has thread_id)

    private func makeUsage(
        provider: AgentProvider = .claude,
        weeklyUsedPercent: Double = 42.5,
        weeklyWindowDurationMinutes: Int? = 10080,
        weeklyResetsAtMs: Int64? = 1_700_000_000_000,
        currentSessionUsedPercent: Double? = 12.3,
        currentSessionResetsAtMs: Int64? = 1_700_001_000_000
    ) -> AssistantAccountUsage {
        AssistantAccountUsage(
            provider: provider,
            weeklyUsedPercent: weeklyUsedPercent,
            weeklyWindowDurationMinutes: weeklyWindowDurationMinutes,
            weeklyResetsAtMs: weeklyResetsAtMs,
            currentSessionUsedPercent: currentSessionUsedPercent,
            currentSessionResetsAtMs: currentSessionResetsAtMs
        )
    }

    /// WHY: `provider` is the key iOS uses to route usage to the right
    /// provider pill; a renamed key silently breaks all provider attribution.
    func test_accountUsagePayload_containsProvider() {
        let p = AppContext.accountUsagePayload(threadId: "tid-1", usage: makeUsage(provider: .claude))
        XCTAssertEqual(p["provider"], .string("claude"),
                       "'provider' field is missing or renamed; iOS cannot route account usage to the Claude pill")
    }

    /// WHY: `weekly_used_percent` drives the progress bar on iOS; the field
    /// name must match the snake_case the iOS decoder expects.
    func test_accountUsagePayload_containsWeeklyUsedPercent() {
        let p = AppContext.accountUsagePayload(threadId: "tid-1", usage: makeUsage(weeklyUsedPercent: 42.5))
        XCTAssertEqual(p["weekly_used_percent"], .number(42.5),
                       "'weekly_used_percent' field missing or mistyped; iOS progress bar would show 0% permanently")
    }

    /// WHY: `weekly_window_duration_minutes` lets iOS display the reset window
    /// length; the key must be present and snake_case.
    func test_accountUsagePayload_containsWeeklyWindowDurationMinutes_whenPresent() {
        let p = AppContext.accountUsagePayload(threadId: "tid-1", usage: makeUsage(weeklyWindowDurationMinutes: 10080))
        XCTAssertEqual(p["weekly_window_duration_minutes"], .number(10080),
                       "'weekly_window_duration_minutes' field missing; iOS cannot show the reset window length")
    }

    /// WHY: when the field is absent from the server response, the payload must
    /// carry `.null` (not omit the key) so iOS can distinguish nil from 0.
    func test_accountUsagePayload_nullsWeeklyWindowDurationMinutes_whenAbsent() {
        let p = AppContext.accountUsagePayload(threadId: "tid-1", usage: makeUsage(weeklyWindowDurationMinutes: nil))
        XCTAssertEqual(p["weekly_window_duration_minutes"], .null,
                       "absent weekly_window_duration_minutes must be .null in the payload, not omitted")
    }

    /// WHY: `weekly_resets_at_ms` is the epoch timestamp iOS uses for the
    /// reset countdown; the key must be present and carry the Int64 value.
    func test_accountUsagePayload_containsWeeklyResetsAtMs_whenPresent() {
        let p = AppContext.accountUsagePayload(threadId: "tid-1", usage: makeUsage(weeklyResetsAtMs: 1_700_000_000_000))
        XCTAssertEqual(p["weekly_resets_at_ms"], .number(Double(1_700_000_000_000)),
                       "'weekly_resets_at_ms' field missing; iOS reset countdown would be stuck at epoch")
    }

    func test_accountUsagePayload_nullsWeeklyResetsAtMs_whenAbsent() {
        let p = AppContext.accountUsagePayload(threadId: "tid-1", usage: makeUsage(weeklyResetsAtMs: nil))
        XCTAssertEqual(p["weekly_resets_at_ms"], .null,
                       "absent weekly_resets_at_ms must be .null in the payload, not omitted")
    }

    /// WHY: `current_session_used_percent` is optional but must be `.null` when
    /// absent so iOS can render the per-session pill correctly.
    func test_accountUsagePayload_containsCurrentSessionUsedPercent_whenPresent() {
        let p = AppContext.accountUsagePayload(threadId: "tid-1", usage: makeUsage(currentSessionUsedPercent: 12.3))
        XCTAssertEqual(p["current_session_used_percent"], .number(12.3),
                       "'current_session_used_percent' field missing; iOS session pill would show 0% permanently")
    }

    func test_accountUsagePayload_nullsCurrentSessionUsedPercent_whenAbsent() {
        let p = AppContext.accountUsagePayload(threadId: "tid-1", usage: makeUsage(currentSessionUsedPercent: nil))
        XCTAssertEqual(p["current_session_used_percent"], .null,
                       "absent current_session_used_percent must be .null, not omitted")
    }

    func test_accountUsagePayload_containsCurrentSessionResetsAtMs_whenPresent() {
        let p = AppContext.accountUsagePayload(threadId: "tid-1", usage: makeUsage(currentSessionResetsAtMs: 1_700_001_000_000))
        XCTAssertEqual(p["current_session_resets_at_ms"], .number(Double(1_700_001_000_000)),
                       "'current_session_resets_at_ms' field missing; iOS session countdown would be stuck")
    }

    func test_accountUsagePayload_nullsCurrentSessionResetsAtMs_whenAbsent() {
        let p = AppContext.accountUsagePayload(threadId: "tid-1", usage: makeUsage(currentSessionResetsAtMs: nil))
        XCTAssertEqual(p["current_session_resets_at_ms"], .null,
                       "absent current_session_resets_at_ms must be .null, not omitted")
    }

    /// WHY: the run-time path includes `thread_id` so iOS can scope the usage
    /// update to the active thread. Missing this key prevents per-thread attribution.
    func test_accountUsagePayload_runtimePath_includesThreadId() {
        let p = AppContext.accountUsagePayload(threadId: "abc-thread", usage: makeUsage())
        XCTAssertEqual(p["thread_id"], .string("abc-thread"),
                       "'thread_id' must be present in the run-time agent.account.usage payload; iOS uses it for per-thread attribution")
    }

    /// WHY: the refresh path omits `thread_id` but includes `reason`; callers
    /// must not accidentally cross the two shapes.
    func test_accountUsagePayload_refreshPath_includesReason_notThreadId() {
        let p = AppContext.accountUsagePayload(reason: "manual", usage: makeUsage())
        XCTAssertEqual(p["reason"], .string("manual"),
                       "'reason' must be present in the refresh-path agent.account.usage payload")
        XCTAssertNil(p["thread_id"],
                     "refresh-path payload must not carry 'thread_id'; only the run-time path does")
    }

    // MARK: - agent.account.usage.refresh

    /// WHY: `state` tells iOS whether the refresh is "started" or "finished";
    /// a renamed key prevents iOS from showing/hiding the loading indicator.
    func test_accountUsageRefreshPayload_containsState() {
        let p = AppContext.accountUsageRefreshPayload(
            state: "finished", reason: "launch", detail: nil, providers: [], refreshCount: 1
        )
        XCTAssertEqual(p["state"], .string("finished"),
                       "'state' field missing from agent.account.usage.refresh; iOS loading indicator would never clear")
    }

    /// WHY: `reason` lets iOS analytics distinguish a launch-triggered refresh
    /// from a user-initiated one; key must be present in the snake_case form.
    func test_accountUsageRefreshPayload_containsReason() {
        let p = AppContext.accountUsageRefreshPayload(
            state: "finished", reason: "launch", detail: nil, providers: [], refreshCount: 2
        )
        XCTAssertEqual(p["reason"], .string("launch"),
                       "'reason' field missing from agent.account.usage.refresh; iOS analytics bucket is wrong")
    }

    /// WHY: `refresh_count` is a monotonic counter iOS uses to correlate
    /// started/finished pairs and detect lost events; must be a number.
    func test_accountUsageRefreshPayload_containsRefreshCount() {
        let p = AppContext.accountUsageRefreshPayload(
            state: "finished", reason: "launch", detail: nil, providers: [], refreshCount: 7
        )
        XCTAssertEqual(p["refresh_count"], .number(7),
                       "'refresh_count' field missing or wrong type; iOS cannot correlate refresh started/finished pairs")
    }

    /// WHY: `detail` is an optional diagnostic string; when present it must be
    /// carried under the exact key "detail".
    func test_accountUsageRefreshPayload_includesDetail_whenPresent() {
        let p = AppContext.accountUsageRefreshPayload(
            state: "finished", reason: "launch", detail: "empty", providers: [], refreshCount: 1
        )
        XCTAssertEqual(p["detail"], .string("empty"),
                       "'detail' field missing when non-nil; iOS diagnostic display would be blank")
    }

    func test_accountUsageRefreshPayload_omitsDetail_whenNil() {
        let p = AppContext.accountUsageRefreshPayload(
            state: "finished", reason: "launch", detail: nil, providers: [], refreshCount: 1
        )
        XCTAssertNil(p["detail"],
                     "'detail' key must be absent when nil (not .null); iOS checks key presence, not null-ness")
    }

    /// WHY: `providers` lists which provider rails were refreshed; iOS uses
    /// this to know which pills to re-render. Must be an array of strings.
    func test_accountUsageRefreshPayload_includesProviders_whenNonEmpty() {
        let p = AppContext.accountUsageRefreshPayload(
            state: "finished", reason: "launch", detail: nil,
            providers: ["claude", "codex"], refreshCount: 1
        )
        XCTAssertEqual(p["providers"], .array([.string("claude"), .string("codex")]),
                       "'providers' array missing or has wrong element type; iOS cannot target the correct usage pills")
    }

    func test_accountUsageRefreshPayload_omitsProviders_whenEmpty() {
        let p = AppContext.accountUsageRefreshPayload(
            state: "started", reason: "manual", detail: nil, providers: [], refreshCount: 1
        )
        XCTAssertNil(p["providers"],
                     "'providers' must be omitted (not an empty array) when the list is empty")
    }
}
