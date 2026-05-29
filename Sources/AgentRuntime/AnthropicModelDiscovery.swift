import Foundation
import CoreModel

public enum AnthropicModelDiscovery {
    public static func listModels(environment: [String: String] = [:]) async -> [AgentModelDescriptor] {
        let env = CodexRunner.processEnvironment(overrides: environment)
        guard let apiKey = env["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty,
              let url = URL(string: "https://api.anthropic.com/v1/models") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return modelDescriptors(fromListResponse: object)
        } catch {
            return []
        }
    }

    public static func modelDescriptors(fromListResponse response: [String: Any]) -> [AgentModelDescriptor] {
        let rawModels = response["data"] as? [[String: Any]]
            ?? response["models"] as? [[String: Any]]
            ?? []
        return rawModels.compactMap { raw -> AgentModelDescriptor? in
            guard let id = string(raw, "id") ?? string(raw, "model"),
                  id.hasPrefix("claude-") else { return nil }
            let label = string(raw, "display_name") ?? string(raw, "displayName") ?? displayName(for: id)
            return descriptor(id: id, label: label)
        }
    }

    public static func latestAliasModels() -> [AgentModelDescriptor] {
        [
            descriptor(id: "opus", label: "Opus (latest)"),
            descriptor(id: "sonnet", label: "Sonnet (latest)"),
            descriptor(id: "haiku", label: "Haiku (latest)")
        ]
    }

    private static func descriptor(id: String, label: String) -> AgentModelDescriptor {
        let lower = "\(id) \(label)".lowercased()
        let supportsReasoning = lower.contains("opus") || lower.contains("sonnet")
        return AgentModelDescriptor(
            id: id,
            label: label,
            provider: .claude,
            supportsReasoning: supportsReasoning,
            supportedReasoningEfforts: supportsReasoning ? AgentReasoningEffort.supportedCases : [],
            supportsCustomModel: true,
            contextWindowTokens: 200_000
        )
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    private static func displayName(for id: String) -> String {
        id.split(separator: "-")
            .filter { Int($0) == nil && $0.count != 8 }
            .map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }
}
