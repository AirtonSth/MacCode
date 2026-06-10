import CoreModel

/// Lightweight emit carrier for CodexAppServerAdapter.
///
/// Problem: `emit(_:threadId:)` called `sessionSnapshot(threadId:)` which copied
/// the full Session struct — two dictionaries + three sets + the growing
/// `finalAssistantMessage` string — just to reach the `onEvent` closure.
/// On tool-heavy turns this copy happens dozens of times per second.
///
/// Fix: extract ONLY the `onEvent` closure from the session under lock (see
/// `CodexAppServerAdapter.onEventCallback(threadId:)`), wrap it here, and forward
/// events without touching any other session state.
///
/// No @MainActor, no stored session state, no lock — pure value type.
struct SessionEventEmitter {
    let onEvent: (@Sendable (AgentRunEvent) -> Void)?

    /// Wraps each `AssistantEvent` in `.event(...)` and forwards to `onEvent`.
    /// Mirrors the original `emit(_:threadId:)` loop, minus the full-Session copy.
    func broadcastEvents(_ events: [AssistantEvent]) {
        guard let onEvent, !events.isEmpty else { return }
        for event in events {
            onEvent(.event(event))
        }
    }

    /// Forwards a pre-wrapped `AgentRunEvent` (e.g. `.finished`, `.status`) directly.
    func broadcastEvent(_ event: AgentRunEvent) {
        onEvent?(event)
    }
}
