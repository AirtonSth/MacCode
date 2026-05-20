import Foundation
import CoreModel

/// Deterministic fake provider for tests, demos, and offline fixture validation.
/// Emits a canned sequence of normalized events without spawning any process.
public final class FakeProviderRunner: AgentProviderRunner, @unchecked Sendable {
    public let provider: AgentProvider
    public let scenario: Scenario

    public enum Scenario: Sendable {
        case simpleAssistant(reply: String)
        case withTool(toolName: String, output: String, reply: String)
        case error(message: String)
    }

    public init(provider: AgentProvider = .codex, scenario: Scenario = .simpleAssistant(reply: "Hello from fake provider.")) {
        self.provider = provider
        self.scenario = scenario
    }

    public func listModels() async -> [AgentModelDescriptor] {
        [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider, supportsReasoning: false)]
    }

    public func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let cancellation = CancellationFlag()
        let handle = AgentRunHandle(runId: request.runId, process: nil) { cancellation.cancel() }
        let scenario = self.scenario

        Task.detached {
            onEvent(.status(.running))
            let threadId = request.providerThreadId ?? UUID().uuidString
            let turnId = UUID().uuidString
            let now = { Int64(Date().timeIntervalSince1970 * 1000) }
            onEvent(.event(.threadStarted(threadId: threadId, providerThreadId: threadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            if cancellation.isCancelled { onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: threadId)); return }
            switch scenario {
            case .simpleAssistant(let reply):
                let id = UUID().uuidString
                onEvent(.event(.itemStarted(item: AssistantItem(id: id, turnId: turnId, type: .assistantMessage, startedAtMs: now()))))
                for chunk in chunked(reply, size: 8) {
                    if cancellation.isCancelled { break }
                    onEvent(.event(.itemDelta(itemId: id, bodyAppend: chunk, outputAppend: nil, summary: nil)))
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                onEvent(.event(.itemCompleted(itemId: id, finalState: .completed)))
                onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: reply)))
            case .withTool(let tool, let output, let reply):
                let tid = UUID().uuidString
                onEvent(.event(.itemStarted(item: AssistantItem(id: tid, turnId: turnId, type: .tool, summary: tool, startedAtMs: now()))))
                onEvent(.event(.itemDelta(itemId: tid, bodyAppend: nil, outputAppend: output, summary: nil)))
                onEvent(.event(.itemCompleted(itemId: tid, finalState: .completed)))
                let aid = UUID().uuidString
                onEvent(.event(.itemStarted(item: AssistantItem(id: aid, turnId: turnId, type: .assistantMessage, startedAtMs: now()))))
                onEvent(.event(.itemDelta(itemId: aid, bodyAppend: reply, outputAppend: nil, summary: nil)))
                onEvent(.event(.itemCompleted(itemId: aid, finalState: .completed)))
                onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: reply)))
            case .error(let message):
                onEvent(.event(.error(message: message, recoverable: false)))
                onEvent(.finished(.failed, finalMessage: nil, providerThreadId: threadId))
                return
            }
            if cancellation.isCancelled {
                onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: threadId))
            } else {
                onEvent(.status(.completed))
                let finalText: String? = {
                    switch scenario {
                    case .simpleAssistant(let r): return r
                    case .withTool(_, _, let r): return r
                    case .error: return nil
                    }
                }()
                onEvent(.finished(.completed, finalMessage: finalText, providerThreadId: threadId))
            }
        }
        return handle
    }
}

private func chunked(_ s: String, size: Int) -> [String] {
    var out: [String] = []
    var idx = s.startIndex
    while idx < s.endIndex {
        let end = s.index(idx, offsetBy: size, limitedBy: s.endIndex) ?? s.endIndex
        out.append(String(s[idx..<end]))
        idx = end
    }
    return out
}
