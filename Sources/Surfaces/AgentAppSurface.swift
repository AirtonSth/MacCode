import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import CoreModel
import Persistence
import AgentRuntime
import DesignSystemKit

@MainActor
public final class AgentAppViewModel: ObservableObject, AgentRunObserver {
    @Published public var threads: [AgentThread] = []
    @Published public var selectedThreadId: AgentThreadID?
    @Published public var messages: [AgentMessage] = []
    @Published public var timeline = AssistantTimelineState()
    @Published public var timelineUpdateTick: Int = 0
    @Published public var focusTick: Int = 0
    @Published public var prompt: String = ""
    @Published public var provider: AgentProvider = .codex
    @Published public var model: String = "gpt-5.5"
    @Published public var availableModels: [AgentModelDescriptor] = []
    @Published public var permissionMode: AgentPermissionMode = .supervised
    @Published public var reasoningEffort: AgentReasoningEffort = .medium
    @Published public var status: AgentRunStatus = .pending
    @Published public var statusMessage: String = ""
    @Published public var currentRunId: AgentRunID?
    @Published public var hasUnreadActivity: Bool = false
    @Published public var showPlanSidebar: Bool = false
    @Published public var planNotes: String = ""
    /// C1: git branch + working-tree summary of the agent's dir, for the
    /// composer context strip ("N files changed +A −B").
    @Published public var gitBranch: String?
    @Published public var gitSummary: GitSummary?
    /// Wired by AppCommandRouter — "Review here" opens a Git/Diff surface.
    public var onReviewRequested: (() -> Void)?
    /// A3: fired when a run starts/ends so the tab + workspace chrome can
    /// show/hide a spinner (AppKit tab strip / sidebar don't observe VM).
    public var onRunStateChange: (() -> Void)?
    /// Fired when a run completes so the workspace can move up in its
    /// pinned/unpinned group.
    public var onRunCompleted: (() -> Void)?
    /// B3: file paths attached to the next message (composer chips).
    @Published public var attachments: [String] = []
    /// When the active run started — drives the "Working for Xs" line.
    @Published public var runStartedAt: Date?

    public let workspaceID: WorkspaceID
    public let cwd: String
    public let coordinator: AgentRunCoordinator
    public let threadRepo: AgentThreadRepository
    public let messageRepo: AgentMessageRepository

    public init(
        workspaceID: WorkspaceID,
        cwd: String,
        coordinator: AgentRunCoordinator,
        threadRepo: AgentThreadRepository,
        messageRepo: AgentMessageRepository
    ) {
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.coordinator = coordinator
        self.threadRepo = threadRepo
        self.messageRepo = messageRepo
        self.coordinator.addObserver(self)
        reloadThreads()
        loadGitBranch()
    }

    public func loadGitBranch() {
        let cwd = self.cwd
        DispatchQueue.global().async { [weak self] in
            let b = GitDiff.branches(in: cwd).current
            let s = GitDiff.summary(in: cwd)
            DispatchQueue.main.async {
                self?.gitBranch = b
                self?.gitSummary = s.isGitRepo ? s : nil
            }
        }
    }

    /// Maps an in-flight run back to its thread so a completion can mark
    /// the right thread unread even after the user navigated away (B6).
    private var runThreads: [AgentRunID: AgentThreadID] = [:]

    public func reloadThreads() {
        threads = (try? threadRepo.list(workspaceId: workspaceID)) ?? []
        if selectedThreadId == nil, let first = threads.first {
            selectThread(first.id)
        }
    }

    public func selectThread(_ id: AgentThreadID) {
        selectedThreadId = id
        if let t = threads.first(where: { $0.id == id }) {
            provider = t.provider
            model = t.model
            status = t.status
            if t.status == .running {
                if runStartedAt == nil { runStartedAt = Date() }
            } else {
                currentRunId = nil
                runStartedAt = nil
            }
        }
        // B6: opening a thread marks it read (persist + reflect in the rail
        // without re-querying, which would recurse through reloadThreads).
        if var t = try? threadRepo.get(id: id), t.hasUnread {
            t.hasUnread = false
            try? threadRepo.upsert(t)
        }
        if let idx = threads.firstIndex(where: { $0.id == id }), threads[idx].hasUnread {
            threads[idx].hasUnread = false
        }
        messageWindow = Self.baseMessageWindow
        loadWindow(id)
        timeline = AssistantTimelineState()
        for event in coordinator.latestStreamEvents(threadId: id) {
            timeline.apply(event)
        }
        suppressPersistedFinalDuplicatedByTimeline()
        timelineUpdateTick = 0
    }

    // MARK: B4 — bounded message window

    static let baseMessageWindow = 50
    private var messageWindow = AgentAppViewModel.baseMessageWindow
    @Published public var hasMoreOlder: Bool = false

    private func loadWindow(_ id: AgentThreadID) {
        let total = (try? messageRepo.count(threadId: id)) ?? 0
        messages = ((try? messageRepo.listRecent(threadId: id, limit: messageWindow)) ?? [])
            .map(Self.displayMessage)
        hasMoreOlder = total > messages.count
    }

    private static func displayMessage(_ message: AgentMessage) -> AgentMessage {
        var m = message
        m.content = AssistantTimelineState.cappedText(m.content)
        return m
    }

    private func suppressPersistedFinalDuplicatedByTimeline() {
        guard let liveFinal = timeline.latestAssistantMessage,
              let last = messages.last,
              last.role == .assistant,
              last.content == liveFinal else { return }
        messages.removeLast()
    }

