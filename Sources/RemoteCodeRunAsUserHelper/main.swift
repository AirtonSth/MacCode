import Foundation
import Darwin

/// Privileged trampoline installed once at
/// `/Library/PrivilegedHelperTools/io.remotecode.RunAsUserHelper`.
///
/// The helper has three deliberately narrow operations:
/// - `exec` drops to a validated interactive user before running an allowlisted
///   provider binary.
/// - `pmset` stays root for the single clamshell-sleep setting used by Insomnia.
/// - `signal` signals only already-owned target-user provider PIDs.
///
/// It never accepts a shell command and never stores the invoking password.
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
            throw HelperError.usage("missing command (expected: exec, pmset, signal, or version)")
        }
        switch first {
        case "exec":
            try execCommand(Array(args.dropFirst()))
        case "pmset":
            try pmSetCommand(Array(args.dropFirst()))
        case "watch":
            try watchCommand(Array(args.dropFirst()))
        case "signal":
            try signalCommand(Array(args.dropFirst()))
        case "version":
            fputs("RemoteCodeRunAsUserHelper 4\n", stdout)
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
        try requireRoot()

        // Change directory before dropping privileges when possible.
        _ = chdir(cwd)
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
        guard chdir(cwd) == 0 else {
            throw HelperError.posix("chdir(\(cwd)) failed errno=\(errno)")
        }

        var env: [String: String] = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": "\(home)/Library/Caches/TemporaryItems",
            "RC_RUN_AS_USER": user
        ]

        // Keep the provider receipt and explicit controls, but never forward
        // arbitrary login-shell values, loader controls, or askpass paths.
        let parentEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in parentEnvironment where shouldPreserve(key: key) && !value.isEmpty {
            env[key] = value
        }

        exec(binary: binary, arguments: binaryArgs, environment: env.map { "\($0.key)=\($0.value)" })
    }

    static func pmSetCommand(_ args: [String]) throws {
        try requireRoot()

        var disabled: Bool?
        var watchPID: pid_t?
        var stopFile: String?
        var sessionDirectory: String?
        var i = 0
        while i < args.count {
            let key = args[i]
            i += 1
            guard i < args.count else { throw HelperError.usage("missing value for \(key)") }
            let value = args[i]
            i += 1
            switch key {
            case "--disablesleep":
                guard value == "0" || value == "1" else {
                    throw HelperError.usage("--disablesleep must be 0 or 1")
                }
                disabled = value == "1"
            case "--watch-pid":
                guard let pid = Int32(value), pid > 0 else {
                    throw HelperError.usage("--watch-pid must be positive")
                }
                watchPID = pid
            case "--stop-file":
                stopFile = value
            case "--session-directory":
                sessionDirectory = value
            default:
                throw HelperError.usage("unknown pmset flag \(key)")
            }
        }

        guard let disabled else { throw HelperError.usage("pmset requires --disablesleep 0|1") }
        let watcherRequested = watchPID != nil || stopFile != nil || sessionDirectory != nil
        if disabled {
            guard watcherRequested, let watchPID, let stopFile, let sessionDirectory else {
                throw HelperError.usage("enabling pmset requires a watcher")
            }
            try validateWatcher(pid: watchPID, stopFile: stopFile, sessionDirectory: sessionDirectory)
        } else if watcherRequested {
            throw HelperError.usage("disabling pmset cannot include a watcher")
        }

        let status = runPMSet(disabled: disabled)
        guard status == 0 else { throw HelperError.posix("pmset exited with status \(status)") }
        if disabled, let watchPID, let stopFile, let sessionDirectory {
            try spawnWatcher(pid: watchPID, stopFile: stopFile, sessionDirectory: sessionDirectory)
        }
    }

    static func signalCommand(_ args: [String]) throws {
        try requireRoot()

        var uid: uid_t?
        var signalNumber: Int32?
        var pids: [pid_t] = []
        var i = 0
        while i < args.count {
            let key = args[i]
            i += 1
            guard i < args.count else { throw HelperError.usage("missing value for \(key)") }
            let value = args[i]
            i += 1
            switch key {
            case "--uid":
                guard uid == nil, let value = UInt32(value) else {
                    throw HelperError.usage("--uid must be specified once")
                }
                uid = value
            case "--signal":
                guard signalNumber == nil, let value = Int32(value) else {
                    throw HelperError.usage("--signal must be specified once")
                }
                signalNumber = value
            case "--pid":
                guard let value = Int32(value), value > 0 else {
                    throw HelperError.usage("--pid must be positive")
                }
                pids.append(value)
            default:
                throw HelperError.usage("unknown signal flag \(key)")
            }
        }

        guard let uid, let signalNumber, !pids.isEmpty else {
            throw HelperError.usage("signal requires --uid --signal and at least one --pid")
        }
        guard signalNumber == SIGTERM || signalNumber == SIGKILL else {
            throw HelperError.usage("signal is limited to SIGTERM or SIGKILL")
        }
        guard uid >= 501, uid != 0, let pw = getpwuid(uid) else {
            throw HelperError.invalidTarget("uid \(uid) is not an interactive user")
        }
        let user = String(cString: pw.pointee.pw_name)
        guard user != "root", !user.hasPrefix("_") else {
            throw HelperError.invalidTarget("uid \(uid) is not an interactive user")
        }

        // Validate every PID before signalling any of them. The root helper
        // must not become an arbitrary cross-user kill primitive.
        for pid in pids {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
                if errno == ESRCH { continue }
                throw HelperError.invalidTarget("could not inspect pid \(pid)")
            }
            guard info.pbi_uid == uid else {
                throw HelperError.invalidTarget("pid \(pid) is not owned by \(user)")
            }
        }

        for pid in pids {
            guard kill(pid, signalNumber) == 0 || errno == ESRCH else {
                throw HelperError.posix("kill(\(pid), \(signalNumber)) failed errno=\(errno)")
            }
        }
    }

    static func watchCommand(_ args: [String]) throws {
        try requireRoot()
        var watchPID: pid_t?
        var stopFile: String?
        var sessionDirectory: String?
        var i = 0
        while i < args.count {
            let key = args[i]
            i += 1
            guard i < args.count else { throw HelperError.usage("missing value for \(key)") }
            let value = args[i]
            i += 1
            switch key {
            case "--watch-pid":
                guard let pid = Int32(value), pid > 0 else {
                    throw HelperError.usage("--watch-pid must be positive")
                }
                watchPID = pid
            case "--stop-file":
                stopFile = value
            case "--session-directory":
                sessionDirectory = value
            default:
                throw HelperError.usage("unknown watch flag \(key)")
            }
        }
        guard let watchPID, let stopFile, let sessionDirectory else {
            throw HelperError.usage("watch requires --watch-pid --stop-file --session-directory")
        }
        try validateWatcher(pid: watchPID, stopFile: stopFile, sessionDirectory: sessionDirectory)

        let interval = timespec(tv_sec: 0, tv_nsec: 500_000_000)
        while access(stopFile, F_OK) != 0 && (kill(watchPID, 0) == 0 || errno == EPERM) {
            var remaining = interval
            _ = nanosleep(&remaining, nil)
        }
        let status = runPMSet(disabled: false)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: sessionDirectory))
        exit(status == 0 ? 0 : 1)
    }

    static func requireRoot() throws {
        guard geteuid() == 0 else {
            throw HelperError.notRoot("effective uid is \(geteuid()); install the helper setuid-root")
        }
    }

    static func runPMSet(disabled: Bool) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    static func validateWatcher(pid: pid_t, stopFile: String, sessionDirectory: String) throws {
        guard stopFile.hasPrefix("/"), sessionDirectory.hasPrefix("/"),
              !stopFile.contains(".."), !sessionDirectory.contains(".."),
              URL(fileURLWithPath: stopFile).deletingLastPathComponent().path ==
                URL(fileURLWithPath: sessionDirectory).standardizedFileURL.path,
              URL(fileURLWithPath: stopFile).lastPathComponent == "disable",
              URL(fileURLWithPath: sessionDirectory).lastPathComponent.hasPrefix("RemoteCodeInsomnia-") else {
            throw HelperError.invalidSession("watcher paths are not a RemoteCode Insomnia session")
        }
        var info = stat()
        guard lstat(sessionDirectory, &info) == 0,
              (info.st_mode & mode_t(0o170000)) == mode_t(0o040000),
              info.st_uid == getuid(),
              (info.st_mode & mode_t(0o077)) == 0 else {
            throw HelperError.invalidSession("session directory must be a private directory owned by the caller")
        }
        guard kill(pid, 0) == 0 || errno == EPERM else {
            throw HelperError.invalidSession("watch process is not alive")
        }
    }

    static func spawnWatcher(pid: pid_t, stopFile: String, sessionDirectory: String) throws {
        guard let helperPath = CommandLine.arguments.first, helperPath.hasPrefix("/") else {
            throw HelperError.posix("helper executable path is unavailable")
        }
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: helperPath)
        watcher.arguments = [
            "watch",
            "--watch-pid", "\(pid)",
            "--stop-file", stopFile,
            "--session-directory", sessionDirectory
        ]
        watcher.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        watcher.standardInput = FileHandle.nullDevice
        watcher.standardOutput = FileHandle.nullDevice
        watcher.standardError = FileHandle.nullDevice
        try watcher.run()
    }

    static func shouldPreserve(key: String) -> Bool {
        key == "PATH"
            || key == "REMOTE_CODE_AGENT_PROVIDER"
            || key == "CLAUDE_CODE_DISABLE_THINKING"
            || key == "MAX_THINKING_TOKENS"
            || key == "SSH_AUTH_SOCK"
            || key == "COLORTERM"
            || key == "TERM_PROGRAM"
            || key.hasPrefix("RC_TOKEN_SAVER_")
    }

    static func exec(binary: String, arguments: [String], environment: [String]) -> Never {
        let cBinary = strdup(binary)
        var cArgs: [UnsafeMutablePointer<CChar>?] = [cBinary]
        cArgs.append(contentsOf: arguments.map { strdup($0) })
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) }
        cEnv.append(nil)
        execve(binary, &cArgs, &cEnv)
        _exit(127)
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
        let actualHome = String(cString: pw.pointee.pw_dir)
        guard URL(fileURLWithPath: home).standardizedFileURL.path ==
                URL(fileURLWithPath: actualHome).standardizedFileURL.path else {
            throw HelperError.invalidTarget("home does not belong to \(user)")
        }
        guard pw.pointee.pw_gid == gid else {
            throw HelperError.invalidTarget("gid mismatch for \(user)")
        }
    }

    static func validateBinary(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("..") else {
            throw HelperError.invalidBinary("path must be absolute and must not contain ..")
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
    case invalidSession(String)
    case posix(String)

    var description: String {
        switch self {
        case .usage(let s), .notRoot(let s), .invalidTarget(let s), .invalidBinary(let s),
             .invalidSession(let s), .posix(let s):
            return s
        }
    }
}
