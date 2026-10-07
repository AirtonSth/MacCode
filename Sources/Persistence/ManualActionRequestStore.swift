import CoreModel
import Foundation

/// Durable manual-action requests. A plain JSON file, not the provider pending-callback
/// table, because that table marks pending rows stale on restart.
public final class ManualActionRequestStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL

    public init(appSupportDirectory: URL) {
        fileURL = appSupportDirectory
            .appendingPathComponent("ManualActions", isDirectory: true)
            .appendingPathComponent("requests.json")
    }

    public func upsert(_ request: ManualActionRequest) throws {
        try lock.withLock {
            var items = load()
            if let index = items.firstIndex(where: { $0.id == request.id }) {
                items[index] = request
            } else {
                items.append(request)
            }
            try save(items)
        }
    }

    public func open(threadID: AgentThreadID) -> ManualActionRequest? {
        lock.withLock {
            load().last { $0.threadID == threadID && $0.state.isOpen }
        }
    }

    public func all(threadID: AgentThreadID) -> [ManualActionRequest] {
        lock.withLock { load().filter { $0.threadID == threadID } }
    }

    /// Only transitions an open/taken request; returns nil for unknown or already closed ids.
    /// A failed write throws and the request stays open.
    @discardableResult
    public func resolve(
        id: UUID,
        state: ManualActionState,
        note: String? = nil,
        at date: Date = Date()
    ) throws -> ManualActionRequest? {
        try lock.withLock {
            var items = load()
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].state.isOpen else {
                return nil
            }
            items[index].state = state
            items[index].note = note
            items[index].resolvedAt = date
            try save(items)
            return items[index]
        }
    }

    /// Only transitions open -> taken; nil for unknown, already taken or terminal ids.
    @discardableResult
    public func take(id: UUID) throws -> ManualActionRequest? {
        try lock.withLock {
            var items = load()
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .open else {
                return nil
            }
            items[index].state = .taken
            try save(items)
            return items[index]
        }
    }

    /// Stale timers pass an old id; a newer open request is untouched.
    @discardableResult
    public func expire(id: UUID) throws -> ManualActionRequest? {
        try resolve(id: id, state: .expired)
    }

    /// The Mac card and the paired-device RPC both go through this: the store write picks the
    /// single winner and only the winner takes the bot's computer. nil for unknown, taken or closed ids.
    @discardableResult
    public func take(id: UUID, control: BotComputerControl) throws -> ManualActionRequest? {
        guard let taken = try take(id: id) else { return nil }
        control.take(taken.botID)
        return taken
    }

    /// Continue or decline for the Mac card and the paired-device RPC: only the winner hands control
    /// back and closes the bot's in-memory request. nil for unknown or already closed ids.
    @discardableResult
    public func resolve(
        id: UUID,
        state: ManualActionState,
        note: String?,
        control: BotComputerControl
    ) throws -> ManualActionRequest? {
        guard let resolved = try resolve(id: id, state: state, note: note) else { return nil }
        control.release(resolved.botID)
        control.dismiss(resolved.id, as: state, note: note)
        return resolved
    }

    /// Every thread's open or taken request (the newest when several), read once.
    public func openByThread() -> [AgentThreadID: ManualActionRequest] {
        lock.withLock {
            var open: [AgentThreadID: ManualActionRequest] = [:]
            for request in load() where request.state.isOpen {
                if let threadID = request.threadID { open[threadID] = request }
            }
            return open
        }
    }

    public func closeAll(botID: BotID) throws {
        try lock.withLock {
            var items = load()
            var changed = false
            for index in items.indices where items[index].botID == botID && items[index].state.isOpen {
                items[index].state = .expired
                items[index].resolvedAt = Date()
                changed = true
            }
            if changed { try save(items) }
        }
    }

    private func load() -> [ManualActionRequest] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ManualActionRequest].self, from: data)) ?? []
    }

    private func save(_ items: [ManualActionRequest]) throws {
        let data = try JSONEncoder().encode(items)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
