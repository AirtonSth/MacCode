import XCTest
@testable import AgentRuntime
import CoreModel

/// WHY: cross-user execution runs the provider as another macOS user via the
/// system `sudo -u` (no helper install). It must no-op for the current uid,
/// only wrap allowlisted absolute binaries, set the target HOME (`-H`) so the
/// provider reads THAT user's ~/.claude account/MCP, and pick the auth mode
/// (`-A` graphical askpass vs `-n` non-interactive) deterministically.
final class RunAsUserProcessBootstrapTests: XCTestCase {

    private func otherUser() -> AgentRunAsUser {
        AgentRunAsUser(generatedUID: "local-work-502", shortName: "work", uid: 502, gid: 20, homePath: "/Users/work")
    }

    func test_currentUser_isPassthrough() throws {
        let current = AgentRunAsUser.current()
        let plan = try RunAsUserProcessBootstrap.plan(
            executablePath: "/usr/local/bin/codex",
            arguments: ["exec", "hi"],
            environment: ["FOO": "1"],
            currentDirectory: "/tmp",
            runAsUser: current,
            currentUID: current.uid
        )
        XCTAssertFalse(plan.usesHelper)
        XCTAssertEqual(plan.executablePath, "/usr/local/bin/codex")
        XCTAssertEqual(plan.arguments, ["exec", "hi"])
    }

    func test_otherUser_rewritesToSudo_withAskpass() throws {
        let plan = try RunAsUserProcessBootstrap.plan(
            executablePath: "/opt/homebrew/bin/claude",
            arguments: ["-p", "hello"],
            environment: ["PATH": "/usr/bin"],
            currentDirectory: "/Users/shared/project",
            runAsUser: otherUser(),
            askpassPath: "/tmp/askpass.sh",
            currentUID: 501
        )
        XCTAssertTrue(plan.usesHelper)
        XCTAssertEqual(plan.executablePath, "/usr/bin/sudo")
        // sudo -A --preserve-env=PATH -u work -H -- /opt/homebrew/bin/claude -p hello
        XCTAssertEqual(plan.arguments,
                       ["-A", "--preserve-env=PATH", "-u", "work", "-H", "--", "/opt/homebrew/bin/claude", "-p", "hello"])
        XCTAssertTrue(plan.arguments.contains("--preserve-env=PATH"),
                      "PATH must survive sudo env_reset so the provider finds node/git/rg")
        XCTAssertEqual(plan.environment["SUDO_ASKPASS"], "/tmp/askpass.sh",
                       "askpass must be exported so `sudo -A` can prompt without a tty")
        XCTAssertNil(plan.environment["HOME"], "-H sets the target HOME; we must not preset the caller's HOME")
    }

    func test_otherUser_withoutAskpass_usesNonInteractive() throws {
        let plan = try RunAsUserProcessBootstrap.plan(
            executablePath: "/opt/homebrew/bin/claude",
            arguments: ["-p", "hi"],
            environment: [:],
            currentDirectory: "/Users/shared",
            runAsUser: otherUser(),
            askpassPath: nil,
            currentUID: 501
        )
        XCTAssertEqual(plan.arguments.first, "-n",
                       "no askpass → -n so a missing credential fails loudly, never hangs on a tty")
        XCTAssertNil(plan.environment["SUDO_ASKPASS"])
    }

    func test_rejectsRelativeBinaryAndUnknownBasename() {
        for bad in ["codex", "/usr/bin/python3"] {
            XCTAssertThrowsError(
                try RunAsUserProcessBootstrap.plan(
                    executablePath: bad,
                    arguments: [],
                    environment: [:],
                    currentDirectory: "/tmp",
                    runAsUser: otherUser(),
                    askpassPath: "/tmp/a.sh",
                    currentUID: 501
                ),
                "must reject \(bad): only allowlisted absolute provider binaries may be elevated"
            )
        }
    }

    func test_rejectsRootAndSystemTargets() {
        let root = AgentRunAsUser(generatedUID: "r", shortName: "root", uid: 0, gid: 0, homePath: "/var/root")
        XCTAssertThrowsError(
            try RunAsUserProcessBootstrap.plan(
                executablePath: "/usr/local/bin/claude",
                arguments: [], environment: [:], currentDirectory: "/tmp",
                runAsUser: root, currentUID: 501
            ),
            "must never elevate to root / non-interactive uids"
        )
    }

    func test_askpassScript_promptsAndNamesTarget() {
        let body = RunAsUserProcessBootstrap.askpassScriptBody(targetUser: "airtonempath")
        XCTAssertTrue(body.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(body.contains("osascript"), "must pop a graphical password dialog")
        XCTAssertTrue(body.contains("hidden answer"), "password entry must be masked")
        XCTAssertTrue(body.contains("airtonempath"), "dialog must name the target user")
        XCTAssertTrue(body.contains("text returned of result"), "must print the entered password to stdout for sudo")
    }

    func test_materializeAskpass_writesExecutableScript() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-askpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try XCTUnwrap(RunAsUserProcessBootstrap.materializeAskpass(targetUser: "work", directory: dir))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(written.contains("work"))
    }
}
