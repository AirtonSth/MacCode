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
    }

    private let fd: Int32
    private let state = NSLock()
    private var busy = false
    private var waiters: [Waiter] = []
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
        let directory = lockURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let opened = lockURL.path.withCString { pointer in
            open(pointer, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        self.fd = opened
    }

    deinit {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    /// Exclusive critical section. Observation uses the same lock so a screenshot
    /// cannot race a click. Throws if the waiter is cancelled before it acquires.
    public func withExclusive<T: Sendable>(
        kind: Kind,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        _ = kind
        try await acquireToken()
        do {
            let value = try await body()
            releaseToken()
            return value
        } catch {
            releaseToken()
            throw error
        }
    }

    /// Same exclusive lease, but returns the recorded interval so overlap tests
    /// drive the shipped lock instead of a mock clock.
    public func withExclusiveLease<T: Sendable>(
        kind: Kind,
        body: @Sendable () async throws -> T
    ) async throws -> (T, Lease) {
        try await acquireToken()
        let acquiredAtNs = DispatchTime.now().uptimeNanoseconds
        do {
            let value = try await body()
            let lease = Lease(
                kind: kind,
                acquiredAtNs: acquiredAtNs,
                releasedAtNs: DispatchTime.now().uptimeNanoseconds
            )
            releaseToken()
            return (value, lease)
        } catch {
            releaseToken()
            throw error
        }
    }

    private func acquireToken() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.lock()
                if Task.isCancelled {
                    state.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if !busy {
                    busy = true
                    lockFile()
                    state.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
                state.unlock()
            }
        } onCancel: {
            cancelWaiter(id: id)
        }
    }

    private func cancelWaiter(id: UUID) {
        state.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            state.unlock()
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        state.unlock()
    }

    private func releaseToken() {
        state.lock()
        unlockFile()
        if waiters.isEmpty {
            busy = false
            state.unlock()
            return
        }
        let next = waiters.removeFirst()
        lockFile()
        state.unlock()
        next.continuation.resume()
    }

    private func lockFile() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_EX)
    }

    private func unlockFile() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
    }
}

public enum ComputerUseHostQueueError: Error, Equatable, CustomStringConvertible {
    case lockFileUnavailable(String)

    public var description: String {
        switch self {
        case .lockFileUnavailable(let path):
            return "Computer-use lock file unavailable: \(path)"
        }
    }
}
