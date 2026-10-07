import Darwin
import XCTest
@testable import AppLifecycleSupport

/// S-F8: one RemoteCode process per App Support directory.
final class AppInstanceLockTests: XCTestCase {
    private func makeDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2InstanceLock-" + UUID().uuidString, isDirectory: true)
    }

    private func acquireOrFail(_ dir: URL, file: StaticString = #filePath, line: UInt = #line) -> AppInstanceLock? {
        guard case .acquired(let lock) = AppInstanceLock.acquire(directory: dir) else {
            XCTFail("expected to acquire the instance lock", file: file, line: line)
            return nil
        }
        return lock
    }

    /// Exit status of `lockf -t 0 <lock file> true` in a separate process:
    /// 0 when another process could take the lock, 75 when it is held.
    private func otherProcessLockStatus(_ dir: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-t", "0", dir.appendingPathComponent(AppInstanceLock.fileName).path, "/usr/bin/true"]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func test_secondInstanceOnSameAppSupportIsRefusedAndLearnsTheHolder() {
        let dir = makeDirectory()
        let first = acquireOrFail(dir)
        XCTAssertNotNil(first)

        guard case .heldByOther(let holder) = AppInstanceLock.acquire(directory: dir) else {
            return XCTFail("a second instance on the same App Support must be refused so it cannot share the database, port and run marker")
        }
        XCTAssertEqual(holder, getpid(), "the refused instance must learn the holder's pid so it can activate the running app instead")
        withExtendedLifetime(first) {}
    }

    func test_lockIsVisibleToOtherProcessesAndReleasedWhenTheHolderGoesAway() throws {
        let dir = makeDirectory()
        var lock = acquireOrFail(dir)
        XCTAssertEqual(try otherProcessLockStatus(dir), 75, "another process must see the lock as held while the app runs")

        lock = nil
        XCTAssertNil(lock)
        XCTAssertEqual(try otherProcessLockStatus(dir), 0, "the kernel must drop the lock with its holder so a relaunch after a crash is never blocked")
        XCTAssertNotNil(acquireOrFail(dir))
    }

    func test_childProcessesDoNotInheritTheLock() throws {
        // Terminals and providers outlive the app; if they inherited the fd the
        // next launch would be refused as a "second instance" of a dead app.
        let dir = makeDirectory()
        var lock = acquireOrFail(dir)

        var child: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&child, "/bin/sleep", nil, nil, argv, environ), 0)
        defer {
            kill(child, SIGKILL)
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }

        lock = nil
        XCTAssertNil(lock)
        XCTAssertEqual(try otherProcessLockStatus(dir), 0, "a child spawned while the lock was held must not keep it after the app releases it")
    }

    func test_separateAppSupportDirectoriesDoNotContend() {
        // The isolated sandbox runs with its own RC2_APP_SUPPORT, so it must
        // never be refused because the user's app is running (and vice versa).
        let userApp = acquireOrFail(makeDirectory())
        let sandbox = acquireOrFail(makeDirectory())
        XCTAssertNotNil(userApp)
        XCTAssertNotNil(sandbox)
    }
}
