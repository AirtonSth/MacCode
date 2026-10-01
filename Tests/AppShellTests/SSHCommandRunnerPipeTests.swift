import XCTest
@testable import AppShell

final class SSHCommandRunnerPipeTests: XCTestCase {
    func test_largeMergedOutputCompletes_becauseWaitingBeforeDrainingDeadlocksOnAFullPipe() throws {
        // WHY: ssh/scp share one stdout+stderr pipe. Waiting for exit before reading
        // blocks forever once the child writes more than the 64 KiB pipe buffer.
        let finished = expectation(description: "runner returns")
        var result: (exitCode: Int32, output: String)?
        var thrown: Error?
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                result = try AppCommandRouter.runCommandBlocking(
                    executable: "/bin/sh",
                    arguments: ["-c", "head -c 1000000 /dev/zero | tr '\\0' a; echo done >&2"],
                    password: nil
                )
            } catch {
                thrown = error
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 15)
        XCTAssertNil(thrown)
        XCTAssertEqual(result?.exitCode, 0)
        XCTAssertEqual(result?.output.filter { $0 == "a" }.count, 1_000_000)
        XCTAssertTrue(result?.output.hasSuffix("done\n") ?? false)
    }
}
