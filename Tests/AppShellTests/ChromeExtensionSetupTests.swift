import XCTest
@testable import AppShell

@MainActor
final class ChromeExtensionSetupTests: XCTestCase {
    func testSetupShowsProgressAndRequiresARealConnectionBeforeReportingConnected() async {
        let started = expectation(description: "preparation started")
        let gate = ChromeSetupGate<URL>()
        let folder = URL(fileURLWithPath: "/test/extension")
        var opened: [URL] = []
        let setup = ChromeExtensionSetup(
            prepare: { started.fulfill(); return await gate.wait() },
            connected: { true },
            openSetup: { opened.append($0) }
        )
        let install = Task { await setup.install() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(setup.state, .preparing)
        XCTAssertTrue(opened.isEmpty)
        await setup.install() // A second click must not start another installation.
        await gate.resume(folder)
        await install.value
        XCTAssertEqual(opened, [folder])
        XCTAssertEqual(setup.extensionDirectory, folder)
        XCTAssertEqual(setup.state, .awaitingChrome)
        await setup.refresh()
        XCTAssertEqual(setup.state, .connected)
        XCTAssertFalse(setup.checking)
    }

    func testOldConnectionCheckCannotHideSetupFailure() async {
        let started = expectation(description: "connection check started")
        let gate = ChromeSetupGate<Bool>()
        let setup = ChromeExtensionSetup(
            prepare: { URL(fileURLWithPath: "/test/extension") },
            connected: { started.fulfill(); return await gate.wait() },
            openSetup: { _ in
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Chrome could not open."])
            }
        )
        let check = Task { await setup.refresh() }
        await fulfillment(of: [started], timeout: 2)
        await setup.install()
        XCTAssertEqual(setup.state, .failed("Chrome could not open."))
        await gate.resume(true)
        await check.value
        XCTAssertEqual(setup.state, .failed("Chrome could not open."))
        XCTAssertFalse(setup.checking)
    }

    func testCancelledPreparationDoesNotOpenChromeOrLeaveSetupBusy() async {
        let started = expectation(description: "preparation started")
        let gate = ChromeSetupGate<URL>()
        let setup = ChromeExtensionSetup(
            prepare: { started.fulfill(); return await gate.wait() },
            connected: { false },
            openSetup: { _ in XCTFail("Cancelled setup must not open Chrome.") }
        )
        let install = Task { await setup.install() }
        await fulfillment(of: [started], timeout: 2)
        install.cancel()
        await gate.resume(URL(fileURLWithPath: "/test/extension"))
        await install.value
        XCTAssertEqual(setup.state, .disconnected)
        XCTAssertNil(setup.extensionDirectory)
    }
}

private actor ChromeSetupGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var result: Value?

    func wait() async -> Value {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ value: Value) {
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}
