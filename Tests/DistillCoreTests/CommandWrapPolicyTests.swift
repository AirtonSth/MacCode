import XCTest
@testable import DistillCore
import CoreModel

final class CommandWrapPolicyTests: XCTestCase {
    private let noEnv: [String: String] = [:]

    func test_isWrapped_coversCompressibleFamilyOnly() {
        for c in ["find", "ls", "git", "gh", "glab", "swift", "xcodebuild", "/usr/bin/git"] {
            XCTAssertTrue(CommandWrapPolicy.isWrapped(c), "\(c) must be wrapped")
        }
        // Exact-output tools must NOT be PATH-wrapped (agent needs full stdout).
        for c in ["rg", "grep", "sed", "cat", "head", "tail", "awk", "jq", "echo", "node", "rm"] {
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

    func test_passthroughReason_allowsReadOnlySubcommandsAndRejectsMutatingOnes() {
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "git", args: ["diff"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "git", args: ["log", "--oneline"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "git", args: ["status"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "git", args: ["branch", "--show-current"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "git", args: ["remote", "-v"], environment: noEnv))
        XCTAssertEqual(
            CommandWrapPolicy.passthroughReason(command: "git", args: ["push"], environment: noEnv),
            "mutating_subcommand",
            "git push must keep raw inherited streams and exact behavior"
        )
        XCTAssertEqual(CommandWrapPolicy.passthroughReason(command: "git", args: ["branch", "-D", "feature"], environment: noEnv), "mutating_subcommand")
        XCTAssertEqual(CommandWrapPolicy.passthroughReason(command: "git", args: ["remote", "add", "origin", "url"], environment: noEnv), "mutating_subcommand")

        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "gh", args: ["pr", "diff", "12"], environment: noEnv))
        XCTAssertEqual(CommandWrapPolicy.passthroughReason(command: "gh", args: ["pr", "merge", "12"], environment: noEnv), "mutating_subcommand")
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "glab", args: ["mr", "diff", "12"], environment: noEnv))
        XCTAssertEqual(CommandWrapPolicy.passthroughReason(command: "glab", args: ["mr", "merge", "12"], environment: noEnv), "mutating_subcommand")

        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "swift", args: ["test"], environment: noEnv))
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "xcodebuild", args: ["test"], environment: noEnv))
        XCTAssertEqual(CommandWrapPolicy.passthroughReason(command: "swift", args: ["package", "reset"], environment: noEnv), "mutating_subcommand")
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

    func test_extractionQuery_neutralExtractiveForCompressibleCommands() {
        for command in ["find", "ls", "git", "gh", "/usr/bin/git"] {
            let q = CommandWrapPolicy.extractionQuery(forCommand: command)
            XCTAssertNotNil(q, "\(command) must send a query")
            XCTAssertTrue(q?.lowercased().contains("verbatim") == true, "\(command) query must signal verbatim line selection")
        }
    }

    func test_faithfulnessGuard_rejectsTinyGarbageTokens() {
        XCTAssertFalse(CommandWrapPolicy.isFaithfulCompression(rawByteCount: 7_000, compressedContentByteCount: 4))
        XCTAssertTrue(CommandWrapPolicy.isFaithfulCompression(rawByteCount: 7_000, compressedContentByteCount: 200))
        XCTAssertTrue(CommandWrapPolicy.isFaithfulCompression(rawByteCount: 10, compressedContentByteCount: 10))
    }
}
