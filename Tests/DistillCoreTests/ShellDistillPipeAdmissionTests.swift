import XCTest
import CoreModel
@testable import DistillCore
import AgentRuntime

final class ShellDistillPipeAdmissionTests: XCTestCase {
    private let distill = "/tmp/rc-bin/distill"

    private func decide(
        admitted: Bool = true,
        tool: String = "run_terminal_command",
        command: String,
        exists: Bool = true
    ) -> ShellDistillPipeAdmission.Decision {
        ShellDistillPipeAdmission.decide(
            admitted: admitted,
            toolName: tool,
            command: command,
            distillExecutable: distill,
            distillExists: exists
        )
    }

    func test_tokenSaverOffFailsOpen() {
        // WHY: paid toggle off must never mutate the agent's command.
        XCTAssertEqual(
            decide(admitted: false, command: "swift test"),
            .skipNotAdmitted
        )
    }

    func test_missingDistillBinaryFailsOpen() {
        // WHY: rewriting to `| missing-binary` would swallow stdout.
        XCTAssertEqual(
            decide(command: "swift test", exists: false),
            .skipMissingDistill
        )
    }

    func test_nonShellToolIsSkipped() {
        XCTAssertEqual(
            decide(tool: "read_file", command: "swift test"),
            .skipNotShell
        )
    }

    func test_nativeReadFileHasNoWrapOrAutoPipePath() {
        // WHY: 680 harvest reads are Grok native `read_file`. Wrappers and
        // PreToolUse auto-pipe only see shell tools. Do not invent a Grok
        // PostToolUse rewrite; official docs ignore that hook's stdout.
        XCTAssertFalse(WrappedCommandCatalog.commandSet.contains("read_file"))
        XCTAssertFalse(WrappedCommandCatalog.commandSet.contains("Read"))
        XCTAssertEqual(
            decide(tool: "read_file", command: ""),
            .skipNotShell
        )
        XCTAssertNil(ProviderProxyPolicy.childPostToolUseCapability(
            targetProvider: .grok,
            distillAvailable: true
        ))
        XCTAssertNil(ProviderProxyPolicy.childPostToolUseCapability(
            targetProvider: .codex,
            distillAvailable: true
        ))
        XCTAssertEqual(
            ProviderProxyPolicy.childPostToolUseCapability(
                targetProvider: .claude,
                distillAvailable: true
            ),
            true
        )
        let large = String(repeating: "func example() {}\n", count: 200)
        let readDecision = ToolOutputCompressionPolicy().decision(
            toolName: "Read",
            output: large,
            toolArgumentsSummary: "path=Sources/Foo.swift"
        )
        XCTAssertTrue(readDecision.shouldCompress,
                      "Claude PostToolUse may still compress Read; Grok cannot invoke this lane")
    }

    func test_exactOutputLastCommandsAreNotAutoPiped() {
        // WHY: agent needs every match/slice line next. Voluntary last-pipe
        // distill stays a separate explicit choice.
        let exact = [
            "rg -n FAIL Sources",
            "grep -n TODO Sources",
            "cat Sources/Foo.swift",
            "head -n 40 Sources/Foo.swift",
            "tail -n 20 /tmp/log",
            "sed -n '1,20p' Sources/Foo.swift",
            "awk '{print}' file",
            "git show HEAD:Sources/Foo.swift",
            "git grep -n TODO",
            "git blame Sources/Foo.swift",
            "git diff Sources/Foo.swift",
            "git diff --patch HEAD",
            "cd /tmp && rg -n FAIL .",
            "python3 script.py | rg error",
        ]
        for command in exact {
            XCTAssertEqual(
                decide(command: command),
                .skipExactOutput,
                command
            )
        }
    }

    func test_alreadyPipedIsNotDoublePiped() {
        let command = #"swift test 2>&1 | distill "Did tests pass?""#
        XCTAssertEqual(decide(command: command), .skipAlreadyPiped)
    }

    func test_guiAndInteractiveAreSkipped() {
        XCTAssertEqual(decide(command: "open -a Safari"), .skipGUI)
        XCTAssertEqual(decide(command: "vim Sources/Foo.swift"), .skipGUI)
        XCTAssertEqual(decide(command: "less README.md"), .skipGUI)
    }

