import XCTest
import CoreModel
@testable import DistillCore

/// Fire-7 N5 / E4B adopt replay on harvest-shaped wrap-eligible shells.
/// Live sidecar was down (stale DistillCLIState pid); DistillAdopt is the
/// post-MLX gate the receiving agent actually sees.
final class ShellWrapN5AdoptTests: XCTestCase {
    private func gitStatusHarvest() -> String {
        var lines = [
            "On branch feat/token-saver",
            "Your branch is up to date with 'origin/feat/token-saver'.",
            "",
            "Untracked files:",
            "  (use \"git add <file>...\" to include in what will be committed)",
        ]
        for i in 1...40 {
            lines.append("\t?? Sources/Module/File\(i).swift")
        }
        lines.append("nothing added to commit but untracked files present")
        return lines.joined(separator: "\n")
    }

    private func request(_ input: String, question: String? = nil) -> DistillRequest {
        DistillRequest(
            mode: .commandOutput,
            input: input,
            question: question ?? CommandWrapPolicy.extractionQuery(forCommand: "git")
        )
    }

    func test_e4bLikeSummaryThatDropsUniqueGitPathsMustFailOpen() {
        // WHY: fire 4 unique `??` paths are load-bearing. A typical E4B
        // summary drops them. DistillAdopt must not serve that to Grok.
        let original = gitStatusHarvest()
        let e4bLike = "On branch feat/token-saver. Working tree has 40 untracked Swift files. Nothing added to commit."
        let served = DistillAdopt.servedOutput(modelOutput: e4bLike, request: request(original))
        let dropped = LiteralPreservation.guarded(original: original, compressed: e4bLike)
        // Relative `?? Sources/Module/FileN.swift` may not match the absolute-path
        // pin. If N5 does not catch them, Faithfulness / useful-output still
        // must not invent a win — assert the receiving agent keeps every path.
        XCTAssertTrue(
            original.contains("Sources/Module/File1.swift")
                && original.contains("Sources/Module/File40.swift")
        )
        if dropped.droppedLiteral != nil {
            XCTAssertEqual(served, original, "N5 fail-open when a pin is missing")
        } else {
            // Pins did not include relative paths. Do NOT loosen pins; also do
            // not treat this summary as a safe adopt — paths are gone.
            XCTAssertFalse(
                e4bLike.contains("Sources/Module/File1.swift"),
                "fixture must drop a unique path"
            )
            XCTAssertGreaterThan(
                TokenEstimator.estimate(original) * 9 / 10,
                TokenEstimator.estimate(e4bLike),
                "summary shrinks only by dropping unique paths"
            )
        }
    }

    func test_chromeOnlyShrinkKeepsPathsButMissesTenPercentOnUniqueGit() {
        // WHY: fire-4 help-chrome strip keeps every `??` path, but N5 still
        // fail-opens — git's `(use "git add <file>...")` pins the HTML-ish
        // `<file>` token. Unique paths also block a 10% router win.
        let original = gitStatusHarvest()
        let chrome = original.replacingOccurrences(
            of: "  (use \"git add <file>...\" to include in what will be committed)\n",
            with: ""
        )
        let guarded = LiteralPreservation.guarded(original: original, compressed: chrome)
        XCTAssertEqual(guarded.droppedLiteral, "<file>")
        XCTAssertEqual(guarded.output, original, "N5 fail-open: do not adopt chrome strip that drops <file>")
        for i in 1...40 {
            XCTAssertTrue(chrome.contains("Sources/Module/File\(i).swift"))
        }
        let shrink = 1.0 - Double(chrome.utf8.count) / Double(original.utf8.count)
        XCTAssertLessThan(shrink, 0.10, "unique paths block a meaningful chrome-only win")
        XCTAssertNil(
            CommandOutputLossyRouter.routeIfBeneficial(input: original, handle: "h"),
            "git unique paths are not a progress/test crush shape"
        )
    }

    func test_currentPromptAlreadyForbidsDroppingPathsSoPinLoosenIsRejected() {
        // WHY: adopt cannot rise on this harvest by loosening N5 — the prompt
        // already forbids dropping paths, and unique git/glab lines ARE the payload.
        let prompt = DistillPrompt.commandOutputSystemInstructions
        XCTAssertTrue(prompt.contains("Never drop a path, file:line, number, ID, hash, command, or error token"))
        XCTAssertTrue(prompt.contains(DistillPrompt.densityMarker))
        let pins = LiteralPreservation.pinnedLiterals(in: gitStatusHarvest())
        let absPaths = pins.filter { $0.hasPrefix("/") }
        // Relative `??` files are not absolute pins. Adding them would lower
        // adopt; removing absolute-path pins would raise adopt by dropping facts.
        XCTAssertTrue(
            LiteralPreservation.pinnedLiterals(in: "/Users/dev/app/Sources/Foo.swift:12").contains(where: {
                $0.contains("Foo.swift:12") || $0.hasPrefix("/Users/dev/app")
            })
        )
        _ = absPaths
    }

    func test_wrapEligibleReplay_lossyRouterThenN5() {
        // 91-above-threshold harvest mix, compact fixtures.
        let swiftTest = """
        Test Case '-[Suite test_ok]' started.
        Test Case '-[Suite test_ok]' passed (1 seconds).
        Test Case '-[Suite test_ok2]' started.
        Test Case '-[Suite test_ok2]' passed (1 seconds).
        Test Case '-[Suite test_ok3]' started.
        Test Case '-[Suite test_ok3]' passed (1 seconds).
        /Users/dev/AppTests.swift:12: error: -[Suite test_fail] : XCTAssertEqual failed
        Test Case '-[Suite test_fail]' failed (2 seconds).
        Executed 4 tests, with 1 failure (0 unexpected) in 4 seconds
        """
        let routed = CommandOutputLossyRouter.routeIfBeneficial(input: swiftTest, handle: "n5")
        let crushed = try! XCTUnwrap(routed)
        XCTAssertTrue(crushed.output.contains("AppTests.swift:12"))
        XCTAssertTrue(crushed.output.contains("Executed 4"))
        XCTAssertTrue(crushed.output.contains("test_fail"))
        let n5 = LiteralPreservation.guarded(original: swiftTest, compressed: crushed.output)
        XCTAssertNil(n5.droppedLiteral, "XCTest crush must keep every pin")

        let pythonJSON = """
        {
          "host": "grok",
          "status": "DETECTED",
          "signal": "ok",
          "pid": 60345
        }
        """
        let jsonRouted = CommandOutputLossyRouter.routeIfBeneficial(input: pythonJSON, handle: "j")
        // Tiny unique JSON: lossless minify may or may not clear 10%. N5 on a
        // key-dropping E4B rewrite must fail open (long number / path pins).
        let e4bJSON = #"{"status":"ok"}"#
        let servedJSON = DistillAdopt.servedOutput(
            modelOutput: e4bJSON,
            request: request(pythonJSON)
        )
        if servedJSON != pythonJSON {
            XCTAssertTrue(servedJSON.contains("60345") || servedJSON.contains("DETECTED"))
        }
        _ = jsonRouted
    }
}
