import XCTest
@testable import DistillCore

/// End-to-end proof of the NATIVE CLI: runs the actually-built RemoteCodeDistillService
/// binary in `cli` mode as a subprocess against a live in-process sidecar. Proves both
/// the success path and the fail-open (no-data-loss) contract on the real artifact.
final class ManagedDistillCLISubprocessTests: XCTestCase {
    private func builtBinary() -> URL? {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            ".build/debug/RemoteCodeDistillService",
            ".build/arm64-apple-macosx/debug/RemoteCodeDistillService",
            ".build/x86_64-apple-macosx/debug/RemoteCodeDistillService",
        ].map { URL(fileURLWithPath: cwd).appendingPathComponent($0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func test_realCLIBinary_compressesViaSidecar_andFailsOpen() async throws {
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let config = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: NSTemporaryDirectory())
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(configuration: config, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }

        let stateURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cli-state-\(UUID().uuidString).json")
        let stateJSON = "{\"base_url\":\"\(ready.baseURL)\",\"auth_token\":\"tok\"}"
        try Data(stateJSON.utf8).write(to: stateURL)
        defer { try? FileManager.default.removeItem(at: stateURL) }

        // Success: real binary compresses live tool output through the sidecar.
        let ok = try runProcess(
            binary,
            ["cli", "Did the build pass? Return PASS or FAIL only."],
            env: ["REMOTE_CODE_DISTILL_STATE_PATH": stateURL.path],
            stdin: "build passed\n0 failures"
        )
        XCTAssertEqual(ok.code, 0)
        XCTAssertTrue(ok.out.contains("PASS"), "real CLI binary compressed via the live sidecar; got: \(ok.out)")

        // Fail-open: point at a non-existent state file (no service) => raw stdin echoed,
        // exit 0. This is the data-loss bug the Python CLI had, now fixed.
        let failOpen = try runProcess(
            binary,
            ["cli", "compress this"],
            env: ["REMOTE_CODE_DISTILL_STATE_PATH": "/nonexistent/\(UUID().uuidString).json"],
            stdin: "RAW DATA MUST SURVIVE"
        )
        XCTAssertEqual(failOpen.code, 0, "fail-open exits 0")
        XCTAssertEqual(
            failOpen.out.trimmingCharacters(in: .whitespacesAndNewlines),
            "RAW DATA MUST SURVIVE",
            "no service => raw stdin echoed verbatim, never lost"
        )
    }

    private func runProcess(_ url: URL, _ args: [String], env: [String: String], stdin: String) throws -> (out: String, code: Int32) {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        process.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try process.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        inPipe.fileHandleForWriting.closeFile()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}
