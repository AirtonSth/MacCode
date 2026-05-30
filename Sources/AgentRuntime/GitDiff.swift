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

public struct GitPullRequestRef: Codable, Sendable, Equatable {
    public let host: String
    public let repositoryPath: String
    public let number: Int
    public let remoteRef: String
    public let webURL: String

    public init(host: String, repositoryPath: String, number: Int, remoteRef: String, webURL: String) {
        self.host = host
        self.repositoryPath = repositoryPath
        self.number = number
        self.remoteRef = remoteRef
        self.webURL = webURL
    }
}

public struct GitPullRequestPreparation: Codable, Sendable, Equatable {
    public let ref: GitPullRequestRef
    public let worktreePath: String
    public let branch: String
    public let result: GitActionResult

    public init(ref: GitPullRequestRef, worktreePath: String, branch: String, result: GitActionResult) {
        self.ref = ref
        self.worktreePath = worktreePath
        self.branch = branch
        self.result = result
    }
}

public enum GitDeliveryPhaseStatus: String, Codable, Sendable, Equatable {
    case ready
    case blocked
    case completed
    case failed
    case skipped
}

public struct GitDeliveryPhase: Codable, Sendable, Equatable {
    public let name: String
    public let status: GitDeliveryPhaseStatus
    public let detail: String

