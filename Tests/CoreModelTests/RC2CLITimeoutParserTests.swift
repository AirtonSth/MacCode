import XCTest
@testable import CoreModel

/// Tests for RC2CLITimeoutParser.
///
/// WHY each test exists:
///   - `--timeout MS` (space form) must be the canonical way to set a receive
///     timeout so rc2 calls cannot block forever on a slow or dead daemon.
///   - `--timeout=MS` (equals form) must also work so values that start with
///     a dash can be passed unambiguously, consistent with CLIArgParser.
///   - Absent flag must return nil so the caller can apply a safe fallback
///     rather than setting SO_RCVTIMEO to a garbage value.
///   - Non-numeric / negative / zero values must return nil to avoid silently
///     installing a useless or counterproductive receive timeout.
///   - The `--timeout` token(s) must be removed from the remaining args so
///     the rest of the arg loop sees a clean list.
final class RC2CLITimeoutParserTests: XCTestCase {

    // MARK: - space-separated form

    func test_spaceSeparated_parsesPositiveInteger() {
        // WHY: `--timeout 5000` is the expected human-readable form.
        let result = RC2CLITimeoutParser.parse(["--timeout", "5000"])
        XCTAssertEqual(result.timeoutMS, 5000,
                       "--timeout 5000 must produce timeoutMS = 5000")
    }

    func test_spaceSeparated_tokenRemovedFromRemaining() {
        // WHY: the global arg loop must not see --timeout after parsing.
        let result = RC2CLITimeoutParser.parse(["--socket", "/tmp/a.sock", "--timeout", "3000", "ping"])
        XCTAssertEqual(result.timeoutMS, 3000)
        XCTAssertEqual(result.remaining, ["--socket", "/tmp/a.sock", "ping"],
                       "--timeout and its value must be stripped from remaining args")
    }

    // MARK: - inline-equals form

    func test_inlineEquals_parsesPositiveInteger() {
        // WHY: `--timeout=5000` is the unambiguous form consistent with CLIArgParser.
        let result = RC2CLITimeoutParser.parse(["--timeout=5000"])
        XCTAssertEqual(result.timeoutMS, 5000,
                       "--timeout=5000 must produce timeoutMS = 5000")
    }

    func test_inlineEquals_tokenRemovedFromRemaining() {
        // WHY: inline form must also clean remaining args.
        let result = RC2CLITimeoutParser.parse(["--timeout=1500", "--json", "workspaces"])
        XCTAssertEqual(result.timeoutMS, 1500)
        XCTAssertEqual(result.remaining, ["--json", "workspaces"])
    }

    // MARK: - absent flag

    func test_absent_returnsNilTimeout() {
        // WHY: when --timeout is not given the caller must use its default
        //      (no setsockopt call), not a zero or undefined value.
        let result = RC2CLITimeoutParser.parse(["--json", "ping"])
        XCTAssertNil(result.timeoutMS,
                     "absent --timeout must produce nil so caller applies its own default")
    }

    func test_absent_remainingIsUnchanged() {
        // WHY: args without --timeout must pass through unmodified.
        let args = ["--socket", "/tmp/rc.sock", "--json", "workspaces"]
        let result = RC2CLITimeoutParser.parse(args)
        XCTAssertEqual(result.remaining, args)
    }

    func test_defaultReceiveTimeoutIsPositiveAndBounded() {
        // WHY: a daemon can accept the Unix socket and then stop responding;
        //      rc2 must have a default one-shot RPC guard even when the user
        //      does not pass --timeout.
        XCTAssertGreaterThan(RC2CLITimeoutParser.defaultReceiveTimeoutMS, 0)
        XCTAssertLessThanOrEqual(RC2CLITimeoutParser.defaultReceiveTimeoutMS, 30_000,
                                 "default receive timeout must be bounded enough to avoid a stuck CLI")
    }

    // MARK: - invalid values

    func test_nonNumericValue_returnsNil() {
        // WHY: `--timeout abc` is a user mistake; nil lets the caller fail-safe
        //      to no timeout rather than silently applying Int("abc") = 0.
        let result = RC2CLITimeoutParser.parse(["--timeout", "abc"])
        XCTAssertNil(result.timeoutMS,
                     "non-numeric value must return nil")
        XCTAssertEqual(result.invalidValue, "abc",
                       "non-numeric timeout must be reported so rc2 can fail loud instead of connecting with a misleading socket error")
    }

    func test_negativeValue_returnsNil() {
        // WHY: a negative SO_RCVTIMEO is meaningless; guard against it.
        let result = RC2CLITimeoutParser.parse(["--timeout", "-1"])
        XCTAssertNil(result.timeoutMS,
                     "negative timeout must return nil")
        XCTAssertEqual(result.invalidValue, "-1",
                       "negative timeout must be reported so rc2 can fail loud before opening the socket")
    }

    func test_zeroValue_returnsNil() {
        // WHY: SO_RCVTIMEO = 0 disables the timeout on most platforms, which
        //      defeats the purpose of passing --timeout 0.  Treat it as invalid.
        let result = RC2CLITimeoutParser.parse(["--timeout", "0"])
        XCTAssertNil(result.timeoutMS,
                     "zero timeout must return nil to avoid disabling the guard")
        XCTAssertEqual(result.invalidValue, "0",
                       "zero timeout must be reported so rc2 can explain the validation error")
    }

    func test_inlineEquals_nonNumeric_returnsNil() {
        // WHY: equals form must apply the same validation as space form.
        let result = RC2CLITimeoutParser.parse(["--timeout=notanumber"])
        XCTAssertNil(result.timeoutMS)
        XCTAssertEqual(result.invalidValue, "notanumber")
    }

    // MARK: - edge cases

    func test_emptyArgs_returnsNilAndEmptyRemaining() {
        let result = RC2CLITimeoutParser.parse([])
        XCTAssertNil(result.timeoutMS)
        XCTAssertTrue(result.remaining.isEmpty)
    }

    func test_timeoutAtEndWithNoValue_dropsSilently() {
        // WHY: `--timeout` with no following value should not crash or consume
        //      the next unrelated token; it drops the bare flag silently.
        let result = RC2CLITimeoutParser.parse(["ping", "--timeout"])
        XCTAssertNil(result.timeoutMS)
        XCTAssertEqual(result.remaining, ["ping"])
    }

    func test_lastWriteWins_twoTimeoutFlags() {
        // WHY: if both forms appear, the later one overrides the earlier one —
        //      consistent with CLIArgParser duplicate-flag semantics.
        let result = RC2CLITimeoutParser.parse(["--timeout", "1000", "--timeout=2000"])
        XCTAssertEqual(result.timeoutMS, 2000,
                       "later --timeout must override earlier one")
        XCTAssertNil(result.invalidValue)
    }

    func test_lastWriteWins_laterInvalidTimeoutIsReported() {
        // WHY: if the final timeout flag is invalid, rc2 must fail loud instead
        // of silently using an earlier valid timeout that the user tried to replace.
        let result = RC2CLITimeoutParser.parse(["--timeout", "1000", "--timeout=0"])
        XCTAssertNil(result.timeoutMS)
        XCTAssertEqual(result.invalidValue, "0")
    }
}
