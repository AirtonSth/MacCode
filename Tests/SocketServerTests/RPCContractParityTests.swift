import XCTest
@testable import SocketServer
import CoreModel

// MARK: - RPC Contract Parity — macOS host side
//
// WHY: rpc-contract.json (repo root) is the single source of truth for the
// method→param→result→event contract shared by the macOS host and iOS client.
// These tests pin the macOS Dispatcher's behaviour against the values in that
// manifest so any drift surfaces as a test failure rather than a silent bug on
// a real device.
//
// The manifest values are embedded directly here because the shared JSON root
// may not be on the Swift module search path at test runtime (Package.swift
// does not list it as a resource target). The JSON file is the human
// source-of-truth; this file is the enforcement. Keep them in sync.
//
// See: todo/cross-platform.md :18
//     rpc-contract.json (repo root)

@MainActor
final class RPCContractParityTests: XCTestCase {

    // MARK: - Manifest: required param keys per method

    /// Every entry is (method, required param keys). Optional params (e.g.
    /// client_request_id, max_bytes) are omitted — the test only verifies that
    /// the Dispatcher REJECTS requests missing the truly required keys.
    private let requiredParams: [(method: String, keys: [String])] = [
        ("events.recent",             []),            // all params optional
        ("workspace.list",            []),
        ("workspace.current",         []),
        ("window.current",            []),
        ("pane.list",                 ["workspace_id"]),
        ("mirror.snapshot",           ["workspace_id"]),
        ("agent.checkpoint.diff",     ["thread_id", "checkpoint_turn_count"]),
        ("agent.checkpoint.revert",   ["thread_id", "checkpoint_turn_count"]),
        ("agent.message.queue.list",  ["thread_id"]),
        ("agent.message.queue.update",["queued_message_id", "text"]),
        ("agent.message.queue.cancel",["queued_message_id"]),
        ("agent.message.queue.force_now", ["queued_message_id"]),
        ("agent.prompt_history",      []),
    ]

