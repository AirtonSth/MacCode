import Darwin
import AgentRuntime
import Foundation

/// Runs the real command behind a leftover symlink to this binary.
///
/// Older builds installed PATH wrappers (`rg`, `node`, `env`, …) and a `distill`
/// link that point here. The managed bin stays first on `PATH`, so any wrapper
/// that survived cleanup must still run the real command, inheriting every
/// stream so a long-running child (Codex app-server via `#!/usr/bin/env node`)
/// is never buffered.
enum PassthroughExec {
    static func runInheritingStreams(command: String, args: [String]) -> Int32 {
        let env = ProcessInfo.processInfo.environment
        guard let realExe = resolveRealExecutable(command: command, environment: env) else {
            FileHandle.standardError.write(
                Data("\((command as NSString).lastPathComponent): command not found\n".utf8)
            )
            return 127
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: realExe)
        process.arguments = args
        // Leave standardInput/Output/Error unset so the child inherits ours verbatim.
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(
                Data("\((realExe as NSString).lastPathComponent): \(error.localizedDescription)\n".utf8)
            )
            return 126
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - real-binary resolution

    private static func resolveRealExecutable(command: String, environment: [String: String]) -> String? {
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let managedBin = (CommandLine.arguments.first.map { ($0 as NSString).deletingLastPathComponent } ?? "")
        let selfReal = canonicalPath(currentExecutablePath() ?? CommandLine.arguments.first ?? "")
        return ProviderProxyPolicy.resolveRealExecutable(
            command: command,
            pathEntries: pathEntries,
            managedBinDirectory: managedBin,
            isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) },
            resolvesToSelf: { candidate in
                guard let selfReal else { return false }
                return canonicalPath(candidate) == selfReal
            }
        )
    }

    private static func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
