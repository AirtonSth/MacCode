import XCTest
@testable import DistillCore

final class ManagedRetrieveMCPTests: XCTestCase {
    private func server(_ map: [String: String] = [:]) -> ManagedRetrieveMCP {
        ManagedRetrieveMCP { handle in map[handle] }
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

    func test_toolsListExposesRetrieveOnly() async throws {
        let obj = try parse(await server().handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((obj["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["rc_retrieve", "rc_search"])
        XCTAssertFalse(tools.contains { ($0["name"] as? String) == "rc_compress" }, "read-only MCP: no compress tool")
    }

    func test_toolsCallReturnsOriginal() async throws {
        let obj = try parse(await server(["abc": "the original bytes"]).handle(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rc_retrieve","arguments":{"handle":"abc"}}}"#))
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["text"] as? String, "the original bytes")
        XCTAssertEqual(result["isError"] as? Bool, false)
    }

    func test_toolsCallUnavailableIsErrorResult() async throws {
        let obj = try parse(await server().handle(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"rc_retrieve","arguments":{"handle":"nope"}}}"#))
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true, "missing original => isError true, never a crash")
    }

    func test_wrongToolIsRejected() async throws {
        let obj = try parse(await server().handle(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rc_compress","arguments":{}}}"#))
        XCTAssertNotNil(obj["error"], "only read-only retrieve/search tools are exposed; no compress tool")
    }

    func test_searchToolReturnsReadOnlyHandles() async throws {
        let index = CCRSearchIndex(records: [
            CCRSearchRecord(handle: "h1", text: "INFO ok"),
            CCRSearchRecord(handle: "h2", text: "ERROR payment failed at Sources/Billing.swift:12")
        ])
        let srv = ManagedRetrieveMCP(retrieve: { _ in nil }, search: { query, topK in index.search(query, topK: topK) })
        let obj = try parse(await srv.handle(
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"rc_search","arguments":{"query":"payment error","topK":1}}}"#))
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertTrue(text.contains(#""handle":"h2""#))
        XCTAssertFalse(text.contains("ERROR payment failed at Sources/Billing.swift:12\"}"), "search returns excerpts/handles, not full originals")
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
        XCTAssertTrue(out.contains("rc_retrieve"), "tools/list exposes rc_retrieve")
    }
}
