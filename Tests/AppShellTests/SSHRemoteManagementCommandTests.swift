import XCTest
@testable import AppShell
@testable import CoreModel

// Tests for SSHRemoteManagementCommand pure command builders.
// All classes are non-MainActor because SSHRemoteManagementCommand is a pure
// non-MainActor enum. No surface or router is needed.
//
// WHY these tests matter: the shell commands are sent verbatim to the remote
// host's POSIX sh. A missing quote, wrong flag order, or wrong operator
// (e.g. using rm without --) would silently corrupt or delete remote files.
// The tests pin the exact argv shape so regressions are caught before any
// live SSH session is needed.

final class SSHRemoteManagementShellQuoteTests: XCTestCase {

    // WHY: a plain ASCII path with no special characters must be wrapped in
    // single-quotes unchanged. If quoting alters a simple path the command
    // will fail to find the file.
    func testPlainPathIsWrappedInSingleQuotes() {
        let q = SSHRemoteManagementCommand.shellQuote("/srv/app/deploy")
        XCTAssertEqual(q, "'/srv/app/deploy'")
    }

    // WHY: paths with spaces are common (home directories on macOS remote hosts,
    // project names). Without quoting, the shell splits on whitespace and each
    // token is treated as a separate argument, breaking the command entirely.
    func testPathWithSpacesIsQuotedSafely() {
        let q = SSHRemoteManagementCommand.shellQuote("/home/user/my project/data")
        XCTAssertEqual(q, "'/home/user/my project/data'")
        // Verify no unquoted space reaches the shell
        XCTAssertFalse(q.contains("\" \""), "space must be inside single-quotes")
    }

    // WHY: a literal single-quote in a path (uncommon but valid on Linux) must
    // be escaped as '\'' (end-quote, literal-apostrophe, re-open-quote).
    // Without this, the shell misparses the command and may truncate or mangle
    // the path.
    func testSingleQuoteInPathIsEscaped() {
        let q = SSHRemoteManagementCommand.shellQuote("/tmp/it's here")
        XCTAssertEqual(q, "'/tmp/it'\\''s here'")
    }

    // WHY: dollar-sign, backtick, and exclamation can trigger variable
    // expansion, command substitution, or history expansion in some shells.
    // Single-quoting suppresses ALL of these, so the path reaches rm/mv/mkdir
    // verbatim. A regression to double-quoting would break this invariant.
    func testSpecialShellCharsAreNeutralizedBySingleQuoting() {
        let path = "/tmp/$HOME/`whoami`/!danger"
        let q = SSHRemoteManagementCommand.shellQuote(path)
        // Inside single quotes, no expansion occurs; the full original string
        // must appear literally between the outer quotes.
        XCTAssertTrue(q.hasPrefix("'"))
        XCTAssertTrue(q.hasSuffix("'"))
        // The content between outer quotes must contain the raw special chars
        let inner = String(q.dropFirst().dropLast())
        XCTAssertTrue(inner.contains("$HOME"))
        XCTAssertTrue(inner.contains("`whoami`"))
    }
}

final class SSHRemoteManagementMkdirTests: XCTestCase {

    private func profile(
        destination: String = "user@host.example",
        port: Int? = nil,
        identityFile: String? = nil,
        options: [String] = []
    ) -> SSHHostProfile {
        SSHHostProfile(label: "h", destination: destination, port: port,
                       identityFile: identityFile, options: options)
    }

    // WHY: mkdir -p must be the remote shell command so intermediate directories
    // are created atomically. A plain `mkdir` without -p fails if any ancestor
    // is missing, forcing the user to re-run for each level. Pinning "-p" catches
    // a flag regression.
    func testMkdirUsesRecursiveFlag() {
        let args = SSHRemoteManagementCommand.mkdirArguments(
            profile: profile(), path: "/srv/new/dir")
        // The last argv element is the shell command passed to "sh -c"; it must
        // include "mkdir -p".
        let cmd = args.last ?? ""
        XCTAssertTrue(cmd.contains("mkdir -p"), "recursive mkdir flag missing")
    }

    // WHY: the path passed to mkdir must be single-quoted so spaces and special
    // chars survive the remote shell. A bare path would be word-split on the
    // remote side.
    func testMkdirQuotesPathWithSpaces() {
        let args = SSHRemoteManagementCommand.mkdirArguments(
            profile: profile(), path: "/home/user/my folder")
        let cmd = args.last ?? ""
        XCTAssertTrue(cmd.contains("'/home/user/my folder'"),
                      "path with spaces must be single-quoted in remote command")
    }

    // WHY: SSH is invoked via "sh -c" for the management commands so the shell
    // interprets the quoted path. The argv must end with ["sh", "-c", <cmd>].
    func testMkdirArgvEndsWithShDashC() {
        let args = SSHRemoteManagementCommand.mkdirArguments(
            profile: profile(), path: "/tmp/x")
        XCTAssertGreaterThanOrEqual(args.count, 3)
        let n = args.count
        XCTAssertEqual(args[n - 3], "sh")
        XCTAssertEqual(args[n - 2], "-c")
    }

    // WHY: port and identity options must be forwarded so management commands
    // work on non-default-port / key-authenticated hosts just like transfers do.
    func testMkdirForwardsPortAndIdentity() {
        let args = SSHRemoteManagementCommand.mkdirArguments(
            profile: profile(port: 2222, identityFile: "/home/k/.ssh/id_ed25519"),
            path: "/tmp/t")
        XCTAssertTrue(args.contains("-p"), "ssh port flag -p missing")
        let pIdx = args.firstIndex(of: "-p")!
        XCTAssertEqual(args[pIdx + 1], "2222")
        XCTAssertTrue(args.contains("-i"), "identity flag -i missing")
        let iIdx = args.firstIndex(of: "-i")!
        XCTAssertEqual(args[iIdx + 1], "/home/k/.ssh/id_ed25519")
    }
}

