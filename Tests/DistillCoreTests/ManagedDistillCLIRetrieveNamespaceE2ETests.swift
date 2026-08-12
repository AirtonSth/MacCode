import XCTest
import Darwin
import CoreModel
import Persistence
import AgentRuntime
@testable import DistillCore

/// R8 regression: the Codex app-server shell policy must carry the same app-support
/// namespace used by the sidecar's scoped recovery DB. The proof uses the built CLI
/// and sidecar as isolated subprocesses and the production provider launcher.
final class ManagedDistillCLIRetrieveNamespaceE2ETests: XCTestCase {
    private let workspaceID = "20000000-0000-0000-0000-000000000002"
    private let projectID = "30000000-0000-0000-0000-000000000003"
    private let threadID = "10000000-0000-0000-0000-000000000001"
    private let attemptID = "50000000-0000-0000-0000-000000000005"

    func test_codexProviderCompressThenRetrieveUsesExactAppSupportNamespaceAndCannotCrossRead() throws {
        let binary = try XCTUnwrap(builtBinary(), "RemoteCodeDistillService debug binary must be built")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r8-retrieve-namespace-\(UUID().uuidString)", isDirectory: true)
        let firstSupport = root.appendingPathComponent("first-support", isDirectory: true)
        let secondSupport = root.appendingPathComponent("second-support", isDirectory: true)
        let managedBin = root.appendingPathComponent("managed-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let distill = managedBin.appendingPathComponent("distill")
        try FileManager.default.createSymbolicLink(at: distill, withDestinationURL: binary)
        let appServer = try makeExecutable(
            at: root,
            name: "fake-codex.js",
            body: Self.codexAppServerFixture
        )

        let first = try launchSidecar(binary: binary, support: firstSupport)
        defer { terminate(first.process) }
        let second = try launchSidecar(binary: binary, support: secondSupport)
        defer { terminate(second.process) }

        let original = (1...220)
            .map { "R8 byte-exact recovery line \($0): repeated provider diagnostic" }
            .joined(separator: "\n") + "\n"
        let originalURL = root.appendingPathComponent("original.txt")
        try Data(original.utf8).write(to: originalURL)

        let firstEnvironment = admittedEnvironment(
            support: firstSupport,
            statePath: first.stateURL.path,
            managedBin: managedBin
        )
        let compressed = try runProvider(
            appServer: appServer,
            environment: firstEnvironment,
            command: "\(shellQuote(distill.path)) 'retain failures and exact details' < \(shellQuote(originalURL.path))",
            currentDirectory: root
        )
        XCTAssertEqual(compressed.code, 0, "stderr=\(compressed.err)")
        let handle = try XCTUnwrap(recoveryHandle(in: compressed.out), compressed.out)
        XCTAssertLessThan(compressed.out.utf8.count, original.utf8.count)

        let retrieved = try runProvider(
            appServer: appServer,
            environment: firstEnvironment,
            command: "\(shellQuote(distill.path)) retrieve \(shellQuote(handle))",
            currentDirectory: root
        )
        XCTAssertEqual(retrieved.code, 0, "stderr=\(retrieved.err) stdout=\(retrieved.out)")
        XCTAssertEqual(Data(retrieved.out.utf8), Data(original.utf8),
                       "retrieve must return the store-before-loss bytes from the exact app DB namespace")

        let secondEnvironment = admittedEnvironment(
            support: secondSupport,
            statePath: second.stateURL.path,
            managedBin: managedBin
        )
        let crossRead = try runProvider(
            appServer: appServer,
            environment: secondEnvironment,
            command: "\(shellQuote(distill.path)) retrieve \(shellQuote(handle))",
            currentDirectory: root
        )
        XCTAssertEqual(crossRead.code, 1)
        XCTAssertEqual(crossRead.out, "distill retrieve: original unavailable\n",
                       "a separate app-support DB must not read another namespace's capability")

        var mismatched = firstEnvironment
        mismatched["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = secondSupport.path
        let mismatch = try runProvider(
            appServer: appServer,
            environment: mismatched,
            command: "\(shellQuote(distill.path)) retrieve \(shellQuote(handle))",
            currentDirectory: root
        )
        XCTAssertEqual(mismatch.code, 1)
        XCTAssertEqual(mismatch.out, "distill retrieve: missing handle or service\n",
                       "the launcher must strip a divergent namespace before recovery reaches any sidecar")
    }

    private func admittedEnvironment(
        support: URL,
        statePath: String,
        managedBin: URL
    ) -> [String: String] {
        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .codex,
            threadId: threadID,
            rootRunId: "40000000-0000-0000-0000-000000000004",
            attemptId: attemptID,
            workspaceId: workspaceID,
            projectId: projectID,
            enabledLanes: ["deterministic_wrapper"]
        )
        var environment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
        environment["REMOTE_CODE_AGENT_PROVIDER"] = AgentProvider.codex.rawValue
        environment["REMOTE_CODE_DISTILL_STATE_PATH"] = statePath
        environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = support.path
        environment["RC_REMOTE_CODE_MANAGED_BIN"] = managedBin.path
        environment["PATH"] = "\(managedBin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")"
        environment["RC_LOGIN_SHELL_ENV_IMPORT"] = "0"
        return environment
    }

