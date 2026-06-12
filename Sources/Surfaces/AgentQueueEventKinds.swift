import Foundation

/// Canonical wire names for agent message queue mirror events.
///
/// WHY: AgentAppSurface and AppCommandRouter both emit these strings to the
/// EventBus; iOS decodes them on the other side. A typo in a string literal
/// at an emit site would produce a silent cross-platform break — iOS receives
/// no event and the queue mirror falls out of sync. Centralising the names
/// here means any rename is caught by AgentQueueEventKindContractTests before
/// it reaches a device.
public enum AgentQueueEventKinds {
    /// A new message was added to the queue while a run is in flight.
    /// Payload shape: see AppCommandRouter.publishQueuedMessage.
    public static let queued        = "agent.message.queued"

    /// A queued message was edited or reordered; sent once per affected message.
    public static let updated       = "agent.message.queue.updated"

    /// A queued message was promoted and is now running; queue depth decreased.
    public static let drained       = "agent.message.queue.drained"

    /// A queued message was cancelled by the user.
    public static let cancelled     = "agent.message.queue.cancelled"
}
