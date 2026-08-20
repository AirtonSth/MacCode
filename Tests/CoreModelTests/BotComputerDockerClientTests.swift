import XCTest
@testable import CoreModel

final class BotComputerDockerClientTests: XCTestCase {
    func test_runProcessReturnsOutputLargerThanPipeCapacity() throws {
        // WHY: a real guest PNG is often larger than the OS pipe capacity, so
        // the runner must consume all bytes while the child is still writing.
        let expected = Data(repeating: 0x41, count: 1_048_576)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-docker-output-\(UUID().uuidString)")
        try expected.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try BotComputerDockerCLI.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [file.path]
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.data, expected)
    }

    func test_defaultRunDrainsStdoutBeforeWaitingForExit() throws {
        // WHY: guest screenshots can exceed a pipe buffer. Waiting for Docker
        // before reading stdout deadlocks the child writer and freezes its caller.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/CoreModel/BotComputerDockerClient.swift"),
            encoding: .utf8
        )
        let read = try XCTUnwrap(source.range(of: "readDataToEndOfFile()"))
        let wait = try XCTUnwrap(source.range(of: "process.waitUntilExit()"))

        XCTAssertLessThan(read.lowerBound, wait.lowerBound)
        XCTAssertTrue(source.contains("process.standardError = FileHandle.nullDevice"))
    }
}
