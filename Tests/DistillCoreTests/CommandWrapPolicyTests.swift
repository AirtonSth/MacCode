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
        for c in ["rg", "grep", "sed", "cat", "head", "tail", "awk", "jq", "echo", "node", "env", "rm"] {
            XCTAssertFalse(CommandWrapPolicy.isWrapped(c), "\(c) must NOT be wrapped")
        }
    }

    func test_exactOutputCatalog_isStableAndIncludesSedGrep() {
        XCTAssertTrue(WrappedCommandCatalog.isExactOutputCommand("sed"))
        XCTAssertTrue(WrappedCommandCatalog.isExactOutputCommand("/usr/bin/rg"))
        XCTAssertTrue(WrappedCommandCatalog.isExactOutputCommand("grep"))
        XCTAssertTrue(WrappedCommandCatalog.isExactOutputCommand("cat"))
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

    func test_decide_failsClosedToPassthrough() {
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
            .passthrough(reason: "below_threshold")
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

    func test_extractionQuery_neutralExtractiveForCompressibleCommands() {
        for command in ["find", "ls", "git", "gh", "/usr/bin/git"] {
            let q = CommandWrapPolicy.extractionQuery(forCommand: command)
            XCTAssertNotNil(q, "\(command) must send a query")
            XCTAssertTrue(q?.lowercased().contains("verbatim") == true, "\(command) query must signal verbatim line selection")
            XCTAssertNil(
                q.flatMap { LocalDistillRuntime.commandOutputIntent(question: $0) },
                "the generic wrapper query must not accidentally select a narrow deterministic contract"
            )
        }
    }

    func test_extractionQuery_keepsLargeReviewOutputOutOfPathsOnlyNONEFallback() throws {
        // WHY: the transparent `gh api` wrapper used to ask to preserve "file paths".
        // That phrase selected the paths-only extractor, which returned NONE for a large
        // review body; the wrapper then rejected the tiny result and exposed raw output.
        let question = try XCTUnwrap(CommandWrapPolicy.extractionQuery(forCommand: "gh"))
        let review = (1...30).map { "review finding \($0): preserve the requested change and evidence" }
            .joined(separator: "\n")

        let output = LocalDistillRuntime.commandOutputFallback(
            input: review,
            question: question,
            maxOutputCharacters: 4_000
        )

        XCTAssertNotEqual(output, "NONE")
        XCTAssertTrue(output.contains("review finding 1:"))
    }

    func test_structuredCommandOutput_minifiesANSIColoredGHJSONWithoutLosingFields() throws {
        // WHY: Grok forces color for `gh api --jq`; the ANSI bytes made valid JSON look like
        // prose, bypassed the deterministic router, and frequently failed open to full output.
        let rows: [[String: Any]] = (1...24).map { index in
            ["id": 4_941_500_000 + index, "state": "CHANGES_REQUESTED", "body": "finding \(index)"]
        }
        let prettyData = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        let pretty = try XCTUnwrap(String(data: prettyData, encoding: .utf8))
        let colored = "\u{001B}[1;38m\(pretty)\u{001B}[0m"
        let request = DistillRequest(
            mode: .commandOutput,
            input: colored,
            question: try XCTUnwrap(CommandWrapPolicy.extractionQuery(forCommand: "gh")),
            maxOutputCharacters: 4_000,
            reversibleStoreMinBytes: 256
        )

        let output = try XCTUnwrap(LocalDistillRuntime.structuredCommandOutput(for: request))
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        )

        XCTAssertEqual(decoded.count, rows.count)
        XCTAssertEqual(decoded.first?["body"] as? String, "finding 1")
        XCTAssertFalse(output.contains("\u{001B}"))
        XCTAssertLessThan(output.utf8.count, colored.utf8.count)
        XCTAssertTrue(
            CommandWrapPolicy.isFaithfulCompression(
                rawByteCount: colored.utf8.count,
                compressedContentByteCount: output.utf8.count
            ),
            "the wrapper must accept the structured result instead of falling back to raw stdout"
        )
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

    func test_wrappedCommandCatalog_neverWrapsShebangInterpreters() {
        // WHY: wrapping `node`/`env` intercepts `#!/usr/bin/env node` and
        // turns Homebrew Codex into Distill (`missing required option /opt/homebrew/bin/codex`).
        XCTAssertTrue(WrappedCommandCatalog.isShebangInterpreter("node"))
        XCTAssertTrue(WrappedCommandCatalog.isShebangInterpreter("/opt/homebrew/bin/env"))
        XCTAssertTrue(
            Set(WrappedCommandCatalog.commands).isDisjoint(with: WrappedCommandCatalog.shebangInterpreterCommandSet),
            "shebang interpreters must never be wrap targets"
        )
        XCTAssertTrue(
            Set(WrappedCommandCatalog.exactOutputCommands)
                .isDisjoint(with: WrappedCommandCatalog.shebangInterpreterCommandSet)
        )
    }
}
