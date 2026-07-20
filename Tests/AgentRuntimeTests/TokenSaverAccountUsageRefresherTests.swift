import XCTest
import CoreModel
@testable import AgentRuntime

final class TokenSaverAccountUsageRefresherTests: XCTestCase {
    func test_codexParserPrefersWeeklyCodexLimitBucket() {
        let usage = AssistantAccountUsageParser.codex(from: [
            "rateLimits": [
                "primary": [
                    "usedPercent": 11,
                    "windowDurationMins": 300
                ]
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "secondary": [
                        "used_percent": 34,
                        "window_minutes": 10_080,
                        "resets_at": 1_781_138_445
                    ],
                    "primary": [
                        "usedPercent": 13,
                        "windowDurationMins": 300
                    ]
                ]
            ]
        ])

        XCTAssertEqual(usage?.provider, .codex)
        XCTAssertEqual(usage?.weeklyUsedPercent, 34)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
        XCTAssertEqual(usage?.currentSessionUsedPercent, 13)
        XCTAssertNotNil(usage?.weeklyResetsAtMs)
    }

    func test_codexParserReadsRawAppServerPrimarySecondaryShape() {
        let usage = AssistantAccountUsageParser.codex(from: [
            "primary": [
                "used_percent": 13,
                "window_minutes": 300,
                "resets_at": 1_780_769_381
            ],
            "secondary": [
                "used_percent": 34,
                "window_minutes": 10_080,
                "resets_at": 1_781_138_445
            ],
            "plan_type": "pro"
        ])

        XCTAssertEqual(usage?.provider, .codex)
        XCTAssertEqual(usage?.weeklyUsedPercent, 34)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
        XCTAssertEqual(usage?.currentSessionUsedPercent, 13)
        XCTAssertEqual(usage?.weeklyResetsAtMs, 1_781_138_445_000)
    }

    func test_claudeUsageTextParsesUsedAndRemainingPercentages() {
        let used = AssistantAccountUsageParser.claudeUsageText("Weekly usage 57% used")
        XCTAssertEqual(used?.provider, .claude)
        XCTAssertEqual(used?.weeklyUsedPercent, 57)
        XCTAssertEqual(used?.weeklyWindowDurationMinutes, 10_080)

        let remaining = AssistantAccountUsageParser.claudeUsageText("Subscription usage 67% remaining")
        XCTAssertEqual(remaining?.provider, .claude)
        XCTAssertEqual(remaining?.weeklyUsedPercent, 33)
        XCTAssertEqual(remaining?.weeklyWindowDurationMinutes, 10_080)
    }

    func test_grokBillingLogLineParsesCreditUsagePercent() {
        // WHY: Token Saver Grok ring was stuck on "No data" because account
        // refresh never read Grok's local billing snapshot (creditUsagePercent).
        let line = #"""
        {"ts":"2026-07-13T23:32:27.798Z","src":"shell","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":29.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-08T20:46:41.975270+00:00","end":"2026-07-15T20:46:41.975270+00:00"},"billingPeriodStart":"2026-07-08T20:46:41.975270+00:00","billingPeriodEnd":"2026-07-15T20:46:41.975270+00:00"},"subscriptionTier":"SuperGrok Heavy"}}
        """#
        let usage = AssistantAccountUsageParser.grokBillingLogLine(line)
        XCTAssertEqual(usage?.provider, .grok)
        XCTAssertEqual(usage?.weeklyUsedPercent, 29)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
        XCTAssertNotNil(usage?.weeklyResetsAtMs,
                        "billingPeriodEnd must become weeklyResetsAt so the card can show reset timing")
    }

    func test_grokFromBillingLogFile_picksNewestPercent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-billing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("unified.jsonl")
        let body = """
        {"msg":"noise","ctx":{}}
        {"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":10.0,"billingPeriodEnd":"2026-07-15T20:46:41.975270+00:00"}}}
        {"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":42.5,"billingPeriodEnd":"2026-07-15T20:46:41.975270+00:00"}}}
        """
        try body.write(to: log, atomically: true, encoding: .utf8)
        let usage = AssistantAccountUsageParser.grokFromBillingLogFile(at: log)
        XCTAssertEqual(usage?.weeklyUsedPercent, 42.5,
                       "must use the newest billing line so the purple ring matches live Grok credits")
    }

    /// WHY: production `~/.grok/logs/unified.jsonl` put 800KB+ of non-billing
    /// traffic between credit snapshots. The old 512KB tail window returned nil,
    /// partial refresh cleared Grok, and Token Saver showed Used 0% despite real
    /// SuperGrok usage (and non-zero Saved tokens for Grok).
    func test_grokFromBillingLogFile_findsPercentBeyondFormer512KBWindow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-billing-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("unified.jsonl")

        let billing = #"{"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":65.0,"billingPeriodEnd":"2026-07-22T20:46:41.975270+00:00"}}}"# + "\n"
        // ~700 KiB of noise after the only billing line — larger than the old
        // 512 KiB default, smaller than the new 4 MiB default.
        let noiseLine = #"{"msg":"tool_result","ctx":{"output":""}}"# + String(repeating: "x", count: 200) + "\n"
        var body = billing
        while body.utf8.count < 700 * 1024 {
            body += noiseLine
        }
        try body.write(to: log, atomically: true, encoding: .utf8)

        let withLegacyWindow = AssistantAccountUsageParser.grokFromBillingLogFile(
            at: log,
            maxBytes: 512 * 1024
        )
        XCTAssertNil(withLegacyWindow,
                     "regression fixture: 512KB window must miss a billing line buried under 700KB of noise")

        let withDefaultWindow = AssistantAccountUsageParser.grokFromBillingLogFile(at: log)
        XCTAssertEqual(withDefaultWindow?.provider, .grok)
        XCTAssertEqual(withDefaultWindow?.weeklyUsedPercent, 65,
                       "default scan window must still find creditUsagePercent past the old 512KB limit")
    }

    func test_claudeUsageScreenParsesInteractiveUsageDialog() {
        let output = """
        Settings  Status Config Usage Stats

        Current session
        █▌ 3% used
        Resets 4:50pm (America/Asuncion)

        Current week (all models)
        ████████████████████████████▍ 56% used
        Resets Jun 9 at 7am (America/Asuncion)

        Current week (Sonnet only)
        █▌ 3% used
        Resets Jun 9 at 7am (America/Asuncion)
        """

        let usage = AssistantAccountUsageParser.claudeUsageScreen(output)

        XCTAssertEqual(usage?.provider, .claude)
        XCTAssertEqual(usage?.weeklyUsedPercent, 56)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
        XCTAssertEqual(usage?.currentSessionUsedPercent, 3)
    }

    func test_claudeUsageScreenParsesCompactedTTYText() {
        let output = """
        Currentweek(allmodels)
        ████████████████████████████▉ 58%used
        ResetsJun9at7am(America/Asuncion)

        Currentweek(Sonnetonly)
        █▌ 3%used
        """

        let usage = AssistantAccountUsageParser.claudeUsageScreen(output)

        XCTAssertEqual(usage?.provider, .claude)
        XCTAssertEqual(usage?.weeklyUsedPercent, 58)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
    }

    func test_claudeUsageScreenStripsAnsiCursorControls() {
        let output = """
        \u{001B}[3GCurrent\u{001B}[11Gweek\u{001B}[16G(all\u{001B}[21Gmodels)
        \u{001B}[3G████████████████████████████▉\u{001B}[54G58%\u{001B}[58Gused
        \u{001B}[3GResets\u{001B}[10GJun\u{001B}[14G9
        """

        let usage = AssistantAccountUsageParser.claudeUsageScreen(output)

        XCTAssertEqual(usage?.provider, .claude)
        XCTAssertEqual(usage?.weeklyUsedPercent, 58)
        XCTAssertEqual(usage?.weeklyWindowDurationMinutes, 10_080)
    }

    func test_liveAccountUsageRefresh_whenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["REMOTE_CODE_LIVE_USAGE_TEST"] == "1" else {
            throw XCTSkip("Set REMOTE_CODE_LIVE_USAGE_TEST=1 to call local provider usage commands.")
        }

        let usages = await TokenSaverAccountUsageRefresher(timeoutSeconds: 18)
            .refreshAccountUsage(TokenSaverAccountUsageRefreshRequest(
                cwd: "/Users/samuelfajreldines/dev/empath",
                environment: [:]
            ))
        print("LIVE_USAGE", usages.map { "\($0.provider.rawValue):\($0.weeklyUsedPercent):\($0.currentSessionUsedPercent ?? -1)" }.joined(separator: ","))

        XCTAssertTrue(usages.contains(where: { $0.provider == .claude && $0.weeklyUsedPercent > 0 }))
        XCTAssertTrue(usages.contains(where: { $0.provider == .codex && $0.weeklyUsedPercent > 0 }))
    }
}