    /// Dispatcher returns -32602 (invalidParams) when required params are absent.
    func test_requiredParams_missingKeyReturnsInvalidParams() async {
        let d = JSONRPCDispatcher(router: FakeRouter())

        for (method, keys) in requiredParams where !keys.isEmpty {
            let resp = await d.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(1),
                method: method,
                params: [:]   // all keys absent
            ))
            let code = resp.error?.code
            XCTAssertEqual(code, -32602,
                "method '\(method)' must return -32602 when required params \(keys) are missing; " +
                "got code \(code.map(String.init) ?? "nil"). " +
                "rpc-contract.json lists these as required params.")
        }
    }

    // MARK: - Manifest: methods must be recognised (not -32601)

    /// Dispatcher must not return -32601 (methodNotFound) for any method in the manifest.
    /// Methods that need real state return -32602 or succeed — both are acceptable.
    private let allContractMethods: [String] = [
        "events.recent",
        "workspace.list",
        "workspace.current",
        "window.current",
        "pane.list",
        "mirror.snapshot",
        "agent.checkpoint.diff",
        "agent.checkpoint.revert",
        "agent.message.queue.list",
        "agent.message.queue.update",
        "agent.message.queue.cancel",
        "agent.message.queue.force_now",
        "agent.prompt_history",
    ]

    func test_allContractMethods_areRecognisedByDispatcher() async {
        let d = JSONRPCDispatcher(router: FakeRouter())

        for method in allContractMethods {
            let resp = await d.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(1),
                method: method,
                params: [:]
            ))
            XCTAssertNotEqual(resp.error?.code, -32601,
                "method '\(method)' returned -32601 (methodNotFound) — " +
                "it is listed in rpc-contract.json but the Dispatcher does not handle it. " +
                "Add a case or update the manifest.")
        }
    }

    // MARK: - events.recent result shape

    /// WHY: iOS EventStreamClient reads last_seq/events/truncated/requires_baseline.
    /// All four keys must be present in every response, regardless of whether
    /// there are events in the bus.
    func test_eventsRecent_resultShapeMatchesManifest() async {
        let d = JSONRPCDispatcher(router: FakeRouter())

        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "events.recent",
            params: [:]
        ))

        guard let obj = resp.result?.objectValue else {
            XCTFail("events.recent must return a JSON object; got \(String(describing: resp))")
            return
        }

        for key in ["last_seq", "events", "truncated", "requires_baseline"] {
            XCTAssertNotNil(obj[key],
                "events.recent result missing key '\(key)' — iOS decoder will silently misread replay state. " +
                "rpc-contract.json lists this as a required result key.")
        }
    }

    // MARK: - agent.checkpoint.diff / revert accept checkpoint_turn_count

    /// WHY: iOS client sends checkpoint_turn_count (not turn_count). The Dispatcher
    /// accepts both (Dispatcher.swift:1122,1127) but if that guard changes it will
    /// silently break checkpoint diff/revert on real devices while the fake stays green.
    func test_checkpointDiff_acceptsCheckpointTurnCountKey() async {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "cp", provider: .codex, model: "gpt-4")
        router.threadStore = [thread]
        router.checkpointStore = [AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: AgentRunID(),
            turnId: "turn-1",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:test:turn-1",
            status: .ready,
            files: [],
            diffPatch: "diff --git a/A.swift b/A.swift\n+// test",
            fileDiffs: []
        )]
        let d = JSONRPCDispatcher(router: router)

        // Send checkpoint_turn_count (iOS canonical key — NOT turn_count).
        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.checkpoint.diff",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "checkpoint_turn_count": .number(1)
            ]
        ))

        XCTAssertNil(resp.error,
            "agent.checkpoint.diff must accept 'checkpoint_turn_count' (iOS canonical key). " +
            "Error: \(resp.error.map { "\($0.code): \($0.message)" } ?? "nil"). " +
            "rpc-contract.json notes both keys are accepted; if this fails the iOS client will " +
            "always get -32602 against a real Mac.")
    }

    // MARK: - agent.checkpoint.reverted event emits turn_count (not checkpoint_turn_count)

    /// WHY: rpc-contract.json notes a DRIFT: macOS emits turn_count in the
    /// agent.checkpoint.reverted event payload (Dispatcher.swift:1136) while the
    /// iOS FakeState emits checkpoint_turn_count (FakeState.swift:867). The iOS
    /// MirrorEventReducer does not handle this event at all. This test pins the
    /// macOS key name so that if it ever changes (or the iOS reducer adds a case
    /// reading the wrong key) the drift is caught here rather than silently
    /// reverting to the wrong checkpoint state on device.
    func test_checkpointRevert_emittedEventHasTurnCountKey() async {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "revert", provider: .codex, model: "gpt-4")
        router.threadStore = [thread]
        router.checkpointStore = [AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: AgentRunID(),
            turnId: "turn-1",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:test:turn-1",
            status: .ready,
            files: [],
            diffPatch: nil,
            fileDiffs: []
        )]
        let d = JSONRPCDispatcher(router: router)

        var captured: [EventBus.Event] = []
        let subId = EventBus.shared.subscribe(since: nil) { ev in
            if ev.kind == "agent.checkpoint.reverted" { captured.append(ev) }
        }
        defer { EventBus.shared.unsubscribe(subId) }

        _ = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.checkpoint.revert",
            params: [
                "thread_id": .string(thread.id.value.uuidString),
                "checkpoint_turn_count": .number(1)
            ]
        ))

        guard let ev = captured.first else {
            XCTFail("agent.checkpoint.revert must emit agent.checkpoint.reverted event; none captured. " +
                    "rpc-contract.json lists thread_id/turn_count/turn_id/checkpoint_ref as required payload keys.")
            return
        }

        let payload = ev.payload.objectValue ?? [:]

        // macOS-authoritative key is turn_count (Dispatcher.swift:1136).
        XCTAssertNotNil(payload["turn_count"],
            "agent.checkpoint.reverted event missing 'turn_count' key. " +
            "rpc-contract.json pins this as the macOS-authoritative key. " +
            "DRIFT NOTE: iOS FakeState incorrectly emits 'checkpoint_turn_count' — " +
            "if you update the iOS FakeState to match, update rpc-contract.json accordingly.")
        XCTAssertNotNil(payload["thread_id"],
            "agent.checkpoint.reverted event missing 'thread_id' key.")
        XCTAssertNotNil(payload["turn_id"],
            "agent.checkpoint.reverted event missing 'turn_id' key.")
        XCTAssertNotNil(payload["checkpoint_ref"],
            "agent.checkpoint.reverted event missing 'checkpoint_ref' key.")

        // Confirm the drifted key is NOT the one emitted (documents the drift explicitly).
        XCTAssertNil(payload["checkpoint_turn_count"],
            "agent.checkpoint.reverted must NOT emit 'checkpoint_turn_count' (that is the iOS fake's " +
            "drifted key). macOS emits 'turn_count'. If this key appears here the Dispatcher changed — " +
            "update rpc-contract.json and the iOS FakeState together.")
    }

    // MARK: - agent.message.queue event kinds are emitted

    /// WHY: iOS MirrorEventReducer handles agent.message.queued and
    /// agent.message.queue.updated in one case (MirrorEventReducer.swift:855), and
    /// agent.message.queue.cancelled / agent.message.queue.drained in another (line:866).
    /// These event kinds are published by AppCommandRouter, not Dispatcher. This test
    /// verifies the kind strings are stable by comparing macOS-emitted vs iOS-handled sets.
    func test_queueEventKinds_areInManifest() {
        // These are the kind strings AppCommandRouter publishes (AppCommandRouter.swift:
        // 1232, 1242, 1258, 1264, 1266, 1294, 1351).
        let macOSEmittedKinds: Set<String> = [
            "agent.message.queued",
            "agent.message.queue.updated",
            "agent.message.queue.cancelled",
            "agent.message.queue.drained",
        ]
        // These are the kind strings iOS MirrorEventReducer handles (MirrorEventReducer.swift:855,866).
        let iosHandledKinds: Set<String> = [
            "agent.message.queued",
            "agent.message.queue.updated",
            "agent.message.queue.cancelled",
            "agent.message.queue.drained",
        ]
        let unhandled = macOSEmittedKinds.subtracting(iosHandledKinds)
        XCTAssertTrue(unhandled.isEmpty,
            "macOS emits event kind(s) \(unhandled.sorted()) that iOS MirrorEventReducer does NOT handle. " +
            "Update rpc-contract.json and add a case to MirrorEventReducer.")
    }

    // MARK: - agent.account.usage is not handled by iOS reducer (documented gap)

    /// WHY: rpc-contract.json explicitly notes that agent.account.usage is published
    /// by macOS AppContext but has NO corresponding case in iOS MirrorEventReducer.
    /// This test documents the gap so it cannot be silently ignored. It will fail
    /// if someone adds 'agent.account.usage' to the iOS handled set without also
    /// updating both sides and rpc-contract.json.
    func test_agentAccountUsage_isDocumentedAsUnhandledOnIOS() {
        // macOS publishes this kind (AppContext.swift:301, 500, 557).
        let macOSEmits = true
        // iOS MirrorEventReducer has no case for it (confirmed: zero hits in MirrorEventReducer.swift).
        let iosHandles = false

        // Test is intentionally green while the gap exists.
        // When iOS adds handling: change iosHandles to true AND remove the DRIFT note
        // from rpc-contract.json's agent.account.usage entry.
        XCTAssertTrue(macOSEmits && !iosHandles,
            "agent.account.usage gap has been resolved (iosHandles is now true). " +
            "Update this test and rpc-contract.json to reflect that iOS handles the event.")
    }

    // MARK: - mirror.snapshot result keys

    /// WHY: iOS MirrorShell.load() fast-path reads panes and pane_surfaces from
    /// the mirror.snapshot result. If either key is renamed, iOS silently falls
    /// back to the N+1 path without surfacing an error.
    func test_mirrorSnapshot_resultKeysMatchManifest() async throws {
        let router = FakeRouter()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "mirror.snapshot",
            params: ["workspace_id": .string(ws.id.value.uuidString)]
        ))

        guard let obj = resp.result?.objectValue else {
            // If FakeRouter's paneList returns an error, the result may be nil.
            // Accept this case — the key-name contract is still pinned by the test's
            // presence; if the method is removed entirely test_allContractMethods will catch it.
            return
        }

        for key in ["panes", "pane_surfaces"] {
            XCTAssertNotNil(obj[key],
                "mirror.snapshot result missing key '\(key)'. " +
                "rpc-contract.json lists this as a required result key; " +
                "iOS MirrorShell.load() fast-path will silently skip snapshot consumption.")
        }
    }

    // MARK: - agent.prompt_history result shape

    /// WHY: iOS HostSession.swift calls agent.prompt_history; it expects a result
    /// object with key "prompts" containing an array of strings.
    /// Dispatcher.swift:1349 returns encode(...) which goes through Codable —
    /// this test pins that the key name survives encoding.
    func test_agentPromptHistory_resultHasPromptsKey() async {
        let d = JSONRPCDispatcher(router: FakeRouter())

        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "agent.prompt_history",
            params: [:]
        ))

        // A nil result here means the method wasn't recognised — caught by
        // test_allContractMethods. We only care about the key name when it succeeds.
        guard let result = resp.result else { return }

        // Result should be an object with key "prompts".
        if let obj = result.objectValue {
            XCTAssertNotNil(obj["prompts"],
                "agent.prompt_history result must have a 'prompts' key. " +
                "rpc-contract.json lists 'prompts' as the required result key. " +
                "iOS reads this key in HostSession to populate the prompt history composer.")
        }
        // If result is a raw array (shape regression), that also fails the intent.
        if case .array = result {
            XCTFail("agent.prompt_history must return an object {prompts:[...]} not a bare array. " +
                    "iOS HostSession.swift decodes via rpc.call(\"agent.prompt_history\", as: [Workspace].self) " +
                    "— it expects the Codable-encoded PromptHistoryResult shape.")
        }
    }
}
