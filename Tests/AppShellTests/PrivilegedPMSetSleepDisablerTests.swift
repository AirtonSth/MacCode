import XCTest
@testable import AppShell

private struct PMSetRequest: Equatable {
    let disabled: Bool
    let watchProcessID: Int32?
    let stopFile: URL?
    let sessionDirectory: URL?
}

final class PrivilegedPMSetSleepDisablerTests: XCTestCase {
    func test_disablingAfterPrivilegedEnableUsesCachedHelperWithoutSecondPasswordPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2PMSetCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var requests: [PMSetRequest] = []
        var sleepDisabled = false
        let disabler = PrivilegedPMSetSleepDisabler(
            processIdentifier: 12345,
            makeSessionDirectory: { directory },
            runPrivilegedPMSet: { disabled, watchProcessID, stopFile, sessionDirectory in
                requests.append(PMSetRequest(
                    disabled: disabled,
                    watchProcessID: watchProcessID,
                    stopFile: stopFile,
                    sessionDirectory: sessionDirectory
                ))
                sleepDisabled = disabled
                return true
            },
            rootDomainSleepDisabled: { sleepDisabled }
        )

        XCTAssertTrue(disabler.setDisabled(true),
                      "enabling closed-display Insomnia must succeed through the one-time helper request")
        XCTAssertEqual(requests.count, 1,
                       "one enable must make exactly one privileged helper request")
        let enableRequest = try XCTUnwrap(requests.first,
                                          "the successful enable must leave an inspectable helper request")
        XCTAssertTrue(enableRequest.disabled,
                      "the enable request must ask the helper to set disablesleep")
        XCTAssertEqual(enableRequest.watchProcessID, 12345,
                       "the helper must watch the app process so a crash restores sleep")
        XCTAssertEqual(enableRequest.stopFile, directory.appendingPathComponent("disable"),
                       "the helper must watch the stop file used by normal disable")
        XCTAssertEqual(enableRequest.sessionDirectory, directory,
                       "the helper must own the session directory for crash-safe cleanup")

        XCTAssertTrue(disabler.disableUsingCachedPermission(),
                      "turning Insomnia off after that grant must signal the already-authorized helper")
        XCTAssertEqual(requests.count, 1,
                       "cached disable must not issue a second privileged helper request")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("disable").path),
                      "cached disable must release the watcher through its local stop file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["disable"],
                       "the cached session must persist only a stop signal and never password-bearing state")
    }

    func test_disablingWithoutCachedHelperFallsBackToOneShotPrivilegedPMSet() throws {
        var requests: [PMSetRequest] = []
        let disabler = PrivilegedPMSetSleepDisabler(
            processIdentifier: 12345,
            runPrivilegedPMSet: { disabled, watchProcessID, stopFile, sessionDirectory in
                requests.append(PMSetRequest(
                    disabled: disabled,
                    watchProcessID: watchProcessID,
                    stopFile: stopFile,
                    sessionDirectory: sessionDirectory
                ))
                return true
            },
            rootDomainSleepDisabled: { false }
        )

        XCTAssertFalse(disabler.disableUsingCachedPermission(),
                       "without a prior privileged enable there is no cached helper to reuse")
        XCTAssertTrue(disabler.setDisabled(false),
                      "legacy or externally-enabled disablesleep must use the one-shot helper fallback")
        XCTAssertEqual(requests.count, 1,
                       "the fallback reset must make one helper request after cached disable is unavailable")
        let disableRequest = try XCTUnwrap(requests.first,
                                           "the fallback reset must leave an inspectable helper request")
        XCTAssertFalse(disableRequest.disabled,
                       "the fallback helper request must restore disablesleep to zero")
        XCTAssertNil(disableRequest.watchProcessID,
                     "a one-shot reset must not start a process watcher")
        XCTAssertNil(disableRequest.stopFile,
                     "a one-shot reset must not depend on cached stop-file state")
        XCTAssertNil(disableRequest.sessionDirectory,
                     "a one-shot reset must not persist a watcher session")
    }
}
