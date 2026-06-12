import XCTest
@testable import SocketServer
import CoreModel
import AgentRuntime

// MARK: - :14  fs.workspace.changed event-name + payload-shape contract
//
// WHY: Dispatcher.swift emits "fs.workspace.changed" from three mutation paths
// (create_file:516, rename:527, delete:539). iOS consumers decode the event by
// name and then read workspace_id / action / paths from the payload. Nothing
// previously pinned either the event name string or the payload field names
// against a consumer expectation, so a typo or rename on either side would be
// invisible until a real device reported silent refresh failures.
//
// These tests are the golden contract: if the event name or any required field
// changes, at least one assertion below must fail immediately, before the change
// ships to a paired iOS device.

@MainActor
final class FsWorkspaceChangedContractTests: XCTestCase {

    // Shared temp dir for all three mutation tests.
    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "rc2-xplat-fs-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmpDir + "/src", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // Helper: subscribe to EventBus.shared, run `work`, return captured events
    // whose kind == "fs.workspace.changed". Unsubscribes before returning so
    // subsequent tests start clean.
    // Filter by workspace_id (each test uses a fresh UUID) so a concurrent test's
    // emission on the shared EventBus does not leak into this test's capture
    // window -- the singleton bus otherwise causes cross-test interference.
    private func capture(workspaceId: UUID, work: () async throws -> Void) async throws -> [EventBus.Event] {
        var captured: [EventBus.Event] = []
        let id = EventBus.shared.subscribe(since: nil) { ev in
            if ev.kind == "fs.workspace.changed",
               ev.payload.objectValue?["workspace_id"]?.stringValue == workspaceId.uuidString {
                captured.append(ev)
            }
        }
        try await work()
        EventBus.shared.unsubscribe(id)
        return captured
    }

    // MARK: create_file emits the correct event shape

    /// WHY: iOS file-browser refresh listens for "fs.workspace.changed" with
    /// action == "create_file". If the event name drifts, iOS never learns of
    /// the new file and the tree appears stale until the next full poll.
    func test_createFile_emitsFsWorkspaceChangedWithCorrectShape() async throws {
        let router = FakeRouter(); router.projectCwd = tmpDir
        let wid = UUID()
        let d = JSONRPCDispatcher(router: router)

        let events = try await capture(workspaceId: wid) {
            _ = await d.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(1),
                method: "fs.workspace.create_file",
                params: [
                    "workspace_id": .string(wid.uuidString),
                    "path": .string("src/Contract.swift")
                ]
            ))
        }

        // Exactly one event must be emitted — not zero (missed), not two (duplicate).
        XCTAssertEqual(events.count, 1,
            "fs.workspace.create_file must emit exactly one 'fs.workspace.changed' event so iOS triggers a single list refresh")

        let payload = try XCTUnwrap(events.first?.payload.objectValue,
            "fs.workspace.changed payload must be a JSON object; iOS decoder will crash on non-object")

        // event name — the hard-pinned string iOS subscribes on
        XCTAssertEqual(events.first?.kind, "fs.workspace.changed",
            "event name is the iOS subscription key; renaming it breaks all iOS file-browser refresh without a client-side change")

        // workspace_id — iOS uses this to scope the refresh to the correct workspace
        XCTAssertEqual(payload["workspace_id"]?.stringValue, wid.uuidString,
            "workspace_id must be the UUID string of the affected workspace so iOS scopes its list refresh correctly")

        // action — iOS switches on this to pick create vs rename vs delete handling
        XCTAssertEqual(payload["action"]?.stringValue, "create_file",
            "action must be 'create_file' so iOS knows to insert a row, not remove or rename one")

        // paths — iOS uses the first entry as the new file path to select/open
        let paths = try XCTUnwrap(payload["paths"]?.arrayValue,
            "paths must be a JSON array; iOS iterates it to update visible file rows")
        XCTAssertFalse(paths.isEmpty,
            "paths array must be non-empty; an empty array means iOS cannot determine which file changed")
        XCTAssertNotNil(paths.first?.stringValue,
            "each paths entry must be a string (relative path); iOS uses it as a navigation key")
    }

    // MARK: rename emits the correct event shape

    /// WHY: iOS rename animation reads paths[0] (old) and paths[1] (new) to
    /// update the in-memory tree node. If action is wrong, iOS treats the event
    /// as an unknown mutation and falls back to a full re-list, causing flicker.
    func test_rename_emitsFsWorkspaceChangedWithCorrectShape() async throws {
        // pre-create the file so rename does not fail
        try "".write(toFile: tmpDir + "/src/Before.swift", atomically: true, encoding: .utf8)
        let router = FakeRouter(); router.projectCwd = tmpDir
        let wid = UUID()
        let d = JSONRPCDispatcher(router: router)

        let events = try await capture(workspaceId: wid) {
            _ = await d.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(1),
                method: "fs.workspace.rename",
                params: [
                    "workspace_id": .string(wid.uuidString),
                    "path": .string("src/Before.swift"),
                    "new_name": .string("After.swift")
                ]
            ))
        }

        XCTAssertEqual(events.count, 1,
            "fs.workspace.rename must emit exactly one 'fs.workspace.changed' event")

        let payload = try XCTUnwrap(events.first?.payload.objectValue)

        XCTAssertEqual(events.first?.kind, "fs.workspace.changed",
            "event name must remain 'fs.workspace.changed' for rename; iOS rename handler is registered on this exact string")

        XCTAssertEqual(payload["workspace_id"]?.stringValue, wid.uuidString,
            "workspace_id must identify the workspace so iOS does not refresh unrelated trees")

        XCTAssertEqual(payload["action"]?.stringValue, "rename",
            "action must be 'rename' so iOS moves the tree node instead of inserting a duplicate or showing a ghost entry")

        let paths = try XCTUnwrap(payload["paths"]?.arrayValue,
            "rename payload must include a paths array with [old, new] so iOS can update its in-memory node reference")
        XCTAssertEqual(paths.count, 2,
            "rename paths must contain exactly two entries: [old_path, new_path] — iOS indexes into position 0 and 1")
        XCTAssertNotNil(paths[0].stringValue, "paths[0] (old path) must be a string")
        XCTAssertNotNil(paths[1].stringValue, "paths[1] (new path) must be a string")
    }

    // MARK: delete emits the correct event shape

    /// WHY: iOS delete handling reads paths to remove rows from the file tree.
    /// If action is missing or wrong, iOS leaves ghost entries that crash on tap.
    func test_delete_emitsFsWorkspaceChangedWithCorrectShape() async throws {
        try "".write(toFile: tmpDir + "/src/Gone.swift", atomically: true, encoding: .utf8)
        let router = FakeRouter(); router.projectCwd = tmpDir
        let wid = UUID()
        let d = JSONRPCDispatcher(router: router)

        let events = try await capture(workspaceId: wid) {
            _ = await d.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(1),
                method: "fs.workspace.delete",
                params: [
                    "workspace_id": .string(wid.uuidString),
                    "paths": .array([.string("src/Gone.swift")])
                ]
            ))
        }

        XCTAssertEqual(events.count, 1,
            "fs.workspace.delete must emit exactly one 'fs.workspace.changed' event")

        let payload = try XCTUnwrap(events.first?.payload.objectValue)

        XCTAssertEqual(events.first?.kind, "fs.workspace.changed",
            "event name must be 'fs.workspace.changed' for delete; iOS unregisters the listener on any other name")

        XCTAssertEqual(payload["workspace_id"]?.stringValue, wid.uuidString,
            "workspace_id must scope the delete event to the correct workspace")

        XCTAssertEqual(payload["action"]?.stringValue, "delete",
            "action must be 'delete' so iOS removes the row rather than inserting or renaming it")

        let paths = try XCTUnwrap(payload["paths"]?.arrayValue,
            "delete payload must include a paths array so iOS knows which rows to remove from the file tree")
        XCTAssertFalse(paths.isEmpty,
            "delete paths must be non-empty; an empty array means iOS cannot remove any rows")
        XCTAssertNotNil(paths.first?.stringValue,
            "each delete paths entry must be a string (relative path) matching the iOS file-tree node key")
    }
}

