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

    func test_runtimeGetsOnlySelectedBotsSecretValues() throws {
        let secretStore = InMemoryBotSecretStore()
        let botID = BotID(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
        let otherBotID = BotID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        try secretStore.save(botID: botID, name: "SERVICE_TOKEN", value: "fixture-runtime-value")
        try secretStore.save(botID: otherBotID, name: "OTHER_TOKEN", value: "fixture-other-value")

        let env = try BotSecretEnvironment.applying(
            to: [
                BotSecretEnvironment.botIDEnvironmentKey: botID.value.uuidString,
                "PATH": "/usr/bin",
            ],
            store: secretStore
        )
        XCTAssertEqual(env["SERVICE_TOKEN"], "fixture-runtime-value")
        XCTAssertNil(env["OTHER_TOKEN"])
        XCTAssertEqual(env[BotSecretEnvironment.botIDEnvironmentKey], botID.value.uuidString)
        XCTAssertEqual(env[BotSecretEnvironment.secretNamesEnvironmentKey], "SERVICE_TOKEN")
    }

    func test_inheritedBotSecretsAreRemovedBeforeApplyingNextBot() throws {
        let secretStore = InMemoryBotSecretStore()
        let firstBotID = BotID(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
        let secondBotID = BotID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        try secretStore.save(botID: firstBotID, name: "FIRST_TOKEN", value: "first-value")
        try secretStore.save(botID: secondBotID, name: "SECOND_TOKEN", value: "second-value")

        let firstEnvironment = try BotSecretEnvironment.applying(
            to: [
                BotSecretEnvironment.botIDEnvironmentKey: firstBotID.value.uuidString,
                "PATH": "/usr/bin",
            ],
            store: secretStore
        )
        let secondEnvironment = try BotSecretEnvironment.applying(
            to: firstEnvironment.merging([
                BotSecretEnvironment.botIDEnvironmentKey: secondBotID.value.uuidString,
                BotSecretEnvironment.secretNamesEnvironmentKey:
                    "RC_TOKEN_SAVER_THREAD_ID,FIRST_TOKEN",
                "RC_TOKEN_SAVER_THREAD_ID": "keep-control-value",
            ]) { _, current in current },
            store: secretStore
        )

        XCTAssertNil(secondEnvironment["FIRST_TOKEN"])
        XCTAssertEqual(secondEnvironment["SECOND_TOKEN"], "second-value")
        XCTAssertEqual(secondEnvironment["RC_TOKEN_SAVER_THREAD_ID"], "keep-control-value")
        XCTAssertEqual(secondEnvironment[BotSecretEnvironment.secretNamesEnvironmentKey], "SECOND_TOKEN")

        try secretStore.delete(botID: secondBotID, name: "SECOND_TOKEN")
        let emptyEnvironment = try BotSecretEnvironment.applying(to: secondEnvironment, store: secretStore)
        XCTAssertNil(emptyEnvironment["FIRST_TOKEN"])
        XCTAssertNil(emptyEnvironment["SECOND_TOKEN"])
        XCTAssertEqual(emptyEnvironment[BotSecretEnvironment.secretNamesEnvironmentKey], "")
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
