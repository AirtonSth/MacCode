import XCTest
@testable import AgentRuntime
import CoreModel

/// Unit tests for ProviderStderrClassifier.shouldDisplay (via displayableStderr).
///
/// WHY: The classifier filters benign provider stderr noise (warnings, LLDB
/// debugger lines, deprecation notices) so the Agent App only surfaces fatal
/// errors. The existing tests cover `Warning:` prefix and "reading additional
/// input from stdin" but several filter branches are untested:
///   - `warn ` prefix (space-separated, e.g. "warn unable to...")
///   - ` warn ` mid-string (embedded warn keyword)
///   - LLDB debugger lines ("debuggerlldb.debuggerversionstore", "no debugger version")
///   - "deprecated" when combined with "error" (must NOT be suppressed)
///
/// All assertions target ProviderStderrClassifier.displayableStderr which is the
/// internal seam that filters and joins lines. nil = suppressed, non-nil = shown.
final class ProviderStderrClassifierTests: XCTestCase {

    // MARK: - warn prefix forms (both providers)

    /// WHY: Lines starting with "warn " (space after) are a common npm/node log
    /// format. They must be suppressed for both providers so Agent App sessions
    /// are not flooded with package manager noise during skill installs.
    func test_warnSpacePrefix_isSuppressedForClaude() {
        let result = ProviderStderrClassifier.displayableStderr(
            "warn unable to find dependency graph\n",
            provider: .claude
        )
        XCTAssertNil(result,
                     "Lines beginning with 'warn ' must be suppressed for claude; " +
                     "npm/node warn lines during skill install must not surface as fatal errors")
    }

    func test_warnSpacePrefix_isSuppressedForCodex() {
        let result = ProviderStderrClassifier.displayableStderr(
            "warn unable to find dependency graph\n",
            provider: .codex
        )
        XCTAssertNil(result,
                     "Lines beginning with 'warn ' must be suppressed for codex; " +
                     "npm/node warn lines during skill install must not surface as fatal errors")
    }

    // MARK: - embedded warn keyword

    /// WHY: The filter also suppresses lines containing " warn " (space-padded)
    /// anywhere, e.g. "npm warn peer dep mismatch". Without this, toolchain
    /// advisory lines appear as fatal errors in the Agent App transcript.
    func test_embeddedWarnKeyword_isSuppressed() {
        let result = ProviderStderrClassifier.displayableStderr(
            "npm warn peer dep mismatch for react\n",
            provider: .claude
        )
        XCTAssertNil(result,
                     "Lines containing ' warn ' mid-string must be suppressed; " +
                     "npm warn advisory lines must not be mistaken for fatal provider errors")
    }

    // MARK: - LLDB / debugger lines

    /// WHY: Ghostty and some macOS toolchains emit LLDB debugger lines to stderr
    /// when launched via Xcode or a debug-attached shell. These must never surface
    /// as user-visible errors since they are debugger noise, not provider failures.
    func test_lldbDebuggerVersionStoreLine_isSuppressed() {
        let result = ProviderStderrClassifier.displayableStderr(
            "DebuggerLLDB.DebuggerVersionStore: loading debug info\n",
            provider: .claude
        )
        XCTAssertNil(result,
                     "LLDB debugger version store lines must be suppressed; " +
                     "they appear in debug-attached sessions and must not look like claude errors")
    }

    func test_noDebuggerVersionLine_isSuppressed() {
        let result = ProviderStderrClassifier.displayableStderr(
            "no debugger version available for this build\n",
            provider: .codex
        )
        XCTAssertNil(result,
                     "'no debugger version' lines must be suppressed; " +
                     "they are debugger environment noise, not codex runtime errors")
    }

    // MARK: - deprecated WITH error word must NOT be suppressed

    /// WHY: The filter suppresses "deprecated" lines ONLY when "error" is absent.
    /// A line like "DeprecatedError: use X instead" is a real error that must
    /// remain visible. Without this exception, genuine DeprecatedError exceptions
    /// would be silently swallowed and the Agent App would appear hung.
    func test_deprecatedWithErrorWord_isDisplayed() {
        let result = ProviderStderrClassifier.displayableStderr(
            "DeprecatedError: use X instead of Y\n",
            provider: .claude
        )
        XCTAssertNotNil(result,
                        "Lines containing both 'deprecated' and 'error' must NOT be suppressed; " +
                        "DeprecatedError exceptions are real failures that the user must see")
        XCTAssertEqual(result, "DeprecatedError: use X instead of Y",
                       "The displayed text must match the trimmed line content")
    }

    // MARK: - empty line is always suppressed

    /// WHY: Empty lines and whitespace-only lines carry no information. They must
    /// be dropped so the error display stays clean regardless of provider.
    func test_emptyLine_isSuppressed() {
        let result = ProviderStderrClassifier.displayableStderr(
            "\n\n   \n",
            provider: .claude
        )
        XCTAssertNil(result,
                     "Whitespace-only stderr must be suppressed; no content means no error to display")
    }

    // MARK: - fatal lines are preserved

    /// WHY: Non-warning, non-deprecated, non-LLDB lines that represent actual
    /// errors must always pass through for both providers.
    func test_fatalAuthenticationError_isDisplayed() {
        let result = ProviderStderrClassifier.displayableStderr(
            "Error: authentication token expired\n",
            provider: .claude
        )
        XCTAssertNotNil(result,
                        "Fatal authentication errors must remain visible; " +
                        "suppressing them makes provider auth loss look like an app freeze")
    }

    func test_fatalSocketError_isDisplayedForCodex() {
        let result = ProviderStderrClassifier.displayableStderr(
            "socket connection refused on port 8080\n",
            provider: .codex
        )
        XCTAssertNotNil(result,
                        "Fatal socket errors must remain visible for codex; " +
                        "suppressing them hides network-level provider failures from the user")
    }
}