// MARK: - :19  agent.checkpoint.revert / agent.checkpoint.diff param-key parity
//
// WHY: the mac host originally read ONLY params["turn_count"] while the iOS
// client sends "checkpoint_turn_count". Both test suites stayed green while
// production calls from a real iOS device failed with JSONRPCError -32602
// (invalid params). The host was fixed to accept BOTH keys (Dispatcher.swift
// :1120 / :1125). These tests are the guard that would have caught the drift:
// if either key stops working in the future, the corresponding test fails with
// a non-nil .error before any device sees the regression.
//
// The test must use params["checkpoint_turn_count"] (the iOS key) as the primary
// case and params["turn_count"] (the mac key) as the secondary, so the fix
// cannot be reverted without breaking at least the primary assertion.

@MainActor
final class CheckpointParamKeyParityTests: XCTestCase {

    // Shared checkpoint fixture reused across all sub-tests.
    private func makeRouterAndThread() -> (FakeRouter, AgentThread) {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "parity", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.checkpointStore = [AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: AgentRunID(),
            turnId: "turn-3",
            checkpointTurnCount: 3,
            checkpointRef: "local-diff:test:turn-3",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "main.swift", kind: "modified", additions: 2, deletions: 1)],
            diffPatch: "@@ main\n+added\n",
            fileDiffs: [AgentTurnCheckpointFileDiff(path: "main.swift", patch: "@@ main\n+added\n")]
        )]
        return (router, thread)
    }

    // MARK: agent.checkpoint.revert — iOS key

    /// WHY: iOS DirectClients sends "checkpoint_turn_count". Before the fix,
    /// the host read only "turn_count" and returned -32602 on every iOS revert.
    /// This test uses the iOS key exclusively so removing the
    /// `params["checkpoint_turn_count"]` branch from Dispatcher.swift causes
    /// this test to fail before a device sees the regression.
    func test_checkpointRevert_acceptsIOSKey_checkpointTurnCount() async throws {
        let (router, thread) = makeRouterAndThread()
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.checkpoint.revert",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "checkpoint_turn_count": .number(3)   // iOS key — the drifted param
            ]
        ))

        XCTAssertNil(response.error,
            "agent.checkpoint.revert with 'checkpoint_turn_count' (the iOS param key) must not return -32602; " +
            "the host must accept this key so a real iOS device can revert without a client-side change")
        XCTAssertNotNil(response.result,
            "a successful revert must return a checkpoint result, not nil")
        XCTAssertEqual(router.lastCheckpointRevert?.0, thread.id,
            "revert must be routed to the correct thread when called with the iOS key")
        XCTAssertEqual(router.lastCheckpointRevert?.1, 3,
            "revert turn count must be 3 when the iOS key carries value 3")
    }

    // MARK: agent.checkpoint.revert — mac-native key

    /// WHY: the mac host's own tests previously used only "turn_count". Both
    /// keys must continue to work after the dual-accept fix so mac-originated
    /// reverts (e.g. from the history panel) do not break when the dual-accept
    /// branch is refactored.
    func test_checkpointRevert_acceptsMacKey_turnCount() async throws {
        let (router, thread) = makeRouterAndThread()
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.checkpoint.revert",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "turn_count": .number(3)   // mac-native key
            ]
        ))

        XCTAssertNil(response.error,
            "agent.checkpoint.revert with 'turn_count' (the mac-native key) must still succeed after the dual-accept fix")
        XCTAssertEqual(router.lastCheckpointRevert?.1, 3,
            "mac-native turn_count value must be forwarded correctly to the router")
    }

    // MARK: agent.checkpoint.revert — neither key → must fail

    /// WHY: the dual-accept fix must not silently swallow missing params.
    /// A request with no turn count at all must still fail with an error so
    /// callers discover the contract violation at call time, not at render time.
    func test_checkpointRevert_missingBothKeys_returnsInvalidParams() async throws {
        let (router, thread) = makeRouterAndThread()
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.checkpoint.revert",
            params: [
                "thread_id": .string(thread.id.value.uuidString)
                // intentionally omit both turn_count and checkpoint_turn_count
            ]
        ))

        XCTAssertNotNil(response.error,
            "agent.checkpoint.revert with no turn-count key must return an error; " +
            "accepting a missing param silently would allow reverts to an unspecified checkpoint")
        XCTAssertEqual(response.error?.code, -32602,
            "missing both turn-count keys must yield the standard invalid-params code -32602")
        XCTAssertEqual(router.checkpointRevertCallCount, 0,
            "the router revert method must not be called when params are invalid")
    }

    // MARK: agent.checkpoint.diff — iOS key

    /// WHY: same param-key drift affects agent.checkpoint.diff (Dispatcher.swift
    /// :1120). iOS sends "checkpoint_turn_count" here too. This test guards the
    /// diff path in parallel so a future refactor cannot break diff while leaving
    /// revert green.
    func test_checkpointDiff_acceptsIOSKey_checkpointTurnCount() async throws {
        let (router, thread) = makeRouterAndThread()
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.checkpoint.diff",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "checkpoint_turn_count": .number(3),  // iOS key
                "path": .string("main.swift")
            ]
        ))

        XCTAssertNil(response.error,
            "agent.checkpoint.diff with 'checkpoint_turn_count' (iOS key) must not return -32602; " +
            "this is the exact failure mode that was silently broken in production")
        XCTAssertEqual(response.result, .string("@@ main\n+added\n"),
            "diff result must match the fixture patch when called with the iOS key")
    }

    // MARK: agent.checkpoint.diff — mac-native key

    /// WHY: mac-native "turn_count" must also continue to work on the diff path
    /// so existing mac history-panel flows are not broken by the dual-accept fix.
    func test_checkpointDiff_acceptsMacKey_turnCount() async throws {
        let (router, thread) = makeRouterAndThread()
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.checkpoint.diff",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "turn_count": .number(3),  // mac-native key
                "path": .string("main.swift")
            ]
        ))

        XCTAssertNil(response.error,
            "agent.checkpoint.diff with 'turn_count' (mac key) must succeed after the dual-accept fix")
        XCTAssertEqual(response.result, .string("@@ main\n+added\n"),
            "diff result must match the fixture patch when called with the mac-native key")
    }

    // MARK: agent.checkpoint.diff — neither key → must fail

    /// WHY: dual-accept must not swallow genuinely malformed requests.
    func test_checkpointDiff_missingBothKeys_returnsInvalidParams() async throws {
        let (router, thread) = makeRouterAndThread()
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.checkpoint.diff",
            params: [
                "thread_id": .string(thread.id.value.uuidString)
                // no turn count
            ]
        ))

        XCTAssertNotNil(response.error,
            "agent.checkpoint.diff with neither turn-count key must return an error to surface param drift early")
        XCTAssertEqual(response.error?.code, -32602,
            "missing both turn-count keys must yield -32602 so clients see the contract violation at call time")
    }
}
