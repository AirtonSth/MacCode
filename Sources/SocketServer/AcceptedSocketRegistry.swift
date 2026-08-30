import Darwin
import Foundation

final class AcceptedSocketRegistry: @unchecked Sendable {
    enum Scope: Equatable {
        case ordinary
        case tailcat
    }

    private struct Entry {
        let generation: UInt64
        let scope: Scope
    }

    enum RegistrationResult {
        case accepted
        case inactive
        case atCapacity(active: Int, limit: Int, shouldPublishDiagnostic: Bool)
    }

    static let defaultMaximumDescriptors = 64

    private let lock = NSLock()
    private var descriptors: [Int32: Entry] = [:]
    private var accepting = true
    private var generation: UInt64 = 1
    private var capacityDiagnosticArmed = true
    private let maximumDescriptors: Int
    private let shutdownDescriptor: @Sendable (Int32) -> Void

    init(
        maximumDescriptors: Int = AcceptedSocketRegistry.defaultMaximumDescriptors,
        shutdownDescriptor: @escaping @Sendable (Int32) -> Void = {
            _ = Darwin.shutdown($0, SHUT_RDWR)
        }
    ) {
        self.maximumDescriptors = max(1, maximumDescriptors)
        self.shutdownDescriptor = shutdownDescriptor
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return descriptors.count
    }

    @discardableResult
    func activate() -> UInt64 {
        lock.lock()
        generation &+= 1
        accepting = true
        capacityDiagnosticArmed = true
        let activatedGeneration = generation
        lock.unlock()
        return activatedGeneration
    }

    func isAccepting(generation expectedGeneration: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return accepting && generation == expectedGeneration
    }

    @discardableResult
    func register(_ descriptor: Int32, scope: Scope = .ordinary) -> Bool {
        if case .accepted = register(descriptor, expectedGeneration: nil, scope: scope) {
            return true
        }
        return false
    }

    func register(
        _ descriptor: Int32,
        generation expectedGeneration: UInt64,
        scope: Scope = .ordinary
    ) -> RegistrationResult {
        register(descriptor, expectedGeneration: expectedGeneration, scope: scope)
    }

    private func register(
        _ descriptor: Int32,
        expectedGeneration: UInt64?,
        scope: Scope = .ordinary
    ) -> RegistrationResult {
        lock.lock()
        let result: RegistrationResult
        if !accepting || expectedGeneration.map({ $0 != generation }) == true {
            result = .inactive
        } else if descriptors.count >= maximumDescriptors {
            let shouldPublishDiagnostic = capacityDiagnosticArmed
            capacityDiagnosticArmed = false
            result = .atCapacity(
                active: descriptors.count,
                limit: maximumDescriptors,
                shouldPublishDiagnostic: shouldPublishDiagnostic
            )
        } else {
            descriptors[descriptor] = Entry(generation: generation, scope: scope)
            result = .accepted
        }
        lock.unlock()

        if case .accepted = result {
            return result
        }
        shutdownDescriptor(descriptor)
        Darwin.close(descriptor)
        return result
    }

    func isActive(_ descriptor: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return accepting && descriptors[descriptor]?.generation == generation
    }

    @discardableResult
    func close(_ descriptor: Int32) -> Bool {
        guard closeWithoutClosing(descriptor) else { return false }
        Darwin.close(descriptor)
        return true
    }

    @discardableResult
    func closeWithoutClosing(_ descriptor: Int32) -> Bool {
        lock.lock()
        let owned = descriptors.removeValue(forKey: descriptor) != nil
        if owned, descriptors.count < maximumDescriptors {
            capacityDiagnosticArmed = true
        }
        lock.unlock()
        return owned
    }

    func shutdownAll() {
        lock.lock()
        accepting = false
        capacityDiagnosticArmed = true
        // Keep the registry lock through every shutdown. A handler's `close`
        // cannot release and recycle a numeric descriptor between this loop's
        // ownership snapshot and the syscall, so shutdown can never target an
        // unrelated file that reused the same integer.
        for descriptor in descriptors.keys {
            shutdownDescriptor(descriptor)
        }
        lock.unlock()
    }

    func shutdown(scope: Scope) {
        lock.lock()
        for (descriptor, entry) in descriptors where entry.scope == scope {
            shutdownDescriptor(descriptor)
        }
        lock.unlock()
    }
}
