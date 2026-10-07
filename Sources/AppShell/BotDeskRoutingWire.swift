import Foundation
import CoreModel
import SocketServer

/// The paired-device shape of a Bot desk route. Keys match `bot.send` /
/// `bot.routing.set` params and the Agent App thread payload
/// (`worker_model` is "" when off, efforts are a level or "auto").
extension BotDeskRouting {
    public var remoteWireObject: [String: JSONValue] {
        let selection = modelSelection
        var object: [String: JSONValue] = [
            "provider": .string(provider.rawValue),
            "provider_instance_id": .string(providerInstanceID),
            "model": .string(model),
            "routing_mode": .string(routingMode.rawValue),
            "permission_mode": .string(permissionMode.rawValue),
            "reasoning_effort": .string(reasoningEffort.rawValue),
            "service_tier": .string(serviceTier.rawValue),
            "worker_model": .string(reasoningModel ?? ""),
            "worker_effort": .string(selection.distillReasoningEffortSelection?.effort?.rawValue ?? "auto"),
            "distill_main_effort": .string(selection.distillMainEffortSelection?.effort?.rawValue ?? "auto"),
        ]
        if let data = try? JSONEncoder().encode(runAsUser),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            object["run_as_user"] = value
        }
        return object
    }

    /// Applies the optional Worker/effort wire fields. Absent keys keep the
    /// current value; "" turns the Worker off; "auto" clears a pinned effort.
    public mutating func applyRemoteWorkerFields(_ values: [String: Any]) throws {
        if let raw = values["worker_model"] {
            guard let model = raw as? String else { throw BotDeskRoutingWireError.invalid("worker_model") }
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            reasoningModel = trimmed.isEmpty ? nil : trimmed
        }
        if let raw = values["worker_effort"] {
            distillReasoningEffortSelection = try Self.effortSelection(raw, key: "worker_effort")
        }
        if let raw = values["distill_main_effort"] {
            distillMainEffortSelection = try Self.effortSelection(raw, key: "distill_main_effort")
        }
    }

    private static func effortSelection(_ raw: Any, key: String) throws -> AgentEffortSelection {
        guard let value = raw as? String else { throw BotDeskRoutingWireError.invalid(key) }
        if value == "auto" { return .automatic }
        guard let effort = AgentReasoningEffort(rawValue: value) else {
            throw BotDeskRoutingWireError.invalid(key)
        }
        return .fixed(effort)
    }
}

public enum BotDeskRoutingWireError: Error, Equatable {
    case invalid(String)
}
