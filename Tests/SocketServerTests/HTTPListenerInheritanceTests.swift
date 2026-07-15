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
        let port = UInt16.random(in: 33000...44000)
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
}
