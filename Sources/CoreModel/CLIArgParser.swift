/// Pure argument parser for the rc2 CLI.
///
/// Improvements over the original inline `parseFlags`:
///   1. `--flag=value` inline form - the only unambiguous way to pass a value
///      that starts with one or more dashes (e.g. `--text=--foo`).
///   2. `--` terminator - stops option parsing; every subsequent token is
///      treated as a positional argument regardless of its prefix.
///
/// The space-separated `--flag value` form is preserved so existing callers
/// are unaffected.  The rule for space-separated form is unchanged: if the
/// next token looks like a flag (`--`) it is NOT consumed as the value; the
/// current flag is set to `"true"` instead.
public enum CLIArgParser {

    /// Parse an argument list into (flags, positionals).
    ///
    /// - Parameter args: tokens to parse (typically `CommandLine.arguments`
    ///                   with the program name and any global flags already
    ///                   removed).
    /// - Returns: A tuple of
    ///   - `flags`: dictionary of flag name → value string (`"true"` for
    ///              boolean flags).
    ///   - `positional`: ordered array of non-flag tokens.
    public static func parseFlagsWithTerminator(_ args: [String]) -> ([String: String], [String]) {
        var flags: [String: String] = [:]
        var positional: [String] = []
        var i = args.startIndex
        var terminated = false          // true once we see "--"

        while i < args.endIndex {
            let token = args[i]

            if terminated {
                positional.append(token)
                i = args.index(after: i)
                continue
            }

            if token == "--" {
                terminated = true
                i = args.index(after: i)
                continue
            }

            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))   // e.g. "flag=value" or "flag"

                if let eqRange = body.range(of: "=") {
                    // Inline form: --flag=value  (value may be empty or start with "-")
                    let key   = String(body[body.startIndex..<eqRange.lowerBound])
                    let value = String(body[eqRange.upperBound...])
                    flags[key] = value
                } else {
                    // Space-separated form: consume next token as value only if it
                    // does NOT look like another flag (preserves legacy behaviour).
                    let next = args.index(after: i)
                    if next < args.endIndex && !args[next].hasPrefix("--") {
                        flags[body] = args[next]
                        i = args.index(after: next)
                        continue
                    } else {
                        flags[body] = "true"
                    }
                }
            } else {
                positional.append(token)
            }

            i = args.index(after: i)
        }

        return (flags, positional)
    }
}
