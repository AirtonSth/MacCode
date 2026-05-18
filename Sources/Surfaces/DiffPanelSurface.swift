import Foundation
import AppKit
import SwiftUI
import CoreModel
import AgentRuntime
import Persistence
import DesignSystemKit

public enum GitPanelMode: String, CaseIterable, Sendable {
    case changes, history
}

@MainActor
public final class DiffPanelViewModel: ObservableObject {
    @Published public var cwd: String
    @Published public var summary: GitSummary
    @Published public var selectedPath: String?
    @Published public var rawDiff: String = ""
    @Published public var wordWrap: Bool = false { didSet { persistPrefs() } }
    @Published public var ignoreWhitespace: Bool = false { didSet { persistPrefs() } }

    @Published public var branches: GitBranches
    @Published public var commits: [GitCommit] = []
    @Published public var commitMessage: String = ""
    @Published public var mode: GitPanelMode = .changes
    @Published public var selectedCommit: String?
    @Published public var lastError: String?
    private var historyLoaded = false
    private let settings: SettingsStore?

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

    public func refresh() {
        let cwd = self.cwd
        DispatchQueue.global().async { [weak self] in
            let s = GitDiff.summary(in: cwd)
            DispatchQueue.main.async { self?.summary = s }
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
        DispatchQueue.global().async { [weak self] in
            let c = GitDiff.log(in: cwd)
            DispatchQueue.main.async { self?.commits = c }
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

    /// Re-fetch the diff for whatever is currently selected. Called on
    /// selection change and whenever the ignore-whitespace toggle flips,
    /// so the toggle has a visible effect instead of being inert.
    public func reloadDiff() {
        let cwd = self.cwd
        let ws = self.ignoreWhitespace
        let path = self.selectedPath
        let commit = self.selectedCommit
        guard path != nil || commit != nil else { rawDiff = ""; return }
        DispatchQueue.global().async { [weak self] in
            let d: String
            if let p = path {
                d = GitDiff.diff(in: cwd, path: p, ignoreWhitespace: ws)
            } else if let h = commit {
                d = GitDiff.commitDiff(in: cwd, hash: h, ignoreWhitespace: ws)
            } else {
                d = ""
            }
            DispatchQueue.main.async { self?.rawDiff = d }
        }
    }

    public func switchBranch(_ name: String) {
        runAction { GitDiff.checkout(in: $0, branch: name) }
    }

    public func newBranch(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        runAction { GitDiff.createBranch(in: $0, name: n) }
    }

    public func commit() {
        let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        runAction(clearMessageOnOK: true) { GitDiff.commit(in: $0, message: msg) }
    }

    /// D4: fill the composer with a generated fallback subject.
    public func suggestMessage() {
        commitMessage = GitDiff.suggestCommitMessage(summary)
    }

    /// D2: push the current branch (sets upstream if needed).
    public func push() {
        runAction { GitDiff.push(in: $0) }
    }

    /// D2: open a PR/MR page for the current branch in the browser.
    public func openPullRequest() {
        guard let url = GitDiff.pullRequestURL(in: cwd), let u = URL(string: url) else {
            lastError = "No remote 'origin' / branch to open a pull request for."
            return
        }
        NSWorkspace.shared.open(u)
    }

    /// Runs a mutating git op off the main thread, then re-reads summary,
    /// branches and log so the panel always reflects post-op truth.
    /// Failures surface in `lastError` — never silent (CLAUDE.md Rule 6).
    private func runAction(clearMessageOnOK: Bool = false,
                           _ op: @escaping @Sendable (String) -> GitActionResult) {
        let cwd = self.cwd
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
                if r.ok {
                    self.lastError = nil
                    if clearMessageOnOK { self.commitMessage = "" }
                } else {
                    self.lastError = r.message
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
    public init(vm: DiffPanelViewModel) { self.vm = vm }

    public var body: some View {
        HSplitView {
            leftColumn.frame(minWidth: 280, idealWidth: 320)
            diffBody.frame(minWidth: 440)
        }
        .background(DS.Palette.bg)
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
                DSIconButton("arrow.clockwise", help: "Refresh") {
                    vm.refresh(); vm.loadBranches(); vm.loadHistory(force: true)
                }
                .accessibilityLabel("Refresh git status")
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
                Button { vm.switchBranch(b) } label: {
                    if b == vm.branches.current {
                        Label(b, systemImage: "checkmark")
                    } else {
                        Text(b)
                    }
                }
            }
            Divider()
            Button {
                newBranchName = ""
                withAnimation(DS.Motion.standard) { showNewBranchField = true }
            } label: {
                Label("New branch…", systemImage: "plus")
            }
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
    }

    private var newBranchComposer: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Palette.accent)
            TextField("new-branch-name", text: $newBranchName)
                .textFieldStyle(.plain)
                .font(DS.Font.monoSmall)
                .onSubmit(confirmNewBranch)
            Button("Create", action: confirmNewBranch)
                .buttonStyle(DSSecondaryButtonStyle())
                .controlSize(.small)
                .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button {
                withAnimation(DS.Motion.standard) { showNewBranchField = false }
                newBranchName = ""
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Cancel new branch")
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
    }

    private func confirmNewBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        vm.newBranch(name)
        newBranchName = ""
        withAnimation(DS.Motion.standard) { showNewBranchField = false }
    }

    private func errorBanner(_ msg: String) -> some View {
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
            Button { withAnimation(DS.Motion.micro) { vm.lastError = nil } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Dismiss error")
            .help("Dismiss error")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .background(DS.Palette.danger.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Palette.danger.opacity(0.4)).frame(height: DS.Border.hairline)
        }
        .transition(.opacity)
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
        let comps = f.path.split(separator: "/").map(String.init)
        let file = comps.last ?? f.path
        let dir = comps.dropLast().joined(separator: "/")
        return Button { vm.selectFile(f.path) } label: {
            HStack(spacing: DS.Space.md) {
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
                } else {
                    Text("binary")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                }
            }
        }
        .buttonStyle(GitRowButtonStyle(selected: selected))
        .help(f.path)
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
                .help("Generate a fallback commit message")
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
            Button(action: vm.commit) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                    Text(commitButtonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(commitDisabled)
            .opacity(commitDisabled ? 0.45 : 1)
            .animation(DS.Motion.micro, value: commitDisabled)
            HStack(spacing: DS.Space.sm) {
                Button(action: vm.push) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "arrow.up.circle").font(.system(size: 11))
                        Text("Push")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .help("git push (sets upstream if needed)")
                Button(action: vm.openPullRequest) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "arrow.triangle.pull").font(.system(size: 11))
                        Text("Pull Request")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .help("Open a PR/MR page for this branch")
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
        let n = vm.summary.files.count
        return n == 0 ? "Commit" : "Commit \(n) file\(n == 1 ? "" : "s")"
    }

    private var commitDisabled: Bool {
        vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || vm.summary.files.isEmpty
    }

    private var commitHint: String {
        if vm.summary.files.isEmpty { return "Nothing to commit — working tree is clean." }
        return "Enter a message to commit all changes."
    }

    // MARK: History

    @ViewBuilder
    private var historyView: some View {
        if vm.commits.isEmpty {
            DSEmptyState(icon: "clock", title: "No history",
                         subtitle: "No commits found for this repository.")
        } else {
            VStack(spacing: 0) {
                DSSectionHeader("History · \(vm.commits.count)")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(vm.commits.enumerated()), id: \.element.hash) { idx, c in
                            commitRow(c, isFirst: idx == 0, isLast: idx == vm.commits.count - 1)
                        }
                    }
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.bottom, DS.Space.sm)
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
    }

