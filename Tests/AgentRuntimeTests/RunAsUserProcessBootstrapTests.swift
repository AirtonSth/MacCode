import XCTest
@testable import AgentRuntime
import CoreModel

/// WHY: foreign-user launches must reuse one root-owned helper instead of
/// opening a graphical password dialog for every provider process.
final class RunAsUserProcessBootstrapTests: XCTestCase {

    private func otherUser() -> AgentRunAsUser {
        AgentRunAsUser(generatedUID: "local-work-502", shortName: "work", uid: 502, gid: 20, homePath: "/Users/work")
    }

    private func helperLocator(_ path: String = "/tmp/RemoteCodeRunAsUserHelper") -> (String) -> String? {
        { name in name == RunAsUserProcessBootstrap.helperExecutableNames[0] ? path : nil }
    }

    func test_currentUser_isPassthrough() throws {
        let current = AgentRunAsUser.current()
        let plan = try RunAsUserProcessBootstrap.plan(
            executablePath: "/usr/local/bin/codex",
            arguments: ["exec", "hi"],
            environment: ["FOO": "1"],
            currentDirectory: "/tmp",
            runAsUser: current,
            helperLocator: helperLocator(),
            currentUID: current.uid
        )
        XCTAssertFalse(plan.usesHelper,
                       "the current user must not cross the privileged boundary")
        XCTAssertEqual(plan.executablePath, "/usr/local/bin/codex")
        XCTAssertEqual(plan.arguments, ["exec", "hi"])
    }

    func test_otherUser_rewritesToInstalledHelper() throws {
        let plan = try RunAsUserProcessBootstrap.plan(
            executablePath: "/opt/homebrew/bin/claude",
            arguments: ["-p", "hello"],
            environment: [
                "PATH": "/usr/bin",
                "SUDO_ASKPASS": "/tmp/askpass.sh",
                "REMOTE_CODE_AGENT_PROVIDER": "claude"
            ],
            currentDirectory: "/Users/shared/project",
            provider: .claude,
            runAsUser: otherUser(),
            helperLocator: helperLocator(),
            currentUID: 501
        )
        XCTAssertTrue(plan.usesHelper)
        XCTAssertEqual(plan.executablePath, "/tmp/RemoteCodeRunAsUserHelper")
        XCTAssertEqual(
            plan.arguments,
            [
                "exec", "--uid", "502", "--gid", "20", "--home", "/Users/work",
                "--user", "work", "--cwd", "/Users/shared/project", "--",
                "/opt/homebrew/bin/claude", "-p", "hello"
            ],
            "foreign-user providers must enter the installed helper once and then exec as the target"
        )
        XCTAssertEqual(plan.environment["REMOTE_CODE_AGENT_PROVIDER"], "claude",
                       "provider identity must survive the helper boundary")
        XCTAssertNil(plan.environment["SUDO_ASKPASS"],
                     "an askpass path must never reach the target-user provider")
    }

