import CryptoKit
import Foundation

/// SR2 Opaque Agent IR — dense machine-only provider wire when Token Saver is ON.
///
/// Dual-channel contract:
/// - **Provider history** keeps wire (SR2/SR1) or an enforced stub — never free monologue.
/// - **UI** shows local humanize (or original prose when enforcement stored a handle).
///
/// Providers Claude, Codex, and Grok share this policy; only instruct injection adapters differ.
public enum SR2WirePolicy: Sendable {
    public static let version = "v1"
    public static let markerLine = "@sr2 v1"
    public static let optimizerVersion = version
    public static let optimizerMarkerLine = markerLine
    public static let legacyMarkerLine = "@sr2 v0"
    /// ACP has no negotiated system/developer content type. Its host leg uses
    /// this strict, separately parsed SR2 block instead of sharing the user's
    /// `@sr2 v1` body.
    public static let trustedHostMarkerLine = "@sr2 host v1"
    public static let instructBlockMarker = "REMOTE_CODE_SR2_ALWAYS_ON_V1"
    public static let structuredFieldKeys: Set<String> = [
        "g", "d", "p", "o", "e", "h", "t", "u",
        "flow", "done", "tools", "must", "should", "may", "not", "constraints", "outputs",
        "run", "out",
        "goal", "use", "browser", "auth", "pr", "comment", "trello-comment"
    ]
    public static let advertisedV1Sample = """
    @sr2 v1
    g:goal-id
    d:decision-id
    p:path:1
    o:ok
    e:none
    h:[[rc:handle]]
    """
    /// Source-compatible name for callers compiled against the earlier policy.
    /// Its bytes are deliberately current v1; no new instruction advertises v0.
    @available(*, deprecated, renamed: "advertisedV1Sample")
    public static let advertisedV0Sample = advertisedV1Sample
    public static let semanticV1Sample = """
    @sr2 v1
    run:command -v swift;command -v distill
    out:=2lines
    !file-edit
    """
    public static let naturalTaskV1Sample = """
    @sr2 v1
    t:open:tracker>pick:1st issue(status=Todo,asgn=sam,prio?=[urgent]@title-or-text)>impl:<ISSUE>(wt@updated main,/task,!review:task,must:test)>update:tracker
    """
    public static let trackerDeliveryV1Sample = """
    @sr2 v1
    goal:trello.Doing[0]>implement>verify>merge:main>verify-merge>trello:Testing
    use:trello-skill,/sam-task
    must:/sam-task.all,/sam-task.playwright,postdeploy-test
    browser:chrome|computer-use?
    auth:user@example.com|secret
    pr:gh,!glab
    trello-comment:gh.PR.url
    done:sam-task.all+playwright+deploy+postdeploy-test+merge-verified+trello-testing
    """

    /// Paid-feature providers that must ship the matrix together (T-SR2-09).
    public static let requiredProviders: [String] = ["claude", "codex", "grok"]

    public enum ChannelKind: String, Sendable, Equatable {
        case sr2
        case sr1
        case freeProse
        case empty
    }

    public struct Classification: Sendable, Equatable {
        public let kind: ChannelKind
        public let providerHistoryText: String
        public let uiSourceText: String
        public let needsHumanize: Bool
        public let wasEnforced: Bool
        public let complianceMiss: Bool

        public init(
            kind: ChannelKind,
            providerHistoryText: String,
            uiSourceText: String,
            needsHumanize: Bool,
            wasEnforced: Bool,
            complianceMiss: Bool
        ) {
            self.kind = kind
            self.providerHistoryText = providerHistoryText
            self.uiSourceText = uiSourceText
            self.needsHumanize = needsHumanize
            self.wasEnforced = wasEnforced
            self.complianceMiss = complianceMiss
        }
    }

    public struct EnforceResult: Sendable, Equatable {
        public let wireStub: String
        public let fullProse: String
        public let recoveryHandlePlaceholder: String

        public init(wireStub: String, fullProse: String, recoveryHandlePlaceholder: String) {
            self.wireStub = wireStub
            self.fullProse = fullProse
            self.recoveryHandlePlaceholder = recoveryHandlePlaceholder
        }
    }

    // MARK: - Detection

    public static func isSR2(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let first = lines[0].lowercased()
        let isOptimizerV1 = [optimizerMarkerLine, "sr2 v1"]
            .map { $0.lowercased() }
            .contains(first)
        let hasBanner = [legacyMarkerLine, markerLine, "sr2 v0", "sr2 v1"]
            .map { $0.lowercased() }
            .contains(first)
        if hasBanner {
            lines.removeFirst()
        }
        guard !lines.isEmpty else { return false }
        // Preserve the legacy bannerless form's minimum of an outcome plus
        // one additional structured field; bannered v0 action-only wires may
        // legitimately contain just `o:cont`.
        guard hasBanner || lines.count >= 2 else { return false }

        // Every body line must be a v0 field. This is deliberately strict:
        // accepting a banner before validating the body turns a provider's
        // banner-plus-monologue into a false compliant response.
        var hasOutcome = false
        for line in lines.prefix(20) {
            guard let field = structuredField(line) else { return false }
            if field.key == "o" {
                let outcome = field.value
                    .split(whereSeparator: { $0.isWhitespace })
                    .first
                    .map(String.init)
                    .map { $0.lowercased() }
                guard let outcome, ["ok", "done", "fail", "need", "cont"].contains(outcome) else {
                    return false
                }
                hasOutcome = true
            }
        }
        // A body longer than the inspected prefix is not allowed to smuggle
        // prose past the grammar either.
        guard lines.count <= 20 else { return false }
        // Runtime v0 is an outcome protocol and still requires `o:`. Optimizer
        // v1 is a semantic prompt IR: `flow:...` / `done:...` can be complete
        // without inventing an outcome that did not exist in the source.
        return isOptimizerV1 || hasOutcome
    }

