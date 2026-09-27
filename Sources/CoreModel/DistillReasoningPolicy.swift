import Foundation

/// Fallback effort catalog for the model ids listed by DistillRunner.
/// Live ACP-advertised efforts take precedence when available.
public enum DistillReasoningPolicy {
    public static let grok46Efforts: [AgentReasoningEffort] = [.low, .medium, .high, .xhigh]
    public static let grok45Efforts: [AgentReasoningEffort] = [.low, .medium, .high]
    public static let glm53Efforts: [AgentReasoningEffort] = [.low, .medium, .high, .xhigh, .max]
    public static let museSparkEfforts: [AgentReasoningEffort] = [.low, .medium, .high, .xhigh]

    public static func supportedEfforts(for model: String) -> [AgentReasoningEffort] {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.isEmpty || id.hasPrefix("grok-4.6") { return grok46Efforts }
        if id.hasPrefix("grok-4.5") { return grok45Efforts }
        if id == "glm-5.3" || id.hasPrefix("glm-5.3-") { return glm53Efforts }
        if id.hasPrefix("muse-spark") { return museSparkEfforts }
        if id.hasPrefix("qwen38") || id.hasPrefix("grok-composer") { return [] }
        return []
    }

    public static func normalizedEffort(
        _ effort: AgentReasoningEffort,
        model: String
    ) -> AgentReasoningEffort {
        let supported = supportedEfforts(for: model)
        guard let deepest = supported.last else { return .medium }
        switch effort {
        case .minimal:
            return supported.contains(.low) ? .low : (supported.first ?? deepest)
        case .low, .medium, .high, .xhigh:
            return supported.contains(effort) ? effort : deepest
        case .max, .ultra, .ultracode:
            return deepest
        }
    }
}
