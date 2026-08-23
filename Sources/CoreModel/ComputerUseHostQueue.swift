import Darwin
import Foundation

/// Host-wide exclusive lease for computer-use HID / mutating tools.
///
/// In-process callers share a FIFO token so two async tasks cannot interleave.
/// Separate MCP stdio processes share the same lock file so two bots cannot
/// drive the pointer or keyboard together.
public final class ComputerUseHostQueue: @unchecked Sendable {
    public static let cliArgument = "computer-use-mcp"
    public static let serverName = "remotecode-computer-use"
    static let maximumWaitersPerTarget = 128
    private static let maximumTicketsPerTarget = maximumWaitersPerTarget + 1

    public enum Kind: String, Sendable, Equatable {
        case observation
        case mutation
    }

    public struct Lease: Sendable, Equatable {
        public var kind: Kind
        public var acquiredAtNs: UInt64
        public var releasedAtNs: UInt64

        public func overlaps(_ other: Lease) -> Bool {
            acquiredAtNs < other.releasedAtNs && other.acquiredAtNs < releasedAtNs
        }
    }

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, Error>
        var ticket: Ticket
    }

    private struct Ticket {
        var url: URL
    }

    private final class TargetState {
        var busy = false
        var waiters: [Waiter] = []
        var fd: Int32 = -1
        var activeID: UUID?
        var activeTicket: Ticket?
        var activeContinuation: CheckedContinuation<Void, Error>?
    }

    private let state = NSLock()
    private var targets: [String: TargetState] = [:]
    public let lockURL: URL

    public static var defaultLockURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("RemoteCode", isDirectory: true)
            .appendingPathComponent("computer-use.lock")
    }

    public static let shared = ComputerUseHostQueue(lockURL: defaultLockURL)

    public init(lockURL: URL) {
        self.lockURL = lockURL
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    deinit {
        state.lock()
        let active = targets.values.compactMap { state -> (Int32, Ticket?)? in
            guard state.fd >= 0 || state.activeTicket != nil else { return nil }
            return (state.fd, state.activeTicket)
        }
        let waiters = targets.values.flatMap(\.waiters)
        targets.removeAll()
        state.unlock()
        for (fd, ticket) in active {
            removeTicket(ticket)
            guard fd >= 0 else { continue }
            flock(fd, LOCK_UN)
            close(fd)
        }
        for waiter in waiters { removeTicket(waiter.ticket) }
    }

    /// Exclusive critical section. Observation uses the same lock so a screenshot
    /// cannot race a click. Throws if the waiter is cancelled before it acquires.
    public func withExclusive<T: Sendable>(
        kind: Kind,
        targetPID: Int32? = nil,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquireToken(targetPID: targetPID)
        do {
            let value = try await body()
            releaseToken(targetPID: targetPID)
            return value
        } catch {
            releaseToken(targetPID: targetPID)
            throw error
        }
    }

    /// Target-labelled convenience for call sites where the host PID is the
    /// primary part of the operation's identity.
    public func withExclusive<T: Sendable>(
        targetPID: Int32,
        kind: Kind,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        try await withExclusive(kind: kind, targetPID: targetPID, body: body)
    }

    /// Same exclusive lease, but returns the recorded interval so overlap tests
    /// drive the shipped lock instead of a mock clock.
    public func withExclusiveLease<T: Sendable>(
        kind: Kind,
        targetPID: Int32? = nil,
        body: @Sendable () async throws -> T
    ) async throws -> (T, Lease) {
        try await acquireToken(targetPID: targetPID)
        let acquiredAtNs = DispatchTime.now().uptimeNanoseconds
        do {
            let value = try await body()
            let lease = Lease(
                kind: kind,
                acquiredAtNs: acquiredAtNs,
                releasedAtNs: DispatchTime.now().uptimeNanoseconds
            )
            releaseToken(targetPID: targetPID)
            return (value, lease)
        } catch {
            releaseToken(targetPID: targetPID)
            throw error
        }
    }

    private func acquireToken(targetPID: Int32?) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let key = key(for: targetPID)
        let ticket: Ticket
        do {
            ticket = try createTicket(for: targetPID)
        } catch let error as ComputerUseHostQueueError {
            throw error
        } catch {
            throw ComputerUseHostQueueError.lockFileUnavailable(lockURL.path)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.lock()
                if Task.isCancelled {
                    state.unlock()
                    removeTicket(ticket)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let target: TargetState
                if let existing = targets[key] {
                    target = existing
                } else {
                    let created = TargetState()
                    targets[key] = created
                    target = created
                }
                if target.busy, target.waiters.count >= Self.maximumWaitersPerTarget {
                    state.unlock()
                    removeTicket(ticket)
                    continuation.resume(throwing: ComputerUseHostQueueError.queueFull(targetPID))
                    return
                }
                if !target.busy {
                    target.busy = true
                    target.activeID = id
                    target.activeTicket = ticket
                    target.activeContinuation = continuation
                    state.unlock()
                    startLease(
                        id: id,
                        ticket: ticket,
                        targetPID: targetPID,
                        key: key,
                        target: target,
                        continuation: continuation
                    )
                    return
                }
                target.waiters.append(Waiter(id: id, continuation: continuation, ticket: ticket))
                state.unlock()
            }
        } onCancel: {
            cancelWaiter(id: id, targetPID: targetPID)
        }
    }

    private func cancelWaiter(id: UUID, targetPID: Int32?) {
        let key = key(for: targetPID)
        state.lock()
        guard let target = targets[key] else {
            state.unlock()
            return
        }
        if let index = target.waiters.firstIndex(where: { $0.id == id }) {
            let waiter = target.waiters.remove(at: index)
            state.unlock()
            removeTicket(waiter.ticket)
            waiter.continuation.resume(throwing: CancellationError())
            return
        }

        // The first local lease can be asynchronously waiting behind another
        // process's ticket. Cancellation must remove that active ticket and
        // promote the next local waiter, otherwise the detached starter could
        // later acquire the lock after its caller has already been cancelled.
        guard target.activeID == id, target.fd < 0,
              let continuation = target.activeContinuation else {
            state.unlock()
            return
        }
        let ticket = target.activeTicket
        let next = target.waiters.isEmpty ? nil : target.waiters.removeFirst()
        if let next {
            target.activeID = next.id
            target.activeTicket = next.ticket
            target.activeContinuation = next.continuation
        } else {
            target.activeID = nil
            target.activeTicket = nil
            target.activeContinuation = nil
            target.busy = false
            targets.removeValue(forKey: key)
        }
        state.unlock()
        removeTicket(ticket)
        continuation.resume(throwing: CancellationError())
        if let next {
            startLease(
                id: next.id,
                ticket: next.ticket,
                targetPID: targetPID,
                key: key,
                target: target,
                continuation: next.continuation
            )
        }
    }

    private func releaseToken(targetPID: Int32?) {
        let key = key(for: targetPID)
        state.lock()
        guard let target = targets[key] else {
            state.unlock()
            return
        }
        let releasedFD = target.fd
        let releasedTicket = target.activeTicket
        target.fd = -1
        target.activeID = nil
        target.activeTicket = nil
        target.activeContinuation = nil
        if releasedFD >= 0 {
            flock(releasedFD, LOCK_UN)
            close(releasedFD)
        }
        guard !target.waiters.isEmpty else {
            target.busy = false
            targets.removeValue(forKey: key)
            state.unlock()
            removeTicket(releasedTicket)
            return
        }
        let next = target.waiters.removeFirst()
        target.activeID = next.id
        target.activeTicket = next.ticket
        target.activeContinuation = next.continuation
        state.unlock()
        removeTicket(releasedTicket)
        startLease(
            id: next.id,
            ticket: next.ticket,
            targetPID: targetPID,
            key: key,
            target: target,
            continuation: next.continuation
        )
    }

    private func key(for targetPID: Int32?) -> String {
        targetPID.map { "pid:\($0)" } ?? "global"
    }

    private func openLockFile(for targetPID: Int32?) -> Int32 {
        let url: URL
        if let targetPID {
            let base = lockURL.deletingPathExtension().lastPathComponent
            url = lockURL.deletingLastPathComponent()
                .appendingPathComponent("\(base).pid-\(targetPID).lock")
        } else {
            url = lockURL
        }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = url.path.withCString { pointer in
            open(pointer, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0, flock(fd, LOCK_EX) == 0 else {
            if fd >= 0 { close(fd) }
            return -1
        }
        return fd
    }

    private func startLease(
        id: UUID,
        ticket: Ticket,
        targetPID: Int32?,
        key: String,
        target: TargetState,
        continuation: CheckedContinuation<Void, Error>
    ) {
        Task {
            do {
                try await waitForTurn(ticket, targetPID: targetPID)
                try Task.checkCancellation()
                let fd = openLockFile(for: targetPID)
                guard fd >= 0 else {
                    throw ComputerUseHostQueueError.lockFileUnavailable(lockURL.path)
                }
                guard installLease(fd: fd, id: id, target: target, ticket: ticket) else {
                    return
                }
                continuation.resume()
            } catch {
                removeTicket(ticket)
                let (isCurrent, remaining) = failLease(id: id, key: key, target: target)
                if isCurrent {
                    continuation.resume(throwing: error)
                } else {
                    return
                }
                for waiter in remaining {
                    removeTicket(waiter.ticket)
                    waiter.continuation.resume(throwing: error)
                }
            }
        }
    }

    private func installLease(fd: Int32, id: UUID, target: TargetState, ticket: Ticket) -> Bool {
        state.lock()
        guard target.activeID == id else {
            state.unlock()
            flock(fd, LOCK_UN)
            close(fd)
            removeTicket(ticket)
            return false
        }
        target.fd = fd
        state.unlock()
        return true
    }

    private func failLease(id: UUID, key: String, target: TargetState) -> (Bool, [Waiter]) {
        state.lock()
        let isCurrent = target.activeID == id
        if isCurrent {
            target.activeID = nil
            target.activeTicket = nil
            target.activeContinuation = nil
            target.busy = false
            targets.removeValue(forKey: key)
        }
        let remaining = isCurrent ? target.waiters : []
        if isCurrent { target.waiters.removeAll() }
        state.unlock()
        return (isCurrent, remaining)
    }

    private func queueDirectory(for targetPID: Int32?) -> URL {
        let base = lockURL.deletingPathExtension().lastPathComponent
        let suffix = targetPID.map { ".pid-\($0)" } ?? ".global"
        return lockURL.deletingLastPathComponent()
            .appendingPathComponent("\(base)\(suffix).queue", isDirectory: true)
    }

    private func createTicket(for targetPID: Int32?) throws -> Ticket {
        let directory = queueDirectory(for: targetPID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let counterURL = directory.appendingPathComponent("counter")
        let counterFD = open(counterURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard counterFD >= 0, flock(counterFD, LOCK_EX) == 0 else {
            if counterFD >= 0 { close(counterFD) }
            throw ComputerUseHostQueueError.lockFileUnavailable(lockURL.path)
        }
        defer {
            flock(counterFD, LOCK_UN)
            close(counterFD)
        }

        cleanupStaleTickets(in: directory)
        let ticketCount = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("ticket-") }.count) ?? 0
        guard ticketCount < Self.maximumTicketsPerTarget else {
            throw ComputerUseHostQueueError.queueFull(targetPID)
        }

        var counterBytes = [UInt8](repeating: 0, count: 32)
        lseek(counterFD, 0, SEEK_SET)
        let readCount = read(counterFD, &counterBytes, counterBytes.count)
        let current = readCount > 0
            ? UInt64(String(decoding: counterBytes[..<readCount], as: UTF8.self)) ?? 0
            : 0
        let sequence = current &+ 1
        let id = UUID()
        let filename = String(format: "ticket-%020llu-%@", sequence, id.uuidString)
        let url = directory.appendingPathComponent(filename)
        let ticketFD = open(url.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard ticketFD >= 0 else {
            throw ComputerUseHostQueueError.lockFileUnavailable(lockURL.path)
        }
        let payload = "\(getpid())|\(DispatchTime.now().uptimeNanoseconds)"
        payload.data(using: .utf8)!.withUnsafeBytes { bytes in
            _ = write(ticketFD, bytes.baseAddress, bytes.count)
        }
        fsync(ticketFD)
        close(ticketFD)
        let encoded = sequence
        let output = String(encoded).data(using: .utf8)!
        lseek(counterFD, 0, SEEK_SET)
        ftruncate(counterFD, 0)
        output.withUnsafeBytes { bytes in
            _ = write(counterFD, bytes.baseAddress, bytes.count)
        }
        fsync(counterFD)
        return Ticket(url: url)
    }

    private func waitForTurn(_ ticket: Ticket, targetPID: Int32?) async throws {
        let directory = queueDirectory(for: targetPID)
        while true {
            try Task.checkCancellation()
            cleanupStaleTickets(in: directory)
            let earlier = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("ticket-") }
                .contains { $0.lastPathComponent < ticket.url.lastPathComponent }) ?? false
            if !earlier { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func cleanupStaleTickets(in directory: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("ticket-") }) ?? []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let record = String(data: data, encoding: .utf8),
                  let owner = Int32(record.split(separator: "|").first ?? "") else {
                continue
            }
            let ownerDead = owner != getpid() && kill(owner, 0) != 0 && errno == ESRCH
            if ownerDead {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func removeTicket(_ ticket: Ticket?) {
        guard let ticket else { return }
        try? FileManager.default.removeItem(at: ticket.url)
    }
}

public enum ComputerUseHostQueueError: Error, Equatable, CustomStringConvertible {
    case lockFileUnavailable(String)
    case queueFull(Int32?)

    public var description: String {
        switch self {
        case .lockFileUnavailable(let path):
            return "Computer-use lock file unavailable: \(path)"
        case .queueFull(let targetPID):
            let target = targetPID.map(String.init) ?? "global"
            return "Computer-use host queue is full for \(target)."
        }
    }
}
