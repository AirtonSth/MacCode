import XCTest
import Darwin
@testable import SocketServer

/// WHY: the listener fd must be close-on-exec. Without FD_CLOEXEC every child
/// spawned while the server runs (forkpty terminal shells, helper processes)
/// inherits port 18217's socket; after the app stops, the orphan keeps the
/// port bound, rebinding fails EADDRINUSE, and iOS connects hang in a backlog
/// nobody accepts (observed live on 2026-07-14: two zsh children held the
/// LISTEN socket). Reproduced here with raw posix_spawn, which — unlike
/// Foundation.Process — inherits any fd not marked close-on-exec.
final class HTTPListenerInheritanceTests: XCTestCase {

    func test_closeOnExecSetupPreservesFlagsAndFailsClosed() {
        // WHY: silently ignoring either fcntl failure lets every terminal child
        // inherit the listener/client descriptor and pin it after app shutdown.
        var installedFlags: Int32?
        XCTAssertTrue(DirectHTTPServer.enableCloseOnExec(
            42,
            getFlags: { _ in 0x40 },
            setFlags: { _, flags in installedFlags = flags; return 0 }
        ))
        XCTAssertEqual(installedFlags, 0x40 | FD_CLOEXEC)

        XCTAssertFalse(DirectHTTPServer.enableCloseOnExec(
            42,
            getFlags: { _ in -1 },
            setFlags: { _, _ in XCTFail("setter must not run after F_GETFD fails"); return 0 }
        ))
        XCTAssertFalse(DirectHTTPServer.enableCloseOnExec(
            42,
            getFlags: { _ in 0 },
            setFlags: { _, _ in -1 }
        ))

        var setterCalled = false
        XCTAssertTrue(DirectHTTPServer.enableCloseOnExec(
            42,
            getFlags: { _ in FD_CLOEXEC },
            setFlags: { _, _ in setterCalled = true; return -1 }
        ))
        XCTAssertFalse(setterCalled)
    }

    private func spawnSleeper() -> pid_t {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("60"), nil]
        defer { argv.dropLast().forEach { free($0) } }
        let rc = posix_spawn(&pid, "/bin/sleep", nil, nil, &argv, nil)
        XCTAssertEqual(rc, 0, "posix_spawn must start the child sleeper")
        return pid
    }

    private func canBindLoopback(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        return rc == 0
    }

    @MainActor
    func test_childSpawnedWhileServerRuns_doesNotPinPortAfterStop() throws {
        let port = try availableLoopbackPort()
        let s = DirectHTTPServer(port: port, loopbackOnly: true,
                                 dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                                 auth: nil, bootEpoch: 1)
        try s.start()

        let child = spawnSleeper()
        defer { kill(child, SIGKILL); var st: Int32 = 0; waitpid(child, &st, 0) }

        s.stop()
        XCTAssertTrue(canBindLoopback(port: port),
                      "port must be rebindable after stop even while an app-spawned child is alive — the listener fd must be close-on-exec")
    }

    @MainActor
    func test_childSpawnedWhileClientIsConnected_doesNotPinAcceptedSocketAfterStop() throws {
        // WHY: the accepted descriptor needs the same inheritance fence as the
        // listener. Otherwise a terminal child keeps an idle iOS connection
        // alive after RemoteCode stops even though the app closed its own copy.
        let port = try availableLoopbackPort()
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            auth: nil,
            bootEpoch: 1
        )
        let acceptedDescriptor = LockedHTTPDescriptor()
        let acceptedReady = DispatchSemaphore(value: 0)
        server.acceptedFDObserverForTesting = { descriptor in
            acceptedDescriptor.value = descriptor
            acceptedReady.signal()
        }
        try server.start()
        let client = try connectLoopback(port: port)
        defer { close(client) }

        XCTAssertEqual(acceptedReady.wait(timeout: .now() + 2), .success)
        let acceptedDeadline = Date().addingTimeInterval(2)
        while Date() < acceptedDeadline, server.acceptedSocketCountForTests == 0 {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(server.acceptedSocketCountForTests, 1)

        let child = spawnSleeper()
        defer { kill(child, SIGKILL); var status: Int32 = 0; waitpid(child, &status, 0) }
        let acceptedFD = try XCTUnwrap(acceptedDescriptor.value)
        let childDescriptors = fileDescriptors(of: child)
        XCTAssertFalse(childDescriptors.isEmpty,
                       "the child descriptor table must be observable for this proof")
        XCTAssertFalse(
            childDescriptors.contains {
                $0.proc_fd == acceptedFD && $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET)
            },
            "the exec'd child must not inherit the accepted HTTP socket"
        )

        server.stop()
        XCTAssertTrue(
            waitForEOF(fd: client, timeout: 2),
            "the app's accepted socket must disappear after stop even while an app-spawned child remains alive"
        )
    }

    private func availableLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        return UInt16(bigEndian: addr.sin_port)
    }

    private func fileDescriptors(of pid: pid_t) -> [proc_fdinfo] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: (Int(needed) + stride - 1) / stride
        )
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, needed)
        guard written > 0 else { return [] }
        return Array(descriptors.prefix(Int(written) / stride))
    }

    private func connectLoopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let savedErrno = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
        }
        return fd
    }

    private func waitForEOF(fd: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var byte: UInt8 = 0
        while Date() < deadline {
            let count = recv(fd, &byte, 1, MSG_DONTWAIT)
            if count == 0 { return true }
            if count < 0, errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }
}

private final class LockedHTTPDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int32?

    var value: Int32? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock(); storage = newValue; lock.unlock()
        }
    }
}
