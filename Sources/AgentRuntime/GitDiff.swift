import Foundation

public enum GitFileStatus: String, Codable, Sendable, Equatable {
    case added, modified, deleted, renamed, copied, untracked, unknown
}

public struct GitFileEntry: Codable, Sendable, Equatable {
    public let path: String
    public let oldPath: String?
    public let status: GitFileStatus
    public let additions: Int
    public let deletions: Int
    public let binary: Bool

    public init(path: String, oldPath: String?, status: GitFileStatus, additions: Int, deletions: Int, binary: Bool) {
        self.path = path; self.oldPath = oldPath; self.status = status
        self.additions = additions; self.deletions = deletions; self.binary = binary
    }
}

public struct GitSummary: Codable, Sendable, Equatable {
    public let isGitRepo: Bool
    public let branch: String?
    public let dirty: Bool
    public let files: [GitFileEntry]
    public let totalAdditions: Int
    public let totalDeletions: Int

    public init(isGitRepo: Bool, branch: String?, dirty: Bool, files: [GitFileEntry], totalAdditions: Int, totalDeletions: Int) {
        self.isGitRepo = isGitRepo; self.branch = branch; self.dirty = dirty
        self.files = files; self.totalAdditions = totalAdditions; self.totalDeletions = totalDeletions
    }
}

/// Lightweight git-diff helpers. Spawns `git` directly so we never link
/// libgit. Used by the changed-files summary and the diff panel surface.
public enum GitDiff {

    public typealias FileEntry = GitFileEntry
    public typealias Summary = GitSummary

    public static func summary(in cwd: String) -> GitSummary {
        guard isGit(cwd) else {
            return GitSummary(isGitRepo: false, branch: nil, dirty: false, files: [], totalAdditions: 0, totalDeletions: 0)
        }
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Numstat over uncommitted changes (staged + unstaged combined).
        let numstat = run(["diff", "--numstat", "HEAD"], cwd: cwd).stdout
        let nameStatus = run(["diff", "--name-status", "HEAD"], cwd: cwd).stdout
        let untracked = run(["ls-files", "--others", "--exclude-standard"], cwd: cwd).stdout

        var statusMap: [String: GitFileStatus] = [:]
        var renameOldPath: [String: String] = [:]
        for line in nameStatus.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard let code = parts.first else { continue }
            if code.hasPrefix("R") {
                if parts.count >= 3 {
                    let old = parts[1]
                    let new = parts[2]
                    statusMap[new] = .renamed
                    renameOldPath[new] = old
                }
            } else if code.hasPrefix("C") {
                if parts.count >= 3 {
                    let new = parts[2]
                    statusMap[new] = .copied
                    renameOldPath[new] = parts[1]
                }
            } else if let single = code.first {
                let path = parts.count >= 2 ? parts[1] : ""
                if path.isEmpty { continue }
                switch single {
                case "A": statusMap[path] = .added
                case "M": statusMap[path] = .modified
                case "D": statusMap[path] = .deleted
                default: statusMap[path] = .unknown
                }
            }
        }

        var files: [GitFileEntry] = []
        var totalA = 0, totalD = 0
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 3 else { continue }
            let isBinary = parts[0] == "-"
            let adds = isBinary ? 0 : Int(parts[0]) ?? 0
            let dels = isBinary ? 0 : Int(parts[1]) ?? 0
            let path = parts[2]
            totalA += adds; totalD += dels
            let st = statusMap[path] ?? .modified
            files.append(GitFileEntry(
                path: path,
                oldPath: renameOldPath[path],
                status: st,
                additions: adds,
                deletions: dels,
                binary: isBinary
            ))
        }
        for line in untracked.split(separator: "\n") {
            let p = String(line)
            guard !p.isEmpty else { continue }
            files.append(GitFileEntry(path: p, oldPath: nil, status: .untracked, additions: 0, deletions: 0, binary: false))
        }
        let dirty = !files.isEmpty
        return GitSummary(
            isGitRepo: true,
            branch: branch.isEmpty ? nil : branch,
            dirty: dirty,
            files: files,
            totalAdditions: totalA,
            totalDeletions: totalD
        )
    }

    public static func diff(in cwd: String, path: String?) -> String {
        guard isGit(cwd) else { return "" }
        var args = ["diff", "HEAD", "--no-color"]
        if let path { args.append("--"); args.append(path) }
        return run(args, cwd: cwd).stdout
    }

    // MARK: helpers

    public static func isGit(_ cwd: String) -> Bool {
        let r = run(["rev-parse", "--is-inside-work-tree"], cwd: cwd)
        return r.exit == 0 && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private struct ProcessResult { let exit: Int32; let stdout: String; let stderr: String }

    private static func run(_ args: [String], cwd: String) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return ProcessResult(exit: -1, stdout: "", stderr: String(describing: error)) }
        p.waitUntilExit()
        let oData = out.fileHandleForReading.readDataToEndOfFile()
        let eData = err.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            exit: p.terminationStatus,
            stdout: String(data: oData, encoding: .utf8) ?? "",
            stderr: String(data: eData, encoding: .utf8) ?? ""
        )
    }
}