    public func loadEarlierMessages() {
        guard let id = selectedThreadId else { return }
        messageWindow += Self.baseMessageWindow
        loadWindow(id)
    }

    /// B7: count of threads with an in-flight run, for the rail header.
    public var activeThreadCount: Int { threads.filter { $0.status == .running }.count }

    /// C7: the most recent plan the agent proposed in this thread's
    /// timeline (t3code PlanSidebar — proposed-plan tracking).
    public var latestPlanText: String? {
        for turn in timeline.turns.reversed() {
            if let plan = turn.items.last(where: { $0.type == .plan }) {
                let t = plan.body.isEmpty ? (plan.summary ?? "") : plan.body
                return t.isEmpty ? nil : t
            }
        }
        return nil
    }

    public func loadModels() async {
        let runner: AgentProviderRunner = provider == .codex ? CodexRunner() : ClaudeRunner()
        let m = await runner.listModels()
        await MainActor.run {
            self.availableModels = m
            // B8: a provider switch must leave a model valid for that
            // provider — never a stale id from the other provider.
            if !m.isEmpty, !m.contains(where: { $0.id == self.model }) {
                self.model = m.first?.id ?? self.model
            }
        }
    }

    /// A1: the provider (source) is fixed once the thread has a
    /// conversation — only model/effort stay changeable after that.
    public var providerLocked: Bool { selectedThreadId != nil && !messages.isEmpty }

    /// Persist the chosen provider/model onto the selected thread so a
    /// resumed run uses the right source + model.
    public func persistThreadConfig() {
        guard let id = selectedThreadId, var t = try? threadRepo.get(id: id) else { return }
        t.provider = provider
        t.model = model
        t.updatedAt = Date()
        try? threadRepo.upsert(t)
        if let i = threads.firstIndex(where: { $0.id == id }) {
            threads[i].provider = provider
            threads[i].model = model
        }
    }

    public func createThread(title: String) {
        let t = AgentThread(workspaceId: workspaceID, title: title, provider: provider, model: model)
        try? threadRepo.upsert(t)
        reloadThreads()
        selectThread(t.id)
    }

    public func renameThread(_ id: AgentThreadID, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var t = try? threadRepo.get(id: id) else { return }
        t.title = title
        t.updatedAt = Date()
        try? threadRepo.upsert(t)
        reloadThreads()
    }

    /// A2: set/clear a thread's swatch color (empty string clears).
    public func setThreadColor(_ id: AgentThreadID, _ color: String) {
        guard var t = try? threadRepo.get(id: id) else { return }
        t.color = color.isEmpty ? nil : color
        t.updatedAt = Date()
        try? threadRepo.upsert(t)
        reloadThreads()
    }

    public func setThreadPinned(_ id: AgentThreadID, _ pinned: Bool) {
        try? threadRepo.setPinned(id: id, pinned: pinned)
        reloadThreads()
    }

    public func reorderThread(_ id: AgentThreadID, before target: AgentThreadID) {
        guard id != target,
              let targetIndex = threads.firstIndex(where: { $0.id == target }) else { return }
        try? threadRepo.reorder(id: id, position: targetIndex)
        reloadThreads()
    }

    public func deleteThread(_ id: AgentThreadID) {
        try? threadRepo.delete(id: id)
        if selectedThreadId == id {
            selectedThreadId = nil
        messages = []
        timeline = AssistantTimelineState()
        timelineUpdateTick = 0
        }
        reloadThreads()
    }

    public func deleteThreads(_ ids: Set<AgentThreadID>) {
        guard !ids.isEmpty else { return }
        try? threadRepo.delete(ids: Array(ids))
        if let selectedThreadId, ids.contains(selectedThreadId) {
            self.selectedThreadId = nil
        messages = []
        timeline = AssistantTimelineState()
        timelineUpdateTick = 0
        }
        reloadThreads()
    }

    /// Derive a concise thread title from the first user message: first
    /// non-empty line, trimmed, clipped, stripped of trailing punctuation.
    public static func deriveTitle(from text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(trimmed.prefix(48))
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t.-:#*"))
        return clipped.isEmpty ? "New thread" : clipped
    }

    public func statusSummary() -> String {
        let t = threads.first(where: { $0.id == selectedThreadId })?.title ?? "—"
        return "provider=\(provider.rawValue) model=\(model) permission=\(permissionMode.rawValue) reasoning=\(reasoningEffort.rawValue) status=\(status.rawValue) thread=\(t)"
    }

    private func systemNote(_ text: String) {
        guard let tid = selectedThreadId else { return }
        let m = AgentMessage(threadId: tid, role: .system, content: text)
        messages.append(m)
        try? messageRepo.append(m)
    }

    /// `/fork` — branch a new thread from the current one, copying its
    /// message history, then select it (remotecode.io `/fork` parity).
    public func forkCurrentThread() {
        guard let tid = selectedThreadId,
              let src = threads.first(where: { $0.id == tid }) else { return }
        let copy = AgentThread(workspaceId: workspaceID, title: "\(src.title) (fork)",
                               provider: src.provider, model: src.model)
        try? threadRepo.upsert(copy)
        for m in (try? messageRepo.list(threadId: tid)) ?? [] {
            try? messageRepo.append(AgentMessage(threadId: copy.id, role: m.role, content: m.content))
        }
        reloadThreads()
        selectThread(copy.id)
    }

