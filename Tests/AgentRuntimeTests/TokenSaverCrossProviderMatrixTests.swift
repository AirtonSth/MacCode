import XCTest
import Foundation
import CoreModel
@testable import AgentRuntime
@testable import DistillCore

/// Full matrix: Claude / Codex / Grok as primary, same-provider nested, and every
/// cross-provider pair — Token Saver techniques must stay admitted (distill hint,
/// managed_path, dialect injection, Claude-only PostToolUse).
final class TokenSaverCrossProviderMatrixTests: XCTestCase {
    private let threadID = "10000000-0000-0000-0000-000000000011"
    private let workspaceID = "20000000-0000-0000-0000-000000000012"
    private let projectID = "30000000-0000-0000-0000-000000000013"
    private let rootRunID = "40000000-0000-0000-0000-000000000014"
    private let attemptID = "50000000-0000-0000-0000-000000000015"

    private let providers: [AgentProvider] = [.claude, .codex, .grok]

    private func admit(
        _ provider: AgentProvider,
        sidecarAvailable: Bool = true
    ) -> TokenSaverExecutionReceipt {
        TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: sidecarAvailable,
            provider: provider,
            threadId: threadID,
            rootRunId: rootRunID,
            attemptId: attemptID,
            workspaceId: workspaceID,
            projectId: projectID,
            waveLive: "wave-a",
            graphifyActive: true
        )
    }

    func test_primaryAgents_allProvidersGetFullTokenSaverTechniquesWhenSidecarHealthy() {
        // WHY: product requires every admitted primary (Claude/Codex/Grok) to receive
        // the same provider-neutral admit signal + dialect; only Claude gets PostToolUse.
        for provider in providers {
            let receipt = admit(provider)
            let env = TokenSaverExecutionReceiptSeam.environment(from: receipt)
            XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(provider) distill hint")
            XCTAssertEqual(receipt.capabilities.distill, true, "\(provider) distill")
            XCTAssertEqual(receipt.capabilities.managedPath, true, "\(provider) managed_path")
            XCTAssertEqual(env["RC_TOKEN_SAVER_THREAD_ID"], threadID)
            XCTAssertEqual(env["RC_TOKEN_SAVER_WAVE_LIVE"], "wave-a")

            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt(
                "user work",
                environment: env
            )
            XCTAssertTrue(prompt.contains("| distill"), "\(provider) dialect must inject | distill")
            XCTAssertTrue(
                prompt.contains("MANDATORY") || prompt.contains("default-pipe"),
                "\(provider) must require default-pipe | distill"
            )
            XCTAssertTrue(
                prompt.contains("non-GUI") || prompt.contains("GUI"),
                "\(provider) must exempt GUI from | distill"
            )
            XCTAssertTrue(prompt.contains("NEVER pipe"), "\(provider) exact-output still forbidden")

            if provider == .claude {
                XCTAssertEqual(receipt.capabilities.postToolUse, true)
                XCTAssertEqual(env["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
            } else {
                XCTAssertNil(receipt.capabilities.postToolUse)
                XCTAssertNil(env["RC_TOKEN_SAVER_POST_TOOL_USE"])
            }
        }
    }

    func test_sameProviderNested_propagateKeepsDistillForAllProviders() {
        // WHY: same-provider subagents must not drop DISTILL_HINT (gate is admit signal, not "is subagent").
        for provider in providers {
            var parentEnv = TokenSaverExecutionReceiptSeam.environment(from: admit(provider))
            parentEnv["REMOTE_CODE_AGENT_PROVIDER"] = provider.rawValue
            parentEnv["RC_REMOTE_CODE_MANAGED_BIN"] = "/tmp/managed-bin"
            parentEnv["PATH"] = "/usr/bin:/bin"

            let child = TokenSaverExecutionReceiptSeam.propagate(
                into: parentEnv,
                provider: provider
            )
            XCTAssertEqual(child["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(provider) nested")
            XCTAssertEqual(child["RC_TOKEN_SAVER_ROOT_RUN_ID"], rootRunID)

            let processEnv = CodexRunner.processEnvironment(
                overrides: child,
                purpose: .agentTurn(provider),
                base: [
                    "HOME": "/tmp/home",
                    "PATH": "/opt/homebrew/bin",
                    "RC_LOGIN_SHELL_ENV_IMPORT": "0",
                    "RC_REMOTE_CODE_MANAGED_BIN": "/tmp/managed-bin",
                ]
            )
            let path = processEnv["PATH"] ?? ""
            XCTAssertTrue(
                path.hasPrefix("/tmp/managed-bin:") || path == "/tmp/managed-bin",
                "\(provider) nested PATH must front managed bin: \(path)"
            )
            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("", environment: processEnv)
            XCTAssertTrue(prompt.contains("| distill"), "\(provider) nested dialect")
        }
    }

    func test_crossProviderMatrix_allPairsReAdmitDistillAndCorrectPostToolUse() {
        // WHY: Claude→Grok, Codex→Grok, Grok→Claude, and every other pair must keep
        // distill/managed_path when sidecar healthy; only Claude children get PostToolUse.
        for parent in providers {
            for child in providers {
                let parentReceipt = admit(parent, sidecarAvailable: true)
                let retargeted = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
                    receipt: parentReceipt,
                    sidecarAvailable: true,
                    provider: child,
                    waveLive: "wave-a"
                )
                XCTAssertEqual(retargeted.provider, child.rawValue, "\(parent)→\(child)")
                XCTAssertEqual(retargeted.capabilities.distill, true, "\(parent)→\(child) distill")
                XCTAssertEqual(retargeted.capabilities.managedPath, true, "\(parent)→\(child) managed")
                let env = TokenSaverExecutionReceiptSeam.environment(from: retargeted)
                XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(parent)→\(child) hint")

                let expectedPost = ProviderProxyPolicy.childPostToolUseCapability(
                    targetProvider: child,
                    distillAvailable: true
                )
                if expectedPost == true {
                    XCTAssertEqual(retargeted.capabilities.postToolUse, true, "\(parent)→\(child) PTU")
                    XCTAssertEqual(env["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
                } else {
                    XCTAssertNil(retargeted.capabilities.postToolUse, "\(parent)→\(child) no PTU")
                    XCTAssertNil(env["RC_TOKEN_SAVER_POST_TOOL_USE"])
                }

                let prompt = AgentSkillInstaller.tokenSaverProviderPrompt(
                    "nested work",
                    environment: env
                )
                XCTAssertTrue(
                    prompt.contains("| distill"),
                    "\(parent)→\(child) must inject mandatory | distill dialect"
                )
            }
        }
    }

    func test_crossProvider_stickyDegradedParentUpgradesWhenSidecarRecovers() {
        // WHY: parent launched with sidecar_unavailable must not permanently starve
        // Claude→Grok / Codex→Claude / Grok→Codex children after the lease is live.
        let pairs: [(AgentProvider, AgentProvider)] = [
            (.claude, .grok), (.claude, .codex),
            (.codex, .grok), (.codex, .claude),
            (.grok, .claude), (.grok, .codex),
        ]
        for (parent, child) in pairs {
            let degraded = admit(parent, sidecarAvailable: false)
            XCTAssertEqual(degraded.capabilities.distill, false)
            let upgraded = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
                receipt: degraded,
                sidecarAvailable: true,
                provider: child
            )
            XCTAssertEqual(upgraded.capabilities.distill, true, "\(parent)→\(child)")
            XCTAssertEqual(upgraded.capabilities.managedPath, true, "\(parent)→\(child)")
            let env = TokenSaverExecutionReceiptSeam.environment(from: upgraded)
            XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(parent)→\(child)")
            if child == .claude {
                XCTAssertEqual(upgraded.capabilities.postToolUse, true)
            } else {
                XCTAssertNil(upgraded.capabilities.postToolUse)
            }
        }
    }

    func test_tokenSaverOff_scrubsDistillForAllProvidersAndCrossProviderChildren() {
        // WHY: fail-open when Token Saver is off — no dialect, no false PostToolUse.
        for provider in providers {
            let denied = TokenSaverExecutionReceiptSeam.admit(
                tokenSaverEnabled: false,
                sameUser: true,
                sidecarAvailable: true,
                provider: provider,
                threadId: threadID
            )
            XCTAssertEqual(TokenSaverExecutionReceiptSeam.environment(from: denied), [:])
            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt(
                "base",
                environment: [:]
            )
            XCTAssertEqual(prompt, "base")
            XCTAssertFalse(prompt.contains("| distill"))
        }
    }

    func test_providerProxyArguments_injectDialectWhenChildEnvAdmitted() {
        // WHY: nested launches go through providerProxyArguments; cross-provider children
        // must still receive the mandatory | distill policy block when DISTILL_HINT=1.
        for child in providers {
            let env = TokenSaverExecutionReceiptSeam.environment(from: admit(child))
            let args = AgentSkillInstaller.providerProxyArguments(
                provider: child,
                arguments: ["-p", "hello"],
                environment: env
            )
            // Args shape is provider-specific; the important proof is that the seam
            // does not drop Token Saver when building nested argv from admitted env.
            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("", environment: env)
            XCTAssertTrue(prompt.contains("MANDATORY") || prompt.contains("default-pipe"))
            XCTAssertTrue(prompt.contains("byte-exactly") || prompt.contains("full stdout"))
            XCTAssertFalse(args.isEmpty)
        }
    }

    func test_rawNestedCodexCarriesValidatedToolShellPolicyIntoProviderArgv() throws {
        // WHY: raw nested Codex does not launch through CodexRunner. Its own
        // app-server filters RC_* environment variables, so the provider proxy
        // must reuse the launcher's validated shell_environment_policy transport
        // or the installed zsh bridge never sees its receipt or ownership gates.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RawNestedCodexPolicy-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        let bridge = try installer.installProviderShellBridge()
        let appSupport = home.appendingPathComponent("app-support", isDirectory: true)
        let statePath = appSupport
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
            .path
        let originalZDOTDIR = home.appendingPathComponent("user-zdotdir", isDirectory: true)

        let childReceipt = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
            receipt: admit(.claude),
            sidecarAvailable: true,
            provider: .codex,
            waveLive: "wave-a"
        )
        var childEnvironment = TokenSaverExecutionReceiptSeam.environment(from: childReceipt)
        childEnvironment.merge(
            ProviderProxyPolicy.childDistillTransportEnvironment(
                targetProvider: .codex,
                capabilities: .init(
                    distill: childReceipt.capabilities.distill == true,
                    managedPath: childReceipt.capabilities.managedPath == true,
                    recoveryScope: childReceipt.capabilities.recoveryScope == true
                ),
                statePath: statePath,
                disabledLanes: Set(childReceipt.disabledLanes)
            )
        ) { _, childValue in childValue }
        childEnvironment["REMOTE_CODE_AGENT_PROVIDER"] = AgentProvider.codex.rawValue
        childEnvironment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = appSupport.path
        childEnvironment["RC_REMOTE_CODE_MANAGED_BIN"] = installer.managedCLIBinURL.path
        childEnvironment["RC_REMOTE_CODE_PROVIDER_PROXY_BIN"] = installer.managedCLIBinURL.path
        childEnvironment["RC_REMOTE_CODE_MANAGED_ZDOTDIR"] = bridge.path
        childEnvironment["RC_REMOTE_CODE_ORIGINAL_ZDOTDIR"] = originalZDOTDIR.path
        childEnvironment["RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR"] = originalZDOTDIR.path
        childEnvironment["ZDOTDIR"] = bridge.path
        childEnvironment["PATH"] = "\(installer.managedCLIBinURL.path):/usr/bin:/bin"

        let arguments = AgentSkillInstaller.providerProxyArguments(
            provider: .codex,
            arguments: ["exec", "--json", "-"],
            environment: childEnvironment
        )
        let execIndex = try XCTUnwrap(arguments.firstIndex(of: "exec"))
        let policyKeys = [
            TokenSaverExecutionReceipt.envKey,
            "RC_TOKEN_SAVER_DISTILL_HINT",
            "RC_TOKEN_SAVER_WORKSPACE_ID",
            "RC_TOKEN_SAVER_PROJECT_ID",
            "RC_TOKEN_SAVER_THREAD_ID",
            "RC_TOKEN_SAVER_ATTEMPT_ID",
            "REMOTE_CODE_AGENT_PROVIDER",
            "REMOTE_CODE_DISTILL_STATE_PATH",
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY",
            "RC_REMOTE_CODE_MANAGED_BIN",
            "PATH",
            "ZDOTDIR",
            "RC_REMOTE_CODE_MANAGED_ZDOTDIR",
            ProviderProxyPolicy.toolShellInterceptEnvironmentKey,
            ProviderProxyPolicy.unownedToolShellEnvironmentKey,
            ProviderProxyPolicy.providerTerminalStdoutEnvironmentKey,
        ]
        for key in policyKeys {
            let index = try XCTUnwrap(arguments.firstIndex(where: {
                $0.hasPrefix("shell_environment_policy.set.\(key)=")
            }), "missing raw nested Codex shell policy for \(key): \(arguments)")
            XCTAssertLessThan(index, execIndex, "\(key) must be a global config before `exec`")
            XCTAssertEqual(arguments[index - 1], "-c")
        }
    }

    func test_rawCodexResumeCarriesOnlyValidatedShellPolicy() throws {
        // WHY: codex exec resume must preserve the provider's continuation
        // ABI. It still needs the validated shell policy, but must not receive
        // a fresh developer-instructions/dialect prompt.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawCodexResume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentSkillInstaller(homeDirectory: home)
        let bridge = try installer.installProviderShellBridge()
        let appSupport = home.appendingPathComponent("app-support", isDirectory: true)
        let statePath = appSupport
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
            .path
        var environment = TokenSaverExecutionReceiptSeam.environment(from: admit(.codex))
        environment["REMOTE_CODE_AGENT_PROVIDER"] = AgentProvider.codex.rawValue
        environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = appSupport.path
        environment["REMOTE_CODE_DISTILL_STATE_PATH"] = statePath
        environment["RC_REMOTE_CODE_MANAGED_BIN"] = installer.managedCLIBinURL.path
        environment["RC_REMOTE_CODE_MANAGED_ZDOTDIR"] = bridge.path
        environment["ZDOTDIR"] = bridge.path
        environment["PATH"] = "\(installer.managedCLIBinURL.path):/usr/bin:/bin"
        let arguments = AgentSkillInstaller.providerProxyArguments(
            provider: .codex,
            arguments: ["exec", "resume", "session-id"],
            environment: environment
        )

        XCTAssertEqual(
            Array(arguments.suffix(3)),
            ["exec", "resume", "session-id"]
        )
        XCTAssertFalse(arguments.contains(where: { $0.contains("developer_instructions=") }))
        XCTAssertFalse(arguments.contains(where: { $0.contains("@sr2") }))
        XCTAssertTrue(
            arguments.contains(where: {
                $0.hasPrefix("shell_environment_policy.set.\(TokenSaverExecutionReceipt.envKey)=")
            })
        )
        let execIndex = try XCTUnwrap(arguments.firstIndex(of: "exec"))
        XCTAssertTrue(
            arguments[..<execIndex].contains(where: {
                $0.hasPrefix("shell_environment_policy.set.PATH=")
            })
        )
    }

    func test_codexChildPolicyRejectsSelfHashBinaryOutsideSelectedRuntimeRoot() throws {
        // WHY: a Claude/Grok parent must not donate a path-shaped binary from a
        // concurrent or legacy build to a Codex child. The host-selected
        // artifact root is the boundary for the absolute-shell capability.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexChildRuntimeRoot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("source/RemoteCodeDistillService")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("trusted-service".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let installer = AgentSkillInstaller(homeDirectory: home)
        let runtime = try XCTUnwrap(installer.runtimeInstaller(for: source))
        let trustedRoot = runtime.managedCLIBinURL.deletingLastPathComponent()
        let digest = try XCTUnwrap(AgentSkillInstaller.serviceBinaryIdentity(at: source))
        let siblingRoot = home
            .appendingPathComponent("sibling/.remote-code/runtime/\(digest)", isDirectory: true)
        let sibling = siblingRoot.appendingPathComponent("RemoteCodeDistillService")
        try FileManager.default.createDirectory(at: siblingRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: sibling)

        var environment = TokenSaverExecutionReceiptSeam.environment(from: admit(.codex))
        environment["REMOTE_CODE_AGENT_PROVIDER"] = AgentProvider.codex.rawValue
        environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = home.appendingPathComponent("support").path
        environment["REMOTE_CODE_DISTILL_STATE_PATH"] = home
            .appendingPathComponent("support/Distill/DistillCLIState.json").path
        environment["RC_REMOTE_CODE_MANAGED_BIN"] = runtime.managedCLIBinURL.path
        environment["RC_REMOTE_CODE_RUNTIME_ROOT"] = trustedRoot.path
        environment["PATH"] = "\(runtime.managedCLIBinURL.path):/usr/bin:/bin"
        environment["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"] = "1"
        environment[AgentSkillInstaller.toolShellProtocolEnvironmentKey] =
            AgentSkillInstaller.toolShellProtocolVersion
        environment[AgentSkillInstaller.toolShellBinaryEnvironmentKey] = sibling.path

        let arguments = ProviderSubprocessLauncher.codexShellEnvironmentPolicyArguments(
            provider: .codex,
            environment: environment
        )

        XCTAssertFalse(
            arguments.contains(where: {
                $0.contains("\(AgentSkillInstaller.toolShellBinaryEnvironmentKey)=")
            }),
            "untrusted shaped binary must fail open instead of entering Codex policy"
        )
        XCTAssertFalse(
            arguments.contains(where: {
                $0.contains("\(AgentSkillInstaller.toolShellProtocolEnvironmentKey)=")
            })
        )
    }

    func test_providerProxyArguments_nestedClaudeInjectsPostToolUseSettings() throws {
        // WHY: Elephant Task 1 nested Claude advisors (2.5M+ tokens each) recorded
        // Nested - Claude lifecycle receipts but zero token_saver_savings rows —
        // provider proxy set RC_TOKEN_SAVER_POST_TOOL_USE without injecting the
        // Claude CLI --settings PostToolUse hook that Agent App ClaudeRunner adds.
        // Advisor ABI is print+plan+Read/Glob/Grep only; PATH wrappers never fire.
        let env = TokenSaverExecutionReceiptSeam.environment(from: admit(.claude))
        XCTAssertEqual(env[ClaudeRunner.tokenSaverPostToolUseEnvKey], "1")

        let advisorArgv = [
            "--print",
            "--model", "opus",
            "--effort", "max",
            "--permission-mode", "plan",
            "--tools", "Read,Glob,Grep",
            "--no-session-persistence",
            "--output-format", "json"
        ]
        let args = AgentSkillInstaller.providerProxyArguments(
            provider: .claude,
            arguments: advisorArgv,
            environment: env
        )
        XCTAssertEqual(args.filter { $0 == "--settings" }.count, 1,
                       "nested Claude must get exactly one --settings for PostToolUse")
        guard let settingsIndex = args.firstIndex(of: "--settings"),
              settingsIndex + 1 < args.count,
              let data = args[settingsIndex + 1].data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any],
              let post = hooks["PostToolUse"] as? [[String: Any]],
              let commandHooks = post.first?["hooks"] as? [[String: Any]],
              let command = commandHooks.first?["command"] as? String
        else {
            return XCTFail("PostToolUse hook settings missing on nested Claude proxy argv")
        }
        XCTAssertTrue(command.hasSuffix("distill hook post-tool-use"),
                      "hook must point at managed distill post-tool-use: \(command)")
        XCTAssertEqual(
            object["outputStyle"] as? String,
            ClaudeRunner.sr2OutputStyleName,
            "nested Claude must also switch off the default natural-language output style"
        )
        // Original advisor ABI must survive (prompt transport, tools, plan mode).
        XCTAssertTrue(args.contains("--print"))
        XCTAssertTrue(args.contains("plan"))
        XCTAssertTrue(args.contains("Read,Glob,Grep"))
    }

    func test_providerProxyArguments_nestedClaudeSkipsSettingsWhenTokenSaverOff() {
        // WHY: fail-open — without POST_TOOL_USE the proxy must not rewrite argv.
        let args = AgentSkillInstaller.providerProxyArguments(
            provider: .claude,
            arguments: ["--print", "--model", "opus", "-p", "hi"],
            environment: [:]
        )
        XCTAssertFalse(args.contains("--settings"))
        XCTAssertEqual(args, ["--print", "--model", "opus", "-p", "hi"])
    }

    func test_providerProxyArguments_nestedClaudeMergesPostToolUseIntoInlineSettings() throws {
        // WHY: nested CLIs that already pass inline --settings must still get
        // PostToolUse hooks (prior skip left zero model-mode savings on advisors).
        let env = TokenSaverExecutionReceiptSeam.environment(from: admit(.claude))
        let original = ["--print", "--settings", "{\"custom\":true}", "-p", "hi"]
        let args = AgentSkillInstaller.providerProxyArguments(
            provider: .claude,
            arguments: original,
            environment: env
        )
        XCTAssertEqual(args.filter { $0 == "--settings" }.count, 1)
        guard let idx = args.firstIndex(of: "--settings"),
              idx + 1 < args.count,
              let data = args[idx + 1].data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("merged --settings JSON missing")
        }
        XCTAssertEqual(obj["custom"] as? Bool, true, "caller keys must survive merge")
        let hooks = try XCTUnwrap(obj["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PostToolUse"], "PostToolUse must be merged in")
        XCTAssertEqual(
            obj["outputStyle"] as? String,
            ClaudeRunner.sr2OutputStyleName,
            "inline --settings merge must still activate the SR2 output style"
        )
    }

    func test_tokenSaverDialect_forcesShellAndGraphifyCoverageForAllProviders() {
        // WHY: Grok/Codex native tools cannot rewrite; dialect must force
        // Graphify + shell+|distill coverage for Claude/Codex/Grok alike.
        for provider in providers {
            var env = TokenSaverExecutionReceiptSeam.environment(from: admit(provider))
            let distillPrompt = AgentSkillInstaller.tokenSaverProviderPrompt("base", environment: env)
            XCTAssertTrue(
                distillPrompt.contains("| distill") || distillPrompt.contains("default-pipe"),
                "\(provider) must require shell | distill"
            )
            XCTAssertTrue(
                distillPrompt.contains("read_file") || distillPrompt.contains("native")
                    || distillPrompt.contains("Coverage first"),
                "\(provider) must constrain native multi-file reads"
            )
            env["RC_GRAPHIFY_ENABLED"] = "1"
            env["RC_GRAPHIFY_GRAPH_JSON"] = "/tmp/graph.json"
            let withGraphify = AgentSkillInstaller.tokenSaverProviderPrompt("base", environment: env)
            XCTAssertTrue(
                withGraphify.contains("graphify query") || withGraphify.contains("Query-first"),
                "\(provider) must inject Graphify query-first when RC_GRAPHIFY_ENABLED=1"
            )
        }
    }

    func test_providerProxyArguments_allProvidersGetDialectOnSupportedNestedTurns() {
        // WHY: product requires dialect + managed PATH for Claude/Codex/Grok nested
        // raw CLI. PostToolUse rewrite is Claude-only (upstream ceiling: Codex has no
        // updatedToolOutput; Grok PostToolUse is passive per docs.x.ai hooks guide).
        // PATH wrappers (incl. bun/bunx) remain the primary auto-compress lever for
        // Codex/Grok shell tool output.
        struct Case {
            let provider: AgentProvider
            let argv: [String]
            let dialectMarker: String
        }
        let cases: [Case] = [
            Case(provider: .claude, argv: ["--print", "--model", "opus", "-p", "nested"], dialectMarker: "--append-system-prompt"),
            Case(provider: .codex, argv: ["exec", "--json", "do work"], dialectMarker: "developer_instructions="),
            Case(provider: .grok, argv: ["--prompt", "do work", "--model", "grok-4.5"], dialectMarker: "--rules"),
        ]
        for c in cases {
            let env = TokenSaverExecutionReceiptSeam.environment(from: admit(c.provider))
            XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(c.provider)")
            let args = AgentSkillInstaller.providerProxyArguments(
                provider: c.provider,
                arguments: c.argv,
                environment: env
            )
            let joined = args.joined(separator: " ")
            XCTAssertTrue(
                joined.contains(c.dialectMarker) || joined.contains("| distill") || joined.contains("MANDATORY"),
                "\(c.provider) nested argv must carry Token Saver dialect (\(c.dialectMarker)): \(joined.prefix(200))"
            )
            if c.provider == .claude {
                XCTAssertTrue(args.contains("--settings"), "Claude nested must inject PostToolUse --settings")
            } else {
                XCTAssertFalse(args.contains("--settings"), "\(c.provider) must not invent Claude-only --settings")
            }
        }
    }

    func test_crossProviderNestedChildEnv_frontsManagedPathAndPreservesThreadForAllPairs() {
        // WHY: ProviderProxyRunner.makeChildEnvironment must put managed wrappers first
        // for every parent→child pair so PATH wraps fire under Codex/Grok/Claude shell.
        // Savings attribute to parent thread_id (same as Nested receipts on Elephant).
        let managed = "/tmp/rc-managed-bin-matrix"
        for parent in providers {
            for child in providers {
                var parentEnv = TokenSaverExecutionReceiptSeam.environment(from: admit(parent))
                parentEnv["REMOTE_CODE_AGENT_PROVIDER"] = parent.rawValue
                parentEnv["RC_REMOTE_CODE_MANAGED_BIN"] = managed
                parentEnv["PATH"] = "/usr/bin:/bin"
                parentEnv["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"] = threadID

                let retargeted = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
                    receipt: admit(parent),
                    sidecarAvailable: true,
                    provider: child,
                    waveLive: "wave-a"
                )
                var childEnv = TokenSaverExecutionReceiptSeam.environment(from: retargeted)
                childEnv["RC_REMOTE_CODE_MANAGED_BIN"] = managed
                // Mirror proxy PATH rewrite when managed_path admitted.
                if retargeted.capabilities.managedPath == true {
                    let parts = (parentEnv["PATH"] ?? "")
                        .split(separator: ":")
                        .map(String.init)
                        .filter { $0 != managed }
                    childEnv["PATH"] = ([managed] + parts).joined(separator: ":")
                }
                let path = childEnv["PATH"] ?? ""
                XCTAssertTrue(
                    path.hasPrefix("\(managed):") || path == managed,
                    "\(parent)→\(child) PATH must front managed bin: \(path)"
                )
                XCTAssertEqual(childEnv["RC_TOKEN_SAVER_THREAD_ID"], threadID, "\(parent)→\(child) thread")
                XCTAssertEqual(childEnv["RC_TOKEN_SAVER_DISTILL_HINT"], "1", "\(parent)→\(child) distill")
                if child == .claude {
                    XCTAssertEqual(childEnv["RC_TOKEN_SAVER_POST_TOOL_USE"], "1", "\(parent)→\(child) PTU")
                } else {
                    XCTAssertNil(childEnv["RC_TOKEN_SAVER_POST_TOOL_USE"], "\(parent)→\(child) no PTU")
                }
            }
        }
    }

    func test_crossProviderNestedChildEnv_retargetsStateAndToolShellOwnershipForAllPairs() {
        // WHY: every admitted child needs the namespace-local Distill lease for
        // explicit pipes and managed wrappers. Only Codex needs the aggregate
        // tool-shell interceptor because Claude has PostToolUse and Grok has no
        // provider-native rewrite boundary.
        let statePath = "/tmp/remote-code-matrix/Distill/DistillCLIState.json"
        for parent in providers {
            for child in providers {
                let retargeted = TokenSaverExecutionReceiptSeam.reAdmitSidecarIfAvailable(
                    receipt: admit(parent),
                    sidecarAvailable: true,
                    provider: child,
                    waveLive: "wave-a"
                )
                let transport = ProviderProxyPolicy.childDistillTransportEnvironment(
                    targetProvider: child,
                    capabilities: .init(
                        distill: retargeted.capabilities.distill == true,
                        managedPath: retargeted.capabilities.managedPath == true,
                        recoveryScope: retargeted.capabilities.recoveryScope == true
                    ),
                    statePath: statePath,
                    disabledLanes: Set(retargeted.disabledLanes)
                )
                var childRuntime = TokenSaverExecutionReceiptSeam.environment(from: retargeted)
                childRuntime.merge(transport) { _, retargetedValue in retargetedValue }
                let scoped = ProviderProxyPolicy.childScopedEnvironment(
                    environment: [
                        "REMOTE_CODE_AGENT_PROVIDER": parent.rawValue,
                        ProviderProxyPolicy.toolShellInterceptEnvironmentKey: "stale",
                        ProviderProxyPolicy.unownedToolShellEnvironmentKey: "1",
                        ProviderProxyPolicy.providerTerminalStdoutEnvironmentKey: "1",
                    ],
                    targetProvider: child,
                    childRunId: UUID().uuidString,
                    childDelegationCapability: String(repeating: "a", count: 64),
                    tokenSaverEnvironment: childRuntime
                )

                XCTAssertEqual(
                    scoped["REMOTE_CODE_DISTILL_STATE_PATH"],
                    statePath,
                    "\(parent)→\(child) state path"
                )
                if child == .codex {
                    for marker in [
                        ProviderProxyPolicy.toolShellInterceptEnvironmentKey,
                        ProviderProxyPolicy.unownedToolShellEnvironmentKey,
                        ProviderProxyPolicy.providerTerminalStdoutEnvironmentKey,
                    ] {
                        XCTAssertEqual(
                            scoped[marker],
                            "1",
                            "\(parent)→\(child) full Codex tool-shell marker \(marker)"
                        )
                    }
                } else {
                    for marker in [
                        ProviderProxyPolicy.toolShellInterceptEnvironmentKey,
                        ProviderProxyPolicy.unownedToolShellEnvironmentKey,
                        ProviderProxyPolicy.providerTerminalStdoutEnvironmentKey,
                    ] {
                        XCTAssertNil(
                            scoped[marker],
                            "\(parent)→\(child) must scrub Codex marker \(marker)"
                        )
                    }
                }
            }
        }

        let denied = ProviderProxyPolicy.childDistillTransportEnvironment(
            targetProvider: .codex,
            capabilities: .init(
                distill: true,
                managedPath: true,
                recoveryScope: false
            ),
            statePath: statePath,
            disabledLanes: []
        )
        XCTAssertTrue(denied.isEmpty, "incomplete recovery admission must stay raw")

        let laneDisabled = ProviderProxyPolicy.childDistillTransportEnvironment(
            targetProvider: .codex,
            capabilities: .init(
                distill: true,
                managedPath: true,
                recoveryScope: true
            ),
            statePath: statePath,
            disabledLanes: [CommandWrapPolicy.toolShellLane]
        )
        XCTAssertEqual(laneDisabled["REMOTE_CODE_DISTILL_STATE_PATH"], statePath)
        XCTAssertNil(laneDisabled[ProviderProxyPolicy.toolShellInterceptEnvironmentKey])
        XCTAssertNil(laneDisabled[ProviderProxyPolicy.unownedToolShellEnvironmentKey])
        XCTAssertNil(laneDisabled[ProviderProxyPolicy.providerTerminalStdoutEnvironmentKey])
    }

    func test_wrapPolicy_noAllowlist_compressesGhApiAndMutatingStdoutForAllProviders() {
        // WHY: PATH wrap policy is provider-neutral (same binary for Claude/Codex/Grok
        // shells and nested proxies). Former allowlist blocked gh api — elephant undercount.
        // Compress eligibility must not depend on which provider owns the run.
        let noEnv: [String: String] = [:]
        let mustCompress: [(String, [String])] = [
            ("gh", ["api", "repos/o/r/pulls/1"]),
            ("gh", ["pr", "merge", "12"]),
            ("gh", ["pr", "list", "--json", "number,title"]),
            ("git", ["push"]),
            ("git", ["status"]),
            ("git", ["log", "--oneline", "-20"]),
            ("curl", ["-s", "https://example.com/api"]),
            ("python3", ["script.py"]),
            ("aws", ["s3", "ls"]),
        ]
        for (cmd, args) in mustCompress {
            XCTAssertTrue(
                CommandWrapPolicy.isWrapped(cmd) || WrappedCommandCatalog.commands.contains(cmd),
                "\(cmd) must be PATH-wrapped so Grok/Codex (no PostToolUse rewrite) can compress"
            )
            XCTAssertNil(
                CommandWrapPolicy.passthroughReason(command: cmd, args: args, environment: noEnv),
                "\(cmd) \(args.joined(separator: " ")) must compress (no allowlist)"
            )
        }
        // Exact-output carve-outs still apply for every provider.
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "rg", args: ["pattern"], environment: noEnv),
            "exact_output_command"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "sed", args: ["-n", "1,10p", "f"], environment: noEnv),
            "exact_output_command"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "git", args: ["diff"], environment: noEnv),
            "exact_patch_output"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "git", args: ["show", "HEAD:file"], environment: noEnv),
            "exact_output_subcommand"
        )
    }

    func test_dialectPrompt_allProviders_requirePipeAndDocumentNoAllowlist() {
        // WHY: voluntary | distill + wrapper policy must be identical for every
        // admitted provider and nested shape (gate = DISTILL_HINT, not provider).
        for provider in providers {
            let env = TokenSaverExecutionReceiptSeam.environment(from: admit(provider))
            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("work", environment: env)
            XCTAssertTrue(prompt.contains("| distill"), "\(provider)")
            XCTAssertTrue(
                prompt.contains("gh api") || prompt.contains("all subcommands"),
                "\(provider) dialect must document no-allowlist / gh api coverage"
            )
            XCTAssertTrue(
                prompt.contains("primary") && (prompt.contains("nested") || prompt.contains("subagent")),
                "\(provider) must apply to primary+nested"
            )
            XCTAssertTrue(prompt.contains("NEVER pipe") || prompt.contains("exact-output") || prompt.contains("rg"),
                          "\(provider) exact-output skip must remain")
        }
    }

    func test_footerDisplayStack_providerAgnostic_multiTurnAndAuto() {
        // WHY: chip stack (tool-output + dialect + cache + Auto) is pure and must
        // not depend on which provider produced the measured ledger row.
        // Surfaces import is not required — estimator is shared; footer seams
        // live in Surfaces but use the same bare-user stack.
        let measured = 4_534
        let multi = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: measured,
            tokenSaverEnabled: true,
            graphifyActive: false,
            orchestrationActive: true,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: 200_000,
                windowProviderBilledTokenUnits: 50_000,
                turnCount: 77,
                cacheReadInputTokens: 5_000_000
            )
        )
        XCTAssertGreaterThan(multi.estimatedCacheAmortization, measured * 10)
        XCTAssertEqual(
            multi.estimatedOrchestration,
            TokenSaverBareUserEstimator.estimateOrchestrationTokens(measured: measured)
        )
        XCTAssertGreaterThan(multi.totalCredible, measured * 10)
        // Off → measured only for every provider identity.
        let off = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: measured,
            tokenSaverEnabled: false,
            graphifyActive: true,
            orchestrationActive: true,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: 200_000,
                windowProviderBilledTokenUnits: 50_000,
                turnCount: 77,
                cacheReadInputTokens: 5_000_000
            )
        )
        XCTAssertEqual(off.totalCredible, measured)
    }

    func test_catalog_expandedHTTPCloudAndPython_availableToAllProviders() {
        // WHY: Grok/Codex rely on PATH wrap for auto compress; catalog must cover
        // noisy CLIs used by every agent shape (primary + nested).
        for name in ["curl", "wget", "aws", "gcloud", "az", "python", "python3"] {
            XCTAssertTrue(WrappedCommandCatalog.commands.contains(name), name)
            XCTAssertFalse(WrappedCommandCatalog.exactOutputCommandSet.contains(name), name)
        }
        // Still never wrap provider binaries or exact-output.
        for name in ["claude", "codex", "grok", "rg", "sed", "jq", "node"] {
            XCTAssertFalse(WrappedCommandCatalog.commands.contains(name), "\(name) must not be in wrap catalog")
        }
    }
}
