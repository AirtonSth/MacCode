import XCTest
import CoreModel
import DistillCore
import Darwin

final class ProviderProxyPolicyTests: XCTestCase {
    func test_catalogCoversAllThreeProvidersAndNotCompressionCommands() {
        // WHY: nested provider interception is a separate controller from RTK wrap.
        for name in ["claude", "codex", "grok"] {
            XCTAssertTrue(ProviderProxyPolicy.isProviderProxy(name))
            XCTAssertTrue(ProviderProxyCatalog.isProviderProxyCommand("/usr/bin/\(name)"))
            XCTAssertFalse(WrappedCommandCatalog.commands.contains(name))
            XCTAssertFalse(WrappedCommandCatalog.exactOutputCommandSet.contains(name))
        }
        XCTAssertFalse(ProviderProxyPolicy.isProviderProxy("ls"))
        XCTAssertFalse(ProviderProxyPolicy.isProviderProxy("git"))
        XCTAssertFalse(ProviderProxyPolicy.isProviderProxy("distill"))
    }

    func test_resolveRealExecutable_skipsManagedBinAndSelf() {
        // WHY: the proxy must never re-invoke itself or another managed shim.
        let managed = "/tmp/rc-managed-bin"
        let real = "/opt/homebrew/bin/grok"
        let pathEntries = [managed, "/opt/homebrew/bin", "/usr/local/bin"]
        let found = ProviderProxyPolicy.resolveRealExecutable(
            command: "grok",
            pathEntries: pathEntries,
            managedBinDirectory: managed,
            isExecutableFile: { $0 == real || $0 == "\(managed)/grok" },
            resolvesToSelf: { $0 == "\(managed)/grok" }
        )
        XCTAssertEqual(found, real)
    }

    func test_resolveRealExecutable_returnsNilWhenOnlyManagedShimExists() {
        let managed = "/tmp/rc-managed-bin"
        let found = ProviderProxyPolicy.resolveRealExecutable(
            command: "claude",
            pathEntries: [managed, "/usr/bin"],
            managedBinDirectory: managed,
            isExecutableFile: { $0 == "\(managed)/claude" },
            resolvesToSelf: { _ in true }
        )
        XCTAssertNil(found, "fail open: no real CLI → command not found, never recurse")
    }

    func test_isManagedProviderProxyPath_detectsSymlinkInManagedBin() {
        let managed = "/Users/x/.remote-code/bin"
        let candidate = "\(managed)/codex"
        XCTAssertTrue(
            ProviderProxyPolicy.isManagedProviderProxyPath(
                command: "codex",
                candidatePath: candidate,
                managedBinDirectory: managed,
                symlinkDestination: { _ in "/App/RemoteCodeDistillService" }
            )
        )
        XCTAssertFalse(
            ProviderProxyPolicy.isManagedProviderProxyPath(
                command: "codex",
                candidatePath: "/opt/homebrew/bin/codex",
                managedBinDirectory: managed,
                symlinkDestination: { _ in nil }
            ),
            "real Homebrew codex is not a proxy"
        )
        XCTAssertFalse(
            ProviderProxyPolicy.isManagedProviderProxyPath(
                command: "ls",
                candidatePath: "\(managed)/ls",
                managedBinDirectory: managed,
                symlinkDestination: { _ in "/App/RemoteCodeDistillService" }
            ),
            "compression wrappers are not provider proxies"
        )
    }

    func test_hasTelemetryScope_requiresThreadAndProvider() {
        // WHY: without scope the proxy must fail open and run raw (no receipt).
        XCTAssertFalse(ProviderProxyPolicy.hasTelemetryScope(environment: [:]))
        XCTAssertFalse(ProviderProxyPolicy.hasTelemetryScope(environment: [
            "REMOTE_CODE_AGENT_PROVIDER": "codex"
        ]))
        let thread = UUID().uuidString
        XCTAssertTrue(ProviderProxyPolicy.hasTelemetryScope(environment: [
            "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": thread,
            "REMOTE_CODE_AGENT_PROVIDER": "claude"
        ]))
        XCTAssertTrue(ProviderProxyPolicy.hasTelemetryScope(environment: [
            "RC_TOKEN_SAVER_THREAD_ID": thread,
            "REMOTE_CODE_AGENT_PROVIDER": "grok"
        ]), "Token Saver thread key is a fallback scope source")
        XCTAssertFalse(ProviderProxyPolicy.hasTelemetryScope(environment: [
            "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": "not-a-uuid",
            "REMOTE_CODE_AGENT_PROVIDER": "claude"
        ]))
    }

