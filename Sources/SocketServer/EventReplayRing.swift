/// FIFO circular buffer behind EventBus's replay ring: appends at the back,
/// evicts from the front in O(1), and reads oldest first like the `[Event]`
/// it replaced. `Array.removeFirst()` shifted the whole 4,096-event window on
/// every publish once the ring was full. An evicted slot is cleared at once so
/// its payload is not kept alive.
struct EventReplayRing<Element>: RandomAccessCollection {
    private var slots: [Element?] = []
    private var head = 0
    private(set) var count = 0

    init() {}

    init<S: Sequence>(_ elements: S) where S.Element == Element {
        for element in elements { append(element) }
    }

    var startIndex: Int { 0 }
    var endIndex: Int { count }

    subscript(position: Int) -> Element {
        precondition(position >= 0 && position < count, "EventReplayRing index out of range")
        return slots[slot(position)]!
    }

    mutating func append(_ element: Element) {
        if count == slots.count { grow() }
        slots[slot(count)] = element
        count += 1
    }

    @discardableResult
    mutating func removeFirst() -> Element {
        precondition(count > 0, "removeFirst on an empty EventReplayRing")
        let element = slots[head]!
        slots[head] = nil
        head = head + 1 == slots.count ? 0 : head + 1
        count -= 1
        return element
    }

    /// Empties the ring and keeps its capacity.
    mutating func removeAll() {
        for index in 0..<count { slots[slot(index)] = nil }
        head = 0
        count = 0
    }

    private func slot(_ position: Int) -> Int {
        let raw = head + position
        return raw < slots.count ? raw : raw - slots.count
    }

    private mutating func grow() {
        var grown: [Element?] = []
        grown.reserveCapacity(Swift.max(16, slots.count * 2))
        for index in 0..<count { grown.append(slots[slot(index)]) }
        grown.append(contentsOf: repeatElement(nil, count: grown.capacity - count))
        slots = grown
        head = 0
    }
}
