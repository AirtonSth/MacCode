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

    func test_legacyTokenSaverThread_becomesAlwaysOnBeforeOffStateScrub() {
        let thread = UUID().uuidString
        let promoted = ProviderProxyPolicy.alwaysOnTelemetryEnvironment([
            "RC_TOKEN_SAVER_THREAD_ID": thread,
            "REMOTE_CODE_AGENT_PROVIDER": "grok"
        ])
        let scrubbed = ProviderProxyPolicy.paidRuntimeEnvironment(
            environment: promoted,
            tokenSaverRuntimeActive: false,
            graphifyRuntimeActive: false
        )
        XCTAssertNil(scrubbed["RC_TOKEN_SAVER_THREAD_ID"])
        XCTAssertEqual(scrubbed["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"], thread)
        XCTAssertTrue(ProviderProxyPolicy.hasTelemetryScope(environment: scrubbed))
    }

    func test_paidRuntimeEnvironment_scrubsSpoofedPaidLanesButPreservesRouting() {
        // WHY: stale inherited variables must not resurrect a paid feature
        // after persisted Token Saver settings say it is off.
        let environment = [
            "RC_TOKEN_SAVER_EXECUTION_RECEIPT_V1": #"{"spoofed":true}"#,
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            "RC_DISTILL_ENDPOINT": "http://127.0.0.1:1",
            "RC_GRAPHIFY_ENABLED": "1",
            "REMOTE_CODE_DISTILL_STATE_PATH": "/tmp/stale-state",
            "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
            "RC_REMOTE_CODE_AGENT_APP_COMMAND": "/managed/remote-code",
            "RC_REMOTE_CODE_SUBAGENT_THREAD_ID": UUID().uuidString,
            "REMOTE_CODE_AGENT_PROVIDER": "codex",
            "PATH": "/managed:/usr/bin"
        ]
        let scrubbed = ProviderProxyPolicy.paidRuntimeEnvironment(
            environment: environment,
            tokenSaverRuntimeActive: false,
            graphifyRuntimeActive: false
        )
        XCTAssertFalse(scrubbed.keys.contains { $0.hasPrefix("RC_TOKEN_SAVER_") })
        XCTAssertFalse(scrubbed.keys.contains { $0.hasPrefix("RC_DISTILL_") })
        XCTAssertFalse(scrubbed.keys.contains { $0.hasPrefix("RC_GRAPHIFY_") })
        XCTAssertNil(scrubbed["REMOTE_CODE_DISTILL_STATE_PATH"])
        XCTAssertEqual(scrubbed["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"], "1")
        XCTAssertEqual(scrubbed["RC_REMOTE_CODE_AGENT_APP_COMMAND"], "/managed/remote-code")
        XCTAssertEqual(scrubbed["PATH"], "/managed:/usr/bin")
    }

    func test_paidRuntimeEnvironment_scrubsOnlyGraphifyWhenItsLiveGateIsOff() {
        let scrubbed = ProviderProxyPolicy.paidRuntimeEnvironment(
            environment: [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                "RC_DISTILL_ENDPOINT": "http://127.0.0.1:1",
                "RC_GRAPHIFY_ENABLED": "1",
                "RC_GRAPHIFY_ROOTS": "/tmp/project"
            ],
            tokenSaverRuntimeActive: true,
            graphifyRuntimeActive: false
        )
        XCTAssertEqual(scrubbed["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertEqual(scrubbed["RC_DISTILL_ENDPOINT"], "http://127.0.0.1:1")
        XCTAssertFalse(scrubbed.keys.contains { $0.hasPrefix("RC_GRAPHIFY_") })
    }

    func test_paidRuntimeEnvironmentAlwaysScrubsHostManagedIntegrationHome() {
        // WHY: provider proxies may originate in an embedded terminal rather than
        // AppShell's launcher. Host filesystem-ownership state must not cross that
        // provider boundary regardless of paid-lane admission.
        for tokenSaverActive in [false, true] {
            let scrubbed = ProviderProxyPolicy.paidRuntimeEnvironment(
                environment: [
                    ChildProcessEnvironmentPolicy.managedIntegrationHomeKey: "/tmp/app-owned-home",
                    "UNCHANGED": "yes",
                ],
                tokenSaverRuntimeActive: tokenSaverActive,
                graphifyRuntimeActive: tokenSaverActive
            )
            XCTAssertNil(scrubbed[ChildProcessEnvironmentPolicy.managedIntegrationHomeKey])
            XCTAssertEqual(scrubbed["UNCHANGED"], "yes")
        }
    }

    func test_childScopedEnvironment_retargetsEachProviderGeneration() {
        // WHY: Codex→Grok→Claude must link each raw provider process to the
        // immediately preceding external child instead of flattening to Codex.
        let child = UUID().uuidString
        let parentCapability = String(repeating: "a", count: 64)
        let childCapability = String(repeating: "b", count: 64)
        let scoped = ProviderProxyPolicy.childScopedEnvironment(
            environment: [
                "REMOTE_CODE_AGENT_PROVIDER": "codex",
                "RC_REMOTE_CODE_ROOT_RUN_ID": UUID().uuidString,
                "RC_TOKEN_SAVER_ROOT_RUN_ID": UUID().uuidString,
                "RC_TOKEN_SAVER_ATTEMPT_ID": UUID().uuidString,
                "RC_TOKEN_SAVER_EXECUTION_RECEIPT_V1": "parent",
                "RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE": "1",
                AgentDelegationCapabilityTransport.environmentKey: parentCapability
            ],
            targetProvider: .grok,
            childRunId: child,
            childDelegationCapability: childCapability,
            tokenSaverEnvironment: [
                "RC_TOKEN_SAVER_EXECUTION_RECEIPT_V1": "retargeted"
            ]
        )
        XCTAssertEqual(scoped["REMOTE_CODE_AGENT_PROVIDER"], "grok")
        XCTAssertEqual(scoped["REMOTE_CODE_PROVIDER_INSTANCE_ID"], "grok")
        XCTAssertEqual(scoped["RC_REMOTE_CODE_ROOT_RUN_ID"], child)
        XCTAssertEqual(scoped["RC_TOKEN_SAVER_ROOT_RUN_ID"], child)
        XCTAssertEqual(scoped["RC_TOKEN_SAVER_ATTEMPT_ID"], child)
        XCTAssertEqual(scoped["RC_TOKEN_SAVER_EXECUTION_RECEIPT_V1"], "retargeted")
        XCTAssertEqual(scoped["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"], "1")
        XCTAssertEqual(
            scoped[AgentDelegationCapabilityTransport.environmentKey],
            childCapability
        )
        XCTAssertNotEqual(
            scoped[AgentDelegationCapabilityTransport.environmentKey],
            parentCapability
        )
    }

    func test_childScopedEnvironment_keepsHierarchyWhenTokenSaverIsOff() {
        let child = UUID().uuidString
        let childCapability = String(repeating: "c", count: 64)
        let scoped = ProviderProxyPolicy.childScopedEnvironment(
            environment: [
                "REMOTE_CODE_AGENT_PROVIDER": "grok",
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                "RC_GRAPHIFY_ENABLED": "1"
            ],
            targetProvider: .claude,
            childRunId: child,
            childDelegationCapability: childCapability,
            tokenSaverEnvironment: nil
        )
        XCTAssertEqual(scoped["REMOTE_CODE_AGENT_PROVIDER"], "claude")
        XCTAssertEqual(scoped["RC_REMOTE_CODE_ROOT_RUN_ID"], child)
        XCTAssertNil(scoped["RC_TOKEN_SAVER_DISTILL_HINT"])
        XCTAssertNil(scoped["RC_GRAPHIFY_ENABLED"])
        XCTAssertEqual(
            scoped[AgentDelegationCapabilityTransport.environmentKey],
            childCapability
        )
    }

    func test_childScopedEnvironment_recomputesClaudeOnlyPostToolUseAcrossProviders() {
        // WHY: Claude→Codex/Grok must drop Claude's hook, while a
        // Codex/Grok→Claude child receives it only through the retargeted live
        // capability environment.
        XCTAssertNil(ProviderProxyPolicy.childPostToolUseCapability(
            targetProvider: .codex,
            distillAvailable: true
        ))
        XCTAssertNil(ProviderProxyPolicy.childPostToolUseCapability(
            targetProvider: .grok,
            distillAvailable: true
        ))
        XCTAssertEqual(ProviderProxyPolicy.childPostToolUseCapability(
            targetProvider: .claude,
            distillAvailable: true
        ), true)
        XCTAssertEqual(ProviderProxyPolicy.childPostToolUseCapability(
            targetProvider: .claude,
            distillAvailable: false
        ), false)

        let child = UUID().uuidString
        let claudeToCodex = ProviderProxyPolicy.childScopedEnvironment(
            environment: [
                "REMOTE_CODE_AGENT_PROVIDER": "claude",
                "REMOTE_CODE_DISTILL_STATE_PATH": "/tmp/claude-parent-state"
            ],
            targetProvider: .codex,
            childRunId: child,
            childDelegationCapability: String(repeating: "d", count: 64),
            tokenSaverEnvironment: [
                "RC_TOKEN_SAVER_EXECUTION_RECEIPT_V1": "codex-child"
            ]
        )
        XCTAssertNil(claudeToCodex["REMOTE_CODE_DISTILL_STATE_PATH"])

        let grokToClaude = ProviderProxyPolicy.childScopedEnvironment(
            environment: ["REMOTE_CODE_AGENT_PROVIDER": "grok"],
            targetProvider: .claude,
            childRunId: child,
            childDelegationCapability: String(repeating: "e", count: 64),
            tokenSaverEnvironment: [
                "RC_TOKEN_SAVER_EXECUTION_RECEIPT_V1": "claude-child",
                "REMOTE_CODE_DISTILL_STATE_PATH": "/tmp/claude-child-state"
            ]
        )
        XCTAssertEqual(
            grokToClaude["REMOTE_CODE_DISTILL_STATE_PATH"],
            "/tmp/claude-child-state"
        )
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

    func test_agentAppProviderParsesOnlyTheExplicitCommandPosition() {
        XCTAssertEqual(
            ProviderProxyPolicy.agentAppProvider(
                arguments: ["agent-app", "claude", "--prompt-file", "/tmp/p"]
            ),
            .claude
        )
        XCTAssertEqual(
            ProviderProxyPolicy.agentAppProvider(
                arguments: [
                    "--socket", "/tmp/rc.sock",
                    "--timeout", "1000",
                    "--json",
                    "agent-app", "codex", "hello"
                ]
            ),
            .codex
        )
        XCTAssertNil(ProviderProxyPolicy.agentAppProvider(
            arguments: ["agent", "send", "please run agent-app grok"]
        ))
        XCTAssertNil(ProviderProxyPolicy.agentAppProvider(
            arguments: ["--unknown", "agent-app", "grok"]
        ))
        XCTAssertNil(ProviderProxyPolicy.agentAppProvider(
            arguments: [
                "--prompt-file", "/tmp/worker-prompt.txt",
                "--model", "grok-4.5",
                "--sandbox", "workspace",
                "--output-format", "json"
            ]
        ), "a raw provider CLI is never auto-promoted into Agent App")
    }

    func test_samGrokWorkerPromotion_preservesExactAgentAppContractForEveryEffort() throws {
        // WHY: the promoted execution must keep the worker report ABI while the
        // real Agent App thread owns persistence, Token Saver and usage.
        for effort in ["low", "medium", "high", "xhigh", "max"] {
            let delegation = try XCTUnwrap(
                ProviderProxyPolicy.samGrokWorkerAgentAppDelegation(
                    providerBasename: "/managed/grok",
                    arguments: samGrokWorkerArguments(effort: effort)
                )
            )
            XCTAssertEqual(delegation.provider, .grok)
            XCTAssertEqual(delegation.promptFile, "/tmp/worker-prompt.txt")
            XCTAssertEqual(delegation.model, "grok-4.5")
            XCTAssertEqual(delegation.reasoningEffort.rawValue, effort)
            XCTAssertEqual(delegation.permissionMode, .autoAcceptEdits)
            XCTAssertEqual(delegation.outputFormat, .grokJSON)
            XCTAssertEqual(delegation.arguments, [
                "agent-app", "grok",
                "--prompt-file", "/tmp/worker-prompt.txt",
                "--model", "grok-4.5",
                "--permission", "auto_accept_edits",
                "--reasoning-effort", effort,
                "--output-format", "grok-json",
                "--runtime-profile", "sam-grok-worker-v1"
            ])
        }
    }

    func test_samGrokWorkerPromotion_acceptsFlagOrderButRequiresTheWholeExactShape() throws {
        let reordered = [
            "--no-auto-update",
            "--sandbox", "workspace",
            "--effort", "high",
            "--disallowed-tools", "Agent",
            "--always-approve",
            "--output-format", "json",
            "--no-memory",
            "--model", "grok-4.5",
            "--no-subagents",
            "--prompt-file", "/tmp/worker-prompt.txt"
        ]
        XCTAssertNotNil(ProviderProxyPolicy.samGrokWorkerAgentAppDelegation(
            providerBasename: "grok",
            arguments: reordered
        ))

        let valueFlags = [
            "--prompt-file", "--model", "--effort",
            "--output-format", "--sandbox", "--disallowed-tools"
        ]
        let booleanFlags = [
            "--always-approve", "--no-memory",
            "--no-subagents", "--no-auto-update"
        ]
        let canonical = samGrokWorkerArguments()
        for flag in valueFlags {
            var missing = canonical
            let index = try XCTUnwrap(missing.firstIndex(of: flag))
            missing.removeSubrange(index...index + 1)
            XCTAssertNil(ProviderProxyPolicy.samGrokWorkerAgentAppDelegation(
                providerBasename: "grok",
                arguments: missing
            ), "missing \(flag) must stay raw")
        }
        for flag in booleanFlags {
            var missing = canonical
            missing.remove(at: try XCTUnwrap(missing.firstIndex(of: flag)))
            XCTAssertNil(ProviderProxyPolicy.samGrokWorkerAgentAppDelegation(
                providerBasename: "grok",
                arguments: missing
            ), "missing \(flag) must stay raw")
        }
    }

    func test_samGrokWorkerPromotion_rejectsDuplicatesTerminatorsAliasesAndExtras() {
        let canonical = samGrokWorkerArguments()
        let duplicateMembers: [[String]] = [
            ["--prompt-file", "/tmp/other"],
            ["--model", "grok-4.5"],
            ["--effort", "high"],
            ["--output-format", "json"],
            ["--sandbox", "workspace"],
            ["--disallowed-tools", "Agent"],
            ["--always-approve"],
            ["--no-memory"],
            ["--no-subagents"],
            ["--no-auto-update"]
        ]
        for duplicate in duplicateMembers {
            XCTAssertNil(ProviderProxyPolicy.samGrokWorkerAgentAppDelegation(
                providerBasename: "grok",
                arguments: canonical + duplicate
            ), "duplicate \(duplicate[0]) must stay raw")
        }

        let rejectedVariants = [
            canonical + ["--"],
            canonical + ["unexpected-positional"],
            canonical + ["--rules", "extra"],
            canonical + ["--version"],
            ["--prompt-file=/tmp/worker-prompt.txt"] + Array(canonical.dropFirst(2)),
            ["--prompt-file", "relative.txt"] + Array(canonical.dropFirst(2)),
            replacingValue("--model", with: "grok-4", in: canonical),
            replacingValue("--effort", with: "minimal", in: canonical),
            replacingValue("--effort", with: "future", in: canonical),
            replacingValue("--output-format", with: "streaming-json", in: canonical),
            replacingValue("--sandbox", with: "workspace-write", in: canonical),
            replacingValue("--disallowed-tools", with: "Read", in: canonical)
        ]
        for variant in rejectedVariants {
            XCTAssertNil(ProviderProxyPolicy.samGrokWorkerAgentAppDelegation(
                providerBasename: "grok",
                arguments: variant
            ))
        }
        for provider in ["codex", "claude"] {
            XCTAssertNil(ProviderProxyPolicy.samGrokWorkerAgentAppDelegation(
                providerBasename: provider,
                arguments: canonical
            ))
        }
    }

    func test_nestedCLIAgentAppDelegation_promotesClaudeCodexGrokAgentTurns() throws {
        // WHY: product requires nested shell `claude`/`codex`/`grok` to enter
        // Agent App (full Token Saver) when the turn ABI is agent-shaped.
        let prompt = "/tmp/rc-nested-prompt.txt"
        let claude = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "claude",
            arguments: [
                "--print", "--model", "opus", "--effort", "max",
                "--permission-mode", "plan", "--output-format", "json",
                "--no-session-persistence"
            ],
            promptFile: prompt
        ))
        XCTAssertEqual(claude.provider, .claude)
        XCTAssertEqual(claude.model, "opus")
        XCTAssertEqual(claude.reasoningEffort, .max)
        XCTAssertEqual(claude.permissionMode, .supervised)
        XCTAssertEqual(claude.outputFormat, .json)
        XCTAssertNil(claude.runtimeProfile)
        XCTAssertTrue(claude.arguments.contains("agent-app"))
        XCTAssertFalse(claude.arguments.contains("--runtime-profile"))

        let codex = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "codex",
            arguments: ["exec", "--json", "--full-auto", "do the work"],
            promptFile: prompt
        ))
        XCTAssertEqual(codex.provider, .codex)
        XCTAssertEqual(codex.permissionMode, .fullAccess)
        XCTAssertEqual(codex.outputFormat, .json)
        XCTAssertNil(codex.runtimeProfile)

        let grok = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: [
                "--model", "grok-4.5", "--effort", "high",
                "--prompt", "investigate", "--always-approve"
            ],
            promptFile: prompt
        ))
        XCTAssertEqual(grok.provider, .grok)
        XCTAssertEqual(grok.reasoningEffort, .high)
        XCTAssertEqual(grok.permissionMode, .fullAccess)
        XCTAssertNil(grok.runtimeProfile)
    }

    func test_nestedCLIAgentAppDelegation_rejectsAdminVersionAndResume() {
        let prompt = "/tmp/rc-nested-prompt.txt"
        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "claude",
            arguments: ["--version"],
            promptFile: prompt
        ))
        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "claude",
            arguments: ["mcp", "list"],
            promptFile: prompt
        ))
        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "claude",
            arguments: ["--print", "--resume", "sess-1"],
            promptFile: prompt
        ))
        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "codex",
            arguments: ["exec", "resume", "sess-1"],
            promptFile: prompt
        ))
        XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "grok",
            arguments: ["--help"]
        ))
        // Restricted tool allowlist (advisor ABI) must stay on raw proxy + PTU.
        XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "claude",
            arguments: [
                "--print", "--model", "opus", "--effort", "max",
                "--permission-mode", "plan",
                "--tools", "Read,Glob,Grep",
                "--output-format", "json"
            ]
        ))
        XCTAssertTrue(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "claude",
            arguments: ["--print", "--model", "opus", "--effort", "high"]
        ))
    }

    func test_nestedCLIAgentAppDelegation_samGrokWorkerKeepsRuntimeProfile() throws {
        let delegation = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: samGrokWorkerArguments(effort: "high"),
            promptFile: "/tmp/worker-prompt.txt"
        ))
        XCTAssertEqual(delegation.runtimeProfile, .samGrokWorkerV1)
        XCTAssertEqual(delegation.outputFormat, .grokJSON)
        XCTAssertTrue(delegation.arguments.contains("sam-grok-worker-v1"))
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

    func test_permissionParsing_isProviderSpecificAndNeverWidensSilently() {
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "claude",
                arguments: ["--permission-mode", "bypassPermissions"]
            ),
            .explicit(.fullAccess)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "grok",
                arguments: [
                    "--permission-mode=acceptEdits",
                    "--sandbox=workspace"
                ]
            ),
            .explicit(.autoAcceptEdits)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "codex",
                arguments: ["exec", "--sandbox", "workspace-write", "-a", "never"]
            ),
            .explicit(.fullAccess),
            "approval suppression requires a full-access parent even with a filesystem sandbox"
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "codex",
                arguments: ["exec", "-s", "read-only", "-a", "never"]
            ),
            .explicit(.fullAccess),
            "read-only filesystem scope does not preserve the parent's approval boundary"
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "claude",
                arguments: ["--print", "--", "--permission-mode", "bypassPermissions"]
            ),
            .inherited,
            "provider-owned positional content after -- is never authority metadata"
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "grok",
                arguments: ["--permission-mode", "future-mode"]
            ),
            .invalid("unknown permission mode")
        )
        XCTAssertFalse(ProviderProxyPolicy.isPermissionMode(
            .fullAccess,
            noBroaderThan: .autoAcceptEdits
        ))
        XCTAssertTrue(ProviderProxyPolicy.isPermissionMode(
            .supervised,
            noBroaderThan: .fullAccess
        ))
    }

    func test_permissionParsing_treatsOpaqueDefaultsAndConfigAsFullCeiling() {
        // WHY: raw provider config/environment is not constrained by the
        // visible argv. A narrow parent may only launch shapes whose complete
        // authority is proven.
        XCTAssertEqual(
            ProviderProxyPolicy.effectiveRawPermissionRequest(
                ProviderProxyPolicy.explicitPermissionRequest(
                    providerBasename: "codex",
                    arguments: ["exec", "review this"]
                )
            ),
            .explicit(.fullAccess)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "codex",
                arguments: ["exec", "--sandbox", "workspace-write", "-a", "on-request"]
            ),
            .explicit(.autoAcceptEdits)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "grok",
                arguments: ["--permission-mode", "default"]
            ),
            .explicit(.fullAccess),
            "permission-only Grok leaves its sandbox authority opaque"
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "claude",
                arguments: ["--permission-mode", "plan"]
            ),
            .explicit(.supervised)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "claude",
                arguments: ["--permission-mode=acceptEdits"]
            ),
            .explicit(.autoAcceptEdits)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "codex",
                arguments: ["exec", "--sandbox=workspace-write", "-a=on-request"]
            ),
            .explicit(.autoAcceptEdits)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "codex",
                arguments: ["exec", "--full-auto"]
            ),
            .explicit(.autoAcceptEdits),
            "--full-auto is Codex's complete workspace-write shortcut"
        )
        for profile in [
            ["--profile", "wide"],
            ["--profile=wide"]
        ] {
            XCTAssertEqual(
                ProviderProxyPolicy.explicitPermissionRequest(
                    providerBasename: "codex",
                    arguments: ["exec", "--sandbox", "read-only"] + profile
                ),
                .explicit(.fullAccess)
            )
        }
        for settings in [
            ["--settings", "/tmp/settings.json"],
            ["--setting-sources=user,project"]
        ] {
            XCTAssertEqual(
                ProviderProxyPolicy.explicitPermissionRequest(
                    providerBasename: "claude",
                    arguments: ["--permission-mode", "plan"] + settings
                ),
                .explicit(.fullAccess)
            )
        }
    }

    func test_permissionParsing_environmentSandboxAndCLIOverrideAreFailClosed() {
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "grok",
                arguments: [],
                environment: ["GROK_SANDBOX": "workspace"]
            ),
            .explicit(.autoAcceptEdits)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "grok",
                arguments: [],
                environment: ["GROK_SANDBOX": "danger-full-access"]
            ),
            .explicit(.fullAccess)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "grok",
                arguments: ["--sandbox", "workspace"],
                environment: ["GROK_SANDBOX": "danger-full-access"]
            ),
            .explicit(.autoAcceptEdits),
            "an explicit CLI sandbox has provider precedence over GROK_SANDBOX"
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "grok",
                arguments: [],
                environment: ["GROK_SANDBOX": "future-mode"]
            ),
            .invalid("unknown GROK_SANDBOX mode")
        )
    }

    func test_permissionParsing_rootExpansionRequiresFullParentCeiling() {
        let cases: [(String, [String])] = [
            ("codex", ["exec", "--sandbox", "workspace-write", "-C", "/"]),
            ("codex", ["exec", "--sandbox=workspace-write", "--add-dir=/tmp"]),
            ("claude", ["--permission-mode", "acceptEdits", "--worktree", "/tmp/other"]),
            ("claude", ["--permission-mode=plan", "--add-dir=/tmp"]),
            ("grok", ["--sandbox", "workspace", "--cwd", "/tmp"]),
            ("grok", ["--sandbox=read-only", "--worktree=/tmp/other"])
        ]
        for (provider, arguments) in cases {
            XCTAssertEqual(
                ProviderProxyPolicy.explicitPermissionRequest(
                    providerBasename: provider,
                    arguments: arguments
                ),
                .explicit(.fullAccess),
                "\(provider) \(arguments) must require a full-access parent"
            )
        }
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "codex",
                arguments: [
                    "exec",
                    "--sandbox", "read-only",
                    "--config", "sandbox_workspace_write.writable_roots=[\"/\"]"
                ]
            ),
            .explicit(.fullAccess)
        )
    }

    func test_permissionParsing_unknownAuthorityAndManagementCommandsRequireFullCeiling() {
        // WHY: provider sandbox flags constrain agent tools, not direct CLI
        // management commands, plugins/hooks/MCP processes, or future options.
        let fullAccessCases: [(String, [String])] = [
            ("codex", [
                "exec", "--sandbox", "read-only",
                "--dangerously-bypass-hook-trust"
            ]),
            ("codex", [
                "exec", "--sandbox", "read-only",
                "--config", #"mcp_servers.audit.command="sh""#
            ]),
            ("codex", [
                "exec", "--sandbox", "read-only",
                "--output-last-message", "/tmp/direct-write"
            ]),
            ("codex", ["--sandbox", "read-only", "apply"]),
            ("claude", [
                "--print", "--permission-mode", "plan",
                "--mcp-config", #"{"mcpServers":{"audit":{"command":"sh"}}}"#
            ]),
            ("claude", [
                "--print", "--permission-mode", "plan",
                "--plugin-dir", "/tmp/untrusted-plugin"
            ]),
            ("claude", ["--permission-mode", "plan", "plugin"]),
            ("grok", [
                "--prompt-file", "/tmp/prompt", "--sandbox", "read-only",
                "--debug-file", "/tmp/direct-write"
            ]),
            ("grok", ["--sandbox", "read-only", "plugin"]),
            ("grok", [
                "--prompt-file", "/tmp/prompt", "--sandbox", "read-only",
                "--future-authority-mode"
            ])
        ]

        for (provider, arguments) in fullAccessCases {
            XCTAssertEqual(
                ProviderProxyPolicy.explicitPermissionRequest(
                    providerBasename: provider,
                    arguments: arguments
                ),
                .explicit(.fullAccess),
                "\(provider) \(arguments) must not bypass the parent ceiling"
            )
        }
    }

    func test_permissionParsing_preservesClosedAdvisorAndWorkerContracts() {
        // WHY: the conservative unknown-option rule must not break the exact
        // read-only Claude advisor. The guarded Grok worker is promoted before
        // this raw parser; if promotion is unavailable, approval suppression
        // must require a full-access parent.
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "claude",
                arguments: [
                    "--print",
                    "--model", "sonnet",
                    "--effort", "max",
                    "--permission-mode", "plan",
                    "--tools", "Read,Glob,Grep",
                    "--no-session-persistence",
                    "--output-format", "json"
                ]
            ),
            .explicit(.supervised)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "grok",
                arguments: [
                    "--prompt-file", "/tmp/prompt",
                    "--model", "grok-4.5",
                    "--reasoning-effort", "high",
                    "--no-memory",
                    "--no-subagents",
                    "--disallowed-tools", "Agent",
                    "--always-approve",
                    "--no-auto-update",
                    "--sandbox", "workspace"
                ]
            ),
            .explicit(.fullAccess)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "codex",
                arguments: [
                    "exec", "--strict-config", "--ephemeral", "--ignore-user-config",
                    "--sandbox", "read-only", "-"
                ]
            ),
            .explicit(.supervised)
        )
    }

    func test_permissionParsing_consumesKnownValuesAndStopsAtTerminator() {
        // WHY: prompt/system values can look exactly like dangerous flags or
        // management commands; only argv structure before `--` is authority.
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "claude",
                arguments: [
                    "--permission-mode", "plan",
                    "--system-prompt", "--plugin-dir",
                    "--", "plugin", "--dangerously-skip-permissions"
                ]
            ),
            .explicit(.supervised)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "codex",
                arguments: [
                    "exec", "--sandbox", "read-only",
                    "--output-schema", "--dangerously-bypass-hook-trust",
                    "apply"
                ]
            ),
            .explicit(.supervised),
            "`apply` is prompt data after the safe exec subcommand"
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "grok",
                arguments: [
                    "--sandbox", "read-only",
                    "--rules", "--restore-code",
                    "--prompt-file", "/tmp/prompt"
                ]
            ),
            .explicit(.supervised)
        )
    }

    func test_optionValue_doesNotPersistPromptOrTerminatedContentAsModel() {
        XCTAssertNil(ProviderProxyPolicy.optionValue(
            ["--model", "-m"],
            in: ["--prompt-file", "--model", "secret-prompt-value"]
        ))
        XCTAssertNil(ProviderProxyPolicy.optionValue(
            ["--model", "-m"],
            in: ["--", "--model", "secret-positional-value"]
        ))
        XCTAssertNil(ProviderProxyPolicy.optionValue(
            ["--model", "-m"],
            in: ["--fallback-model", "--model", "secret-positional-value"]
        ), "unknown provider options make argv metadata ambiguous")
        XCTAssertEqual(ProviderProxyPolicy.optionValue(
            ["--model", "-m"],
            in: [
                "--prompt-file", "/tmp/prompt",
                "--model", "grok-4.5",
                "--", "--model", "secret-positional-value"
            ]
        ), "grok-4.5")
    }

    func test_usageCaptureFormat_coversDocumentedNonInteractiveJSONABIs() {
        // WHY: only provider-declared non-interactive JSON/JSONL shapes may be
        // tee'd; interactive TTY behavior remains inherited unchanged.
        XCTAssertEqual(
            ProviderProxyPolicy.usageCaptureFormat(
                providerBasename: "grok",
                arguments: [
                    "--prompt-file", "/tmp/prompt.txt",
                    "--output-format", "json",
                    "--no-subagents"
                ]
            ),
            .grokJSON
        )
        XCTAssertNil(ProviderProxyPolicy.usageCaptureFormat(
            providerBasename: "grok",
            arguments: ["--output-format", "json"]
        ))
        XCTAssertEqual(ProviderProxyPolicy.usageCaptureFormat(
            providerBasename: "grok",
            arguments: [
                "--prompt-file", "/tmp/prompt.txt",
                "--output-format", "streaming-json"
            ]
        ), .grokJSONLines)
        XCTAssertEqual(ProviderProxyPolicy.usageCaptureFormat(
            providerBasename: "claude",
            arguments: [
                "--print",
                "--output-format", "json"
            ]
        ), .claudeJSON)
        XCTAssertEqual(ProviderProxyPolicy.usageCaptureFormat(
            providerBasename: "claude",
            arguments: [
                "--print",
                "--output-format", "stream-json",
                "--verbose"
            ]
        ), .claudeJSONLines)
        XCTAssertNil(ProviderProxyPolicy.usageCaptureFormat(
            providerBasename: "claude",
            arguments: ["--output-format", "json"]
        ), "interactive Claude must retain its TTY")
        XCTAssertNil(ProviderProxyPolicy.usageCaptureFormat(
            providerBasename: "codex",
            arguments: ["--json", "review"]
        ), "installed Codex advisor expects plain output and stays usage-opaque")
        XCTAssertEqual(ProviderProxyPolicy.usageCaptureFormat(
            providerBasename: "codex",
            arguments: ["exec", "--json", "--skip-git-repo-check", "review this"]
        ), .codexJSONLines)
        XCTAssertNil(ProviderProxyPolicy.usageCaptureFormat(
            providerBasename: "codex",
            arguments: ["exec", "resume", "--last", "--json"]
        ))
        XCTAssertNil(ProviderProxyPolicy.usageCaptureFormat(
            providerBasename: "codex",
            arguments: ["exec", "--", "--json"]
        ))
    }

    func test_usageCaptureFormat_rejectsSessionContinuationAndArgumentTerminator() {
        let claudeBase = ["--print", "--output-format", "json"]
        for continuation in [
            ["--resume", "session"],
            ["--resume=session"],
            ["-r", "session"],
            ["--continue"],
            ["-c"],
            ["--session-id", UUID().uuidString],
            ["--fork-session"]
        ] {
            XCTAssertNil(ProviderProxyPolicy.usageCaptureFormat(
                providerBasename: "claude",
                arguments: claudeBase + continuation
            ))
        }
        XCTAssertNil(ProviderProxyPolicy.usageCaptureFormat(
            providerBasename: "grok",
            arguments: [
                "--prompt-file", "/tmp/prompt.txt",
                "--output-format", "json",
                "--", "--resume", "session"
            ]
        ))
        XCTAssertNil(ProviderProxyPolicy.usageCaptureFormat(
            providerBasename: "claude",
            arguments: claudeBase + ["unexpected positional prompt"]
        ))
    }

    func test_usageCaptureFormat_consumesFlagValuesBeforeCheckingContinuationFlags() {
        // WHY: a rules string that happens to equal a flag is data, not a
        // resumed session. The scanner must honor value-taking flag boundaries.
        XCTAssertEqual(ProviderProxyPolicy.usageCaptureFormat(
            providerBasename: "grok",
            arguments: [
                "--prompt-file", "/tmp/prompt.txt",
                "--rules", "--resume",
                "--output-format", "json"
            ]
        ), .grokJSON)
    }

    func test_grokJSONTokenUsage_parsesProviderBillingWithoutPersistingContent() throws {
        // WHY: restrictive raw Grok workers cannot enter Agent App, but their
        // provider-reported usage must still finalize the Subagents receipt.
        let data = try JSONSerialization.data(withJSONObject: [
            "text": "sensitive result is deliberately ignored",
            "usage": [
                "input_tokens": 25_103,
                "cache_read_input_tokens": 6_016,
                "output_tokens": 18,
                "reasoning_tokens": 13,
                "total_tokens": 31_137,
                "cost_in_usd_ticks": 123_450_000
            ]
        ])
        let usage = try XCTUnwrap(ProviderProxyPolicy.grokJSONTokenUsage(from: data))
        XCTAssertEqual(usage.inputTokens, 31_119)
        XCTAssertEqual(usage.outputTokens, 18)
        XCTAssertEqual(usage.totalTokens, 31_137)
        XCTAssertEqual(usage.uncachedInputTokens, 25_103)
        XCTAssertEqual(usage.cacheReadInputTokens, 6_016)
        XCTAssertEqual(usage.reportedCostMicros, 12_345)
    }

    func test_grokJSONTokenUsage_prefersCumulativeModelUsage() throws {
        // WHY: Grok's final modelUsage is the session-cumulative billing source;
        // top-level request usage must not overwrite its cache-read total.
        let data = try JSONSerialization.data(withJSONObject: [
            "usage": [
                "input_tokens": 3,
                "output_tokens": 1
            ],
            "modelUsage": [
                "grok-4.5": [
                    "inputTokens": 510,
                    "cacheReadInputTokens": 30_000,
                    "outputTokens": 14,
                    "contextWindow": 131_072
                ]
            ]
        ])
        let usage = try XCTUnwrap(ProviderProxyPolicy.grokJSONTokenUsage(from: data))
        XCTAssertEqual(usage.inputTokens, 30_510)
        XCTAssertEqual(usage.outputTokens, 14)
        XCTAssertEqual(usage.totalTokens, 30_524)
        XCTAssertEqual(usage.contextWindow, 131_072)
        XCTAssertNil(usage.contextTokens, "cumulative billing is not context occupancy")
    }

    func test_grokJSONTokenUsage_rejectsMalformedOrEmptyUsage() throws {
        XCTAssertNil(ProviderProxyPolicy.grokJSONTokenUsage(from: Data("not-json".utf8)))
        XCTAssertNil(ProviderProxyPolicy.grokJSONTokenUsage(
            from: try JSONSerialization.data(withJSONObject: [
                "usage": ["input_tokens": -1, "output_tokens": 0]
            ])
        ))
    }

    func test_claudeJSONTokenUsage_parsesCumulativeModelUsage() throws {
        // WHY: the installed Claude advisor is intentionally raw/read-only, so
        // its final JSON modelUsage is the only provider billing evidence.
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "result",
            "result": "sensitive advisor result is deliberately ignored",
            "total_cost_usd": 0.012345,
            "usage": [
                "input_tokens": 3,
                "output_tokens": 13
            ],
            "modelUsage": [
                "claude-haiku": [
                    "inputTokens": 513,
                    "cacheCreationInputTokens": 30_842,
                    "cacheReadInputTokens": 2_000,
                    "outputTokens": 14,
                    "contextWindow": 200_000
                ]
            ]
        ])
        let usage = try XCTUnwrap(ProviderProxyPolicy.claudeJSONTokenUsage(from: data))
        XCTAssertEqual(usage.inputTokens, 33_355)
        XCTAssertEqual(usage.outputTokens, 14)
        XCTAssertEqual(usage.totalTokens, 33_369)
        XCTAssertEqual(usage.uncachedInputTokens, 513)
        XCTAssertEqual(usage.cacheCreationInputTokens, 30_842)
        XCTAssertEqual(usage.cacheReadInputTokens, 2_000)
        XCTAssertEqual(usage.contextWindow, 200_000)
        XCTAssertNil(usage.contextTokens)
        XCTAssertEqual(usage.reportedCostMicros, 12_345)
    }

    func test_claudeJSONTokenUsage_rejectsPlainAdvisorOutput() {
        XCTAssertNil(ProviderProxyPolicy.claudeJSONTokenUsage(
            from: Data("review complete".utf8)
        ))
    }

    func test_providerJSONTokenUsage_rejectsIntegerOverflow() throws {
        // WHY: provider JSON is untrusted input; cumulative model totals must
        // fail closed instead of trapping the proxy process on Int overflow.
        let large = Int.max / 2 + 1
        let data = try JSONSerialization.data(withJSONObject: [
            "modelUsage": [
                "one": ["inputTokens": large, "outputTokens": 1],
                "two": ["inputTokens": large, "outputTokens": 1]
            ]
        ])
        XCTAssertNil(ProviderProxyPolicy.claudeJSONTokenUsage(from: data))
    }

    func test_JSONLineDecoder_emitsCompleteLinesIncrementallyAndRecoversAtEOF() {
        var decoder = ProviderProxyJSONLineDecoder(maximumLineBytes: 64)
        XCTAssertTrue(decoder.append(Data(#"{"type":"partial""#.utf8)).isEmpty)
        XCTAssertEqual(
            decoder.append(Data(
                (#","value":1}"# + "\r\n" + #"{"tail":2}"#).utf8
            )),
            [Data(#"{"type":"partial","value":1}"#.utf8)]
        )
        XCTAssertEqual(decoder.finish(), [Data(#"{"tail":2}"#.utf8)])
    }

    func test_streamTap_forwardsProviderBytesExactlyBeforeTelemetryParsing() {
        // WHY: successful middleware must be invisible to provider automation,
        // including non-UTF8 bytes, CRLF, empty lines, and partial JSON chunks.
        let chunks = [
            Data([0x7B, 0x22, 0x61]),
            Data([0x22, 0x3A, 0x31, 0x7D, 0x0D, 0x0A]),
            Data([0xFF, 0x00, 0x0A])
        ]
        let original = chunks.reduce(into: Data()) { $0.append($1) }
        var forwarded = Data()
        var decoder = ProviderProxyJSONLineDecoder()
        var lines: [Data] = []
        for chunk in chunks {
            lines += ProviderProxyPolicy.forwardAndDecodeJSONLines(
                chunk,
                decoder: &decoder,
                forward: { forwarded.append($0) }
            )
        }
        lines += decoder.finish()

        XCTAssertEqual(forwarded, original)
        XCTAssertEqual(lines.first, Data(#"{"a":1}"#.utf8))
        XCTAssertEqual(lines.last, Data([0xFF, 0x00]))
    }

    func test_rawUsageEligibility_recordsActualTokensButNoEligibleRunWhenOff() {
        XCTAssertEqual(ProviderProxyPolicy.rawUsageEligibleRuns(
            tokenSaverAdmitted: false,
            candidate: 1
        ), 0)
        XCTAssertEqual(ProviderProxyPolicy.rawUsageEligibleRuns(
            tokenSaverAdmitted: true,
            candidate: 1
        ), 1)
    }

    func test_streamUsage_reconcilesIncrementalClaudeWithFinalCumulativeSnapshot() throws {
        let assistant = Data(#"{"type":"assistant","message":{"usage":{"input_tokens":4,"cache_creation_input_tokens":3,"output_tokens":2}}}"#.utf8)
        let result = Data(#"{"type":"result","modelUsage":{"claude-sonnet":{"inputTokens":4,"cacheCreationInputTokens":3,"cacheReadInputTokens":5,"outputTokens":2,"contextWindow":200000}}}"#.utf8)
        let first = try XCTUnwrap(ProviderProxyPolicy.streamJSONTokenUsage(
            from: assistant,
            provider: .claude
        ))
        let final = try XCTUnwrap(ProviderProxyPolicy.streamJSONTokenUsage(
            from: result,
            provider: .claude
        ))
        XCTAssertEqual(first.resolvedSemantics, .incremental)
        XCTAssertEqual(final.resolvedSemantics, .cumulative)

        var accumulator = ProviderProxyUsageAccumulator()
        let firstUpdate = accumulator.record(first)
        XCTAssertEqual(firstUpdate.delta?.totalTokens, 9)
        let finalUpdate = accumulator.record(final)
        XCTAssertEqual(finalUpdate.effective.totalTokens, 14)
        XCTAssertEqual(finalUpdate.delta?.totalTokens, 5)
        XCTAssertNil(
            accumulator.record(final).delta,
            "the final cumulative snapshot must not be billed twice"
        )
    }

    func test_streamUsage_parsesCodexCachedInputWithoutDoubleCounting() throws {
        let data = Data(#"{"type":"thread.token_usage","input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"total_tokens":110,"context_window":258400}"#.utf8)
        let usage = try XCTUnwrap(ProviderProxyPolicy.streamJSONTokenUsage(
            from: data,
            provider: .codex
        ))
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.uncachedInputTokens, 20)
        XCTAssertEqual(usage.cacheReadInputTokens, 80)
        XCTAssertEqual(usage.outputTokens, 10)
        XCTAssertEqual(usage.totalTokens, 110)
        XCTAssertEqual(usage.resolvedSemantics, .cumulative)
    }

    func test_usageCommitBuffer_retriesFailedDeltaWithNextObservationExactlyOnce() {
        // WHY: a transient store failure must not advance the committed
        // baseline. The next provider observation has to retry 100 + 50 as one
        // 150-token commit, without later duplicating either delta.
        var buffer = ProviderProxyUsageCommitBuffer()
        var attemptedTotals: [Int] = []
        var persistedTotal = 0

        buffer.enqueue(
            delta: AssistantTokenUsage(
                inputTokens: 80,
                outputTokens: 20,
                totalTokens: 100,
                uncachedInputTokens: 80,
                semantics: .incremental
            ),
            session: AssistantTokenUsage(totalTokens: 100)
        )
        XCTAssertFalse(buffer.persistPending(maxAttempts: 1) { attempt in
            attemptedTotals.append(attempt.delta.totalTokens)
            return ProviderProxyUsagePersistenceResult(
                persisted: false,
                eligibleRunRecorded: false
            )
        })

        buffer.enqueue(
            delta: AssistantTokenUsage(
                inputTokens: 40,
                outputTokens: 10,
                totalTokens: 50,
                uncachedInputTokens: 40,
                semantics: .incremental
            ),
            session: AssistantTokenUsage(totalTokens: 150)
        )
        XCTAssertTrue(buffer.persistPending(maxAttempts: 1) { attempt in
            attemptedTotals.append(attempt.delta.totalTokens)
            persistedTotal += attempt.delta.totalTokens
            XCTAssertEqual(attempt.delta.inputTokens, 120)
            XCTAssertEqual(attempt.delta.outputTokens, 30)
            XCTAssertEqual(attempt.delta.billedTotalTokenUnits, 150)
            XCTAssertEqual(attempt.session.totalTokens, 150)
            XCTAssertEqual(attempt.eligibleRunCandidate, 1)
            return ProviderProxyUsagePersistenceResult(
                persisted: true,
                eligibleRunRecorded: true
            )
        })

        XCTAssertEqual(attemptedTotals, [100, 150])
        XCTAssertEqual(persistedTotal, 150)
        XCTAssertTrue(buffer.persistPending(maxAttempts: 3) { _ in
            XCTFail("a committed delta must never be retried")
            return ProviderProxyUsagePersistenceResult(
                persisted: true,
                eligibleRunRecorded: true
            )
        })
    }

    func test_usageCommitBuffer_finalFlushRetriesWithBoundedBackoff() {
        // WHY: providers that emit usage only at EOF have no future observation
        // to trigger recovery, so final flush must retry transient failures.
        var buffer = ProviderProxyUsageCommitBuffer()
        var attempts = 0
        var retryNumbers: [Int] = []
        var persistedTotal = 0
        buffer.enqueue(
            delta: AssistantTokenUsage(totalTokens: 100, semantics: .incremental),
            session: AssistantTokenUsage(totalTokens: 100)
        )

        XCTAssertTrue(buffer.persistPending(
            maxAttempts: 3,
            retryDelay: { retryNumbers.append($0) }
        ) { attempt in
            attempts += 1
            guard attempts == 2 else {
                return ProviderProxyUsagePersistenceResult(
                    persisted: false,
                    eligibleRunRecorded: false
                )
            }
            persistedTotal += attempt.delta.totalTokens
            return ProviderProxyUsagePersistenceResult(
                persisted: true,
                eligibleRunRecorded: true
            )
        })

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(retryNumbers, [1])
        XCTAssertEqual(persistedTotal, 100)
        XCTAssertEqual(buffer.eligibleRunCandidate, 0)

        var failingBuffer = ProviderProxyUsageCommitBuffer()
        var boundedAttempts = 0
        var boundedRetryNumbers: [Int] = []
        failingBuffer.enqueue(
            delta: AssistantTokenUsage(totalTokens: 25, semantics: .incremental),
            session: AssistantTokenUsage(totalTokens: 25)
        )
        XCTAssertFalse(failingBuffer.persistPending(
            maxAttempts: 3,
            retryDelay: { boundedRetryNumbers.append($0) }
        ) { _ in
            boundedAttempts += 1
            return ProviderProxyUsagePersistenceResult(
                persisted: false,
                eligibleRunRecorded: false
            )
        })
        XCTAssertEqual(boundedAttempts, 3)
        XCTAssertEqual(boundedRetryNumbers, [1, 2])
        var recoveredTotal = 0
        XCTAssertTrue(failingBuffer.persistPending(maxAttempts: 1) { attempt in
            recoveredTotal += attempt.delta.totalTokens
            return ProviderProxyUsagePersistenceResult(
                persisted: true,
                eligibleRunRecorded: true
            )
        })
        XCTAssertEqual(recoveredTotal, 25, "bounded failure must retain the pending delta")
    }

    func test_usageCommitBuffer_offCommitsActualUsageWithoutConsumingEligibility() {
        // WHY: Token Saver OFF still records provider usage with eligibleRuns=0.
        // If it is enabled later in the same process, exactly the first admitted
        // commit may carry eligibleRuns=1.
        var buffer = ProviderProxyUsageCommitBuffer()
        buffer.enqueue(
            delta: AssistantTokenUsage(totalTokens: 40, semantics: .incremental),
            session: AssistantTokenUsage(totalTokens: 40)
        )
        XCTAssertTrue(buffer.persistPending(maxAttempts: 1) { attempt in
            XCTAssertEqual(attempt.eligibleRunCandidate, 1)
            return ProviderProxyUsagePersistenceResult(
                persisted: true,
                eligibleRunRecorded: false
            )
        })
        XCTAssertEqual(buffer.eligibleRunCandidate, 1)

        buffer.enqueue(
            delta: AssistantTokenUsage(totalTokens: 10, semantics: .incremental),
            session: AssistantTokenUsage(totalTokens: 50)
        )
        XCTAssertTrue(buffer.persistPending(maxAttempts: 1) { attempt in
            XCTAssertEqual(attempt.eligibleRunCandidate, 1)
            return ProviderProxyUsagePersistenceResult(
                persisted: true,
                eligibleRunRecorded: true
            )
        })
        XCTAssertEqual(buffer.eligibleRunCandidate, 0)
    }

    func test_streamUsage_withoutTotalDoesNotDoubleCountReasoningInsideOutput() throws {
        // WHY: some providers report reasoning as a subset of output. Without a
        // total_tokens field, adding both inflates actual usage and savings.
        let data = Data(#"{"usage":{"input_tokens":100,"output_tokens":30,"reasoning_tokens":20}}"#.utf8)
        let usage = try XCTUnwrap(ProviderProxyPolicy.streamJSONTokenUsage(
            from: data,
            provider: .grok
        ))
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.totalTokens, 130)

        let reasoningOnlyOutput = Data(#"{"usage":{"input_tokens":100,"output_tokens":10,"reasoning_tokens":40}}"#.utf8)
        let reasoningUsage = try XCTUnwrap(ProviderProxyPolicy.streamJSONTokenUsage(
            from: reasoningOnlyOutput,
            provider: .grok
        ))
        XCTAssertEqual(reasoningUsage.outputTokens, 40)
        XCTAssertEqual(reasoningUsage.totalTokens, 140)
    }

    func test_finalizationTracker_failedCommitCanRetryButSuccessIsTerminal() {
        let runId = UUID()
        var tracker = ProviderProxyFinalizationTracker()
        XCTAssertTrue(tracker.claim(runId))
        XCTAssertFalse(tracker.claim(runId), "only one finalize may be in flight")
        tracker.complete(runId, succeeded: false)
        XCTAssertFalse(tracker.isFinalized(runId))
        XCTAssertTrue(tracker.claim(runId), "a transient failure must release the claim")
        tracker.complete(runId, succeeded: true)
        XCTAssertTrue(tracker.isFinalized(runId))
        XCTAssertFalse(tracker.claim(runId), "a committed finalization is idempotent")
    }

    private func samGrokWorkerArguments(effort: String = "high") -> [String] {
        [
            "--prompt-file", "/tmp/worker-prompt.txt",
            "--model", "grok-4.5",
            "--effort", effort,
            "--output-format", "json",
            "--sandbox", "workspace",
            "--always-approve",
            "--no-memory",
            "--no-subagents",
            "--disallowed-tools", "Agent",
            "--no-auto-update"
        ]
    }

    private func replacingValue(
        _ flag: String,
        with value: String,
        in arguments: [String]
    ) -> [String] {
        var replaced = arguments
        let index = replaced.firstIndex(of: flag)!
        replaced[index + 1] = value
        return replaced
    }
}
