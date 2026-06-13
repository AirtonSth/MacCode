import XCTest
@testable import AgentRuntime

/// QA-mac:52 -- crash-safety harness for closed-pipe writes (T039).
///
/// `classify` is unit-tested in GuardedStdinWriteTests; this drives the actual
/// `write(_:to:process:notFound:)` syscall path against a REAL child process whose
/// stdin pipe has been closed (the child killed), asserting it throws the typed
/// "session gone" error instead of crashing the host via an uncatchable
/// FileHandle exception or SIGPIPE. Uses /bin/cat -- a universally-available
/// system binary -- so the test needs no fixtures.
final class GuardedStdinWriteClosedPipeTests: XCTestCase {

    private enum TestSessionGone: Error, Equatable { case gone }

    override func setUp() {
        super.setUp()
        // The production CLI ignores SIGPIPE (RC2CLI/main.swift); mirror that here so
        // the raw write(2) to a closed pipe returns EPIPE for classify() to handle,
        // rather than delivering SIGPIPE to the test runner.
        signal(SIGPIPE, SIG_IGN)
    }

    func test_writeToDeadProcessThrowsInsteadOfCrashing() throws {
        let cat = Process()
        cat.executableURL = URL(fileURLWithPath: "/bin/cat")
        let stdin = Pipe()
        let stdout = Pipe()
        cat.standardInput = stdin
        cat.standardOutput = stdout
        try cat.run()

        // Kill the child and wait so its stdin read end is gone.
        cat.terminate()
        cat.waitUntilExit()
        XCTAssertFalse(cat.isRunning, "precondition: the child must be dead before the guarded write")

        // The guarded write must THROW our typed error, never crash the process.
        XCTAssertThrowsError(
            try GuardedStdinWrite.write(Data("hello\n".utf8),
                                        to: stdin.fileHandleForWriting,
                                        process: cat,
                                        notFound: { TestSessionGone.gone })
        ) { error in
            XCTAssertEqual(error as? TestSessionGone, .gone,
                "writing to a dead process's stdin must surface the typed session-gone error")
        }
    }

    func test_writeToClosedReadEndThrowsEPIPEInsteadOfCrashing() throws {
        // Spawn /bin/cat, then close ITS stdout/our read end and kill it so a write
        // to the still-open write fd hits EPIPE. process.isRunning is re-checked
        // inside write(); after termination it returns sessionNotFound. This proves
        // the closed-pipe write path is crash-safe end to end.
        let cat = Process()
        cat.executableURL = URL(fileURLWithPath: "/bin/cat")
        let stdin = Pipe()
        cat.standardInput = stdin
        try cat.run()
        cat.terminate()
        cat.waitUntilExit()

        // A large payload (multiple write loops) must still terminate by throwing,
        // never hang or crash.
        let big = Data(String(repeating: "x", count: 1_000_000).utf8)
        XCTAssertThrowsError(
            try GuardedStdinWrite.write(big,
                                        to: stdin.fileHandleForWriting,
                                        process: cat,
                                        notFound: { TestSessionGone.gone })
        ) { error in
            XCTAssertEqual(error as? TestSessionGone, .gone,
                "a large write to a closed pipe must throw, not busy-loop or crash")
        }
    }
}
