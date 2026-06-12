import XCTest
@testable import CoreModel

/// Tests for RC2CLIDiagnostics.
///
/// WHY each test exists:
///   - missingFlag must embed the exact flag name so a user who omits e.g.
///     --workspace is told "--workspace" was missing, not a generic usage dump.
///   - invalidValue must embed the flag name for the same reason.
///   - unknownSubcommand must embed both the bad subcommand and the parent
///     command so the user knows exactly where the parse failed.
final class RC2CLIDiagnosticsTests: XCTestCase {

    // MARK: - missingFlag

    func test_missingFlag_containsFlagName() {
        // WHY: the diagnostic must name the missing flag so the user can fix
        //      their invocation without reading the full usage text.
        let msg = RC2CLIDiagnostics.missingFlag("workspace")
        XCTAssertTrue(msg.contains("--workspace"),
                      "missingFlag('workspace') must contain '--workspace'; got: \(msg)")
    }

    func test_missingFlag_prefixedWithError() {
        // WHY: the "error:" prefix lets scripts detect diagnostic lines from
        //      normal output on stderr.
        let msg = RC2CLIDiagnostics.missingFlag("id")
        XCTAssertTrue(msg.hasPrefix("error:"),
                      "missingFlag message must start with 'error:'; got: \(msg)")
    }

    func test_missingFlag_variousFlagNames() {
        // WHY: the helper must work for every flag name used across all guards,
        //      not just a hardcoded subset.
        for flag in ["thread", "text", "type", "pane", "direction", "split", "ratios",
                     "ref", "url", "selector", "script", "value", "window"] {
            let msg = RC2CLIDiagnostics.missingFlag(flag)
            XCTAssertTrue(msg.contains("--\(flag)"),
                          "missingFlag('\(flag)') must contain '--\(flag)'; got: \(msg)")
        }
    }

    // MARK: - invalidValue

    func test_invalidValue_containsFlagName() {
        // WHY: when a flag is present but its value is unusable (e.g. non-numeric
        //      --port) the message must still name the flag.
        let msg = RC2CLIDiagnostics.invalidValue(for: "port")
        XCTAssertTrue(msg.contains("--port"),
                      "invalidValue(for:'port') must contain '--port'; got: \(msg)")
    }

    func test_invalidValue_prefixedWithError() {
        let msg = RC2CLIDiagnostics.invalidValue(for: "timeout")
        XCTAssertTrue(msg.hasPrefix("error:"),
                      "invalidValue message must start with 'error:'; got: \(msg)")
    }

    // MARK: - unknownSubcommand

    func test_unknownSubcommand_containsBothNames() {
        // WHY: the user must know both WHICH subcommand was wrong AND for which
        //      parent command, so they can fix the invocation immediately.
        let msg = RC2CLIDiagnostics.unknownSubcommand("frobnicate", of: "pane")
        XCTAssertTrue(msg.contains("frobnicate"),
                      "unknownSubcommand must contain the bad sub name; got: \(msg)")
        XCTAssertTrue(msg.contains("pane"),
                      "unknownSubcommand must contain the parent command name; got: \(msg)")
    }

    func test_unknownSubcommand_prefixedWithError() {
        let msg = RC2CLIDiagnostics.unknownSubcommand("bad", of: "browser")
        XCTAssertTrue(msg.hasPrefix("error:"),
                      "unknownSubcommand message must start with 'error:'; got: \(msg)")
    }
}
