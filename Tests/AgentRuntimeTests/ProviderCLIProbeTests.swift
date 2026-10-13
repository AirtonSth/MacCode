import XCTest
import CoreModel
import Darwin
@testable import AgentRuntime

final class ProviderCLIProbeTests: XCTestCase {
    func test_versionReadsFirstLineFromExecutable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("codex")
        try "#!/bin/sh\nprintf 'codex 0.130.0\\nUpdate available: codex 0.131.0\\n'\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let status = ProviderCLIProbe.versionStatus(binaryPath: binary.path)

        XCTAssertEqual(status.version, "codex 0.130.0",
                       "provider snapshots must report the actual CLI version instead of leaving runtime capability state static")
        XCTAssertEqual(status.updateState, "update_available")
        XCTAssertEqual(status.advisory, "Update available: codex 0.131.0",
                       "provider snapshots must surface CLI update advisories before long-running Agent App work starts on a stale provider")
    }

    func test_codexAuthProbeReadsLoginStatusAndEnvironment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("codex")
        try """
        #!/bin/sh
        if [ "$1" = "login" ] && [ "$2" = "status" ] && [ "$CODEX_HOME" = "\(dir.path)" ]; then
          printf 'Logged in using ChatGPT\\n'
          exit 0
        fi
        exit 1
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let authenticated = ProviderCLIProbe.authenticated(
            provider: .codex,
            binaryPath: binary.path,
            environment: ["CODEX_HOME": dir.path]
        )

        XCTAssertEqual(authenticated, true,
                       "provider snapshots must probe Codex auth with instance-scoped CODEX_HOME so personal/work accounts do not collapse into one status")
    }

    func test_distillAuthStatusReadsConnectedAccounts_becauseSchedulesMustNotRejectASignedInDistill() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let distillHome = home.appendingPathComponent(".distill", isDirectory: true)
        try FileManager.default.createDirectory(at: distillHome, withIntermediateDirectories: true)
        try #"{"access_token":"x","email":"a@b.c"}"#.write(
            to: distillHome.appendingPathComponent("claude-auth.json"), atomically: true, encoding: .utf8)
        let authenticated = ProviderCLIProbe.authStatus(
            provider: .distill, binaryPath: "/usr/bin/true", environment: ["DISTILL_HOME": distillHome.path], runAsUser: nil)
        XCTAssertEqual(authenticated.authenticated, true)
        XCTAssertEqual(authenticated.accountLabel, "a@b.c")

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(ProviderCLIProbe.authStatus(
            provider: .distill, binaryPath: "/usr/bin/true", environment: ["DISTILL_HOME": empty.path], runAsUser: nil).authenticated, false)
    }

    func test_claudeAuthProbeReadsJsonStatus() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
          printf '{"loggedIn":true,"account":{"email":"work@example.com"},"authMethod":"oauth"}\\n'
          exit 0
        fi
        exit 1
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let status = ProviderCLIProbe.authStatus(provider: .claude, binaryPath: binary.path)

        XCTAssertEqual(status.authenticated, true,
                       "provider snapshots must parse Claude auth JSON instead of leaving auth state unknown until a run fails")
        XCTAssertEqual(status.accountLabel, "work@example.com",
                       "provider snapshots must expose account labels so same-provider personal/work instances can be distinguished before a long run starts")
        XCTAssertEqual(status.accountAuthMethod, "oauth",
                       "provider snapshots must preserve richer auth metadata so status cards can show how the selected account is authenticated before long runs")
    }

    func test_authProbeReadsTextAuthMethod() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("codex")
        try """
        #!/bin/sh
        if [ "$1" = "login" ] && [ "$2" = "status" ]; then
          printf 'Logged in using ChatGPT\\n'
          exit 0
        fi
        exit 1
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let status = ProviderCLIProbe.authStatus(provider: .codex, binaryPath: binary.path)

        XCTAssertEqual(status.authenticated, true)
        XCTAssertEqual(status.accountAuthMethod, "ChatGPT",
                       "text auth probes must retain auth method details instead of collapsing every account to a boolean")
    }

    func test_authProbeDoesNotReportUnauthenticatedWhenProviderWrapperCannotFindRuntime() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("codex")
        try """
        #!/bin/sh
        printf 'env: node: No such file or directory\\n' >&2
        exit 127
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let status = ProviderCLIProbe.authStatus(provider: .codex, binaryPath: binary.path)

        XCTAssertNil(status.authenticated,
                     "a missing provider runtime from a minimal macOS GUI PATH is an environment failure, not lost Codex authentication")
    }

    func test_slashCommandProbeIgnoresHelpSubcommands() throws {
        // WHY: `--help` lists CLI *subcommands* (exec, install, setup-token, ...)
        // plus wrapped description fragments ("server" below) — none of which are
        // interactive slash commands. Deriving suggestions from it filled the
        // composer autocomplete with bogus "/exec", "/Only", "/dialog" entries,
        // so the probe must contribute nothing and leave the curated per-provider
        // defaults as the only slash-command source.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("codex")
        try """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          cat <<'EOF'
        Usage: codex [OPTIONS] <COMMAND>

        Commands:
          exec      Run Codex non-interactively
          review    Run a code review
          app-server [experimental] Run the app
                     server behind a local socket
          help      Print help

        Options:
          -h, --help Print help
        EOF
          exit 0
        fi
        exit 1
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let commands = ProviderCLIProbe.slashCommands(
            provider: .codex,
            binaryPath: binary.path,
            environment: ["CODEX_HOME": dir.path]
        )

        XCTAssertEqual(commands, [],
                       "CLI subcommands and wrapped help fragments must never surface as composer slash-command suggestions")
    }

    func test_updateRunsProviderUpdateWithEnvironment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        if [ "$1" = "update" ] && [ "$HOME" = "\(dir.path)" ]; then
          printf 'updated claude\\n'
          exit 0
        fi
        printf 'bad update env\\n' >&2
        exit 7
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let result = ProviderCLIProbe.update(provider: .claude, binaryPath: binary.path, environment: ["HOME": dir.path])

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "updated claude\n",
                       "provider update actions must execute the provider-native update command with the selected instance environment")
    }

    /// The automatic Distill updater decides from this output alone, so the
    /// probe must ask the check (never plain `update`, which installs), keep
    /// stderr out of the JSON, report the exit status, and give nothing back
    /// for a check that hangs instead of holding the updater.
    func test_distillUpdateCheckRunsTheCheckOnlyAndReturnsItsStdoutAndStatus() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("distill")
        try """
        #!/bin/sh
        if [ "$*" = "update --check --json" ] && [ "$DISTILL_HOME" = "\(dir.path)" ]; then
          if [ "$RC_TEST_HANG" = "1" ]; then sleep 5; fi
          printf 'progress noise\\n' >&2
          printf '{"updateAvailable":false}\\n'
          exit 3
        fi
        printf 'installed\\n'
        exit 0
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let result = try XCTUnwrap(ProviderCLIProbe.distillUpdateCheck(
            binaryPath: binary.path, environment: ["DISTILL_HOME": dir.path]
        ))
        XCTAssertEqual(result.stdout, "{\"updateAvailable\":false}\n")
        XCTAssertEqual(result.status, 3)
        XCTAssertNil(ProviderCLIProbe.distillUpdateCheck(
            binaryPath: binary.path, environment: ["DISTILL_HOME": dir.path, "RC_TEST_HANG": "1"], timeoutSeconds: 0.2
        ))
        XCTAssertNil(ProviderCLIProbe.distillUpdateCheck(binaryPath: dir.appendingPathComponent("missing").path))
    }

    /// Distill refuses to update when started through a symlink outside its
    /// release install: the check asks nothing and `update` exits 0 without
    /// installing, so the app would stay on an old release while reporting
    /// success. Both commands must run through the install the symlink leads
    /// to; the default layout and a source build are run as they were given.
    func test_distillUpdateRunsThroughTheReleaseInstallASymlinkLeadsTo() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root", isDirectory: true)
        for sub in ["root/bin", "root/downloads", "elsewhere", "source"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data("samuelfaj/distill\n".utf8).write(to: root.appendingPathComponent(".distill-release"))
        let script = "#!/bin/sh\nprintf '%s\\n' \"$0\"\n"
        let release = root.appendingPathComponent("downloads/distill-x")
        let sourceBuild = dir.appendingPathComponent("source/distill")
        for file in [release, sourceBuild] {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let managed = root.appendingPathComponent("bin/distill")
        try fm.createSymbolicLink(atPath: managed.path, withDestinationPath: "../downloads/distill-x")
        let outside = dir.appendingPathComponent("elsewhere/distill")
        try fm.createSymbolicLink(atPath: outside.path, withDestinationPath: managed.path)

        func checked(_ path: String) -> String? {
            ProviderCLIProbe.distillUpdateCheck(binaryPath: path)?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func updated(_ path: String) -> String {
            ProviderCLIProbe.update(provider: .distill, binaryPath: path).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let inInstall = release.resolvingSymlinksInPath().path
        XCTAssertEqual(checked(outside.path), inInstall)
        XCTAssertEqual(updated(outside.path), inInstall)
        XCTAssertEqual(checked(managed.path), managed.path)
        XCTAssertEqual(updated(managed.path), managed.path)
        XCTAssertEqual(checked(sourceBuild.path), sourceBuild.path)
        XCTAssertEqual(updated(sourceBuild.path), sourceBuild.path)
    }

    func test_failingUpdatePreservesTerminalStderrDiagnosticAndVisibleTruncationNotice() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        if [ "$1" = "update" ]; then
          python3 -c "import sys; sys.stderr.write('STALE UPDATE PREFIX\\n'); sys.stderr.write('x' * 200000); sys.stderr.write('\\nFINAL UPDATE STDERR DIAGNOSTIC\\n')"
          exit 23
        fi
        exit 1
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let result = ProviderCLIProbe.update(provider: .claude, binaryPath: binary.path, timeoutSeconds: 5.0)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, 23)
        XCTAssertTrue(result.stderr.contains("FINAL UPDATE STDERR DIAGNOSTIC"),
                      "a failed update must preserve the provider's terminal stderr diagnostic, not just the beginning of a noisy stream")
        XCTAssertTrue(result.stderr.contains("provider update output truncated"),
                      "bounded update output must disclose that earlier bytes were discarded")
        XCTAssertFalse(result.stderr.contains("STALE UPDATE PREFIX"),
                       "suffix retention must discard stale prefix bytes while keeping the terminal failure marker")
    }

    func test_probeReturnsWhenExitedWrapperLeavesAChildHoldingStdoutOpen() throws {
        // WHY: provider wrappers can fork a long-lived child and exit. Waiting
        // for pipe EOF after the root is gone made provider snapshots and the
        // full test suite hang forever despite the probe timeout.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let childPIDFile = dir.appendingPathComponent("child-pid")
        let binary = dir.appendingPathComponent("codex")
        try """
        #!/bin/sh
        sleep 30 &
        printf '%s\n' "$!" > "$CHILD_PID_FILE"
        printf 'codex 0.130.0\n'
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let startedAt = Date()
        let version = ProviderCLIProbe.version(
            binaryPath: binary.path,
            environment: ["CHILD_PID_FILE": childPIDFile.path],
            timeoutSeconds: 1
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        let childPID = (try? String(contentsOf: childPIDFile, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let childPID { _ = Darwin.kill(childPID, SIGKILL) }
        XCTAssertEqual(version, "codex 0.130.0")
        XCTAssertNotNil(childPID, "the fixture must prove a descendant inherited the pipe")
        XCTAssertLessThan(
            elapsed,
            0.9,
            "a completed probe must not wait for EOF from a long-lived descendant"
        )
    }
}