    // MARK: Diff viewer

    private var diffBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            diffToolbar
            if vm.rawDiff.isEmpty {
                DSEmptyState(
                    icon: "doc.text.magnifyingglass",
                    title: vm.mode == .history ? "Select a commit" : "Select a file",
                    subtitle: vm.mode == .history
                        ? "Pick a commit from History to inspect its full diff."
                        : "Pick a changed file to view its diff side by side."
                )
            } else {
                ScrollView([.vertical, vm.wordWrap ? .init() : .horizontal]) {
                    Text(displayDiff)
                        .font(DS.Font.mono)
                        .textSelection(.enabled)
                        .padding(DS.Space.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(DS.Palette.bg)
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
            wsToggle("Wrap", $vm.wordWrap)
            wsToggle("Ignore WS", $vm.ignoreWhitespace)
            Button(action: copyDiff) {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textSecondary)
            .disabled(vm.rawDiff.isEmpty)
            .help("Copy diff")
            .accessibilityLabel("Copy diff to clipboard")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .frame(minHeight: 34)
        .dsBar(edge: .bottom)
    }

    private func wsToggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Button { binding.wrappedValue.toggle() } label: {
            Text(title)
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
        .help(title == "Wrap" ? "Toggle line wrapping" : "Ignore whitespace in diff")
    }

    private func copyDiff() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(vm.rawDiff, forType: .string)
    }

    private func statusForPath(_ p: String) -> GitFileStatus {
        vm.summary.files.first { $0.path == p }?.status ?? .modified
    }

    private var displayDiff: AttributedString {
        var out = AttributedString()
        for line in vm.rawDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            var seg = AttributedString(String(line) + "\n")
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                seg.foregroundColor = DS.Palette.success
                seg.backgroundColor = DS.Palette.success.opacity(0.08)
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                seg.foregroundColor = DS.Palette.danger
                seg.backgroundColor = DS.Palette.danger.opacity(0.08)
            } else if line.hasPrefix("@@") {
                seg.foregroundColor = DS.Palette.accent
                seg.backgroundColor = DS.Palette.accent.opacity(0.08)
            } else if line.hasPrefix("diff --git") || line.hasPrefix("+++") || line.hasPrefix("---") {
                seg.foregroundColor = DS.Palette.warning
            } else {
                seg.foregroundColor = DS.Palette.textSecondary
            }
            out.append(seg)
        }
        return out
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

    public init(workspaceID: WorkspaceID, cwd: String, title: String = "Diff", settings: SettingsStore? = nil) {
        self.descriptor = SurfaceDescriptor(type: .rightSidebarTool, title: title, iconName: "doc.text.magnifyingglass",
                                            metadata: ["workspace": workspaceID.value.uuidString, "cwd": cwd, "tool": "diff"])
        self.viewModel = DiffPanelViewModel(cwd: cwd, settings: settings)
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
    public func sendText(_ text: String) {}
    public func readText() -> String { viewModel.rawDiff }
    public func snapshot() -> [String: String] { ["selected": viewModel.selectedPath ?? ""] }
}
