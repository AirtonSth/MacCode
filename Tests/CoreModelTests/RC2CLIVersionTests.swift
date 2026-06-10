import XCTest
@testable import CoreModel

/// Tests for RC2CLIVersion - the canonical version-string builder for `rc2 --version`.
///
/// WHY each test exists:
///   - `rc2 --version` printed nothing; users and scripts had no way to know
///     which CLI or protocol version they were talking to.
///   - The version string must include BOTH the CLI version and the protocol
///     version so callers can distinguish a new CLI talking to an old daemon from
///     any other combination.
///   - The format must be stable (machine-parseable for scripts) and informative
///     (human-readable in one line).
final class RC2CLIVersionTests: XCTestCase {

    // MARK: - version string content

    func test_versionString_containsCLIVersion() {
        // WHY: scripts must be able to grep for "rc2 1.0.0" to verify the CLI build.
        let s = RC2CLIVersion.versionString(cliVersion: "1.0.0", protocolVersion: "2.0")
        XCTAssertTrue(s.contains("1.0.0"),
                      "version string must embed the CLI version")
    }

    func test_versionString_containsProtocolVersion() {
        // WHY: callers need to confirm the RPC protocol level without launching the daemon.
        let s = RC2CLIVersion.versionString(cliVersion: "1.0.0", protocolVersion: "2.0")
        XCTAssertTrue(s.contains("2.0"),
                      "version string must embed the protocol version")
    }

    func test_versionString_isSingleLine() {
        // WHY: --version output is typically one line; multi-line breaks "grep -q" pipelines.
        let s = RC2CLIVersion.versionString(cliVersion: "1.0.0", protocolVersion: "2.0")
        XCTAssertFalse(s.contains("\n"),
                       "version string must fit on a single line")
    }

    func test_versionString_differentVersionsProduceDifferentStrings() {
        // WHY: proves the function actually uses its arguments, not hardcoded literals.
        let s1 = RC2CLIVersion.versionString(cliVersion: "1.0.0", protocolVersion: "2.0")
        let s2 = RC2CLIVersion.versionString(cliVersion: "2.0.0", protocolVersion: "2.0")
        XCTAssertNotEqual(s1, s2,
                          "different CLI versions must produce different output - function must use its arguments")
    }

    func test_versionString_differentProtocolVersionsProduceDifferentStrings() {
        // WHY: proves protocolVersion argument is actually used.
        let s1 = RC2CLIVersion.versionString(cliVersion: "1.0.0", protocolVersion: "1.0")
        let s2 = RC2CLIVersion.versionString(cliVersion: "1.0.0", protocolVersion: "2.0")
        XCTAssertNotEqual(s1, s2,
                          "different protocol versions must produce different output - function must use its arguments")
    }

    // MARK: - constants

    func test_currentCLIVersion_isNonEmpty() {
        // WHY: RC2CLIVersion.currentCLIVersion is the single-source-of-truth constant
        //       used by main.swift; if it is empty, --version is useless.
        XCTAssertFalse(RC2CLIVersion.currentCLIVersion.isEmpty,
                       "currentCLIVersion must be a non-empty string")
    }

    func test_currentProtocolVersion_isNonEmpty() {
        // WHY: same reasoning - protocol version constant must have a value.
        XCTAssertFalse(RC2CLIVersion.currentProtocolVersion.isEmpty,
                       "currentProtocolVersion must be a non-empty string")
    }

    func test_defaultVersionString_usesConstants() {
        // WHY: the zero-argument convenience must be equivalent to passing the constants;
        //       confirms the convenience and constants stay in sync.
        let explicit = RC2CLIVersion.versionString(
            cliVersion: RC2CLIVersion.currentCLIVersion,
            protocolVersion: RC2CLIVersion.currentProtocolVersion)
        let convenience = RC2CLIVersion.versionString()
        XCTAssertEqual(explicit, convenience,
                       "zero-arg versionString() must equal versionString(currentCLIVersion, currentProtocolVersion)")
    }
}
