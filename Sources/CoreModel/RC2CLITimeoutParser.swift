/// Pure, nonisolated parser for the rc2 `--timeout MS` global flag.
///
/// Accepts both space-separated form (`--timeout 5000`) and inline-equals form
/// (`--timeout=5000`).  Returns `nil` when the flag is absent.  Returns `nil`
/// for non-numeric or negative values and records the invalid value so the CLI
/// can fail loud before opening a socket.
///
/// Rule: only `--timeout` tokens are consumed; the remainder of the array is
/// returned unchanged so the existing arg-loop is unaffected.
public enum RC2CLITimeoutParser {
    /// Default receive guard for one-shot rc2 RPCs.
    ///
    /// WHY: when the daemon accepts a Unix socket connection but never sends a
    /// JSON-RPC line, the CLI must fail bounded instead of hanging forever.
    public static let defaultReceiveTimeoutMS = 5_000

    public struct Result {
        /// Parsed timeout in milliseconds, or nil when absent/invalid.
        public let timeoutMS: Int?
        /// Remaining args with the `--timeout` token(s) removed.
        public let remaining: [String]
        /// Raw invalid timeout value, or nil when absent/valid.
        public let invalidValue: String?
    }

    /// Parse `--timeout MS` / `--timeout=MS` from `args`.
    ///
    /// - Parameter args: raw CLI args (may include program name at index 0 or not).
    /// - Returns: `Result` with the extracted value and the cleaned arg list.
    public static func parse(_ args: [String]) -> Result {
        var remaining: [String] = []
        var timeoutMS: Int? = nil
        var invalidValue: String? = nil
        var i = args.startIndex

        func accept(_ raw: String) {
            if let parsed = validated(raw) {
                timeoutMS = parsed
                invalidValue = nil
            } else {
                timeoutMS = nil
                invalidValue = raw
            }
        }

        while i < args.endIndex {
            let token = args[i]

            // Inline-equals form: --timeout=MS
            if token.hasPrefix("--timeout=") {
                let raw = String(token.dropFirst("--timeout=".count))
                accept(raw)
                i = args.index(after: i)
                continue
            }

            // Space-separated form: --timeout MS
            if token == "--timeout" {
                let next = args.index(after: i)
                if next < args.endIndex {
                    let raw = args[next]
                    accept(raw)
                    i = args.index(after: next)
                    continue
                }
                // --timeout at end of args with no value — ignore, drop token
                i = args.index(after: i)
                continue
            }

            remaining.append(token)
            i = args.index(after: i)
        }

        return Result(timeoutMS: timeoutMS, remaining: remaining, invalidValue: invalidValue)
    }

    // MARK: - private

    /// Returns `ms` if it is a positive integer; nil otherwise.
    /// Zero is excluded — a zero receive-timeout disables the timeout on most
    /// platforms, which would silently remove the guard we are adding.
    private static func validated(_ raw: String) -> Int? {
        guard let ms = Int(raw), ms > 0 else { return nil }
        return ms
    }
}
