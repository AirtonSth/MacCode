import Darwin
import Foundation

/// Watches a handed-off `/v1/rpc` socket while its request runs and reports a
/// peer that went away (FIN, RST, or a host-side `shutdown` from revoke or
/// stop). The kernel wakes the read source only on those edges or on new
/// bytes, so an in-flight RPC costs no timer wakeups while it waits.
///
/// Ownership: `onDisconnect` runs after libdispatch has dropped its interest
/// in the descriptor, so it may close the fd. `stop()` returns only after
/// that, and reports whether `onDisconnect` ran. When it did, the caller must
/// not touch the fd number again: it was released and may already belong to
/// another accepted connection.
final class RPCPeerDisconnectWatchdog: @unchecked Sendable {
    private enum Peek {
        case bytesWaiting
        case wouldBlock
        case gone
    }

    /// Fallback poll interval once a pipelined request is buffered. Same
    /// cadence as the poll this type replaced.
    static let bufferedPollInterval: DispatchTimeInterval = .milliseconds(5)

    private let fd: Int32
    private let isOwned: @Sendable () -> Bool
    private let onDisconnect: @Sendable () -> Void
    private let queue = DispatchQueue(label: "rc2.rpc.peer-watchdog")
    private let source: DispatchSourceRead
    // Only touched on `queue`.
    private var fallback: DispatchSourceTimer?
    private var liveSources = 1
    private var stopRequested = false
    private var disconnected = false

    private let lock = NSLock()
    private var finished = false
    private var finishedDisconnected = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    init(
        fd: Int32,
        isOwned: @escaping @Sendable () -> Bool,
        onDisconnect: @escaping @Sendable () -> Void
    ) {
        self.fd = fd
        self.isOwned = isOwned
        self.onDisconnect = onDisconnect
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source
        source.setEventHandler { [self] in readEvent() }
        source.setCancelHandler { [self] in sourceCancelled() }
        source.resume()
    }

    /// Stops watching and waits until every source is fully cancelled.
    /// Returns true when the watchdog already reported a disconnect (and so
    /// released the fd); the caller must then leave the fd number alone.
    @discardableResult
    func stop() async -> Bool {
        queue.async { [self] in
            stopRequested = true
            source.cancel()
            fallback?.cancel()
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if finished {
                let result = finishedDisconnected
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func readEvent() {
        guard isOwned() else {
            disconnected = true
            source.cancel()
            return
        }
        switch Self.peek(fd) {
        case .gone:
            disconnected = true
            source.cancel()
        case .bytesWaiting:
            // A pipelined request is already buffered and must stay unread for
            // the keep-alive reader. The read source is level triggered and
            // would spin, so hand over to a poll at the old cadence. A peer FIN
            // still reads as "connected" here (as it did with the old poll),
            // but a host-side shutdown flushes the buffer and a registry
            // release flips ownership, so revoke and stop still cancel the RPC.
            if !stopRequested { startBufferedPoll() }
            source.cancel()
        case .wouldBlock:
            break
        }
    }

    private func startBufferedPoll() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.bufferedPollInterval,
            repeating: Self.bufferedPollInterval,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [self] in
            if !isOwned() || Self.peek(fd) == .gone {
                disconnected = true
                timer.cancel()
            }
        }
        timer.setCancelHandler { [self] in sourceCancelled() }
        fallback = timer
        liveSources += 1
        timer.resume()
    }

    private func sourceCancelled() {
        liveSources -= 1
        guard liveSources == 0 else { return }
        let wasDisconnected = disconnected
        if wasDisconnected { onDisconnect() }
        lock.lock()
        finished = true
        finishedDisconnected = wasDisconnected
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: wasDisconnected) }
    }

    private static func peek(_ fd: Int32) -> Peek {
        var byte: UInt8 = 0
        let result = withUnsafeMutableBytes(of: &byte) { buffer in
            Darwin.recv(fd, buffer.baseAddress, 1, MSG_PEEK | MSG_DONTWAIT)
        }
        if result > 0 { return .bytesWaiting }
        if result == 0 { return .gone }
        return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ? .wouldBlock : .gone
    }
}
