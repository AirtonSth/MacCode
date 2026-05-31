import XCTest
@testable import AppShell

final class PrivilegedPMSetSleepDisablerTests: XCTestCase {
    func test_disablingAfterPrivilegedEnableUsesCachedHelperWithoutSecondPasswordPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2PMSetCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var commands: [String] = []
        var sleepDisabled = false
        let disabler = PrivilegedPMSetSleepDisabler(
            processIdentifier: 12345,
            makeSessionDirectory: { directory },
            runPrivilegedShellCommand: { command in
                commands.append(command)
                sleepDisabled = command.contains("disablesleep 1")
                return true
            },
            rootDomainSleepDisabled: { sleepDisabled }
        )

        XCTAssertTrue(disabler.setDisabled(true),
                      "enabling closed-display Insomnia may ask once for admin permission when pmset fallback is required")
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].contains("/usr/bin/pmset -a disablesleep 1"))

        XCTAssertTrue(disabler.disableUsingCachedPermission(),
                      "turning Insomnia off after that grant must reuse the cached helper instead of prompting again")
        XCTAssertEqual(commands.count, 1,
                       "disabling with a cached helper must not invoke another privileged AppleScript command")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("disable").path),
                      "the cached helper is released by a local stop file that the already-authorized process handles")
    }

    func test_disablingWithoutCachedHelperFallsBackToOneShotPrivilegedPMSet() {
        var commands: [String] = []
        let disabler = PrivilegedPMSetSleepDisabler(
            processIdentifier: 12345,
            runPrivilegedShellCommand: { command in
                commands.append(command)
                return true
            },
            rootDomainSleepDisabled: { false }
        )

        XCTAssertFalse(disabler.disableUsingCachedPermission(),
                       "without a prior privileged enable there is no cached helper to reuse")
        XCTAssertTrue(disabler.setDisabled(false),
                      "legacy or externally-enabled disablesleep still needs the one-shot privileged fallback")
        XCTAssertEqual(commands, ["/usr/bin/pmset -a disablesleep 0"])
    }
}
