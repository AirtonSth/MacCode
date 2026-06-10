import XCTest
@testable import CoreModel

/// Tests for CLIArgParser.parseFlagsWithTerminator.
///
/// WHY each test exists:
///   - Values beginning with -- (e.g. --text "--foo") were silently dropped
///     by the old parseFlags that checked `!a[i+1].hasPrefix("--")`. Any flag
///     value that looks like a flag was consumed as another flag key, which made
///     it impossible to pass text that starts with two dashes without quoting
///     tricks.  The new parser solves this via the "--flag=value" form.
///   - The "--" terminator is standard POSIX / GNU convention; callers need it
///     to pass arbitrary positional arguments after flag parsing stops.
///   - "--flag=value" is the only unambiguous form for values that start with
///     "-", so the new parser must handle it alongside "--flag value".
final class CLIArgParserTests: XCTestCase {

    // MARK: - basic flag parsing (existing behaviour preserved)

    func test_basicFlagValue_parsedAsFlag() {
        // WHY: --key value (space-separated) is the canonical existing form; must work.
        let (flags, pos) = CLIArgParser.parseFlagsWithTerminator(["--id", "abc123"])
        XCTAssertEqual(flags["id"], "abc123")
        XCTAssertTrue(pos.isEmpty)
    }

    func test_booleanFlag_setToTrue() {
        // WHY: --json with no following value must become "true" (existing contract).
        let (flags, _) = CLIArgParser.parseFlagsWithTerminator(["--json"])
        XCTAssertEqual(flags["json"], "true")
    }

    func test_positionalArgBeforeFlag_collected() {
        // WHY: positional args must be returned separately.
        let (flags, pos) = CLIArgParser.parseFlagsWithTerminator(["move", "--workspace", "w1"])
        XCTAssertEqual(flags["workspace"], "w1")
        XCTAssertEqual(pos, ["move"])
    }

    // MARK: - --flag=value inline form

    func test_inlineEqualForm_parsedCorrectly() {
        // WHY: "--flag=value" must split on first "=" so the key is "flag"
        //       and the value is the string after the "=".
        let (flags, pos) = CLIArgParser.parseFlagsWithTerminator(["--text=hello world"])
        XCTAssertEqual(flags["text"], "hello world")
        XCTAssertTrue(pos.isEmpty)
    }

    func test_inlineEqualForm_valueStartingWithDash() {
        // WHY: this is the core bug - callers need to pass values like "--foo"
        //       (e.g. agent send --text "--thinking step") using the = form.
        let (flags, pos) = CLIArgParser.parseFlagsWithTerminator(["--text=--thinking step"])
        XCTAssertEqual(flags["text"], "--thinking step",
                       "value starting with -- must be preserved when given as --flag=value")
        XCTAssertTrue(pos.isEmpty)
    }

    func test_inlineEqualForm_emptyValue() {
        // WHY: --flag= with nothing after the = means an explicitly empty string,
        //       not a missing value. Callers need to be able to clear a field.
        let (flags, _) = CLIArgParser.parseFlagsWithTerminator(["--title="])
        XCTAssertEqual(flags["title"], "")
    }

    func test_inlineEqualForm_valueContainingEquals() {
        // WHY: only the FIRST "=" splits; subsequent "=" belong to the value
        //       (e.g. base64 strings, URLs with query strings).
        let (flags, _) = CLIArgParser.parseFlagsWithTerminator(["--url=https://x.com?a=1&b=2"])
        XCTAssertEqual(flags["url"], "https://x.com?a=1&b=2")
    }

    // MARK: - "--" terminator

    func test_doubleHyphenTerminator_stopsFlagParsing() {
        // WHY: after "--" every token is positional, even if it looks like a flag.
        let (flags, pos) = CLIArgParser.parseFlagsWithTerminator(["--id", "s1", "--", "--foo", "bar"])
        XCTAssertEqual(flags["id"], "s1")
        XCTAssertEqual(pos, ["--foo", "bar"],
                       "tokens after -- must be positional even when they look like flags")
        XCTAssertNil(flags["foo"])
    }

    func test_doubleHyphenTerminator_atStart() {
        // WHY: "--" as first token means all args are positional.
        let (flags, pos) = CLIArgParser.parseFlagsWithTerminator(["--", "--id", "x"])
        XCTAssertTrue(flags.isEmpty)
        XCTAssertEqual(pos, ["--id", "x"])
    }

    func test_doubleHyphenTerminator_onlyTerminator() {
        // WHY: lone "--" produces empty flags and empty positional.
        let (flags, pos) = CLIArgParser.parseFlagsWithTerminator(["--"])
        XCTAssertTrue(flags.isEmpty)
        XCTAssertTrue(pos.isEmpty)
    }

    func test_positionalAfterTerminator_notTreatedAsFlag() {
        // WHY: "--flag value -- --otherflag" must keep --otherflag as positional.
        let (flags, pos) = CLIArgParser.parseFlagsWithTerminator(
            ["--workspace", "W1", "--", "--extra", "positional"])
        XCTAssertEqual(flags["workspace"], "W1")
        XCTAssertEqual(pos, ["--extra", "positional"])
    }

    // MARK: - edge cases

    func test_emptyInput_returnsEmpty() {
        let (flags, pos) = CLIArgParser.parseFlagsWithTerminator([])
        XCTAssertTrue(flags.isEmpty)
        XCTAssertTrue(pos.isEmpty)
    }

    func test_duplicateFlag_lastValueWins() {
        // WHY: callers may override earlier defaults by appending flags.
        let (flags, _) = CLIArgParser.parseFlagsWithTerminator(["--id", "first", "--id", "second"])
        XCTAssertEqual(flags["id"], "second")
    }

    func test_spaceFormWhereNextArgIsFlag_treatedAsBoolean() {
        // WHY: "--flag1 --flag2" (no value before next flag) - flag1 = "true",
        //       flag2 also needs its own value or defaults to "true".
        let (flags, _) = CLIArgParser.parseFlagsWithTerminator(["--json", "--id", "x"])
        XCTAssertEqual(flags["json"], "true")
        XCTAssertEqual(flags["id"], "x")
    }
}
