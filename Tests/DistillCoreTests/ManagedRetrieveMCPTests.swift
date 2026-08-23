import CryptoKit
import CoreModel
import Persistence
import XCTest
@testable import DistillCore

final class ManagedRetrieveMCPTests: XCTestCase {
    private let rootRunID = "123e4567-e89b-12d3-a456-426614174000"
    private let receiptKey = Data(repeating: 0x5a, count: 32)

    private actor RequestRecorder {
        private var requests: [DistillRequest] = []

        func append(_ request: DistillRequest) {
            requests.append(request)
        }

        func all() -> [DistillRequest] {
            requests
        }
    }

    private actor AskRecorder {
        private var ops: [String] = []

        func answer(op: String) -> String {
            ops.append(op)
            return "answered:\(op)"
        }

        func all() -> [String] {
            ops
        }
    }

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
                    recoveryIdempotencyKey: "mcp-op",
                    routeStage: .deterministic
                )
            },
            scopedRecoveryAvailable: scoped,
            rootRunID: scoped ? rootRunID : nil,
            receiptKey: scoped ? receiptKey : nil,
            distillAdmission: { true }
        )
    }
    private func parse(_ s: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(s?.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func callLine(id: Int, name: String, arguments: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func toolText(_ response: [String: Any]) throws -> String {
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    private func catalogPage(_ response: [String: Any]) throws -> [String: Any] {
        let text = try toolText(response)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }

    func test_initialize() async throws {
        let obj = try parse(await server().handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        XCTAssertEqual(obj["id"] as? Int, 1)
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertNotNil(result["serverInfo"])
        XCTAssertNotNil(result["capabilities"])
    }

    func test_toolsListExposesOnlyNonRecoveryStatsUntilScopedCapabilitiesExist() async throws {
        let srv = server()
        let firstLine = await srv.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let secondLine = await srv.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        XCTAssertEqual(firstLine, secondLine, "tools/list must be byte-stable for the same capability scope")
        let obj = try parse(firstLine)
        let tools = try XCTUnwrap((obj["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["rc_stats", "rc_search", "rc_catalog", "rc_ask"])
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
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["rc_stats", "rc_search", "rc_catalog", "rc_ask", "rc_retrieve", "rc_compress"])

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

    func test_unscopedSearchToolReturnsHits() async throws {
        let index = CCRSearchIndex(records: [
            CCRSearchRecord(handle: "h1", text: "INFO ok"),
            CCRSearchRecord(handle: "h2", text: "ERROR payment failed at Sources/Billing.swift:12")
        ])
        let srv = ManagedRetrieveMCP(retrieve: { _ in nil }, search: { query, topK in index.search(query, topK: topK) })
        let obj = try parse(await srv.handle(
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"rc_search","arguments":{"query":"payment error","topK":1}}}"#))
        XCTAssertNil(obj["error"])
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
    }

    func test_rcAskRunsCatalogOpOnLocalDispatcher() async throws {
        let listed = try parse(await server().handle(#"{"jsonrpc":"2.0","id":40,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let ask = try XCTUnwrap(tools.first { ($0["name"] as? String) == "rc_ask" })
        let schema = try XCTUnwrap(ask["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let op = try XCTUnwrap(properties["op"] as? [String: Any])
        XCTAssertEqual(op["type"] as? String, "string")
        XCTAssertNil(op["enum"], "the 168-id catalog must be discovered just in time via rc_catalog")
        let description = try XCTUnwrap(op["description"] as? String)
        for id in LibrarianCatalog.hotHintIDs {
            XCTAssertTrue(description.contains(id), "missing hot hint \(id)")
        }
        XCTAssertEqual(LibrarianCatalog.hotHintIDs.count, 8)
        XCTAssertTrue(description.contains("rc_catalog"))

        let original = String(repeating: "ERROR payment failed\n", count: 40)
        let escaped = original.replacingOccurrences(of: "\n", with: "\\n")
        let called = try parse(await server().handle(
            #"{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"rc_ask","arguments":{"op":"log_crusher","input":"\#(escaped)"}}}"#
        ))
        let result = try XCTUnwrap(called["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("log_crusher") || text.contains("[[rc:"), text)
        XCTAssertEqual(result["isError"] as? Bool, false)
    }

    func test_rcCatalogSchemaAndPagesReachEveryCallableOp() async throws {
        let srv = server()
        let listed = try parse(await srv.handle(#"{"jsonrpc":"2.0","id":42,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let catalog = try XCTUnwrap(tools.first { ($0["name"] as? String) == "rc_catalog" })
        let schema = try XCTUnwrap(catalog["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let limit = try XCTUnwrap(properties["limit"] as? [String: Any])
        XCTAssertEqual(limit["minimum"] as? Int, 1)
        XCTAssertEqual(limit["maximum"] as? Int, 20)
        XCTAssertNil(schema["required"], "query, cursor, and limit are all optional")

        var cursor: String?
        var ids: [String] = []
        repeat {
            var arguments: [String: Any] = ["limit": 13]
            if let cursor { arguments["cursor"] = cursor }
            let line = try callLine(id: 43, name: "rc_catalog", arguments: arguments)
            let page = try catalogPage(try parse(await srv.handle(line)))
            let items = try XCTUnwrap(page["items"] as? [[String: Any]])
            ids.append(contentsOf: items.compactMap { $0["id"] as? String })
            cursor = page["nextCursor"] as? String
        } while cursor != nil

        XCTAssertEqual(ids, LibrarianCatalog.implementedIDs)
        XCTAssertEqual(Set(ids).count, 168)
        XCTAssertTrue(Set(ids).isDisjoint(with: LibrarianCatalog.forbiddenIDs))
        XCTAssertTrue(Set(ids).isDisjoint(with: LibrarianCatalog.disabledOnNineB))
    }

    func test_rcCatalogSearchAndInvalidCursorFailClosed() async throws {
        let srv = server()
        let exactLine = try callLine(
            id: 44,
            name: "rc_catalog",
            arguments: ["query": "test_verdict", "limit": 20]
        )
        let exact = try catalogPage(try parse(await srv.handle(exactLine)))
        let exactItems = try XCTUnwrap(exact["items"] as? [[String: Any]])
        XCTAssertEqual(exactItems.first?["id"] as? String, "test_verdict")

        let summaryLine = try callLine(
            id: 45,
            name: "rc_catalog",
            arguments: ["query": "Ledger stats", "limit": 20]
        )
        let summary = try catalogPage(try parse(await srv.handle(summaryLine)))
        let summaryItems = try XCTUnwrap(summary["items"] as? [[String: Any]])
        XCTAssertTrue(summaryItems.contains { ($0["id"] as? String) == "stats" })

        for hidden in ["apply_patch", "i18n_translation_draft"] {
            let line = try callLine(id: 46, name: "rc_catalog", arguments: ["query": hidden])
            let page = try catalogPage(try parse(await srv.handle(line)))
            XCTAssertEqual((page["items"] as? [[String: Any]])?.count, 0, hidden)
        }

        let invalid = try parse(await srv.handle(try callLine(
            id: 47,
            name: "rc_catalog",
            arguments: ["cursor": "not-a-cursor", "limit": 7]
        )))
        XCTAssertEqual((invalid["error"] as? [String: Any])?["code"] as? Int, -32602)

        let first = try catalogPage(try parse(await srv.handle(try callLine(
            id: 48,
            name: "rc_catalog",
            arguments: ["query": "handle", "limit": 1]
        ))))
        let boundCursor = try XCTUnwrap(first["nextCursor"] as? String)
        let mismatched = try parse(await srv.handle(try callLine(
            id: 49,
            name: "rc_catalog",
            arguments: ["query": "test", "cursor": boundCursor, "limit": 1]
        )))
        XCTAssertEqual((mismatched["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func test_rcCatalogAndUnknownOpNeverCallGenerate() async throws {
        let recorder = AskRecorder()
        let srv = ManagedRetrieveMCP(
            retrieve: { _ in nil },
            ask: { op, _, _, _ in await recorder.answer(op: op) }
        )

        _ = try parse(await srv.handle(try callLine(
            id: 50,
            name: "rc_catalog",
            arguments: ["query": "test", "limit": 3]
        )))
        let unknown = try parse(await srv.handle(try callLine(
            id: 51,
            name: "rc_ask",
            arguments: ["op": "not_in_the_catalog"]
        )))

        let recorded = await recorder.all()
        XCTAssertEqual(recorded, [])
        XCTAssertEqual((unknown["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func test_everyDiscoveredCatalogOpRoundTripsThroughRcAsk() async throws {
        let recorder = AskRecorder()
        let srv = ManagedRetrieveMCP(
            retrieve: { _ in nil },
            ask: { op, _, _, _ in await recorder.answer(op: op) }
        )

        for (offset, op) in LibrarianCatalog.implementedIDs.enumerated() {
            let response = try parse(await srv.handle(try callLine(
                id: 1_000 + offset,
                name: "rc_ask",
                arguments: ["op": op]
            )))
            XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, false, op)
        }
        let recorded = await recorder.all()
        XCTAssertEqual(recorded, LibrarianCatalog.implementedIDs)
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

    func test_unscopedCompressToolFailsOpenWithRawInput() async throws {
        let obj = try parse(await server().handle(
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"rc_compress","arguments":{"input":"large output","question":"keep errors","estimatedInputTokens":1000,"toolRoundTripTokens":40}}}"#))
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "large output")
        XCTAssertEqual(result["isError"] as? Bool, false)
    }

    func test_scopedCompressWithoutTrustedReceiptFailsOpenBeforeCallingCandidate() async throws {
        // WHY: recovery scope alone is not authority to emit lossy bytes. A stale MCP
        // process without the active root receipt must return the exact input untouched.
        let recorder = RequestRecorder()
        let input = String(repeating: "raw provider output\n", count: 80)
        let srv = ManagedRetrieveMCP(
            retrieve: { _ in nil },
            compress: { request in
                await recorder.append(request)
                return DistillResponse(
                    requestID: request.id,
                    output: "compressed",
                    inputCharacters: request.input.count,
                    originalHandle: "mcp-h",
                    routeStage: .deterministic
                )
            },
            scopedRecoveryAvailable: true
        )
        let escaped = input.replacingOccurrences(of: "\n", with: "\\n")
        let obj = try parse(await srv.handle(
            #"{"jsonrpc":"2.0","id":81,"method":"tools/call","params":{"name":"rc_compress","arguments":{"input":"\#(escaped)","estimatedInputTokens":2000,"toolRoundTripTokens":40}}}"#
        ))
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let requests = await recorder.all()

        XCTAssertEqual(content.first?["text"] as? String, input)
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertTrue(requests.isEmpty, "untrusted MCP must not submit a compression candidate")
    }

    func test_compressToolFailsOpenWhenRoundTripWouldCostMoreThanSavings() async throws {
        let obj = try parse(await server(scoped: true).handle(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"rc_compress","arguments":{"input":"small","question":"keep errors","estimatedInputTokens":20,"toolRoundTripTokens":200}}}"#))
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "small")
        XCTAssertEqual(result["isError"] as? Bool, false)
    }

    func test_trustedCompressDefersExactDeliveredLedgerUntilAfterResponseWrite() async throws {
        // WHY: the candidate must not claim savings. Only receipt-inclusive bytes that
        // survived every trust/recovery/net-shrink gate may enter the ledger after write.
        let recorder = RequestRecorder()
        let input = String(repeating: #"{"status":"ok","detail":"repeated"}"#, count: 80)
        let srv = ManagedRetrieveMCP(
            retrieve: { _ in nil },
            compress: { request in
                await recorder.append(request)
                return DistillResponse(
                    requestID: request.id,
                    output: #"{"status":"ok"}"#,
                    inputCharacters: request.input.count,
                    originalHandle: "mcp-h",
                    recoveryIdempotencyKey: "mcp-op",
                    routeStage: .encoderBERT
                )
            },
            scopedRecoveryAvailable: true,
            rootRunID: rootRunID,
            receiptKey: receiptKey,
            distillAdmission: { true }
        )
        let escaped = input.replacingOccurrences(of: "\"", with: "\\\"")
        let outcome = await srv.handleForDelivery(
            #"{"jsonrpc":"2.0","id":82,"method":"tools/call","params":{"name":"rc_compress","arguments":{"input":"\#(escaped)","provider":"codex","estimatedInputTokens":3000,"toolRoundTripTokens":40}}}"#
        )
        let obj = try parse(outcome.response)
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let emitted = Data(text.utf8)
        let receipt = try XCTUnwrap(DistillAppliedReceipt.parseTrailingV2Marker(in: emitted))
        let signedPrefix = Data(emitted.prefix(receipt.markerByteRange.lowerBound))
        let requestsBeforeDelivery = await recorder.all()

        XCTAssertEqual(Set(result.keys), ["content", "isError"])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertTrue(text.contains("[[rc:mcp-h]]"))
        XCTAssertLessThan(emitted.count, Data(input.utf8).count)
        XCTAssertTrue(DistillAppliedReceipt.verify(
            receipt,
            rootRunID: rootRunID,
            payloadByteCount: signedPrefix.count,
            payloadSHA256: Data(SHA256.hash(data: signedPrefix)),
            key: receiptKey
        ))
        let jsonPrefix = try XCTUnwrap(text.components(separatedBy: "\n[[rc:mcp-h]]").first)
        let decodedPrefix = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(jsonPrefix.utf8)) as? [String: Any]
        )
        XCTAssertEqual(decodedPrefix["status"] as? String, "ok")
        XCTAssertEqual(requestsBeforeDelivery.count, 1, "ledger must not run before the response is written")
        XCTAssertEqual(requestsBeforeDelivery.first?.recordSavings, false)
        XCTAssertNil(requestsBeforeDelivery.first?.precomputedOutput)

        let deferred = try XCTUnwrap(outcome.deferredSideEffect)
        await deferred()
        let requestsAfterDelivery = await recorder.all()
        XCTAssertEqual(requestsAfterDelivery.count, 2)
        let ledger = try XCTUnwrap(requestsAfterDelivery.last)
        XCTAssertEqual(ledger.recordSavings, true)
        XCTAssertEqual(ledger.input, input)
        XCTAssertEqual(ledger.precomputedOutput, text)
        XCTAssertEqual(ledger.precomputedRouteStage, .encoderBERT)
        XCTAssertEqual(
            ledger.precomputedRecoveryConfirmations,
            [.init(capability: "mcp-h", idempotencyKey: "mcp-op")]
        )
    }

    func test_trustedCompressFailsOpenWhenReceiptAndHandleEraseNetSavings() async throws {
        let recorder = RequestRecorder()
        let input = String(repeating: "x", count: 128)
        let srv = ManagedRetrieveMCP(
            retrieve: { _ in nil },
            compress: { request in
                await recorder.append(request)
                return DistillResponse(
                    requestID: request.id,
                    output: String(repeating: "x", count: 100),
                    inputCharacters: request.input.count,
                    originalHandle: "mcp-h",
                    recoveryIdempotencyKey: "mcp-op",
                    routeStage: .deterministic
                )
            },
            scopedRecoveryAvailable: true,
            rootRunID: rootRunID,
            receiptKey: receiptKey,
            distillAdmission: { true }
        )
        let outcome = await srv.handleForDelivery(
            #"{"jsonrpc":"2.0","id":83,"method":"tools/call","params":{"name":"rc_compress","arguments":{"input":"\#(input)","estimatedInputTokens":1000,"toolRoundTripTokens":40}}}"#
        )
        let obj = try parse(outcome.response)
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])

        XCTAssertEqual(content.first?["text"] as? String, input)
        XCTAssertNil(outcome.deferredSideEffect)
        let requests = await recorder.all()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.recordSavings, false)
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

    func test_realBinaryMcpRejectsWorldReadableReceiptState() throws {
        // WHY: the receipt verifier refuses secrets exposed to group/other users.
        // The producer must fail open under the identical permission boundary.
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            ".build/debug/RemoteCodeDistillService",
            ".build/arm64-apple-macosx/debug/RemoteCodeDistillService",
        ].map { URL(fileURLWithPath: cwd).appendingPathComponent($0) }
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mcp-world-readable-state-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        SettingsStore(db: db).update { $0.tokenSaverEnabled = true }
        try SettingsRepository(db: db).set(
            "private.account.session",
            #"{"user":{"subscribed":true}}"#
        )
        let stateURL = support
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: [
            "base_url": "http://127.0.0.1:1",
            "auth_token": "test-token",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "receipt_key": try XCTUnwrap(DistillAppliedReceipt.encodeReceiptKey(receiptKey)),
        ]).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: stateURL.path
        )

        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment.merge([
            "REMOTE_CODE_DISTILL_STATE_PATH": stateURL.path,
            "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace",
            "RC_TOKEN_SAVER_PROJECT_ID": "project",
            "RC_TOKEN_SAVER_THREAD_ID": "thread",
            "REMOTE_CODE_AGENT_PROVIDER": "codex",
            "RC_TOKEN_SAVER_ATTEMPT_ID": "attempt",
            "RC_TOKEN_SAVER_ROOT_RUN_ID": rootRunID,
        ]) { _, replacement in replacement }
        process.environment = environment
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try process.run()
        inPipe.fileHandleForWriting.write(Data(
            (#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"# + "\n").utf8
        ))
        inPipe.fileHandleForWriting.closeFile()
        let output = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let listed = try parse(output.trimmingCharacters(in: .whitespacesAndNewlines))
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertFalse(
            tools.contains { ($0["name"] as? String) == "rc_compress" },
            "world-readable receipt state must disable lossy MCP compression"
        )
    }
}
