import XCTest
@testable import AppShell

final class ComputerUsePermissionBrokerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ComputerUsePermissionBroker.resetForTesting()
    }

    func test_requestsOnlyMissingPermissionsAndOnlyOncePerProcess() {
        // WHY: the app never asked for Screen Recording / Accessibility, so its
        // current code identity was never registered with TCC — helpers spawned
        // by the providers inherit the app's grant and reported false even with
        // "RemoteCode" toggled on for an older build. Ask from the app, once.
        var screen = false
        var ax = true
        var screenRequests = 0
        var axRequests = 0
        let requesters = ComputerUsePermissionBroker.Requesters(
            preflightScreenCapture: { screen },
            requestScreenCapture: { screenRequests += 1; screen = true; return true },
            accessibilityTrusted: { ax },
            requestAccessibility: { axRequests += 1; return true }
        )
        let after = ComputerUsePermissionBroker.requestOnceIfMissing(using: requesters)
        XCTAssertEqual(screenRequests, 1, "only the missing permission is requested")
        XCTAssertEqual(axRequests, 0)
        XCTAssertTrue(after.allGranted)

        screen = false
        _ = ComputerUsePermissionBroker.requestOnceIfMissing(using: requesters)
        XCTAssertEqual(screenRequests, 1, "the system prompt must not re-appear on every admitted run")
    }

    func test_nothingRequestedWhenBothPermissionsHold() {
        var requests = 0
        let requesters = ComputerUsePermissionBroker.Requesters(
            preflightScreenCapture: { true },
            requestScreenCapture: { requests += 1; return true },
            accessibilityTrusted: { true },
            requestAccessibility: { requests += 1; return true }
        )
        XCTAssertTrue(ComputerUsePermissionBroker.requestOnceIfMissing(using: requesters).allGranted)
        XCTAssertEqual(requests, 0)
    }
}
