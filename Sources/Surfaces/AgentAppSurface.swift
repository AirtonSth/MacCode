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
    @Published public var showPlanSidebar: Bool = false
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
            threadRail
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
            conversationColumn
                .frame(minWidth: 460)
            if vm.showPlanSidebar {
                planSidebar.frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            }
        }
        .background(DS.Palette.bg)
        .task { await vm.loadModels() }
    }

    // MARK: Thread rail

    private var threadRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Threads", trailing: AnyView(
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
                    .fill(t.status == .running ? DS.Palette.success
                          : t.status == .failed ? DS.Palette.danger
                          : DS.Palette.textTertiary)
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

    // MARK: Conversation column

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            header
            timeline
            composer
        }
        .background(DS.Palette.bg)
    }

    // Compact run-config header. Git/terminal intentionally absent —
    // those live in the workspace (Git tab + Terminal surface).
    private var header: some View {
        HStack(spacing: DS.Space.md) {
            runConfigChip(icon: "cpu", value: vm.provider.rawValue.capitalized) {
                Picker("", selection: $vm.provider) {
                    Text("Codex").tag(AgentProvider.codex)
                    Text("Claude").tag(AgentProvider.claude)
                }
                .labelsHidden()
                .onChange(of: vm.provider) { _ in Task { await vm.loadModels() } }
            }
            runConfigChip(icon: "sparkle", value: modelLabel) {
                Picker("", selection: $vm.model) {
                    ForEach(vm.availableModels, id: \.id) { m in Text(m.label).tag(m.id) }
                }.labelsHidden()
            }
            runConfigChip(icon: "lock.shield", value: permissionLabel) {
                Picker("", selection: $vm.permissionMode) {
                    Text("Supervised").tag(AgentPermissionMode.supervised)
                    Text("Auto-edit").tag(AgentPermissionMode.autoAcceptEdits)
                    Text("Full access").tag(AgentPermissionMode.fullAccess)
                }.labelsHidden()
            }
            Spacer()
            if vm.status == .running {
                HStack(spacing: DS.Space.sm) {
                    ProgressView().controlSize(.small).scaleEffect(0.65)
                    Button("Stop") { vm.stop() }.buttonStyle(DSSecondaryButtonStyle())
                }
            }
            DSPill(vm.status.rawValue, tone: statusTone(vm.status))
            DSIconButton("list.bullet.rectangle", help: "Toggle plan notes") {
                vm.showPlanSidebar.toggle()
            }
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
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

    // A pill-shaped control wrapping a borderless Picker so the pickers
    // read as one cohesive run-config strip instead of three raw combos.
    @ViewBuilder
    private func runConfigChip<P: View>(icon: String, value: String, @ViewBuilder _ picker: () -> P) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(DS.Palette.textTertiary)
            picker()
                .font(DS.Font.caption)
                .frame(minWidth: 70)
                .fixedSize()
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.xs)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
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

    // MARK: Timeline

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.lg) {
                    if vm.messages.isEmpty && vm.timeline.turns.isEmpty && vm.timeline.error == nil {
                        emptyConversation.padding(.top, DS.Space.huge)
                    }
                    ForEach(vm.messages, id: \.id) { msg in messageRow(msg) }
                    ForEach(vm.timeline.turns, id: \.turnId) { turn in turnView(turn) }
                    if let err = vm.timeline.error { errorCard(err) }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.Palette.bg)
            .onChange(of: vm.messages.count) { _ in withAnimation(DS.Motion.micro) { proxy.scrollTo("BOTTOM") } }
            .onChange(of: vm.timeline.turns.count) { _ in withAnimation(DS.Motion.micro) { proxy.scrollTo("BOTTOM") } }
        }
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
    private func errorCard(_ err: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(DS.Palette.danger).font(.system(size: 13))
            Text(err)
                .font(DS.Font.monoSmall)
                .foregroundColor(DS.Palette.danger)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.lg)
        .background(DS.Palette.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(DS.Palette.danger.opacity(0.35), lineWidth: DS.Border.hairline))
    }

    @ViewBuilder
    private func messageRow(_ msg: AgentMessage) -> some View {
        let isUser = msg.role == .user
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: isUser ? "person.crop.circle" : "sparkle")
                    .font(.system(size: 11))
                    .foregroundColor(isUser ? DS.Palette.accent : DS.Palette.success)
                Text(isUser ? "You" : "Assistant")
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(DS.Palette.textTertiary)
            }
            Text(msg.content)
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Space.lg)
        .background(isUser ? DS.Palette.surface : DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(isUser ? DS.Palette.line : DS.Palette.accent.opacity(0.22),
                          lineWidth: DS.Border.hairline))
    }

    @ViewBuilder
    private func turnView(_ turn: AssistantTurnSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach(turn.items, id: \.id) { item in itemRow(item) }
            if let final = turn.finalAssistantMessage, !final.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: "sparkle").font(.system(size: 11)).foregroundColor(DS.Palette.success)
                        Text("Assistant").font(DS.Font.caption2.weight(.semibold)).foregroundColor(DS.Palette.textTertiary)
                    }
                    Text(final)
                        .font(DS.Font.body).foregroundColor(DS.Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(DS.Space.lg)
                .background(DS.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.accent.opacity(0.3), lineWidth: DS.Border.hairline))
            }
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
                if item.state == .streaming {
                    ProgressView().controlSize(.small).scaleEffect(0.5)
                } else {
                    Text(item.state.rawValue).font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary)
                }
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
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
    }

    private func itemTone(_ t: AssistantItemType) -> DSPill.Tone {
        switch t {
        case .reasoning: return .neutral
        case .plan: return .accent
        case .tool: return .warning
        case .assistantMessage: return .success
        }
    }

    // MARK: Composer

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
                    .frame(minHeight: 64, maxHeight: 160)
            }
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
            HStack {
                Text("⌘↩ to send").font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary)
                Spacer()
                Button("Send") { Task { await vm.send() } }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(sendDisabled)
                    .opacity(sendDisabled ? 0.45 : 1)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(DS.Space.lg)
        .dsBar(edge: .top)
    }

    private var sendDisabled: Bool {
        vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.status == .running
    }

    // MARK: Plan notes sidebar

    private var planSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Plan notes", trailing: AnyView(
                DSIconButton("xmark", help: "Hide notes") { vm.showPlanSidebar = false }
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

