import Foundation

public struct LibrarianGenerateCall: Sendable {
    public let system: String
    public let user: String
    public let maxTokens: Int
}

public protocol LibrarianGenerating: Sendable {
    func generate(_ call: LibrarianGenerateCall) async -> String?
}

/// OpenAI-compatible localhost generate (oMLX / Distill sidecar style).
/// Default-off: only used when `RC_LIBRARIAN_GENERATE_BASE_URL` is set.
public struct LibrarianOpenAICompatibleRuntime: LibrarianGenerating, Sendable {
    public let baseURL: URL
    public let model: String
    public let timeout: TimeInterval

    public init?(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 30
    ) {
        let raw = environment["RC_LIBRARIAN_GENERATE_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, let url = URL(string: raw) else { return nil }
        self.baseURL = url
        self.model = environment["RC_LIBRARIAN_GENERATE_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "Qwen3.8-27B-4bit"
        self.timeout = timeout
    }

    public init(baseURL: URL, model: String, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }

    public func generate(_ call: LibrarianGenerateCall) async -> String? {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": call.maxTokens,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": call.system],
                ["role": "user", "content": call.user],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return LibrarianThinkStrip.strip(content)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