    /// Current provider compliance is narrower than legacy readability. Old
    /// `@sr2 v0` threads still parse through `isSR2`, but only an exact v1
    /// banner/body is eligible to remain newly persisted provider history.
    public static func isCurrentSR2(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text == trimmed,
              trimmed.split(whereSeparator: \.isNewline).first?.lowercased()
                == markerLine.lowercased() else {
            return false
        }
        return isSR2(trimmed)
    }

    /// Provider-bound text with an SR2 banner must never fall back to raw UI
    /// merely because its body misses the strict grammar. This is intentionally
    /// narrower than a general text classifier: callers use it only after typed
    /// provider provenance, while natural assistant text may quote SR2 verbatim.
    public static func hasSR2Banner(_ text: String) -> Bool {
        guard let first = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first?
            .lowercased() else { return false }
        return [legacyMarkerLine, markerLine, "sr2 v0", "sr2 v1"]
            .map { $0.lowercased() }
            .contains(first)
    }

    /// Reject untrusted humanizer output that still contains provider wire.
    ///
    /// Whole-string SR1/SR2 classification is deliberately insufficient at
    /// this boundary: a local model can prepend one natural word and then emit
    /// a raw banner or field dump. This probe is only for text produced by the
    /// humanizer. Natural assistant/user content has no such provenance and
    /// must not be stripped merely because it quotes an SR2 example.
    public static func containsHumanizationWireSyntax(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.contains("@sr2 v0") || lower.contains("@sr2 v1")
            || lower.contains("sr2 v0") || lower.contains("sr2 v1")
            || lower.contains("[[rc:") {
            return true
        }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var legacySemanticLineCount = 0
        for line in lines {
            let lineLower = line.lowercased()
            let tokens = lineLower
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
            if tokens.contains("sr1")
                || lineLower == "dict"
                || lineLower.hasPrefix("dict:") {
                return true
            }
            if structuredField(line) != nil {
                return true
            }
            guard let first = line.first,
                  DistillSemanticPrefixes.contains(first),
                  line.count > 1 else { continue }
            let next = line[line.index(after: line.startIndex)]
            if next == ":" || next == "=" || next.isWhitespace {
                legacySemanticLineCount += 1
            }
        }
        // A trusted humanizer may naturally answer in Portuguese with a single
        // sentence such as "O Snake..." or "O jogo...". The old SR1 dialect is
        // a multi-line field dump at this boundary; markers and colon/equal
        // structured fields were rejected above independently.
        return legacySemanticLineCount >= 2
    }

    public static let unavailableStatusNote = "Status note unavailable"

