import XCTest
import CoreModel
import AgentRuntime
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
        let scrubbed = ProviderProxyPolicy.removingLegacyOptimizationKeys(promoted)
        XCTAssertNil(scrubbed["RC_TOKEN_SAVER_THREAD_ID"])
        XCTAssertEqual(scrubbed["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"], thread)
        XCTAssertTrue(ProviderProxyPolicy.hasTelemetryScope(environment: scrubbed))
    }

    func test_removingLegacyOptimizationKeys_scrubsSpoofedLanesButPreservesRouting() {
        // WHY: stale inherited variables from an older build must not resurrect
        // the removed Token Saver / Graphify lanes, while routing stays intact.
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
        let scrubbed = ProviderProxyPolicy.removingLegacyOptimizationKeys(environment)
        XCTAssertFalse(scrubbed.keys.contains { $0.hasPrefix("RC_TOKEN_SAVER_") })
        XCTAssertFalse(scrubbed.keys.contains { $0.hasPrefix("RC_DISTILL_") })
        XCTAssertFalse(scrubbed.keys.contains { $0.hasPrefix("RC_GRAPHIFY_") })
        XCTAssertNil(scrubbed["REMOTE_CODE_DISTILL_STATE_PATH"])
        XCTAssertEqual(scrubbed["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"], "1")
        XCTAssertEqual(scrubbed["RC_REMOTE_CODE_AGENT_APP_COMMAND"], "/managed/remote-code")
        XCTAssertEqual(scrubbed["PATH"], "/managed:/usr/bin")
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
            childDelegationCapability: childCapability
        )
        XCTAssertEqual(scoped["REMOTE_CODE_AGENT_PROVIDER"], "grok")
        XCTAssertEqual(scoped["REMOTE_CODE_PROVIDER_INSTANCE_ID"], "grok")
        XCTAssertEqual(scoped["RC_REMOTE_CODE_ROOT_RUN_ID"], child)
        XCTAssertFalse(scoped.keys.contains { $0.hasPrefix("RC_TOKEN_SAVER_") },
                       "a parent's leftover Token Saver keys must not reach the child")
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

    func test_childScopedEnvironment_keepsHierarchyAndDropsLegacyKeys() {
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
            childDelegationCapability: childCapability
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

    func test_childScopedEnvironment_neverInheritsAParentDistillStatePath() {
        // WHY: the Distill sidecar lease path belonged to the removed Token
        // Saver; a parent's leftover value must not reach any child provider.
        let child = UUID().uuidString
        for target in [AgentProvider.codex, .claude, .grok] {
            let scoped = ProviderProxyPolicy.childScopedEnvironment(
                environment: [
                    "REMOTE_CODE_AGENT_PROVIDER": "claude",
                    "REMOTE_CODE_DISTILL_STATE_PATH": "/tmp/claude-parent-state"
                ],
                targetProvider: target,
                childRunId: child,
                childDelegationCapability: String(repeating: "d", count: 64)
            )
            XCTAssertNil(scoped["REMOTE_CODE_DISTILL_STATE_PATH"], "\(target)")
        }
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
        // Live sam-grok-worker emits --model grok-4.6; grok-4.5 remains valid.
        let models = ["grok-4.5", "grok-4.6", "grok-4.6-preview"]
        for model in models {
            for effort in ["low", "medium", "high", "xhigh", "max"] {
                let delegation = try XCTUnwrap(
                    ProviderProxyPolicy.samGrokWorkerAgentAppDelegation(
                        providerBasename: "/managed/grok",
                        arguments: samGrokWorkerArguments(effort: effort, model: model)
                    )
                )
                XCTAssertEqual(delegation.provider, .grok)
                XCTAssertEqual(delegation.promptFile, "/tmp/worker-prompt.txt")
                XCTAssertEqual(delegation.model, model)
                let normalizedEffort: String
                if model.hasPrefix("grok-4.6") {
                    normalizedEffort = ["max": "xhigh"][effort] ?? effort
                } else {
                    normalizedEffort = ["xhigh": "high", "max": "high"][effort] ?? effort
                }
                XCTAssertEqual(delegation.reasoningEffort.rawValue, normalizedEffort)
                XCTAssertEqual(delegation.permissionMode, .autoAcceptEdits)
                XCTAssertEqual(delegation.outputFormat, .grokJSON)
                XCTAssertEqual(delegation.arguments, [
                    "agent-app", "grok",
                    "--prompt-file", "/tmp/worker-prompt.txt",
                    "--model", model,
                    "--permission", "auto_accept_edits",
                    "--reasoning-effort", normalizedEffort,
                    "--output-format", "grok-json",
                    "--runtime-profile", "sam-grok-worker-v1"
                ])
            }
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
            replacingValue("--model", with: "grok-code", in: canonical),
            replacingValue("--model", with: "gpt-5.6", in: canonical),
            replacingValue("--effort", with: "minimal", in: canonical),
            replacingValue("--effort", with: "future", in: canonical),
            replacingValue("--effort", with: "ultracode", in: canonical),
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
                "--permission-mode", "plan", "--output-format", "json"
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

        let claudeUltracode = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "claude",
            arguments: ["--print", "--model", "claude-opus-4-7", "--effort", "ultracode"],
            promptFile: prompt
        ))
        XCTAssertEqual(claudeUltracode.reasoningEffort, .ultracode,
                       "Agent App must retain Ultracode workflows instead of reducing it to an xhigh receipt")
        let claudeOneMillionAlias = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "claude",
            arguments: ["--print", "--model", "sonnet[1m]", "--effort", "xhigh"],
            promptFile: prompt
        ))
        XCTAssertEqual(claudeOneMillionAlias.reasoningEffort, .xhigh)
        for modelWithoutExplicitEffort in [
            "claude-opus-4-7", "claude-sonnet-4-6", "opus[1m]", "sonnet[1m]", "best"
        ] {
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "claude",
                arguments: ["--print", "--model", modelWithoutExplicitEffort],
                promptFile: prompt
            ), "nested Claude must stay raw so user/project effort configuration remains authoritative")
        }
        for rawModel in ["claude-haiku-4-5", "claude-unknown-future", ""] {
            var arguments = ["--print"]
            if !rawModel.isEmpty { arguments += ["--model", rawModel] }
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "claude", arguments: arguments, promptFile: prompt
            ), "unknown, omitted, and no-effort Haiku contracts must stay on the raw CLI")
        }
        for unsupportedEffort in ["none", "ultra", "custom-future"] {
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "claude",
                arguments: ["--print", "--model", "opus", "--effort", unsupportedEffort],
                promptFile: prompt
            ), "nonrepresentable Claude effort \(unsupportedEffort) must stay on the raw CLI")
        }

        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "codex",
            arguments: ["exec", "--json", "--full-auto", "do the work"],
            promptFile: prompt
        ), "Codex without an explicit model or effort has no truthful nonoptional receipt")

        for modelWithoutExplicitEffort in [
            "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
            "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-spark"
        ] {
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "codex",
                arguments: ["exec", "--json", "--full-auto", "--model", modelWithoutExplicitEffort, "do the work"],
                promptFile: prompt
            ), "nested Codex must stay raw so config.toml effort, including ultra, remains authoritative")
        }

        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "codex",
            arguments: [
                "--config=model_reasoning_effort=\"low\"",
                "exec", "--model", "gpt-5.6-sol",
                "--config", "model_reasoning_effort='high'",
                "-c=model_reasoning_effort=medium",
                "-c", "model_reasoning_effort=max",
                "-c", "model_reasoning_effort=unsupported",
                "--", "-c", "model_reasoning_effort=low"
            ],
            promptFile: prompt
        ), "the last custom Codex effort is valid to Codex but not representable by Agent App, so promotion must fail closed")

        for unrepresentable in ["minimal", "none", "", "custom-future", "ultracode"] {
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "codex",
                arguments: [
                    "exec", "--model", "gpt-5.6-sol",
                    "-c", "model_reasoning_effort=max",
                    "-c", "model_reasoning_effort=\(unrepresentable)", "work"
                ],
                promptFile: prompt
            ), "last Codex effort '\(unrepresentable)' must override max and keep the raw CLI")
        }

        let codexAfterUltra = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "codex",
            arguments: [
                "exec", "--model", "gpt-5.6-sol",
                "-c", "model_reasoning_effort=ultra",
                "-c", "model_reasoning_effort=high", "work"
            ],
            promptFile: prompt
        ))
        XCTAssertEqual(codexAfterUltra.reasoningEffort, .high,
                       "a later representable override must supersede ultra exactly like the CLI")
        let ultraAfterMax = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "codex",
            arguments: [
                "exec", "--model", "gpt-5.6-sol",
                "-c", "model_reasoning_effort=max",
                "-c", "model_reasoning_effort=ultra", "work"
            ],
            promptFile: prompt
        ))
        XCTAssertEqual(ultraAfterMax.reasoningEffort, .ultra,
                       "a later Codex ultra override must promote instead of staying on the raw CLI")

        for maxModel in ["gpt-5.6", "gpt-5.6-terra", "gpt-5.6-luna"] {
            let delegation = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "codex",
                arguments: ["exec", "--model", maxModel, "-c", "model_reasoning_effort=max", "work"],
                promptFile: prompt
            ))
            XCTAssertEqual(delegation.reasoningEffort, .max,
                           "\(maxModel) advertises max in the live app-server catalog")
        }
        for ultraModel in ["gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
            let delegation = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "codex",
                arguments: ["exec", "--model", ultraModel, "-c", "model_reasoning_effort=ultra", "work"],
                promptFile: prompt
            ))
            XCTAssertEqual(delegation.reasoningEffort, .ultra,
                           "\(ultraModel) advertises ultra in the live app-server catalog")
        }
        for restrictedModel in ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-spark"] {
            let maxDelegation = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "codex",
                arguments: ["exec", "--model", restrictedModel, "-c", "model_reasoning_effort=max", "work"],
                promptFile: prompt
            ))
            XCTAssertEqual(maxDelegation.reasoningEffort, .xhigh,
                           "max must clamp when model support is absent or not observable")
            let ultraDelegation = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "codex",
                arguments: ["exec", "--model", restrictedModel, "-c", "model_reasoning_effort=ultra", "work"],
                promptFile: prompt
            ))
            XCTAssertEqual(ultraDelegation.reasoningEffort, .xhigh,
                           "ultra must clamp like max when model support is absent or not observable")
        }
        for unknownModel in ["", "gpt-custom-future"] {
            var arguments = ["exec"]
            if !unknownModel.isEmpty { arguments += ["--model", unknownModel] }
            arguments += ["-c", "model_reasoning_effort=max", "work"]
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "codex", arguments: arguments, promptFile: prompt
            ), "Agent App must not invent a receipt for an unknown Codex model contract")
        }

        for catalogModel in ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.3-codex", "gpt-5.2"] {
            let delegation = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "codex",
                arguments: [
                    "exec", "--model", catalogModel,
                    "-c", "model_reasoning_effort=high", "work"
                ],
                promptFile: prompt
            ), "CodexRunner catalog model \(catalogModel) must be promotable with a representable effort")
            XCTAssertEqual(delegation.provider, .codex)
            XCTAssertEqual(delegation.model, catalogModel)
            XCTAssertEqual(delegation.reasoningEffort, .high)
        }
        let astraMax = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "codex",
            arguments: [
                "exec", "--model", "gpt-6-astra",
                "-c", "model_reasoning_effort=max", "work"
            ],
            promptFile: prompt
        ))
        XCTAssertEqual(astraMax.reasoningEffort, .max,
                       "gpt-6-astra advertises max in the live catalog snapshot")

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

        let grokYolo = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: [
                "--model", "grok-4.5", "--effort", "high",
                "--prompt", "investigate", "--yolo"
            ],
            promptFile: prompt
        ))
        XCTAssertEqual(grokYolo.permissionMode, .fullAccess,
                       "grok-build clap aliases --yolo to --always-approve")
        XCTAssertEqual(grokYolo.reasoningEffort, .high)

        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: [
                "--model", "grok-4.5", "--effort", "high",
                "--prompt", "investigate", "--yolo", "--max-turns", "8"
            ],
            promptFile: prompt
        ), "promotion must not discard the caller's max-turns limit")

        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: ["--prompt", "investigate", "--always-approve"],
            promptFile: prompt
        ), "nested Grok must stay raw so default_reasoning_effort from config.toml remains authoritative")
        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: ["--prompt", "investigate", "--model", "grok-4.5", "--always-approve"],
            promptFile: prompt
        ), "even a known Grok model stays raw without an explicit effort flag")
        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: ["--prompt", "investigate", "--model", "grok-custom-future", "--effort", "max"],
            promptFile: prompt
        ), "unknown custom Grok models must stay raw when reasoning support cannot be proven")
        for unsupportedEffort in ["none", "ultra", "custom-future", "ultracode"] {
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "grok",
                arguments: ["--prompt", "investigate", "--model", "grok-4.6", "--effort", unsupportedEffort],
                promptFile: prompt
            ), "nonrepresentable Grok effort \(unsupportedEffort) must stay on the raw CLI")
        }
    }

    func test_nestedCLIAgentAppDelegation_rejectsAdminVersionAndResume() throws {
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
        for subcommand in ["fork", "review", "help"] {
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "codex",
                arguments: [
                    "exec", subcommand, "sess-1",
                    "--model", "gpt-6-astra",
                    "-c", "model_reasoning_effort=high"
                ],
                promptFile: prompt
            ), "codex exec \(subcommand) must stay on the raw CLI")
        }
        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "codex",
            arguments: [
                "exec", "--json", "--model", "gpt-5.6-sol",
                "-c", "model_reasoning_effort=high", "work"
            ],
            promptFile: prompt
        ), "codex exec --json is exec JSONL and must stay raw even when model and effort would otherwise promote")
        XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "codex",
            arguments: [
                "exec", "--json", "--model", "gpt-5.6-sol",
                "-c", "model_reasoning_effort=high", "work"
            ]
        ), "eligibility must reject exec --json before stdin materialization")
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
        for outputFormat in ["stream-json", "yaml"] {
            let arguments = [
                "--print", "--model", "opus", "--effort", "high",
                "--output-format", outputFormat
            ]
            XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
                providerBasename: "claude", arguments: arguments
            ), "unrepresented output format \(outputFormat) must stay on raw CLI")
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "claude", arguments: arguments, promptFile: prompt
            ), "unrepresented output format \(outputFormat) must not become text delegation")
        }
        let unforwardedClaudeOptions: [[String]] = [
            ["--include-hook-events"], ["--replay-user-messages"], ["--forward-subagent-text"],
            ["--add-dir", "/tmp/extra"], ["--mcp-config", "{}"], ["--json-schema", "{}"],
            ["--system-prompt-file", "/tmp/sys.md"], ["--append-system-prompt-file", "/tmp/append.md"],
            ["--plugin-dir", "/tmp/plugin"], ["--plugin-url", "https://example.invalid/p.zip"],
            ["--worktree", "wt"], ["-w", "wt2"], ["--fallback-model", "sonnet"],
            ["--bare"], ["--permission-prompts", "host"], ["--max-budget-usd", "1"],
            ["--name", "nested"], ["-n", "nested2"], ["--agents", "{}"],
            ["--agent", "reviewer"], ["--file", "file_abc:doc.txt"],
            ["--debug-file", "/tmp/debug.log"], ["--betas", "context-1m"],
            ["--from-pr", "1"], ["--remote-control", "desk"], ["--brief"],
            ["--chrome"], ["--no-chrome"], ["--dangerously-skip-permissions"],
            ["--allow-dangerously-skip-permissions"], ["--exclude-dynamic-system-prompt-sections"],
            ["--restricted"], ["--ax-screen-reader"], ["--bg"], ["--background"],
            ["--autocompact", "auto"], ["--max-turns", "4"],
            ["--cloud", "desk"], ["--environment", "env_1"], ["--teleport", "sess"],
            ["--tmux"], ["--prompt-suggestions", "off"],
            ["--remote-control-session-name-prefix", "rc"],
            ["--system-prompt-snapshot", "/tmp/snap.md"], ["--no-session-persistence"]
        ]
        for option in unforwardedClaudeOptions {
            let arguments = ["--print", "--model", "opus", "--effort", "high"] + option
            XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
                providerBasename: "claude", arguments: arguments
            ), "unforwarded Claude option \(option[0]) must remain on raw CLI")
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "claude", arguments: arguments, promptFile: prompt
            ), "unforwarded Claude option \(option[0]) must not be dropped by promotion")
        }
        XCTAssertTrue(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "claude",
            arguments: ["--print", "--model", "default", "--effort", "medium", "--permission-mode", "default", "--output-format", "json"]
        ), "Agent App's represented provider, effort, permission, and output fields remain promotable")
        XCTAssertTrue(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "claude",
            arguments: ["--print", "--model", "default", "--effort", "medium"]
        ), "live 2.1.282 catalog leads with id default (Opus 5.5)")
        let defaultPermission = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "claude",
            arguments: [
                "--print", "--model", "opus", "--effort", "high",
                "--permission-mode", "default"
            ],
            promptFile: prompt
        ))
        XCTAssertEqual(defaultPermission.permissionMode, .supervised,
                       "permission-mode default remains an accepted alias of manual")
        let manualPermission = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "claude",
            arguments: [
                "--print", "--model", "opus", "--effort", "high",
                "--permission-mode", "manual"
            ],
            promptFile: prompt
        ))
        XCTAssertEqual(manualPermission.permissionMode, .supervised)
        XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "claude",
            arguments: [
                "--print", "--model", "opus", "--effort", "high",
                "--future-unknown-flag"
            ]
        ), "unknown dash flags must stay fail-closed")
        let grokBase = ["--model", "grok-4.7", "--effort", "high", "--prompt", "investigate"]
        let unsupportedGrokOptions: [[String]] = [
            ["--max-turns", "1"], ["--json-schema", "{\"type\":\"object\"}"],
            ["--prompt-json", "{\"prompt\":\"do work\"}"], ["--cwd", "/other/worktree"],
            ["--tools", "bash"], ["--allow", "read"], ["--deny", "write"],
            ["--allowed-tools", "read"], ["--disallowed-tools", "write"],
            ["--allowedTools", "read"], ["--disallowedTools", "write"],
            ["--settings", "/tmp/grok-settings.json"], ["--input-format", "stream-json"],
            ["--rules", "rules.md"], ["--sandbox", "strict"],
            ["--system-prompt-override", "restricted"], ["--system-prompt", "restricted"],
            ["--debug-file", "/tmp/grok.log"], ["--leader-socket", "/tmp/grok.sock"],
            ["--agents", "agent.toml"], ["--agent", "reviewer"],
            ["--worktree-ref", "branch"], ["--ref", "branch"], ["--worktree", "/tmp/worktree"],
            ["-w", "/tmp/worktree"], ["--restore-code"], ["--include-partial-messages"],
            ["--verbatim"], ["--disable-web-search"], ["--no-leader"], ["--debug"],
            ["--auto-update"], ["--no-auto-update"], ["--memory"], ["--no-memory"],
            ["--plan"], ["--no-plan"], ["--subagents"], ["--no-subagents"],
            ["--fullscreen"], ["--minimal"], ["--no-alt-screen"], ["--oauth"]
        ]
        for option in unsupportedGrokOptions {
            let arguments = grokBase + option
            XCTAssertFalse(
                ProviderProxyPolicy.nestedCLIAgentAppEligible(
                    providerBasename: "grok", arguments: arguments
                ),
                "Grok option \(option.first ?? "") must remain on raw CLI"
            )
            XCTAssertNil(
                ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                    providerBasename: "grok", arguments: arguments,
                    promptFile: "/tmp/rc-nested-prompt.txt"
                ),
                "Grok option \(option.first ?? "") must not be dropped by promotion"
            )
        }
        let promptJSONArgs = [
            "--model", "grok-4.7", "--effort", "high",
            "--prompt-json", "{\"prompt\":\"do work\"}"
        ]
        XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "grok", arguments: promptJSONArgs
        ), "prompt-json is not decoded and must remain raw")
        XCTAssertNil(ProviderProxyPolicy.nestedCLIInlinePrompt(
            providerBasename: "grok", arguments: promptJSONArgs
        ))
    }

    func test_nestedCodexAgentAppEligibilityKeepsUnrepresentedExecOptionsRaw() {
        // WHY: These Codex 0.157 CLI options alter prompt inputs, tools, sandbox,
        // workspace, configuration, or output; nested Agent App does not forward them.
        let common = ["exec", "--model", "gpt-6-sol", "-c", "model_reasoning_effort=high", "work"]
        let unsupportedOptions: [[String]] = [
            ["-i", "/tmp/shot.png"], ["--add-dir", "/tmp/extra"],
            ["--enable", "web_search_tool"], ["--disable", "view_image_tool"],
            ["--worktree"], ["--thread-source", "api"],
            ["--output-schema", "/tmp/schema.json"],
            ["--output-last-message", "/tmp/last.txt"], ["-o", "/tmp/last.txt"],
            ["--local-provider", "ollama"], ["--approve-for-me"],
            ["--ignore-rules"], ["--dangerously-bypass-hook-trust"],
            ["--strict-config"]
        ]
        for option in unsupportedOptions {
            let arguments = common + option
            XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
                providerBasename: "codex", arguments: arguments
            ), "Codex option \(option.first ?? "") must remain on raw CLI")
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "codex", arguments: arguments,
                promptFile: "/tmp/rc-nested-prompt.txt"
            ), "Codex option \(option.first ?? "") must not be dropped by promotion")
        }
    }

    func test_nestedCodexAgentAppEligibility_failsClosedForUnrepresentedExecOptions() {
        // WHY: Agent App delegation preserves only model and reasoning effort;
        // consuming any other option would silently drop CLI behavior.
        let unrepresentedOptions = [
            ["-s", "read-only"], ["-i", "/tmp/shot.png"],
            ["--add-dir", "/tmp/extra"], ["--enable", "web_search_tool"],
            ["--disable", "view_image_tool"], ["--worktree"],
            ["--thread-source", "api"], ["--output-schema", "/tmp/schema.json"],
            ["--approve-for-me"], ["-o", "/tmp/result.txt"],
            ["--ask-for-approval", "never"], ["--profile", "custom"]
        ]
        for option in unrepresentedOptions {
            let arguments = ["exec", "--model", "gpt-6-astra"] + option + ["-c", "model_reasoning_effort=high", "work"]
            XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
                providerBasename: "codex",
                arguments: arguments
            ), "unrepresented option must stay on the raw Codex CLI: \(option)")
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "codex",
                arguments: arguments,
                promptFile: "/tmp/rc-nested-prompt.txt"
            ))
        }
        XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "codex",
            arguments: ["exec", "--model", "gpt-6-astra", "-c", "sandbox_mode=read-only", "work"]
        ), "arbitrary config overrides must not be discarded during promotion")
        XCTAssertTrue(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "codex",
            arguments: ["exec", "--model", "gpt-6-astra", "-c", "model_reasoning_effort=high", "work"]
        ))
    }

    func test_nestedEligibilityRejectsRawFallbackContractsBeforeReadingPromptInput() {
        // WHY: ProviderProxyRunner reads stdin only after this preflight. A
        // mapping that later returns nil would otherwise consume stdin and fail
        // instead of preserving the provider CLI's own config/default effort.
        let rawCases: [(String, [String])] = [
            ("claude", ["--print", "--model", "opus"]),
            ("claude", ["--print", "--model", "opus", "--effort", "ultra"]),
            ("codex", ["exec", "--model", "gpt-5.6-sol", "work"]),
            ("codex", ["exec", "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=minimal", "work"]),
            ("codex", ["exec", "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=none", "work"]),
            ("grok", ["--model", "grok-4.6", "--prompt", "work"]),
            ("grok", ["--model", "grok-4.6", "--effort", "ultra", "--prompt", "work"])
        ]
        for (provider, arguments) in rawCases {
            XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
                providerBasename: provider,
                arguments: arguments
            ), "\(provider) raw fallback must be decided before stdin/temp-file materialization")
        }

        XCTAssertTrue(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "codex",
            arguments: ["exec", "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high", "work"]
        ))
        let unrepresentedCodexOptions = [
            ["exec", "--enable", "web_search_cached", "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high", "work"],
            ["exec", "--add-dir", "/tmp/extra", "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high", "work"],
            ["exec", "-s", "read-only", "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high", "work"],
            ["exec", "-i", "/tmp/shot.png", "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high", "describe image"],
            ["exec", "--output-schema", "/tmp/schema.json", "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high", "work"],
            ["exec", "--approve-for-me", "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=high", "work"]
        ]
        for arguments in unrepresentedCodexOptions {
            XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
                providerBasename: "codex",
                arguments: arguments
            ), "unrepresented Codex options must keep the invocation on the raw CLI: \\(arguments)")
            XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
                providerBasename: "codex",
                arguments: arguments,
                promptFile: "/tmp/nested-prompt.txt"
            ), "promotion must not discard Codex option semantics: \\(arguments)")
        }
        XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "codex",
            arguments: [
                "exec", "--not-a-real-flag", "--model", "gpt-5.6-sol",
                "-c", "model_reasoning_effort=high", "work"
            ]
        ), "unknown dash flags still fail closed to the raw CLI")
        XCTAssertTrue(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "codex",
            arguments: ["exec", "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=ultra", "work"]
        ), "Codex ultra is representable and must promote before stdin materialization")
        XCTAssertTrue(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "grok",
            arguments: ["--model", "grok-4.6", "--effort", "high", "--prompt", "work"]
        ))
    }

    func test_nestedGrokScannersHonorYoloAndGrok141Flags() throws {
        // WHY: live grok 1.0.41 treats --yolo as --always-approve. Nested
        // scanners that mark --yolo / --max-turns unknown fail-close Agent App
        // promotion and drop the prompt. Unknown dash flags must still fail closed.
        let prompt = "/tmp/rc-nested-prompt.txt"
        let yolo = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: [
                "--model", "grok-4.6", "--effort", "high",
                "--prompt", "investigate", "--yolo"
            ],
            promptFile: prompt
        ))
        XCTAssertEqual(yolo.permissionMode, .fullAccess,
                       "--yolo is grok-build always-approve")

        XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "grok",
            arguments: [
                "--model", "grok-4.7", "--effort", "high",
                "--prompt", "investigate", "--max-turns", "8"
            ]
        ), "max-turn limits must remain enforced by the raw CLI")

        XCTAssertEqual(
            ProviderProxyPolicy.nestedCLIInlinePrompt(
                providerBasename: "grok",
                arguments: [
                    "--prompt", "inline work",
                    "--max-turns", "3",
                    "--verbatim",
                    "--debug-file", "/tmp/grok.debug"
                ]
            ),
            "inline work"
        )
        for option in ["--cwd", "--json-schema", "--deny", "--prompt-json"] {
            XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
                providerBasename: "grok",
                arguments: [
                    "--model", "grok-4.7", "--effort", "high",
                    "--prompt", "investigate", option, "value"
                ]
            ), "unforwarded \(option) must remain on the raw Grok CLI path")
        }

        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: [
                "--model", "grok-4.6", "--effort", "high",
                "--prompt", "investigate", "--future-authority-mode"
            ],
            promptFile: prompt
        ), "unknown grok dash flags must stay fail-closed")

        let dontAsk = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: [
                "--model", "grok-4.6", "--effort", "high",
                "--prompt", "investigate",
                "--permission-mode", "dontAsk"
            ],
            promptFile: prompt
        ))
        XCTAssertEqual(dontAsk.permissionMode, .fullAccess,
                       "dontAsk suppresses prompts and requires a full-access parent mapping")

        let autoArguments = [
            "--model", "grok-4.7", "--effort", "high",
            "--prompt", "investigate", "--permission-mode", "auto"
        ]
        XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "grok",
            arguments: autoArguments
        ), "classifier-based auto mode must stay on the raw CLI path before stdin reads")
        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: autoArguments,
            promptFile: prompt
        ), "classifier-based auto mode cannot be represented by Agent App")

        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "grok",
                arguments: ["--permission-mode", "dontAsk"]
            ),
            .explicit(.fullAccess)
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "grok",
                arguments: ["--permission-mode", "auto"]
            ),
            .explicit(.fullAccess),
            "grok auto is not acceptEdits; parent ceiling must not treat it as workspace edits"
        )
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "grok",
                arguments: ["--yolo"]
            ),
            .explicit(.fullAccess)
        )

        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: [
                "--model", "grok-4.6", "--effort", "high",
                "--prompt", "investigate",
                "--resume", "sid-keep-raw"
            ],
            promptFile: prompt
        ), "grok --resume is a value option and must stay on the raw CLI")
        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: [
                "--model", "grok-4.6", "--effort", "high",
                "--prompt", "investigate",
                "-s", "sid-keep-raw"
            ],
            promptFile: prompt
        ), "grok -s/--session-id must stay on the raw CLI")
        XCTAssertFalse(
            ProviderProxyPolicy.nestedCLIAgentAppEligible(
                providerBasename: "grok",
                arguments: ["-v"]
            ),
            "grok -v is --version and must stay on the raw CLI"
        )
        XCTAssertFalse(
            ProviderProxyPolicy.nestedCLIAgentAppEligible(
                providerBasename: "grok",
                arguments: ["-c"]
            ),
            "grok -c is --continue and must stay on the raw CLI"
        )

        XCTAssertFalse(ProviderProxyPolicy.nestedCLIAgentAppEligible(
            providerBasename: "grok",
            arguments: [
                "--model", "grok-4.7", "--effort", "high",
                "--prompt", "investigate",
                "--fullscreen", "--minimal", "--no-alt-screen", "--oauth"
            ]
        ), "Grok 4.7 CLI mode and authentication options must remain on raw CLI")
        let grok47 = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: [
                "--model", "grok-4.7", "--effort", "high",
                "--prompt", "investigate"
            ],
            promptFile: prompt
        ))
        XCTAssertEqual(grok47.model, "grok-4.7")
        XCTAssertEqual(grok47.reasoningEffort, .high)

        XCTAssertNil(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: [
                "--model", "grok-4.7-build-fast", "--effort", "high",
                "--prompt", "investigate"
            ],
            promptFile: prompt
        ), "grok-4.7-build-fast has no reasoning contract so nested Agent App stays fail-closed")
    }

    func test_nestedCLIAgentAppDelegation_samGrokWorkerKeepsRuntimeProfile() throws {
        let grok45 = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: samGrokWorkerArguments(effort: "high"),
            promptFile: "/tmp/worker-prompt.txt"
        ))
        XCTAssertEqual(grok45.model, "grok-4.5")
        XCTAssertEqual(grok45.runtimeProfile, .samGrokWorkerV1)
        XCTAssertEqual(grok45.outputFormat, .grokJSON)
        XCTAssertTrue(grok45.arguments.contains("sam-grok-worker-v1"))

        let grok46 = try XCTUnwrap(ProviderProxyPolicy.nestedCLIAgentAppDelegation(
            providerBasename: "grok",
            arguments: samGrokWorkerArguments(effort: "xhigh", model: "grok-4.6"),
            promptFile: "/tmp/worker-prompt.txt"
        ))
        XCTAssertEqual(grok46.model, "grok-4.6")
        XCTAssertEqual(grok46.reasoningEffort, .xhigh)
        XCTAssertEqual(grok46.runtimeProfile, .samGrokWorkerV1)
        XCTAssertEqual(grok46.outputFormat, .grokJSON)
        XCTAssertTrue(grok46.arguments.contains("sam-grok-worker-v1"))
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
        XCTAssertEqual(
            ProviderProxyPolicy.explicitPermissionRequest(
                providerBasename: "codex",
                arguments: ["exec", "--approve-for-me"]
            ),
            .explicit(.fullAccess),
            "--approve-for-me routes approval requests through an automatic reviewer"
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

    private func samGrokWorkerArguments(
        effort: String = "high",
        model: String = "grok-4.5"
    ) -> [String] {
        [
            "--prompt-file", "/tmp/worker-prompt.txt",
            "--model", model,
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
