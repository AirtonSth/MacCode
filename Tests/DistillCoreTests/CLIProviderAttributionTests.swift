import XCTest
@testable import DistillCore

/// End-to-end proof of the savings-attribution fix: the REAL `distill` CLI binary, run with
/// REMOTE_CODE_AGENT_PROVIDER set (which providerEnvironment now guarantees), records its
/// command-output savings under that provider — NOT "unknown". This is the bug that made the
/// per-provider report show "Claude Saved 0" while 285K sat under "unknown".
final class CLIProviderAttributionTests: XCTestCase {
    private actor RecordCapture {
        private(set) var records: [DistillSavingsRecord] = []
        func add(_ request: DistillRequest, _ response: DistillResponse) {
            if let r = DistillSavingsCalculator.record(for: request, response: response) { records.append(r) }
        }
    }

    private func builtBinary() -> URL? {
        let cwd = FileManager.default.currentDirectoryPath
        return [".build/debug/RemoteCodeDistillService", ".build/arm64-apple-macosx/debug/RemoteCodeDistillService"]
            .map { URL(fileURLWithPath: cwd).appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func test_cliWithProviderEnvAttributesSavingsToProviderNotUnknown() async throws {
        guard let binary = builtBinary() else { throw XCTSkip("RemoteCodeDistillService debug binary not built") }

        let capture = RecordCapture()
        let config = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: NSTemporaryDirectory())
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(configuration: config, scheduler: scheduler) { request, response in
            await capture.add(request, response)
        }
        let ready = try await server.start()
        defer { server.stop() }

        let stateURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("attr-state-\(UUID().uuidString).json")
        try Data("{\"base_url\":\"\(ready.baseURL)\",\"auth_token\":\"tok\"}".utf8).write(to: stateURL)
        defer { try? FileManager.default.removeItem(at: stateURL) }

        let (_, code) = try runProcess(
            binary,
            ["cli", "Did it pass? Return PASS or FAIL only."],
            env: ["REMOTE_CODE_DISTILL_STATE_PATH": stateURL.path, "REMOTE_CODE_AGENT_PROVIDER": "claude"],
            stdin: "build passed\n0 failures"
        )
        XCTAssertEqual(code, 0)

        // onSuccess is awaited before the HTTP response, so by now the record exists.
        let records = await capture.records
        let record = try XCTUnwrap(records.first, "the CLI run must produce a savings record")
        XCTAssertEqual(record.provider, "claude", "REMOTE_CODE_AGENT_PROVIDER=claude => savings attributed to claude, NOT unknown")
        XCTAssertEqual(record.mode, "command-output")
        XCTAssertGreaterThan(record.savedTokens, 0, "and the saving is recorded")
    }

    private func runProcess(_ url: URL, _ args: [String], env: [String: String], stdin: String) throws -> (out: String, code: Int32) {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        process.environment = environment
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe; process.standardOutput = outPipe; process.standardError = Pipe()
        try process.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8)); inPipe.fileHandleForWriting.closeFile()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (out, process.terminationStatus)
    }
}