    func test_wrapEligibleLastCommandsArePiped() {
        let commands = [
            "swift test --filter Foo",
            "cd /tmp && git status --short",
            "git log --oneline -20",
            "git diff --stat",
            "glab mr view 259",
            "ls -la Sources",
            "python3 script.py",
            "swift test 2>&1",
            "find . -name '*.swift'",
            "npm test",
        ]
        for command in commands {
            guard case .pipe(let rewritten) = decide(command: command) else {
                return XCTFail("expected pipe for \(command)")
            }
            XCTAssertTrue(rewritten.hasPrefix(command), rewritten)
            XCTAssertTrue(rewritten.contains(" | "), rewritten)
            XCTAssertTrue(rewritten.contains(distill), rewritten)
            XCTAssertTrue(
                rewritten.contains(ShellDistillPipeAdmission.posixSingleQuoted(ShellDistillPipeAdmission.defaultQuestion)),
                rewritten
            )
            XCTAssertFalse(
                ToolOutputCompressionPolicy.shellCommandLooksExactOutput(rewritten)
                    && !ToolOutputCompressionPolicy.lastPipelineCommandIsVoluntaryDistill(rewritten),
                "piped rewrite must classify as last-pipe distill, not raw exact-output: \(rewritten)"
            )
            XCTAssertTrue(
                ToolOutputCompressionPolicy.lastPipelineCommandIsVoluntaryDistill(rewritten),
                rewritten
            )
        }
    }

    func test_harvestReplay_165WrapEligibleMustPipeAndExactMustNot() {
        // WHY: this un-hinted Grok CLI session issued 0 `| distill` pipes.
        // Host PreToolUse must pipe wrap-eligible last commands and must not
        // auto-pipe raw rg/grep/cat. 165 = 287 shells − 122 exact-output (fire 1).
        var wrap: [String] = []
        let wrapMix: [(String, Int)] = [
            ("git status --short", 56),
            ("swift test --filter TokenSaver", 26),
            ("python3 harvest_replay.py", 17),
            ("ls -la Sources", 7),
            ("glab mr view 259", 6),
            ("npm test", 10),
            ("find . -name '*.swift'", 10),
            ("git log --oneline -20", 10),
            ("git diff --stat HEAD", 8),
            ("docker ps", 5),
            ("pytest -q", 5),
            ("make test", 5),
        ]
        for (command, count) in wrapMix {
            wrap.append(contentsOf: repeatElement(command, count: count))
        }
        XCTAssertEqual(wrap.count, 165, "fixture must stay 165 wrap-eligible shells")

        var piped = 0
        for command in wrap {
            guard case .pipe = decide(command: command) else {
                return XCTFail("wrap-eligible must pipe: \(command)")
            }
            piped += 1
        }
        XCTAssertEqual(piped, 165)

        let exact = WrappedCommandCatalog.exactOutputCommands.map { "\($0) payload" }
            + ["git show HEAD:File.swift", "git grep -n TODO", "git blame File.swift"]
        for command in exact {
            XCTAssertEqual(decide(command: command), .skipExactOutput, command)
        }

        // Token Saver off still fails open on the same 165.
        for command in wrap.prefix(5) {
            XCTAssertEqual(decide(admitted: false, command: command), .skipNotAdmitted)
        }
    }

    func test_pipedSwiftTestShapeStillCrushesForReceivingAgent() {
        // WHY: auto-pipe is useless if the receiving agent loses PASS/FAIL,
        // file:line, or error text. Replay the fire-2 XCTest crusher on the
        // output that `| distill` would feed the lossy router.
        var raw = ""
        for i in 1...20 {
            raw += "Test Case '-[Suite test_\(i)]' started.\n"
            raw += "Test Case '-[Suite test_\(i)]' passed (0.01 seconds).\n"
        }
        raw += "/Users/dev/AppTests.swift:12: error: -[Suite test_fail] : XCTAssertEqual failed\n"
        raw += "Test Case '-[Suite test_fail]' failed (0.02 seconds).\n"
        raw += "Test Suite 'Suite' failed at 2026-08-16.\n"
        raw += "Executed 21 tests, with 1 failure (0 unexpected) in 0.4 seconds\n"

        let routed = CommandOutputLossyRouter.routeIfBeneficial(
            input: raw,
            handle: "pipe-ab",
            query: ShellDistillPipeAdmission.defaultQuestion
        )
        let adopted = try! XCTUnwrap(routed, "XCTest chatter must still crush after a pipe")
        XCTAssertTrue(adopted.output.contains("test_fail"), adopted.output)
        XCTAssertTrue(adopted.output.contains("AppTests.swift:12"), adopted.output)
        XCTAssertTrue(adopted.output.contains("Executed 21"), adopted.output)
        XCTAssertFalse(adopted.output.contains("started."), adopted.output)
        XCTAssertLessThan(adopted.output.utf8.count, raw.utf8.count)
        XCTAssertEqual(adopted.output.contains("[[rc:pipe-ab]]"), true)

        let before = TokenEstimator.estimate(raw)
        let after = TokenEstimator.estimate(adopted.output)
        XCTAssertLessThan(after, before)
    }
}
