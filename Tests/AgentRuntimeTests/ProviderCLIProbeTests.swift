import XCTest
import CoreModel
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
}
