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
