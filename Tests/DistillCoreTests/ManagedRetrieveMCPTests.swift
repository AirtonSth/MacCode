import XCTest
@testable import DistillCore

final class ManagedRetrieveMCPTests: XCTestCase {
    private func server(_ map: [String: String] = [:], scoped: Bool = false) -> ManagedRetrieveMCP {
        ManagedRetrieveMCP(
            retrieve: { handle in map[handle] },
            stats: { DistillStatsSnapshot(totalSavedTokens: 120, totalRuns: 3) },
            compress: { request in
                DistillResponse(
                    requestID: request.id,
                    output: "compressed",
                    inputCharacters: request.input.count,
                    inputTokens: 100,
                    outputTokens: 10,
                    originalHandle: "mcp-h",
                    routeStage: .deterministic
                )
            },
            scopedRecoveryAvailable: scoped
        )
    }
    private func parse(_ s: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(s?.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_initialize() async throws {
        let obj = try parse(await server().handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        XCTAssertEqual(obj["id"] as? Int, 1)
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertNotNil(result["serverInfo"])
        XCTAssertNotNil(result["capabilities"])
    }

    func test_toolsListExposesOnlyNonRecoveryStatsUntilScopedCapabilitiesExist() async throws {
        let obj = try parse(await server().handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((obj["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["rc_stats"])
    }

    func test_unscopedRetrieveToolIsRejectedEvenWhenLegacyClosureCanReturnOriginal() async throws {
        let obj = try parse(await server(["abc": "the original bytes"]).handle(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rc_retrieve","arguments":{"handle":"abc"}}}"#))
        XCTAssertNotNil(obj["error"])
    }

    func test_scopedToolsAdvertiseAndRetrieveCapability() async throws {
        let srv = server(["rcv1.capability": "exact original"], scoped: true)
        let listed = try parse(await srv.handle(#"{"jsonrpc":"2.0","id":20,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["rc_stats", "rc_retrieve", "rc_search", "rc_compress"])

        let called = try parse(await srv.handle(
            #"{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"rc_retrieve","arguments":{"handle":"rcv1.capability"}}}"#
        ))
        let result = try XCTUnwrap(called["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "exact original")
        XCTAssertEqual(result["isError"] as? Bool, false)
    }

    func test_toolsCallUnavailableIsErrorResult() async throws {
        let obj = try parse(await server().handle(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"rc_retrieve","arguments":{"handle":"nope"}}}"#))
        XCTAssertNotNil(obj["error"], "unscoped recovery is unavailable, never a crash")
    }

    func test_wrongToolIsRejected() async throws {
        let obj = try parse(await server().handle(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rc_delete","arguments":{}}}"#))
        XCTAssertNotNil(obj["error"], "only retrieve/search/stats/net-positive compress tools are exposed")
    }

    func test_unscopedSearchToolIsRejected() async throws {
        let index = CCRSearchIndex(records: [
            CCRSearchRecord(handle: "h1", text: "INFO ok"),
            CCRSearchRecord(handle: "h2", text: "ERROR payment failed at Sources/Billing.swift:12")
        ])
        let srv = ManagedRetrieveMCP(retrieve: { _ in nil }, search: { query, topK in index.search(query, topK: topK) })
        let obj = try parse(await srv.handle(
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"rc_search","arguments":{"query":"payment error","topK":1}}}"#))
        XCTAssertNotNil(obj["error"])
    }

    func test_statsToolReturnsSavingsSnapshot() async throws {
        let obj = try parse(await server().handle(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"rc_stats","arguments":{}}}"#))
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertTrue(text.contains(#""total_saved_tokens":120"#))
        XCTAssertEqual(result["isError"] as? Bool, false)
    }

    func test_unscopedCompressToolIsRejectedBeforeItCanEmitRawHandle() async throws {
        let obj = try parse(await server().handle(
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"rc_compress","arguments":{"input":"large output","question":"keep errors","estimatedInputTokens":1000,"toolRoundTripTokens":40}}}"#))
        XCTAssertNotNil(obj["error"])
    }

    func test_compressToolSkipsWhenRoundTripWouldCostMoreThanSavings() async throws {
        let obj = try parse(await server().handle(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"rc_compress","arguments":{"input":"small","question":"keep errors","estimatedInputTokens":20,"toolRoundTripTokens":200}}}"#))
        XCTAssertNotNil(obj["error"])
    }

    func test_notificationGetsNoResponse() async {
        let response = await server().handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(response)
    }

    func test_unknownMethodErrors() async throws {
        let obj = try parse(await server().handle(#"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#))
        XCTAssertNotNil(obj["error"])
    }

    // End-to-end: the real binary in `mcp` mode speaks JSON-RPC over stdio.
    func test_realBinaryMcpModeSpeaksJSONRPC() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            ".build/debug/RemoteCodeDistillService",
            ".build/arm64-apple-macosx/debug/RemoteCodeDistillService",
        ].map { URL(fileURLWithPath: cwd).appendingPathComponent($0) }
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp"]
        // No state file => retrieve is unavailable, but init/list/call must still answer.
        var env = ProcessInfo.processInfo.environment
        env["REMOTE_CODE_DISTILL_STATE_PATH"] = "/nonexistent/\(UUID().uuidString).json"
        process.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe; process.standardOutput = outPipe; process.standardError = Pipe()
        try process.run()
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ].joined(separator: "\n") + "\n"
        inPipe.fileHandleForWriting.write(Data(requests.utf8))
        inPipe.fileHandleForWriting.closeFile()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2, "init + tools/list each return a line; got: \(out)")
        XCTAssertTrue(out.contains("\"serverInfo\""), "initialize answered")
        XCTAssertFalse(out.contains("rc_retrieve"), "unscoped recovery is not advertised")
        XCTAssertTrue(out.contains("rc_stats"), "tools/list exposes rc_stats")
        XCTAssertFalse(out.contains("rc_compress"), "unscoped lossy compression is not advertised")
    }
}
