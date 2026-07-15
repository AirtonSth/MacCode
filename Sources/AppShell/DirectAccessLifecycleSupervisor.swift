import Foundation

@MainActor
final class DirectAccessLifecycleSupervisor {
    typealias RetryCancellation = @MainActor () -> Void
    typealias RetryScheduler = @MainActor (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> RetryCancellation

    private enum State {
        case stopped
        case running(advertised: Bool)
        case suspended
    }

    private let startServer: (Bool) throws -> Void
    private let stopServer: () -> Void
    private let publishBonjour: () -> Void
    private let stopBonjour: () -> Void
    private let retryDelays: [TimeInterval]
    private let scheduleRetry: RetryScheduler
    private let retryLogger: (_ attempt: Int, _ delay: TimeInterval, _ error: Error) -> Void
    private var state: State = .stopped
    private var retryIndex = 0
    private var cancelRetry: RetryCancellation?
    /// Monotonic guard for armed retries: the default scheduler hops
    /// DispatchWorkItem → Task, and a cancel between those hops is lost —
    /// the stale Task would still run start(remoteEnabled:) after the user
    /// toggled remote access off (or the Mac slept). Every cancel/re-arm
    /// bumps the generation; a retry whose captured generation is stale
    /// must no-op.
    private var retryGeneration: UInt64 = 0

    init(
        startServer: @escaping (Bool) throws -> Void,
        stopServer: @escaping () -> Void,
        publishBonjour: @escaping () -> Void,
        stopBonjour: @escaping () -> Void,
        retryDelays: [TimeInterval] = [1, 2, 4],
        scheduleRetry: @escaping RetryScheduler = DirectAccessLifecycleSupervisor.defaultRetryScheduler,
        retryLogger: @escaping (_ attempt: Int, _ delay: TimeInterval, _ error: Error) -> Void = { _, _, _ in }
    ) {
        self.startServer = startServer
        self.stopServer = stopServer
        self.publishBonjour = publishBonjour
        self.stopBonjour = stopBonjour
        self.retryDelays = retryDelays
        self.scheduleRetry = scheduleRetry
        self.retryLogger = retryLogger
    }

    func configure(remoteEnabled: Bool) throws {
        cancelPendingRetry()
        tearDownRunningState()
        retryIndex = 0
        do {
            try start(remoteEnabled: remoteEnabled)
        } catch {
            state = .stopped
            scheduleNextRetry(remoteEnabled: remoteEnabled, error: error)
            throw error
        }
    }

    func suspend() {
        cancelPendingRetry()
        if case .running(let advertised) = state {
            if advertised { stopBonjour() }
            stopServer()
        }
        state = .suspended
    }

    func resume(remoteEnabled: Bool) throws {
        guard case .suspended = state else { return }
        retryIndex = 0
        do {
            try start(remoteEnabled: remoteEnabled)
        } catch {
            state = .stopped
            scheduleNextRetry(remoteEnabled: remoteEnabled, error: error)
            throw error
        }
    }

    func shutdown() {
        cancelPendingRetry()
        tearDownRunningState()
        state = .stopped
    }

    private func start(remoteEnabled: Bool) throws {
        try startServer(remoteEnabled)
        if remoteEnabled { publishBonjour() }
        state = .running(advertised: remoteEnabled)
    }

    private func scheduleNextRetry(remoteEnabled: Bool, error: Error) {
        guard retryIndex < retryDelays.count else { return }
        let delay = retryDelays[retryIndex]
        retryIndex += 1
        retryLogger(retryIndex, delay, error)
        let generation = retryGeneration
        cancelRetry = scheduleRetry(delay) { [weak self] in
            guard let self, self.retryGeneration == generation else { return }
            self.cancelRetry = nil
            do {
                try self.start(remoteEnabled: remoteEnabled)
            } catch {
                self.state = .stopped
                self.scheduleNextRetry(remoteEnabled: remoteEnabled, error: error)
            }
        }
    }

    private func cancelPendingRetry() {
        retryGeneration &+= 1
        cancelRetry?()
        cancelRetry = nil
    }

    private func tearDownRunningState() {
        guard case .running(let advertised) = state else { return }
        if advertised { stopBonjour() }
        stopServer()
        state = .stopped
    }

    private static func defaultRetryScheduler(
        delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> RetryCancellation {
        let item = DispatchWorkItem {
            Task { @MainActor in action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}
