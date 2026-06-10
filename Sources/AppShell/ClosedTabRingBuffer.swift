import Foundation
import CoreModel

/// Closed-tab entry: the descriptor that was removed plus the workspace cwd
/// at close time (so the terminal re-launches in the same directory).
public struct ClosedTabEntry: Sendable, Equatable {
    public let descriptor: SurfaceDescriptor
    public let workspaceCwd: String

    public init(descriptor: SurfaceDescriptor, workspaceCwd: String) {
        self.descriptor = descriptor
        self.workspaceCwd = workspaceCwd
    }
}

/// Fixed-capacity ring buffer of `ClosedTabEntry` values keyed per workspace.
/// Push beyond capacity silently drops the oldest entry (not the newest).
/// Purely value-typed; no AppKit or @MainActor dependency.
public struct ClosedTabRingBuffer {
    public let capacity: Int
    private var store: [WorkspaceID: [ClosedTabEntry]] = [:]

    public init(capacity: Int = 10) {
        precondition(capacity > 0, "capacity must be > 0")
        self.capacity = capacity
    }

    /// Append a closed-tab entry for a workspace.
    /// If count already equals capacity, the oldest entry for that workspace is dropped.
    public mutating func push(_ entry: ClosedTabEntry, for workspace: WorkspaceID) {
        var entries = store[workspace] ?? []
        if entries.count >= capacity {
            entries.removeFirst()
        }
        entries.append(entry)
        store[workspace] = entries
    }

    /// Return and remove the most-recently-closed entry for a workspace, or nil if empty.
    public mutating func pop(for workspace: WorkspaceID) -> ClosedTabEntry? {
        guard var entries = store[workspace], !entries.isEmpty else { return nil }
        let last = entries.removeLast()
        store[workspace] = entries.isEmpty ? nil : entries
        return last
    }

    /// Number of entries queued for a workspace.
    public func count(for workspace: WorkspaceID) -> Int {
        store[workspace]?.count ?? 0
    }
}
