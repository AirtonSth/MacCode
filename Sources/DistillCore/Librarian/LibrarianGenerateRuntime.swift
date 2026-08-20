import Foundation

public struct LibrarianGenerateCall: Sendable {
    public let system: String
    public let user: String
    public let maxTokens: Int
}

public protocol LibrarianGenerating: Sendable {
    func generate(_ call: LibrarianGenerateCall) async -> String?
}

/// Counts generate calls and last-call latency for the shipped probe/benchmark path.
public final class LibrarianInstrumentedGenerate: LibrarianGenerating, @unchecked Sendable {
    public let inner: any LibrarianGenerating
    public private(set) var callCount = 0
    public private(set) var lastLatencyMs = 0

    public init(_ inner: any LibrarianGenerating) {
        self.inner = inner
    }

    public func generate(_ call: LibrarianGenerateCall) async -> String? {
        let start = Date()
        let out = await inner.generate(call)
        lastLatencyMs = max(0, Int(Date().timeIntervalSince(start) * 1000))
        callCount += 1
        return out
    }
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
            .nilIfEmpty ?? "Ornith-1.5-9B-MLX-4bit"
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
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        // Paid-facing text is `content` only. Never return `reasoning_content`.
        let content = Self.messageContent(message)
        guard !content.isEmpty else { return nil }
        return LibrarianThinkStrip.strip(content)
    }

    private static func messageContent(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }
}

/// Catalog generate through the same DistillRuntime the sidecar already selected
/// (Settings 1.7B / E4B / OpenAI-compat) and wrapped for training recording.
public struct LibrarianDistillRuntimeAdapter: LibrarianGenerating {
    public let runtime: any DistillRuntime

    public init(runtime: any DistillRuntime) {
        self.runtime = runtime
    }

    public func generate(_ call: LibrarianGenerateCall) async -> String? {
        await runtime.rawGenerate(system: call.system, user: call.user, maxTokens: call.maxTokens)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