    /// Intercept `/clear /fork /model /plan /status` before they reach the
    /// provider. Returns true if the input was a (handled) command.
    @discardableResult
    public func handleSlashCommand(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("/") else { return false }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts.first?.lowercased() ?? ""
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch cmd {
        case "clear":
            createThread(title: "New thread")
        case "fork":
            forkCurrentThread()
        case "model":
            if !arg.isEmpty, let m = availableModels.first(where: {
                $0.id.localizedCaseInsensitiveContains(arg) || $0.label.localizedCaseInsensitiveContains(arg)
            }) {
                model = m.id
                systemNote("Model → \(m.label)")
            } else {
                let names = availableModels.map { $0.label }.joined(separator: ", ")
                systemNote(names.isEmpty ? "No models loaded yet." : "Models: \(names)")
            }
        case "plan":
            showPlanSidebar.toggle()
            permissionMode = .supervised
            systemNote("Plan mode \(showPlanSidebar ? "on" : "off") · permission: supervised")
        case "status":
            systemNote(statusSummary())
        default:
            systemNote("Unknown command: /\(cmd)")
        }
        return true
    }

    public func addAttachments(_ paths: [String]) {
        for p in paths where !attachments.contains(p) { attachments.append(p) }
    }
    public func removeAttachment(_ path: String) {
        attachments.removeAll { $0 == path }
    }

    public func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        // Slash commands never reach the provider.
        if text.hasPrefix("/") {
            prompt = ""
            _ = handleSlashCommand(text)
            return
        }
        if selectedThreadId == nil {
            createThread(title: "New thread")
        }
        guard let tid = selectedThreadId else { return }
        // B5: title a still-default thread from its first message.
        if let t = threads.first(where: { $0.id == tid }),
           (t.title == "New thread" || t.title.isEmpty),
           ((try? messageRepo.list(threadId: tid))?.isEmpty ?? true) {
            renameThread(tid, to: Self.deriveTitle(from: text))
        }
        prompt = ""
        timeline = AssistantTimelineState()
        timelineUpdateTick = 0
        // B3: fold attachment paths into the prompt so the agent (which
        // has fs access per permission mode) can read them; show a friendly
        // chip summary in the transcript.
        let attached = attachments
        attachments = []
        let composed = attached.isEmpty ? text
            : text + "\n\n[Attached files]\n" + attached.map { "- \($0)" }.joined(separator: "\n")
        let display = attached.isEmpty ? text
            : text + "\n\n📎 " + attached.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        // The coordinator is the single writer of run messages — mirror
        // the user message in-memory only (no double-persist).
        messages.append(AgentMessage(threadId: tid, role: .user, content: AssistantTimelineState.cappedText(display)))
        let req = AgentRunRequest(
            threadId: tid,
            provider: provider,
            model: model,
            cwd: cwd,
            prompt: composed,
            providerThreadId: threads.first(where: { $0.id == tid })?.providerThreadId,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort
        )
        do {
            let runId = try await coordinator.startRun(req)
            await MainActor.run {
                self.currentRunId = runId
                self.runThreads[runId] = tid
                self.status = .running
                self.runStartedAt = Date()
                self.onRunStateChange?()
            }
        } catch {
            await MainActor.run { self.statusMessage = "Failed to start: \(error)"; self.status = .failed }
        }
    }

    public func stop() {
        if let r = currentRunId {
            coordinator.stopRun(r)
        }
        if let tid = selectedThreadId {
            coordinator.stopRun(threadId: tid)
        }
    }

    private func persistFinalAssistantIfMissing(_ text: String, threadId: AgentThreadID) {
        let text = AssistantTimelineState.cappedText(text)
        let existing = (try? messageRepo.list(threadId: threadId)) ?? []
        guard !existing.contains(where: { $0.role == .assistant && $0.content == text }) else { return }
        try? messageRepo.append(AgentMessage(threadId: threadId, role: .assistant, content: text))
    }

    // MARK: AgentRunObserver

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {
        Task { @MainActor in
            guard threadId == self.selectedThreadId else { return }
            self.currentRunId = run
            self.runThreads[run] = threadId
            if self.status != .running { self.status = .running }
            self.timeline.apply(event)
            self.timelineUpdateTick &+= 1
        }
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
        Task { @MainActor in
            let finishedTid = threadId
            self.runThreads[runId] = nil
            if status == .completed, let msg = finalMessage, !msg.isEmpty {
                // The coordinator is normally the persistence owner, but
                // live provider completions can arrive after stream drain on
                // a background handler. Keep the restart contract here too.
                self.persistFinalAssistantIfMissing(msg, threadId: finishedTid)
            }
            if status == .completed, finalMessage != nil, finishedTid != self.selectedThreadId,
               var t = try? self.threadRepo.get(id: finishedTid) {
                // B6: finished on a thread the user left → mark unread.
                // The selected thread already shows the reply via the live
                // turn items, so we do NOT mirror it into `messages`
                // (that caused the answer to render two/three times).
                t.hasUnread = true
                try? self.threadRepo.upsert(t)
            }
            if finishedTid == self.selectedThreadId {
                self.status = status
                self.currentRunId = nil
                self.runStartedAt = nil
            }
            self.reloadThreads()
            self.loadGitBranch()   // the run may have changed the tree
            if status == .completed {
                self.onRunCompleted?()
            }
            self.onRunStateChange?()
        }
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {
        Task { @MainActor in
            let threadWorkspace = try? self.threadRepo.get(id: threadId)?.workspaceId
            guard threadWorkspace == self.workspaceID else { return }
            self.reloadThreads()
            if threadId == self.selectedThreadId {
                self.status = status
                if status == .running { self.currentRunId = runId }
                if status == .running, self.runStartedAt == nil { self.runStartedAt = Date() }
            }
            self.onRunStateChange?()
        }
    }
}

