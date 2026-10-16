import Foundation

public struct BotContextDelegation: Codable, Equatable, Sendable {
    public let version: Int
    public let parentRunID: AgentRunID
    public let parentThreadID: AgentThreadID
    public let parentPin: BotConversationContextPin
    public let childRunID: AgentRunID
    public let childThreadID: AgentThreadID
    public let childPin: BotConversationContextPin
    /// Authority is closed; guest recovery tracks physical cleanup separately.
    public let closed: Bool

    public static let maximumAncestorDepth = 64

    public init(
        version: Int = 1,
        parentRunID: AgentRunID,
        parentThreadID: AgentThreadID,
        parentPin: BotConversationContextPin,
        childRunID: AgentRunID,
        childThreadID: AgentThreadID,
        childPin: BotConversationContextPin,
        closed: Bool = false
    ) {
        self.version = version
        self.parentRunID = parentRunID
        self.parentThreadID = parentThreadID
        self.parentPin = parentPin
        self.childRunID = childRunID
        self.childThreadID = childThreadID
        self.childPin = childPin
        self.closed = closed
    }
}
