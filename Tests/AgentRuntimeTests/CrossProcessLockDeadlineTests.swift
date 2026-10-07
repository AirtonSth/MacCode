import XCTest
import Darwin
@testable import Persistence
@testable import AgentRuntime

/// Holds an exclusive BSD lock on `path` from another process for up to
/// `seconds`, like a stuck or suspended Distill sidecar. On macOS a `flock`
/// lock also blocks `fcntl` record locks on the same file, so this exercises
/// both lock styles across processes (record locks never conflict in-process).
final class CrossProcessFileLockHolder {
    private let process = Process()

    init(path: String, seconds: Int = 30) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The shell opens fd 9, lockf(1) locks that open file and exits, and
        // `exec sleep` keeps the locked fd open until the process is killed.
        process.arguments = [
            "-c", "exec 9>>\"$0\"; /usr/bin/lockf -s 9 && exec /bin/sleep \"$1\"",
            path, String(seconds),
        ]
        try process.run()
        let probe = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard probe >= 0 else { throw POSIXError(.EIO) }
        defer { close(probe) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if flock(probe, LOCK_EX | LOCK_NB) == 0 {
                _ = flock(probe, LOCK_UN)
                usleep(10_000)
                continue
            }
            return
        }
        release()
        throw POSIXError(.ETIMEDOUT)
    }

    func release() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    deinit { release() }
}

final class CrossProcessLockDeadlineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-lock-deadline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openLockFile(_ name: String) throws -> Int32 {
        let fd = open(root.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        return fd
    }

    private func elapsed(_ body: () throws -> Void) rethrows -> TimeInterval {
        let start = Date()
        try body()
        return Date().timeIntervalSince(start)
    }

    // MARK: BoundedFileLock

    func test_uncontendedLockIsAcquiredWithoutWaiting() throws {
        // WHY: the bound must not tax the common case; one attempt, no sleep.
        for style in [BoundedFileLock.Style.posixRecord, .flock] {
            let fd = try openLockFile("free-\(style.rawValue).lock")
            defer { close(fd) }
            var outcome: BoundedFileLock.Outcome?
            let time = elapsed {
                outcome = BoundedFileLock.acquireExclusive(
                    descriptor: fd, style: style, label: "test", onTimeout: .fail
                )
            }
            XCTAssertEqual(outcome, .acquired)
            XCTAssertLessThan(time, 0.1)
            BoundedFileLock.unlock(descriptor: fd, style: style)
        }
    }

    func test_lockHeldByAnotherProcessTimesOutAfterAboutTwoSeconds() throws {
        // WHY (S-F7): F_SETLKW / flock(LOCK_EX) waited forever on a stuck peer,
        // a plausible cause of hangs that never end. The wait is now 2 s.
        for style in [BoundedFileLock.Style.posixRecord, .flock] {
            let name = "held-\(style.rawValue).lock"
            let holder = try CrossProcessFileLockHolder(path: root.appendingPathComponent(name).path)
            defer { holder.release() }
            let fd = try openLockFile(name)
            defer { close(fd) }
            var outcome: BoundedFileLock.Outcome?
            let time = elapsed {
                outcome = BoundedFileLock.acquireExclusive(
                    descriptor: fd, style: style, label: "test", onTimeout: .failOpen
                )
            }
            guard case .timedOut(let waited) = outcome else {
                return XCTFail("\(style): expected timeout, got \(String(describing: outcome))")
            }
            XCTAssertGreaterThanOrEqual(waited, 1_900)
            XCTAssertGreaterThanOrEqual(time, 1.9)
            XCTAssertLessThan(time, 3.0, "\(style) must not wait for the 30 s holder")
        }
    }

    func test_waiterAcquiresAsSoonAsThePeerReleases() throws {
        // WHY: bounding the wait must not turn ordinary short contention into
        // a failure; a peer that finishes inside the deadline still hands over.
        let name = "handoff.lock"
        let holder = try CrossProcessFileLockHolder(path: root.appendingPathComponent(name).path)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { holder.release() }
        let fd = try openLockFile(name)
        defer { close(fd) }
        var outcome: BoundedFileLock.Outcome?
        let time = elapsed {
            outcome = BoundedFileLock.acquireExclusive(
                descriptor: fd, style: .posixRecord, label: "test", onTimeout: .fail
            )
        }
        XCTAssertEqual(outcome, .acquired)
        XCTAssertGreaterThanOrEqual(time, 0.4)
        XCTAssertLessThan(time, 1.9)
    }

