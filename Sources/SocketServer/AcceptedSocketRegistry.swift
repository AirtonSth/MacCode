import Darwin
import Foundation

final class AcceptedSocketRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: Set<Int32> = []
    private var accepting = true

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return descriptors.count
    }

    func activate() {
        lock.lock()
        accepting = true
        lock.unlock()
    }

    @discardableResult
    func register(_ descriptor: Int32) -> Bool {
        lock.lock()
        let accepted = accepting
        if accepted { descriptors.insert(descriptor) }
        lock.unlock()
        if !accepted { Darwin.close(descriptor) }
        return accepted
    }

    func isActive(_ descriptor: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return accepting && descriptors.contains(descriptor)
    }

    @discardableResult
    func close(_ descriptor: Int32) -> Bool {
        lock.lock()
        let owned = descriptors.remove(descriptor) != nil
        lock.unlock()
        guard owned else { return false }
        Darwin.close(descriptor)
        return true
    }

    func shutdownAll() {
        lock.lock()
        let owned = descriptors
        accepting = false
        lock.unlock()
        for descriptor in owned {
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }
}
