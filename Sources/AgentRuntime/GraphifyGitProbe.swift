import Foundation
import CoreModel

/// Thin git probes for Graphify root resolution. Fail-open: returns nil on error.
public enum GraphifyGitProbe {
    public struct RepoIdentity: Sendable, Equatable {
        public let toplevel: String
        public let commonDir: String

        public var checkout: GraphifyCheckout {
            GraphifyCheckout(
                key: GraphifyRepoKey(commonDir: commonDir),
                displayRoot: toplevel
            )
        }
    }

    /// Returns identity when `path` is inside a git work tree.
    /// Accepts file or directory paths (files resolve via their parent directory).
    public static func identity(at path: String) -> RepoIdentity? {
        let absURL = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absURL.path, isDirectory: &isDir) else { return nil }
        let cwd = isDir.boolValue ? absURL.path : absURL.deletingLastPathComponent().path
        let top = revParse(["--show-toplevel"], cwd: cwd)
        let common = revParse(["--git-common-dir"], cwd: cwd)
        guard let top, let common, !top.isEmpty, !common.isEmpty else { return nil }
        let commonAbs: String
        if common.hasPrefix("/") {
            commonAbs = URL(fileURLWithPath: common).standardizedFileURL.path
        } else {
            commonAbs = URL(fileURLWithPath: top).appendingPathComponent(common).standardizedFileURL.path
        }
        return RepoIdentity(toplevel: top, commonDir: commonAbs)
    }

    public static func isInsideWorkTree(_ path: String) -> Bool {
        identity(at: path) != nil
    }

    /// Discover product checkouts under a multi-repo container (maxDepth 2).
    /// Skips node_modules, dist, .next, and treats `_worktrees` as non-product
    /// (worktrees still resolve via `identity(at:)` when cwd points inside them).
    public static func discoverChildRepos(
        containerCwd: String,
        maxDepth: Int = 2
    ) -> [GraphifyCheckout] {
        let root = URL(fileURLWithPath: containerCwd).standardizedFileURL
        var found: [GraphifyCheckout] = []
        var seenKeys = Set<GraphifyRepoKey>()
        let skipNames: Set<String> = [
            "node_modules", ".git", "dist", ".next", "build", "vendor",
            "__pycache__", ".venv", "coverage", "graphify-out", "_worktrees"
        ]

        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries {
                let name = entry.lastPathComponent
                if skipNames.contains(name) { continue }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                if let id = identity(at: entry.path) {
                    let checkout = id.checkout
                    if seenKeys.insert(checkout.key).inserted {
                        found.append(checkout)
                    }
                    // Do not descend into a repo for "product children".
                    continue
                }
                walk(entry, depth: depth + 1)
            }
        }

        walk(root, depth: 1)
        return found.sorted { $0.displayRoot < $1.displayRoot }
    }

    private static func revParse(_ args: [String], cwd: String) -> String? {
        let result = runGit(["rev-parse"] + args, cwd: cwd)
        guard result.exit == 0 else { return nil }
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    private struct ProcessResult {
        let exit: Int32
        let stdout: String
    }

    private static func runGit(_ args: [String], cwd: String) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe()
        p.standardOutput = out
        // stderr was read and discarded; an undrained second pipe can deadlock the stdout read.
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            return ProcessResult(exit: -1, stdout: "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ProcessResult(
            exit: p.terminationStatus,
            stdout: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
