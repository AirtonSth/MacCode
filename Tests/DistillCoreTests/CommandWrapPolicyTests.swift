import XCTest
@testable import DistillCore
import CoreModel

final class CommandWrapPolicyTests: XCTestCase {
    private let noEnv: [String: String] = [:]

    func test_isWrapped_coversCompressibleFamilyOnly() {
        for c in ["find", "ls", "git", "gh", "glab", "swift", "xcodebuild", "/usr/bin/git",
                  "curl", "aws", "python3"] {
            XCTAssertTrue(CommandWrapPolicy.isWrapped(c), "\(c) must be wrapped")
        }
        // Exact-output tools must NOT be PATH-wrapped (agent needs full stdout).
        // `node` stays unwrapped (agent runtime / bridge); use bun/python for script compress.
        for c in ["rg", "grep", "sed", "cat", "head", "tail", "awk", "jq", "echo", "node", "rm"] {
            XCTAssertFalse(CommandWrapPolicy.isWrapped(c), "\(c) must NOT be wrapped")
        }
    }

    func test_exactOutputCatalog_isStableAndIncludesSedGrep() {
        XCTAssertTrue(WrappedCommandCatalog.isExactOutputCommand("sed"))
        XCTAssertTrue(WrappedCommandCatalog.isExactOutputCommand("/usr/bin/rg"))
        XCTAssertTrue(WrappedCommandCatalog.isExactOutputCommand("grep"))
        XCTAssertTrue(WrappedCommandCatalog.isExactOutputCommand("cat"))
        for command in ["shasum", "sha256sum", "md5", "cksum"] {
            XCTAssertTrue(
                WrappedCommandCatalog.isExactOutputCommand(command),
                "digest output is an exact verification payload: \(command)"
            )
            XCTAssertFalse(
                CommandWrapPolicy.isAutoWrappable(command),
                "a digest must never be routed through lossy Distill: \(command)"
            )
        }
        XCTAssertFalse(WrappedCommandCatalog.isExactOutputCommand("git"))
        XCTAssertFalse(WrappedCommandCatalog.commands.contains("sed"))
        XCTAssertFalse(WrappedCommandCatalog.commands.contains("rg"))
    }

