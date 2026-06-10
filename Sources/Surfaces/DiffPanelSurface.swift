import Foundation
import AppKit
import SwiftUI
import CoreModel
import AgentRuntime
import Persistence
import DesignSystemKit
import CoreServices

public enum GitPanelMode: String, CaseIterable, Sendable {
    case changes, history
}

@MainActor
public final class DiffPanelViewModel: ObservableObject {
    /// Cap the rendered diff so a giant `git show` can't stall TextKit
    /// layout / spike memory (PERF-006). ~400K chars is already far
    /// beyond what is human-reviewable in one pass.
    private static let maxDiffRenderChars = 400 * 1024

    @Published public var cwd: String
    @Published public var summary: GitSummary
    @Published public var selectedPath: String?
    @Published public var rawDiff: String = "" { didSet { rebuildStyledDiff() } }
    /// Styled diff rebuilt once when `rawDiff` changes, not on every body
    /// pass, so unrelated @Published changes (wrap toggle, error banner,
    /// summary refresh) don't re-parse the whole diff (PERF-005). Capped
    /// to avoid laying out a multi-MB attributed string at once (PERF-006).
    @Published public private(set) var styledDiff: AttributedString = AttributedString()
    /// True when the rendered diff was clipped to `maxDiffRenderBytes`.
    @Published public private(set) var diffTruncated: Bool = false
    /// In-flight git work. `isLoading` gates the read-only refresh spinner
    /// (UX-001); `isBusy` gates mutating actions and their spinner (UX-002).
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isBusy: Bool = false
    /// Transient confirmation after a successful mutating action (UX-002).
    @Published public var actionSuccess: String?
    @Published public var wordWrap: Bool = false { didSet { persistPrefs() } }
    @Published public var ignoreWhitespace: Bool = false { didSet { persistPrefs() } }

    @Published public var branches: GitBranches
    @Published public var commits: [GitCommit] = []
    @Published public var commitMessage: String = ""
    @Published public var mode: GitPanelMode = .changes
    /// Paths the user has explicitly checked for per-file commit.
    /// Empty means "commit all" (existing behaviour); non-empty means
    /// only those paths are staged+committed.
    @Published public var selectedFiles: Set<String> = []
    @Published public var selectedCommit: String?
    /// UX-015: `lastError` is friendly/humanized copy shown in the banner;
    /// `lastErrorRaw` keeps the original git stderr for the "Copy details"
    /// expander so nothing is lost.
    @Published public var lastError: String?
    @Published public private(set) var lastErrorRaw: String?
    /// History pagination: total number of commits requested from git log.
    /// Starts at 100 and grows by `historyPageSize` on each "Load more".
    @Published public private(set) var historyLoadLimit: Int = 100
    /// Subject-line filter for the history list (case-insensitive contains).
    @Published public var historyFilter: String = ""
    /// When true the next commit action runs `git commit --amend` instead of
    /// a fresh commit. Resets to false after a successful amend so the checkbox
    /// does not silently amend again on the next commit.
    @Published public var amendLastCommit: Bool = false
    private var historyLoaded = false
    /// Monotonic token: each reloadDiff bumps it; only the matching
    /// completion may write rawDiff so a slow earlier git process can't
    /// overwrite the diff of a newer selection (PERF-007).
    private var diffGeneration = 0
    private let settings: SettingsStore?
    /// FSEvents stream token for cwd watch; nil until `startFSWatcher()` is called.
    private var fsStream: FSEventStreamRef?
    /// Wall-clock time of the last auto-refresh triggered by FSEvents.
    private var lastFSRefresh: Date = .distantPast

    /// C8: diff view prefs persist across launches via SettingsStore.
    public init(cwd: String, settings: SettingsStore? = nil) {
        self.cwd = cwd
        self.settings = settings
        self.summary = GitDiff.summary(in: cwd)
        self.branches = GitDiff.branches(in: cwd)
        if let s = settings?.load() {
            // Set within init → property observers don't fire (no echo write).
            self.wordWrap = s.diffWordWrap
            self.ignoreWhitespace = s.diffIgnoreWhitespace
        }
    }

    private func persistPrefs() {
        settings?.update {
            $0.diffWordWrap = self.wordWrap
            $0.diffIgnoreWhitespace = self.ignoreWhitespace
        }
    }

