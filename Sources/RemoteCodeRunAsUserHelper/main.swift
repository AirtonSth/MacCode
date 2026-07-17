import Foundation
import Darwin

/// Privileged trampoline: setuid to a target macOS user, then exec the provider.
/// Stdio is inherited so RemoteCode's Foundation Process pipes keep working.
///
/// Security model (MVP):
/// - Must start with euid 0 (setuid-root install or LaunchDaemon).
/// - Only absolute allowlisted provider basenames.
/// - Never invokes a shell.
/// - Rebuilds a minimal environment after setuid.
@main
struct RemoteCodeRunAsUserHelperMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            try run(args: args)
        } catch {
            fputs("RemoteCodeRunAsUserHelper: \(error)\n", stderr)
            exit(EX_USAGE)
        }
    }

    static func run(args: [String]) throws {
        guard let first = args.first else {
            throw HelperError.usage("missing command (expected: exec)")
        }
        switch first {
        case "exec":
            try execCommand(Array(args.dropFirst()))
        case "version":
            fputs("RemoteCodeRunAsUserHelper 1\n", stdout)
            exit(0)
        default:
            throw HelperError.usage("unknown command \(first)")
        }
    }

    static func execCommand(_ args: [String]) throws {
        var uid: uid_t?
        var gid: gid_t?
        var home: String?
        var user: String?
        var cwd: String?
        var rest: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" {
                rest = Array(args.suffix(from: i + 1))
                break
            }
            guard a.hasPrefix("--") else {
                throw HelperError.usage("unexpected argument \(a)")
            }
            let key = a
            i += 1
            guard i < args.count else { throw HelperError.usage("missing value for \(key)") }
            let value = args[i]
            switch key {
            case "--uid":
                guard let v = UInt32(value) else { throw HelperError.usage("bad uid") }
                uid = v
            case "--gid":
                guard let v = UInt32(value) else { throw HelperError.usage("bad gid") }
                gid = v
            case "--home":
                home = value
            case "--user":
                user = value
            case "--cwd":
                cwd = value
            default:
                throw HelperError.usage("unknown flag \(key)")
            }
            i += 1
        }

        guard let uid, let gid, let home, let user, let cwd else {
            throw HelperError.usage("exec requires --uid --gid --home --user --cwd -- binary ...")
        }
        guard !rest.isEmpty else { throw HelperError.usage("missing binary after --") }
        let binary = rest[0]
        let binaryArgs = Array(rest.dropFirst())

        try validateTarget(uid: uid, gid: gid, user: user, home: home)
        try validateBinary(binary)

        // Privilege check: must be root (setuid bit or launched by launchd as root).
        if geteuid() != 0 {
            throw HelperError.notRoot("effective uid is \(geteuid()); install helper setuid-root or as LaunchDaemon")
        }

        // Change directory before dropping privileges when possible.
        if chdir(cwd) != 0 {
            // Retry after setuid if cwd is only accessible as target user.
        }

        // Darwin headers type the group argument as Int32 on Apple platforms.
        if initgroups(user, Int32(bitPattern: gid)) != 0 {
            throw HelperError.posix("initgroups failed errno=\(errno)")
        }
        if setgid(gid) != 0 {
            throw HelperError.posix("setgid failed errno=\(errno)")
        }
        if setuid(uid) != 0 {
            throw HelperError.posix("setuid failed errno=\(errno)")
        }
        if getuid() != uid || geteuid() != uid {
            throw HelperError.posix("uid not fully dropped (uid=\(getuid()) euid=\(geteuid()))")
        }

        if chdir(cwd) != 0 {
            throw HelperError.posix("chdir(\(cwd)) failed errno=\(errno)")
        }

        var env: [String] = [
            "HOME=\(home)",
            "USER=\(user)",
            "LOGNAME=\(user)",
            "PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM=xterm-256color",
            "LANG=en_US.UTF-8",
            "LC_ALL=en_US.UTF-8",
            "TMPDIR=\(home)/Library/Caches/TemporaryItems",
            "RC_RUN_AS_USER=\(user)"
        ]
        // Preserve a small allowlist from the parent when present (no secrets).
        for key in ["SSH_AUTH_SOCK", "COLORTERM", "TERM_PROGRAM"] {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
                env.append("\(key)=\(value)")
            }
        }

        let cBinary = strdup(binary)
        defer { free(cBinary) }
        var cArgs: [UnsafeMutablePointer<CChar>?] = [cBinary]
        for arg in binaryArgs {
            cArgs.append(strdup(arg))
        }
        cArgs.append(nil)
        defer {
            for ptr in cArgs.dropFirst().dropLast() {
                free(ptr)
            }
        }

        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) }
        cEnv.append(nil)
        defer {
            for ptr in cEnv.dropLast() { free(ptr) }
        }

        execve(binary, &cArgs, &cEnv)
        throw HelperError.posix("execve(\(binary)) failed errno=\(errno)")
    }

    static func validateTarget(uid: uid_t, gid: gid_t, user: String, home: String) throws {
        if uid < 501 || uid == 0 {
            throw HelperError.invalidTarget("uid \(uid) not allowed")
        }
        if user.isEmpty || user == "root" || user.hasPrefix("_") {
            throw HelperError.invalidTarget("user \(user) not allowed")
        }
        if !home.hasPrefix("/Users/") {
            throw HelperError.invalidTarget("home must be under /Users")
        }
        guard let pw = getpwuid(uid) else {
            throw HelperError.invalidTarget("uid \(uid) not found")
        }
        let name = String(cString: pw.pointee.pw_name)
        guard name == user else {
            throw HelperError.invalidTarget("uid \(uid) is \(name), not \(user)")
        }
        if pw.pointee.pw_gid != gid {
            // Primary gid mismatch — still allow if supplementary groups cover it,
            // but require the account's real primary for setgid consistency.
            throw HelperError.invalidTarget("gid mismatch for \(user)")
        }
    }

    static func validateBinary(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw HelperError.invalidBinary("path must be absolute")
        }
        if path.contains("..") {
            throw HelperError.invalidBinary("path must not contain ..")
        }
        let base = URL(fileURLWithPath: path).lastPathComponent
        let allow: Set<String> = ["codex", "claude", "grok", "node", "npm"]
        guard allow.contains(base) else {
            throw HelperError.invalidBinary("basename \(base) not allowlisted")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw HelperError.invalidBinary("missing executable \(path)")
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw HelperError.invalidBinary("not executable \(path)")
        }
    }
}

enum HelperError: Error, CustomStringConvertible {
    case usage(String)
    case notRoot(String)
    case invalidTarget(String)
    case invalidBinary(String)
    case posix(String)

    var description: String {
        switch self {
        case .usage(let s), .notRoot(let s), .invalidTarget(let s), .invalidBinary(let s), .posix(let s):
            return s
        }
    }
}