    func test_foreignUser_withoutInstalledHelper_failsWithoutPrompt() {
        XCTAssertThrowsError(
            try RunAsUserProcessBootstrap.plan(
                executablePath: "/opt/homebrew/bin/claude",
                arguments: [],
                environment: [:],
                currentDirectory: "/Users/shared",
                runAsUser: otherUser(),
                helperLocator: { _ in nil },
                currentUID: 501
            ),
            "capability probes and unprepared launches must fail closed rather than prompt repeatedly"
        )
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
                    helperLocator: helperLocator(),
                    currentUID: 501
                ),
                "must reject \(bad): only allowlisted absolute provider binaries may cross the helper boundary"
            )
        }
    }

    func test_rejectsRootAndSystemTargets() {
        let root = AgentRunAsUser(generatedUID: "r", shortName: "root", uid: 0, gid: 0, homePath: "/var/root")
        XCTAssertThrowsError(
            try RunAsUserProcessBootstrap.plan(
                executablePath: "/usr/local/bin/claude",
                arguments: [],
                environment: [:],
                currentDirectory: "/tmp",
                runAsUser: root,
                helperLocator: helperLocator(),
                currentUID: 501
            ),
            "the helper must never elevate to root or a system account"
        )
    }

    func test_helperInstallation_isIdempotentAndDoesNotPersistPassword() throws {
        var installed = false
        var installCount = 0
        let install: (String, String, String?) -> Bool = { source, destination, askpass in
            XCTAssertEqual(source, "/tmp/bundled-helper")
            XCTAssertEqual(destination, "/tmp/installed-helper")
            XCTAssertNil(askpass, "the fake installer must not receive or persist a password")
            installCount += 1
            installed = true
            return true
        }
        let first = try RunAsUserProcessBootstrap.ensureHelperInstalled(
            sourcePath: "/tmp/bundled-helper",
            destinationPath: "/tmp/installed-helper",
            isInstalled: { _ in installed },
            sourceIsUsable: { _ in true },
            install: install
        )
        let second = try RunAsUserProcessBootstrap.ensureHelperInstalled(
            sourcePath: "/tmp/bundled-helper",
            destinationPath: "/tmp/installed-helper",
            isInstalled: { _ in installed },
            sourceIsUsable: { _ in true },
            install: install
        )
        XCTAssertEqual(first, "/tmp/installed-helper")
        XCTAssertEqual(second, first)
        XCTAssertEqual(installCount, 1,
                       "once the root-owned helper is installed, later actions must not reauthorize")
    }

    func test_pmSetArguments_areFixedAndWatcherBound() throws {
        let directory = URL(fileURLWithPath: "/tmp/RemoteCodeInsomnia-test")
        let stop = directory.appendingPathComponent("disable")
        XCTAssertEqual(
            try RunAsUserProcessBootstrap.pmSetArguments(
                disabled: true,
                watchProcessID: 12345,
                stopFile: stop,
                sessionDirectory: directory
            ),
            [
                "pmset", "--disablesleep", "1", "--watch-pid", "12345",
                "--stop-file", stop.path, "--session-directory", directory.path
            ],
            "Insomnia may pass only the fixed pmset setting and its crash watcher"
        )
        XCTAssertEqual(
            try RunAsUserProcessBootstrap.pmSetArguments(
                disabled: false,
                watchProcessID: nil,
                stopFile: nil,
                sessionDirectory: nil
            ),
            ["pmset", "--disablesleep", "0"]
        )
        XCTAssertThrowsError(
            try RunAsUserProcessBootstrap.pmSetArguments(
                disabled: false,
                watchProcessID: 12345,
                stopFile: stop,
                sessionDirectory: directory
            ),
            "a reset must not be able to smuggle watcher or arbitrary command arguments"
        )
    }

    func test_askpassScript_isMaskedAndStatesPasswordIsNotSaved() {
        let body = RunAsUserProcessBootstrap.askpassScriptBody(targetUser: "airtonempath")
        XCTAssertTrue(body.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(body.contains("osascript"), "the one-time installer must still provide a graphical password field")
        XCTAssertTrue(body.contains("hidden answer"), "password entry must be masked")
        XCTAssertTrue(body.contains("airtonempath"), "the prompt must name the requested target user")
        XCTAssertTrue(body.contains("password is not saved"), "the feature must save permission, never the password")
        XCTAssertTrue(body.contains("text returned of result"), "sudo must receive only the entered answer")
    }

    func test_privilegedSignalArguments_targetsOnlyTheFixedHelperOperation() throws {
        let plan = try XCTUnwrap(
            RunAsUserProcessBootstrap.privilegedSignalArguments(uid: 502, signal: SIGKILL, pids: [4242, 4243])
        )
        XCTAssertEqual(plan, ["signal", "--uid", "502", "--signal", "9", "--pid", "4242", "--pid", "4243"],
                       "teardown must use the one installed helper and never show another password prompt")
    }

    func test_privilegedSignalArguments_rejectsInvalidInputsAndDropsInvalidPids() {
        XCTAssertNil(RunAsUserProcessBootstrap.privilegedSignalArguments(uid: 502, signal: SIGKILL, pids: []),
                     "nothing to signal must not invoke a privileged command")
        let plan = RunAsUserProcessBootstrap.privilegedSignalArguments(uid: 502, signal: SIGTERM, pids: [0, -1, 77])
        XCTAssertEqual(plan, ["signal", "--uid", "502", "--signal", "15", "--pid", "77"],
                       "must never signal pid 0 or a negative pid")
        XCTAssertNil(RunAsUserProcessBootstrap.privilegedSignalArguments(uid: 502, signal: SIGINT, pids: [77]),
                     "the helper signal surface is limited to teardown TERM and KILL")
    }

    func test_materializeAskpass_writesPrivateExecutableScript() throws {
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
