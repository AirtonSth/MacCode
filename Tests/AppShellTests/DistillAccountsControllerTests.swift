import XCTest
@testable import AppShell
import AgentRuntime
import SocketServer

@MainActor
final class DistillAccountsControllerTests: XCTestCase {
    private final class Accounts: DistillAccountManaging, @unchecked Sendable {
        var statusesValue = DistillAccountProvider.allCases.map { DistillAccountStatus(provider: $0, connected: false) }
        var loginCount = 0
        var fail = false
        var delay = false

        func statuses() -> [DistillAccountStatus] { statusesValue }
        func login(_ provider: DistillAccountProvider, onURL: @escaping @Sendable (URL) -> Void) async throws {
            loginCount += 1
            if delay { try await Task.sleep(nanoseconds: 10_000_000_000) }
            if fail { throw DistillAccountError.failed("login failed") }
            statusesValue = statusesValue.map { $0.provider == provider ? DistillAccountStatus(provider: provider, connected: true) : $0 }
        }
        func logout(_ provider: DistillAccountProvider) async throws {
            statusesValue = statusesValue.map { $0.provider == provider ? DistillAccountStatus(provider: provider, connected: false) : $0 }
        }
    }

    func test_missingDistillInstallsOnceAndRefreshesAfterSuccess() async {
        var installerCalls = 0
        var refreshCalls = 0
        let controller = DistillAccountsController(
            accounts: Accounts(),
            installer: { installerCalls += 1; return "/tmp/distill" },
            resolveBinary: { nil },
            didChange: { _, succeeded in if succeeded { refreshCalls += 1 } }
        )
        controller.ensureDistillInstalled()
        XCTAssertEqual(controller.installState, .installing)
        for _ in 0..<100 where controller.installState == .installing {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(controller.installState, .installed)
        XCTAssertEqual(installerCalls, 1)
        XCTAssertEqual(refreshCalls, 1)
    }

    func test_installIsSingleFlightWhileInstallerWaits() async {
        let entered = expectation(description: "installer started off the main actor")
        let semaphore = DispatchSemaphore(value: 0)
        var installerCalls = 0
        defer { semaphore.signal() }
        let controller = DistillAccountsController(
            accounts: Accounts(),
            installer: {
                installerCalls += 1
                entered.fulfill()
                semaphore.wait()
                return "/tmp/distill"
            },
            resolveBinary: { nil }
        )
        controller.ensureDistillInstalled()
        controller.ensureDistillInstalled()
        controller.ensureDistillInstalled()
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(controller.installState, .installing)
        XCTAssertEqual(installerCalls, 1)
    }

    func test_installFailureShowsOfficialCommandAndRetryRunsInstallerAgain() async {
        var installerCalls = 0
        let controller = DistillAccountsController(
            accounts: Accounts(),
            installer: {
                installerCalls += 1
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "network unavailable"])
            },
            resolveBinary: { nil }
        )
        controller.ensureDistillInstalled()
        for _ in 0..<100 where controller.installState == .installing {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .failed(let message) = controller.installState else { return XCTFail("expected failed state") }
        XCTAssertTrue(message.contains(DistillProvisioner.installPlan().commandLine))
        controller.retryDistillInstall()
        for _ in 0..<100 where controller.installState == .installing {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(installerCalls, 2)
    }

    func test_alreadyInstalledSkipsInstaller() {
        var installerCalls = 0
        let controller = DistillAccountsController(
            accounts: Accounts(),
            installer: { installerCalls += 1; return "/tmp/distill" },
            resolveBinary: { "/tmp/distill" }
        )
        controller.ensureDistillInstalled()
        XCTAssertEqual(controller.installState, .installed)
        XCTAssertEqual(installerCalls, 0)
    }

    func test_loginAllowsOnlyOneOperationAndCancelClearsBusyState() async {
        let accounts = Accounts()
        accounts.delay = true
        let controller = DistillAccountsController(accounts: accounts)
        controller.login(.grok)
        XCTAssertEqual(controller.busyProvider, .grok)
        for _ in 0..<50 where accounts.loginCount == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        controller.login(.claude)
        XCTAssertEqual(accounts.loginCount, 1)
        controller.cancel()
        XCTAssertNil(controller.busyProvider)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(controller.busyProvider)
    }

    func test_loginSuccessRefreshesStatusAndPublishesProviderUpdate() async throws {
        let accounts = Accounts()
        let providerEvents = expectation(description: "agent.provider.updated carries account operation start, refresh, and end")
        providerEvents.expectedFulfillmentCount = 3
        let eventToken = EventBus.shared.subscribe(since: nil) { event in
            guard event.kind == "agent.provider.updated",
                  event.payload.objectValue?["provider"] == .string("claude") else { return }
            providerEvents.fulfill()
        }
        defer { EventBus.shared.unsubscribe(eventToken) }
        var successfulRefreshes = 0
        let controller = DistillAccountsController(accounts: accounts) { _, succeeded in
            if succeeded { successfulRefreshes += 1 }
        }
        controller.login(.claude)
        for _ in 0..<50 where controller.busyProvider != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(controller.busyProvider)
        XCTAssertEqual(controller.statuses.first { $0.provider == .claude }?.connected, true)
        XCTAssertEqual(successfulRefreshes, 1)
        await fulfillment(of: [providerEvents], timeout: 2)
    }

    func test_loginFailureSurfacesErrorAndClearsBusyState() async throws {
        let accounts = Accounts()
        accounts.fail = true
        let controller = DistillAccountsController(accounts: accounts)
        controller.login(.grok)
        for _ in 0..<50 where controller.busyProvider != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.lastError, "login failed")
        XCTAssertNil(controller.busyProvider)
    }
}
