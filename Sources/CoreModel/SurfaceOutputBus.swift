import Foundation

/// HC-1: bridge live surface output (terminal PTY chunks, etc.) from the
/// `Surfaces` module to the network event bus without inverting the
/// module dependency graph. `Surfaces` and `AppShell` both see
/// `CoreModel`; `AppShell` wires `sink` to publish on `EventBus`.
public final class SurfaceOutputBus: @unchecked Sendable {
    public static let shared = SurfaceOutputBus()
    private init() {}

    /// Set by AppShell to forward to the network event bus.
    public var sink: ((_ surfaceId: SurfaceID, _ chunk: Data) -> Void)?

    public func emit(_ surfaceId: SurfaceID, _ chunk: Data) {
        sink?(surfaceId, chunk)
    }
}