public struct AgentAppView: View {
    @ObservedObject var vm: AgentAppViewModel
    @State private var renamingThreadId: AgentThreadID?
    @State private var renameText: String = ""
    @State private var expandedTools: Set<String> = []
    @State private var selectedThreadIds: Set<AgentThreadID> = []
    @State private var lastSelectedThreadId: AgentThreadID?
    @State private var draggingThreadId: AgentThreadID?
    @State private var timelineSticksToBottom = true
    @State private var showScrollDownButton = false
    @State private var composerEditorHeight: CGFloat = PromptComposerEditor.minHeight

    public init(vm: AgentAppViewModel) { self.vm = vm }

    public var body: some View {
        HSplitView {
            threadRail
                .frame(minWidth: 150, idealWidth: 165, maxWidth: 220)
            conversationColumn
                .frame(minWidth: 460)
            if vm.showPlanSidebar {
                planSidebar.frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            }
        }
        .background(DS.Palette.bg)
        .task { await vm.loadModels() }
        .onDeleteCommand { deleteSelectedThreads() }
    }

    // MARK: Thread rail

    private var threadRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader(vm.activeThreadCount > 0 ? "Threads · \(vm.activeThreadCount) active" : "Threads",
                            trailing: AnyView(
                DSIconButton("plus", help: "New thread") { vm.createThread(title: "New thread") }
            ))
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            if vm.threads.isEmpty {
                DSEmptyState(icon: "bubble.left.and.bubble.right",
                             title: "No threads",
                             subtitle: "Send a prompt to start a Codex or Claude thread.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                        ForEach(vm.threads, id: \.id) { t in threadRow(t) }
                    }.padding(DS.Space.sm)
                }
                .focusable()
            }
        }
        .background(DS.Palette.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }

    @ViewBuilder
    private func threadRow(_ t: AgentThread) -> some View {
        if renamingThreadId == t.id {
            renameRow(t)
        } else {
            let selected = vm.selectedThreadId == t.id
            let multiSelected = selectedThreadIds.contains(t.id)
            let running = t.status == .running || (selected && vm.status == .running)
            Button { selectThreadRow(t) } label: {
                HStack(spacing: DS.Space.md) {
                    if running {
                        // A3: spinner while this thread has a run in flight.
                        ProgressView().controlSize(.small).scaleEffect(0.5)
                            .frame(width: 8, height: 8)
                    } else {
                        Image(systemName: t.pinned ? "pin.fill" : "circle.fill")
                            .font(.system(size: t.pinned ? 9 : 7, weight: .semibold))
                            .foregroundColor(TabColor.from(t.color).map { Color(hex: $0.hex) }
                                             ?? (t.status == .failed ? DS.Palette.danger : DS.Palette.textTertiary))
                            .frame(width: 8, height: 8)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(DS.Font.bodyDense.weight(t.hasUnread ? .semibold : .regular))
                            .foregroundColor(DS.Palette.text).lineLimit(1)
                        Text("\(t.provider.rawValue) · \(t.model)")
                            .font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if t.hasUnread {
                        Circle().fill(DS.Palette.accent).frame(width: 7, height: 7)
                            .accessibilityLabel("Unread activity")
                    }
                    if multiSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Palette.accent)
                    }
                }
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.sm)
                .background((selected || multiSelected) ? DS.Palette.selection : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t.title)
            .onDrag {
                draggingThreadId = t.id
                return NSItemProvider(object: t.id.value.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: AgentThreadDropDelegate(vm: vm, draggingThreadId: $draggingThreadId, target: t))
            .contextMenu {
                Button(t.pinned ? "Unpin" : "Pin") { vm.setThreadPinned(t.id, !t.pinned) }
                Divider()
                Button("Rename…") { renameText = t.title; renamingThreadId = t.id }
                Menu("Color") {
                    Button("None") { vm.setThreadColor(t.id, "") }
                    ForEach(TabColor.allCases, id: \.self) { c in
                        Button { vm.setThreadColor(t.id, c.rawValue) } label: {
                            TabColorMenuLabel(c)
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    deleteThreads(selectedThreadIds.isEmpty ? [t.id] : selectedThreadIds)
                }
            }
        }
    }

    private func renameRow(_ t: AgentThread) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "pencil")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Palette.accent)
            TextField("Thread name", text: $renameText)
                .textFieldStyle(.plain)
                .font(DS.Font.bodyDense)
                .onSubmit { commitRename(t) }
            Button { renamingThreadId = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Cancel rename")
            .help("Cancel rename")
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .strokeBorder(DS.Palette.accent.opacity(0.4), lineWidth: DS.Border.hairline))
    }

    private func commitRename(_ t: AgentThread) {
        vm.renameThread(t.id, to: renameText)
        renamingThreadId = nil
    }

    // MARK: Conversation column

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            header
            timeline
            composer
        }
        .background(DS.Palette.bg)
        // C6: Esc interrupts an in-flight run (remotecode.io parity).
        .onExitCommand { if vm.status == .running { vm.stop() } }
    }

    // Thin context header. Run-config (provider/model/permission) lives in
    // the composer footer now, Codex-style.
    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
            Text(vm.gitBranch ?? "no branch")
                .font(DS.Font.caption2.monospaced())
                .foregroundColor(DS.Palette.textSecondary)
            Text("·").foregroundColor(DS.Palette.textTertiary)
            Text(URL(fileURLWithPath: vm.cwd).lastPathComponent)
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textTertiary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            DSPill(vm.status.rawValue, tone: statusTone(vm.status))
            DSIconButton("list.bullet.rectangle", help: "Toggle plan") {
                vm.showPlanSidebar.toggle()
            }
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .dsBar(edge: .bottom)
    }

    private var modelLabel: String {
        vm.availableModels.first(where: { $0.id == vm.model })?.label ?? vm.model
    }
    private var permissionLabel: String {
        switch vm.permissionMode {
        case .supervised: return "Supervised"
        case .autoAcceptEdits: return "Auto-edit"
        case .fullAccess: return "Full access"
        }
    }
    private var permissionTone: Color {
        switch vm.permissionMode {
        case .supervised: return DS.Palette.textSecondary
        case .autoAcceptEdits: return DS.Palette.warning
        case .fullAccess: return DS.Palette.danger
        }
    }
    private var effortLabel: String { vm.reasoningEffort.displayName }

    private func statusTone(_ s: AgentRunStatus) -> DSPill.Tone {
        switch s {
        case .running: return .accent
        case .completed: return .success
        case .failed: return .danger
        case .cancelled, .interrupted: return .warning
        default: return .neutral
        }
    }

    // MARK: Timeline

    // Flat, Codex-style transcript: a centered reading column, user
    // messages as right-aligned bubbles, assistant output as full-width
    // prose, tools as one dim line. No per-item cards.
    private var timeline: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.huge) {
                            if vm.messages.isEmpty && vm.timeline.turns.isEmpty && vm.timeline.error == nil {
                                emptyConversation.padding(.top, 56)
                            }
                            ForEach(vm.messages, id: \.id) { msg in messageRow(msg) }
                            ForEach(vm.timeline.turns, id: \.turnId) { turn in turnView(turn) }
                            if vm.status == .running { workingStatus }
                            if let err = vm.timeline.error { errorRow(err) }
                            Color.clear
                                .frame(height: 1)
                                .id("BOTTOM")
                                .background(
                                    GeometryReader { marker in
                                        Color.clear.preference(
                                            key: TimelineBottomPreferenceKey.self,
                                            value: marker.frame(in: .named("agentTimeline")).maxY
                                        )
                                    }
                                )
                        }
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.vertical, DS.Space.xl)
                        .frame(maxWidth: 920, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .coordinateSpace(name: "agentTimeline")
                    .background(DS.Palette.bg)
                    .onPreferenceChange(TimelineBottomPreferenceKey.self) { bottomY in
                        let atBottom = bottomY <= viewport.size.height + 28
                        timelineSticksToBottom = atBottom
                        showScrollDownButton = !atBottom
                    }
                }
                if showScrollDownButton {
                    Button {
                        timelineSticksToBottom = true
                        showScrollDownButton = false
                        withAnimation(DS.Motion.micro) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DS.Palette.onAccent)
                            .frame(width: 34, height: 34)
                            .background(DS.Palette.accent)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scroll to latest message")
                    .help("Scroll to latest message")
                    .padding(.trailing, DS.Space.xl)
                    .padding(.bottom, DS.Space.lg)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .onAppear { scrollTimelineToBottom(proxy) }
            .onChange(of: vm.focusTick) { _ in scrollTimelineToBottom(proxy, force: true) }
            .onChange(of: vm.messages.count) { _ in scrollTimelineToBottom(proxy) }
            .onChange(of: vm.timeline.turns.count) { _ in scrollTimelineToBottom(proxy) }
            .onChange(of: vm.timelineUpdateTick) { _ in scrollTimelineToBottom(proxy) }
            .onChange(of: vm.status) { _ in scrollTimelineToBottom(proxy) }
        }
    }

    private func scrollTimelineToBottom(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || timelineSticksToBottom else { return }
        timelineSticksToBottom = true
        showScrollDownButton = false
        withAnimation(DS.Motion.micro) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
    }

    // "Working for 2m 21s" + hairline, while a run is in flight.
    private var workingStatus: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            TimelineView(.periodic(from: vm.runStartedAt ?? Date(), by: 1)) { _ in
                HStack(spacing: DS.Space.sm) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Working for \(elapsedString)")
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textTertiary)
                }
            }
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var elapsedString: String {
        let s = max(0, Int(Date().timeIntervalSince(vm.runStartedAt ?? Date())))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// Markdown → AttributedString with Codex-style inline code chips.
    private func styledMarkdown(_ text: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var a = try? AttributedString(markdown: text, options: opts) else {
            return AttributedString(text)
        }
        let codeRanges = a.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        for r in codeRanges {
            a[r].font = DS.Font.monoSmall
            a[r].backgroundColor = DS.Palette.surfaceOverlay
            a[r].foregroundColor = DS.Palette.accent
        }
        return a
    }

    @ViewBuilder
    private func assistantProse(_ text: String) -> some View {
        Text(styledMarkdown(text))
            .font(DS.Font.body)
            .foregroundColor(DS.Palette.text)
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyConversation: some View {
        VStack(spacing: DS.Space.lg) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(DS.Palette.accent.opacity(0.7))
            Text("Start a conversation")
                .font(DS.Font.title3).foregroundColor(DS.Palette.textSecondary)
            Text("Ask \(vm.provider.rawValue.capitalized) to build, refactor, or explain code in this workspace.")
                .font(DS.Font.bodyDense)
                .foregroundColor(DS.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func errorRow(_ err: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundColor(DS.Palette.danger)
            Text(err)
                .font(DS.Font.monoSmall).foregroundColor(DS.Palette.danger)
                .lineSpacing(3).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func messageRow(_ msg: AgentMessage) -> some View {
        switch msg.role {
        case .user:
            // Right-aligned bubble. The HStack MUST fill the reading column
            // (.infinity) — otherwise the LazyVStack collapses to this
            // row's intrinsic width and every message renders as a tiny
            // pill centered in an empty pane.
            HStack(spacing: 0) {
                Spacer(minLength: DS.Space.huge)
                VStack(alignment: .trailing, spacing: DS.Space.xs) {
                    Text(msg.content)
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.text)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.vertical, DS.Space.md)
                        .background(DS.Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                        // Bubble wraps its content and caps at 600; it must
                        // hug the RIGHT edge (trailing), else a short message
                        // floats in the middle of a 600-wide invisible box.
                        .frame(maxWidth: 600, alignment: .trailing)
                    Button { copyToPasteboard(msg.content) } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityLabel("Copy message")
                    .help("Copy message")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            assistantProse(msg.content)
        case .system:
            Text(msg.content)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
                .italic()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func turnView(_ turn: AssistantTurnSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            ForEach(turn.items, id: \.id) { item in itemRow(item) }
            // Only show the turn's final text if no assistant-message item
            // already rendered it (prevents the answer showing twice).
            if let final = turn.finalAssistantMessage, !final.isEmpty,
               !turn.items.contains(where: { $0.type == .assistantMessage }) {
                assistantProse(final)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func itemRow(_ item: AssistantItem) -> some View {
        switch item.type {
        case .assistantMessage:
            if !item.body.isEmpty { assistantProse(item.body) }
        case .reasoning:
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(item.state == .streaming ? "Thinking…" : "Thought")
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                if !item.body.isEmpty {
                    Text(item.body)
                        .font(DS.Font.bodyDense)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .plan:
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("PLAN").font(DS.Font.caption2.weight(.semibold)).tracking(0.6)
                    .foregroundColor(DS.Palette.accent)
                assistantProse(item.body)
            }
        case .tool:
            toolRow(item)
        }
    }

    @ViewBuilder
    private func toolRow(_ item: AssistantItem) -> some View {
        let label = ((item.summary?.isEmpty == false ? item.summary! : item.body))
            .replacingOccurrences(of: "\n", with: " ")
        let running = item.state == .streaming
        let hasOutput = (item.output?.isEmpty == false)
        let expanded = expandedTools.contains(item.id)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Button {
                guard hasOutput else { return }
                if expanded { expandedTools.remove(item.id) } else { expandedTools.insert(item.id) }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: running ? "circle.dotted" : "terminal")
                        .font(.system(size: 10)).foregroundColor(DS.Palette.textTertiary)
                    (Text(running ? "Running " : "Ran ")
                        .font(DS.Font.caption).foregroundColor(DS.Palette.textTertiary)
                     + Text(label)
                        .font(DS.Font.monoSmall).foregroundColor(DS.Palette.textSecondary))
                    .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if hasOutput {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hasOutput ? (expanded ? "Hide tool output" : "Show tool output") : "Tool output unavailable")
            if expanded, let o = item.output, !o.isEmpty {
                Text(o)
                    .font(DS.Font.monoSmall).foregroundColor(DS.Palette.textTertiary)
                    .textSelection(.enabled)
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Composer

    // Unified Codex-style composer card: changed-files strip → editor →
    // toolbar (attach · permission · model·effort · send/stop).
    private var composer: some View {
        VStack(spacing: 0) {
            if let s = vm.gitSummary, !s.files.isEmpty { changedFilesStrip(s) }
            if !vm.attachments.isEmpty {
                attachmentChips
                    .padding(.horizontal, DS.Space.lg)
                    .padding(.top, DS.Space.md)
            }
            PromptComposerEditor(
                text: $vm.prompt,
                height: $composerEditorHeight,
                placeholder: "Ask \(vm.provider.rawValue.capitalized) for changes…",
                isEnabled: vm.status != .running,
                onSend: { Task { await vm.send() } }
            )
            .frame(height: composerEditorHeight)
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.sm)
            .padding(.bottom, DS.Space.xs)
            composerToolbar
        }
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        .padding(DS.Space.lg)
        .background(DS.Palette.bg)
    }

    private func changedFilesStrip(_ s: GitSummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Text("\(s.files.count) file\(s.files.count == 1 ? "" : "s") changed")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                Text("+\(s.totalAdditions)")
                    .font(DS.Font.caption.monospacedDigit()).foregroundColor(DS.Palette.success)
                Text("−\(s.totalDeletions)")
                    .font(DS.Font.caption.monospacedDigit()).foregroundColor(DS.Palette.danger)
                Spacer(minLength: 0)
                Button { vm.onReviewRequested?() } label: {
                    Text("Review here")
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Review changes in the Git panel")
                .help("Review changes in the Git panel")
            }
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
        }
    }

    private var composerToolbar: some View {
        HStack(spacing: DS.Space.md) {
            Button(action: pickAttachments) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Palette.textSecondary)
            .help("Attach files").accessibilityLabel("Attach files")
            .disabled(vm.status == .running)
            permissionMenu
            Spacer(minLength: DS.Space.sm)
            if vm.status == .running {
                ProgressView().controlSize(.small).scaleEffect(0.55)
            }
            modelMenu
            sendStopButton
        }
        .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
    }

    private var permissionMenu: some View {
        Menu {
            Button("Supervised") { vm.permissionMode = .supervised }
            Button("Auto-edit") { vm.permissionMode = .autoAcceptEdits }
            Button("Full access") { vm.permissionMode = .fullAccess }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: vm.permissionMode == .fullAccess ? "exclamationmark.shield.fill" : "lock.shield")
                    .font(.system(size: 10))
                Text(permissionLabel).font(DS.Font.caption.weight(.medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .fixedSize()
            .foregroundColor(permissionTone)
            .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
            .background(permissionTone.opacity(0.13))
            .clipShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Permission mode")
    }

    private var modelMenu: some View {
        Menu {
            Picker("Source", selection: $vm.provider) {
                Text("Codex").tag(AgentProvider.codex)
                Text("Claude").tag(AgentProvider.claude)
            }
            .disabled(vm.providerLocked || vm.status == .running)
            .onChange(of: vm.provider) { _ in
                Task { await vm.loadModels(); await MainActor.run { vm.persistThreadConfig() } }
            }
            if !vm.availableModels.isEmpty {
                Picker("Model", selection: $vm.model) {
                    ForEach(vm.availableModels, id: \.id) { m in Text(m.label).tag(m.id) }
                }
                .onChange(of: vm.model) { _ in vm.persistThreadConfig() }
                .disabled(vm.status == .running)
            }
            Divider()
            Picker("Reasoning effort", selection: $vm.reasoningEffort) {
                ForEach(AgentReasoningEffort.supportedCases, id: \.self) { e in
                    Text(e.displayName).tag(e)
                }
            }
            if vm.providerLocked {
                Divider()
                Text("Source locked — \(vm.provider.rawValue.capitalized) thread")
            }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Text(modelLabel).font(DS.Font.caption.weight(.medium)).foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                Text("·").foregroundColor(DS.Palette.textTertiary)
                Text(effortLabel).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
            }
            .fixedSize()
            .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
            .background(DS.Palette.surfaceRaised)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(vm.status == .running)
        .help("Provider · model · reasoning effort")
    }

    private var sendStopButton: some View {
        Button {
            if vm.status == .running { vm.stop() } else { Task { await vm.send() } }
        } label: {
            ZStack {
                Circle()
                    .fill(vm.status == .running ? DS.Palette.text
                          : (sendIdleDisabled ? DS.Palette.surfaceRaised : DS.Palette.accent))
                    .frame(width: 28, height: 28)
                Image(systemName: vm.status == .running ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(vm.status == .running ? DS.Palette.bg
                                     : (sendIdleDisabled ? DS.Palette.textTertiary : DS.Palette.onAccent))
            }
        }
        .buttonStyle(.plain)
        .disabled(vm.status != .running && sendIdleDisabled)
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityLabel(vm.status == .running ? "Stop" : "Send")
        .help(vm.status == .running ? "Stop running agent" : "Send prompt")
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                ForEach(vm.attachments, id: \.self) { path in
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "doc").font(.system(size: 9))
                        Text((path as NSString).lastPathComponent)
                            .font(DS.Font.caption2).lineLimit(1)
                        Button { vm.removeAttachment(path) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attachment")
                        .help("Remove attachment")
                    }
                    .foregroundColor(DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.sm).padding(.vertical, 3)
                    .background(DS.Palette.surfaceRaised)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                }
            }
        }
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            vm.addAttachments(panel.urls.map { $0.path })
        }
    }

    private var sendIdleDisabled: Bool {
        vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && vm.attachments.isEmpty
    }

    private func selectThreadRow(_ thread: AgentThread) {
        if NSEvent.modifierFlags.contains(.shift),
           let lastSelectedThreadId,
           let last = vm.threads.firstIndex(where: { $0.id == lastSelectedThreadId }),
           let current = vm.threads.firstIndex(where: { $0.id == thread.id }) {
            let range = min(last, current)...max(last, current)
            selectedThreadIds.formUnion(vm.threads[range].map(\.id))
        } else {
            selectedThreadIds = [thread.id]
            lastSelectedThreadId = thread.id
        }
        vm.selectThread(thread.id)
    }

    private func deleteSelectedThreads() {
        let fallback = vm.selectedThreadId.map { Set([$0]) } ?? []
        deleteThreads(selectedThreadIds.isEmpty ? fallback : selectedThreadIds)
    }

    private func deleteThreads(_ ids: Set<AgentThreadID>) {
        guard !ids.isEmpty else { return }
        vm.deleteThreads(ids)
        selectedThreadIds.subtract(ids)
        if let lastSelectedThreadId, ids.contains(lastSelectedThreadId) {
            self.lastSelectedThreadId = selectedThreadIds.first
        }
    }

    // MARK: Plan notes sidebar

    private var planSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Plan", trailing: AnyView(
                DSIconButton("xmark", help: "Hide plan") { vm.showPlanSidebar = false }
            ))
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            if let plan = vm.latestPlanText {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("PROPOSED BY AGENT")
                        .font(DS.Font.caption2.weight(.semibold)).tracking(0.6)
                        .foregroundColor(DS.Palette.accent)
                    ScrollView {
                        Text(plan)
                            .font(DS.Font.monoSmall)
                            .foregroundColor(DS.Palette.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
                .padding(DS.Space.md)
                .background(DS.Palette.bg)
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            }
            Text("NOTES")
                .font(DS.Font.caption2.weight(.semibold)).tracking(0.6)
                .foregroundColor(DS.Palette.textTertiary)
                .padding(.horizontal, DS.Space.md).padding(.top, DS.Space.sm)
            TextEditor(text: $vm.planNotes)
                .font(DS.Font.mono)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.md)
                .background(DS.Palette.surface)
        }
        .background(DS.Palette.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }
}

enum PromptComposerKeyAction: Equatable {
    case send
    case insertNewline
    case ignore

    static func action(for event: NSEvent) -> PromptComposerKeyAction {
        guard event.keyCode == 36 || event.keyCode == 76 else { return .ignore }
        return event.modifierFlags.contains(.shift) ? .insertNewline : .send
    }
}

private final class PromptComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        switch PromptComposerKeyAction.action(for: event) {
        case .send:
            onSend?()
        case .insertNewline:
            insertNewlineIgnoringFieldEditor(self)
        case .ignore:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: DS.NS.textTertiary
        ]
        placeholderString.draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
    }
}

private struct PromptComposerEditor: NSViewRepresentable {
    static let minHeight: CGFloat = 30
    static let maxHeight: CGFloat = 132

    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let isEnabled: Bool
    let onSend: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true

        let textView = PromptComposerTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.backgroundColor = .clear
        textView.textColor = DS.NS.text
        textView.insertionPointColor = DS.NS.text
        textView.textContainerInset = NSSize(width: 0, height: 5)
        textView.minSize = NSSize(width: 0, height: Self.minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.onSend = onSend
        textView.placeholderString = placeholder
        context.coordinator.textView = textView
        context.coordinator.recalculateHeight()
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scroll.documentView as? PromptComposerTextView else { return }
        textView.onSend = onSend
        textView.isEditable = isEnabled
        textView.placeholderString = placeholder
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
        context.coordinator.recalculateHeight()
        scroll.hasVerticalScroller = height >= Self.maxHeight
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, height: $height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var height: CGFloat
        weak var textView: PromptComposerTextView?

        init(text: Binding<String>, height: Binding<CGFloat>) {
            _text = text
            _height = height
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            textView.needsDisplay = true
            recalculateHeight()
        }

        func recalculateHeight() {
            guard let textView else { return }
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let next = min(PromptComposerEditor.maxHeight,
                           max(PromptComposerEditor.minHeight, ceil(used + textView.textContainerInset.height * 2)))
            if abs(height - next) > 0.5 {
                DispatchQueue.main.async { [weak self] in
                    self?.height = next
                }
            }
        }
    }
}

private struct TimelineBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AgentThreadDropDelegate: DropDelegate {
    let vm: AgentAppViewModel
    @Binding var draggingThreadId: AgentThreadID?
    let target: AgentThread

    func dropEntered(info: DropInfo) {
        guard let draggingThreadId, draggingThreadId != target.id else { return }
        vm.reorderThread(draggingThreadId, before: target.id)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingThreadId = nil
        return true
    }
}


@MainActor
public final class AgentAppSurface: NSObject, Surface {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    public let viewModel: AgentAppViewModel
    /// EventBus subscription so socket-driven thread mutations refresh
    /// this already-open surface (wired by AppCommandRouter, like Feed).
    public var subscriptionToken: AnyHashable?

    public init(workspaceID: WorkspaceID, cwd: String, coordinator: AgentRunCoordinator, threadRepo: AgentThreadRepository, messageRepo: AgentMessageRepository, title: String = "Agent App") {
        self.descriptor = SurfaceDescriptor(type: .agentApp, title: title, iconName: "sparkle", metadata: ["workspace": workspaceID.value.uuidString, "cwd": cwd])
        self.viewModel = AgentAppViewModel(workspaceID: workspaceID, cwd: cwd, coordinator: coordinator, threadRepo: threadRepo, messageRepo: messageRepo)
        let host = NSHostingView(rootView: AgentAppView(vm: viewModel))
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

    public func focus() {
        viewModel.focusTick &+= 1
        view.window?.makeFirstResponder(view)
    }
    public func unfocus() {}
    public func close() {}
    public func sendText(_ text: String) {
        viewModel.prompt = (viewModel.prompt.isEmpty ? text : viewModel.prompt + "\n" + text)
    }
    public func readText() -> String {
        viewModel.messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
    }
    public func snapshot() -> [String: String] {
        ["selected_thread": viewModel.selectedThreadId?.value.uuidString ?? "",
         "provider": viewModel.provider.rawValue,
         "model": viewModel.model]
    }

    // A3: drives the tab/workspace spinner.
    public var isBusy: Bool { viewModel.status == .running || viewModel.activeThreadCount > 0 }
}

private struct TabColorMenuLabel: View {
    let color: TabColor

    init(_ color: TabColor) {
        self.color = color
    }

    var body: some View {
        Label {
            Text(color.label)
        } icon: {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(hex: color.hex))
                .frame(width: 12, height: 12)
        }
    }
}