final class SSHRemoteManagementRenameTests: XCTestCase {

    private func profile(destination: String = "u@host") -> SSHHostProfile {
        SSHHostProfile(label: "h", destination: destination)
    }

    // WHY: rename must use `mv -- 'SRC' 'DST'`. The `--` sentinel ensures paths
    // starting with `-` are not treated as flags. Without it, a file named
    // `-rf` would be interpreted as flags by mv, causing data loss.
    func testRenameUsesMoveDashDash() {
        let args = SSHRemoteManagementCommand.renameArguments(
            profile: profile(), from: "/a/old.txt", to: "/a/new.txt")
        let cmd = args.last ?? ""
        XCTAssertTrue(cmd.hasPrefix("mv -- "),
                      "rename must start with 'mv -- ' to guard against flag-like names")
    }

    // WHY: source must come before destination in the mv command; swapping them
    // would overwrite the source path with the destination (often absent), which
    // means silent data loss.
    func testRenameSourceBeforeDestination() {
        let args = SSHRemoteManagementCommand.renameArguments(
            profile: profile(), from: "/srv/a", to: "/srv/b")
        let cmd = args.last ?? ""
        let srcQuoted = SSHRemoteManagementCommand.shellQuote("/srv/a")
        let dstQuoted = SSHRemoteManagementCommand.shellQuote("/srv/b")
        let srcPos = cmd.range(of: srcQuoted)!.lowerBound
        let dstPos = cmd.range(of: dstQuoted)!.lowerBound
        XCTAssertLessThan(srcPos, dstPos,
                          "source path must appear before destination in mv command")
    }

    // WHY: both paths must be quoted; a space in either would split the argument
    // list and cause mv to receive wrong path counts.
    func testRenameQuotesBothPaths() {
        let args = SSHRemoteManagementCommand.renameArguments(
            profile: profile(), from: "/a/my file", to: "/b/new file")
        let cmd = args.last ?? ""
        XCTAssertTrue(cmd.contains("'/a/my file'"))
        XCTAssertTrue(cmd.contains("'/b/new file'"))
    }

    // WHY: argv must close with ["sh", "-c", <cmd>] -- same contract as mkdir.
    func testRenameArgvEndsWithShDashC() {
        let args = SSHRemoteManagementCommand.renameArguments(
            profile: profile(), from: "/a", to: "/b")
        let n = args.count
        XCTAssertGreaterThanOrEqual(n, 3)
        XCTAssertEqual(args[n - 3], "sh")
        XCTAssertEqual(args[n - 2], "-c")
    }
}

final class SSHRemoteManagementDeleteTests: XCTestCase {

    private func profile(destination: String = "u@host") -> SSHHostProfile {
        SSHHostProfile(label: "h", destination: destination)
    }

    // WHY: file deletion must use `rm -f -- 'PATH'`. The `-f` prevents rm from
    // prompting and returning non-zero on a missing target; `--` guards against
    // paths starting with `-`. Without `-f` the command fails silently on some
    // POSIX systems when the file is already gone.
    func testDeleteFileUsesRmForceDashDash() {
        let args = SSHRemoteManagementCommand.deleteArguments(
            profile: profile(), path: "/tmp/file.log", isDirectory: false)
        let cmd = args.last ?? ""
        XCTAssertTrue(cmd.hasPrefix("rm -f -- "),
                      "file delete must use 'rm -f -- ' (force, end-of-flags sentinel)")
        XCTAssertFalse(cmd.contains("-rf"), "file delete must NOT use -r")
    }

    // WHY: directory deletion needs `rm -rf -- 'PATH'` because rm without -r
    // fails on non-empty directories, leaving the user with a partial removal.
    // The `-f` suppresses errors on already-absent children. This test pins
    // the distinction so a copy-paste error (using file delete for a dir) is caught.
    func testDeleteDirectoryUsesRmRecursiveForceDashDash() {
        let args = SSHRemoteManagementCommand.deleteArguments(
            profile: profile(), path: "/srv/old_deploy", isDirectory: true)
        let cmd = args.last ?? ""
        XCTAssertTrue(cmd.hasPrefix("rm -rf -- "),
                      "directory delete must use 'rm -rf -- '")
    }

    // WHY: the path must be quoted to survive spaces and special chars.
    func testDeleteQuotesPath() {
        let args = SSHRemoteManagementCommand.deleteArguments(
            profile: profile(), path: "/tmp/my logs/app.log", isDirectory: false)
        let cmd = args.last ?? ""
        XCTAssertTrue(cmd.contains("'/tmp/my logs/app.log'"),
                      "path with space must be single-quoted in delete command")
    }

    // WHY: argv must close with ["sh", "-c", <cmd>] -- same contract as mkdir/rename.
    func testDeleteArgvEndsWithShDashC() {
        let args = SSHRemoteManagementCommand.deleteArguments(
            profile: profile(), path: "/x", isDirectory: false)
        let n = args.count
        XCTAssertGreaterThanOrEqual(n, 3)
        XCTAssertEqual(args[n - 3], "sh")
        XCTAssertEqual(args[n - 2], "-c")
    }

    // WHY: destination must be present in the command to ensure the right target
    // is addressed. Missing destination => rm runs locally on the router host.
    func testDeleteIncludesDestinationInArgv() {
        let args = SSHRemoteManagementCommand.deleteArguments(
            profile: profile(destination: "deploy@prod.example.com"),
            path: "/var/log/app.log",
            isDirectory: false)
        XCTAssertTrue(args.contains("deploy@prod.example.com"),
                      "remote destination must appear in ssh argv")
    }
}