    /// Build the +/−/@@/header-tinted AttributedString once per rawDiff
    /// change (PERF-005). Clip overly large diffs so TextKit doesn't lay
    /// out megabytes at once (PERF-006).
    private func rebuildStyledDiff() {
        // Cap by character count (always a valid index, unlike a raw UTF-8
        // byte offset). maxDiffRenderBytes is a coarse safety valve.
        let source: Substring
        if rawDiff.count > Self.maxDiffRenderChars {
            source = rawDiff.prefix(Self.maxDiffRenderChars)
            diffTruncated = true
        } else {
            source = rawDiff[...]
            diffTruncated = false
        }
        var out = AttributedString()
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var seg = AttributedString(String(line) + "\n")
            // QA-007: classification lives in a pure, tested helper; the view
            // only maps kind → color here.
            switch DiffLineKind.classify(line) {
            case .add:
                seg.foregroundColor = DS.Palette.success
                seg.backgroundColor = DS.Palette.success.opacity(0.08)
            case .del:
                seg.foregroundColor = DS.Palette.danger
                seg.backgroundColor = DS.Palette.danger.opacity(0.08)
            case .hunk:
                seg.foregroundColor = DS.Palette.accent
                seg.backgroundColor = DS.Palette.accent.opacity(0.08)
            case .header:
                seg.foregroundColor = DS.Palette.warning
            case .context:
                seg.foregroundColor = DS.Palette.textSecondary
            }
            out.append(seg)
        }
        styledDiff = out
    }

    public func refresh() {
        let cwd = self.cwd
        DispatchQueue.global().async { [weak self] in
            let s = GitDiff.summary(in: cwd)
            DispatchQueue.main.async { self?.summary = s }
        }
    }

    /// Refresh-button entry point: one background pass that reloads
    /// summary, branches and history together, with a visible spinner so
    /// the panel never looks frozen during git work (UX-001).
    public func reloadAll() {
        guard !isLoading else { return }
        let cwd = self.cwd
        isLoading = true
        DispatchQueue.global().async { [weak self] in
            let s = GitDiff.summary(in: cwd)
            let b = GitDiff.branches(in: cwd)
            let log = GitDiff.log(in: cwd)
            DispatchQueue.main.async {
                guard let self else { return }
                self.summary = s
                self.branches = b
                self.commits = log
                self.historyLoaded = true
                self.isLoading = false
            }
        }
    }

    public func loadBranches() {
        let cwd = self.cwd
        DispatchQueue.global().async { [weak self] in
            let b = GitDiff.branches(in: cwd)
            DispatchQueue.main.async { self?.branches = b }
        }
    }

    public func loadHistory(force: Bool = false) {
        if historyLoaded && !force { return }
        historyLoaded = true
        let cwd = self.cwd
        let limit = historyLoadLimit
        DispatchQueue.global().async { [weak self] in
            let c = GitDiff.log(in: cwd, limit: limit)
            DispatchQueue.main.async { self?.commits = c }
        }
    }

    /// Fetch the next page of history beyond the current `historyLoadLimit`.
    /// The limit grows by `historyPageSize` on each call so subsequent calls
    /// fetch successively larger windows. The UI shows "Load 100 more" to
    /// communicate this contract clearly.
    public func loadMoreHistory() {
        historyLoadLimit = Self.historyNextLimit(loaded: historyLoadLimit)
        let cwd = self.cwd
        let limit = historyLoadLimit
        isLoading = true
        DispatchQueue.global().async { [weak self] in
            let c = GitDiff.log(in: cwd, limit: limit)
            DispatchQueue.main.async {
                guard let self else { return }
                self.commits = c
                self.isLoading = false
            }
        }
    }

    public func selectFile(_ path: String?) {
        selectedPath = path
        selectedCommit = nil
        if path != nil {
            reloadDiff()
        } else {
            rawDiff = ""
        }
    }

    public func selectCommit(_ hash: String) {
        selectedCommit = hash
        selectedPath = nil
        reloadDiff()
    }

    /// UX-012: move the selection up/down the active list (changed files
    /// in Changes mode, commits in History mode) for keyboard review.
    public func selectAdjacent(_ direction: Int) {
        if mode == .history {
            guard !commits.isEmpty else { return }
            let idx = commits.firstIndex { $0.hash == selectedCommit } ?? -1
            let next = max(0, min(commits.count - 1, idx + direction))
            selectCommit(commits[next].hash)
        } else {
            let files = summary.files
            guard !files.isEmpty else { return }
            let idx = files.firstIndex { $0.path == selectedPath } ?? -1
            let next = max(0, min(files.count - 1, idx + direction))
            selectFile(files[next].path)
        }
    }

    /// Re-fetch the diff for whatever is currently selected. Called on
    /// selection change and whenever the ignore-whitespace toggle flips,
    /// so the toggle has a visible effect instead of being inert.
    public func reloadDiff() {
        let cwd = self.cwd
        let ws = self.ignoreWhitespace
        let path = self.selectedPath
        let commit = self.selectedCommit
        guard path != nil || commit != nil else { rawDiff = ""; isLoading = false; return }
        // Snapshot untracked status before leaving the main actor so the
        // background closure can make a decision without touching @Published.
        let isUntracked: Bool = {
            guard let p = path else { return false }
            return summary.files.first { $0.path == p }?.status == .untracked
        }()
        diffGeneration &+= 1
        let gen = diffGeneration
        isLoading = true
        DispatchQueue.global().async { [weak self] in
            let d: String
            if let p = path {
                if isUntracked {
                    // For untracked files git has no index entry, so
                    // `git diff HEAD` produces nothing. Synthesize an
                    // all-addition patch by reading the file content directly.
                    let fullPath = (cwd as NSString).appendingPathComponent(p)
                    let content = (try? String(contentsOfFile: fullPath, encoding: .utf8)) ?? ""
                    d = GitDiff.synthesizeUntrackedDiff(content: content, path: p)
                } else {
                    d = GitDiff.diff(in: cwd, path: p, ignoreWhitespace: ws)
                }
            } else if let h = commit {
                d = GitDiff.commitDiff(in: cwd, hash: h, ignoreWhitespace: ws)
            } else {
                d = ""
            }
            DispatchQueue.main.async {
                guard let self, gen == self.diffGeneration else { return }
                self.rawDiff = d
                self.isLoading = false
            }
        }
    }

    public func switchBranch(_ name: String) {
        runAction(successMessage: "Switched to \(name)") { GitDiff.checkout(in: $0, branch: name) }
    }

    /// UX-004: stash uncommitted work, then switch — the guarded path
    /// offered when the working tree is dirty.
    public func stashAndSwitchBranch(_ name: String) {
        runAction(successMessage: "Stashed changes and switched to \(name)") {
            GitDiff.stashAndCheckout(in: $0, branch: name)
        }
    }

    public func newBranch(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        runAction(successMessage: "Created branch \(n)") { GitDiff.createBranch(in: $0, name: n) }
    }

    public func commit() {
        let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        // `git add -A` commits the entire working tree — there is no
        // staging model, so the success copy says "all changes" to match
        // what actually happens (UX-005). Clear selection so the panel
        // doesn't keep showing a now-committed file's stale diff.
        let n = summary.files.count
        let amend = amendLastCommit
        let argv = Self.commitArgv(message: msg, amend: amend)
        let label = amend ? "Amended last commit" : "Committed all changes (\(n) file\(n == 1 ? "" : "s"))"
        runAction(clearMessageOnOK: true, successMessage: label) { cwd in
            Self.runGitCommit(cwd: cwd, argv: argv)
        }
        if amend { amendLastCommit = false }
        selectedPath = nil
        selectedCommit = nil
        rawDiff = ""
    }

    /// Stages and commits only the files in `selectedFiles`.
    /// Falls back to committing all when `selectedFiles` is empty.
    /// No-op when the commit message is blank.
    /// When `amendLastCommit` is true, runs `--amend` regardless of selection.
    public func commitSelected() {
        let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        let amend = amendLastCommit
        // Amend path: stage everything and amend.
        if amend {
            let argv = Self.commitArgv(message: msg, amend: true)
            runAction(clearMessageOnOK: true, successMessage: "Amended last commit") { cwd in
                Self.runGitCommit(cwd: cwd, argv: argv)
            }
            amendLastCommit = false
            selectedFiles = []
            selectedPath = nil
            selectedCommit = nil
            rawDiff = ""
            return
        }
        let allPaths = summary.files.map(\.path)
        guard let paths = StagingHelper.pathArgs(selected: selectedFiles, all: allPaths) else {
            // Empty / invalid selection: fall back to committing all.
            commit(); return
        }
        let n = paths.count
        runAction(clearMessageOnOK: true,
                  successMessage: "Committed \(n) selected file\(n == 1 ? "" : "s")") {
            GitDiff.commitPaths(in: $0, message: msg, paths: paths)
        }
        selectedFiles = []
        selectedPath = nil
        selectedCommit = nil
        rawDiff = ""
    }

    /// UX-006: throw away a file's working-tree edits (git checkout HEAD --).
    /// Clears the diff if the discarded file was the one on screen.
    public func discardFile(_ path: String) {
        runAction(successMessage: "Discarded changes in \(path)") {
            GitDiff.restorePathToHead(in: $0, path: path)
        }
        if selectedPath == path {
            selectedPath = nil
            rawDiff = ""
        }
    }

    /// D4: fill the composer with a generated fallback subject.
    /// UX-014: only fill when the field is empty so a typed message is
    /// never silently clobbered.
    public func suggestMessage() {
        guard commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        commitMessage = GitDiff.suggestCommitMessage(summary)
    }

    /// D2: push the current branch (sets upstream if needed).
    public func push() {
        let branch = branches.current ?? "branch"
        runAction(successMessage: "Pushed \(branch)") { GitDiff.push(in: $0) }
    }

    /// Fetch remote refs (`git fetch --prune`) without touching the working tree.
    /// Safe at any time; surfaces auth/network failures in the error banner.
    public func fetch() {
        runAction(successMessage: "Fetched remote refs") { GitDiff.fetch(in: $0) }
    }

    /// Pull the current branch (`git pull --ff-only`). Fails loud on diverged
    /// history or local conflicts so the user is never silently surprised.
    public func pull() {
        let branch = branches.current ?? "branch"
        runAction(successMessage: "Pulled \(branch)") { GitDiff.pull(in: $0) }
    }

    /// Called when the panel becomes visible (tab selected, window shown).
    /// Triggers a lightweight refresh so stale state is never the first thing
    /// a user sees after switching away and back.
    public func didBecomeVisible() {
        refresh()
        startFSWatcher()
    }

    /// Resolves a relative changed-file path against the workspace root.
    /// Pure, nonisolated so it is testable without @MainActor.
    nonisolated static func absolutePathURL(cwd: String, relativePath: String) -> URL {
        URL(fileURLWithPath: relativePath, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL
    }

    /// Returns true when "Open in Files tab" applies to a changed-file entry.
    /// Binary files are excluded: there is nothing to show in the text editor.
    /// Pure, nonisolated so it is testable without @MainActor.
    nonisolated static func isOpenInFilesTabApplicable(for entry: GitFileEntry) -> Bool {
        !entry.binary
    }

    /// Optional closure injected by the host surface so non-binary rows can
    /// open the file in the app's Files tab. `nil` when no router is available
    /// (e.g. standalone usage, tests); the menu item is hidden in that case.
    public var openInFilesTabAction: ((String) -> Void)?

    // MARK: - Pure helpers (nonisolated static — no @MainActor needed for tests)

    /// The number of commits fetched per page when the user taps "Load more".
    nonisolated static let historyPageSize: Int = 100

    /// Returns the new total limit after one "Load more" tap.
    /// Pure: `loaded` is current `historyLoadLimit`, result is passed back to
    /// `git log -n <result>` so the next page is always a strict superset.
    nonisolated static func historyNextLimit(loaded: Int, pageSize: Int = historyPageSize) -> Int {
        loaded + pageSize
    }

    /// Returns true when `commit.subject` contains `query` (case-insensitive).
    /// Empty `query` always matches — no filter active.
    nonisolated static func commitMatchesFilter(_ commit: GitCommit, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return commit.subject.localizedCaseInsensitiveContains(q)
    }

    /// Builds the git commit argv fragment for the message + amend flag.
    /// The returned array is the arguments passed to `git` after `["add", "-A"]`:
    ///   normal:  ["commit", "-m", message]
    ///   amend:   ["commit", "--amend", "-m", message]
    /// Pure — no I/O; callers own staging and execution.
    nonisolated static func commitArgv(message: String, amend: Bool) -> [String] {
        var args = ["commit"]
        if amend { args.append("--amend") }
        args += ["-m", message]
        return args
    }

    /// Commits in `cwd` with the given argv (as returned by `commitArgv`).
    /// Runs `git add -A` first unless `skipStage` is true (amend with no changes).
    /// Returns a `GitActionResult` compatible with `runAction`.
    nonisolated static func runGitCommit(cwd: String, argv: [String], skipStage: Bool = false) -> GitActionResult {
        func git(_ args: [String]) -> (exit: Int32, out: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (p.terminationStatus, out)
        }
        if !skipStage {
            let add = git(["add", "-A"])
            if add.exit != 0 {
                return GitActionResult(ok: false, message: add.out.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let r = git(argv)
        return GitActionResult(ok: r.exit == 0, message: r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The history list filtered by `historyFilter`. Computed so the view
    /// derives its list without a separate @Published property that could
    /// diverge from `commits`.
    public var filteredCommits: [GitCommit] {
        let q = historyFilter
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return commits }
        return commits.filter { Self.commitMatchesFilter($0, query: q) }
    }

    /// Minimum wall-clock interval between FSEvent-triggered auto-refreshes.
    /// Exposed as `nonisolated static` so it is testable without @MainActor.
    nonisolated static let fsDebounceInterval: TimeInterval = 2.0

    /// Pure debounce decision: returns `true` when `elapsed` seconds have
    /// passed since the last refresh, meaning a new refresh should fire.
    /// Extracted from the FSEvents callback so this logic is unit-testable
    /// without FSEvents infrastructure.
    nonisolated static func shouldRefresh(elapsed: TimeInterval) -> Bool {
        elapsed >= fsDebounceInterval
    }

    // MARK: FSEvents watcher

    private func startFSWatcher() {
        guard fsStream == nil else { return }
        let cwd = self.cwd as CFString
        let paths = [cwd] as CFArray
        // Context box carries `self` to the C callback via an unmanaged pointer.
        // Bridged through a retaining void* so the callback can call back onto
        // the main actor without capturing `self` directly in the C closure.
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { ptr in
                guard let p = ptr else { return }
                Unmanaged<DiffPanelViewModel>.fromOpaque(p).release()
            },
            copyDescription: nil
        )
        let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let vm = Unmanaged<DiffPanelViewModel>.fromOpaque(info).takeUnretainedValue()
                DispatchQueue.main.async {
                    let elapsed = Date().timeIntervalSince(vm.lastFSRefresh)
                    guard DiffPanelViewModel.shouldRefresh(elapsed: elapsed) else { return }
                    vm.lastFSRefresh = Date()
                    vm.refresh()
                }
            },
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // latency: coalesce rapid bursts (save storms) into one callback
            1.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )
        guard let stream else { return }
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        fsStream = stream
    }

    deinit {
        if let s = fsStream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    /// D2: open a PR/MR page for the current branch in the browser.
    public func openPullRequest() {
        guard let url = GitDiff.pullRequestURL(in: cwd), let u = URL(string: url) else {
            lastErrorRaw = nil
            lastError = "No remote 'origin' / branch to open a pull request for."
            return
        }
        NSWorkspace.shared.open(u)
    }

    /// Runs a mutating git op off the main thread, then re-reads summary,
    /// branches and log so the panel always reflects post-op truth.
    /// Failures surface in `lastError` — never silent (CLAUDE.md Rule 6).
    private func runAction(clearMessageOnOK: Bool = false,
                           successMessage: String? = nil,
                           _ op: @escaping @Sendable (String) -> GitActionResult) {
        let cwd = self.cwd
        isBusy = true
        actionSuccess = nil
        DispatchQueue.global().async { [weak self] in
            let r = op(cwd)
            let s = GitDiff.summary(in: cwd)
            let b = GitDiff.branches(in: cwd)
            let log = GitDiff.log(in: cwd)
            DispatchQueue.main.async {
                guard let self else { return }
                self.summary = s
                self.branches = b
                self.commits = log
                self.isBusy = false
                if r.ok {
                    self.lastError = nil
                    self.lastErrorRaw = nil
                    if clearMessageOnOK { self.commitMessage = "" }
                    if let successMessage { self.actionSuccess = successMessage }
                } else {
                    // UX-015: show actionable copy; keep raw stderr for details.
                    self.lastErrorRaw = r.message
                    self.lastError = GitDiff.humanizeError(r.message)
                }
            }
        }
    }
}

/// Row chrome shared by changed-file and commit rows: hover / pressed /
/// selected states plus a 2px accent rail when selected. One place so
/// every list row in the panel feels identical.
private struct GitRowButtonStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(selected ? DS.Palette.selection
                          : configuration.isPressed ? DS.Palette.pressed
                          : hovering ? DS.Palette.hover : Color.clear)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(DS.Palette.accent)
                    .frame(width: 2)
                    .padding(.vertical, DS.Space.xs)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(DS.Motion.micro, value: hovering)
    }
}