    func test_passthroughReason_exactOutputAndDisabled() {
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "sed", args: ["-n", "1,50p", "f"], environment: noEnv),
            "exact_output_command"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "rg", args: ["pattern"], environment: noEnv),
            "exact_output_command"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "cat", args: ["file"], environment: noEnv),
            "exact_output_command"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "git", args: ["grep", "foo"], environment: noEnv),
            "exact_output_subcommand"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "git", args: ["show", "HEAD:file"], environment: noEnv),
            "exact_output_subcommand"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "ls", args: ["-la"], environment: ["REMOTE_CODE_WRAP_DISABLE": "1"]),
            "disabled"
        )
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "ls", args: ["-la"], environment: noEnv))
    }

    func test_claudePostToolUseOwnsOrdinaryWrapperOutputExactlyOnce() {
        let postToolUse = ["RC_TOKEN_SAVER_POST_TOOL_USE": "1"]

        for invocation in [
            ("swift", ["test", "--filter", "FeatureTests"]),
            ("git", ["status"]),
            ("/bin/zsh", ["-lc", "swift test --filter FeatureTests"]),
        ] {
            XCTAssertEqual(
                CommandWrapPolicy.passthroughReason(
                    command: invocation.0,
                    args: invocation.1,
                    environment: postToolUse
                ),
                "provider_post_tool_use_owner",
                "Claude PostToolUse must be the sole automatic owner of \(invocation)"
            )
        }

        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(
                command: "/bin/zsh",
                args: ["-lc", "swift test 2>&1 | distill 'test failures'"],
                environment: postToolUse
            ),
            "explicit_distill_pipeline",
            "an explicit pipe remains the sole owner before the provider fallback"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(
                command: "rg",
                args: ["-n", "needle", "Sources"],
                environment: postToolUse
            ),
            "exact_output_command",
            "exact-output policy remains stronger than provider ownership"
        )
        XCTAssertNil(
            CommandWrapPolicy.passthroughReason(
                command: "swift",
                args: ["test"],
                environment: ["RC_TOKEN_SAVER_POST_TOOL_USE": "0"]
            ),
            "only the admitted literal lane transfers ownership"
        )
    }

    func test_exactGitOutputPreservesGlobalOptionValuesBeforeTheSubcommand() {
        // WHY: paths and config assignments belonging to Git's global options are
        // not subcommands. Treating `/repo` or `color.ui=false` as the operation
        // would send exact blob/match output through a lossy Distill route.
        let exactInvocations = [
            ["-C", "/repo", "show", "HEAD:README.md"],
            ["-c", "color.ui=false", "show", "HEAD:README.md"],
            ["--git-dir", "/repo/.git", "grep", "needle"],
            ["-C/repo", "cat-file", "blob", "HEAD:README.md"],
            ["-ccolor.ui=false", "blame", "README.md"],
            ["--work-tree=/repo", "show", "HEAD:README.md"],
        ]
        for args in exactInvocations {
            XCTAssertEqual(
                CommandWrapPolicy.passthroughReason(command: "git", args: args, environment: noEnv),
                "exact_output_subcommand",
                "git \(args.joined(separator: " ")) must preserve exact output"
            )
        }

        XCTAssertNil(
            CommandWrapPolicy.passthroughReason(
                command: "git",
                args: ["-C", "/repo", "status"],
                environment: noEnv
            ),
            "an ordinary Git command with global options must remain Distill-eligible"
        )
    }

    func test_forwardingCommandsPreserveExactOutputChildrenButRemainEligibleOtherwise() {
        // WHY: universal wrappers may sit outside a byte-exact command. Distilling
        // `env rg`, `xargs rg`, or `time sed` would corrupt the agent-facing payload;
        // forwarding an ordinary command must remain compress-eligible.
        let exactChildren: [(String, [String])] = [
            ("env", ["rg", "pattern", "Sources"]),
            ("env", ["-i", "FOO=bar", "/usr/bin/rg", "pattern"]),
            ("env", ["-u", "FOO", "sed", "-n", "1,5p", "file"]),
            ("env", ["-P", "/usr/bin:/bin", "rg", "pattern"]),
            ("xargs", ["rg", "pattern"]),
            ("xargs", ["-0", "-n", "1", "sed", "-n", "1p"]),
            ("xargs", ["-J", "{}", "sed", "-n", "1p"]),
            ("xargs", ["-R2", "rg", "pattern"]),
            ("xargs", ["-S4096", "sed", "-n", "1p"]),
            ("time", ["sed", "-n", "1,5p", "file"]),
            ("time", ["-p", "--format", "%E", "rg", "pattern"]),
        ]
        for (command, args) in exactChildren {
            XCTAssertEqual(
                CommandWrapPolicy.passthroughReason(command: command, args: args, environment: noEnv),
                "exact_output_forwarded",
                "forwarded exact child must remain byte-exact"
            )
        }

        let ordinaryChildren: [(String, [String])] = [
            ("env", ["ls", "-la"]),
            ("env", ["FOO=bar", "git", "status"]),
            ("env", ["-P", "/usr/bin:/bin", "ls"]),
            ("xargs", ["-0", "ls"]),
            ("xargs", ["git", "status"]),
            ("xargs", ["-J", "{}", "ls"]),
            ("xargs", ["-R2", "git", "status"]),
            ("xargs", ["-S4096", "ls"]),
            ("time", ["ls", "-la"]),
            ("time", ["git", "status"]),
        ]
        for (command, args) in ordinaryChildren {
            XCTAssertNil(
                CommandWrapPolicy.passthroughReason(command: command, args: args, environment: noEnv)
            )
        }

        // `env -S` carries a shell-like command in its value. Even an ordinary
        // embedded child must pass through because argv parsing cannot prove its
        // exact-output or interactive shape safely.
        let splitStringInvocations: [(String, [String])] = [
            ("env", ["-S", "rg pattern"]),
            ("env", ["--split-string=ls -la"]),
            ("env", ["--split-string", "git status"]),
        ]
        for (command, args) in splitStringInvocations {
            XCTAssertEqual(
                CommandWrapPolicy.passthroughReason(command: command, args: args, environment: noEnv),
                "env_split_string",
                "env split-string invocations must remain untouched even for ordinary embedded commands"
            )
        }
    }

    func test_passthroughReason_compressesAllSubcommandsExceptExactOutputCarveOuts() {
        // WHY: product rule — distill every wrapped command (incl. former "mutating"
        // allowlist rejects like gh api / git push stdout). Only exact-output /
        // exact-patch families stay passthrough.
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "git", args: ["diff"], environment: noEnv),
            "exact_patch_output"
        )
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "git", args: ["diff", "--stat"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "git", args: ["log", "--oneline"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "git", args: ["status"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "git", args: ["branch", "--show-current"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "git", args: ["remote", "-v"], environment: noEnv))
        XCTAssertNil(
            CommandWrapPolicy.passthroughReason(command: "git", args: ["push"], environment: noEnv),
            "git push stdout is compress-eligible; side effects still run"
        )
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "git", args: ["branch", "-D", "feature"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "git", args: ["remote", "add", "origin", "url"], environment: noEnv))

        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "gh", args: ["pr", "diff", "12"], environment: noEnv),
            "exact_patch_output"
        )
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "gh", args: ["pr", "diff", "12", "--name-only"], environment: noEnv))
        XCTAssertNil(
            CommandWrapPolicy.passthroughReason(command: "gh", args: ["pr", "merge", "12"], environment: noEnv),
            "merge status text may distill"
        )
        XCTAssertNil(
            CommandWrapPolicy.passthroughReason(command: "gh", args: ["api", "repos/o/r/pulls/1"], environment: noEnv),
            "gh api was the elephant undercount hole — must compress"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "glab", args: ["mr", "diff", "12"], environment: noEnv),
            "exact_patch_output"
        )
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "glab", args: ["mr", "diff", "12", "--name-status"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "glab", args: ["mr", "merge", "12"], environment: noEnv))

        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "swift", args: ["test"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "xcodebuild", args: ["test"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "swift", args: ["package", "reset"], environment: noEnv))
    }

    func test_fullPatchInvocationsStayExactUnlessExplicitlySummaryOnly() {
        let summaryFlags = ["--stat", "--shortstat", "--numstat", "--name-only", "--name-status"]
        for flag in summaryFlags {
            XCTAssertNil(
                CommandWrapPolicy.passthroughReason(
                    command: "git",
                    args: ["diff", "HEAD~1", flag],
                    environment: noEnv
                ),
                "git diff \(flag) is explicit summary output and may remain eligible"
            )
        }
        XCTAssertNil(
            CommandWrapPolicy.passthroughReason(
                command: "/usr/bin/git",
                args: ["diff", "--stat=120", "HEAD"],
                environment: noEnv
            )
        )

        let exactInvocations: [(String, [String])] = [
            ("git", ["diff"]),
            ("git", ["diff", "HEAD~1", "HEAD"]),
            ("git", ["diff", "--cached"]),
            ("git", ["diff", "--stat", "--patch"]),
            ("git", ["diff", "--name-only", "-U5"]),
            ("gh", ["pr", "diff", "42"]),
            ("gh", ["pr", "diff", "42", "--name-only", "--patch"]),
            ("glab", ["mr", "diff", "42"]),
            ("glab", ["mr", "diff", "42", "--stat", "--raw"]),
        ]
        for (command, args) in exactInvocations {
            XCTAssertEqual(
                CommandWrapPolicy.passthroughReason(
                    command: command,
                    args: args,
                    environment: noEnv
                ),
                "exact_patch_output",
                "\(command) \(args.joined(separator: " ")) must stay byte-exact"
            )
        }
    }

    func test_shouldCompress_thresholdsAndEnvOverrides() {
        XCTAssertFalse(CommandWrapPolicy.shouldCompress(byteCount: 10, lineCount: 2, environment: noEnv))
        XCTAssertTrue(CommandWrapPolicy.shouldCompress(byteCount: 2_000, lineCount: 2, environment: noEnv), "over byte threshold")
        XCTAssertTrue(CommandWrapPolicy.shouldCompress(byteCount: 10, lineCount: 50, environment: noEnv), "over line threshold")
        XCTAssertTrue(CommandWrapPolicy.shouldCompress(byteCount: 10, lineCount: 6, environment: ["REMOTE_CODE_WRAP_MIN_LINES": "5"]))
    }

    func test_decide_failsClosedToPassthroughAndDistillsSmallEligibleOutput() {
        XCTAssertEqual(
            CommandWrapPolicy.decide(command: "ls", isTerminalToAgent: false, outputIsValidUTF8: true, byteCount: 99_999, lineCount: 999, environment: noEnv),
            .passthrough(reason: "not_terminal")
        )
        XCTAssertEqual(
            CommandWrapPolicy.decide(command: "find", isTerminalToAgent: true, outputIsValidUTF8: false, byteCount: 99_999, lineCount: 999, environment: noEnv),
            .passthrough(reason: "binary_output")
        )
        XCTAssertEqual(
            CommandWrapPolicy.decide(command: "git", isTerminalToAgent: true, outputIsValidUTF8: true, byteCount: 50, lineCount: 3, environment: noEnv),
            .compress,
            "every eligible terminal command must execute Distill regardless of output size"
        )
        XCTAssertEqual(
            CommandWrapPolicy.decide(command: "git", isTerminalToAgent: true, outputIsValidUTF8: true, byteCount: 5_000, lineCount: 120, environment: noEnv),
            .compress
        )
    }

    func test_decide_compressesTerminalCatalogCommandsForAllProvidersAndKeepsExactOutputRaw() {
        // WHY: Codex/Grok (and Claude wrap path) share this seam — compressible catalog
        // commands must compress when terminal; exact-output basenames never auto-compress.
        let largeLines = 80
        let largeBytes = 4_000
        for command in ["ls", "find", "git", "gh", "npm", "docker"] {
            XCTAssertEqual(
                CommandWrapPolicy.decide(
                    command: command,
                    isTerminalToAgent: true,
                    outputIsValidUTF8: true,
                    byteCount: largeBytes,
                    lineCount: largeLines,
                    environment: noEnv
                ),
                .compress,
                "\(command) must be wrap-compressible when terminal and above threshold"
            )
        }
        for exact in ["rg", "grep", "cat", "head", "sed", "jq"] {
            XCTAssertEqual(
                CommandWrapPolicy.passthroughReason(command: exact, args: [], environment: noEnv),
                "exact_output_command",
                "\(exact) must remain full-stdout (never PATH-wrapped compress)"
            )
        }
    }

    func test_extractionQuery_matchesExplicitDistillPromptForCompressibleCommands() {
        for command in ["find", "ls", "git", "gh", "/usr/bin/git"] {
            let q = CommandWrapPolicy.extractionQuery(forCommand: command)
            XCTAssertEqual(
                q,
                "Summarize the key output and exit status",
                "ordinary wrappers must use the live-proven explicit-distill prompt"
            )
        }
    }

    func test_faithfulnessGuard_rejectsTinyGarbageTokens() {
        XCTAssertFalse(CommandWrapPolicy.isFaithfulCompression(rawByteCount: 7_000, compressedContentByteCount: 4))
        XCTAssertTrue(CommandWrapPolicy.isFaithfulCompression(rawByteCount: 7_000, compressedContentByteCount: 200))
        XCTAssertTrue(CommandWrapPolicy.isFaithfulCompression(rawByteCount: 10, compressedContentByteCount: 10))
    }

    func test_wrappedCommandCatalog_includesEndorsedForcedWrapCategories() {
        // One representative per newly-endorsed category (package managers, build tools,
        // test runners, linters, containers/IaC, HTTP/cloud, python) must be forced-wrapped.
        let representatives = [
            "npm", "brew", "bun", "bunx", // package managers / install (bun used heavily by empath)
            "make", "cargo",     // build tools
            "pytest", "jest",    // test runners
            "eslint", "shellcheck", // linters
            "docker", "terraform",  // containers / IaC
            "curl", "aws", "python3" // HTTP / cloud / scripts (all providers)
        ]
        for c in representatives {
            XCTAssertTrue(WrappedCommandCatalog.commands.contains(c), "\(c) must be in the forced wrap catalog")
            XCTAssertFalse(WrappedCommandCatalog.exactOutputCommandSet.contains(c), "\(c) must not be exact-output")
        }
    }

    func test_wrappedCommandCatalog_neverOverlapsExactOutputFamily() {
        // The forced wrap catalog and the exact-output (byte-exact stdout) family must remain
        // fully disjoint sets — a command can never be both compressible and byte-exact.
        XCTAssertTrue(
            Set(WrappedCommandCatalog.commands).isDisjoint(with: Set(WrappedCommandCatalog.exactOutputCommands)),
            "commands and exactOutputCommands must never overlap"
        )
    }

    func test_autoWrapCoversArbitraryNonInteractiveCommandsButNotExactOrTUI() {
        XCTAssertTrue(CommandWrapPolicy.isAutoWrappable("custom-build-tool"))
        XCTAssertTrue(CommandWrapPolicy.isAutoWrappable("npx"))

        for command in ["rg", "sed", "cat", "vim", "less", "top", "codex", "distill"] {
            XCTAssertFalse(CommandWrapPolicy.isAutoWrappable(command), command)
        }
    }

    func test_shellLauncherWithExactInnerCommandPassesThrough() {
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(
                command: "/bin/zsh",
                args: ["-lc", "sed -n '10,30p' Sources/Foo.swift"],
                environment: [:]
            ),
            "exact_output_shell_payload"
        )
        XCTAssertNil(
            CommandWrapPolicy.passthroughReason(
                command: "/bin/zsh",
                args: ["-lc", "npx jest --runInBand"],
                environment: [:]
            )
        )
    }

    func test_shellExactIntentSurvivesEnvCommandAndXargsForwarders() {
        // WHY: bash/zsh is the outer PATH-wrapped process for these shapes. The
        // exact child can only protect its bytes if the shell detector carries
        // intent through every forwarding layer, including macOS xargs flags.
        let exactPayloads = [
            "env FOO=bar git -C /repo show HEAD:README.md",
            "command git -c color.ui=false show HEAD:README.md",
            "env FOO=bar command git --git-dir=/repo/.git grep needle",
            "printf 'HEAD:README.md\\n' | xargs git -C /repo show",
            "printf 'README.md\\n' | xargs -J {} git -ccolor.ui=false blame {}",
            "printf 'needle\\n' | xargs -0 command rg Sources",
            "command -v swift; command -v distill",
        ]
        for shell in ["/bin/bash", "/bin/zsh"] {
            for payload in exactPayloads {
                let expectedReason = payload.contains("|") ? "segmented_shell" : "exact_output_shell_payload"
                XCTAssertEqual(
                    CommandWrapPolicy.passthroughReason(
                        command: shell,
                        args: ["-lc", payload],
                        environment: noEnv
                    ),
                    expectedReason,
                    "\(shell) -lc \(payload) must preserve exact child output"
                )
            }
        }

        let ordinaryPayloads = [
            "env FOO=bar git -C /repo status",
            "command git -c color.ui=false log --oneline",
            "printf 'path\\n' | xargs git status",
        ]
        for payload in ordinaryPayloads {
            XCTAssertNil(
                CommandWrapPolicy.passthroughReason(
                    command: "/bin/zsh",
                    args: ["-lc", payload],
                    environment: noEnv
                ),
                "ordinary forwarded command must remain Distill-eligible: \(payload)"
            )
        }
    }

    func test_shellOutputClassificationSeparatesExactOrdinaryAndMixedSegments() {
        // WHY: a provider commonly batches exact probes and one noisy command
        // into the same `sh -c`. The outer shell must stay transparent while
        // the ordinary child wrapper owns exactly one compression request.
        XCTAssertEqual(
            CommandWrapPolicy.shellOutputClassification(
                "command -v swift\ncommand -v distill\nrg -n UNIQUE_EXACT_MATCH README.md\nswift noisy.swift"
            ),
            .mixed
        )
        XCTAssertEqual(
            CommandWrapPolicy.shellOutputClassification(
                "command -v swift; command -v distill; rg -n UNIQUE_EXACT_MATCH README.md"
            ),
            .exactOnly
        )
        XCTAssertEqual(
            CommandWrapPolicy.shellOutputClassification(
                "swift noisy.swift; printf 'rg; literal\\n'"
            ),
            .ordinaryOnly
        )
        XCTAssertEqual(
            CommandWrapPolicy.shellOutputClassification(
                "bash -lc 'rg -n UNIQUE_EXACT_MATCH README.md'"
            ),
            .exactOnly,
            "nested shell source must not hide an exact-output child from the outer classifier"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(
                command: "/bin/zsh",
                args: ["-lc", "command -v swift\nswift noisy.swift"],
                environment: noEnv
            ),
            "segmented_shell"
        )
    }

    func test_toolShellInterceptorOwnsOnlyOneSafeOrdinaryCatalogCommand() {
        // WHY: Codex launches an absolute login shell that bypasses PATH wrappers.
        // The aggregate interceptor may own one finite noisy command, but must
        // leave exact, compound, redirected, interactive, and unknown commands raw.
        for payload in [
            "swift noisy.swift",
            "/usr/bin/swift noisy.swift",
            "git status",
            "xcodebuild test -scheme RemoteCode",
        ] {
            XCTAssertTrue(
                CommandWrapPolicy.isSafeOrdinaryToolShellPayload(payload),
                "safe ordinary payload should be interceptor-owned: \(payload)"
            )
        }

        for payload in [
            "rg -n UNIQUE_EXACT_MATCH README.md",
            "command -v swift",
            "swift noisy.swift | distill summarize",
            "distill retrieve rc_123",
            "swift noisy.swift | wc -l",
            "swift noisy.swift > output.txt",
            "swift noisy.swift; git status",
            "swift noisy.swift && git status",
            "swift \"$SECRET\"",
            "export MODE=test",
            "python3",
            "printenv",
        ] {
            XCTAssertFalse(
                CommandWrapPolicy.isSafeOrdinaryToolShellPayload(payload),
                "unsafe or exact payload must stay raw: \(payload)"
            )
        }
    }

    func test_boundedSemicolonSegmentsOwnOnlySafeMixedCommands() throws {
        // WHY: the managed shell may split output ownership only when doing so
        // cannot change shell state or reinterpret ambiguous syntax.
        let segments = try XCTUnwrap(CommandWrapPolicy.boundedSemicolonSegments(
            "command -v swift;command -v distill;rg -n UNIQUE_EXACT_MATCH README.md;swift noisy.swift"
        ))
        XCTAssertEqual(
            segments,
            [
                .init(source: "command -v swift", preservesExactOutput: true),
                .init(source: "command -v distill", preservesExactOutput: true),
                .init(source: "rg -n UNIQUE_EXACT_MATCH README.md", preservesExactOutput: true),
                .init(source: "swift noisy.swift", preservesExactOutput: false),
            ]
        )

        let unsafe = [
            "rg needle file; swift noisy.swift | wc -l",
            "rg needle file; swift noisy.swift > result.txt",
            "rg needle file && swift noisy.swift",
            "rg needle file; swift $(printf noisy).swift",
            "cd /tmp; rg needle file; swift noisy.swift",
            "export FLAG=1; rg needle file; swift noisy.swift",
            "rg needle file\nswift noisy.swift",
            "rg needle file; ; swift noisy.swift",
        ]
        for payload in unsafe {
            XCTAssertNil(
                CommandWrapPolicy.boundedSemicolonSegments(payload),
                "unsafe payload must execute as one raw shell: \(payload)"
            )
        }
    }

    func test_nestedWrapperPassesThroughSoOuterCommandDistillsOnce() {
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(
                command: "npx",
                args: ["jest", "--runInBand"],
                environment: ["REMOTE_CODE_WRAP_PARENT": "1"]
            ),
            "nested_wrapper"
        )
    }

    func test_shellLauncherWithExplicitDistillPipelineDoesNotDistillTwice() {
        let payloads = [
            "set -o pipefail; npx jest 2>&1 | distill 'test result'",
            "set -o pipefail; npx jest 2>&1 | command distill 'test result'",
            "set -o pipefail; npx jest 2>&1 | env RC_EXPLICIT=1 distill 'test result'",
        ]
        for payload in payloads {
            XCTAssertEqual(
                CommandWrapPolicy.passthroughReason(
                    command: "/bin/zsh",
                    args: ["-lc", payload],
                    environment: [:]
                ),
                "explicit_distill_pipeline",
                "an explicit forwarded Distill stage must own compression exactly once: \(payload)"
            )
        }
    }

    func test_shellLauncherDoesNotTreatLongOptionContainingCAsCommandPayload() {
        XCTAssertNil(
            CommandWrapPolicy.passthroughReason(
                command: "/bin/bash",
                args: ["--rcfile", "/tmp/rc", "--command", "npx test | distill 'summary'"],
                environment: [:]
            ),
            "only a real shell -c flag should trigger pipeline/exact-output inspection"
        )
        XCTAssertEqual(
            CommandWrapPolicy.decide(
                command: "/bin/bash",
                args: ["-lc", "sed -n '1,5p' file"],
                isTerminalToAgent: true,
                outputIsValidUTF8: true,
                byteCount: 100,
                lineCount: 5,
                environment: [:]
            ),
            .passthrough(reason: "exact_output_shell_payload")
        )
    }

    func test_bareOrInteractiveShellPassesThroughButScriptShellRemainsEligible() {
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "bash", args: [], environment: [:]),
            "interactive_shell"
        )
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "zsh", args: ["-i"], environment: [:]),
            "interactive_shell"
        )
        XCTAssertNil(
            CommandWrapPolicy.passthroughReason(command: "bash", args: ["script.sh"], environment: [:]),
            "a finite shell script is a normal command-output invocation"
        )
    }

    func test_argumentLevelInteractiveShapesPassThroughButOrdinaryCommandsRemainEligible() {
        let interactive: [(String, [String])] = [
            ("python3", []),
            ("python3", ["-i", "script.py"]),
            ("node", []),
            ("node", ["--interactive"]),
            ("sqlite3", []),
            ("sqlite3", ["database.sqlite"]),
            ("git", ["add", "-p"]),
            ("git", ["commit"]),
            ("git", ["-C", "/repo", "commit"]),
            ("git", ["-c", "user.name=Tester", "commit"]),
            ("git", ["--git-dir", "/repo/.git", "commit"]),
            ("git", ["rebase", "-i", "HEAD~2"]),
            ("docker", ["run", "-it", "alpine"]),
            ("docker", ["exec", "--interactive", "--tty", "container", "sh"]),
            ("kubectl", ["exec", "-it", "pod", "--", "sh"]),
            ("npm", ["init"]),
        ]
        for (command, args) in interactive {
            XCTAssertEqual(
                CommandWrapPolicy.passthroughReason(command: command, args: args, environment: noEnv),
                "interactive_arguments",
                "\(command) \(args.joined(separator: " ")) must preserve its interactive session"
            )
        }

        let ordinary: [(String, [String])] = [
            ("python3", ["script.py"]),
            ("python3", ["-c", "print('ok')"]),
            ("node", ["script.js"]),
            ("node", ["--eval", "console.log('ok')"]),
            ("sqlite3", ["database.sqlite", "select 1;"]),
            ("git", ["add", "README.md"]),
            ("git", ["commit", "-m", "checkpoint"]),
            ("git", ["commit", "-am", "checkpoint"]),
            ("git", ["commit", "--amend", "--no-edit"]),
            ("docker", ["run", "--rm", "alpine", "echo", "ok"]),
            ("docker", ["exec", "container", "echo", "ok"]),
            ("kubectl", ["exec", "pod", "--", "echo", "ok"]),
            ("npm", ["init", "--yes"]),
            ("npm", ["test"]),
        ]
        for (command, args) in ordinary {
            XCTAssertNil(
                CommandWrapPolicy.passthroughReason(command: command, args: args, environment: noEnv),
                "\(command) \(args.joined(separator: " ")) must remain eligible for normal output handling"
            )
        }
    }
}
