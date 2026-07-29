import Foundation

/// Strips raw tool-invocation markup from final user-facing assistant text.
///
/// WHY: when a headless/autonomous run references a tool that is not available,
/// providers sometimes emit the invocation as *plain text* (e.g. a mangled
/// `<ScheduleWakeup>…</invoke>` block) instead of a real tool call. That text was
/// being persisted and rendered in the transcript, then the run reported
/// `.completed` and the thread silently stalled. This sanitizer is the
/// provider-agnostic choke point (mirrors `RetrieveHandleSanitizer`) that removes
/// the markup before persistence/display.
///
/// Detection signal: after stripping, a durable machine marker is left so
/// `IncompleteTurnContinuation` can still classify the turn as incomplete (the
/// raw markup itself must not remain in the transcript). The marker is stripped
/// at the render layer via `BackgroundAwaitContinuation.strippingAwaitingMarker`.
///
/// MUST NOT alter text inside fenced code blocks (``` … ```) or inline code
/// spans — legitimate documentation of tool syntax must survive.
public enum AssistantToolMarkupSanitizer {
    /// Machine marker left after stripping raw tool markup so incomplete-turn
    /// classification still fires on the sanitized final message.
    public static let uncalledToolMarker = "[[RC_UNCALLED_TOOL]]"

    // MARK: - Public API

    /// True when `text` contains tool-invocation markup outside code spans/fences.
    public static func contains(_ text: String) -> Bool {
        var found = false
        _ = mapNonCodeSegments(text) { segment in
            if !found && segmentContainsMarkup(segment) {
                found = true
            }
            return segment
        }
        return found
    }

    /// True when the message carries an uncalled-tool signal: the durable marker
    /// (post-sanitize) and/or raw markup (pre-sanitize / bypass path).
    public static func containsUncalledToolSignal(_ text: String) -> Bool {
        if text.range(of: uncalledToolMarker, options: .caseInsensitive) != nil {
            return true
        }
        return contains(text)
    }

    /// Removes tool-invocation markup outside code spans/fences. Does **not**
    /// inject the detection marker — use `sanitize` for final-assistant text.
    public static func strip(_ text: String) -> String {
        let mapped = mapNonCodeSegments(text) { stripMarkup(in: $0) }
        return tidyWhitespace(mapped)
    }

    /// Strip markup and, when any was removed (or already signalled), ensure the
    /// durable `uncalledToolMarker` is present so incomplete-turn recovery fires.
    public static func sanitize(_ text: String) -> String {
        let hadSignal = containsUncalledToolSignal(text)
        let stripped = strip(text)
        guard hadSignal else { return stripped }
        return prefixingUncalledToolMarker(stripped)
    }

    /// Removes `uncalledToolMarker` from user-facing text. Detection keys on the
    /// marker, but the transcript must never show it — same contract as
    /// `BackgroundAwaitContinuation.strippingAwaitingMarker` for `[[RC_AWAITING]]`.
    public static func strippingUncalledToolMarker(_ text: String) -> String {
        guard text.range(of: uncalledToolMarker, options: .caseInsensitive) != nil else {
            return text
        }
        let pattern = NSRegularExpression.escapedPattern(for: uncalledToolMarker)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return tidyWhitespace(stripped)
    }

    // MARK: - Marker

    /// Idempotent prefix of `uncalledToolMarker` + newline.
    private static func prefixingUncalledToolMarker(_ text: String) -> String {
        if text.range(of: uncalledToolMarker, options: .caseInsensitive) != nil {
            return text
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return uncalledToolMarker }
        return uncalledToolMarker + "\n" + body
    }

    // MARK: - Markup detection / strip (prose segments only)

    private static func segmentContainsMarkup(_ segment: String) -> Bool {
        let ns = segment as NSString
        let full = NSRange(location: 0, length: ns.length)
        for regex in markupRegexes {
            if regex.firstMatch(in: segment, options: [], range: full) != nil {
                return true
            }
        }
        return false
    }

    private static func stripMarkup(in segment: String) -> String {
        var result = segment
        // Repeat until stable: outer wrappers may reveal inner invoke/parameter runs.
        var previous = ""
        while previous != result {
            previous = result
            for regex in markupRegexes {
                let full = NSRange(location: 0, length: (result as NSString).length)
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: full,
                    withTemplate: ""
                )
            }
        }
        return result
    }

    /// Patterns for tool-invocation markup. Order is not load-bearing because
    /// strip loops to a fixed point; listed from most specific wrappers first.
    private static let markupRegexes: [NSRegularExpression] = {
        let patterns = [
            // <function_calls>…</function_calls> and <function_results>…</function_results>
            #"(?s)<function_calls\b[^>]*>.*?</function_calls>"#,
            #"(?s)<function_results\b[^>]*>.*?</function_results>"#,
            // Canonical / namespaced: <invoke …>, <ns:invoke …>
            #"(?s)<(?:[A-Za-z_][\w-]*:)?invoke\b[^>]*>.*?</invoke>"#,
            // Mangled open-by-tool-name closed by </invoke> (incident form):
            // <ScheduleWakeup>\n<parameter …>…</parameter>…</invoke>
            // Exclude real tags that have their own handlers (invoke/function_*/parameter).
            #"(?s)<(?!/|(?:[A-Za-z_][\w-]*:)?invoke\b|function_calls\b|function_results\b|parameter\b)([A-Za-z_][\w]*)\s*>\s*(?:<parameter\b[^>]*>.*?</parameter>\s*)+</invoke>"#,
            // Standalone <parameter name="…">…</parameter> runs left after a partial strip
            #"(?s)<parameter\s+name\s*=\s*"[^"]*"\s*>.*?</parameter>"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    // MARK: - Code-span / fence preservation

    /// Applies `transform` only to segments that are neither fenced code blocks
    /// (``` … ```) nor inline code spans (` … `). Code segments are copied
    /// verbatim so docs that quote tool syntax survive.
    private static func mapNonCodeSegments(_ text: String, transform: (String) -> String) -> String {
        var output = ""
        var i = text.startIndex
        let end = text.endIndex
        while i < end {
            // Fenced code block (``` … ```), including unclosed tail as code.
            if text[i...].hasPrefix("```") {
                let fenceStart = i
                var j = text.index(i, offsetBy: 3, limitedBy: end) ?? end
                if let close = text.range(of: "```", range: j..<end) {
                    j = close.upperBound
                    output += text[fenceStart..<j]
                    i = j
                } else {
                    output += text[fenceStart...]
                    break
                }
                continue
            }
            // Inline code span (` … `). Unclosed tail treated as code.
            if text[i] == "`" {
                let spanStart = i
                let after = text.index(after: i)
                if let close = text[after...].firstIndex(of: "`") {
                    let spanEnd = text.index(after: close)
                    output += text[spanStart..<spanEnd]
                    i = spanEnd
                } else {
                    output += text[spanStart...]
                    break
                }
                continue
            }
            // Prose until the next backtick (fence or inline).
            let proseStart = i
            while i < end && text[i] != "`" {
                i = text.index(after: i)
            }
            output += transform(String(text[proseStart..<i]))
        }
        return output
    }

    // MARK: - Whitespace

    private static func tidyWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
