import Foundation
import CoreModel

enum ProviderStderrClassifier {
    static func displayableStderr(_ raw: String, provider: AgentProvider) -> String? {
        // PERF: single pass avoids the map + filter intermediates on the
        // stderr path; kept text identical.
        var kept: [String] = []
        kept.reserveCapacity(8)
        for part in raw.split(whereSeparator: \.isNewline) {
            let line = String(part)
            if shouldDisplay(line: line, provider: provider) { kept.append(line) }
        }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func runtimeEvent(message: String, provider: AgentProvider, source: String) -> ProviderRuntimeEvent {
        ProviderRuntimeEvent(
            provider: provider,
            source: source,
            method: "stderr.fatal",
            payloadJSON: payloadJSON(message: message, provider: provider),
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Resolved terminal status + optional `agent_runs.error_message` for a finish.
    ///
    /// WHY: abnormal ends (failed / interrupted / silent empty completed) were
    /// persisted with a nil `error_message`, so the Agent App showed "stopped"
    /// with no reason. Prefer real provider stderr/error detail; fall back to a
    /// provider-named observation. User Stop (`.cancelled`) stays silent.
    struct TerminalResolution: Equatable, Sendable {
        var status: AgentRunStatus
        var errorMessage: String?
    }

    /// Prefer filtered provider detail; otherwise a specific non-generic reason.
    /// Never returns vague placeholders like "failed" or "unknown error".
    static func resolveTerminal(
        provider: AgentProvider,
        status: AgentRunStatus,
        observedDetail: String?,
        producedAssistantOutput: Bool
    ) -> TerminalResolution {
        switch status {
        case .cancelled, .pending, .running:
            return TerminalResolution(status: status, errorMessage: nil)
        case .completed:
            // Incomplete-turn handoffs keep a non-empty final and stay completed
            // so IncompleteTurnContinuation can auto-nudge. A "success" with no
            // assistant output is not success — reclassify so the UI can explain.
            if producedAssistantOutput {
                return TerminalResolution(status: .completed, errorMessage: nil)
            }
            return TerminalResolution(
                status: .failed,
                errorMessage: "\(displayName(provider)) run completed without producing an assistant response"
            )
        case .failed:
            return TerminalResolution(
                status: .failed,
                errorMessage: preferredDetail(observedDetail, provider: provider)
                    ?? "\(displayName(provider)) run failed: provider stream ended without a terminal success event or stderr detail"
            )
        case .interrupted:
            return TerminalResolution(
                status: .interrupted,
                errorMessage: preferredDetail(observedDetail, provider: provider)
                    ?? "\(displayName(provider)) run was interrupted without a recorded reason"
            )
        }
    }

    /// Prefer classifier-filtered stderr; keep already-structured provider causes intact.
    static func preferredDetail(_ raw: String?, provider: AgentProvider) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let filtered = displayableStderr(trimmed, provider: provider) {
            return filtered
        }
        // Fully-noise stderr: do not invent from garbage; caller uses fallback.
        // Structured messages that are not multi-line stderr still pass when
        // every line was filtered only if the whole string was empty after trim.
        // A single non-displayable line yields nil so the provider-named fallback
        // names the observation instead of storing a warning line as "the" error.
        return nil
    }

    static func displayName(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }

    private static func shouldDisplay(line: String, provider: AgentProvider) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.contains("reading additional input from stdin") { return false }
        if lower.hasPrefix("warning:") { return false }
        if lower.hasPrefix("warn ") || lower.contains(" warn ") { return false }
        if lower.contains("deprecated") && !lower.contains("error") { return false }
        if lower.contains("debuggerlldb.debuggerversionstore") { return false }
        if lower.contains("no debugger version") { return false }
        switch provider {
        case .codex:
            if lower.contains("codex") && lower.contains("warning") { return false }
        case .claude:
            if lower.contains("claude") && lower.contains("warning") { return false }
        case .grok:
            if lower.contains("grok") && lower.contains("warning") { return false }
        }
        return true
    }

    private static func payloadJSON(message: String, provider: AgentProvider) -> String {
        let object: [String: Any] = [
            "type": "stderr.fatal",
            "provider": provider.rawValue,
            "message": message
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"type":"stderr.fatal","message":"unencodable stderr"}"#
        }
        return json
    }
}
