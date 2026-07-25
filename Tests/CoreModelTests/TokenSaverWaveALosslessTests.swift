import XCTest
@testable import CoreModel

final class TokenSaverWaveALosslessTests: XCTestCase {
    func test_defaultsShadowNotActive() {
        for (_, mode) in TokenSaverWaveALossless.defaults {
            XCTAssertNotEqual(mode, .active)
        }
        XCTAssertTrue(TokenSaverWaveALossless.promotionDefaultOff)
    }

    func test_roundTrip_positiveAndNegative() {
        let raw = Data("log-line\n".utf8)
        XCTAssertTrue(TokenSaverWaveALossless.expandCollapseRoundTrip(raw))
        let bin = Data([0, 1, 2, 255])
        XCTAssertTrue(TokenSaverWaveALossless.expandCollapseRoundTrip(bin))
        XCTAssertNil(TokenSaverWaveALossless.expand(Data("!!!not-base64!!!".utf8)))
    }

    func test_repeatedLog_collapsePreservesExit() {
        let log = (0..<20).map { _ in "progress..." }.joined(separator: "\n") + "\nexit code: 0\n"
        let (collapsed, ok) = TokenSaverWaveALossless.collapseRepeatedLogLines(log)
        XCTAssertTrue(ok)
        XCTAssertTrue(collapsed.contains("exit code"))
        XCTAssertLessThan(collapsed.utf8.count, log.utf8.count)
        XCTAssertTrue(TokenSaverWaveALossless.repeatedLogAllows(original: log))
    }

    func test_heterogeneousJSON_staysRaw() {
        XCTAssertFalse(TokenSaverWaveALossless.isHomogeneousJSON("[1,\"x\"]"))
        XCTAssertFalse(TokenSaverWaveALossless.isHomogeneousJSON("[{\"a\":1},{\"b\":2}]"))
        // Same keys, different value kinds → raw
        XCTAssertFalse(TokenSaverWaveALossless.isHomogeneousJSON("[{\"a\":1},{\"a\":\"x\"}]"))
        XCTAssertTrue(TokenSaverWaveALossless.isHomogeneousJSON("[1,2,3]"))
        XCTAssertTrue(TokenSaverWaveALossless.isHomogeneousJSON("[{\"a\":1},{\"a\":2}]"))
    }

    func test_jsonGainGate() {
        let original = """
        {
          "a": 1,
          "b": 2,
          "c": 3
        }
        """
        let compact = "{\"a\":1,\"b\":2,\"c\":3}"
        XCTAssertTrue(TokenSaverWaveALossless.structuredJSONAllows(original: original, collapsed: compact))
        // No gain
        XCTAssertFalse(TokenSaverWaveALossless.structuredJSONAllows(original: compact, collapsed: compact))
    }

    func test_exactReplayCaps() {
        let d = Data("e".utf8)
        XCTAssertTrue(TokenSaverWaveALossless.exactReplayAllows(first: d, second: d, isMostRecent: false, pointerCount: 8))
        XCTAssertFalse(TokenSaverWaveALossless.exactReplayAllows(first: d, second: d, isMostRecent: false, pointerCount: 9))
        XCTAssertFalse(TokenSaverWaveALossless.exactReplayAllows(first: d, second: d, isMostRecent: true, pointerCount: 1))
    }

    func test_unchangedReread_requiresRangeAndHandle() {
        XCTAssertTrue(TokenSaverWaveALossless.unchangedRereadAllows(
            samePath: true, sameHash: true, sameRange: true, handlePresent: true, retrievalActive: true
        ))
        XCTAssertFalse(TokenSaverWaveALossless.unchangedRereadAllows(
            samePath: true, sameHash: true, sameRange: false, handlePresent: true, retrievalActive: true
        ))
    }

    func test_scorecard_shadow() {
        let board = TokenSaverWaveALossless.Scoreboard()
        TokenSaverWaveALossless.observeShadow(
            trigger: .repeatedLog, eligible: true, wouldAccept: true,
            bindingDigest: "b1", scoreboard: board
        )
        TokenSaverWaveALossless.observeShadow(
            trigger: .repeatedLog, eligible: true, wouldAccept: false,
            bindingDigest: "b1", scoreboard: board
        )
        let s = board.snapshot(bindingDigest: "b1", trigger: .repeatedLog)
        XCTAssertEqual(s.eligible, 2)
        XCTAssertEqual(s.attempted, 2) // every observe is attempted
        XCTAssertEqual(s.accepted, 1)
        XCTAssertEqual(s.fallback, 1)
        // Different BindingID is independent
        XCTAssertEqual(board.snapshot(bindingDigest: "b2", trigger: .repeatedLog).eligible, 0)
    }

    func test_scorecardBoundsDistinctBindings() {
        let board = TokenSaverWaveALossless.Scoreboard(maxEntries: 2)
        for binding in ["b1", "b2", "b3"] {
            TokenSaverWaveALossless.observeShadow(
                trigger: .repeatedLog,
                eligible: true,
                wouldAccept: true,
                bindingDigest: binding,
                scoreboard: board
            )
        }
        XCTAssertEqual(board.snapshot(bindingDigest: "b1", trigger: .repeatedLog).eligible, 1)
        XCTAssertEqual(board.snapshot(bindingDigest: "b2", trigger: .repeatedLog).eligible, 1)
        XCTAssertEqual(board.snapshot(bindingDigest: "b3", trigger: .repeatedLog).eligible, 0)
    }

    func test_jsonRejectsUnparseableCollapsed() {
        let original = "{ \"a\": 1, \"b\": 2, \"c\": 3, \"d\": 4, \"e\": 5 }"
        XCTAssertFalse(TokenSaverWaveALossless.structuredJSONAllows(original: original, collapsed: "not-json"))
    }

    func test_repeatedLog_storelessExpandEqualsOriginal() {
        let log = (0..<10).map { _ in "progress..." }.joined(separator: "\n") + "\nexit code: 1\n"
        guard let collapsed = TokenSaverWaveALossless.collapseStorelessLog(log) else {
            return XCTFail("expected collapse")
        }
        XCTAssertEqual(TokenSaverWaveALossless.expandStorelessLog(collapsed), log)
        XCTAssertTrue(TokenSaverWaveALossless.repeatedLogAllows(original: log))
        XCTAssertTrue(TokenSaverWaveALossless.repeatedLogInvertible(original: log))
    }
}
