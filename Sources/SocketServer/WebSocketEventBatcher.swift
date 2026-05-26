import Foundation

final class WebSocketEventBatcher: @unchecked Sendable {
    private let enabled: Bool
    private let filter: EventStreamFilter
    private let delay: TimeInterval
    private let send: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "io.remotecode.ws-event-batcher")
    private var pending: [String: Data] = [:]
    private var order: [String] = []
    private var scheduled = false

    init(enabled: Bool,
         filter: EventStreamFilter,
         delay: TimeInterval = 0.075,
         send: @escaping @Sendable (Data) -> Void) {
        self.enabled = enabled
        self.filter = filter
        self.delay = max(0, delay)
        self.send = send
    }

    func enqueue(event: EventBus.Event, data: Data) {
        guard enabled, let key = filter.coalescingKey(for: event) else {
            queue.async {
                self.flushLocked()
                self.send(data)
            }
            return
        }

        queue.async {
            if self.pending[key] == nil {
                self.order.append(key)
            }
            self.pending[key] = data
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + self.delay) {
                self.flushLocked()
            }
        }
    }

    func flush() {
        queue.sync {
            flushLocked()
        }
    }

    private func flushLocked() {
        guard !pending.isEmpty else {
            scheduled = false
            return
        }
        let keys = order
        let frames = keys.compactMap { pending[$0] }
        pending.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        scheduled = false
        for frame in frames {
            send(frame)
        }
    }
}
