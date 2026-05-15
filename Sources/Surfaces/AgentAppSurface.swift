import Foundation
import AppKit
import SwiftUI
import Combine
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
    @Published public var prompt: String = ""
    @Published public var provider: AgentProvider = .codex
    @Published public var model: String = "gpt-5"
    @Published public var availableModels: [AgentModelDescriptor] = []
    @Published public var permissionMode: AgentPermissionMode = .supervised
    @Published public var reasoningEffort: AgentReasoningEffort = .medium
    @Published public var status: AgentRunStatus = .pending
    @Published public var statusMessage: String = ""
    @Published public var currentRunId: AgentRunID?
    @Published public var hasUnreadActivity: Bool = false
    @Published public var gitSummary: GitSummary = GitSummary(isGitRepo: false, branch: nil, dirty: false, files: [], totalAdditions: 0, totalDeletions: 0)
    @Published public var showPlanSidebar: Bool = false
    @Published public var showTerminalDrawer: Bool = false
    @Published public var planNotes: String = ""

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
        self.coordinator.observer = self
        reloadThreads()
        refreshGitSummary()
    }

    public func refreshGitSummary() {
        let cwd = self.cwd
        DispatchQueue.global().async {
            let s = GitDiff.summary(in: cwd)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.applyGitSummary(s)
            }
        }
    }

    private func applyGitSummary(_ s: GitSummary) {
        self.gitSummary = s
    }

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
        }
        messages = (try? messageRepo.list(threadId: id)) ?? []
        timeline = AssistantTimelineState()
    }

    public func loadModels() async {
        let runner: AgentProviderRunner = provider == .codex ? CodexRunner() : ClaudeRunner()
        let m = await runner.listModels()
        await MainActor.run { self.availableModels = m }
    }

    public func createThread(title: String) {
        let t = AgentThread(workspaceId: workspaceID, title: title, provider: provider, model: model)
        try? threadRepo.upsert(t)
        reloadThreads()
        selectThread(t.id)
    }

    public func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if selectedThreadId == nil {
            createThread(title: String(text.prefix(48)))
        }
        guard let tid = selectedThreadId else { return }
        prompt = ""
        timeline = AssistantTimelineState()
        let userMsg = AgentMessage(threadId: tid, role: .user, content: text)
        messages.append(userMsg)
        let req = AgentRunRequest(
            threadId: tid,
            provider: provider,
            model: model,
            cwd: cwd,
            prompt: text,
            providerThreadId: threads.first(where: { $0.id == tid })?.providerThreadId,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort
        )
        do {
            let runId = try await coordinator.startRun(req)
            await MainActor.run { self.currentRunId = runId; self.status = .running }
        } catch {
            await MainActor.run { self.statusMessage = "Failed to start: \(error)"; self.status = .failed }
        }
    }

    public func stop() {
        if let r = currentRunId { coordinator.stopRun(r) }
    }

    // MARK: AgentRunObserver

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID) {
        Task { @MainActor in
            self.timeline.apply(event)
        }
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
        Task { @MainActor in
            self.status = status
            if status == .completed, let msg = finalMessage, let tid = self.selectedThreadId {
                self.messages.append(AgentMessage(threadId: tid, role: .assistant, content: msg))
            }
            self.currentRunId = nil
            self.reloadThreads()
            self.refreshGitSummary()
        }
    }

    nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID) {
        Task { @MainActor in self.status = status }
    }
}

public struct AgentAppView: View {
    @ObservedObject var vm: AgentAppViewModel

    public init(vm: AgentAppViewModel) { self.vm = vm }

    public var body: some View {
        HSplitView {
            threadListPane
                .frame(minWidth: 210, idealWidth: 240)
            mainPane
                .frame(minWidth: 420)
            if vm.showPlanSidebar {
                planSidebar.frame(minWidth: 230, idealWidth: 280)
            }
        }
        .background(DS.Palette.bg)
        .task { await vm.loadModels() }
    }

    // MARK: Plan sidebar

