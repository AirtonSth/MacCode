import XCTest
import CoreModel
@testable import AppShell

@MainActor
final class BotComputerBootDockerTests: XCTestCase {
    func test_ownedImageProvisionsCapturesScreenAndResumes() throws {
        guard let image = ProcessInfo.processInfo.environment["RC_MACCODE_BOOT_PROBE_IMAGE"] else {
            throw XCTSkip("Set RC_MACCODE_BOOT_PROBE_IMAGE to a separately built guest image")
        }
        // Keep the installed app's image tag and runtime completely untouched.
        let docker = BotComputerDockerCLI { args in
            try BotComputerDockerCLI.defaultRun(args.map { $0 == BotComputerGuestSpec.imageTag ? image : $0 })
        }
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccode-boot-probe-\(UUID().uuidString)", isDirectory: true)
        let bot = BotID()
        let service = BotComputerGuestService(appSupport: support, docker: docker)
        defer {
            do {
                try service.removeGuestRuntime(botID: bot)
                try FileManager.default.removeItem(at: support)
            } catch { XCTFail("Owned boot probe cleanup failed: \(error)") }
        }
        let ready = try service.provision(botID: bot)
        XCTAssertFalse(ready.resumed)
        XCTAssertTrue(ready.capturedPNG.starts(with: [0x89, 0x50, 0x4e, 0x47]))
        XCTAssertTrue(service.isContainerRunning(botID: bot))
        try service.stop(botID: bot)
        let resumed = try service.provision(botID: bot)
        XCTAssertTrue(resumed.resumed)
        XCTAssertEqual(resumed.containerID, ready.containerID)

        // Docker routes a non-TTY container's stderr through its own stderr.
        // Successful `logs` must preserve that stream as well as stdout.
        _ = try docker.exec(name: ready.containerID,
                            command: ["/bin/sh", "-c", "printf boot-probe-stderr > /proc/1/fd/2"],
                            user: nil, detach: false)
        XCTAssertTrue(try docker.logs(name: ready.containerID, tailLines: 40).contains("boot-probe-stderr"))
    }
}
