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

public struct GitBranches: Codable, Sendable, Equatable {
    public let current: String?
    public let locals: [String]

    public init(current: String?, locals: [String]) {
        self.current = current; self.locals = locals
    }
}

public struct GitCommit: Codable, Sendable, Equatable {
    public let hash: String
    public let shortHash: String
    public let author: String
    public let date: String
    public let subject: String

    public init(hash: String, shortHash: String, author: String, date: String, subject: String) {
        self.hash = hash; self.shortHash = shortHash; self.author = author
        self.date = date; self.subject = subject
    }
}

public struct GitActionResult: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String

    public init(ok: Bool, message: String) {
        self.ok = ok; self.message = message
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

    public static func diff(in cwd: String, path: String?, ignoreWhitespace: Bool = false) -> String {
        guard isGit(cwd) else { return "" }
        var args = ["diff", "HEAD", "--no-color"]
        if ignoreWhitespace { args.append("-w") }
        if let path { args.append("--"); args.append(path) }
        return run(args, cwd: cwd).stdout
    }

    // MARK: branch / commit / history

    public static func branches(in cwd: String) -> GitBranches {
        guard isGit(cwd) else { return GitBranches(current: nil, locals: []) }
        let head = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = (head.isEmpty || head == "HEAD") ? nil : head
        let listed = run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd: cwd).stdout
        let locals = listed.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return GitBranches(current: current, locals: locals)
    }

    public static func checkout(in cwd: String, branch: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["checkout", branch], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    public static func createBranch(in cwd: String, name: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["checkout", "-b", name], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    /// Stages every change (`git add -A`) then commits with `message`.
    public static func commit(in cwd: String, message: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let add = run(["add", "-A"], cwd: cwd)
        guard add.exit == 0 else { return GitActionResult(ok: false, message: actionMessage(add)) }
        let r = run(["commit", "-m", message], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    public static func log(in cwd: String, limit: Int = 100) -> [GitCommit] {
        guard isGit(cwd) else { return [] }
        let fmt = "%H%x1f%h%x1f%an%x1f%ad%x1f%s"
        let out = run(["log", "-n", String(limit), "--date=short", "--pretty=format:\(fmt)"], cwd: cwd).stdout
        var commits: [GitCommit] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { continue }
            commits.append(GitCommit(hash: f[0], shortHash: f[1], author: f[2], date: f[3], subject: f[4]))
        }
        return commits
    }

    /// remotecode.io GitQuickControl parity — a sensible fallback commit
    /// subject derived from the working-tree summary.
    public static func suggestCommitMessage(_ s: GitSummary) -> String {
        guard !s.files.isEmpty else { return "" }
        let stat = "+\(s.totalAdditions) −\(s.totalDeletions)"
        if s.files.count == 1 { return "Update \(s.files[0].path) (\(stat))" }
        return "Update \(s.files.count) files (\(stat))"
    }

    /// `git push`; if there is no upstream, set one (`-u origin HEAD`).
    public static func push(in cwd: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["push"], cwd: cwd)
        if r.exit == 0 { return GitActionResult(ok: true, message: actionMessage(r)) }
        let combined = (r.stderr + r.stdout).lowercased()
        if combined.contains("no upstream") || combined.contains("set-upstream") || combined.contains("has no upstream") {
            let r2 = run(["push", "-u", "origin", "HEAD"], cwd: cwd)
            return GitActionResult(ok: r2.exit == 0, message: actionMessage(r2))
        }
        return GitActionResult(ok: false, message: actionMessage(r))
    }

    /// A web URL to open a pull/merge request for the current branch,
    /// derived from `origin`. nil if not a repo / no usable remote.
    public static func pullRequestURL(in cwd: String) -> String? {
        guard isGit(cwd) else { return nil }
        let remote = run(["remote", "get-url", "origin"], cwd: cwd)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else { return nil }
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, branch != "HEAD" else { return nil }
        // Normalize git@host:owner/repo(.git) and https://host/owner/repo(.git)
        var host = "", path = ""
        if remote.hasPrefix("git@"), let colon = remote.firstIndex(of: ":") {
            host = String(remote[remote.index(remote.startIndex, offsetBy: 4)..<colon])
            path = String(remote[remote.index(after: colon)...])
        } else if let r = URL(string: remote), let h = r.host {
            host = h
            path = String(r.path.drop(while: { $0 == "/" }))
        } else {
            return nil
        }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        if host.contains("gitlab") {
            return "https://\(host)/\(path)/-/merge_requests/new?merge_request%5Bsource_branch%5D=\(branch)"
        }
        // GitHub (and GitHub-compatible) compare page.
        return "https://\(host)/\(path)/compare/\(branch)?expand=1"
    }

    public static func commitDiff(in cwd: String, hash: String, ignoreWhitespace: Bool = false) -> String {
        guard isGit(cwd) else { return "" }
        var args = ["show", hash, "--no-color"]
        if ignoreWhitespace { args.append("-w") }
        return run(args, cwd: cwd).stdout
    }

    // MARK: helpers

    /// Prefer stderr (where git writes failures); fall back to stdout
    /// (e.g. "nothing to commit") so errors are never surfaced empty.
    private static func actionMessage(_ r: ProcessResult) -> String {
        let e = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
