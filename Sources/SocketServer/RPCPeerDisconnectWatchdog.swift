import Darwin
import Foundation

/// Watches a handed-off `/v1/rpc` socket while its request runs and reports a
/// peer that went away (FIN, RST, or a host-side `shutdown` from revoke or
/// stop). The kernel wakes the read source only on those edges or on new
/// bytes, so an in-flight RPC costs no timer wakeups while it waits.
///
/// Ownership: `onDisconnect` runs from the cancel handler, after libdispatch
/// has dropped its interest in the descriptor, so it may close the fd.
/// `stop()` returns only after the cancel handler ran, so the caller can
/// close or reuse the fd afterwards without racing the source.
final class RPCPeerDisconnectWatchdog: @unchecked Sendable {
    private enum Peek {
        case bytesWaiting
        case wouldBlock
        case gone
    }

    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var disconnected = false
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        fd: Int32,
        isOwned: @escaping @Sendable () -> Bool,
        onDisconnect: @escaping @Sendable () -> Void
    ) {
        let queue = DispatchQueue(label: "rc2.rpc.peer-watchdog")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source
        source.setEventHandler { [self] in
            guard isOwned() else {
                markDisconnected()
                source.cancel()
                return
            }
            switch Self.peek(fd) {
            case .gone:
                markDisconnected()
                source.cancel()
            case .bytesWaiting:
                // A pipelined request is already buffered. The source is level
                // triggered, so keep it armed and it would spin; stop watching.
                // (The poll it replaces also saw "connected" for the rest of
                // the RPC in this case.)
                source.cancel()
            case .wouldBlock:
                break
            }
        }
        source.setCancelHandler { [self] in
            lock.lock()
            let wasDisconnected = disconnected
            lock.unlock()
            if wasDisconnected { onDisconnect() }
            lock.lock()
            finished = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
        }
        source.resume()
    }

    /// Stops watching and waits until the source is fully cancelled.
    func stop() async {
        source.cancel()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func markDisconnected() {
        lock.lock()
        disconnected = true
        lock.unlock()
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
