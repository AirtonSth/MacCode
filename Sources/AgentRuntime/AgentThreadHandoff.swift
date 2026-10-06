import Foundation
import CoreModel

/// Deterministic continuation text for a conversation whose provider session
/// stays behind: a bot hand-off into a new thread, or a bot's Linux-guest
/// thread moved to the Mac, whose guest session the Mac cannot load.
public enum AgentThreadHandoff {
    /// Max chars kept per message.
    static let messageLimit = 300
    static let messageCount = 6

    /// Header plus the last user/assistant messages, truncated.
    public static func summary(title: String, threadId: AgentThreadID, messages: [AgentMessage]) -> String {
        var lines = ["Continuação da thread \"\(title)\" (id \(threadId.value.uuidString.lowercased()))"]
        let turns = messages.filter { $0.role == .user || $0.role == .assistant }.suffix(messageCount)
        for message in turns {
            let label = message.role == .user ? "Usuário" : "Assistente"
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = text.count > messageLimit ? String(text.prefix(messageLimit)) + "…" : text
            lines.append("\(label): \(clipped)")
        }
        return lines.joined(separator: "\n")
    }
}
