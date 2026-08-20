import XCTest
import CoreModel

final class BotDesktopChildEnvironmentTests: XCTestCase {
    func test_dockerDesktopStubsHarnessAndHidesDocker() throws {
        // WHY: a dockerDesktop child must not drive this Mac via macos-harness
        // or talk to the host Docker socket.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-desktop-stub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = BotDesktopChildEnvironment.apply(
            kind: .dockerDesktop,
            env: [
                "PATH": "/usr/local/bin:/usr/bin",
                "DOCKER_HOST": "unix:///var/run/docker.sock",
                "DOCKER_CONTEXT": "desktop-linux",
            ],
            stubDirectory: root
        )
        XCTAssertNil(env["DOCKER_HOST"])
        XCTAssertNil(env["DOCKER_CONTEXT"])
        let path = try XCTUnwrap(env["PATH"])
        XCTAssertTrue(path.hasPrefix(root.path + ":"))
        let harness = root.appendingPathComponent("macos-harness")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: harness.path))
        let docker = root.appendingPathComponent("docker")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: docker.path))

        let harnessOut = try run(harness)
        XCTAssertEqual(harnessOut.status, 1)
        XCTAssertTrue(harnessOut.err.contains("bot_computer_observe"))
        let dockerOut = try run(docker)
        XCTAssertEqual(dockerOut.status, 127)
        XCTAssertTrue(dockerOut.err.contains("not available"))
    }

    func test_thisMacKindsLeaveHostPathAlone() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-desktop-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in [BotDesktopKind.logicalExecutionSpace, .botOwnedBrowser, .dedicatedLocalVM] {
            let env = BotDesktopChildEnvironment.apply(
                kind: kind,
                env: ["PATH": "/usr/bin", "DOCKER_HOST": "unix:///var/run/docker.sock"],
                stubDirectory: root
            )
            XCTAssertEqual(env["PATH"], "/usr/bin", kind.rawValue)
            XCTAssertEqual(env["DOCKER_HOST"], "unix:///var/run/docker.sock", kind.rawValue)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("docker").path))
        }
    }

    private func run(_ url: URL) throws -> (status: Int32, err: String) {
        let process = Process()
        process.executableURL = url
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
