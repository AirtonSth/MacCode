import XCTest
import Darwin
@testable import Persistence

final class TerminalHistoryFailureLedgerFDInheritanceTests: XCTestCase {
    func test_closeOnExecSetupPreservesFlagsAndFailsClosed() {
        // WHY: every ledger open must abort if either descriptor flag read or
        // installation fails; continuing would leak that fd into future execs.
        var installedFlags: Int32?
        XCTAssertTrue(TerminalHistoryFileDescriptorFlags.enableCloseOnExec(
            42,
            getFlags: { _ in 0x40 },
            setFlags: { _, flags in installedFlags = flags; return 0 }
        ))
        XCTAssertEqual(installedFlags, 0x40 | FD_CLOEXEC)

        XCTAssertFalse(TerminalHistoryFileDescriptorFlags.enableCloseOnExec(
            42,
            getFlags: { _ in -1 },
            setFlags: { _, _ in XCTFail("setter must not run after F_GETFD fails"); return 0 }
        ))
        XCTAssertFalse(TerminalHistoryFileDescriptorFlags.enableCloseOnExec(
            42,
            getFlags: { _ in 0 },
            setFlags: { _, _ in -1 }
        ))

        var setterCalled = false
        XCTAssertTrue(TerminalHistoryFileDescriptorFlags.enableCloseOnExec(
            42,
            getFlags: { _ in FD_CLOEXEC },
            setFlags: { _, _ in setterCalled = true; return -1 }
        ))
        XCTAssertFalse(setterCalled)
    }

    func test_lockTemporaryAndDirectoryDescriptorsDoNotSurviveExec() throws {
        // WHY: RemoteCode spawns long-lived terminal children while failure
        // anchors are updated. An inherited lock, temp-file, or directory fd
        // can pin deleted sidecars and retain storage for the child's lifetime.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "RC2TerminalLedgerFD-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try SQLiteDB(path: directory.appendingPathComponent("remote-code.sqlite").path)
        try Schema.migrate(database)
        let probe = TerminalHistoryLedgerDescriptorProbe()
        let repository = TerminalOutputRepository(
            db: database,
            terminalHistoryFailureLedgerRootForTesting: directory.appendingPathComponent("ledger"),
            descriptorOpenedForTesting: { kind, descriptor in
                probe.capture(kind: kind, descriptor: descriptor)
            }
        )

        try repository.recordFailureAnchor(
            surfaceID: UUID().uuidString,
            writerGeneration: UUID().uuidString,
            reason: "fd_inheritance_regression",
            minimumNextChunkIndex: 2
        )

        XCTAssertEqual(probe.spawnErrors, [], "every raw posix_spawn probe must execute")
        XCTAssertEqual(Set(probe.observedKinds), Set(["lock", "temp", "directory"]))
        XCTAssertEqual(
            probe.inheritedKinds,
            [],
            "no failure-ledger descriptor may remain open in an exec'd terminal child"
        )
    }
}

private final class TerminalHistoryLedgerDescriptorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [(kind: String, inherited: Bool)] = []
    private var errors: [Int32] = []

    var observedKinds: [String] {
        lock.lock(); defer { lock.unlock() }
        return observations.map(\.kind)
    }

    var inheritedKinds: [String] {
        lock.lock(); defer { lock.unlock() }
        return observations.filter(\.inherited).map(\.kind)
    }

    var spawnErrors: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return errors
    }

    func capture(kind: String, descriptor: Int32) {
        var processID: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sleep"),
            strdup("60"),
            nil
        ]
        defer { arguments.dropLast().forEach { free($0) } }
        let result = posix_spawn(&processID, "/bin/sleep", nil, nil, &arguments, nil)
        guard result == 0 else {
            lock.lock(); errors.append(result); lock.unlock()
            return
        }
        defer {
            kill(processID, SIGKILL)
            var status: Int32 = 0
            waitpid(processID, &status, 0)
        }

        let inherited = fileDescriptors(of: processID).contains { $0.proc_fd == descriptor }
        lock.lock()
        observations.append((kind, inherited))
        lock.unlock()
    }

    private func fileDescriptors(of processID: pid_t) -> [proc_fdinfo] {
        let needed = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: (Int(needed) + stride - 1) / stride
        )
        let written = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, &descriptors, needed)
        guard written > 0 else { return [] }
        return Array(descriptors.prefix(Int(written) / stride))
    }
}
