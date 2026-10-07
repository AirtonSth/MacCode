import XCTest
import AgentRuntime
import CoreModel
import RemoteCodeTreaty
@testable import SocketServer
@testable import AppShell

/// WHY: on connect the iPhone asks the Mac for the account usage it already
/// stored so the rings fill at once. The real host must serve it from this
/// app's own support directory (the file the live usage events write), not
/// throw "not supported" or read another install's data.
@MainActor
final class AgentAccountUsageGetRemoteTests: XCTestCase {
    func test_hostServesUsageStoredByThisApp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2AccountUsageRemote-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let resetsAt = Date().addingTimeInterval(86_400)
        _ = try TokenSaverUsageStore(appSupportDirectory: ctx.appSupportDirectory).recordAccountUsage(
            provider: .grok, weeklyUsedPercent: 31, weeklyResetsAt: resetsAt
        )

        let response = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: AgentAccountUsageGet.method, params: nil
        ))
        XCTAssertNil(response.error)
        let result = try JSONDecoder().decode(
            AgentAccountUsageGet.Result.self,
            from: JSONEncoder().encode(XCTUnwrap(response.result))
        )
        let grok = try XCTUnwrap(result.providers.first { $0.provider == "grok" })
        XCTAssertEqual(grok.weeklyUsedPercent, 31)
        XCTAssertNotNil(result.storedAtMs)
    }
}