    func test_makeNodeId_isBoundedContentFreeAndSafe() {
        // WHY: receipts must never carry prompt text; node id stays a safe token.
        let id = ProviderProxyPolicy.makeNodeId(
            providerBasename: "grok",
            processIdentifier: 42_001,
            monotonicNanos: 0xdead_beef
        )
        XCTAssertTrue(id.hasPrefix("nested.grok.42001."))
        XCTAssertLessThanOrEqual(id.utf8.count, 128)
        XCTAssertTrue(id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        })
        XCTAssertFalse(id.lowercased().contains("prompt"))
        XCTAssertNotEqual(id, "root")
    }

    func test_runStatus_mapsExitAndSignals() {
        // WHY: Subagents rows need completed / failed / cancelled, not raw wait status.
        XCTAssertEqual(
            ProviderProxyPolicy.runStatus(wasUncaughtSignal: false, terminationStatus: 0),
            .completed
        )
        XCTAssertEqual(
            ProviderProxyPolicy.runStatus(wasUncaughtSignal: false, terminationStatus: 1),
            .failed
        )
        XCTAssertEqual(
            ProviderProxyPolicy.runStatus(wasUncaughtSignal: false, terminationStatus: 2),
            .failed,
            "nonzero normal exit is failed even if the number collides with SIGINT"
        )
        XCTAssertEqual(
            ProviderProxyPolicy.runStatus(wasUncaughtSignal: true, terminationStatus: SIGINT),
            .cancelled
        )
        XCTAssertEqual(
            ProviderProxyPolicy.runStatus(wasUncaughtSignal: true, terminationStatus: SIGTERM),
            .cancelled
        )
        XCTAssertEqual(
            ProviderProxyPolicy.runStatus(wasUncaughtSignal: true, terminationStatus: SIGKILL),
            .failed
        )
        XCTAssertEqual(
            ProviderProxyPolicy.runStatus(
                wasUncaughtSignal: false,
                terminationStatus: 0,
                forwardedSignal: SIGTERM
            ),
            .cancelled,
            "a signal received by the proxy must not become completed when the child exits cleanly after forwarding"
        )
    }

    func test_agentAppDelegation_recognizesSamGrokWorkerInvocation() throws {
        // WHY: Codex -> Grok orchestration must enter RemoteCode's Agent App
        // pipeline instead of spawning a token-saver-blind raw provider turn.
        let promptPath = "/tmp/worker-prompt.txt"
        let delegation = try XCTUnwrap(ProviderProxyPolicy.agentAppDelegation(
            providerBasename: "grok",
            arguments: [
                "--prompt-file", promptPath,
                "--model", "grok-4.5",
                "--effort", "high",
                "--output-format", "json",
                "--sandbox", "workspace",
                "--always-approve",
                "--no-memory",
                "--no-subagents",
                "--disallowed-tools", "Agent",
                "--no-auto-update"
            ],
            environment: [
                "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
                "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH": "/tmp/RemoteCodeDebug.sock",
                "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": UUID().uuidString,
                "REMOTE_CODE_AGENT_PROVIDER": "codex"
            ]
        ))

        XCTAssertEqual(delegation.provider, .grok)
        XCTAssertEqual(delegation.promptFile, promptPath)
        XCTAssertEqual(delegation.model, "grok-4.5")
        XCTAssertEqual(delegation.reasoningEffort, .high)
        XCTAssertEqual(delegation.permissionMode, .autoAcceptEdits)
        XCTAssertEqual(delegation.outputFormat, .grokJSON)
    }

    func test_agentAppDelegation_rejectsInteractiveOrUnscopedProviderCalls() {
        XCTAssertNil(ProviderProxyPolicy.agentAppDelegation(
            providerBasename: "grok",
            arguments: [],
            environment: ["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1"]
        ))
        XCTAssertNil(ProviderProxyPolicy.agentAppDelegation(
            providerBasename: "grok",
            arguments: ["--prompt-file", "/tmp/prompt.txt", "--resume", "session"],
            environment: [
                "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
                "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH": "/tmp/RemoteCodeDebug.sock"
            ]
        ))
        XCTAssertNil(ProviderProxyPolicy.agentAppDelegation(
            providerBasename: "grok",
            arguments: ["--prompt-file", "/tmp/prompt.txt"],
            environment: [
                "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH": "/tmp/RemoteCodeDebug.sock"
            ]
        ))
    }

    func test_agentAppSocketPathUsesInjectedScopeThenBundledChannelFallback() {
        // WHY: nested agents carry an exact host socket, while a human running
        // `remote-code agent-app` in Terminal must still reach its bundled
        // stable/debug/canary app without setting RC2_CHANNEL manually.
        XCTAssertEqual(
            ProviderProxyPolicy.agentAppSocketPath(
                environment: ["RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH": "/tmp/explicit.sock"],
                bundledSocketPath: "/tmp/RemoteCode.sock"
            ),
            "/tmp/explicit.sock"
        )
        XCTAssertEqual(
            ProviderProxyPolicy.agentAppSocketPath(
                environment: [:],
                bundledSocketPath: "/tmp/RemoteCode.sock"
            ),
            "/tmp/RemoteCode.sock"
        )
        XCTAssertNil(
            ProviderProxyPolicy.agentAppSocketPath(
                environment: [:],
                bundledSocketPath: nil
            )
        )
    }
}
