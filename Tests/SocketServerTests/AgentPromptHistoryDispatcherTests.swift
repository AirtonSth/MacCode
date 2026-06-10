import XCTest
@testable import SocketServer
import CoreModel

/// Tests for the agent.prompt_history RPC method (cross-platform item 35).
///
/// Contract: iOS CommandPaletteView calls
///   session.invoke("agent.prompt_history", params: ["limit": <n>])
/// and reads result["prompts"].arrayValue.
/// The host must return {"prompts": [...]} most-recent-first.
@MainActor
final class AgentPromptHistoryDispatcherTests: XCTestCase {

    // MARK: - Helpers

    private func makeDispatcher(prompts: [String], workspaceID: WorkspaceID? = nil) -> JSONRPCDispatcher {
        let router = FakeRouter()
        let wid = workspaceID ?? WorkspaceID()
        router.window.selectedWorkspaceID = wid
        // FakeRouter stores history oldest-first (same contract as PromptHistoryStore).
        router.promptHistoryByWorkspace[wid] = prompts
        return JSONRPCDispatcher(router: router)
    }

    // MARK: - (a) result shape is {"prompts": [...]}

    /// agent.prompt_history must always wrap the list in {"prompts":[...]} so
    /// the iOS client can read result["prompts"].arrayValue without a fallback
    /// branch. A bare array would silently return nil on the iOS side.
    func test_resultShape_isWrappedInPromptsKey() async {
        let d = makeDispatcher(prompts: ["first", "second"])
        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.prompt_history",
            params: ["limit": .number(20)]
        ))
        XCTAssertNil(resp.error, "agent.prompt_history must not error for a valid call")
        guard case .object(let body) = resp.result,
              case .array = body["prompts"] else {
            return XCTFail("result must be {\"prompts\":[...]}; iOS reads result[\"prompts\"].arrayValue")
        }
    }

    // MARK: - (b) ordering is most-recent-first

    /// iOS presents history as a picker list where index 0 is the most-recent
    /// prompt. If we return oldest-first the user sees inverted history.
    func test_ordering_isMostRecentFirst() async {
        let d = makeDispatcher(prompts: ["oldest", "middle", "newest"])
        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.prompt_history",
            params: ["limit": .number(20)]
        ))
        guard case .object(let body) = resp.result,
              case .array(let arr) = body["prompts"] else {
            return XCTFail("expected {\"prompts\":[...]}")
        }
        XCTAssertEqual(arr.first, .string("newest"),
                       "index 0 must be the most-recently stored prompt so iOS picker shows it first")
        XCTAssertEqual(arr.last, .string("oldest"),
                       "last element must be the oldest stored prompt")
    }

    // MARK: - (c) limit caps the count

    /// iOS passes a limit to avoid fetching hundreds of historical prompts when
    /// it only needs the top few for the quick-pick UI. The cap must apply.
    func test_limitParam_capsResultCount() async {
        let prompts = (1...10).map { "prompt\($0)" }
        let d = makeDispatcher(prompts: prompts)
        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.prompt_history",
            params: ["limit": .number(3)]
        ))
        guard case .object(let body) = resp.result,
              case .array(let arr) = body["prompts"] else {
            return XCTFail("expected {\"prompts\":[...]}")
        }
        XCTAssertEqual(arr.count, 3,
                       "limit=3 must cap the returned array to 3 items; more would waste iOS rendering budget")
        XCTAssertEqual(arr.first, .string("prompt10"),
                       "first item must be the most recent after capping")
    }

    // MARK: - (d) empty history returns {"prompts":[]} not an error

    /// CommandPaletteView does not guard the result for nil; it reads
    /// result["prompts"].arrayValue which returns [] for .array([]). An error
    /// or absent key would crash or show stale data.
    func test_emptyHistory_returnsEmptyArrayNotError() async {
        let d = makeDispatcher(prompts: [])
        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.prompt_history",
            params: ["limit": .number(20)]
        ))
        XCTAssertNil(resp.error,
                     "empty history is not an error condition; iOS must get an empty list, not a failure")
        guard case .object(let body) = resp.result,
              case .array(let arr) = body["prompts"] else {
            return XCTFail("result must be {\"prompts\":[]} even when history is empty")
        }
        XCTAssertEqual(arr.count, 0,
                       "prompts array must be empty, not absent or nil")
    }

    // MARK: - no workspace_id still works

    /// iOS sends only the limit param (no workspace_id). The dispatcher must
    /// resolve to the currently selected workspace without throwing.
    func test_noWorkspaceParam_resolvesToSelectedWorkspace() async {
        let d = makeDispatcher(prompts: ["alpha", "beta"])
        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.prompt_history",
            params: ["limit": .number(20)]
        ))
        XCTAssertNil(resp.error,
                     "omitting workspace_id must not error; iOS never passes this param")
        guard case .object(let body) = resp.result,
              case .array(let arr) = body["prompts"] else {
            return XCTFail("expected {\"prompts\":[...]}")
        }
        XCTAssertEqual(arr.count, 2)
    }

    // MARK: - authorization: read-only batch method

    /// agent.prompt_history is a read-only query. Scoped devices (non-* trust)
    /// must be allowed to call it under the "read" capability bucket, matching
    /// the same treatment as agent.thread.list and other *.list methods.
    func test_isReadOnlyBatchMethod() {
        // This is a pure static check -- no dispatcher round-trip needed.
        XCTAssertTrue(
            JSONRPCDispatcher.isReadOnlyBatchMethod("agent.prompt_history"),
            "agent.prompt_history is a read-only RPC; scoped iOS devices must be able to call it without 'write' capability"
        )
    }
}
