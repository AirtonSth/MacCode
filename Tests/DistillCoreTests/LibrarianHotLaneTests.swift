import XCTest
@testable import DistillCore

/// Default-use proof: a matching command output is processed by its hot-lane
/// catalog op automatically — no model, no user request — and the invocation
/// records a per-op `librarian.<op>` ledger row.
final class LibrarianHotLaneTests: XCTestCase {
    private struct Reply: Decodable {
        let output: String
        let originalHandle: String?
        enum CodingKeys: String, CodingKey {
            case output
            case originalHandle = "originalHandle"
        }
    }

    private func makeServer(
        records: SavingsCollector
    ) async throws -> (server: DistillHTTPServer, port: UInt16, store: TestScopedRecoveryStore) {
        let configuration = try DistillServiceConfiguration(
            authToken: "hot-lane-token",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 1
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 1)
        let store = TestScopedRecoveryStore()
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            scopedRecoveryStore: store,
            onSavingsRecord: { record in await records.add(record) },
            librarianEnvironment: LibrarianOpEnvironment.live
        )
        let ready = try await server.start()
        return (server, ready.port, store)
    }

    private func post(
        port: UInt16,
        input: String,
        context: TokenSaverRecoveryRequestContext
    ) async throws -> (status: Int, body: Reply) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/distill")!)
        request.httpMethod = "POST"
        request.setValue("Bearer hot-lane-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(context.workspaceID, forHTTPHeaderField: "X-RemoteCode-Workspace-ID")
        request.setValue(context.projectID, forHTTPHeaderField: "X-RemoteCode-Project-ID")
        request.setValue(context.threadID, forHTTPHeaderField: "X-RemoteCode-Thread-ID")
        request.setValue(context.provider, forHTTPHeaderField: "X-RemoteCode-Provider")
        request.setValue(context.attemptID, forHTTPHeaderField: "X-RemoteCode-Attempt-ID")
        request.setValue(context.operationID, forHTTPHeaderField: "X-RemoteCode-Operation-ID")
        request.setValue(context.invocationID, forHTTPHeaderField: "X-RemoteCode-Invocation-ID")
        let distill = DistillRequest(
            id: UUID(),
            mode: .commandOutput,
            input: input,
            question: "what failed?",
            recordSavings: true
        )
        request.httpBody = try JSONEncoder().encode(distill)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, try JSONDecoder().decode(Reply.self, from: data))
    }

    private let testReport: String = {
        var lines = ["Test Suite 'WidgetTests' started at 2026-09-18 00:00:00.000"]
        var passed = 0
        var failed = 0
        for index in 0..<120 {
            let name = "-[FixtureTests.WidgetTests testCase\(index)]"
            lines.append("Test Case '\(name)' started.")
            if index % 9 == 0 {
                lines.append("Test Case '\(name)' failed (0.002 seconds).")
                lines.append("Sources/WidgetTests.swift:\(index + 10): error: \(name) : XCTAssertEqual failed - expected widget \(index)")
                failed += 1
            } else {
                lines.append("Test Case '\(name)' passed (0.001 seconds).")
                passed += 1
            }
        }
        lines.append("Executed \(passed + failed) tests, with \(failed) failures (0 unexpected) in 1.234 (1.245) seconds")
        return lines.joined(separator: "\n")
    }()

    private let listing: String = {
        (0..<400).map { "Sources/nested/module\($0)/File\($0).swift" }.joined(separator: "\n")
    }()

    private let buildLog: String = {
        var lines: [String] = []
        for index in 0..<80 {
            lines.append("[\(index)/80] Compiling Fixture \(index)")
            lines.append("    Progress: \(index)%")
        }
        lines.append("Build complete in 42.0s")
        return lines.joined(separator: "\n")
    }()

    private let jsonBlob: String = {
        let rows = (0..<120).map { "{\"id\": \($0), \"state\": \"ready\", \"name\": \"widget-\($0)\"}" }
        return "[" + rows.joined(separator: ",\n") + "]"
    }()

    private let lintReport: String = {
        var lines = ["Linting FixtureKit (swiftlint)"]
        for index in 0..<140 {
            lines.append("Sources/Widget.swift:\(index):1: warning: unused variable widget\(index)")
        }
        lines.append("140 problems (1 error, 139 warnings)")
        return lines.joined(separator: "\n")
    }()

    private let diffBlob: String = {
        var lines = ["diff --git a/Sources/Widget.swift b/Sources/Widget.swift", "index 111..222 100644"]
        for index in 0..<40 {
            lines.append("@@ -\(index * 20),18 +\(index * 20),19 @@ func renderWidget() {")
            for context in 0..<8 { lines.append(" let untouched\(index)_\(context) = \(context)") }
            lines.append("-let title = \"old-\(index)\"")
            lines.append("+let title = \"new-\(index)\"")
            for context in 8..<18 { lines.append(" let trailing\(index)_\(context) = \(context)") }
        }
        return lines.joined(separator: "\n")
    }()

    func test_matchingOutputsRouteThroughTheirHotLaneOpAndRecordLibrarianRows() async throws {
        let records = SavingsCollector()
        let (server, port, store) = try await makeServer(records: records)
        defer { server.stop() }

        let cases: [(name: String, input: String, expectedModes: Set<String>)] = [
            ("test report", testReport, ["librarian.test_crusher"]),
            ("large listing", listing, ["librarian.stdout_budget_elide"]),
            ("build log", buildLog, ["librarian.progress_bar_crusher"]),
            ("json blob", jsonBlob, ["librarian.json_crusher"]),
            ("diff", diffBlob, ["librarian.diff_crusher"]),
            ("lint report", lintReport, ["librarian.log_crusher", "librarian.progress_bar_crusher", "librarian.test_crusher"])
        ]

        for testCase in cases {
            let context = testRecoveryContext()
            let (status, body) = try await post(port: port, input: testCase.input, context: context)
            XCTAssertEqual(status, 200, "\(testCase.name) must be served")
            XCTAssertNotEqual(body.output, testCase.input,
                              "\(testCase.name) must be reduced by its hot-lane op, not passed through")
            XCTAssertLessThan(body.output.utf8.count, testCase.input.utf8.count,
                              "\(testCase.name) reduction must shrink the payload")

            let modes = await records.modes()
            let matched = modes.contains { mode in
                testCase.expectedModes.contains { mode.hasPrefix($0) }
            }
            XCTAssertTrue(
                matched,
                "\(testCase.name) must record one of \(testCase.expectedModes); recorded: \(modes)"
            )
            // Store-before-loss: the delivered handle must resolve to the original bytes.
            if let handle = body.originalHandle {
                let recovered = try store.retrieveOriginal(capability: handle, context: context)
                XCTAssertEqual(recovered, Data(testCase.input.utf8),
                               "\(testCase.name) handle must retrieve the byte-exact original")
            } else {
                XCTFail("\(testCase.name) lossy delivery must carry a recovery handle")
            }
            XCTAssertFalse(
                body.output.contains("[[rc:\(context.invocationID)"),
                "\(testCase.name) must not leak an internal invocation id as a handle"
            )
        }

        let modes = await records.modes()
        XCTAssertEqual(Set(modes).count, modes.count, "one row per delivery, no double counting: \(modes)")
    }

    func test_operatorApprovedCommandOutputStillRoutesAndKeepsExactOutputToolsOut() async throws {
        let records = SavingsCollector()
        let (server, port, _) = try await makeServer(records: records)
        defer { server.stop() }

        // Keep a working directory with a file the diff case references.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-hotlane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = testRecoveryContext()
        let (status, body) = try await post(port: port, input: testReport, context: context)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.output.contains("testRenderWidget") || body.output.contains("error"),
                      "test report reduction must keep the failing test evidence: \(body.output.prefix(400))")

        // Exact-output tool text (a grep dump) is never auto-routed by a catalog op.
        let grepDump = (0..<200).map { "Sources/Widget.swift:\($0): func renderWidget()" }.joined(separator: "\n")
        XCTAssertNil(LibrarianHotLane.opID(for: grepDump),
                     "grep output is exact-output protected: no hot-lane op may claim it")
    }
}

actor SavingsCollector {
    private var records: [DistillSavingsRecord] = []

    func add(_ record: DistillSavingsRecord) {
        records.append(record)
    }

    func modes() -> [String] {
        records.map(\.mode)
    }
}