    private func launchSidecar(
        binary: URL,
        support: URL
    ) throws -> (process: Process, stateURL: URL) {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        SettingsStore(db: db).update { $0.tokenSaverEnabled = true }
        try SettingsRepository(db: db).set(
            "private.account.session",
            #"{"user":{"subscribed":true}}"#
        )

        let authToken = "r8-\(UUID().uuidString)"
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = binary
        process.arguments = [
            "--auth-token", authToken,
            "--app-support-dir", support.path,
            "--host", "127.0.0.1",
            "--port", "0",
            "--runtime", "mlx",
            "--max-concurrent-requests", "1",
            "--max-queue-depth", "2",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["REMOTE_CODE_DISTILL_ALLOW_TEST_RUNTIME"] = "1"
        process.environment = environment
        process.standardOutput = output
        process.standardError = error
        try process.run()

        var pending = Data()
        let decoder = JSONDecoder()
        while process.isRunning {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                if let ready = try? decoder.decode(DistillServiceReadyEvent.self, from: line) {
                    let stateURL = support
                        .appendingPathComponent("Distill", isDirectory: true)
                        .appendingPathComponent("DistillCLIState.json")
                    try FileManager.default.createDirectory(
                        at: stateURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let state: [String: Any] = [
                        "base_url": ready.baseURL,
                        "auth_token": authToken,
                        "pid": ready.pid,
                    ]
                    try JSONSerialization.data(withJSONObject: state).write(to: stateURL, options: .atomic)
                    return (process, stateURL)
                }
            }
        }
        let stderr = String(decoding: error.fileHandleForReading.availableData, as: UTF8.self)
        terminate(process)
        throw NSError(
            domain: "ManagedDistillCLIRetrieveNamespaceE2ETests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "sidecar did not become ready: \(stderr)"]
        )
    }

    private func runProvider(
        appServer: URL,
        environment: [String: String],
        command: String,
        currentDirectory: URL
    ) throws -> (out: String, err: String, code: Int32) {
        let process = try ProviderSubprocessLauncher.makeProcess(
            provider: .codex,
            executablePath: appServer.path,
            arguments: ["app-server", "--fixture-command", command],
            currentDirectory: currentDirectory.path,
            environment: environment
        )
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(decoding: stdout, as: UTF8.self),
            String(decoding: stderr, as: UTF8.self),
            process.terminationStatus
        )
    }

    private func recoveryHandle(in output: String) -> String? {
        guard let markerStart = output.range(of: "[[rc:")?.upperBound,
              let markerEnd = output[markerStart...].range(of: "]]")?.lowerBound else {
            return nil
        }
        let handle = String(output[markerStart..<markerEnd])
        return handle.isEmpty ? nil : handle
    }

    private func builtBinary() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return [
            ".build/debug/RemoteCodeDistillService",
            ".build/arm64-apple-macosx/debug/RemoteCodeDistillService",
            ".build/x86_64-apple-macosx/debug/RemoteCodeDistillService",
        ]
            .map { cwd.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func makeExecutable(at directory: URL, name: String, body: String) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: file)
        guard chmod(file.path, 0o755) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
        return file
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let codexAppServerFixture = #"""
    #!/usr/bin/env node
    const { spawnSync } = require("child_process");
    const args = process.argv.slice(2);
    const commandIndex = args.indexOf("--fixture-command");
    const command = commandIndex >= 0 ? args[commandIndex + 1] : "exit 2";
    const childEnvironment = { PATH: "/usr/bin:/bin" };
    const prefix = "shell_environment_policy.set.";
    for (let index = 0; index + 1 < args.length; index += 1) {
      if (args[index] !== "-c") continue;
      const assignment = args[index + 1];
      if (!assignment.startsWith(prefix)) continue;
      const separator = assignment.indexOf("=", prefix.length);
      if (separator < 0) continue;
      const key = assignment.slice(prefix.length, separator);
      try { childEnvironment[key] = JSON.parse(assignment.slice(separator + 1)); } catch (_) {}
    }
    const result = spawnSync("/bin/sh", ["-c", command], {
      cwd: process.cwd(),
      env: childEnvironment,
      encoding: "utf8"
    });
    process.stdout.write(result.stdout || "");
    process.stderr.write(result.stderr || "");
    process.exit(result.status === null ? 1 : result.status);
    """#
}
