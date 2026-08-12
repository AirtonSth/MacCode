import Foundation

/// SR2 Opaque Agent IR — dense machine-only provider wire when Token Saver is ON.
///
/// Dual-channel contract:
/// - **Provider history** keeps wire (SR2/SR1) or an enforced stub — never free monologue.
/// - **UI** shows local humanize (or original prose when enforcement stored a handle).
///
/// Providers Claude, Codex, and Grok share this policy; only instruct injection adapters differ.
public enum SR2WirePolicy: Sendable {
    public static let version = "v0"
    public static let markerLine = "@sr2 v0"
    public static let optimizerVersion = "v1"
    public static let optimizerMarkerLine = "@sr2 v1"
    public static let instructBlockMarker = "REMOTE_CODE_SR2_ALWAYS_ON_V1"

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
        let hasBanner = [markerLine, optimizerMarkerLine, "sr2 v0", "sr2 v1"]
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
                guard let outcome, ["ok", "fail", "need", "cont"].contains(outcome) else {
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

    private static func structuredField(_ line: String) -> (key: String, value: String)? {
        guard let delimiterIndex = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
            return nil
        }
        let key = line[..<delimiterIndex].lowercased()
        let allowed = Set([
            "g", "d", "p", "o", "e", "h", "t", "u",
            "flow", "done", "tools", "must", "should", "may", "not", "constraints", "outputs"
        ])
        guard allowed.contains(key) else { return nil }
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

    /// Collapse free prose into a recoverable wire stub for provider history.
    public static func enforceFreeProse(
        _ prose: String,
        handle: String = "pending"
    ) -> EnforceResult {
        let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = recoveryMarker(for: handle)
        let stub = """
        \(markerLine)
        o:ok
        h:\(marker)
        """
        return EnforceResult(
            wireStub: stub.trimmingCharacters(in: .whitespacesAndNewlines),
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
    @sr2 v0
    g:<goal_id>? d:<decision_id>? p:path:line[,…]? o:ok|fail|need|cont e:<class>? h:[[rc:<handle>]]?
    Rules:
    - No articles, filler, hedging, markdown essays, or multi-paragraph prose on the wire.
    - Prefer action-only `o:cont` when only tool calls ran (see actionOnlyWire).
    - Long answers: answer-as-handle — short o: + h:[[rc:<handle>]] + p: anchors (not full prose on wire).
    - Keep paths, SHAs, exit codes, error strings exact when present.
    - SR1 (S/C/D/R/O/N/P) is fallback only if you cannot emit SR2; never plain chat prose.
    - User input may arrive as `u:<lossless escaped instruction>` plus `o:cont`; decode `\\n`, `\\r`, and `\\\\` before acting.
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
        switch kind {
        case .sr2, .sr1:
            let ui = uiIn.isEmpty || isSR2(uiIn) || isSR1(uiIn) ? model : uiIn
            // Prefer UI expansion when humanize produced readable prose.
            let useUI = ui != model && !ui.isEmpty && !isSR2(ui) && !isSR1(ui)
            return DualChannelPersistPlan(
                historyText: model,
                uiText: useUI ? ui : model,
                shouldEmitTranslation: useUI,
                wasEnforced: false,
                complianceMiss: false,
                kind: kind
            )
        case .freeProse:
            guard let rawHandle = storeProse?(model) else {
                let ui = uiIn.isEmpty ? model : uiIn
                return DualChannelPersistPlan(
                    historyText: model,
                    uiText: ui,
                    shouldEmitTranslation: false,
                    wasEnforced: false,
                    complianceMiss: true,
                    kind: .freeProse
                )
            }
            let handle = rawHandle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !handle.isEmpty,
                  handle.caseInsensitiveCompare("pending") != .orderedSame,
                  handle.caseInsensitiveCompare("unavailable") != .orderedSame else {
                let ui = uiIn.isEmpty ? model : uiIn
                return DualChannelPersistPlan(
                    historyText: model,
                    uiText: ui,
                    shouldEmitTranslation: false,
                    wasEnforced: false,
                    complianceMiss: true,
                    kind: .freeProse
                )
            }
            let enforced = enforceFreeProse(model, handle: handle)
            return DualChannelPersistPlan(
                historyText: enforced.wireStub,
                uiText: uiIn.isEmpty ? model : uiIn,
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