    private var planSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Plan", trailing: AnyView(
                DSIconButton("xmark", help: "Hide plan") { vm.showPlanSidebar = false }
            ))
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
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

    // MARK: Thread list

    private var threadListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Threads", trailing: AnyView(
                DSIconButton("plus", help: "New thread") { vm.createThread(title: "New thread") }
            ))
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            if vm.threads.isEmpty {
                DSEmptyState(icon: "bubble.left.and.bubble.right",
                             title: "No threads",
                             subtitle: "Send a prompt below to start a Codex or Claude thread in this workspace.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                        ForEach(vm.threads, id: \.id) { t in
                            threadRow(t)
                        }
                    }.padding(DS.Space.sm)
                }
            }
        }
        .background(DS.Palette.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }

    @ViewBuilder
    private func threadRow(_ t: AgentThread) -> some View {
        let selected = vm.selectedThreadId == t.id
        Button { vm.selectThread(t.id) } label: {
            HStack(spacing: DS.Space.md) {
                Circle()
                    .fill(t.status == .running ? DS.Palette.success : DS.Palette.textTertiary)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(DS.Font.bodyDense)
                        .foregroundColor(DS.Palette.text).lineLimit(1)
                    Text("\(t.provider.rawValue) · \(t.model)")
                        .font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(selected ? DS.Palette.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Main column

    private var mainPane: some View {
        VStack(spacing: 0) {
            header
            branchToolbar
            timelineView
            if vm.showTerminalDrawer {
                terminalDrawer.frame(minHeight: 150, idealHeight: 190, maxHeight: 300)
            }
            composer
        }
        .background(DS.Palette.bg)
    }

    private var terminalDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TERMINAL").font(DS.Font.caption2.weight(.semibold))
                    .tracking(0.6).foregroundColor(DS.Palette.textTertiary)
                Spacer()
                DSIconButton("xmark", help: "Hide drawer") { vm.showTerminalDrawer = false }
            }
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            ScrollView {
                Text("Open a dedicated Terminal surface beside this Agent App for a full shell. Press ⌘T or use “+ Term” in the pane toolbar.")
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.textTertiary)
                    .padding(DS.Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline) }
    }

    private var branchToolbar: some View {
        HStack(spacing: DS.Space.md) {
            if vm.gitSummary.isGitRepo {
                Label(vm.gitSummary.branch ?? "detached", systemImage: "arrow.triangle.branch")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
                if vm.gitSummary.dirty { DSPill("dirty", tone: .warning) }
                HStack(spacing: DS.Space.xs) {
                    Text("+\(vm.gitSummary.totalAdditions)")
                        .font(DS.Font.caption2.monospacedDigit()).foregroundColor(DS.Palette.success)
                    Text("−\(vm.gitSummary.totalDeletions)")
                        .font(DS.Font.caption2.monospacedDigit()).foregroundColor(DS.Palette.danger)
                }
            } else {
                Label("No Git", systemImage: "questionmark.circle")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textTertiary)
            }
            Spacer()
            Text(vm.cwd).font(DS.Font.monoSmall)
                .foregroundColor(DS.Palette.textTertiary).lineLimit(1).truncationMode(.middle)
            DSIconButton("arrow.clockwise", help: "Refresh git status") { vm.refreshGitSummary() }
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .dsBar(edge: .bottom)
    }

    private var header: some View {
        HStack(spacing: DS.Space.md) {
            Picker("", selection: $vm.provider) {
                Text("Codex").tag(AgentProvider.codex)
                Text("Claude").tag(AgentProvider.claude)
            }
            .labelsHidden()
            .onChange(of: vm.provider) { _ in Task { await vm.loadModels() } }
            .frame(width: 120)
            Picker("", selection: $vm.model) {
                ForEach(vm.availableModels, id: \.id) { m in Text(m.label).tag(m.id) }
            }.labelsHidden().frame(width: 200)
            Picker("", selection: $vm.permissionMode) {
                Text("Supervised").tag(AgentPermissionMode.supervised)
                Text("Auto-edit").tag(AgentPermissionMode.autoAcceptEdits)
                Text("Full access").tag(AgentPermissionMode.fullAccess)
            }.labelsHidden().frame(width: 150)
            Spacer()
            DSIconButton("terminal", help: "Toggle terminal drawer") { vm.showTerminalDrawer.toggle() }
            DSIconButton("list.bullet.rectangle", help: "Toggle plan sidebar") { vm.showPlanSidebar.toggle() }
            if vm.status == .running {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Button("Stop") { vm.stop() }.buttonStyle(DSSecondaryButtonStyle())
            }
            DSPill(vm.status.rawValue, tone: statusTone(vm.status))
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
        .dsBar(edge: .bottom)
    }

    private func statusTone(_ s: AgentRunStatus) -> DSPill.Tone {
        switch s {
        case .running: return .accent
        case .completed: return .success
        case .failed: return .danger
        case .cancelled, .interrupted: return .warning
        default: return .neutral
        }
    }

    private var timelineView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                ForEach(vm.messages, id: \.id) { msg in messageRow(msg) }
                ForEach(vm.timeline.turns, id: \.turnId) { turn in turnView(turn) }
                if let err = vm.timeline.error {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(DS.Palette.danger)
                        Text(err).font(DS.Font.bodyDense).foregroundColor(DS.Palette.danger)
                    }.dsPanel()
                }
                changedFilesCard
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Palette.bg)
    }

    @ViewBuilder
    private func messageRow(_ msg: AgentMessage) -> some View {
        let isUser = msg.role == .user
        HStack(alignment: .top, spacing: DS.Space.md) {
            Text(isUser ? "YOU" : "AI")
                .font(DS.Font.caption2.weight(.semibold))
                .foregroundColor(isUser ? DS.Palette.accent : DS.Palette.success)
                .frame(width: 28, alignment: .leading)
                .padding(.top, 2)
            Text(msg.content)
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.text)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.lg)
        .background(isUser ? DS.Palette.surface : DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
    }

    @ViewBuilder
    private func turnView(_ turn: AssistantTurnSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach(turn.items, id: \.id) { item in itemRow(item) }
            if let final = turn.finalAssistantMessage, !final.isEmpty {
                Text(final)
                    .font(DS.Font.body).foregroundColor(DS.Palette.text)
                    .textSelection(.enabled)
                    .padding(DS.Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .strokeBorder(DS.Palette.accent.opacity(0.3), lineWidth: DS.Border.hairline)
                    )
            }
        }
    }

    @ViewBuilder
    private var changedFilesCard: some View {
        if vm.gitSummary.isGitRepo && !vm.gitSummary.files.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundColor(DS.Palette.textSecondary)
                    Text("Changed files (\(vm.gitSummary.files.count))")
                        .font(DS.Font.captionStrong).foregroundColor(DS.Palette.text)
                    Spacer()
                    Text("+\(vm.gitSummary.totalAdditions)")
                        .font(DS.Font.caption2.monospacedDigit()).foregroundColor(DS.Palette.success)
                    Text("−\(vm.gitSummary.totalDeletions)")
                        .font(DS.Font.caption2.monospacedDigit()).foregroundColor(DS.Palette.danger)
                }
                ForEach(vm.gitSummary.files, id: \.path) { f in
                    HStack(spacing: DS.Space.md) {
                        Text(statusGlyph(f.status))
                            .font(DS.Font.monoSmall.weight(.bold))
                            .frame(width: 14).foregroundColor(statusColor(f.status))
                        Text(f.path).font(DS.Font.monoSmall)
                            .foregroundColor(DS.Palette.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if !f.binary {
                            Text("+\(f.additions)").font(DS.Font.caption2.monospacedDigit()).foregroundColor(DS.Palette.success)
                            Text("−\(f.deletions)").font(DS.Font.caption2.monospacedDigit()).foregroundColor(DS.Palette.danger)
                        } else {
                            DSPill("bin")
                        }
                    }
                }
            }
            .dsPanel()
        }
    }

    private func statusGlyph(_ s: GitFileStatus) -> String {
        switch s {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .untracked: return "?"
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

    @ViewBuilder
    private func itemRow(_ item: AssistantItem) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                DSPill(item.type.rawValue, tone: itemTone(item.type))
                if let s = item.summary, !s.isEmpty {
                    Text(s).font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary).lineLimit(1)
                }
                Spacer()
                Text(item.state.rawValue).font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary)
            }
            if !item.body.isEmpty {
                Text(item.body)
                    .font(item.type == .tool ? DS.Font.monoSmall : DS.Font.bodyDense)
                    .foregroundColor(DS.Palette.textSecondary)
                    .textSelection(.enabled)
            }
            if let o = item.output, !o.isEmpty {
                Text(o)
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.textTertiary)
                    .textSelection(.enabled)
                    .padding(DS.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.bg)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            }
        }
        .padding(DS.Space.lg)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
    }

    private func itemTone(_ t: AssistantItemType) -> DSPill.Tone {
        switch t {
        case .reasoning: return .neutral
        case .plan: return .accent
        case .tool: return .warning
        case .assistantMessage: return .success
        }
    }

    private var composer: some View {
        VStack(spacing: DS.Space.sm) {
            ZStack(alignment: .topLeading) {
                if vm.prompt.isEmpty {
                    Text("Message \(vm.provider.rawValue.capitalized)…")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textTertiary)
                        .padding(.horizontal, DS.Space.md + 2).padding(.vertical, DS.Space.md)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $vm.prompt)
                    .font(DS.Font.body)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Space.sm)
                    .frame(minHeight: 64, maxHeight: 150)
            }
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
            HStack {
                Text("⌘↩ to send").font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary)
                Spacer()
                Button("Send") { Task { await vm.send() } }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.status == .running)
                    .opacity((vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.status == .running) ? 0.45 : 1)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(DS.Space.lg)
        .dsBar(edge: .top)
    }
}

@MainActor
public final class AgentAppSurface: NSObject, Surface {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    public let viewModel: AgentAppViewModel

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

    public func focus() { view.window?.makeFirstResponder(view) }
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
}
