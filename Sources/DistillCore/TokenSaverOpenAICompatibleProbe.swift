import Foundation
import CoreModel

/// One-shot Settings check that the OpenAI-compatible generate endpoint answers.
public enum TokenSaverOpenAICompatibleProbe {
    public enum Outcome: Equatable, Sendable {
        case ok(model: String, host: String, preview: String)
        case failed(String)

        public var message: String {
            switch self {
            case .ok(let model, let host, _):
                return "Reached \(model) at \(host)"
            case .failed(let reason):
                return reason
            }
        }
    }

    public static func run(
        baseURL: String,
        model: String,
        token: String,
        timeout: TimeInterval = 12,
        complete: (@Sendable (String, String, String, Int) async -> String?)? = nil
    ) async -> Outcome {
        guard let url = TokenSaverGenerateTarget.parseAPIBaseURL(baseURL) else {
            return .failed("Enter a URL like http://127.0.0.1:8000/v1")
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            return .failed("Enter the API model id used by your OpenAI-compatible server")
        }
        let modelID = trimmedModel
        let host = url.host ?? url.absoluteString
        let reply: String?
        if let complete {
            reply = await complete(
                "Reply with one word: pong",
                "ping",
                modelID,
                8
            )
        } else {
            reply = await OpenAICompatibleDistillRuntime.postChat(
                baseURL: url,
                token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                timeout: timeout,
                system: "Reply with one word: pong",
                user: "ping",
                model: modelID,
                maxTokens: 8
            )
        }
        guard let text = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .failed("Could not reach \(host). Check the API endpoint, URL, model id, and token.")
        }
        return .ok(model: modelID, host: host, preview: String(text.prefix(80)))
    }
}
