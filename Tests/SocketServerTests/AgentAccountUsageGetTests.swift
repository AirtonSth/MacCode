import XCTest
import AgentRuntime
import CoreModel
import RemoteCodeTreaty
@testable import SocketServer

/// WHY: the iPhone's usage rings stayed empty after connecting until the next
/// live `agent.account.usage` event, which can be minutes away (or never, for
/// an idle provider). On connect the phone must be able to read what the Mac
/// already has, with a read-only device, without making the host probe any
/// provider, and without a pre-reset percent or a missing value being painted
/// as real usage.
final class AgentAccountUsageGetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2AccountUsageGet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func decode(_ value: JSONValue) throws -> AgentAccountUsageGet.Result {
        try JSONDecoder().decode(AgentAccountUsageGet.Result.self, from: JSONEncoder().encode(value))
    }

    func test_getIsReadScopedBatchableAndNotAMutation() {
        XCTAssertEqual(AgentAccountUsageGet.method, "agent.account.usage.get")
        XCTAssertTrue(JSONRPCDispatcher.isReadOnlyBatchMethod("agent.account.usage.get"))
        XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: "agent.account.usage.get"), "read")
        XCTAssertTrue(JSONRPCDispatcher.isAuthorized(method: "agent.account.usage.get", grantedCapabilities: "read"))
        XCTAssertFalse(JSONRPCDispatcher.hostMutationMethods.contains("agent.account.usage.get"))
    }

    @MainActor
    func test_capabilitiesAdvertiseAccountUsageGetOnBothAuthorities() async throws {
        let payload = DirectHTTPServer.capabilitiesProjection(loopbackOnly: false)
            .authenticatedPayload(serverID: "host-1", bootEpoch: 42)
        let capabilities = try XCTUnwrap(payload["capabilities"] as? [String: Any])
        let agent = try XCTUnwrap(capabilities["agent"] as? [String: Any])
        XCTAssertEqual(agent["account_usage_get_v1"] as? Bool, true)
        let decoded = try JSONDecoder().decode(
            HostCapabilities.Agent.self,
            from: JSONSerialization.data(withJSONObject: agent)
        )
        XCTAssertTrue(decoded.accountUsageGetV1, "the treaty type the iPhone gates on reads the same flag")

        let response = await JSONRPCDispatcher(router: FakeRouter()).dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil
        ))
        XCTAssertEqual(response.result?.objectValue?["agent"]?.objectValue?["account_usage_get_v1"], .bool(true))
    }

    func test_olderHostWithoutFlagDecodesAsUnsupported() throws {
        let decoded = try JSONDecoder().decode(
            HostCapabilities.Agent.self,
            from: Data(#"{"providers":["codex"],"supports_stream_events":true,"supports_resume":true}"#.utf8)
        )
        XCTAssertFalse(decoded.accountUsageGetV1)
    }

    /// A host that never stored usage must say "unknown" (null), not 0%: a
    /// 0% ring would claim the account is unused.
    func test_nothingStoredReadsAsUnknownForEveryProvider() throws {
        let result = try decode(AgentAccountUsageWire.load(appSupportDirectory: root))
        XCTAssertEqual(result.providers.map(\.provider), ["claude", "codex", "grok"])
        XCTAssertNil(result.storedAtMs)
        for row in result.providers {
            XCTAssertNil(row.weeklyUsedPercent, row.provider)
            XCTAssertNil(row.currentSessionUsedPercent, row.provider)
        }
    }

    /// The stored values come back per provider with the same field names as
    /// the live `agent.account.usage` event, so one decoder fills the rings.
    func test_storedUsageIsReturnedPerProviderWithItsWindows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weeklyReset = now.addingTimeInterval(3 * 86_400)
        let sessionReset = now.addingTimeInterval(2 * 3_600)
        _ = try TokenSaverUsageStore(appSupportDirectory: root, now: { now }).recordAccountUsage(
            provider: .claude,
            weeklyUsedPercent: 42,
            weeklyWindowDurationMinutes: 10_080,
            weeklyResetsAt: weeklyReset,
            currentSessionUsedPercent: 17,
            currentSessionResetsAt: sessionReset
        )

        let result = try decode(AgentAccountUsageWire.load(appSupportDirectory: root, now: now))
        XCTAssertEqual(result.providers.map(\.provider), ["claude", "codex", "grok"])
        XCTAssertNotNil(result.storedAtMs, "the phone needs the cache age")
        XCTAssertEqual(result.providers[0], AgentAccountUsageGet.ProviderUsage(
            provider: "claude",
            weeklyUsedPercent: 42,
            weeklyWindowDurationMinutes: 10_080,
            weeklyResetsAtMs: Int64(weeklyReset.timeIntervalSince1970 * 1000),
            currentSessionUsedPercent: 17,
            currentSessionResetsAtMs: Int64(sessionReset.timeIntervalSince1970 * 1000)
        ))
        XCTAssertNil(result.providers[1].weeklyUsedPercent, "codex never reported usage")
        XCTAssertNil(result.providers[2].weeklyUsedPercent, "grok never reported usage")
    }

    /// After the provider's window resets, the stored percent is stale: the
    /// weekly ring must read 0 and the short-window ring must fall back
    /// (null), exactly like the Mac sidebar, instead of showing pre-reset usage.
    func test_expiredWindowsDoNotPaintPreResetUsage() throws {
        let recordedAt = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try TokenSaverUsageStore(appSupportDirectory: root, now: { recordedAt }).recordAccountUsage(
            provider: .codex,
            weeklyUsedPercent: 88,
            weeklyResetsAt: recordedAt.addingTimeInterval(3_600),
            currentSessionUsedPercent: 60,
            currentSessionResetsAt: recordedAt.addingTimeInterval(600)
        )

        let later = recordedAt.addingTimeInterval(7_200)
        let codex = try decode(AgentAccountUsageWire.load(appSupportDirectory: root, now: later)).providers[1]
        XCTAssertEqual(codex.provider, "codex")
        XCTAssertEqual(codex.weeklyUsedPercent, 0)
        XCTAssertNil(codex.currentSessionUsedPercent)
    }

    /// A host build without the router hook answers "not supported" instead
    /// of an empty success the phone would read as "no usage".
    func test_routerWithoutUsageReportsNotSupported() async {
        let response = await JSONRPCDispatcher(router: FakeRouter()).dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "agent.account.usage.get", params: nil
        ))
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, -32004, "JSONRPCError.notSupported, not method-not-found")
        XCTAssertEqual(response.error?.data, .string("agent.account.usage.get"))
    }
}
