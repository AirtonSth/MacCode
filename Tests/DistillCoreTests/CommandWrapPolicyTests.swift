import XCTest
@testable import DistillCore

final class CommandWrapPolicyTests: XCTestCase {
    private let noEnv: [String: String] = [:]

    func test_isWrapped_coversReadSearchFamilyByBasename() {
        for c in ["rg", "grep", "find", "ls", "cat", "sed", "/bin/cat", "/opt/homebrew/bin/rg"] {
            XCTAssertTrue(CommandWrapPolicy.isWrapped(c), "\(c) must be wrapped")
        }
        for c in ["git", "echo", "node", "python3", "rm", "mv"] {
            XCTAssertFalse(CommandWrapPolicy.isWrapped(c), "\(c) must NOT be wrapped")
        }
    }

    func test_passthroughReason_sedInPlaceAndDisabled() {
        XCTAssertEqual(CommandWrapPolicy.passthroughReason(command: "sed", args: ["-i", "s/a/b/", "f"], environment: noEnv), "sed_in_place")
        XCTAssertEqual(CommandWrapPolicy.passthroughReason(command: "sed", args: ["-i.bak", "s/a/b/", "f"], environment: noEnv), "sed_in_place")
        XCTAssertEqual(CommandWrapPolicy.passthroughReason(command: "sed", args: ["--in-place=.bak", "s/a/b/", "f"], environment: noEnv), "sed_in_place")
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "sed", args: ["-n", "1,50p", "f"], environment: noEnv),
                     "a read-only sed slice is eligible for compression")
        XCTAssertEqual(CommandWrapPolicy.passthroughReason(command: "rg", args: ["x"], environment: ["REMOTE_CODE_WRAP_DISABLE": "1"]), "disabled")
        XCTAssertNil(CommandWrapPolicy.passthroughReason(command: "rg", args: ["x"], environment: noEnv))
    }

    func test_shouldCompress_thresholdsAndEnvOverrides() {
        XCTAssertFalse(CommandWrapPolicy.shouldCompress(byteCount: 10, lineCount: 2, environment: noEnv))
        XCTAssertTrue(CommandWrapPolicy.shouldCompress(byteCount: 2_000, lineCount: 2, environment: noEnv), "over byte threshold")
        XCTAssertTrue(CommandWrapPolicy.shouldCompress(byteCount: 10, lineCount: 50, environment: noEnv), "over line threshold")
        // env lowers the line threshold so a 6-line output now compresses
        XCTAssertTrue(CommandWrapPolicy.shouldCompress(byteCount: 10, lineCount: 6, environment: ["REMOTE_CODE_WRAP_MIN_LINES": "5"]))
    }

    func test_decide_failsClosedToPassthrough() {
        // not terminal -> passthrough even when big (the corruption-prevention case)
        XCTAssertEqual(
            CommandWrapPolicy.decide(command: "cat", isTerminalToAgent: false, outputIsValidUTF8: true, byteCount: 99_999, lineCount: 999, environment: noEnv),
            .passthrough(reason: "not_terminal")
        )
        // binary output -> passthrough
        XCTAssertEqual(
            CommandWrapPolicy.decide(command: "cat", isTerminalToAgent: true, outputIsValidUTF8: false, byteCount: 99_999, lineCount: 999, environment: noEnv),
            .passthrough(reason: "binary_output")
        )
        // below threshold -> passthrough
        XCTAssertEqual(
            CommandWrapPolicy.decide(command: "rg", isTerminalToAgent: true, outputIsValidUTF8: true, byteCount: 50, lineCount: 3, environment: noEnv),
            .passthrough(reason: "below_threshold")
        )
        // terminal + utf8 + over threshold -> compress
        XCTAssertEqual(
            CommandWrapPolicy.decide(command: "rg", isTerminalToAgent: true, outputIsValidUTF8: true, byteCount: 5_000, lineCount: 120, environment: noEnv),
            .compress
        )
    }

    func test_extractionQuery_neutralExtractiveForEveryWrappedCommand() {
        // Every wrapped command sends the same neutral extractive query: it routes unstructured
        // output to the BERT verbatim lane (beats the generative LLM on code AND search), while
        // structured JSON is still caught by the lossless content-router before BERT.
        for command in ["cat", "sed", "rg", "grep", "find", "ls", "/bin/cat", "/usr/bin/sed"] {
            let q = CommandWrapPolicy.extractionQuery(forCommand: command)
            XCTAssertNotNil(q, "\(command) must send a query")
            XCTAssertTrue(q?.lowercased().contains("verbatim") == true, "\(command) query must signal verbatim line selection")
        }
    }

    func test_faithfulnessGuard_rejectsTinyGarbageTokens() {
        // "NONE"/"PASS" from a multi-KB command is the distill model answering as a question.
        XCTAssertFalse(CommandWrapPolicy.isFaithfulCompression(rawByteCount: 7_000, compressedContentByteCount: 4))
        XCTAssertTrue(CommandWrapPolicy.isFaithfulCompression(rawByteCount: 7_000, compressedContentByteCount: 200))
        // a genuinely tiny raw can't produce >=24 content; floor relaxes to the raw size
        XCTAssertTrue(CommandWrapPolicy.isFaithfulCompression(rawByteCount: 10, compressedContentByteCount: 10))
    }

    func test_compressedContentByteCount_stripsRecoveryHandle() {
        // The handle line must not let a "NONE" token clear the faithfulness floor.
        let emitted = "NONE\n[[rc:3b73314b71ae1dbaa198f2d1b603005fa9a64087becdbb957f32fe0658ed9211]]\n"
        XCTAssertEqual(CommandWrapPolicy.compressedContentByteCount(emitted), 4)
        XCTAssertFalse(CommandWrapPolicy.isFaithfulCompression(
            rawByteCount: 7_000,
            compressedContentByteCount: CommandWrapPolicy.compressedContentByteCount(emitted)
        ), "a NONE token plus a handle must still be rejected as garbage")

        let real = "Sources/A.swift:12: func foo()\nSources/A.swift:20: func bar()\n[[rc:abc]]"
        XCTAssertGreaterThan(CommandWrapPolicy.compressedContentByteCount(real), 40)
    }

    func test_resolveRealExecutable_skipsManagedDirAndSelf() {
        let path = ["/managed/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let resolved = CommandWrapPolicy.resolveRealExecutable(
            command: "rg",
            pathEntries: path,
            managedBinDirectory: "/managed/bin",
            isExecutableFile: { $0 == "/managed/bin/rg" || $0 == "/usr/local/bin/rg" || $0 == "/usr/bin/rg" },
            // /usr/local/bin/rg happens to be ANOTHER symlink to our binary — must be skipped too.
            resolvesToSelf: { $0 == "/usr/local/bin/rg" }
        )
        XCTAssertEqual(resolved, "/usr/bin/rg",
                       "must skip the managed dir AND any candidate that resolves back to the wrapper binary")
    }

    func test_resolveRealExecutable_nilWhenNoRealBinary() {
        let resolved = CommandWrapPolicy.resolveRealExecutable(
            command: "rg",
            pathEntries: ["/managed/bin", "/usr/bin"],
            managedBinDirectory: "/managed/bin",
            isExecutableFile: { $0 == "/managed/bin/rg" }, // only the wrapper exists
            resolvesToSelf: { _ in false }
        )
        XCTAssertNil(resolved, "no real binary => nil so the wrapper behaves like the command is absent")
    }
}