    /// Host dual-channel stub: `@sr2 v1` + `o:ok` + `p:sha256=` + recovery `h:`.
    /// This is not model-authored SR2 and must never be the default UI body.
    public static func isCanonicalHistoryEnvelope(_ text: String) -> Bool {
        let lines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.first?.lowercased() == markerLine.lowercased() else { return false }
        var hasOutcomeOK = false
        var hasDigest = false
        var hasHandle = false
        for line in lines.dropFirst() {
            guard let field = structuredField(line) else { return false }
            switch field.key {
            case "o":
                let head = field.value
                    .split(whereSeparator: { $0.isWhitespace })
                    .first?
                    .lowercased()
                guard head == "ok" else { return false }
                hasOutcomeOK = true
            case "p":
                let lower = field.value.lowercased()
                guard lower.hasPrefix("sha256=") else { return false }
                let hex = String(field.value.dropFirst("sha256=".count))
                guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return false }
                hasDigest = true
            case "h":
                let payload = field.value
                let isHandle = payload.hasPrefix("[[rc:") && payload.hasSuffix("]]")
                let isInline = payload.hasPrefix(inlineOriginalPrefix)
                guard isHandle || isInline else { return false }
                hasHandle = true
            default:
                return false
            }
        }
        return hasOutcomeOK && hasDigest && hasHandle
    }

    /// Human-facing body for typed provider text. Recovers envelope originals,
    /// expands parseable SR2, and never returns protocol bytes as the default.
    /// Quoted SR2 inside natural prose is out of scope — callers use this only
    /// after provider provenance (`hasSR2Banner` on an item/final/thought).
    public static func humanReadableDisplay(
        stored: String,
        retrieve: ((String) -> String?)? = nil
    ) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return stored }
        if isCanonicalHistoryEnvelope(trimmed) {
            guard let original = providerOriginal(in: trimmed, retrieve: retrieve) else {
                return unavailableStatusNote
            }
            let originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !originalTrimmed.isEmpty, !isCanonicalHistoryEnvelope(originalTrimmed) else {
                return unavailableStatusNote
            }
            return humanReadableDisplay(stored: original, retrieve: nil)
        }
        if isSR2(trimmed) || hasSR2Banner(trimmed) || looksLikeCompressedAgentIR(trimmed) {
            return deterministicHumanizedWire(trimmed) ?? unavailableStatusNote
        }
        return stored
    }

    /// Banner-stripped leftovers still look like provider IR: several `g:`/`e:`
    /// lines, or English labels the model used instead of `d:`/`p:`.
    public static func looksLikeCompressedAgentIR(_ text: String) -> Bool {
        if hasSR2Banner(text) || isSR2(text) { return true }
        let lines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var hits = 0
        for line in lines.prefix(24) {
            if structuredField(line) != nil {
                hits += 1
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            guard key.count <= 40,
                  key.rangeOfCharacter(from: .whitespaces) == nil,
                  key.contains(where: \.isLetter) else { continue }
            let lower = key.lowercased()
            if lower == "action" || lower == "proof" || lower == "status"
                || lower == "next" || lower.hasPrefix("pr")
                || lower.hasPrefix("railway") || lower == "playwright"
                || lower == "trello" || lower == "comments" {
                hits += 1
            }
        }
        return hits >= 3
    }

    /// Deterministic last-resort UI rendering from a source that has already
    /// been classified as trusted wire. It never examines arbitrary natural
    /// prose. Status lives on `e:` — only fail/error values render as Error.
    public static func deterministicHumanizedWire(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSR2(trimmed) || hasSR2Banner(trimmed) || looksLikeCompressedAgentIR(trimmed) else {
            return nil
        }

        var outcomes: [String] = []
        var evidence: [String] = []
        var notes: [String] = []
        var narrativeNotes: [String] = []
        var semantics: [String] = []
        var mergedPRIds: [String] = []
        var prURLsById: [String: String] = [:]
        var nextStep: String?
        var actionMentionsBlocked = false
        var continuationOnly = false
        var hasOkOutcome = false
        let labels = [
            "g": "Goal", "d": "Decision", "t": "Task",
            "flow": "Next steps", "done": "Complete when", "tools": "Tools",
            "must": "Required", "should": "Recommended", "may": "Optional",
            "not": "Do not", "constraints": "Constraints", "outputs": "Outputs",
            "run": "Run", "out": "Expected output",
            "goal": "Goal", "use": "Use", "browser": "Browser", "auth": "Auth",
            "pr": "Pull request", "comment": "Comment", "trello-comment": "Trello comment",
        ]
        let statusLabels = [
            "ci": "Checks", "checks": "Checks", "pr": "Pull request",
            "url": "URL", "fix": "Fix", "head": "Head", "worktree": "Worktree",
            "railway": "Railway", "goal": "Goal", "elapsed": "Elapsed",
            "error": "Error", "fail": "Error",
        ]

        func readable(_ value: String) -> String {
            value
                .replacingOccurrences(of: ">", with: " then ")
                .replacingOccurrences(of: "+", with: " and ")
                .replacingOccurrences(of: "|", with: " or ")
        }
        func readableHyphens(_ value: String) -> String {
            if value.contains("://") { return value }
            return value.replacingOccurrences(of: "-", with: " ")
        }
        func sentence(_ value: String) -> String {
            let value = readable(value)
            return value.hasSuffix(".") ? value : value + "."
        }
        func evidenceLine(_ value: String) -> String? {
            let lower = value.lowercased()
            if lower.hasPrefix("sha256=") { return nil }
            if lower.hasPrefix("path:") {
                let rest = String(value.dropFirst(5))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.isEmpty { return nil }
                if rest.lowercased() == "final" { return nil }
                if rest.allSatisfy(\.isNumber) { return "Path \(rest)." }
                return "Path: \(sentence(rest))"
            }
            if let equals = value.firstIndex(of: "=") {
                let index = value[..<equals]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = value[value.index(after: equals)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !index.isEmpty, index.allSatisfy(\.isNumber), !detail.isEmpty {
                    return "Evidence \(index): \(sentence(detail))"
                }
            }
            return "Evidence: \(sentence(value))"
        }
        func ingestStatus(key: String, rest: String) {
            if key == "prs-merged" || key == "prs_merged" {
                mergedPRIds = rest
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return
            }
            if key.hasPrefix("pr"), key.count > 2, key.dropFirst(2).allSatisfy(\.isNumber) {
                prURLsById[String(key.dropFirst(2))] = rest
                return
            }
            if key == "next" {
                nextStep = nextStepNarrative(rest)
                return
            }
            if let narrative = trackerDeliveryStatusLine(key: key, rest: rest) {
                narrativeNotes.append(narrative)
                return
            }
            if let line = genericStatusLine(
                key: key,
                rest: rest,
                statusLabels: statusLabels,
                readableHyphens: readableHyphens,
                sentence: sentence
            ) {
                notes.append(line)
            }
        }
        func statusLine(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let lower = trimmed.lowercased()
            if lower == "none" { return nil }
            if let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colon])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let rest = String(trimmed[trimmed.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.isEmpty { return statusLine(key) }
                ingestStatus(key: key, rest: rest)
                return nil
            }
            if lower.hasPrefix("fail") || lower.hasPrefix("error") {
                return "Error: \(sentence(readableHyphens(trimmed)))"
            }
            return "Status: \(sentence(readableHyphens(trimmed)))"
        }
        func appendGoal(_ value: String) {
            if let narrative = goalNarrative(value) {
                semantics.append(narrative)
            } else {
                semantics.append("Goal: \(sentence(value))")
            }
        }
        func appendAction(_ value: String) {
            if let narrative = actionNarrative(value) {
                actionMentionsBlocked = value.lowercased().contains("blocked")
                semantics.append(narrative)
            } else {
                semantics.append("Action: \(sentence(readableHyphens(value)))")
            }
        }

        for raw in trimmed.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.lowercased().hasPrefix("@sr2") else { continue }
            if let field = structuredField(line) {
                switch field.key {
                case "o":
                    let head = field.value.split(whereSeparator: \.isWhitespace).first?.lowercased()
                    if head == "cont" {
                        continuationOnly = true
                    } else if head == "done" {
                        outcomes.append("Completed.")
                    } else if head == "ok" {
                        hasOkOutcome = true
                    } else {
                        outcomes.append(sentence(field.value))
                    }
                case "p":
                    if let line = evidenceLine(field.value) {
                        evidence.append(line)
                    }
                case "e":
                    if let leftover = statusLine(field.value) {
                        notes.append(leftover)
                    }
                case "h":
                    continue
                case "g", "goal":
                    appendGoal(field.value)
                default:
                    if let label = labels[field.key] {
                        semantics.append("\(label): \(sentence(field.value))")
                    }
                }
                continue
            }
            if let delimiter = line.firstIndex(where: { $0 == ":" || $0 == "=" }) {
                let key = String(line[..<delimiter])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let value = String(line[line.index(after: delimiter)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !value.isEmpty else { continue }
                switch key {
                case "action":
                    appendAction(value)
                case "proof":
                    if let line = evidenceLine(value) {
                        evidence.append(line)
                    }
                default:
                    ingestStatus(key: key, rest: value)
                }
                continue
            }
            let token = line.lowercased()
            if token == "blocked" || token == "blocking", !actionMentionsBlocked {
                outcomes.append("Blocked.")
            }
        }

        var pieces = outcomes + semantics
        if !mergedPRIds.isEmpty || !narrativeNotes.isEmpty {
            pieces.append("Current status:")
            for id in mergedPRIds {
                let ref = prURLsById[id].flatMap { githubRepoPullRef(from: $0) } ?? "#\(id)"
                pieces.append("* PR #\(id) has been merged: \(ref).")
            }
            pieces.append(contentsOf: narrativeNotes.map { $0.hasPrefix("* ") ? $0 : "* \($0)" })
        }
        pieces.append(contentsOf: notes)
        pieces.append(contentsOf: evidence)
        if let nextStep {
            pieces.append(nextStep)
        }
        if pieces.isEmpty, hasOkOutcome { pieces.append("ok.") }
        if pieces.isEmpty, continuationOnly { pieces.append("Continuing the work.") }
        return pieces.isEmpty
            ? "I could not expand the SR2 response."
            : pieces.joined(separator: "\n")
    }

    private static func goalNarrative(_ value: String) -> String? {
        let compact = value.lowercased().replacingOccurrences(of: "_", with: "-")
        if compact.contains("trello"), compact.contains("doing"), compact.contains("delivery") {
            return "The goal is to deliver the Trello task currently in Doing."
        }
        return nil
    }

    private static func actionNarrative(_ value: String) -> String? {
        let compact = value.lowercased().replacingOccurrences(of: "_", with: "-")
        if compact.hasPrefix("blocked-") {
            let rest = compact.dropFirst("blocked-".count)
            if rest.contains("deploy") && rest.contains("proof") {
                return "The current action is blocked while waiting for deployment proof."
            }
            let readable = rest.replacingOccurrences(of: "-", with: " ")
            return "The current action is blocked while waiting for \(readable)."
        }
        return nil
    }

    private static func nextStepNarrative(_ value: String) -> String {
        let compact = value.lowercased().replacingOccurrences(of: "_", with: "-")
        if compact.contains("wait"), compact.contains("deploy"), compact.contains("playwright") {
            var sentence = "The next step is to wait for the deployment to finish, then run authenticated post-deployment Playwright tests."
            if compact.contains("trello") || compact.contains("update") {
                sentence += " If everything is verified successfully, update the Trello card accordingly."
            }
            return sentence
        }
        let readable = value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let trimmed = readable.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".") { return "The next step is to \(trimmed)" }
        return "The next step is to \(trimmed)."
    }

    private static func trackerDeliveryStatusLine(key: String, rest: String) -> String? {
        let restLower = rest.lowercased()
        if key.hasPrefix("railway") {
            let name = key.hasPrefix("railway-") ? String(key.dropFirst("railway-".count)) : restLower
            if restLower.contains("404") {
                return "The production access-pins endpoint returned a 404 before the clean deployment."
            }
            if restLower == "success" {
                if name.contains("main-admin") {
                    return "The Railway deployment for main-admin succeeded."
                }
                if name.contains("prod-api") {
                    return "The Railway production API deployment succeeded."
                }
                return "The Railway deployment for \(name.replacingOccurrences(of: "-", with: " ")) succeeded."
            }
            if restLower == "initializing" {
                if name.contains("prod-api") {
                    return "The Railway production API deployment is still initializing."
                }
                return "The Railway \(name.replacingOccurrences(of: "-", with: " ")) deployment is still initializing."
            }
        }
        if key == "playwright" {
            if restLower == "unverified" {
                return "Post-deployment Playwright testing has not yet been verified."
            }
        }
        if key == "trello" {
            if restLower.contains("unchanged") && restLower.contains("doing") {
                return "The Trello card remains in Doing."
            }
            if restLower.contains("doing") {
                return "The Trello card is in Doing."
            }
        }
        if key == "comments" || key == "comment" {
            if restLower.contains("not-posted") || restLower.contains("not posted") {
                return "No comments have been posted to the Trello card yet."
            }
        }
        return nil
    }

    private static func genericStatusLine(
        key: String,
        rest: String,
        statusLabels: [String: String],
        readableHyphens: (String) -> String,
        sentence: (String) -> String
    ) -> String? {
        if key == "url" { return "URL: \(rest)" }
        let label = statusLabels[key] ?? key.capitalized
        if label == "Error" {
            return "Error: \(sentence(readableHyphens(rest)))"
        }
        return "\(label): \(sentence(readableHyphens(rest)))"
    }

    private static func githubRepoPullRef(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com") else {
            return trimmed.isEmpty ? nil : trimmed
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull" else { return trimmed }
        return "\(parts[0])/\(parts[1])#\(parts[3])"
    }

    /// Deterministic UI fallback for provider output already classified as
    /// legacy SR1. This parser is deliberately provenance-bound: arbitrary
    /// natural prose never enters it, so labels can be removed without risking
    /// damage to legitimate sentences such as "O jogo...".
    private static func deterministicHumanizedSR1(_ text: String) -> String? {
        var pieces: [String] = []
        let labels: [Character: String] = [
            "S": "State", "C": "Context", "D": "Action", "R": "Risk",
            "O": "", "N": "Do not", "P": "Proof",
        ]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if lower == "sr1" || lower.hasPrefix("sr1 ")
                || lower == "dict" || lower.hasPrefix("dict:") {
                continue
            }
            guard let first = line.first?.uppercased().first,
                  let label = labels[first],
                  line.count > 1 else {
                pieces.append(line)
                continue
            }
            let next = line.index(after: line.startIndex)
            let delimiter = line[next]
            guard delimiter == ":" || delimiter == "=" || delimiter.isWhitespace else {
                pieces.append(line)
                continue
            }
            let start = delimiter == ":" || delimiter == "="
                ? line.index(after: next)
                : next
            let value = line[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            pieces.append(label.isEmpty ? value : "\(label): \(value)")
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }

    private static func structuredField(_ line: String) -> (key: String, value: String)? {
        if line.hasPrefix("!") {
            let value = line.dropFirst()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : ("not", value)
        }
        guard let delimiterIndex = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
            return nil
        }
        let key = line[..<delimiterIndex].lowercased()
        guard structuredFieldKeys.contains(key) else { return nil }
        let value = line[line.index(after: delimiterIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return (key, value)
    }

    public static func channelKind(
        of text: String,
        isSR1: (String) -> Bool
    ) -> ChannelKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if isSR2(trimmed) { return .sr2 }
        if isSR1(trimmed) { return .sr1 }
        return .freeProse
    }

    // MARK: - Enforcement

    /// Recovery marker format — **must** match `ReversibleContentStore.marker(for:)`
    /// (`[[rc:<handle>]]`, bare content-addressed hex). Never prefix `ans_` inside
    /// the marker: store keys are bare SHA-256; `normalize` would look up `ans_<sha>`
    /// and miss the row.
    public static func recoveryMarker(for handle: String) -> String {
        let safe = handle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let bare = safe.isEmpty ? "pending" : safe
        return "[[rc:\(bare)]]"
    }

    /// Extract the first durable recovery marker from wire/history text.
    /// The returned value is kept in marker form so each store implementation
    /// can apply its own normalization consistently.
    public static func recoveryMarker(in text: String) -> String? {
        guard let start = text.range(of: "[[rc:") else { return nil }
        guard let end = text[start.upperBound...].range(of: "]]"),
              end.lowerBound > start.upperBound else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    private static let inlineOriginalPrefix = "inline-base64:"

    /// Lossless canonical v1 history envelope used when a provider emitted a
    /// legacy wire or free prose. The preferred form stores the exact provider
    /// bytes under a durable handle. If storage fails, base64 keeps those UTF-8
    /// bytes inline so history remains both v1-compliant and recoverable.
    private static func canonicalHistoryEnvelope(
        for providerOutput: String,
        handle: String?
    ) -> String {
        let data = Data(providerOutput.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let payload: String
        if let handle {
            payload = recoveryMarker(for: handle)
        } else {
            payload = inlineOriginalPrefix + data.base64EncodedString()
        }
        return [markerLine, "o:ok", "p:sha256=\(digest)", "h:\(payload)"].joined(separator: "\n")
    }

    /// Recover the byte-exact provider output represented by a canonical v1
    /// history envelope. `retrieve` receives the complete `[[rc:...]]` marker.
    /// Both handle and inline forms are SHA-256 checked before release.
    public static func providerOriginal(
        in history: String,
        retrieve: ((String) -> String?)? = nil
    ) -> String? {
        let lines = history
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard lines.first?.lowercased() == markerLine.lowercased(),
              let digestField = lines.first(where: { $0.lowercased().hasPrefix("p:sha256=") }),
              let payloadField = lines.first(where: { $0.lowercased().hasPrefix("h:") }) else {
            return nil
        }
        let expectedDigest = String(digestField.dropFirst("p:sha256=".count)).lowercased()
        guard expectedDigest.count == 64,
              expectedDigest.allSatisfy({ $0.isHexDigit }) else { return nil }
        let payload = String(payloadField.dropFirst(2))
        let original: String?
        if payload.hasPrefix(inlineOriginalPrefix),
           let data = Data(base64Encoded: String(payload.dropFirst(inlineOriginalPrefix.count))) {
            original = String(data: data, encoding: .utf8)
        } else if payload.hasPrefix("[[rc:"), payload.hasSuffix("]]"), let retrieve {
            original = retrieve(payload)
        } else {
            original = nil
        }
        guard let original else { return nil }
        let actualDigest = SHA256.hash(data: Data(original.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return actualDigest == expectedDigest ? original : nil
    }

    /// Lossless single-line envelope for a user instruction sent to a paid
    /// provider. The caller owns the net-positive gate: wrapping is useful only
    /// when the final wire still estimates smaller than the original prompt.
    public static func userInstructionWire(_ instruction: String) -> String {
        let escaped = instruction
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\(markerLine)\nu:\(escaped)\no:cont"
    }

    /// Decodes a `u:` field produced by `userInstructionWire`.
    public static func userInstruction(in wire: String) -> String? {
        guard isSR2(wire) else { return nil }
        let lines = wire.split(whereSeparator: \.isNewline).map(String.init)
        guard let payload = lines.first(where: { $0.lowercased().hasPrefix("u:") })?.dropFirst(2) else {
            return nil
        }
        var result = ""
        var escaping = false
        for character in payload {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                default:
                    result.append("\\")
                    result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { result.append("\\") }
        return result
    }

    /// Encode trusted host guidance for providers without a system/developer
    /// payload surface (currently Grok ACP). This is intentionally not a user
    /// instruction wire and can never be decoded through `userInstruction`.
    public static func trustedHostInstructionWire(_ instruction: String) -> String {
        let escaped = instruction
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\(trustedHostMarkerLine)\nhost:\(escaped)"
    }

    /// Strict parser for the typed ACP host block. Rejects banners, extra
    /// fields, malformed escapes, or content that could be mistaken for the
    /// canonical user SR2 v1 leg.
    public static func trustedHostInstruction(in wire: String) -> String? {
        let lines = wire.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 2,
              lines[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == trustedHostMarkerLine.lowercased(),
              lines[1].lowercased().hasPrefix("host:") else {
            return nil
        }
        let payload = String(lines[1].dropFirst("host:".count))
        guard !payload.isEmpty else { return nil }
        var result = ""
        var escaping = false
        for character in payload {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                default: return nil
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        guard !escaping, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return result
    }

    /// Collapse free prose into a recoverable wire stub for provider history.
    public static func enforceFreeProse(
        _ prose: String,
        handle: String = "pending"
    ) -> EnforceResult {
        let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = recoveryMarker(for: handle)
        let stub = canonicalHistoryEnvelope(for: prose, handle: handle)
        return EnforceResult(
            wireStub: stub,
            fullProse: trimmed,
            recoveryHandlePlaceholder: marker
        )
    }

    /// When Token Saver is ON, classify assistant text and produce dual-channel legs.
    ///
    /// - SR2/SR1: history keeps wire; UI needs humanize.
    /// - Free prose: history becomes enforced stub; UI source is original prose;
    ///   compliance_miss counts toward per-provider gates.
    public static func classifyForTokenSaver(
        response: String,
        tokenSaverOn: Bool,
        isSR1: (String) -> Bool,
        recoveryHandle: String = "pending"
    ) -> Classification {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Classification(
                kind: .empty,
                providerHistoryText: "",
                uiSourceText: "",
                needsHumanize: false,
                wasEnforced: false,
                complianceMiss: false
            )
        }
        guard tokenSaverOn else {
            return Classification(
                kind: .freeProse,
                providerHistoryText: trimmed,
                uiSourceText: trimmed,
                needsHumanize: false,
                wasEnforced: false,
                complianceMiss: false
            )
        }
        let kind = channelKind(of: trimmed, isSR1: isSR1)
        switch kind {
        case .sr2, .sr1:
            return Classification(
                kind: kind,
                providerHistoryText: trimmed,
                uiSourceText: trimmed,
                needsHumanize: true,
                wasEnforced: false,
                complianceMiss: false
            )
        case .freeProse:
            if hasSR2Banner(trimmed) {
                // Keep the strict classification as a compliance miss, but send
                // provider-originated banner text through the trusted humanizer.
                // The dual-channel persist step will canonicalize the history leg.
                return Classification(
                    kind: .freeProse,
                    providerHistoryText: trimmed,
                    uiSourceText: trimmed,
                    needsHumanize: true,
                    wasEnforced: true,
                    complianceMiss: true
                )
            }
            let enforced = enforceFreeProse(trimmed, handle: recoveryHandle)
            return Classification(
                kind: .freeProse,
                providerHistoryText: enforced.wireStub,
                uiSourceText: enforced.fullProse,
                needsHumanize: false,
                wasEnforced: true,
                complianceMiss: true
            )
        case .empty:
            return Classification(
                kind: .empty,
                providerHistoryText: "",
                uiSourceText: "",
                needsHumanize: false,
                wasEnforced: false,
                complianceMiss: false
            )
        }
    }

    /// Dual-channel: UI humanize must never re-enter provider-facing history text.
    public static func dualChannelAllows(
        providerHistoryText: String,
        uiHumanizedText: String
    ) -> Bool {
        let hist = providerHistoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ui = uiHumanizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hist.isEmpty, !ui.isEmpty else { return true }
        // If history equals full humanized monologue and is not wire, fail.
        if hist == ui, !isSR2(hist) {
            // SR1-shaped history is OK even if UI matches expanded form only after humanize
            // (they should differ). Equal free prose is the forbidden case.
            return false
        }
        return true
    }

    // MARK: - Instruct (Claude / Codex / Grok)

    /// Compact always-on block injected when `RC_TOKEN_SAVER_DISTILL_HINT=1`.
    public static let alwaysOnInstructBlock = """
    \(instructBlockMarker)
    Token Saver ON — assistant wire is MANDATORY for Claude, Codex, and Grok (no free monologue).
    Every provider-authored text item MUST be SR2 Opaque Agent IR (machine-only): reasoning, commentary/intermediate updates, and final replies. Humans never read this wire; the host humanizes for UI.
    Format:
    \(advertisedV1Sample)
    Each field is on its own line; omit optional lines instead of joining fields.
    Rules:
    - No articles, filler, hedging, markdown essays, or multi-paragraph prose on the wire.
    - Prefer action-only `o:cont` when only tool calls ran (see actionOnlyWire).
    - Long answers: answer-as-handle — short o: + h:[[rc:<handle>]] + p: anchors (not full prose on wire).
    - Keep paths, SHAs, exit codes, error strings exact when present.
    - `@sr2 v1` is the only current provider wire. Never emit legacy `@sr2 v0`, SR1 (S/C/D/R/O/N/P), or plain chat prose.
    - User input may arrive as `u:<lossless escaped instruction>` plus `o:cont`; decode `\\n`, `\\r`, and `\\\\` before acting.
    - User semantic input may arrive as:
    \(semanticV1Sample)
      Here `run:a;b` is one shell tool call. `run:[a;b]>[c]` requires two separate ordered shell tool calls; never flatten bracketed groups into one `sh`/`zsh -c` compound. `out:=Nlines` requires one global exact cardinality, and indexed `out:1=2lines,2=1line` binds exact cardinality to individual ordered groups; `!file-edit` forbids file edits. Execute exact groups raw. For an ordinary non-TUI group, preserve its command and add explicit `| distill` in that separate tool call when full stdout is not needed byte-exactly.
    - A bounded natural orchestration may arrive as:
    \(naturalTaskV1Sample)
      In `t:`, `>` is strict order, parentheses bind attributes to that action, comma joins attributes, and `key=value` is a hard constraint. `key?=value@title-or-text` is a soft preference; `@title-or-text` matches the task title or text. Rank matching candidates first, then fall back to candidates satisfying the hard constraints when none match. `!x:y` is MUST NOT, `must:` is mandatory, `should:` is advisory, `wt@updated B` means a worktree based on updated branch B, and `label(role)=URL` preserves repository-role mappings. Keep every literal and binding exact.
    - A bounded tracker-delivery goal may arrive as:
    \(trackerDeliveryV1Sample)
      In this shape `goal:` is ordered work (`>` means the prior step must succeed), `use:` names required skills/tools, `must:` is mandatory, `browser:A|B?` is an optional fallback, `auth:user|secret` is a login pair, `pr:tool,!other` selects the proposal CLI, and `trello-comment:` / `comment:tracker=` is the required tracker comment. `done:` is the completion gate. Keep every literal and binding exact.
    - Tool stdout stays exact: keep exact-output (rg/sed/cat/jq) unpiped; pipe noisy builds/tests/logs via `| distill`.
    - Host-local telemetry labels such as Thinking/Ran Shell/Failed Shell are outside the provider wire.
    """

    // MARK: - T-SR2-08 action-only / answer-as-handle

    /// Tool-only continuation wire (no prose body).
    public static func actionOnlyWire(paths: [String] = []) -> String {
        var lines = [markerLine, "o:cont"]
        if !paths.isEmpty {
            lines.append("p:" + paths.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Long answer stored under handle; wire stays dense.
    public static func answerAsHandleWire(
        handle: String,
        outcome: String = "ok",
        paths: [String] = []
    ) -> String {
        var lines = [
            markerLine,
            "o:\(outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ok" : outcome)",
            "h:\(recoveryMarker(for: handle))"
        ]
        if !paths.isEmpty {
            lines.insert("p:" + paths.joined(separator: ","), at: 2)
        }
        return lines.joined(separator: "\n")
    }

    /// Export content-free compliance for stats / T-SR2-07.
    public static func complianceExport() -> [[String: Any]] {
        sharedCompliance.snapshot().map { provider, row in
            let missRate = row.turns > 0 ? Double(row.misses) / Double(row.turns) : 0
            return [
                "provider": provider,
                "turns": row.turns,
                "misses": row.misses,
                "enforced": row.enforced,
                "miss_rate": missRate
            ] as [String: Any]
        }.sorted { ($0["provider"] as? String ?? "") < ($1["provider"] as? String ?? "") }
    }

    public static func complianceExportJSON() -> String {
        let rows = complianceExport()
        guard JSONSerialization.isValidJSONObject(rows),
              let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    public static func appendingAlwaysOnInstruct(to base: String, tokenSaverHintOn: Bool) -> String {
        guard tokenSaverHintOn else { return base }
        if base.contains(instructBlockMarker) { return base }
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? alwaysOnInstructBlock : trimmed + "\n\n" + alwaysOnInstructBlock
    }

    /// Matrix gate: all three providers must be listed covered.
    public static func matrixIsComplete(coveredProviders: Set<String>) -> Bool {
        let normalized = Set(coveredProviders.map { $0.lowercased() })
        return requiredProviders.allSatisfy { normalized.contains($0) }
    }

    // MARK: - Compliance ledger (content-free)

    public struct ComplianceEvent: Sendable, Equatable {
        public let provider: String
        public let kind: ChannelKind
        public let wasEnforced: Bool
        public let complianceMiss: Bool

        public init(provider: String, kind: ChannelKind, wasEnforced: Bool, complianceMiss: Bool) {
            self.provider = provider.lowercased()
            self.kind = kind
            self.wasEnforced = wasEnforced
            self.complianceMiss = complianceMiss
        }
    }

    public final class ComplianceScoreboard: @unchecked Sendable {
        private let lock = NSLock()
        private var turns: [String: Int] = [:]
        private var misses: [String: Int] = [:]
        private var enforced: [String: Int] = [:]

        public init() {}

        public func record(_ event: ComplianceEvent) {
            lock.lock()
            defer { lock.unlock() }
            let p = event.provider
            turns[p, default: 0] += 1
            if event.complianceMiss { misses[p, default: 0] += 1 }
            if event.wasEnforced { enforced[p, default: 0] += 1 }
        }

        public func missRate(provider: String) -> Double {
            lock.lock()
            defer { lock.unlock() }
            let t = turns[provider.lowercased(), default: 0]
            guard t > 0 else { return 0 }
            return Double(misses[provider.lowercased(), default: 0]) / Double(t)
        }

        public func snapshot() -> [String: (turns: Int, misses: Int, enforced: Int)] {
            lock.lock()
            defer { lock.unlock() }
            var out: [String: (turns: Int, misses: Int, enforced: Int)] = [:]
            for p in Set(turns.keys).union(misses.keys).union(enforced.keys) {
                out[p] = (
                    turns: turns[p, default: 0],
                    misses: misses[p, default: 0],
                    enforced: enforced[p, default: 0]
                )
            }
            return out
        }

        public func reset() {
            lock.lock()
            turns.removeAll()
            misses.removeAll()
            enforced.removeAll()
            lock.unlock()
        }
    }

    public static let sharedCompliance = ComplianceScoreboard()

    // MARK: - Dual-channel persist plan (provider history vs UI)

    /// What the host must write after translation so free monologue cannot
    /// remain the provider-facing history text.
    public struct DualChannelPersistPlan: Sendable, Equatable {
        /// Text that belongs in assistant message body / next-turn context.
        public let historyText: String
        /// Text the user should read in the UI.
        public let uiText: String
        /// When true, emit `sr1Translation(original: historyText, rewritten: uiText)`.
        public let shouldEmitTranslation: Bool
        public let wasEnforced: Bool
        public let complianceMiss: Bool
        public let kind: ChannelKind

        public init(
            historyText: String,
            uiText: String,
            shouldEmitTranslation: Bool,
            wasEnforced: Bool,
            complianceMiss: Bool,
            kind: ChannelKind
        ) {
            self.historyText = historyText
            self.uiText = uiText
            self.shouldEmitTranslation = shouldEmitTranslation
            self.wasEnforced = wasEnforced
            self.complianceMiss = complianceMiss
            self.kind = kind
        }
    }

    /// Build the dual-channel write after the humanize pass.
    ///
    /// - SR2/SR1: history keeps model wire; UI is humanize output (or wire if empty).
    /// - Free prose + Token Saver ON: `storeProse` must persist full prose and return
    ///   a verified content-addressed handle; history becomes a wire stub with `[[rc:<handle>]]`;
    ///   UI is the original monologue (already human).
    /// - Token Saver OFF: history and UI stay model output / humanize passthrough.
    public static func dualChannelPersistPlan(
        modelOutput: String,
        humanizeOutput: String,
        tokenSaverOn: Bool,
        isSR1: (String) -> Bool,
        storeProse: ((String) -> String?)?
    ) -> DualChannelPersistPlan {
        let original = modelOutput
        let model = modelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let uiIn = humanizeOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty {
            return DualChannelPersistPlan(
                historyText: "",
                uiText: "",
                shouldEmitTranslation: false,
                wasEnforced: false,
                complianceMiss: false,
                kind: .empty
            )
        }
        guard tokenSaverOn else {
            let ui = uiIn.isEmpty ? model : uiIn
            return DualChannelPersistPlan(
                historyText: model,
                uiText: ui,
                shouldEmitTranslation: false,
                wasEnforced: false,
                complianceMiss: false,
                kind: .freeProse
            )
        }
        let kind = channelKind(of: model, isSR1: isSR1)
        func verifiedHandle() -> String? {
            guard let rawHandle = storeProse?(original) else { return nil }
            let handle = rawHandle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !handle.isEmpty,
                  handle.caseInsensitiveCompare("pending") != .orderedSame,
                  handle.caseInsensitiveCompare("unavailable") != .orderedSame else {
                return nil
            }
            return handle
        }
        func normalizedHistory() -> String {
            canonicalHistoryEnvelope(for: original, handle: verifiedHandle())
        }
        switch kind {
        case .sr2:
            let humanizerLeakedWire = containsHumanizationWireSyntax(uiIn)
            let deterministic = deterministicHumanizedWire(model)
            let ui = uiIn.isEmpty || isSR2(uiIn) || isSR1(uiIn) || humanizerLeakedWire
                ? (deterministic ?? model)
                : uiIn
            // Prefer UI expansion when humanize produced readable prose.
            let useUI = ui != model && !ui.isEmpty && !isSR2(ui) && !isSR1(ui)
            if !isCurrentSR2(original) {
                return DualChannelPersistPlan(
                    historyText: normalizedHistory(),
                    uiText: useUI ? ui : (deterministic ?? ui),
                    shouldEmitTranslation: true,
                    wasEnforced: true,
                    complianceMiss: true,
                    kind: kind
                )
            }
            return DualChannelPersistPlan(
                historyText: original,
                uiText: useUI ? ui : model,
                shouldEmitTranslation: useUI,
                wasEnforced: false,
                complianceMiss: false,
                kind: kind
            )
        case .sr1:
            let humanizerLeakedWire = containsHumanizationWireSyntax(uiIn)
            let deterministic = deterministicHumanizedSR1(model)
            let ui = uiIn.isEmpty || isSR2(uiIn) || isSR1(uiIn) || humanizerLeakedWire
                ? (deterministic ?? model)
                : uiIn
            return DualChannelPersistPlan(
                historyText: normalizedHistory(),
                uiText: ui,
                shouldEmitTranslation: true,
                wasEnforced: true,
                complianceMiss: true,
                kind: kind
            )
        case .freeProse:
            if hasSR2Banner(model) {
                let leakedWire = uiIn.isEmpty
                    || containsHumanizationWireSyntax(uiIn)
                    || isSR1(uiIn)
                let deterministic = deterministicHumanizedWire(model)
                    ?? "I could not expand the SR2 response."
                return DualChannelPersistPlan(
                    historyText: normalizedHistory(),
                    uiText: leakedWire ? deterministic : uiIn,
                    shouldEmitTranslation: true,
                    wasEnforced: true,
                    complianceMiss: true,
                    kind: .freeProse
                )
            }
            return DualChannelPersistPlan(
                historyText: normalizedHistory(),
                uiText: uiIn.isEmpty ? original : humanizeOutput,
                shouldEmitTranslation: true,
                wasEnforced: true,
                complianceMiss: true,
                kind: .freeProse
            )
        case .empty:
            return DualChannelPersistPlan(
                historyText: "",
                uiText: "",
                shouldEmitTranslation: false,
                wasEnforced: false,
                complianceMiss: false,
                kind: .empty
            )
        }
    }
}
