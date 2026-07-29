import XCTest
@testable import SocketServer

/// WHY: HTTP `/v1/rpc` and WebSocket JSON-RPC launch `dispatchRPC` in unstructured
/// Tasks. Without explicit priority, large snapshot/replay work can contend at the
/// same Swift scheduler priority as stop/input/control. These pure tests pin the
/// request-body classifier and priority mapping so bulk stays utility and
/// interactive/conservative stays userInitiated — scheduler admission only.
final class RPCDispatchPriorityTests: XCTestCase {

    // MARK: - Helpers

    private func data(_ utf8: String) -> Data {
        Data(utf8.utf8)
    }

    private func singleRPC(method: String, id: String = "1") -> Data {
        data(#"{"jsonrpc":"2.0","id":"\#(id)","method":"\#(method)","params":{}}"#)
    }

    private func batchRPC(_ methods: [String]) -> Data {
        let items = methods.enumerated().map { index, method in
            #"{"jsonrpc":"2.0","id":"\#(index)","method":"\#(method)","params":{}}"#
        }.joined(separator: ",")
        return data("[\(items)]")
    }

    // MARK: - Bulk classification

    /// WHY: Full `sync.snapshot` is the largest host-side RPC body path. If it
    /// classified interactive, utility demotion would never apply and stop/input
    /// Tasks would keep sharing default priority with multi-MB snapshot work.
    func test_classify_syncSnapshot_isBulk() {
        let body = singleRPC(method: "sync.snapshot")
        XCTAssertEqual(RPCDispatchSchedulerClass.classify(bodyData: body), .bulk)
    }

    /// WHY: Chunked snapshot begin/chunk/commit are the resumable bulk surface.
    /// Misclassifying any leg as interactive would pin long transfers at
    /// userInitiated and reintroduce the contention this admission exists to cut.
    func test_classify_syncSnapshotChunkFamily_isBulk() {
        for method in [
            "sync.snapshot.begin",
            "sync.snapshot.chunk",
            "sync.snapshot.commit",
        ] {
            let body = singleRPC(method: method)
            XCTAssertEqual(
                RPCDispatchSchedulerClass.classify(bodyData: body),
                .bulk,
                "\(method) is read-only bulk snapshot work and must demote"
            )
        }
    }

    /// WHY: `events.recent` is catch-up/replay volume on the same path as live
    /// control. Classifying it interactive would keep gap replay competing with
    /// stop at userInitiated priority on the host.
    func test_classify_eventsRecent_isBulk() {
        let body = singleRPC(method: "events.recent")
        XCTAssertEqual(RPCDispatchSchedulerClass.classify(bodyData: body), .bulk)
    }

    /// WHY: Clients batch multiple snapshot legs in one HTTP body. A snapshot-only
    /// batch must stay bulk so the whole admit unit demotes; otherwise one bulk
    /// method plus another bulk method would wrongly escalate to interactive.
    func test_classify_snapshotOnlyBatch_isBulk() {
        let body = batchRPC([
            "sync.snapshot.begin",
            "sync.snapshot.chunk",
            "events.recent",
        ])
        XCTAssertEqual(RPCDispatchSchedulerClass.classify(bodyData: body), .bulk)
    }

    // MARK: - Interactive / conservative classification

    /// WHY: A mixed batch that includes stop/input must never demote. If any
    /// interactive item were ignored, stop could ride a bulk Task and lose to
    /// concurrent snapshot work — the failure mode this classifier prevents.
    func test_classify_mixedBatch_isInteractive() {
        let body = batchRPC([
            "sync.snapshot",
            "agent.run.stop",
        ])
        XCTAssertEqual(
            RPCDispatchSchedulerClass.classify(bodyData: body),
            .interactive,
            "any non-bulk item in a batch must force interactive priority"
        )
    }

    /// WHY: Mutations change host state and must outrun bulk catch-up. Treating
    /// them as utility would let snapshot Tasks starve writes users just issued.
    func test_classify_mutation_isInteractive() {
        let body = singleRPC(method: "agent.message.send")
        XCTAssertEqual(RPCDispatchSchedulerClass.classify(bodyData: body), .interactive)
    }

    /// WHY: Malformed bodies still need a dispatch Task (parseError response).
    /// Conservative interactive priority ensures error handling is not deferred
    /// behind bulk snapshot work and cannot be gamed into utility demotion.
    func test_classify_malformedBody_isInteractive() {
        let bodies: [Data] = [
            data("not json"),
            data(""),
            data("null"),
            data("42"),
            data("[]"),
            data(#"{"jsonrpc":"2.0","id":"1"}"#), // missing method
        ]
        for body in bodies {
            XCTAssertEqual(
                RPCDispatchSchedulerClass.classify(bodyData: body),
                .interactive,
                "malformed/unknown shape must classify interactive/conservative"
            )
        }
    }

    /// WHY: Stop and user-input are the interactive control surface that must
    /// remain responsive while snapshots run. If they classified bulk, the
    /// priority fix would invert and make stop/input slower under load.
    func test_classify_stopAndUserInput_isInteractive() {
        for method in [
            "agent.run.stop",
            "agent.user_input.respond",
            "agent.request.respond",
            "agent.message.queue.cancel",
        ] {
            let body = singleRPC(method: method)
            XCTAssertEqual(
                RPCDispatchSchedulerClass.classify(bodyData: body),
                .interactive,
                "\(method) is stop/input/control and must stay interactive"
            )
        }
    }

    // MARK: - Priority mapping

    /// WHY: Admission only helps if bulk maps to a lower Task priority than
    /// interactive. Pin the exact Swift priorities the HTTP/WS launch sites use.
    func test_taskPriority_bulkIsUtility_interactiveIsUserInitiated() {
        XCTAssertEqual(RPCDispatchSchedulerClass.bulk.taskPriority, .utility)
        XCTAssertEqual(RPCDispatchSchedulerClass.interactive.taskPriority, .userInitiated)

        let bulkBody = singleRPC(method: "sync.snapshot")
        let interactiveBody = singleRPC(method: "agent.run.stop")
        XCTAssertEqual(
            RPCDispatchSchedulerClass.taskPriority(for: bulkBody),
            .utility,
            "snapshot body must launch at utility so control can preempt"
        )
        XCTAssertEqual(
            RPCDispatchSchedulerClass.taskPriority(for: interactiveBody),
            .userInitiated,
            "stop body must launch at userInitiated"
        )
        XCTAssertEqual(
            DirectHTTPServer.rpcDispatchTaskPriority(for: bulkBody),
            .utility
        )
        XCTAssertEqual(
            DirectHTTPServer.rpcDispatchTaskPriority(for: interactiveBody),
            .userInitiated
        )
    }

    /// WHY: The bulk method set is the allowlist for demotion. Drift here would
    /// silently change which RPCs get utility priority without a test failure.
    func test_bulkMethods_matchesAcceptanceAllowlist() {
        XCTAssertEqual(
            RPCDispatchSchedulerClass.bulkMethods,
            [
                "sync.snapshot",
                "sync.snapshot.begin",
                "sync.snapshot.chunk",
                "sync.snapshot.commit",
                "events.recent",
            ]
        )
    }
}