    func test_lockErrorOtherThanContentionFailsImmediately() {
        // WHY: a bad descriptor is not contention; retrying it for 2 s would
        // only delay the error the caller already reports.
        var outcome: BoundedFileLock.Outcome?
        let time = elapsed {
            outcome = BoundedFileLock.acquireExclusive(
                descriptor: -1, style: .posixRecord, label: "test", onTimeout: .fail
            )
        }
        XCTAssertEqual(outcome, .failed(errno: EBADF))
        XCTAssertLessThan(time, 0.1)
    }

    // MARK: Call sites

    func test_providerOwnershipLedgerFailsBoundedAndUnchangedWhilePeerHoldsLock() throws {
        // WHY: a spawn or sweep must not hang behind a stuck peer, and it must
        // not write the ledger unlocked either: a lost ownership row leaves a
        // provider uncertified for crash cleanup, so the spawn fails instead.
        let file = root.appendingPathComponent("provider-tags.json")
        let store = ProviderProcessOwnershipStore(fileURL: file)
        let first = SpawnedProcessTag(
            pgid: 41, spawnedAt: Date(timeIntervalSince1970: 1), managedKind: .sidecar,
            startIdentity: ProviderProcessStartIdentity(seconds: 1, microseconds: 1)
        )
        let second = SpawnedProcessTag(
            pgid: 42, spawnedAt: Date(timeIntervalSince1970: 2), managedKind: .sidecar,
            startIdentity: ProviderProcessStartIdentity(seconds: 2, microseconds: 1)
        )
        try store.replace([first])

        let holder = try CrossProcessFileLockHolder(
            path: file.deletingPathExtension().appendingPathExtension("lock").path
        )
        var thrown: Error?
        let time = elapsed {
            do { try store.append(second) } catch { thrown = error }
        }
        XCTAssertEqual(
            thrown as? ProviderProcessOwnershipError,
            .processListFailed("ownership lock acquire timed out")
        )
        XCTAssertGreaterThanOrEqual(time, 1.9)
        XCTAssertLessThan(time, 3.0)
        XCTAssertEqual(try store.load(), [first], "a timed-out append must not touch the ledger")

        holder.release()
        try store.append(second)
        XCTAssertEqual(try store.load(), [first, second])
    }

    func test_terminalHistoryFailureLedgerFailsBoundedWhilePeerHoldsLock() throws {
        // WHY: terminal history must not hang behind a stuck peer. The anchors
        // have no other cross-process guard, so the write errors rather than
        // merging unlocked, and succeeds again once the peer lets go.
        let database = try SQLiteDB(path: root.appendingPathComponent("remote-code.sqlite").path)
        try Schema.migrate(database)
        let ledgerRoot = root.appendingPathComponent("ledger", isDirectory: true)
        let repository = TerminalOutputRepository(
            db: database,
            terminalHistoryFailureLedgerRootForTesting: ledgerRoot,
            descriptorOpenedForTesting: nil
        )
        let surfaceID = UUID().uuidString
        let generation = UUID().uuidString
        try FileManager.default.createDirectory(at: ledgerRoot, withIntermediateDirectories: true)

        let holder = try CrossProcessFileLockHolder(path: ledgerRoot.appendingPathComponent(".lock").path)
        var thrown: NSError?
        let time = elapsed {
            do {
                try repository.recordFailureAnchor(
                    surfaceID: surfaceID, writerGeneration: generation,
                    reason: "test", minimumNextChunkIndex: 1
                )
            } catch { thrown = error as NSError }
        }
        XCTAssertEqual(thrown?.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(thrown?.code, Int(ETIMEDOUT))
        XCTAssertGreaterThanOrEqual(time, 1.9)
        XCTAssertLessThan(time, 3.0)

        holder.release()
        try repository.recordFailureAnchor(
            surfaceID: surfaceID, writerGeneration: generation,
            reason: "test", minimumNextChunkIndex: 1
        )
        XCTAssertEqual(try repository.failureAnchors(surfaceID: surfaceID).count, 1)
    }
}
