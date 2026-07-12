import Foundation
import CoreModel

enum ProviderStderrClassifier {
    static func displayableStderr(_ raw: String, provider: AgentProvider) -> String? {
        let kept = raw.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { shouldDisplay(line: $0, provider: provider) }
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
