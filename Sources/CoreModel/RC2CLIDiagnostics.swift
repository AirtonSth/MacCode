/// Pure, nonisolated helpers for rc2 CLI argument-error diagnostics.
///
/// Lives in CoreModel (not RC2CLI) so the message format can be unit-tested
/// without importing an executable target.
public enum RC2CLIDiagnostics {

    /// Returns the standard "missing required flag" message for a single flag.
    ///
    /// WHY: every guard failure in main.swift must tell the user WHICH flag was
    /// absent, not just dump a generic usage block.
    ///
    /// Format: "error: missing required --<flag>"
    public static func missingFlag(_ flag: String) -> String {
        "error: missing required --\(flag)"
    }

    /// Returns the standard "invalid value" message for a flag.
    ///
    /// Format: "error: invalid value for --<flag>"
    public static func invalidValue(for flag: String) -> String {
        "error: invalid value for --\(flag)"
    }

    /// Returns the standard "unknown subcommand" message.
    ///
    /// Format: "error: unknown subcommand '<sub>' for '<cmd>'"
    public static func unknownSubcommand(_ sub: String, of cmd: String) -> String {
        "error: unknown subcommand '\(sub)' for '\(cmd)'"
    }
}
