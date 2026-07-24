import XCTest
@testable import SocketServer
import CoreModel

@MainActor
final class AgentRoutingDispatcherTests: XCTestCase {
    func testThreadListProjectsStableRoutingState() async {
        let router = FakeRouter()
        let manual = AgentModelSelection(
            provider: .claude,
            modelId: "claude-sonnet",
            reasoningEffort: .high,
            serviceTier: .fast
        )
        let routing = AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: manual,
            manualProviderInstanceId: "claude-work",
            eligibleProviders: [.claude, .codex],
            policyDigest: String(repeating: "a", count: 64),
            revision: 4
        )
        router.threadStore = [AgentThread(
            title: "routed",
            provider: .claude,
            providerInstanceId: "claude-work",
            model: manual.effectiveModel,
            reasoningEffort: manual.reasoningEffort,
            serviceTier: manual.serviceTier,
            modelSelection: manual,
            routingConfiguration: routing
        )]

        let response = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.thread.list",
            params: nil
        ))

        guard case .array(let threads)? = response.result,
              case .object(let thread)? = threads.first,
              case .object(let nested)? = thread["routing"] else {
            return XCTFail("thread list must include routing state")
        }
        XCTAssertEqual(thread["routing_mode"], .string("auto"))
        XCTAssertEqual(thread["routing_revision"], .number(4))
        XCTAssertEqual(thread["eligible_providers"], .array([.string("claude"), .string("codex")]))
        XCTAssertEqual(nested["mode"], .string("auto"))
        XCTAssertEqual(nested["revision"], .number(4))
        XCTAssertEqual(nested["manualSelection"], thread["manual_selection"])
    }

    func testAutoMessageRejectsManualProviderPinsBeforeRouterMutation() async {
        let router = FakeRouter()
        let thread = AgentThread(title: "auto", provider: .codex, model: "gpt")
        router.threadStore = [thread]

        let response = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.message.send",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "text": .string("route this"),
                "routing_mode": .string("auto"),
                "routing_revision": .number(1),
                "provider": .string("codex")
            ]
        ))

        XCTAssertEqual(response.error?.code, -32602)
        XCTAssertEqual(router.sendAgentMessageCallCount, 0)
    }

    // Regression: a routing_revision of exactly 2^63 is a finite, integral,
    // non-negative Double that passed the old `<= Double(Int.max)` guard (because
    // Double(Int.max) rounds up to 2^63) and then trapped in `Int(rawRevision)`,
    // aborting the whole host process — a remote DoS. The fix must reject it as
    // invalidParams and leave the router unmutated (no crash).
    func testRoutingRevisionOverflowRejectedWithoutCrash() async {
        let router = FakeRouter()
        let thread = AgentThread(title: "auto", provider: .codex, model: "gpt")
        router.threadStore = [thread]

        for revision in [0x1p63 /* 2^63 */, 0x1p64 /* 2^64 */, 1.5 /* fractional */, -1.0] {
            let response = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "agent.message.send",
                params: [
                    "thread_id": .string(thread.id.value.uuidString),
                    "text": .string("hi"),
                    "routing_mode": .string("manual"),
                    "routing_revision": .number(revision)
                ]
            ))
            XCTAssertEqual(response.error?.code, -32602, "revision \(revision) must be rejected as invalidParams")
            XCTAssertEqual(router.sendAgentMessageCallCount, 0)
        }
    }

    func testRoutingRevisionConflictMapsToTypedJSONRPCError() {
        let error = JSONRPCDispatcher.mapDomainError(
            AgentRoutingRevisionError.conflict(expected: 2, actual: 3),
            method: "agent.thread.configure"
        )

        XCTAssertEqual(error.code, -32020)
        XCTAssertEqual(error.data?.objectValue?["kind"], .string("revision_conflict"))
        XCTAssertEqual(error.data?.objectValue?["expected_revision"], .number(2))
        XCTAssertEqual(error.data?.objectValue?["actual_revision"], .number(3))
    }
}
