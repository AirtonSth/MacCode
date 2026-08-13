import XCTest
import Darwin
import CoreModel
import Persistence
@testable import AgentRuntime
@testable import DistillCore

private final class LiveSidecarReadyCapture: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pending = Data()
    private var event: DistillServiceReadyEvent?
    private var stdoutBytes = Data()
    private var diagnosticBytes = Data()

    func receiveStdout(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else {
            completed.signal()
            return
        }
        stdoutBytes.append(data)
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if let ready = try? JSONDecoder().decode(DistillServiceReadyEvent.self, from: line) {
                event = ready
                completed.signal()
                return
            }
        }
    }

    func receiveStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        diagnosticBytes.append(data)
        lock.unlock()
    }

    func snapshot() -> (event: DistillServiceReadyEvent?, diagnostics: String) {
        lock.lock()
        defer { lock.unlock() }
        return (
            event,
            "stdout=\(String(decoding: stdoutBytes, as: UTF8.self)); stderr=\(String(decoding: diagnosticBytes, as: UTF8.self))"
        )
    }
}

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
        let server = DistillHTTPServer(
            configuration: config,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore()
        )
        let ready = try await server.start()
        defer { server.stop() }

        let supportURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("managed-distill-live-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: supportURL.path).run()
        let settings = SettingsStore(db: db)
        settings.update { $0.tokenSaverEnabled = true }
        let settingsRepository = SettingsRepository(db: db)
        try settingsRepository.set(
            "private.account.session",
            #"{"user":{"subscribed":true}}"#
        )
        let stateURL = supportURL
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stateJSON: [String: Any] = [
            "base_url": ready.baseURL,
            "auth_token": "tok",
            "pid": ready.pid,
        ]
        try JSONSerialization.data(withJSONObject: stateJSON).write(to: stateURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let liveEnvironment = [
            "REMOTE_CODE_DISTILL_STATE_PATH": stateURL.path,
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": supportURL.path,
            "REMOTE_CODE_AGENT_PROVIDER": "codex",
            "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace-subprocess",
            "RC_TOKEN_SAVER_PROJECT_ID": "project-subprocess",
            "RC_TOKEN_SAVER_THREAD_ID": "thread-subprocess",
            "RC_TOKEN_SAVER_ATTEMPT_ID": "attempt-subprocess"
        ]

        // Success: real binary compresses live tool output through the sidecar.
        let ok = try runProcess(
            binary,
            ["cli", "Did the build pass? Return PASS or FAIL only."],
            env: liveEnvironment,
            stdin: "build passed\n0 failures"
        )
        XCTAssertEqual(ok.code, 0)
        XCTAssertTrue(ok.out.contains("PASS"), "real CLI binary compressed via the live sidecar; got: \(ok.out)")

        // A stale env + state + installed symlink cannot override the live paid
        // setting. No request reaches the still-running sidecar.
        settings.update { $0.tokenSaverEnabled = false }
        let staleSymlink = supportURL.appendingPathComponent("stale-distill-link")
        try FileManager.default.createSymbolicLink(at: staleSymlink, withDestinationURL: binary)
        let off = try runProcess(
            staleSymlink,
            ["cli", "compress this"],
            env: liveEnvironment,
            stdin: "OFF BYTES MUST SURVIVE"
        )
        XCTAssertEqual(off.code, 0)
        XCTAssertEqual(off.out, "OFF BYTES MUST SURVIVE")

        // Entitlement is part of live admission, not merely the user's toggle.
        settings.update { $0.tokenSaverEnabled = true }
        try settingsRepository.set(
            "private.account.session",
            #"{"user":{"subscribed":false}}"#
        )
        let unsubscribed = try runProcess(
            binary,
            ["cli", "compress this"],
            env: liveEnvironment,
            stdin: "UNSUBSCRIBED BYTES MUST SURVIVE"
        )
        XCTAssertEqual(unsubscribed.code, 0)
        XCTAssertEqual(unsubscribed.out, "UNSUBSCRIBED BYTES MUST SURVIVE")

        // Teardown removes the live lease before the sidecar exits. Even with
        // enabled+subscribed DB state and stale inherited env, the CLI stays raw.
        try settingsRepository.set(
            "private.account.session",
            #"{"user":{"subscribed":true}}"#
        )
        try FileManager.default.removeItem(at: stateURL)
        let teardown = try runProcess(
            binary,
            ["cli", "compress this"],
            env: liveEnvironment,
            stdin: "TEARDOWN BYTES MUST SURVIVE"
        )
        XCTAssertEqual(teardown.code, 0)
        XCTAssertEqual(teardown.out, "TEARDOWN BYTES MUST SURVIVE")

        // Fail-open: point at a non-existent state file (no service) => exact
        // raw stdin, exit 0. This is the data-loss bug the Python CLI had.
        let failOpen = try runProcess(
            binary,
            ["cli", "compress this"],
            env: [
                "REMOTE_CODE_DISTILL_STATE_PATH": "/nonexistent/\(UUID().uuidString).json",
                "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": supportURL.path,
            ],
            stdin: "RAW DATA MUST SURVIVE"
        )
        XCTAssertEqual(failOpen.code, 0, "fail-open exits 0")
        XCTAssertEqual(failOpen.out, "RAW DATA MUST SURVIVE", "no service => raw stdin echoed verbatim, never lost")
    }

    func test_providerProxyCrossProviderCodexChildCarriesArtifactToolShellHandshake() throws {
        // WHY: Claude/Grok parents must not own Codex's absolute zsh lane, but
        // their raw provider proxy still has to issue the complete child
        // shell_environment_policy transport. This exercises the native
        // ProviderProxyRunner subprocess path rather than only its policy seam.
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cross-provider-tool-shell-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let providerHome = root.appendingPathComponent("provider-home", isDirectory: true)
        let fakeProviderDirectory = root.appendingPathComponent("provider-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeProviderDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = AgentSkillInstaller(homeDirectory: providerHome)
        let runtimeInstaller = try XCTUnwrap(installer.runtimeInstaller(for: binary))
        try runtimeInstaller.installProviderShellBridge()
        let managedBin = runtimeInstaller.managedCLIBinURL
        let service = try XCTUnwrap(runtimeInstaller.pinnedServiceBinaryURL)
        let statePath = support
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
        try FileManager.default.createDirectory(
            at: statePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: statePath)

        let capturedArguments = root.appendingPathComponent("codex-arguments.txt")
        _ = try makeExecutable(
            at: fakeProviderDirectory,
            name: "codex",
            body: "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(capturedArguments.path)\"\n"
        )
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        SettingsStore(db: db).update { $0.tokenSaverEnabled = true }
        try SettingsRepository(db: db).set(
            "private.account.session",
            #"{"user":{"subscribed":true}}"#
        )
        let runtime = AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(db: db),
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false }
        )

        for parentProvider in [AgentProvider.claude, .grok] {
            let thread = AgentThreadID()
            let rootRun = AgentRunID()
            let parentCapability = AgentDelegationCapability.issue()
            _ = try runtime.recordExternalRoot(
                runId: rootRun,
                threadId: thread,
                provider: parentProvider,
                providerInstanceId: parentProvider.rawValue,
                model: "test",
                permissionMode: .fullAccess,
                delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(parentCapability)
            )
            let receipt = TokenSaverExecutionReceiptSeam.admit(
                tokenSaverEnabled: true,
                sameUser: true,
                sidecarAvailable: true,
                provider: parentProvider,
                threadId: thread.value.uuidString,
                rootRunId: rootRun.value.uuidString,
                attemptId: rootRun.value.uuidString,
                workspaceId: UUID().uuidString,
                projectId: UUID().uuidString
            )
            var environment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
            environment["REMOTE_CODE_AGENT_PROVIDER"] = parentProvider.rawValue
            environment["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"] = thread.value.uuidString
            environment["RC_REMOTE_CODE_ROOT_RUN_ID"] = rootRun.value.uuidString
            environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = support.path
            environment["REMOTE_CODE_DISTILL_STATE_PATH"] = statePath.path
            environment["RC_REMOTE_CODE_MANAGED_BIN"] = managedBin.path
            environment["RC_REMOTE_CODE_PROVIDER_PROXY_BIN"] = managedBin.path
            environment[AgentSkillInstaller.runtimeRootEnvironmentKey] =
                managedBin.deletingLastPathComponent().path
            environment["PATH"] = [managedBin.path, fakeProviderDirectory.path, "/usr/bin", "/bin"].joined(separator: ":")
            environment[AgentDelegationCapabilityTransport.environmentKey] = parentCapability

            let result = try runProcess(
                binary,
                ["provider-proxy", "codex", "exec", "--json", "-"],
                env: environment,
                stdin: ""
            )
            XCTAssertEqual(result.code, 0, "\(parentProvider): \(result.err)")
            let arguments = try String(contentsOf: capturedArguments, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            let assignments = arguments.filter {
                $0.hasPrefix("shell_environment_policy.set.")
            }
            for key in [
                TokenSaverExecutionReceipt.envKey,
                "REMOTE_CODE_DISTILL_STATE_PATH",
                "RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT",
                AgentSkillInstaller.toolShellProtocolEnvironmentKey,
                AgentSkillInstaller.toolShellBinaryEnvironmentKey,
                ProviderProxyPolicy.unownedToolShellEnvironmentKey,
                ProviderProxyPolicy.providerTerminalStdoutEnvironmentKey,
            ] {
                XCTAssertTrue(
                    assignments.contains(where: { $0.hasPrefix("shell_environment_policy.set.\(key)=") }),
                    "\(parentProvider)→codex missing \(key): \(arguments)"
                )
            }
            let binaryAssignment = try XCTUnwrap(
                assignments.first(where: {
                    $0.hasPrefix("shell_environment_policy.set.\(AgentSkillInstaller.toolShellBinaryEnvironmentKey)=")
                })
            )
            XCTAssertTrue(binaryAssignment.contains(service.path))
            XCTAssertTrue(
                assignments.contains(where: {
                    $0.contains("RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT")
                }),
                "the Codex child must receive the interceptor gate"
            )
        }
    }

    func test_wrappersMapUncaughtTERMToShellExit143() throws {
        // WHY: Foundation reports an uncaught signal as terminationStatus 15.
        // Returning that value from the wrapper changes POSIX shell semantics;
        // callers must observe the conventional 128 + signal status instead.
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let ordinary = try runProcess(
            binary,
            ["wrap", "/bin/sh", "-c", "kill -TERM $$"],
            env: [:],
            stdin: ""
        )
        XCTAssertEqual(
            ordinary.code,
            143,
            "ordinary wrapper must translate uncaught TERM to shell status 128 + 15"
        )

        let toolShell = try runProcess(
            binary,
            ["cli", "tool-shell", "--", "kill -TERM $$"],
            env: [:],
            stdin: ""
        )
        XCTAssertEqual(
            toolShell.code,
            143,
            "tool-shell passthrough must translate uncaught TERM to shell status 128 + 15"
        )
    }

    func test_toolShellBridgePinsCurrentBinaryAndFailsOpenAcrossSentinelsAndDrift() throws {
        // WHY: a second RemoteCode instance can repoint ~/.remote-code/bin/distill
        // to an older service that treats `tool-shell` as a compression prompt
        // and blocks on stdin. The bridge must never invoke that mutable link.
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-shell-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = AgentSkillInstaller(homeDirectory: root)
        let runtime = try XCTUnwrap(installer.runtimeInstaller(for: binary))
        _ = try runtime.ensureDistillCLI(serviceBinaryURL: binary)
        let bridge = try runtime.installProviderShellBridge()
        let managedBin = runtime.managedCLIBinURL
        let marker = root.appendingPathComponent("stale-invoked")
        let stale = try makeExecutable(
            at: root,
            name: "stale-distill",
            body: "#!/bin/sh\nprintf stale > \"$STALE_MARKER\"\nIFS= read -r _\n"
        )
        // Stamp the run against the artifact-scoped paths first. A concurrent
        // old app then overwrites both legacy global integration points.
        let globalBin = installer.managedCLIBinURL
        try FileManager.default.createDirectory(at: globalBin, withIntermediateDirectories: true)
        let globalDistill = globalBin.appendingPathComponent("distill")
        try FileManager.default.createSymbolicLink(at: globalDistill, withDestinationURL: stale)
        let legacyBridge = installer.providerShellBridgeURL
        try FileManager.default.createDirectory(at: legacyBridge, withIntermediateDirectories: true)
        try Data(
            """
            if [[ -n "${ZSH_EXECUTION_STRING:-}" ]]; then
              exec "${RC_LEGACY_GLOBAL_DISTILL}" tool-shell -- "${ZSH_EXECUTION_STRING}"
            fi
            """.utf8
        ).write(to: legacyBridge.appendingPathComponent(".zshenv"))

        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "\(managedBin.path):/usr/bin:/bin",
            "ZDOTDIR": bridge.path,
            "RC_REMOTE_CODE_MANAGED_ZDOTDIR": bridge.path,
            "RC_REMOTE_CODE_ORIGINAL_ZDOTDIR": root.path,
            "RC_REMOTE_CODE_MANAGED_BIN": managedBin.path,
            "RC_REMOTE_CODE_UNOWNED_TOOL_SHELL": "1",
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            "RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT": "1",
            AgentSkillInstaller.toolShellProtocolEnvironmentKey:
                AgentSkillInstaller.toolShellProtocolVersion,
            AgentSkillInstaller.toolShellBinaryEnvironmentKey: binary.path,
            "STALE_MARKER": marker.path,
            "RC_LEGACY_GLOBAL_DISTILL": globalDistill.path,
        ]

        let explicitPipe = try runZshWithTimeout(
            "printf 'PIPE_CURRENT_ONCE\\n' | distill 'preserve on unavailable sidecar'",
            environment: environment,
            timeout: 5,
            keepStdinOpen: true
        )
        XCTAssertFalse(explicitPipe.timedOut, explicitPipe.err)
        XCTAssertEqual(explicitPipe.code, 0, explicitPipe.err)
        XCTAssertEqual(explicitPipe.out, "PIPE_CURRENT_ONCE\n")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "explicit pipe resolved the drifted global distill instead of the artifact bin"
        )

        let current = try runZshWithTimeout(
            #"printf 'SENTINELS=%s,%s' "${RC_REMOTE_CODE_TOOL_SHELL_DONE:-0}" "${RC_TOKEN_SAVER_TOOL_SHELL_DONE:-0}""#,
            environment: environment,
            timeout: 5,
            keepStdinOpen: true
        )
        XCTAssertFalse(current.timedOut, current.err)
        XCTAssertEqual(current.code, 0, current.err)
        XCTAssertEqual(current.out, "SENTINELS=1,1")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "the mutable stale symlink or overwritten legacy bridge must never be invoked"
        )

        var cases: [(String, [String: String])] = []
        var currentDone = environment
        currentDone[AgentSkillInstaller.toolShellCurrentDoneEnvironmentKey] = "1"
        currentDone[AgentSkillInstaller.toolShellBinaryEnvironmentKey] = stale.path
        cases.append(("current_done", currentDone))
        var legacyDone = environment
        legacyDone[AgentSkillInstaller.toolShellLegacyDoneEnvironmentKey] = "1"
        legacyDone[AgentSkillInstaller.toolShellBinaryEnvironmentKey] = stale.path
        cases.append(("legacy_done", legacyDone))
        var protocolDrift = environment
        protocolDrift[AgentSkillInstaller.toolShellProtocolEnvironmentKey] = "0"
        protocolDrift[AgentSkillInstaller.toolShellBinaryEnvironmentKey] = stale.path
        cases.append(("protocol_drift", protocolDrift))
        var missing = environment
        missing[AgentSkillInstaller.toolShellBinaryEnvironmentKey] =
            root.appendingPathComponent("missing-service").path
        cases.append(("missing_binary", missing))

        for (name, caseEnvironment) in cases {
            let result = try runZshWithTimeout(
                "printf FAIL_OPEN_\(name)",
                environment: caseEnvironment,
                timeout: 1,
                keepStdinOpen: true
            )
            XCTAssertFalse(result.timedOut, "\(name) must fail open immediately")
            XCTAssertEqual(result.code, 0, "\(name): \(result.err)")
            XCTAssertEqual(result.out, "FAIL_OPEN_\(name)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: marker.path),
                "\(name) invoked the stale blocking binary"
            )
        }
    }

    func test_toolShellHonorsLiveDisabledLaneAfterReceiptWasIssued() async throws {
        // WHY: a provider receipt is immutable for the lifetime of a turn. An
        // operator disabling tool_shell in the live state overlay after that
        // receipt must stop the next interception without restarting the turn.
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-shell-live-lane-\(UUID().uuidString)", isDirectory: true)
        let binURL = supportURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: supportURL.path).run()
        let settings = SettingsStore(db: db)
        settings.update { $0.tokenSaverEnabled = true }
        try SettingsRepository(db: db).set(
            "private.account.session",
            #"{"user":{"subscribed":true}}"#
        )

        let config = try DistillServiceConfiguration(
            authToken: "tool-shell-live-token",
            appSupportDirectory: supportURL.path
        )
        let server = DistillHTTPServer(
            configuration: config,
            scheduler: DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2),
            scopedRecoveryStore: TestScopedRecoveryStore()
        )
        let ready = try await server.start()
        defer { server.stop() }

        let stateURL = supportURL
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        func writeState(disabledLanes: [String]) throws {
            let state: [String: Any] = [
                "base_url": ready.baseURL,
                "auth_token": "tool-shell-live-token",
                "pid": ready.pid,
                "disabled_lanes": disabledLanes,
                "enabled_lanes": [CommandWrapPolicy.toolShellLane],
            ]
            try JSONSerialization.data(withJSONObject: state).write(to: stateURL, options: .atomic)
        }
        try writeState(disabledLanes: [])

        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .codex,
            threadId: "10000000-0000-0000-0000-000000000001",
            rootRunId: "40000000-0000-0000-0000-000000000004",
            attemptId: "50000000-0000-0000-0000-000000000005",
            workspaceId: "20000000-0000-0000-0000-000000000002",
            projectId: "30000000-0000-0000-0000-000000000003"
        )
        XCTAssertFalse(
            receipt.disabledLanes.contains(CommandWrapPolicy.toolShellLane),
            "the regression requires one unchanged receipt that admits tool_shell"
        )
        var environment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
        environment["REMOTE_CODE_AGENT_PROVIDER"] = "codex"
        environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = supportURL.path
        environment["REMOTE_CODE_DISTILL_STATE_PATH"] = stateURL.path
        environment["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"] = "1"
        environment["RC_REMOTE_CODE_UNOWNED_TOOL_SHELL"] = "1"

        let fakeSwift = try makeExecutable(
            at: binURL,
            name: "swift",
            body: "#!/bin/sh\nfor i in $(seq 1 200); do printf 'build line %s: repeated diagnostic output\\n' \"$i\"; done\n"
        )
        let payload = "\(fakeSwift.path) noisy.swift"
        let rawOutput = (1...200)
            .map { "build line \($0): repeated diagnostic output" }
            .joined(separator: "\n") + "\n"

        let admitted = try runProcess(
            binary,
            ["cli", "tool-shell", "--", payload],
            env: environment,
            stdin: "",
            unset: ["RC_TOKEN_SAVER_DISABLED_LANES", "RC_TOKEN_SAVER_ENABLED_LANES"]
        )
        XCTAssertEqual(admitted.code, 0, "stderr=\(admitted.err)")
        XCTAssertTrue(admitted.out.contains("[[rc:"), "enabled live lane must intercept: \(admitted.out)")
        let beforeDisable = await server.metrics.snapshot(
            activeRequests: 0,
            maxConcurrentRequests: 2
        )
        XCTAssertEqual(beforeDisable.totalRequests, 1)

        // The receipt above remains byte-identical; only the authoritative live
        // overlay changes between executions.
        // The state keeps tool_shell in enabled_lanes too: the incident kill
        // switch must win when the same lane appears in both live lists.
        try writeState(disabledLanes: [CommandWrapPolicy.toolShellLane])
        let disabled = try runProcess(
            binary,
            ["cli", "tool-shell", "--", payload],
            env: environment,
            stdin: "",
            unset: ["RC_TOKEN_SAVER_DISABLED_LANES", "RC_TOKEN_SAVER_ENABLED_LANES"]
        )
        XCTAssertEqual(disabled.code, 0, "stderr=\(disabled.err)")
        XCTAssertEqual(disabled.out, rawOutput, "live disabled_lanes must force exact passthrough")
        let afterDisable = await server.metrics.snapshot(
            activeRequests: 0,
            maxConcurrentRequests: 2
        )
        XCTAssertEqual(
            afterDisable.totalRequests,
            1,
            "live kill switch must prevent a second distill request from the stale receipt"
        )
    }

    func test_explicitDistillUsesAdmittedReceiptAndAppSupportNamespace() async throws {
        // WHY: an explicit `| distill` is a paid Token Saver action. It must
        // require the host-issued receipt and resolve the isolated app's lease
        // when Codex/Grok shell plumbing did not preserve the state-path key.
        // One invocation must produce one sidecar request and a reduced output.
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let supportURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("managed-distill-explicit-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: supportURL.path).run()
        let settings = SettingsStore(db: db)
        settings.update { $0.tokenSaverEnabled = true }
        let settingsRepository = SettingsRepository(db: db)
        try settingsRepository.set("private.account.session", #"{"user":{"subscribed":true}}"#)
        let savingsRepo = TokenSaverSavingsRepository(db: db)
        let config = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: supportURL.path)
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: config,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore(),
            onSuccess: { request, response, threadID in
                guard let record = DistillSavingsCalculator.record(
                    for: request,
                    response: response,
                    threadID: threadID
                ) else {
                    return
                }
                _ = try? savingsRepo.record(
                    provider: record.provider,
                    mode: record.mode,
                    inputTokens: record.inputTokens,
                    outputTokens: record.outputTokens,
                    savedTokens: record.savedTokens,
                    cacheState: record.cacheState,
                    contentType: "unknown",
                    engine: record.routeStage?.rawValue ?? "unknown",
                    attributability: record.attributability,
                    delivered: record.delivered,
                    threadID: record.threadID
                )
            }
        )
        let ready = try await server.start()
        defer { server.stop() }

        let stateURL = supportURL
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stateJSON: [String: Any] = [
            "base_url": ready.baseURL,
            "auth_token": "tok",
            "pid": ready.pid,
        ]
        try JSONSerialization.data(withJSONObject: stateJSON).write(to: stateURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .claude,
            threadId: "10000000-0000-0000-0000-000000000001",
            rootRunId: "40000000-0000-0000-0000-000000000004",
            attemptId: "50000000-0000-0000-0000-000000000005",
            workspaceId: "20000000-0000-0000-0000-000000000002",
            projectId: "30000000-0000-0000-0000-000000000003"
        )
        var admittedEnvironment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
        admittedEnvironment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = supportURL.path
        admittedEnvironment["REMOTE_CODE_AGENT_PROVIDER"] = "claude"
        XCTAssertEqual(admittedEnvironment["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
        // Deliberately omit REMOTE_CODE_DISTILL_STATE_PATH: the isolated
        // namespace must be derived from app support, not stable-channel state.

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("managed-distill-explicit-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeSwift = try makeExecutable(
            at: root,
            name: "swift",
            body: "#!/bin/sh\nfor i in $(seq 1 200); do printf 'build line %s: repeated diagnostic output\\n' \"$i\"; done\n"
        )
        let distill = root.appendingPathComponent("distill")
        try FileManager.default.createSymbolicLink(at: distill, withDestinationURL: binary)
        let path = "\(root.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        let rawOutput = (1...200)
            .map { "build line \($0): repeated diagnostic output" }
            .joined(separator: "\n") + "\n"

        // Claude's admitted PostToolUse lane owns ordinary Bash output. The
        // automatic PATH wrapper therefore stays raw and the real hook binary
        // creates the sole request/ledger row for those bytes.
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(
                command: "swift",
                args: ["noisy.swift"],
                environment: admittedEnvironment
            ),
            "provider_post_tool_use_owner"
        )
        let hookEnvelope: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": ["command": "swift noisy.swift"],
            "tool_response": rawOutput,
        ]
        let hookInput = try JSONSerialization.data(withJSONObject: hookEnvelope)
        let hooked = try runProcess(
            binary,
            ["cli", "hook", "post-tool-use"],
            env: admittedEnvironment,
            stdin: String(decoding: hookInput, as: UTF8.self)
        )
        XCTAssertEqual(hooked.code, 0, "stderr=\(hooked.err)")
        let hookedJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(hooked.out.utf8)) as? [String: Any]
        )
        XCTAssertNotNil(
            (hookedJSON["hookSpecificOutput"] as? [String: Any])?["updatedToolOutput"],
            "the real PostToolUse subprocess must replace ordinary noisy output"
        )
        let metricsAfterHook = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(metricsAfterHook.totalRequests, 1,
                       "wrapper plus hook must make exactly one sidecar request")
        let rowsAfterHook = try db.prepare("SELECT COUNT(*), MIN(cache_state) FROM token_saver_savings;")
        XCTAssertTrue(try rowsAfterHook.step())
        XCTAssertEqual(rowsAfterHook.columnInt64(0), 1)
        XCTAssertEqual(rowsAfterHook.columnText(1), "tool_output_hooked")

        let command = "swift noisy.swift | distill"
        let result = try runShell(command, env: admittedEnvironment.merging(["PATH": path]) { _, value in value })

        XCTAssertEqual(result.code, 0, "stderr=\(result.err)")
        XCTAssertFalse(result.out.split(whereSeparator: \.isNewline).count >= 200, result.out)
        XCTAssertTrue(result.out.contains("[[rc:"), "lossy explicit distill output must carry recovery: \(result.out)")
        let metrics = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(metrics.totalRequests, 2,
                       "the explicit pipe must add exactly one request after the hook")
        XCTAssertEqual(metrics.successfulRequests, 2)
        let savingsRows = try db.prepare("SELECT COUNT(*) FROM token_saver_savings;")
        XCTAssertTrue(try savingsRows.step())
        XCTAssertEqual(savingsRows.columnInt64(0), 2,
                       "hook and explicit pipe must each create one durable savings row")
        let cacheStates = try db.prepare("SELECT cache_state FROM token_saver_savings ORDER BY cache_state;")
        var observedCacheStates: [String] = []
        while try cacheStates.step() { observedCacheStates.append(cacheStates.columnText(0) ?? "") }
        XCTAssertEqual(observedCacheStates, ["tool_output_hooked", "tool_output_pipe"])

        var noReceiptEnvironment = admittedEnvironment
        noReceiptEnvironment.removeValue(forKey: TokenSaverExecutionReceipt.envKey)
        let denied = try runShell(
            command,
            env: noReceiptEnvironment.merging(["PATH": path]) { _, value in value }
        )
        XCTAssertEqual(denied.code, 0)
        XCTAssertEqual(denied.out.split(whereSeparator: \.isNewline).count, 200,
                       "no receipt must fail open to the exact explicit-pipe bytes")
        let afterDenied = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(afterDenied.totalRequests, 2, "a denied explicit pipe must not reach the sidecar")

        // An explicit app namespace is authoritative. A malformed or removed
        // lease must fail open; it must never fall through to a stable/canary
        // lease belonging to another app instance.
        try Data("{not-json".utf8).write(to: stateURL, options: .atomic)
        let malformedNamespace = try runShell(
            command,
            env: admittedEnvironment.merging(["PATH": path]) { _, value in value }
        )
        XCTAssertEqual(malformedNamespace.code, 0)
        XCTAssertEqual(malformedNamespace.out.split(whereSeparator: \.isNewline).count, 200,
                       "malformed app namespace must fail open to exact bytes")
        try FileManager.default.removeItem(at: stateURL)
        let missingNamespace = try runShell(
            command,
            env: admittedEnvironment.merging(["PATH": path]) { _, value in value }
        )
        XCTAssertEqual(missingNamespace.code, 0)
        XCTAssertEqual(missingNamespace.out.split(whereSeparator: \.isNewline).count, 200,
                       "missing app namespace must fail open to exact bytes")
        var emptyNamespaceEnvironment = admittedEnvironment
        emptyNamespaceEnvironment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = ""
        let emptyNamespace = try runShell(
            command,
            env: emptyNamespaceEnvironment.merging(["PATH": path]) { _, value in value }
        )
        XCTAssertEqual(emptyNamespace.code, 0)
        XCTAssertEqual(emptyNamespace.out.split(whereSeparator: \.isNewline).count, 200,
                       "empty app namespace must fail open to exact bytes")

        // Receipt-required `distill` must not search release-channel state when
        // both explicit namespace keys are absent.
        let noNamespace = try runShell(
            command,
            env: admittedEnvironment.merging(["PATH": path]) { _, value in value },
            unset: ["REMOTE_CODE_DISTILL_STATE_PATH", "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"]
        )
        XCTAssertEqual(noNamespace.code, 0)
        XCTAssertEqual(noNamespace.out.split(whereSeparator: \.isNewline).count, 200,
                       "receipt without an explicit namespace must fail open to exact bytes")
        let afterNamespaceDenials = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(afterNamespaceDenials.totalRequests, 2,
                       "invalid app namespace must not reach a sibling sidecar")
        let finalSavingsRows = try db.prepare("SELECT COUNT(*) FROM token_saver_savings;")
        XCTAssertTrue(try finalSavingsRows.step())
        XCTAssertEqual(finalSavingsRows.columnInt64(0), 2,
                       "denied/fail-open invocations must not create savings rows")
        let providerAttempts = try db.prepare("SELECT COUNT(*) FROM token_saver_attempts;")
        XCTAssertTrue(try providerAttempts.step())
        XCTAssertEqual(providerAttempts.columnInt64(0), 0,
                       "provider-attempt rows are opened by AppContext provider-usage attribution, not sidecar compression")
        _ = fakeSwift
        _ = stateURL
    }

    func test_liveExplicitDistillProviderPipeUsesOneRequestAndDeliveredSavings() async throws {
        // WHY: R5 failed only in the real provider shell: Codex's app-server
        // dropped RC_* variables, so the older explicit `distill` binary sent
        // an unscoped request and the sidecar correctly failed open to 200 raw
        // lines. This test starts the built sidecar and CLI as real processes,
        // uses the installed MLX model, and supplies the same stamped provider
        // receipt/scope. The live HTTP metrics and SQLite ledger are the only
        // request/savings evidence; no in-process runtime or mocked counters.
        guard ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip("Set REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_TEST=1 (+ live model dir) to run the real sidecar E2E.")
        }
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let modelSupport = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_DIR"]
                ?? "/tmp/RemoteCodeTokenSaverLiveModel",
            isDirectory: true
        )
        let modelInstaller = TokenSaverModelInstaller(appSupportDirectory: modelSupport)
        guard let manifest = modelInstaller.loadManifest(),
              manifest.isApprovedModel,
              FileManager.default.fileExists(
                  atPath: modelInstaller.modelStorageDirectory(
                      modelID: manifest.modelID,
                      revision: manifest.revision
                  ).path
              ),
              FileManager.default.fileExists(atPath: modelInstaller.encoderManifestURL.path) else {
            throw XCTSkip("Live MLX model/encoder manifests are not installed in \(modelSupport.path)")
        }

        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-distill-live-sidecar-\(UUID().uuidString)", isDirectory: true)
        let distillURL = supportURL.appendingPathComponent("Distill", isDirectory: true)
        try FileManager.default.createDirectory(at: distillURL, withIntermediateDirectories: true)
        // Reuse the verified multi-GB model through symlinks; the sidecar still
        // validates every manifest entry before becoming ready.
        try FileManager.default.createSymbolicLink(
            at: distillURL.appendingPathComponent("Models", isDirectory: true),
            withDestinationURL: modelInstaller.distillDirectory.appendingPathComponent("Models", isDirectory: true)
        )
        try FileManager.default.createSymbolicLink(
            at: distillURL.appendingPathComponent("Encoders", isDirectory: true),
            withDestinationURL: modelInstaller.distillDirectory.appendingPathComponent("Encoders", isDirectory: true)
        )
        for source in [
            modelInstaller.manifestURL,
            modelInstaller.encoderManifestURL,
            modelInstaller.validationCacheURL,
        ] where FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.copyItem(
                at: source,
                to: distillURL.appendingPathComponent(source.lastPathComponent)
            )
        }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: supportURL.path).run()
        let settings = SettingsStore(db: db)
        settings.update { $0.tokenSaverEnabled = true }
        let settingsRepository = SettingsRepository(db: db)
        try settingsRepository.set("private.account.session", #"{"user":{"subscribed":true}}"#)

        let authToken = "r5-live-\(UUID().uuidString)"
        let sidecar = try launchLiveSidecar(
            binary: binary,
            supportDirectory: supportURL,
            authToken: authToken,
            modelID: manifest.modelID,
            modelURL: manifest.modelURL
        )
        defer {
            if sidecar.process.isRunning {
                sidecar.process.terminate()
                sidecar.process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: supportURL)
        }
        XCTAssertEqual(sidecar.ready.runtime, "mlx")

        let stateURL = distillURL.appendingPathComponent("DistillCLIState.json")
        let stateJSON: [String: Any] = [
            "base_url": sidecar.ready.baseURL,
            "auth_token": authToken,
            "pid": sidecar.ready.pid,
        ]
        try JSONSerialization.data(withJSONObject: stateJSON).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)

        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .codex,
            threadId: "10000000-0000-0000-0000-000000000001",
            rootRunId: "40000000-0000-0000-0000-000000000004",
            attemptId: "50000000-0000-0000-0000-000000000005",
            workspaceId: "20000000-0000-0000-0000-000000000002",
            projectId: "30000000-0000-0000-0000-000000000003",
            enabledLanes: ["distill"]
        )
        var providerEnvironment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
        providerEnvironment["REMOTE_CODE_AGENT_PROVIDER"] = "codex"
        providerEnvironment["REMOTE_CODE_DISTILL_STATE_PATH"] = stateURL.path
        providerEnvironment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = supportURL.path

        let workspace = supportURL.appendingPathComponent("workspace", isDirectory: true)
        let wrapperBin = supportURL.appendingPathComponent("managed-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wrapperBin, withIntermediateDirectories: true)
        let noisySource = """
        for index in 1...200 {
            print("SR2 E2E noisy output line \\(index)")
        }
        """
        try Data(noisySource.utf8).write(to: workspace.appendingPathComponent("noisy.swift"))
        try Data("UNIQUE_EXACT_MATCH\n".utf8).write(to: workspace.appendingPathComponent("README.md"))
        // `rg` is intentionally not a managed wrapper: exact-output commands
        // stay on the real PATH and are proven by the no-request assertion.
        for command in ["swift", "distill"] {
            try FileManager.default.createSymbolicLink(
                at: wrapperBin.appendingPathComponent(command),
                withDestinationURL: binary
            )
        }
        providerEnvironment["PATH"] = "\(wrapperBin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        providerEnvironment["RC_REMOTE_CODE_MANAGED_BIN"] = wrapperBin.path

        let rawOutput = (1...200).map { "SR2 E2E noisy output line \($0)" }.joined(separator: "\n") + "\n"
        let compressed = try runShell(
            "swift noisy.swift | distill \"Summarize the key output and exit status\"",
            env: providerEnvironment,
            currentDirectory: workspace
        )
        XCTAssertEqual(compressed.code, 0, "stderr=\(compressed.err)")
        XCTAssertFalse(compressed.out.isEmpty)
        XCTAssertFalse(compressed.out == rawOutput, "the live provider pipe must not fail open")
        XCTAssertLessThan(compressed.out.utf8.count, rawOutput.utf8.count)
        XCTAssertTrue(compressed.out.contains("[[rc:"), compressed.out)

        let metrics = try await liveJSON(
            URL(string: sidecar.ready.baseURL + "/metrics")!,
            authToken: authToken
        )
        XCTAssertEqual(metrics["total_requests"] as? Int, 1,
                       "one explicit provider pipe must issue exactly one live sidecar request")
        XCTAssertEqual(metrics["successful_requests"] as? Int, 1)
        XCTAssertEqual(metrics["tool_output_compressed"] as? Int, 1)

        let savings = try db.prepare("""
            SELECT COUNT(*), SUM(input_tokens), SUM(output_tokens), SUM(saved_tokens),
                   SUM(delivered), MIN(engine)
            FROM token_saver_savings;
        """)
        XCTAssertTrue(try savings.step())
        XCTAssertEqual(savings.columnInt64(0), 1, "one live request must create exactly one savings row")
        XCTAssertGreaterThan(savings.columnInt64(1), savings.columnInt64(2))
        XCTAssertGreaterThan(savings.columnInt64(3), 0, "live delivered savings must be positive")
        XCTAssertEqual(savings.columnInt64(4), 1, "only a delivered response counts as savings")
        XCTAssertNotEqual(savings.columnText(5), "verbatim")

        // Receipt authorization remains fail-open: stale hints and a live lease
        // cannot authorize an explicit pipe on their own, and cannot add a
        // second sidecar attempt or savings row.
        var noReceipt = providerEnvironment
        noReceipt.removeValue(forKey: TokenSaverExecutionReceipt.envKey)
        let denied = try runShell(
            "swift noisy.swift | distill \"Summarize the key output and exit status\"",
            env: noReceipt,
            currentDirectory: workspace
        )
        XCTAssertEqual(denied.code, 0)
        XCTAssertEqual(denied.out, rawOutput, "missing receipt must preserve exact piped bytes")

        // Exact-output tools remain byte-preserving even for an admitted run.
        let exact = try runShell(
            "rg -n UNIQUE_EXACT_MATCH README.md",
            env: providerEnvironment,
            currentDirectory: workspace
        )
        XCTAssertEqual(exact.code, 0)
        XCTAssertEqual(exact.out, "1:UNIQUE_EXACT_MATCH\n")
        let metricsAfterBypass = try await liveJSON(
            URL(string: sidecar.ready.baseURL + "/metrics")!,
            authToken: authToken
        )
        XCTAssertEqual(metricsAfterBypass["total_requests"] as? Int, 1,
                       "receipt denial and exact-output bypass must not reach the sidecar")
    }

    func test_liveCodexGeneralInterceptorAndExplicitPipeEachCompressExactlyOnce() async throws {
        // WHY: Codex's absolute zsh bypasses PATH wrapper ownership. The managed
        // aggregate interceptor must compress one safe bare command, while an
        // explicit pipe remains its own single pass; both stay recoverable.
        guard ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_TEST"] == "1" else {
            throw XCTSkip("Set REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_TEST=1 (+ live model dir) to run the real sidecar E2E.")
        }
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let modelSupportCandidates = [
            ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_LIVE_MODEL_DIR"],
            "/tmp/r5-live-diagnose.zOLMZM",
            "/tmp/RemoteCodeAgentCanary-r7.h7i07Q/state/Application Support/RemoteCodeAgentCanary",
        ].compactMap { $0 }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let modelSupport = try XCTUnwrap(
            modelSupportCandidates.first(where: { support in
                let installer = TokenSaverModelInstaller(appSupportDirectory: support)
                guard let manifest = installer.loadManifest(), manifest.isApprovedModel else { return false }
                return FileManager.default.fileExists(
                    atPath: installer.modelStorageDirectory(
                        modelID: manifest.modelID,
                        revision: manifest.revision
                    ).path
                ) && FileManager.default.fileExists(atPath: installer.encoderManifestURL.path)
            }),
            "an installed MLX model and encoder manifest are required for this live provider E2E"
        )
        let modelInstaller = TokenSaverModelInstaller(appSupportDirectory: modelSupport)
        let manifest = try XCTUnwrap(modelInstaller.loadManifest())

        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-distill-live-codex-bare-\(UUID().uuidString)", isDirectory: true)
        let distillURL = supportURL.appendingPathComponent("Distill", isDirectory: true)
        try FileManager.default.createDirectory(at: distillURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: distillURL.appendingPathComponent("Models", isDirectory: true),
            withDestinationURL: modelInstaller.distillDirectory.appendingPathComponent("Models", isDirectory: true)
        )
        try FileManager.default.createSymbolicLink(
            at: distillURL.appendingPathComponent("Encoders", isDirectory: true),
            withDestinationURL: modelInstaller.distillDirectory.appendingPathComponent("Encoders", isDirectory: true)
        )
        for source in [
            modelInstaller.manifestURL,
            modelInstaller.encoderManifestURL,
            modelInstaller.validationCacheURL,
        ] where FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.copyItem(
                at: source,
                to: distillURL.appendingPathComponent(source.lastPathComponent)
            )
        }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: supportURL.path).run()
        let settings = SettingsStore(db: db)
        settings.update { $0.tokenSaverEnabled = true }
        let settingsRepository = SettingsRepository(db: db)
        try settingsRepository.set("private.account.session", #"{"user":{"subscribed":true}}"#)

        let authToken = "r7-live-bare-\(UUID().uuidString)"
        let sidecar = try launchLiveSidecar(
            binary: binary,
            supportDirectory: supportURL,
            authToken: authToken,
            modelID: manifest.modelID,
            modelURL: manifest.modelURL
        )
        defer {
            if sidecar.process.isRunning {
                sidecar.process.terminate()
                sidecar.process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: supportURL)
        }
        XCTAssertEqual(sidecar.ready.runtime, "mlx")

        let stateURL = distillURL.appendingPathComponent("DistillCLIState.json")
        let stateJSON: [String: Any] = [
            "base_url": sidecar.ready.baseURL,
            "auth_token": authToken,
            "pid": sidecar.ready.pid,
        ]
        try JSONSerialization.data(withJSONObject: stateJSON).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)

        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .codex,
            threadId: "10000000-0000-0000-0000-000000000001",
            rootRunId: "40000000-0000-0000-0000-000000000004",
            attemptId: "50000000-0000-0000-0000-000000000005",
            workspaceId: "20000000-0000-0000-0000-000000000002",
            projectId: "30000000-0000-0000-0000-000000000003",
            enabledLanes: ["distill"]
        )
        var providerEnvironment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
        providerEnvironment["REMOTE_CODE_AGENT_PROVIDER"] = "codex"
        providerEnvironment["REMOTE_CODE_DISTILL_STATE_PATH"] = stateURL.path
        providerEnvironment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = supportURL.path
        providerEnvironment["RC_LOGIN_SHELL_ENV_IMPORT"] = "0"

        let workspace = supportURL.appendingPathComponent("workspace", isDirectory: true)
        let providerHome = supportURL.appendingPathComponent("provider-home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let installer = AgentSkillInstaller(homeDirectory: providerHome)
        let runtimeInstaller = try XCTUnwrap(installer.runtimeInstaller(for: binary))
        try runtimeInstaller.installProviderShellBridge()
        let wrapperBin = runtimeInstaller.managedCLIBinURL
        try FileManager.default.createDirectory(at: wrapperBin, withIntermediateDirectories: true)
        let noisySource = """
        for index in 1...200 {
            print("SR2 E2E noisy output line \\(index)")
        }
        """
        try Data(noisySource.utf8).write(to: workspace.appendingPathComponent("noisy.swift"))
        try Data("UNIQUE_EXACT_MATCH\n".utf8).write(to: workspace.appendingPathComponent("README.md"))
        // `rg`/`less` are exact/TUI surfaces and intentionally are not managed
        // aliases in production. Their raw checks below use the real PATH.
        for command in ["swift", "distill"] {
            try FileManager.default.createSymbolicLink(
                at: wrapperBin.appendingPathComponent(command),
                withDestinationURL: binary
            )
        }
        let systemPath = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/bin:/bin"
        providerEnvironment["PATH"] = "\(wrapperBin.path):\(systemPath)"
        providerEnvironment["RC_REMOTE_CODE_MANAGED_BIN"] = wrapperBin.path
        providerEnvironment["RC_REMOTE_CODE_MANAGED_ZDOTDIR"] = runtimeInstaller.providerShellBridgeURL.path
        providerEnvironment["RC_REMOTE_CODE_ORIGINAL_ZDOTDIR"] = providerHome.path
        providerEnvironment["RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR"] = providerHome.path
        providerEnvironment["ZDOTDIR"] = runtimeInstaller.providerShellBridgeURL.path
        providerEnvironment["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"] = "1"
        providerEnvironment[AgentSkillInstaller.toolShellProtocolEnvironmentKey] =
            AgentSkillInstaller.toolShellProtocolVersion
        providerEnvironment[AgentSkillInstaller.toolShellBinaryEnvironmentKey] =
            binary.resolvingSymlinksInPath().standardizedFileURL.path

        let appServer = try makeExecutable(
            at: supportURL,
            name: "fake-codex.js",
            body: """
            #!/usr/bin/env node
            const { spawnSync } = require("child_process");
            const childEnvironment = { ...process.env };
            const prefix = "shell_environment_policy.set.";
            for (let index = 2; index + 1 < process.argv.length; index += 1) {
              if (process.argv[index] !== "-c") continue;
              const assignment = process.argv[index + 1];
              if (!assignment.startsWith(prefix)) continue;
              const separator = assignment.indexOf("=", prefix.length);
              if (separator < 0) continue;
              const key = assignment.slice(prefix.length, separator);
              const encoded = assignment.slice(separator + 1);
              try { childEnvironment[key] = JSON.parse(encoded); } catch (_) {}
            }
            const command = childEnvironment.RC_R7_E2E_COMMAND || "command -v swift; swift noisy.swift";
            const result = spawnSync("/bin/zsh", ["-lc", command], {
              cwd: process.cwd(),
              env: childEnvironment,
              encoding: "utf8"
            });
            process.stdout.write(result.stdout || "");
            process.stderr.write(result.stderr || "");
            process.exit(result.status === null ? 1 : result.status);
            """
        )

        func runProvider(
            environment: [String: String],
            command: String
        ) throws -> (out: String, err: String, code: Int32, arguments: [String]) {
            var launchEnvironment = environment
            launchEnvironment["RC_R7_E2E_COMMAND"] = command
            let process = try ProviderSubprocessLauncher.makeProcess(
                provider: .codex,
                executablePath: appServer.path,
                arguments: ["app-server"],
                currentDirectory: workspace.path,
                environment: launchEnvironment
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
                process.terminationStatus,
                process.arguments ?? []
            )
        }

        let resolved = try runProvider(
            environment: providerEnvironment,
            command: "command -v swift"
        )
        XCTAssertEqual(resolved.code, 0, "stderr=\(resolved.err)")
        XCTAssertEqual(resolved.out, "\(wrapperBin.appendingPathComponent("swift").path)\n")

        let rawOutput = (1...200).map { "SR2 E2E noisy output line \($0)" }.joined(separator: "\n") + "\n"
        XCTAssertEqual(rawOutput.utf8.count, 5_892, "the E2E must keep the exact R7 noisy-output fixture")
        let bare = try runProvider(
            environment: providerEnvironment,
            command: "swift noisy.swift"
        )
        XCTAssertEqual(bare.code, 0, "stderr=\(bare.err)")
        XCTAssertTrue(
            bare.arguments.contains(where: { $0.contains("shell_environment_policy.set.PATH=") }),
            "the launcher must pass the provider PATH into Codex's shell policy"
        )
        XCTAssertTrue(
            bare.arguments.contains(where: { $0.contains("shell_environment_policy.set.ZDOTDIR=") }),
            "the launcher must pass the managed zsh bridge into Codex's shell policy"
        )
        XCTAssertTrue(
            bare.arguments.contains(where: { $0.contains("shell_environment_policy.set.RC_REMOTE_CODE_UNOWNED_TOOL_SHELL=") }),
            "the launcher must mark Codex's absolute tool shell as unowned"
        )
        XCTAssertTrue(
            bare.arguments.contains(where: { $0.contains("shell_environment_policy.set.RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT=") }),
            "the admitted Codex shell policy must carry the aggregate-interceptor gate"
        )
        XCTAssertTrue(bare.out.contains("[[rc:"), "bare interceptor output must carry recovery: \(bare.out)")
        XCTAssertLessThan(bare.out.utf8.count, rawOutput.utf8.count)
        let bareHandle = try XCTUnwrap(SR2WirePolicy.recoveryMarker(in: bare.out))
        let bareCapability = String(bareHandle.dropFirst("[[rc:".count).dropLast(2))
        let bareRecovered = try runProvider(
            environment: providerEnvironment,
            command: "distill retrieve \(bareCapability)"
        )
        XCTAssertEqual(bareRecovered.code, 0, "stderr=\(bareRecovered.err)")
        XCTAssertEqual(bareRecovered.out, rawOutput, "interceptor recovery must be byte-exact")

        let metricsAfterBare = try await liveJSON(
            URL(string: sidecar.ready.baseURL + "/metrics")!,
            authToken: authToken
        )
        XCTAssertEqual(metricsAfterBare["total_requests"] as? Int, 1,
                       "the general interceptor must issue exactly one request")

        let compressed = try runProvider(
            environment: providerEnvironment,
            command: "set -o pipefail;swift noisy.swift | distill \"Summarize the key output and exit status\""
        )
        XCTAssertEqual(compressed.code, 0, "stderr=\(compressed.err)")
        XCTAssertTrue(compressed.out.contains("[[rc:"), "explicit provider pipe must carry recovery: \(compressed.out)")
        XCTAssertLessThan(compressed.out.utf8.count, rawOutput.utf8.count)
        let pipeHandle = try XCTUnwrap(SR2WirePolicy.recoveryMarker(in: compressed.out))
        let pipeCapability = String(pipeHandle.dropFirst("[[rc:".count).dropLast(2))
        let pipeRecovered = try runProvider(
            environment: providerEnvironment,
            command: "distill retrieve \(pipeCapability)"
        )
        XCTAssertEqual(pipeRecovered.code, 0, "stderr=\(pipeRecovered.err)")
        XCTAssertEqual(pipeRecovered.out, rawOutput, "explicit-pipe recovery must be byte-exact")

        let metrics = try await liveJSON(
            URL(string: sidecar.ready.baseURL + "/metrics")!,
            authToken: authToken
        )
        XCTAssertEqual(metrics["total_requests"] as? Int, 2,
                       "interceptor and explicit pipe must each issue one request")
        XCTAssertEqual(metrics["successful_requests"] as? Int, 2)
        XCTAssertEqual(metrics["tool_output_compressed"] as? Int, 2)

        let savings = try db.prepare("""
            SELECT COUNT(*), SUM(input_tokens), SUM(output_tokens), SUM(saved_tokens),
                   SUM(delivered), MIN(engine)
            FROM token_saver_savings;
        """)
        XCTAssertTrue(try savings.step())
        XCTAssertEqual(savings.columnInt64(0), 2, "pipe and interceptor must create separate savings rows")
        XCTAssertGreaterThan(savings.columnInt64(1), savings.columnInt64(2))
        XCTAssertGreaterThan(savings.columnInt64(3), 0, "explicit-pipe delivered savings must be positive")
        XCTAssertEqual(savings.columnInt64(4), 2, "both compressions must be delivered")
        XCTAssertNotEqual(savings.columnText(5), "verbatim")
        let origins = try db.prepare("SELECT cache_state FROM token_saver_savings ORDER BY id;")
        var cacheStates: [String] = []
        while try origins.step() { cacheStates.append(origins.columnText(0) ?? "") }
        XCTAssertEqual(Set(cacheStates), ["tool_output_interceptor", "tool_output_pipe"])

        let pipeline = try runProvider(
            environment: providerEnvironment,
            command: "swift noisy.swift | wc -l"
        )
        XCTAssertEqual(pipeline.code, 0, "stderr=\(pipeline.err)")
        XCTAssertEqual(pipeline.out.trimmingCharacters(in: .whitespacesAndNewlines), "200")
        let metricsAfterPipeline = try await liveJSON(
            URL(string: sidecar.ready.baseURL + "/metrics")!,
            authToken: authToken
        )
        XCTAssertEqual(metricsAfterPipeline["total_requests"] as? Int, 2,
                       "an intermediate pipeline wrapper must remain raw")

        var noReceipt = providerEnvironment
        noReceipt.removeValue(forKey: TokenSaverExecutionReceipt.envKey)
        let denied = try runProvider(
            environment: noReceipt,
            command: "swift noisy.swift"
        )
        XCTAssertEqual(denied.code, 0, "stderr=\(denied.err)")
        XCTAssertFalse(denied.out.contains("[[rc:"), "missing receipt must fail open to raw output")
        XCTAssertTrue(denied.out.contains(rawOutput), "missing receipt must preserve every bare-command line")
        let metricsAfterDenied = try await liveJSON(
            URL(string: sidecar.ready.baseURL + "/metrics")!,
            authToken: authToken
        )
        XCTAssertEqual(metricsAfterDenied["total_requests"] as? Int, 2,
                       "missing receipt must not reach the sidecar")

        let exact = try runProvider(
            environment: providerEnvironment,
            command: "rg -n UNIQUE_EXACT_MATCH README.md"
        )
        XCTAssertEqual(exact.code, 0, "stderr=\(exact.err)")
        XCTAssertEqual(exact.out, "1:UNIQUE_EXACT_MATCH\n")
        let tui = try runProvider(
            environment: providerEnvironment,
            command: "less README.md"
        )
        XCTAssertEqual(tui.code, 0, "stderr=\(tui.err)")
        XCTAssertEqual(tui.out, "UNIQUE_EXACT_MATCH\n")
        let metricsAfterBypass = try await liveJSON(
            URL(string: sidecar.ready.baseURL + "/metrics")!,
            authToken: authToken
        )
        XCTAssertEqual(metricsAfterBypass["total_requests"] as? Int, 2,
                       "exact and TUI commands must remain raw and bypass the sidecar")
    }

    func test_absoluteZshCompoundFailsOpenWhileBareInterceptorAndPipeStaySinglePass() async throws {
        // WHY: Codex resolves its user shell independently of PATH and may run
        // an absolute zsh whose mixed compound was not marked by our aggregate
        // wrapper. Compressing only its last ordinary child loses the exact
        // prefix from the provider-visible tool result. An unowned mixed shell
        // must therefore fail open as one raw stream; the provider recovers
        // savings by issuing exact and ordinary commands as separate calls.
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let supportURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("managed-distill-compound-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: supportURL.path).run()
        let settings = SettingsStore(db: db)
        settings.update { $0.tokenSaverEnabled = true }
        let settingsRepository = SettingsRepository(db: db)
        try settingsRepository.set("private.account.session", #"{"user":{"subscribed":true}}"#)
        let savingsRepo = TokenSaverSavingsRepository(db: db)
        let config = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: supportURL.path)
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let recoveryStore = TestScopedRecoveryStore()
        let server = DistillHTTPServer(
            configuration: config,
            scheduler: scheduler,
            scopedRecoveryStore: recoveryStore,
            onSuccess: { request, response, threadID in
                guard let record = DistillSavingsCalculator.record(
                    for: request,
                    response: response,
                    threadID: threadID
                ) else { return }
                _ = try? savingsRepo.record(
                    provider: record.provider,
                    mode: record.mode,
                    inputTokens: record.inputTokens,
                    outputTokens: record.outputTokens,
                    savedTokens: record.savedTokens,
                    cacheState: record.cacheState,
                    contentType: "unknown",
                    engine: record.routeStage?.rawValue ?? "unknown",
                    attributability: record.attributability,
                    delivered: record.delivered,
                    threadID: record.threadID
                )
            }
        )
        let ready = try await server.start()
        defer { server.stop() }

        let stateURL = supportURL
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stateJSON: [String: Any] = [
            "base_url": ready.baseURL,
            "auth_token": "tok",
            "pid": ready.pid,
        ]
        try JSONSerialization.data(withJSONObject: stateJSON).write(to: stateURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .codex,
            threadId: "10000000-0000-0000-0000-000000000001",
            rootRunId: "40000000-0000-0000-0000-000000000004",
            attemptId: "50000000-0000-0000-0000-000000000005",
            workspaceId: "20000000-0000-0000-0000-000000000002",
            projectId: "30000000-0000-0000-0000-000000000003"
        )
        var environment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
        environment["REMOTE_CODE_AGENT_PROVIDER"] = "codex"
        environment["REMOTE_CODE_DISTILL_STATE_PATH"] = stateURL.path
        environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = supportURL.path
        environment["RC_LOGIN_SHELL_ENV_IMPORT"] = "0"

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("managed-distill-compound-bin-\(UUID().uuidString)", isDirectory: true)
        let installer = AgentSkillInstaller(homeDirectory: root)
        let runtimeInstaller = try XCTUnwrap(installer.runtimeInstaller(for: binary))
        try runtimeInstaller.installProviderShellBridge()
        let pinnedService = try XCTUnwrap(runtimeInstaller.pinnedServiceBinaryURL)
        let wrapperBin = runtimeInstaller.managedCLIBinURL
        let realBin = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let noisySource = """
        import Foundation

        for index in 1...200 {
            print("build line \\(index): repeated diagnostic output")
        }
        """
        try Data(noisySource.utf8).write(to: root.appendingPathComponent("noisy.swift"))
        try Data("UNIQUE_EXACT_MATCH\n".utf8).write(to: root.appendingPathComponent("README.md"))
        let wrappedSwift = wrapperBin.appendingPathComponent("swift")
        let wrappedDistill = wrapperBin.appendingPathComponent("distill")
        try FileManager.default.createSymbolicLink(at: wrappedSwift, withDestinationURL: pinnedService)
        try FileManager.default.createSymbolicLink(at: wrappedDistill, withDestinationURL: pinnedService)
        let path = "\(wrapperBin.path):\(realBin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        environment["PATH"] = path
        environment["RC_REMOTE_CODE_MANAGED_BIN"] = wrapperBin.path
        environment["RC_REMOTE_CODE_MANAGED_ZDOTDIR"] = runtimeInstaller.providerShellBridgeURL.path
        environment[AgentSkillInstaller.runtimeRootEnvironmentKey] =
            wrapperBin.deletingLastPathComponent().path
        environment["RC_REMOTE_CODE_ORIGINAL_ZDOTDIR"] = root.path
        environment["RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR"] = root.path
        environment["ZDOTDIR"] = runtimeInstaller.providerShellBridgeURL.path
        environment["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"] = "1"
        environment[AgentSkillInstaller.toolShellProtocolEnvironmentKey] =
            AgentSkillInstaller.toolShellProtocolVersion
        environment[AgentSkillInstaller.toolShellBinaryEnvironmentKey] =
            pinnedService.resolvingSymlinksInPath().standardizedFileURL.path

        // Keep the absolute shell alive after the noisy child, matching the
        // Codex execve-intercept topology where the child retains a shell
        // parent instead of system zsh's final-command exec optimization.
        let payload = "command -v swift;command -v distill;rg -n UNIQUE_EXACT_MATCH README.md;swift noisy.swift;/usr/bin/true"
        let expectedExactPrefix = "\(wrappedSwift.path)\n\(wrappedDistill.path)\n1:UNIQUE_EXACT_MATCH\n"

        let appServer = try makeExecutable(
            at: root,
            name: "fake-codex-compound.js",
            body: """
            #!/usr/bin/env node
            const { spawnSync } = require("child_process");
            const childEnvironment = { ...process.env };
            const prefix = "shell_environment_policy.set.";
            for (let index = 2; index + 1 < process.argv.length; index += 1) {
              if (process.argv[index] !== "-c") continue;
              const assignment = process.argv[index + 1];
              if (!assignment.startsWith(prefix)) continue;
              const separator = assignment.indexOf("=", prefix.length);
              if (separator < 0) continue;
              const key = assignment.slice(prefix.length, separator);
              try { childEnvironment[key] = JSON.parse(assignment.slice(separator + 1)); } catch (_) {}
            }
            const result = spawnSync("/bin/zsh", [
              "-lc", childEnvironment.RC_R9_E2E_COMMAND || \(String(reflecting: payload))
            ], {
              cwd: \(String(reflecting: root.path)),
              env: childEnvironment,
              encoding: "utf8"
            });
            process.stdout.write(result.stdout || "");
            process.stderr.write(result.stderr || "");
            process.exit(result.status === null ? 1 : result.status);
            """
        )
        func runProvider(_ command: String) throws -> (out: String, err: String, code: Int32, arguments: [String]) {
            var launchEnvironment = environment
            launchEnvironment["RC_R9_E2E_COMMAND"] = command
            let process = try ProviderSubprocessLauncher.makeProcess(
                provider: .codex,
                executablePath: appServer.path,
                arguments: ["app-server"],
                currentDirectory: root.path,
                environment: launchEnvironment
            )
            let providerOutput = Pipe()
            let providerError = Pipe()
            process.standardOutput = providerOutput
            process.standardError = providerError
            try process.run()
            let outputData = providerOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = providerError.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                String(decoding: outputData, as: UTF8.self),
                String(decoding: errorData, as: UTF8.self),
                process.terminationStatus,
                process.arguments ?? []
            )
        }

        let violatingCompound = try runProvider(payload)
        let output = violatingCompound.out
        XCTAssertEqual(violatingCompound.code, 0, "stderr=\(violatingCompound.err)")
        XCTAssertTrue(
            violatingCompound.arguments.contains(where: {
                $0.contains("shell_environment_policy.set.RC_REMOTE_CODE_PROVIDER_TERMINAL_STDOUT=")
            }),
            "the E2E must use the admitted real-provider shell environment"
        )
        XCTAssertTrue(output.hasPrefix(expectedExactPrefix), output)
        XCTAssertEqual(
            String(output.prefix(expectedExactPrefix.utf8.count)),
            expectedExactPrefix,
            "the first three command results must remain byte-exact and ordered"
        )
        let rawNoisyOutput = (1...200)
            .map { "build line \($0): repeated diagnostic output" }
            .joined(separator: "\n") + "\n"
        XCTAssertEqual(
            output,
            expectedExactPrefix + rawNoisyOutput,
            "an unowned absolute-zsh compound must preserve every exact and ordinary byte"
        )
        XCTAssertNil(
            SR2WirePolicy.recoveryMarker(in: output),
            "fail-open compound output must not claim a partial recovery payload"
        )

        let metricsAfterCompound = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(
            metricsAfterCompound.totalRequests,
            0,
            "a violating mixed compound must not send only its last child to Distill"
        )
        XCTAssertEqual(metricsAfterCompound.successfulRequests, 0)

        let execOptimizedCompound = try runProvider(
            "command -v swift;command -v distill;rg -n UNIQUE_EXACT_MATCH README.md;swift noisy.swift"
        )
        XCTAssertEqual(execOptimizedCompound.code, 0, "stderr=\(execOptimizedCompound.err)")
        XCTAssertEqual(
            execOptimizedCompound.out,
            expectedExactPrefix + rawNoisyOutput,
            "the final-child exec-optimization shape must not lose aggregate ownership"
        )
        let metricsAfterExecOptimization = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(
            metricsAfterExecOptimization.totalRequests,
            0,
            "a shell that disappears before its final child must still fail open wholly raw"
        )

        let forgedMarker = try runProvider(
            "command -v swift;export REMOTE_CODE_WRAP_SEGMENTED_SHELL=$PPID;swift noisy.swift"
        )
        XCTAssertEqual(forgedMarker.code, 0, "stderr=\(forgedMarker.err)")
        XCTAssertEqual(
            forgedMarker.out,
            "\(wrappedSwift.path)\n" + rawNoisyOutput,
            "a PID-only marker from an unowned provider shell must not transfer suffix ownership"
        )
        let metricsAfterForgedMarker = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(metricsAfterForgedMarker.totalRequests, 0, "a forged aggregate marker must remain raw")

        let exactSwift = try runProvider("command -v swift")
        XCTAssertEqual(exactSwift.code, 0, "stderr=\(exactSwift.err)")
        XCTAssertEqual(exactSwift.out, "\(wrappedSwift.path)\n")
        let exactDistill = try runProvider("command -v distill")
        XCTAssertEqual(exactDistill.code, 0, "stderr=\(exactDistill.err)")
        XCTAssertEqual(exactDistill.out, "\(wrappedDistill.path)\n")
        let exactSearch = try runProvider("rg -n UNIQUE_EXACT_MATCH README.md")
        XCTAssertEqual(exactSearch.code, 0, "stderr=\(exactSearch.err)")
        XCTAssertEqual(exactSearch.out, "1:UNIQUE_EXACT_MATCH\n")
        let metricsAfterExactCalls = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(metricsAfterExactCalls.totalRequests, 0, "separate exact calls must stay raw")

        let bareNoisy = try runProvider("swift noisy.swift")
        XCTAssertEqual(bareNoisy.code, 0, "stderr=\(bareNoisy.err) args=\(bareNoisy.arguments)")
        XCTAssertFalse(
            bareNoisy.out.contains("build line 100:"),
            "the aggregate interceptor must compress one safe bare command; stderr=\(bareNoisy.err); args=\(bareNoisy.arguments)"
        )
        let bareRecoveryMarker = try XCTUnwrap(SR2WirePolicy.recoveryMarker(in: bareNoisy.out))
        let bareRecoveryHandle = String(bareRecoveryMarker.dropFirst("[[rc:".count).dropLast(2))
        XCTAssertEqual(
            try recoveryStore.retrieveOriginal(
                capability: bareRecoveryHandle,
                context: testRecoveryContext()
            ),
            Data(rawNoisyOutput.utf8),
            "automatic-interceptor recovery must preserve every original byte"
        )
        let metricsAfterBareNoisy = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(metricsAfterBareNoisy.totalRequests, 1, "bare interceptor must issue exactly one request")

        let noisy = try runProvider("set -o pipefail;swift noisy.swift | distill \"summarize build output\"")
        XCTAssertEqual(noisy.code, 0, "stderr=\(noisy.err)")
        XCTAssertFalse(noisy.out.contains("build line 100:"), "the separate explicit pipe must be compressed")
        XCTAssertLessThan(noisy.out.split(whereSeparator: \.isNewline).count, 200, noisy.out)
        let recoveryMarker = try XCTUnwrap(
            SR2WirePolicy.recoveryMarker(in: noisy.out),
            "separate ordinary output must carry recovery: \(noisy.out)"
        )
        let recoveryHandle = String(recoveryMarker.dropFirst("[[rc:".count).dropLast(2))
        let recovered = try XCTUnwrap(
            recoveryStore.retrieveOriginal(
                capability: recoveryHandle,
                context: testRecoveryContext()
            )
        )
        XCTAssertEqual(recovered, Data(rawNoisyOutput.utf8))

        let metrics = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(metrics.totalRequests, 2, "interceptor and explicit pipe must each reach the sidecar once")
        XCTAssertEqual(metrics.successfulRequests, 2)
        let savingsRows = try db.prepare("SELECT COUNT(*), SUM(delivered), SUM(saved_tokens) FROM token_saver_savings;")
        XCTAssertTrue(try savingsRows.step())
        XCTAssertEqual(
            savingsRows.columnInt64(0),
            2,
            "automatic and explicit routes create separate rows"
        )
        XCTAssertEqual(savingsRows.columnInt64(1), 2, "both noisy compressions must be delivered")
        XCTAssertGreaterThan(savingsRows.columnInt64(2), 0, "delivered compound output must report savings")
        let cacheStateRows = try db.prepare("SELECT cache_state FROM token_saver_savings ORDER BY id;")
        var cacheStates: [String] = []
        while try cacheStateRows.step() { cacheStates.append(cacheStateRows.columnText(0) ?? "") }
        XCTAssertEqual(Set(cacheStates), ["tool_output_interceptor", "tool_output_pipe"])
        let failingPayload = "command -v swift;command -v distill;rg -n UNIQUE_EXACT_MATCH README.md;/usr/bin/false"
        let failing = try runProvider(failingPayload)
        XCTAssertEqual(failing.code, 1, "the validated payload must preserve the original final command status")
        XCTAssertEqual(
            failing.out,
            expectedExactPrefix,
            "the injected export must stay silent and preserve the original command visibility"
        )
        let metricsAfterFailure = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(metricsAfterFailure.totalRequests, 2, "empty unwrapped failure must not add a request")
        let rowsAfterFailure = try db.prepare("SELECT COUNT(*), SUM(delivered) FROM token_saver_savings;")
        XCTAssertTrue(try rowsAfterFailure.step())
        XCTAssertEqual(rowsAfterFailure.columnInt64(0), 2, "empty failing output must not add a savings row")
        XCTAssertEqual(rowsAfterFailure.columnInt64(1), 2)

        let unsafePayload = "rg -n UNIQUE_EXACT_MATCH README.md;swift noisy.swift | wc -l"
        let unsafe = try runProvider(unsafePayload)
        XCTAssertEqual(unsafe.code, 0, "stderr=\(unsafe.err)")
        XCTAssertEqual(
            unsafe.out,
            "1:UNIQUE_EXACT_MATCH\n     200\n",
            "an ambiguous pipeline must execute once as an entirely raw shell command"
        )
        let metricsAfterUnsafe = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(metricsAfterUnsafe.totalRequests, 2, "unsafe syntax must not reach Distill")
        let rowsAfterUnsafe = try db.prepare("SELECT COUNT(*), SUM(delivered) FROM token_saver_savings;")
        XCTAssertTrue(try rowsAfterUnsafe.step())
        XCTAssertEqual(rowsAfterUnsafe.columnInt64(0), 2)
        XCTAssertEqual(rowsAfterUnsafe.columnInt64(1), 2)

        // A nonterminal wrapper must mark its real child as parent-owned. npm
        // commonly uses `#!/usr/bin/env node`; without the marker, the nested
        // node wrapper can mistake the provider's external reader for its own
        // terminal stream and Distill an intermediate pipeline stage.
        let wrappedNpm = wrapperBin.appendingPathComponent("npm")
        let wrappedNode = wrapperBin.appendingPathComponent("node")
        try FileManager.default.createSymbolicLink(at: wrappedNpm, withDestinationURL: binary)
        try FileManager.default.createSymbolicLink(at: wrappedNode, withDestinationURL: binary)
        let realNpm = try makeExecutable(
            at: realBin,
            name: "npm",
            body: "#!/usr/bin/env node\n"
        )
        let realNode = try makeExecutable(
            at: realBin,
            name: "node",
            body: "#!/bin/sh\nprintf 'PARENT=%s\\n' \"${REMOTE_CODE_WRAP_PARENT:-unset}\"\ni=1\nwhile [ $i -le 40 ]; do printf 'npm raw line %s\\n' \"$i\"; i=$((i + 1)); done\n"
        )
        let nestedPipeline = try runProcess(
            URL(fileURLWithPath: "/bin/zsh"),
            ["-c", "npm --version | /bin/cat"],
            env: environment,
            stdin: "",
            currentDirectory: root
        )
        let expectedNestedOutput = "PARENT=1\n" + (1...40)
            .map { "npm raw line \($0)" }
            .joined(separator: "\n") + "\n"
        XCTAssertEqual(nestedPipeline.code, 0, "stderr=\(nestedPipeline.err)")
        XCTAssertEqual(
            nestedPipeline.out,
            expectedNestedOutput,
            "the nested shebang interpreter must preserve the intermediate pipeline bytes"
        )
        let metricsAfterNestedPipeline = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(
            metricsAfterNestedPipeline.totalRequests,
            2,
            "npm -> env node in an intermediate pipeline must not create a Distill request"
        )

        // Defense in depth for the wrap entry point: verification hashes are
        // exact evidence and must not be summarized when terminal-to-agent.
        let realShasum = try makeExecutable(
            at: realBin,
            name: "shasum",
            body: "#!/bin/sh\nprintf '0123456789abcdef  artifact.bin\\n'\n"
        )
        let digest = try runProcess(
            binary,
            ["wrap", "shasum", "artifact.bin"],
            env: environment,
            stdin: "",
            currentDirectory: root
        )
        XCTAssertEqual(digest.code, 0, "stderr=\(digest.err)")
        XCTAssertEqual(digest.out, "0123456789abcdef  artifact.bin\n")
        let metricsAfterDigest = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(metricsAfterDigest.totalRequests, 2, "digest output must bypass Distill")

        let wrappedZsh = wrapperBin.appendingPathComponent("zsh")
        try FileManager.default.createSymbolicLink(at: wrappedZsh, withDestinationURL: binary)
        var ownedEnvironment = environment
        ownedEnvironment["RC_REMOTE_CODE_UNOWNED_TOOL_SHELL"] = "1"
        let ownedAggregate = try runProcess(
            wrappedZsh,
            ["-c", payload],
            env: ownedEnvironment,
            stdin: "",
            currentDirectory: root
        )
        XCTAssertEqual(ownedAggregate.code, 0, "stderr=\(ownedAggregate.err)")
        XCTAssertEqual(
            ownedAggregate.out,
            expectedExactPrefix + rawNoisyOutput,
            "a mixed aggregate must fail open as one byte-preserving shell payload"
        )
        XCTAssertNil(SR2WirePolicy.recoveryMarker(in: ownedAggregate.out))
        let metricsAfterOwnedAggregate = await server.metrics.snapshot(activeRequests: 0, maxConcurrentRequests: 2)
        XCTAssertEqual(metricsAfterOwnedAggregate.totalRequests, 2,
                       "mixed managed-shell syntax must not create a Distill request")

        _ = realNpm
        _ = realNode
        _ = realShasum

    }

    func test_wrapPreservesSeparateStdoutAndStderrForPipesAndRedirects() throws {
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("command-wrap-streams-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeFind = try makeExecutable(
            at: root,
            name: "find",
            body: "#!/bin/sh\nprintf 'WRAPPED STDOUT\\n'\nprintf 'WRAPPED STDERR\\n' >&2\nexit 23\n"
        )
        let path = "\(root.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"

        let piped = try runShell(
            "set -o pipefail; \(shellQuote(binary.path)) wrap find | /bin/cat",
            env: ["PATH": path]
        )
        XCTAssertEqual(piped.out, "WRAPPED STDOUT\n", "a pipeline must receive stdout only")
        XCTAssertEqual(piped.err, "WRAPPED STDERR\n", "stderr must bypass the stdout pipeline")
        XCTAssertEqual(piped.code, 23, "the real command status must survive a pipefail pipeline")

        let redirectedOut = root.appendingPathComponent("redirected.out")
        let redirectedErr = root.appendingPathComponent("redirected.err")
        let redirected = try runShell(
            "\(shellQuote(binary.path)) wrap find > \(shellQuote(redirectedOut.path)) 2> \(shellQuote(redirectedErr.path))",
            env: ["PATH": path]
        )
        XCTAssertEqual(redirected.out, "")
        XCTAssertEqual(redirected.err, "")
        XCTAssertEqual(redirected.code, 23)
        XCTAssertEqual(try String(contentsOf: redirectedOut), "WRAPPED STDOUT\n",
                       "stdout redirection must not contain diagnostics")
        XCTAssertEqual(try String(contentsOf: redirectedErr), "WRAPPED STDERR\n",
                       "stderr redirection must retain diagnostics")

        _ = fakeFind
    }

    func test_wrapPTYCapturesOnlyForAnAdmittedScopedReceipt() throws {
        // WHY: provider PTY stdout is not a pipe, so the wrapper must capture
        // only when the host supplied an admitted receipt with full recovery
        // scope. Hints, stale state, and incomplete scope are not admission;
        // a user's ordinary terminal remains byte-for-byte passthrough.
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }
        let command = "if [ \"${REMOTE_CODE_WRAP_PARENT:-unset}\" = 1 ]; then printf 'WRAPPER_CAPTURE\\n'; else printf 'WRAPPER_PASSTHROUGH\\n'; fi"
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("command-wrap-pty-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .codex,
            threadId: "10000000-0000-0000-0000-000000000001",
            rootRunId: "40000000-0000-0000-0000-000000000004",
            attemptId: "50000000-0000-0000-0000-000000000005",
            workspaceId: "20000000-0000-0000-0000-000000000002",
            projectId: "30000000-0000-0000-0000-000000000003"
        )
        var admittedEnvironment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
        admittedEnvironment["REMOTE_CODE_AGENT_PROVIDER"] = "codex"
        admittedEnvironment["REMOTE_CODE_DISTILL_STATE_PATH"] =
            root.appendingPathComponent("missing-state.json").path

        func output(for environment: [String: String]) throws -> String {
            let result = try runPTY(
                binary,
                ["wrap", "/bin/sh", "-c", command],
                env: environment
            )
            XCTAssertEqual(result.code, 0, "stderr=\(result.err) stdout=\(result.out)")
            return result.out
        }

        let admittedOutput = try output(for: admittedEnvironment)
        XCTAssertEqual(
            admittedOutput.components(separatedBy: "WRAPPER_CAPTURE").count - 1,
            1,
            "a valid receipt admits exactly one terminal capture: \(admittedOutput)"
        )

        // A complete scope plus a forged hint is still raw: the hint is not an
        // authorization channel and cannot replace the host-issued receipt.
        var forgedHintEnvironment = admittedEnvironment
        forgedHintEnvironment[TokenSaverExecutionReceipt.envKey] = "{\"forged\":true}"
        forgedHintEnvironment["RC_TOKEN_SAVER_DISTILL_HINT"] = "1"
        let forgedHintOutput = try output(for: forgedHintEnvironment)
        XCTAssertFalse(forgedHintOutput.contains("WRAPPER_CAPTURE"), forgedHintOutput)
        XCTAssertTrue(forgedHintOutput.contains("WRAPPER_PASSTHROUGH"), forgedHintOutput)

        var staleEnvironment = forgedHintEnvironment
        staleEnvironment["RC_TOKEN_SAVER_DISTILL_HINT"] = "stale"
        let staleOutput = try output(for: staleEnvironment)
        XCTAssertFalse(staleOutput.contains("WRAPPER_CAPTURE"), staleOutput)
        XCTAssertTrue(staleOutput.contains("WRAPPER_PASSTHROUGH"), staleOutput)

        var incompleteEnvironment = forgedHintEnvironment
        incompleteEnvironment["RC_TOKEN_SAVER_WORKSPACE_ID"] = ""
        incompleteEnvironment["RC_TOKEN_SAVER_PROJECT_ID"] = ""
        incompleteEnvironment["RC_TOKEN_SAVER_THREAD_ID"] = ""
        incompleteEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"] = ""
        let incompleteOutput = try output(for: incompleteEnvironment)
        XCTAssertFalse(incompleteOutput.contains("WRAPPER_CAPTURE"), incompleteOutput)
        XCTAssertTrue(incompleteOutput.contains("WRAPPER_PASSTHROUGH"), incompleteOutput)

        var offEnvironment = incompleteEnvironment
        offEnvironment["RC_TOKEN_SAVER_DISTILL_HINT"] = ""
        let offOutput = try output(for: offEnvironment)
        XCTAssertFalse(offOutput.contains("WRAPPER_CAPTURE"), offOutput)
        XCTAssertTrue(offOutput.contains("WRAPPER_PASSTHROUGH"), offOutput)
    }

    func test_wrapPipelineKeepsIntermediateStagePassthroughWithAdmittedReceipt() throws {
        // WHY: a downstream sibling reader is an intermediate pipeline stage,
        // not the provider's final agent-facing stream. It must not capture or
        // add wrapper bookkeeping even when admission is present.
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }
        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .codex,
            threadId: "10000000-0000-0000-0000-000000000001",
            attemptId: "50000000-0000-0000-0000-000000000005",
            workspaceId: "20000000-0000-0000-0000-000000000002",
            projectId: "30000000-0000-0000-0000-000000000003"
        )
        var environment = TokenSaverExecutionReceiptSeam.environment(from: receipt)
        environment["REMOTE_CODE_AGENT_PROVIDER"] = "codex"
        environment["REMOTE_CODE_DISTILL_STATE_PATH"] =
            "/nonexistent/\(UUID().uuidString).json"
        let command = "if [ \"${REMOTE_CODE_WRAP_PARENT:-unset}\" = 1 ]; then printf 'NESTED_CHILD_RAW\\n'; else printf 'MISSING_PARENT_MARKER\\n'; fi"
        let result = try runShell(
            "set -o pipefail; \(shellQuote(binary.path)) wrap /bin/sh -c \(shellQuote(command)) | /bin/cat",
            env: environment
        )
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(
            result.out,
            "NESTED_CHILD_RAW\n",
            "an intermediate wrapper stays raw and prevents its real child from opening a nested Distill route"
        )
    }

    func test_explicitDistillPipelineRunsOnceAndMarksInnerWrappersAsNested() throws {
        guard let binary = builtBinary() else {
            throw XCTSkip("RemoteCodeDistillService debug binary not built")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("command-wrap-explicit-\(UUID().uuidString)", isDirectory: true)
        let wrapperBin = root.appendingPathComponent("wrappers", isDirectory: true)
        let realBin = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let countFile = root.appendingPathComponent("distill.count")
        let markerFile = root.appendingPathComponent("distill.parent")
        try Data("0\n".utf8).write(to: countFile)
        let distill = try makeExecutable(
            at: wrapperBin,
            name: "distill",
            body: "#!/bin/sh\ncount=$(cat \"\(countFile.path)\")\nprintf '%s\\n' $((count + 1)) > \"\(countFile.path)\"\nprintf '%s\\n' \"${REMOTE_CODE_WRAP_PARENT:-missing}\" > \"\(markerFile.path)\"\ncat\n"
        )
        let realFind = try makeExecutable(
            at: realBin,
            name: "find",
            body: "#!/bin/sh\nprintf 'INNER STDOUT\\n'\nprintf 'INNER STDERR\\n' >&2\nexit 23\n"
        )
        let wrappedFind = wrapperBin.appendingPathComponent("find")
        try FileManager.default.createSymbolicLink(at: wrappedFind, withDestinationURL: binary)
        let path = "\(wrapperBin.path):\(realBin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"

        let payloads = [
            "set -o pipefail; find 2>&1 | distill",
            "set -o pipefail; find 2>&1 | command distill",
            "set -o pipefail; find 2>&1 | env RC_EXPLICIT=1 distill",
        ]
        for payload in payloads {
            try Data("0\n".utf8).write(to: countFile)
            try? FileManager.default.removeItem(at: markerFile)
            let result = try runProcess(
                binary,
                ["wrap", "sh", "-c", payload],
                env: ["PATH": path],
                stdin: ""
            )
            XCTAssertEqual(result.code, 23, "the shell must preserve the real pipeline status: \(payload)")
            XCTAssertEqual(result.out, "INNER STDOUT\nINNER STDERR\n", payload)
            XCTAssertEqual(
                try String(contentsOf: countFile),
                "1\n",
                "the explicit forwarded Distill stage must run exactly once: \(payload)"
            )
            XCTAssertEqual(
                try String(contentsOf: markerFile),
                "1\n",
                "the explicit Distill shell must mark nested wrappers as parent-owned: \(payload)"
            )
        }

        _ = distill
        _ = realFind
    }

    private func runProcess(
        _ url: URL,
        _ args: [String],
        env: [String: String],
        stdin: String,
        unset: Set<String> = [],
        currentDirectory: URL? = nil
    ) throws -> (out: String, err: String, code: Int32) {
        let process = Process()
        process.executableURL = url
        process.arguments = args
        process.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        for key in unset { environment.removeValue(forKey: key) }
        process.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        inPipe.fileHandleForWriting.closeFile()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(decoding: data, as: UTF8.self),
            String(decoding: errorData, as: UTF8.self),
            process.terminationStatus
        )
    }

    private func runZshWithTimeout(
        _ payload: String,
        environment: [String: String],
        timeout: TimeInterval,
        keepStdinOpen: Bool
    ) throws -> (out: String, err: String, code: Int32, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", payload]
        process.environment = environment
        let input = keepStdinOpen ? Pipe() : nil
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }
        let timedOut = process.isRunning
        input?.fileHandleForWriting.closeFile()
        if timedOut {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline {
                usleep(10_000)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        return (
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            process.terminationStatus,
            timedOut
        )
    }

    private func runShell(
        _ command: String,
        env: [String: String],
        unset: Set<String> = [],
        currentDirectory: URL? = nil
    ) throws -> (out: String, err: String, code: Int32) {
        try runProcess(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", command],
            env: env,
            stdin: "",
            unset: unset,
            currentDirectory: currentDirectory
        )
    }

    private func launchLiveSidecar(
        binary: URL,
        supportDirectory: URL,
        authToken: String,
        modelID: String,
        modelURL: String
    ) throws -> (process: Process, output: Pipe, ready: DistillServiceReadyEvent) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let capture = LiveSidecarReadyCapture()
        process.executableURL = binary
        process.arguments = [
            "--auth-token", authToken,
            "--app-support-dir", supportDirectory.path,
            "--host", "127.0.0.1",
            "--port", "0",
            "--runtime", "mlx",
            "--model-id", modelID,
            "--model-url", modelURL,
            "--max-concurrent-requests", "1",
            "--max-queue-depth", "2",
        ]
        process.standardOutput = output
        process.standardError = error
        output.fileHandleForReading.readabilityHandler = { handle in
            capture.receiveStdout(handle.availableData)
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            capture.receiveStderr(handle.availableData)
        }
        try process.run()
        _ = capture.completed.wait(timeout: .now() + 120)
        let snapshot = capture.snapshot()
        if let ready = snapshot.event { return (process, output, ready) }
        let status = process.isRunning ? "running" : "exited \(process.terminationStatus)"
        if process.isRunning { process.terminate() }
        throw NSError(
            domain: "ManagedDistillCLISubprocessTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "live sidecar did not emit ready event (\(status)); \(snapshot.diagnostics)"
            ]
        )
    }

    private func liveJSON(_ url: URL, authToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(
                domain: "ManagedDistillCLISubprocessTests",
                code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                userInfo: [NSLocalizedDescriptionKey: "live sidecar request failed"]
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "ManagedDistillCLISubprocessTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "live sidecar returned non-object JSON"]
            )
        }
        return object
    }

    private func runPTY(
        _ binary: URL,
        _ args: [String],
        env: [String: String]
    ) throws -> (out: String, err: String, code: Int32) {
        let command = ([binary.path] + args).map(shellQuote).joined(separator: " ")
        return try runShell(
            "/usr/bin/script -q /dev/null /bin/sh -c \(shellQuote(command))",
            env: env
        )
    }

    private func makeExecutable(at directory: URL, name: String, body: String) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: file)
        guard chmod(file.path, 0o755) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
        return file
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