public struct DiffPanelView: View {
    @ObservedObject var vm: DiffPanelViewModel
    @State private var showNewBranchField = false
    @State private var newBranchName = ""
    /// UX-013: focus the new-branch field the moment it is revealed so the
    /// user can type immediately; Esc cancels.
    @FocusState private var newBranchFocused: Bool
    public init(vm: DiffPanelViewModel) { self.vm = vm }

    public var body: some View {
        HSplitView {
            leftColumn.frame(minWidth: 280, idealWidth: 320)
            diffBody.frame(minWidth: 440)
        }
        .background(DS.Palette.bg)
        // UX-012: arrow keys move the selection through the active list;
        // ⌘C copies the current diff without reaching for the toolbar.
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .up: vm.selectAdjacent(-1)
            case .down: vm.selectAdjacent(1)
            default: break
            }
        }
        .background(
            Button("", action: copyDiff)
                .keyboardShortcut("c", modifiers: .command)
                .opacity(0)
                .disabled(vm.rawDiff.isEmpty)
                .accessibilityHidden(true)
        )
    }

    // MARK: Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            if let err = vm.lastError { errorBanner(err) }
            if !vm.summary.isGitRepo {
                DSEmptyState(icon: "questionmark.folder", title: "Not a git repo",
                             subtitle: "Open a workspace backed by git to inspect changes.")
            } else if vm.mode == .changes {
                changesView
            } else {
                historyView
            }
        }
        .background(DS.Palette.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                branchChip
                Spacer(minLength: 0)
                if vm.summary.isGitRepo, vm.summary.totalAdditions + vm.summary.totalDeletions > 0 {
                    HStack(spacing: DS.Space.xs) {
                        Text("+\(vm.summary.totalAdditions)")
                            .font(DS.Font.caption2.weight(.semibold).monospacedDigit())
                            .foregroundColor(DS.Palette.success)
                        Text("−\(vm.summary.totalDeletions)")
                            .font(DS.Font.caption2.weight(.semibold).monospacedDigit())
                            .foregroundColor(DS.Palette.danger)
                    }
                }
                if vm.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 18, height: 18)
                        .accessibilityLabel("Loading git status")
                } else {
                    DSIconButton("arrow.clockwise", help: "Refresh") {
                        vm.reloadAll()
                    }
                    .accessibilityLabel("Refresh git status")
                    .accessibilityIdentifier("diff.refresh")
                }
            }
            if showNewBranchField { newBranchComposer }
            modeSwitch
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }

    private var branchChip: some View {
        Menu {
            if vm.branches.locals.isEmpty {
                Text("No branches")
            }
            ForEach(vm.branches.locals, id: \.self) { b in
                Button { requestSwitch(to: b) } label: {
                    if b == vm.branches.current {
                        Label(b, systemImage: "checkmark")
                    } else {
                        Text(b)
                    }
                }
                .accessibilityIdentifier("diff.branch.\(b)")
            }
            Divider()
            Button {
                newBranchName = ""
                withAnimation(DS.Motion.standard) { showNewBranchField = true }
                newBranchFocused = true   // UX-013: type immediately.
            } label: {
                Label("New branch…", systemImage: "plus")
            }
            .accessibilityIdentifier("diff.branch.new")
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                Text(vm.branches.current ?? "detached")
                    .font(DS.Font.monoSmall.weight(.medium))
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch or create branch")
        .accessibilityIdentifier("diff.branchChip")
    }

    private var newBranchComposer: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Palette.accent)
            TextField("new-branch-name", text: $newBranchName)
                .textFieldStyle(.plain)
                .font(DS.Font.monoSmall)
                .focused($newBranchFocused)
                .onSubmit(confirmNewBranch)
                .onExitCommand(perform: cancelNewBranch)   // UX-013: Esc cancels.
                .accessibilityIdentifier("diff.newBranch.field")
            Button("Create", action: confirmNewBranch)
                .buttonStyle(DSSecondaryButtonStyle())
                .controlSize(.small)
                .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("diff.newBranch.create")
            Button(action: cancelNewBranch) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Cancel new branch")
            .accessibilityIdentifier("diff.newBranch.cancel")
            .help("Cancel new branch")
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.bg)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
        .onChange(of: showNewBranchField) { shown in
            if shown { newBranchFocused = true }   // UX-013 backstop.
        }
    }

    /// History subject-line filter field. Shown above the commit list in
    /// history mode. Clearing the field restores the full list.
    private var historyFilterField: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Palette.textTertiary)
            TextField("Filter by subject...", text: $vm.historyFilter)
                .textFieldStyle(.plain)
                .font(DS.Font.monoSmall)
                .accessibilityIdentifier("diff.history.filter")
            if !vm.historyFilter.isEmpty {
                Button {
                    vm.historyFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
                .accessibilityIdentifier("diff.history.filter.clear")
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.bg)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .padding(.horizontal, DS.Space.lg)
        .padding(.bottom, DS.Space.sm)
    }

    /// Token-styled segmented control — the native `.segmented` picker
    /// looks alien on this dark chrome.
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            segButton("Changes", count: vm.summary.files.count, mode: .changes)
            segButton("History", count: nil, mode: .history)
        }
        .padding(2)
        .background(DS.Palette.bg)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
    }

    private func segButton(_ title: String, count: Int?, mode: GitPanelMode) -> some View {
        let on = vm.mode == mode
        return Button {
            withAnimation(DS.Motion.standard) { vm.mode = mode }
            if mode == .history { vm.loadHistory() }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Text(title).font(DS.Font.caption.weight(on ? .semibold : .regular))
                if let c = count, c > 0 {
                    Text("\(c)")
                        .font(DS.Font.caption2.weight(.semibold).monospacedDigit())
                        .foregroundColor(on ? DS.Palette.accent : DS.Palette.textSecondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(on ? DS.Palette.accent.opacity(0.20) : DS.Palette.surfaceOverlay)
                        .clipShape(Capsule())
                }
            }
            .foregroundColor(on ? DS.Palette.text : DS.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.sm)
            .background(on ? DS.Palette.surfaceRaised : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control - 1, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("diff.mode.\(mode.rawValue)")
    }

    private func confirmNewBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        vm.newBranch(name)
        newBranchName = ""
        withAnimation(DS.Motion.standard) { showNewBranchField = false }
    }

    private func cancelNewBranch() {
        newBranchFocused = false
        withAnimation(DS.Motion.standard) { showNewBranchField = false }
        newBranchName = ""
    }

    /// UX-004: a clean tree switches immediately; a dirty tree gets a
    /// guard offering "Stash & switch" instead of dumping a cryptic git
    /// "would be overwritten by checkout" error into the banner.
    private func requestSwitch(to branch: String) {
        guard branch != vm.branches.current else { return }
        guard vm.summary.dirty else { vm.switchBranch(branch); return }
        let alert = NSAlert()
        alert.messageText = "You have uncommitted changes"
        alert.informativeText = "Switching to \"\(branch)\" with a dirty working tree may fail or overwrite changes. Stash your changes first?"
        alert.addButton(withTitle: "Stash & Switch")
        alert.addButton(withTitle: "Switch Anyway")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: vm.stashAndSwitchBranch(branch)
        case .alertSecondButtonReturn: vm.switchBranch(branch)
        default: break
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(DS.Palette.danger)
                    .font(.system(size: 11))
                Text(msg)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.danger)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    withAnimation(DS.Motion.micro) { vm.lastError = nil }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityLabel("Dismiss error")
                .accessibilityIdentifier("diff.error.dismiss")
                .help("Dismiss error")
            }
            // UX-015: when the friendly copy differs from the raw git stderr,
            // offer a "Copy details" affordance so the original is recoverable.
            if let raw = vm.lastErrorRaw, raw != msg {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw, forType: .string)
                } label: {
                    Text("Copy details").font(DS.Font.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.danger.opacity(0.85))
                .accessibilityIdentifier("diff.error.copyDetails")
                .help("Copy the raw git error to the clipboard")
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .background(DS.Palette.danger.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Palette.danger.opacity(0.4)).frame(height: DS.Border.hairline)
        }
        .transition(.opacity)
        .accessibilityIdentifier("diff.error.banner")
    }

    // MARK: Changes

    private var changesView: some View {
        VStack(spacing: 0) {
            DSSectionHeader("Changes · \(vm.summary.files.count)")
            if vm.summary.files.isEmpty {
                DSEmptyState(icon: "checkmark.seal", title: "No changes",
                             subtitle: "The working tree is clean.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(vm.summary.files, id: \.path) { f in
                            fileRow(f)
                        }
                    }
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.bottom, DS.Space.sm)
                }
            }
            commitBox
        }
    }

    private func fileRow(_ f: GitFileEntry) -> some View {
        let selected = vm.selectedPath == f.path
        let staged = vm.selectedFiles.contains(f.path)
        let comps = f.path.split(separator: "/").map(String.init)
        let file = comps.last ?? f.path
        let dir = comps.dropLast().joined(separator: "/")
        return Button { vm.selectFile(f.path) } label: {
            HStack(spacing: DS.Space.md) {
                // Per-file staging checkbox. Tap toggles inclusion without
                // changing the diff-pane selection.
                Button {
                    if vm.selectedFiles.contains(f.path) {
                        vm.selectedFiles.remove(f.path)
                    } else {
                        vm.selectedFiles.insert(f.path)
                    }
                } label: {
                    Image(systemName: staged ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundColor(staged ? DS.Palette.accent : DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help(staged ? "Remove from commit" : "Include in commit")
                .accessibilityLabel(staged ? "Deselect \(f.path)" : "Select \(f.path)")
                .accessibilityIdentifier("diff.file.stage.\(f.path)")
                statusBadge(f.status)
                HStack(spacing: 0) {
                    if !dir.isEmpty {
                        Text(dir + "/")
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                    Text(file)
                        .foregroundColor(DS.Palette.text)
                }
                .font(DS.Font.monoSmall)
                .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: DS.Space.sm)
                if !f.binary {
                    Text("+\(f.additions)")
                        .font(DS.Font.caption2.monospacedDigit())
                        .foregroundColor(DS.Palette.success)
                    Text("−\(f.deletions)")
                        .font(DS.Font.caption2.monospacedDigit())
                        .foregroundColor(DS.Palette.danger)
                    // IMP-012: proportional add/del bar for at-a-glance
                    // change magnitude per file (GitHub-style).
                    changeBar(additions: f.additions, deletions: f.deletions)
                } else {
                    Text("binary")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                }
            }
        }
        .buttonStyle(GitRowButtonStyle(selected: selected))
        .help(f.path)
        .accessibilityIdentifier("diff.file.\(f.path)")
        // UX-006: discard a file's working-tree edits without a terminal.
        // UX-017: binary files have no textual diff — give them an escape
        // hatch (Open / Reveal) instead of a dead-end "binary" label.
        // P2: non-binary rows get "Open in Files tab" + "Reveal in Finder"
        // so users can jump to the editor or Finder directly from the diff list.
        .contextMenu {
            if f.binary {
                Button { openFile(f.path) } label: {
                    Label("Open in default app", systemImage: "arrow.up.forward.app")
                }
                Button { revealFile(f.path) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Divider()
            } else {
                if let action = vm.openInFilesTabAction {
                    Button { action(f.path) } label: {
                        Label("Open in Files tab", systemImage: "doc.text")
                    }
                }
                Button { revealFile(f.path) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Divider()
            }
            if f.status != .untracked {
                Button(role: .destructive) { requestDiscard(f.path) } label: {
                    Label("Discard changes", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    private func absoluteURL(_ path: String) -> URL {
        DiffPanelViewModel.absolutePathURL(cwd: vm.cwd, relativePath: path)
    }
    private func openFile(_ path: String) { NSWorkspace.shared.open(absoluteURL(path)) }
    private func revealFile(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([absoluteURL(path)])
    }

    /// UX-006: confirm before throwing away a file's edits — git checkout
    /// HEAD is irreversible for unsaved working-tree changes.
    private func requestDiscard(_ path: String) {
        let alert = NSAlert()
        alert.messageText = "Discard changes in this file?"
        alert.informativeText = "“\(path)” will be reverted to the last committed version. This cannot be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { vm.discardFile(path) }
    }

    /// IMP-012: a thin proportional add/del bar (≈24pt) that fills green
    /// for additions and red for deletions, sized by their relative weight.
    /// A pure-context (0/0) change collapses to nothing so it never shows an
    /// empty rail.
    private func changeBar(additions: Int, deletions: Int) -> some View {
        let total = additions + deletions
        let addFrac = total > 0 ? CGFloat(additions) / CGFloat(total) : 0
        return GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(DS.Palette.success)
                    .frame(width: geo.size.width * addFrac)
                Rectangle().fill(DS.Palette.danger)
            }
        }
        .frame(width: 24, height: 4)
        .clipShape(Capsule())
        .opacity(total > 0 ? 1 : 0)
        .help("+\(additions) −\(deletions)")
        .accessibilityHidden(true)
    }

    private func statusBadge(_ s: GitFileStatus) -> some View {
        Text(statusGlyph(s))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(statusColor(s))
            .frame(width: 16, height: 16)
            .background(statusColor(s).opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: Commit composer

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            HStack {
                Text("COMMIT")
                    .font(DS.Font.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer()
                Button(action: vm.suggestMessage) {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles").font(.system(size: 9))
                        Text("Suggest").font(DS.Font.caption2.weight(.medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.accent)
                .disabled(vm.summary.files.isEmpty)
                .help("Generate a fallback commit message (only when empty)")
                .accessibilityIdentifier("diff.commit.suggest")
            }
            .padding(.top, DS.Space.xs)
            TextField("Message (summarize the change)", text: $vm.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Font.monoSmall)
                .lineLimit(1...5)
                .padding(DS.Space.md)
                .background(DS.Palette.bg)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                )
                .accessibilityIdentifier("diff.commitMessage")
            // Amend checkbox: rewrites the last commit instead of creating a
            // new one. Useful in agent workflows where HEAD is a draft.
            // Resets automatically after each successful amend.
            Toggle(isOn: $vm.amendLastCommit) {
                HStack(spacing: DS.Space.xs) {
                    Text("Amend last commit")
                        .font(DS.Font.caption2.weight(.medium))
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(DS.Palette.warning)
                        .opacity(vm.amendLastCommit ? 1 : 0)
                }
                .foregroundColor(vm.amendLastCommit ? DS.Palette.warning : DS.Palette.textSecondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("Rewrite the last commit (git commit --amend). Cannot be undone.")
            .accessibilityIdentifier("diff.amend.checkbox")
            if let ok = vm.actionSuccess {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                        .foregroundColor(DS.Palette.success)
                    Text(ok).font(DS.Font.caption2.weight(.medium))
                        .foregroundColor(DS.Palette.success)
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
                .accessibilityIdentifier("diff.actionSuccess")
                .task(id: ok) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    withAnimation(DS.Motion.micro) { vm.actionSuccess = nil }
                }
            }
            Button(action: vm.commitSelected) {
                HStack(spacing: DS.Space.sm) {
                    if vm.isBusy {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                    }
                    Text(commitButtonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(commitDisabled || vm.isBusy)
            .opacity((commitDisabled || vm.isBusy) ? 0.45 : 1)
            .animation(DS.Motion.micro, value: commitDisabled)
            .animation(DS.Motion.micro, value: vm.isBusy)
            .accessibilityIdentifier("diff.commitButton")
            HStack(spacing: DS.Space.sm) {
                Button(action: vm.fetch) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "arrow.down.to.line").font(.system(size: 11))
                        Text("Fetch")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(vm.isBusy)
                .help("git fetch --prune (updates remote refs without changing local files)")
                .accessibilityIdentifier("diff.fetchButton")
                Button(action: vm.pull) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 11))
                        Text("Pull")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(vm.isBusy)
                .help("git pull --ff-only (fast-forward only)")
                .accessibilityIdentifier("diff.pullButton")
            }
            HStack(spacing: DS.Space.sm) {
                Button(action: vm.push) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "arrow.up.circle").font(.system(size: 11))
                        Text("Push")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(vm.isBusy)
                .help("git push (sets upstream if needed)")
                .accessibilityIdentifier("diff.pushButton")
                Button(action: vm.openPullRequest) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "arrow.triangle.pull").font(.system(size: 11))
                        Text("Pull Request")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .help("Open a PR/MR page for this branch")
                .accessibilityIdentifier("diff.prButton")
            }
            if commitDisabled {
                Text(commitHint)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
            }
        }
        .padding(DS.Space.lg)
        .background(DS.Palette.surface)
    }

    private var commitButtonTitle: String {
        if vm.amendLastCommit { return "Amend Last Commit" }
        let allCount = vm.summary.files.count
        let selCount = vm.selectedFiles.count
        if allCount == 0 { return "Commit" }
        if selCount > 0 {
            return "Commit \(selCount) selected file\(selCount == 1 ? "" : "s")"
        }
        return "Commit all \(allCount) file\(allCount == 1 ? "" : "s")"
    }

    private var commitDisabled: Bool {
        let emptyMessage = vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Amend only requires a non-empty message; the tree may be clean.
        if vm.amendLastCommit { return emptyMessage }
        return emptyMessage || vm.summary.files.isEmpty
    }

    private var commitHint: String {
        if vm.summary.files.isEmpty && !vm.amendLastCommit { return "Nothing to commit — working tree is clean." }
        if vm.selectedFiles.isEmpty { return "Enter a message to commit all changes." }
        return "Enter a message to commit the selected files."
    }

    // MARK: History

    @ViewBuilder
    private var historyView: some View {
        if vm.commits.isEmpty {
            DSEmptyState(icon: "clock", title: "No history",
                         subtitle: "No commits found for this repository.")
        } else {
            VStack(spacing: 0) {
                DSSectionHeader("History · \(vm.filteredCommits.count)\(vm.historyFilter.isEmpty ? "" : " (filtered)")")
                historyFilterField
                let displayed = vm.filteredCommits
                if displayed.isEmpty {
                    DSEmptyState(icon: "magnifyingglass", title: "No matches",
                                 subtitle: "No commits match the current filter.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            // PERF-013: iterate over `indices` so we don't allocate
                            // a fresh `Array(enumerated())` on every body pass.
                            ForEach(displayed.indices, id: \.self) { idx in
                                commitRow(displayed[idx], isFirst: idx == 0, isLast: idx == displayed.count - 1)
                            }
                        }
                        .padding(.horizontal, DS.Space.sm)
                        .padding(.bottom, DS.Space.xs)
                        // "Load 100 more" footer — only when filter is off
                        // (paging under a filter would be confusing) and when
                        // we fetched a full page (fewer means we hit the end).
                        if vm.historyFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && vm.commits.count == vm.historyLoadLimit {
                            Button {
                                vm.loadMoreHistory()
                            } label: {
                                HStack(spacing: DS.Space.xs) {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.system(size: 11))
                                    Text("Load 100 more")
                                }
                                .font(DS.Font.caption.weight(.medium))
                                .foregroundColor(DS.Palette.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DS.Space.md)
                            }
                            .buttonStyle(.plain)
                            .disabled(vm.isLoading)
                            .accessibilityIdentifier("diff.history.loadMore")
                            .help("Load the next 100 commits")
                        }
                        Spacer(minLength: DS.Space.sm)
                    }
                }
            }
        }
    }

    private func commitRow(_ c: GitCommit, isFirst: Bool, isLast: Bool) -> some View {
        let selected = vm.selectedCommit == c.hash
        return Button { vm.selectCommit(c.hash) } label: {
            HStack(alignment: .top, spacing: DS.Space.md) {
                // Timeline rail: connecting line + node dot.
                ZStack {
                    VStack(spacing: 0) {
                        Rectangle().fill(DS.Palette.line)
                            .frame(width: DS.Border.hairline)
                            .opacity(isFirst ? 0 : 1)
                        Rectangle().fill(DS.Palette.line)
                            .frame(width: DS.Border.hairline)
                            .opacity(isLast ? 0 : 1)
                    }
                    Circle()
                        .fill(selected ? DS.Palette.accent : DS.Palette.textTertiary)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(DS.Palette.surface, lineWidth: 2))
                }
                .frame(width: 8)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(c.subject)
                        .font(DS.Font.bodyDense.weight(.medium))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(2).truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: DS.Space.sm) {
                        Text(c.shortHash)
                            .font(DS.Font.caption2.weight(.semibold).monospaced())
                            .foregroundColor(DS.Palette.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(DS.Palette.accent.opacity(0.14))
                            .clipShape(Capsule())
                        Text(c.author)
                            .font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(c.date)
                            .font(DS.Font.caption2.monospacedDigit())
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                }
            }
        }
        .buttonStyle(GitRowButtonStyle(selected: selected))
        .help("\(c.shortHash) — \(c.subject)")
        .accessibilityIdentifier("diff.commit.\(c.shortHash)")
    }

    // MARK: Diff viewer

    private var diffBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            diffToolbar
            if vm.rawDiff.isEmpty {
                if vm.isLoading {
                    DSEmptyState(
                        icon: "doc.text.magnifyingglass",
                        title: "Loading diff…",
                        subtitle: "Running git — this can take a moment on large repos."
                    )
                    .overlay(alignment: .center) {
                        ProgressView().controlSize(.small).padding(.top, 64)
                    }
                } else {
                    DSEmptyState(
                        icon: "doc.text.magnifyingglass",
                        title: vm.mode == .history ? "Select a commit" : "Select a file",
                        subtitle: vm.mode == .history
                            ? "Pick a commit from History to inspect its full diff."
                            : "Pick a changed file to view its diff side by side."
                    )
                }
            } else {
                ScrollView([.vertical, vm.wordWrap ? .init() : .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(vm.styledDiff)
                            .font(DS.Font.mono)
                            .textSelection(.enabled)
                            .padding(DS.Space.lg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("diff.body")
                        if vm.diffTruncated {
                            Text("Diff truncated — too large to render fully. Use Copy diff for the complete text.")
                                .font(DS.Font.caption2)
                                .foregroundColor(DS.Palette.textTertiary)
                                .padding(.horizontal, DS.Space.lg)
                                .padding(.bottom, DS.Space.lg)
                        }
                    }
                }
                .background(DS.Palette.bg)
                .overlay(alignment: .topTrailing) {
                    if vm.isLoading {
                        ProgressView().controlSize(.small).padding(DS.Space.md)
                    }
                }
            }
        }
        .onChange(of: vm.ignoreWhitespace) { _ in vm.reloadDiff() }
    }

    private var diffToolbar: some View {
        HStack(spacing: DS.Space.md) {
            if let p = vm.selectedPath {
                statusBadge(statusForPath(p))
                Text(p)
                    .font(DS.Font.monoSmall.weight(.medium))
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1).truncationMode(.middle)
            } else if let h = vm.selectedCommit {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11)).foregroundColor(DS.Palette.accent)
                Text(String(h.prefix(7)))
                    .font(DS.Font.monoSmall.weight(.medium))
                    .foregroundColor(DS.Palette.text)
            } else {
                Text("Diff")
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            Spacer(minLength: DS.Space.lg)
            wsToggle("Wrap", $vm.wordWrap,
                     icon: vm.wordWrap ? "arrow.turn.down.left" : "arrow.left.and.right",
                     identifier: "diff.toggle.wrap")
            wsToggle("Ignore WS", $vm.ignoreWhitespace,
                     icon: nil, identifier: "diff.toggle.ignoreWS")
            Button(action: copyDiff) {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textSecondary)
            .disabled(vm.rawDiff.isEmpty)
            .help("Copy diff")
            .accessibilityLabel("Copy diff to clipboard")
            .accessibilityIdentifier("diff.copyButton")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .frame(minHeight: 34)
        .dsBar(edge: .bottom)
    }

    /// UX-011: the optional `icon` reflects the active mode in the toolbar
    /// (wrap vs horizontal-scroll) so the effect isn't only conveyed by the
    /// subtle pill fill.
    private func wsToggle(_ title: String, _ binding: Binding<Bool>, icon: String? = nil, identifier: String) -> some View {
        Button { binding.wrappedValue.toggle() } label: {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
                Text(title)
            }
                .font(DS.Font.caption2.weight(.medium))
                .foregroundColor(binding.wrappedValue ? DS.Palette.onAccent : DS.Palette.textSecondary)
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 3)
                .background(binding.wrappedValue ? DS.Palette.accent : DS.Palette.surfaceRaised)
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(DS.Palette.line,
                                           lineWidth: binding.wrappedValue ? 0 : DS.Border.hairline)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(binding.wrappedValue ? .isSelected : [])
        .accessibilityIdentifier(identifier)
        .help(title == "Wrap" ? "Toggle line wrapping" : "Ignore whitespace in diff")
    }

    private func copyDiff() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(vm.rawDiff, forType: .string)
    }

    private func statusForPath(_ p: String) -> GitFileStatus {
        vm.summary.files.first { $0.path == p }?.status ?? .modified
    }

    private func statusGlyph(_ s: GitFileStatus) -> String {
        switch s {
        case .added: return "A"; case .modified: return "M"; case .deleted: return "D"
        case .renamed: return "R"; case .copied: return "C"; case .untracked: return "?"
        case .unknown: return "•"
        }
    }
    private func statusColor(_ s: GitFileStatus) -> Color {
        switch s {
        case .added, .untracked: return DS.Palette.success
        case .deleted: return DS.Palette.danger
        case .renamed, .copied: return DS.Palette.warning
        default: return DS.Palette.textSecondary
        }
    }
}

@MainActor
public final class DiffPanelSurface: NSObject, Surface {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    public let viewModel: DiffPanelViewModel

    public init(workspaceID: WorkspaceID, cwd: String, title: String = "Diff",
                settings: SettingsStore? = nil,
                openInFilesTabAction: ((String) -> Void)? = nil) {
        self.descriptor = SurfaceDescriptor(type: .rightSidebarTool, title: title, iconName: "doc.text.magnifyingglass",
                                            metadata: ["workspace": workspaceID.value.uuidString, "cwd": cwd, "tool": "diff"])
        self.viewModel = DiffPanelViewModel(cwd: cwd, settings: settings)
        self.viewModel.openInFilesTabAction = openInFilesTabAction
        let host = NSHostingView(rootView: DiffPanelView(vm: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        self.view = container
        super.init()
    }

    public func focus() { view.window?.makeFirstResponder(view) }
    public func unfocus() {}
    public func close() {}
    /// Called by the shell when the panel becomes visible so stale state is
    /// never the first thing the user sees after switching tabs or windows.
    public func didBecomeVisible() { viewModel.didBecomeVisible() }
    public func sendText(_ text: String) {}
    public func readText() -> String { viewModel.rawDiff }
    public func snapshot() -> [String: String] { ["selected": viewModel.selectedPath ?? ""] }
}
