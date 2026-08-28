import XCTest
import CoreModel
@testable import AgentRuntime
@testable import DistillCore

final class ClaudePrimaryPreToolUseBridgeTests: XCTestCase {
    func test_primarySDKRegistersExplicitManagedPreToolUseCallback() throws {
        // WHY: SDK `hooks:` overrides settings JSON, so primary Claude must carry
        // PreToolUse in the explicit callback map beside PostToolUse.
        let source = try bridgeSource()
        XCTAssertTrue(source.contains("async function tokenSaverPreToolUse(input)"))
        XCTAssertTrue(source.contains("spawn(executable, ['hook', 'pre-tool-pipe']"))
        XCTAssertTrue(source.contains("PreToolUse: [{"))
        XCTAssertTrue(source.contains("matcher: 'Bash'"))
        XCTAssertTrue(source.contains("hooks: [tokenSaverPreToolUse]"))
        XCTAssertTrue(source.contains("hooks: tokenSaverHooks()"))
        XCTAssertTrue(source.contains("function tokenSaverExecutionReceiptAdmitsClaude(env)"))
    }

    func test_primarySDKCallbackUsesSameManagedExactOutputAdmission() throws {
        // WHY: primary SDK and CLI settings must delegate to one managed policy;
        // exact-output rg remains byte-for-byte while build output is rewritten.
        let state = ManagedDistillCLI.State(
            baseURL: "http://127.0.0.1:9",
            authToken: "synthetic"
        )
        func run(_ command: String) throws -> [String: Any] {
            let input = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "PreToolUse",
                "tool_name": "Bash",
                "tool_input": ["command": command],
            ])
            let cli = ManagedDistillCLI(arguments: [], stdin: input, state: state) { _ in
                XCTFail("pre-tool admission never calls the sidecar")
                return nil
            }
            let result = cli.hookPreToolPipe(
                processArguments: ["/managed/distill"],
                environment: ["RC_REMOTE_CODE_MANAGED_BIN": "/managed"],
                homeDirectory: "/synthetic-home",
                fileExists: { $0 == "/managed/distill" }
            )
            return (try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]) ?? [:]
        }

        XCTAssertTrue(try run("rg -n token Sources").isEmpty)
        let build = try run("swift test")
        let specific = try XCTUnwrap(build["hookSpecificOutput"] as? [String: Any])
        let updated = try XCTUnwrap(specific["updatedInput"] as? [String: Any])
        XCTAssertTrue((updated["command"] as? String)?.contains("/managed/distill") == true)
    }

    func test_primarySDKExplicitCallbackExecutesManagedHookWithSettingsPresent() throws {
        // WHY: execute the real bridge callback registration, not a lookalike,
        // while a settings hook is also present. The explicit SDK map must win
        // and round-trip the managed hook's updatedInput unchanged.
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudePrimaryPreToolUse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let distill = temporary.appendingPathComponent("distill")
        let script = """
        #!/bin/sh
        cat >/dev/null
        printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":"swift test | managed-distill"}}}'
        """
        try Data(script.utf8).write(to: distill)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: distill.path)

        let harness = #"""
        const fs = require('fs');
        const path = require('path');
        const os = require('os');
        const { spawn } = require('child_process');
        const source = fs.readFileSync(process.argv[1], 'utf8');
        const admissionStart = source.indexOf('function tokenSaverExecutionReceiptAdmitsClaude');
        const postStart = source.indexOf('async function tokenSaverPostToolUse');
        const start = source.indexOf('function managedDistillExecutable');
        const end = source.indexOf('function bridgeUserInputRequest');
        if (admissionStart < 0 || postStart <= admissionStart || start < 0 || end <= start) {
          throw new Error('callback slice missing');
        }
        const current = { env: {
          ...JSON.parse(process.argv[3]),
          RC_REMOTE_CODE_MANAGED_BIN: process.argv[2],
        }};
        const normalizeToolName = (name) => String(name || '').trim().replace(/[-_]/g, '').toLowerCase();
        const factory = new Function('current', 'path', 'os', 'fs', 'spawn', 'normalizeToolName', 'tokenSaverPostToolUse', 'TOKEN_SAVER_HOOK_TIMEOUT_MS',
          source.slice(admissionStart, postStart) + '\n' + source.slice(start, end)
            + '\nreturn tokenSaverHooks;');
        const tokenSaverHooks = factory(current, path, os, fs, spawn, normalizeToolName, async () => ({}), 45000);
        const settings = { hooks: { PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command' }] }] } };
        const hooks = tokenSaverHooks();
        if (!settings.hooks.PreToolUse || !hooks.PreToolUse || !hooks.PostToolUse) {
          throw new Error('settings and explicit hooks must coexist');
        }
        hooks.PreToolUse[0].hooks[0]({
          hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command: 'swift test' }
        }).then((value) => process.stdout.write(JSON.stringify(value)));
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", "-e", harness, try bridgeURL().path, temporary.path,
            try admittedClaudeEnvironmentJSON()
        ]
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        let errorText = String(
            decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, errorText)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let specific = try XCTUnwrap(decoded["hookSpecificOutput"] as? [String: Any])
        let updated = try XCTUnwrap(specific["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["command"] as? String, "swift test | managed-distill")
    }

    func test_primarySDKCallbacksRejectMissingMalformedAndMismatchedReceiptsBeforeSpawn() throws {
        // WHY: inherited hint/PTU flags are not admission. The canonical Swift
        // receipt must validate and bind this exact run before any hook process.
        let harness = #"""
        const fs = require('fs');
        const path = require('path');
        const os = require('os');
        (async () => {
        const source = fs.readFileSync(process.argv[1], 'utf8');
        const admissionStart = source.indexOf('function tokenSaverExecutionReceiptAdmitsClaude');
        const postStart = source.indexOf('async function tokenSaverPostToolUse');
        const preStart = source.indexOf('function managedDistillExecutable');
        const end = source.indexOf('function bridgeUserInputRequest');
        if (admissionStart < 0 || postStart <= admissionStart || preStart < 0 || end <= preStart) {
          throw new Error('callback slice missing');
        }
        const current = { env: {} };
        let spawnCount = 0;
        const spawn = () => { spawnCount += 1; throw new Error('unexpected spawn'); };
        const normalizeToolName = (name) => String(name || '').trim().replace(/[-_]/g, '').toLowerCase();
        const factory = new Function('current', 'path', 'os', 'fs', 'spawn', 'normalizeToolName', 'tokenSaverPostToolUse', 'TOKEN_SAVER_HOOK_TIMEOUT_MS',
          source.slice(admissionStart, postStart) + '\n' + source.slice(preStart, end)
            + '\nreturn tokenSaverHooks;');
        const hooks = factory(current, path, os, fs, spawn, normalizeToolName, async () => ({}), 45000)();
        const callback = hooks.PreToolUse[0].hooks[0];
        const input = {
          hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command: 'swift test' }
        };
        const base = JSON.parse(process.argv[2]);
        const receiptKey = 'RC_TOKEN_SAVER_EXECUTION_RECEIPT_V1';
        current.env = { ...base };
        delete current.env[receiptKey];
        const missing = await callback(input);
        current.env = { ...base, [receiptKey]: '{malformed' };
        const malformed = await callback(input);
        current.env = {
          ...base,
          RC_TOKEN_SAVER_ATTEMPT_ID: '00000000-0000-0000-0000-000000000099',
        };
        const mismatched = await callback(input);
        process.stdout.write(JSON.stringify({ missing, malformed, mismatched, spawnCount }));
        })().catch((error) => {
          process.stderr.write(String(error));
          process.exitCode = 1;
        });
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", "-e", harness, try bridgeURL().path,
            try admittedClaudeEnvironmentJSON()
        ]
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        let errorText = String(
            decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, errorText)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(decoded["missing"] as? [String: Any]).isEmpty)
        XCTAssertTrue(try XCTUnwrap(decoded["malformed"] as? [String: Any]).isEmpty)
        XCTAssertTrue(try XCTUnwrap(decoded["mismatched"] as? [String: Any]).isEmpty)
        XCTAssertEqual(decoded["spawnCount"] as? Int, 0)
    }

    private func admittedClaudeEnvironmentJSON() throws -> String {
        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .claude,
            threadId: "00000000-0000-0000-0000-000000000001",
            rootRunId: "00000000-0000-0000-0000-000000000002",
            attemptId: "00000000-0000-0000-0000-000000000003"
        )
        var environment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
        environment["REMOTE_CODE_AGENT_PROVIDER"] = AgentProvider.claude.rawValue
        let data = try JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func bridgeSource() throws -> String {
        try String(contentsOf: bridgeURL(), encoding: .utf8)
    }

    private func bridgeURL() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs")
    }
}