    public init(name: String, status: GitDeliveryPhaseStatus, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

public struct GitDeliveryPlan: Codable, Sendable, Equatable {
    public let branchName: String
    public let commitMessage: String
    public let pullRequestTitle: String
    public let pullRequestBody: String
    public let pullRequestURL: String?
    public let phases: [GitDeliveryPhase]

    public init(branchName: String, commitMessage: String, pullRequestTitle: String, pullRequestBody: String, pullRequestURL: String?, phases: [GitDeliveryPhase]) {
        self.branchName = branchName
        self.commitMessage = commitMessage
        self.pullRequestTitle = pullRequestTitle
        self.pullRequestBody = pullRequestBody
        self.pullRequestURL = pullRequestURL
        self.phases = phases
    }
}

public struct GitDeliveryCopy: Codable, Sendable, Equatable {
    public let branchName: String?
    public let commitMessage: String?
    public let pullRequestTitle: String?
    public let pullRequestBody: String?

    public init(branchName: String? = nil, commitMessage: String? = nil, pullRequestTitle: String? = nil, pullRequestBody: String? = nil) {
        self.branchName = branchName
        self.commitMessage = commitMessage
        self.pullRequestTitle = pullRequestTitle
        self.pullRequestBody = pullRequestBody
    }
}

public struct GitDeliveryResult: Codable, Sendable, Equatable {
    public let ok: Bool
    public let plan: GitDeliveryPlan
    public let phases: [GitDeliveryPhase]
    public let pullRequestURL: String?

    public init(ok: Bool, plan: GitDeliveryPlan, phases: [GitDeliveryPhase], pullRequestURL: String?) {
        self.ok = ok
        self.plan = plan
        self.phases = phases
        self.pullRequestURL = pullRequestURL
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

    /// Stash the working tree (incl. untracked) then checkout `branch`.
    /// Used by the dirty-checkout guard so users with uncommitted work
    /// can switch branches without losing changes (UX-004).
    public static func stashAndCheckout(in cwd: String, branch: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let stash = run(["stash", "push", "--include-untracked", "-m", "remote-code: switch to \(branch)"], cwd: cwd)
        guard stash.exit == 0 else { return GitActionResult(ok: false, message: actionMessage(stash)) }
        let r = run(["checkout", branch], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    public static func restorePathToHead(in cwd: String, path: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["checkout", "HEAD", "--", path], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    public static func createBranch(in cwd: String, name: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["checkout", "-b", name], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    public static func createWorktree(in cwd: String, path: String, branch: String, baseBranch: String) -> GitActionResult {
        guard isGit(cwd) else { return GitActionResult(ok: false, message: "Not a git repository.") }
        let r = run(["worktree", "add", "-b", branch, path, baseBranch], cwd: cwd)
        return GitActionResult(ok: r.exit == 0, message: actionMessage(r))
    }

    public static func pullRequestRef(from urlString: String) -> GitPullRequestRef? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let numberString: String = {
            if let pullIndex = parts.firstIndex(of: "pull"), parts.indices.contains(pullIndex + 1) {
                return parts[pullIndex + 1]
            }
            if let markerIndex = parts.firstIndex(of: "-"),
               parts.indices.contains(markerIndex + 2),
               parts[markerIndex + 1] == "merge_requests" {
                return parts[markerIndex + 2]
            }
            return nil
        }(), let number = Int(numberString), number > 0 else { return nil }

        let repoParts: [String]
        let remoteRef: String
        if let pullIndex = parts.firstIndex(of: "pull"), pullIndex >= 2 {
            repoParts = Array(parts[..<pullIndex])
            remoteRef = "refs/pull/\(number)/head"
        } else if let markerIndex = parts.firstIndex(of: "-"), markerIndex >= 2 {
            repoParts = Array(parts[..<markerIndex])
            remoteRef = "refs/merge-requests/\(number)/head"
        } else {
            return nil
        }
        let repoPath = repoParts.joined(separator: "/")
        guard !repoPath.isEmpty else { return nil }
        return GitPullRequestRef(host: host, repositoryPath: repoPath, number: number, remoteRef: remoteRef, webURL: urlString)
    }

    public static func preparePullRequestWorktree(in cwd: String, urlString: String, worktreePath requestedPath: String? = nil) -> GitPullRequestPreparation {
        guard isGit(cwd) else {
            let ref = pullRequestRef(from: urlString) ?? GitPullRequestRef(host: "", repositoryPath: "", number: 0, remoteRef: "", webURL: urlString)
            return GitPullRequestPreparation(ref: ref, worktreePath: requestedPath ?? "", branch: "", result: GitActionResult(ok: false, message: "Not a git repository."))
        }
        guard let ref = pullRequestRef(from: urlString) else {
            let fallback = GitPullRequestRef(host: "", repositoryPath: "", number: 0, remoteRef: "", webURL: urlString)
            return GitPullRequestPreparation(ref: fallback, worktreePath: requestedPath ?? "", branch: "", result: GitActionResult(ok: false, message: "Unsupported pull request URL."))
        }
        let trackingRef: String
        let fetchedRemote: String?
        let fetch = fetchPullRequestRef(ref, cwd: cwd)
        guard fetch.result.exit == 0 else {
            return GitPullRequestPreparation(ref: ref, worktreePath: requestedPath ?? "", branch: "", result: GitActionResult(ok: false, message: actionMessage(fetch.result)))
        }
        trackingRef = fetch.trackingRef
        fetchedRemote = fetch.remoteName
        let branch = "rc-pr/\(safeRefComponent(ref.host))/\(safeRefComponent(ref.repositoryPath))-\(ref.number)"
        let path: String
        if let requestedPath, !requestedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            path = requestedPath
        } else {
            let root = URL(fileURLWithPath: cwd).standardizedFileURL
            let parent = root.deletingLastPathComponent()
            let repoName = root.lastPathComponent.isEmpty ? "workspace" : root.lastPathComponent
            path = parent.appendingPathComponent("\(repoName)-pr-worktrees").appendingPathComponent("pr-\(ref.number)").path
        }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let add = run(["worktree", "add", "-B", branch, path, trackingRef], cwd: cwd)
        if add.exit == 0, let fetchedRemote {
            _ = run(["branch", "--set-upstream-to=\(fetchedRemote)/pr/\(ref.number)", branch], cwd: path)
        }
        return GitPullRequestPreparation(ref: ref, worktreePath: path, branch: branch, result: GitActionResult(ok: add.exit == 0, message: actionMessage(add)))
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

    public static func deliveryPlan(in cwd: String) -> GitDeliveryPlan {
        deliveryPlan(in: cwd, copy: nil)
    }

    public static func deliveryPlan(in cwd: String, copy: GitDeliveryCopy?) -> GitDeliveryPlan {
        let summary = self.summary(in: cwd)
        guard summary.isGitRepo else {
            return GitDeliveryPlan(
                branchName: "",
                commitMessage: "",
                pullRequestTitle: "",
                pullRequestBody: "",
                pullRequestURL: nil,
                phases: [GitDeliveryPhase(name: "inspect", status: .blocked, detail: "Not a git repository.")]
            )
        }
        let fallbackCommitMessage = suggestCommitMessage(summary)
        let commitMessage = sanitizedCommitMessage(copy?.commitMessage) ?? fallbackCommitMessage
        let branchName = sanitizedBranchName(copy?.branchName) ?? deliveryBranchName(summary: summary)
        let title = sanitizedTitle(copy?.pullRequestTitle) ?? (commitMessage.isEmpty ? "Update workspace" : commitMessage)
        let changed = summary.files.map { "- \($0.path) (\($0.status.rawValue))" }.joined(separator: "\n")
        let fallbackBody = """
        ## Summary
        \(summary.files.isEmpty ? "- No working tree changes detected." : changed)

        ## Stats
        +\(summary.totalAdditions) -\(summary.totalDeletions)
        """
        let body = sanitizedBody(copy?.pullRequestBody) ?? fallbackBody
        let prURL = pullRequestURL(in: cwd)
        return GitDeliveryPlan(
            branchName: branchName,
            commitMessage: commitMessage,
            pullRequestTitle: title,
            pullRequestBody: body,
            pullRequestURL: prURL,
            phases: [
                GitDeliveryPhase(name: "branch", status: branchName.isEmpty ? .blocked : .ready, detail: branchName.isEmpty ? "No branch name available." : branchName),
                GitDeliveryPhase(name: "commit", status: commitMessage.isEmpty ? .blocked : .ready, detail: commitMessage.isEmpty ? "No changes to commit." : commitMessage),
                GitDeliveryPhase(name: "push", status: summary.files.isEmpty ? .blocked : .ready, detail: summary.files.isEmpty ? "No changes to push." : "Push current branch after commit."),
                GitDeliveryPhase(name: "pull_request", status: prURL == nil ? .blocked : .ready, detail: prURL ?? "No origin remote or current branch for PR URL.")
            ]
        )
    }

    public static func deliver(in cwd: String) -> GitDeliveryResult {
        deliver(in: cwd, copy: nil, environment: nil)
    }

    public static func deliver(in cwd: String, environment: [String: String]?) -> GitDeliveryResult {
        deliver(in: cwd, copy: nil, environment: environment)
    }

    public static func deliver(in cwd: String, copy: GitDeliveryCopy?, environment: [String: String]?) -> GitDeliveryResult {
        let plan = deliveryPlan(in: cwd, copy: copy)
        let summary = self.summary(in: cwd)
        guard summary.isGitRepo else {
            return GitDeliveryResult(ok: false, plan: plan, phases: [
                GitDeliveryPhase(name: "inspect", status: .failed, detail: "Not a git repository.")
            ], pullRequestURL: nil)
        }
        guard !summary.files.isEmpty else {
            return GitDeliveryResult(ok: false, plan: plan, phases: [
                GitDeliveryPhase(name: "commit", status: .blocked, detail: "No changes to commit.")
            ], pullRequestURL: plan.pullRequestURL)
        }

        var phases: [GitDeliveryPhase] = []
        let currentBranch = branches(in: cwd).current
        if currentBranch == plan.branchName {
            phases.append(GitDeliveryPhase(name: "branch", status: .skipped, detail: "Already on \(plan.branchName)."))
        } else {
            let branch = createBranch(in: cwd, name: plan.branchName)
            phases.append(GitDeliveryPhase(name: "branch", status: branch.ok ? .completed : .failed, detail: branch.message.isEmpty ? plan.branchName : branch.message))
            guard branch.ok else {
                return GitDeliveryResult(ok: false, plan: plan, phases: phases, pullRequestURL: nil)
            }
        }

        let committed = commit(in: cwd, message: plan.commitMessage)
        phases.append(GitDeliveryPhase(name: "commit", status: committed.ok ? .completed : .failed, detail: committed.message))
        guard committed.ok else {
            return GitDeliveryResult(ok: false, plan: plan, phases: phases, pullRequestURL: nil)
        }

        let pushed = push(in: cwd)
        phases.append(GitDeliveryPhase(name: "push", status: pushed.ok ? .completed : .failed, detail: pushed.message))
        guard pushed.ok else {
            return GitDeliveryResult(ok: false, plan: plan, phases: phases, pullRequestURL: nil)
        }

        let pullRequest = createPullRequest(in: cwd, plan: plan, environment: environment)
        phases.append(pullRequest.phase)
        return GitDeliveryResult(ok: true, plan: plan, phases: phases, pullRequestURL: pullRequest.url)
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
        guard let context = pullRequestContext(in: cwd) else { return nil }
        let host = context.host
        let path = context.repositoryPath
        let branch = context.branch
        if host.contains("gitlab") {
            return "https://\(host)/\(path)/-/merge_requests/new?merge_request%5Bsource_branch%5D=\(branch)"
        }
        // GitHub (and GitHub-compatible) compare page.
        return "https://\(host)/\(path)/compare/\(branch)?expand=1"
    }

    private struct PullRequestContext {
        let host: String
        let repositoryPath: String
        let branch: String
        let baseBranch: String
    }

    private struct PullRequestCreation {
        let phase: GitDeliveryPhase
        let url: String?
    }

    private static func pullRequestContext(in cwd: String) -> PullRequestContext? {
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
        let originHead = run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], cwd: cwd)
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = originHead.hasPrefix("origin/") ? String(originHead.dropFirst("origin/".count)) : nil
        return PullRequestContext(host: host, repositoryPath: path, branch: branch, baseBranch: base?.isEmpty == false ? base! : "main")
    }

    private static func sanitizedCommitMessage(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\u{0}") else { return nil }
        return String(trimmed.prefix(120))
    }

    private static func sanitizedTitle(_ value: String?) -> String? {
        sanitizedCommitMessage(value)
    }

    private static func sanitizedBody(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\u{0}") else { return nil }
        return String(trimmed.prefix(10_000))
    }

    private static func sanitizedBranchName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...100).contains(trimmed.count),
              !trimmed.hasPrefix("/"),
              !trimmed.hasSuffix("/"),
              !trimmed.contains(".."),
              !trimmed.contains("@{"),
              trimmed.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    private static func createPullRequest(in cwd: String, plan: GitDeliveryPlan, environment: [String: String]?) -> PullRequestCreation {
        guard let context = pullRequestContext(in: cwd), let fallbackURL = pullRequestURL(in: cwd) else {
            return PullRequestCreation(
                phase: GitDeliveryPhase(name: "pull_request", status: .blocked, detail: "No origin remote or current branch for PR URL."),
                url: nil
            )
        }
        if context.host.contains("github") {
            let auth = runCommand(["gh", "auth", "status"], cwd: cwd, environment: nonInteractiveEnvironment(environment))
            guard auth.exit == 0 else {
                return PullRequestCreation(
                    phase: GitDeliveryPhase(name: "pull_request", status: .ready, detail: fallbackURL),
                    url: fallbackURL
                )
            }
            let created = runCommand([
                "gh", "pr", "create",
                "--title", plan.pullRequestTitle,
                "--body", plan.pullRequestBody,
                "--head", context.branch,
                "--base", context.baseBranch
            ], cwd: cwd, environment: nonInteractiveEnvironment(environment))
            return pullRequestCreationResult(created, fallbackURL: fallbackURL)
        }
        if context.host.contains("gitlab") {
            let auth = runCommand(["glab", "auth", "status"], cwd: cwd, environment: nonInteractiveEnvironment(environment))
            guard auth.exit == 0 else {
                return PullRequestCreation(
                    phase: GitDeliveryPhase(name: "pull_request", status: .ready, detail: fallbackURL),
                    url: fallbackURL
                )
            }
            let created = runCommand([
                "glab", "mr", "create",
                "--title", plan.pullRequestTitle,
                "--description", plan.pullRequestBody,
                "--source-branch", context.branch,
                "--target-branch", context.baseBranch
            ], cwd: cwd, environment: nonInteractiveEnvironment(environment))
            return pullRequestCreationResult(created, fallbackURL: fallbackURL)
        }
        return PullRequestCreation(
            phase: GitDeliveryPhase(name: "pull_request", status: .ready, detail: fallbackURL),
            url: fallbackURL
        )
    }

    private static func pullRequestCreationResult(_ result: ProcessResult, fallbackURL: String) -> PullRequestCreation {
        guard result.exit == 0 else {
            return PullRequestCreation(
                phase: GitDeliveryPhase(name: "pull_request", status: .failed, detail: actionMessage(result)),
                url: fallbackURL
            )
        }
        let output = (result.stdout + "\n" + result.stderr)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let url = output.first { $0.hasPrefix("http://") || $0.hasPrefix("https://") } ?? fallbackURL
        return PullRequestCreation(
            phase: GitDeliveryPhase(name: "pull_request", status: .completed, detail: url),
            url: url
        )
    }

    private static func nonInteractiveEnvironment(_ environment: [String: String]?) -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment ?? [:] {
            merged[key] = value
        }
        merged["GH_PROMPT_DISABLED"] = "1"
        merged["GLAB_PROMPT_DISABLED"] = "1"
        return merged
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

    private static func safeRefComponent(_ raw: String) -> String {
        raw.lowercased()
            .map { char in
                char.isLetter || char.isNumber || char == "-" || char == "_" ? char : "-"
            }
            .reduce(into: "") { partial, char in
                if char == "-", partial.last == "-" { return }
                partial.append(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func deliveryBranchName(summary: GitSummary) -> String {
        let base: String
        if let first = summary.files.first?.path, !first.isEmpty {
            base = "agent/\(safeRefComponent(first.replacingOccurrences(of: ".", with: "-")))"
        } else {
            base = "agent/update"
        }
        return base.isEmpty ? "agent/update" : String(base.prefix(72))
    }

    private struct PullRequestFetch {
        let result: ProcessResult
        let trackingRef: String
        let remoteName: String?
    }

    private static func fetchPullRequestRef(_ ref: GitPullRequestRef, cwd: String) -> PullRequestFetch {
        var remotes = remoteNames(in: cwd)
        if remotes.contains("origin") {
            remotes.removeAll { $0 == "origin" }
            remotes.insert("origin", at: 0)
        }
        if let upstreamIndex = remotes.firstIndex(of: "upstream"), upstreamIndex > 1 {
            remotes.remove(at: upstreamIndex)
            remotes.insert("upstream", at: 1)
        }
        for remote in remotes {
            let trackingRef = "refs/remotes/\(remote)/pr/\(ref.number)"
            let result = run(["fetch", remote, "\(ref.remoteRef):\(trackingRef)"], cwd: cwd)
            if result.exit == 0 {
                return PullRequestFetch(result: result, trackingRef: trackingRef, remoteName: remote)
            }
        }
        let directURL = "https://\(ref.host)/\(ref.repositoryPath).git"
        let direct = run(["fetch", directURL, ref.remoteRef], cwd: cwd)
        return PullRequestFetch(result: direct, trackingRef: "FETCH_HEAD", remoteName: nil)
    }

    private static func remoteNames(in cwd: String) -> [String] {
        let listed = run(["remote"], cwd: cwd).stdout
        return listed.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public static func isGit(_ cwd: String) -> Bool {
        let r = run(["rev-parse", "--is-inside-work-tree"], cwd: cwd)
        return r.exit == 0 && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private struct ProcessResult { let exit: Int32; let stdout: String; let stderr: String }

    private static func run(_ args: [String], cwd: String) -> ProcessResult {
        runCommand(["git"] + args, cwd: cwd, environment: nil)
    }

    private static func runCommand(_ args: [String], cwd: String, environment: [String: String]?) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        if let environment {
            p.environment = environment
        }
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
