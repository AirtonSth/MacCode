import Foundation
import AppKit
import SwiftUI
import Combine
import CoreModel
import Persistence
import AgentRuntime

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
            threadListPane
                .frame(minWidth: 200, idealWidth: 230)
            mainPane
                .frame(minWidth: 400)
        }
        .task { await vm.loadModels() }
    }

    private var threadListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Threads").font(.headline)
                Spacer()
                Button(action: { vm.createThread(title: "New thread") }) {
                    Image(systemName: "plus")
                }.buttonStyle(.borderless)
            }.padding(8)
            Divider()
            List(selection: Binding(
                get: { vm.selectedThreadId },
                set: { if let t = $0 { vm.selectThread(t) } }
            )) {
                ForEach(vm.threads, id: \.id) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.body)
                        Text("\(t.provider.rawValue) • \(t.model)")
                            .font(.caption).foregroundColor(.secondary)
                    }.tag(t.id)
                }
            }.listStyle(.sidebar)
        }
    }

    private var mainPane: some View {
        VStack(spacing: 0) {
            header
            Divider()
            timelineView
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Provider", selection: $vm.provider) {
                Text("Codex").tag(AgentProvider.codex)
                Text("Claude").tag(AgentProvider.claude)
            }
            .onChange(of: vm.provider) { _ in Task { await vm.loadModels() } }
            .frame(width: 130)
            Picker("Model", selection: $vm.model) {
                ForEach(vm.availableModels, id: \.id) { m in
                    Text(m.label).tag(m.id)
                }
            }.frame(width: 220)
            Picker("Mode", selection: $vm.permissionMode) {
                Text("Supervised").tag(AgentPermissionMode.supervised)
                Text("Auto-edit").tag(AgentPermissionMode.autoAcceptEdits)
                Text("Full").tag(AgentPermissionMode.fullAccess)
            }.frame(width: 160)
            Spacer()
            if vm.status == .running {
                ProgressView().controlSize(.small)
                Button("Stop") { vm.stop() }
            }
            Text(vm.status.rawValue).font(.caption).foregroundColor(.secondary)
        }.padding(8)
    }

    private var timelineView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.messages, id: \.id) { msg in
                        messageRow(msg)
                    }
                    ForEach(vm.timeline.turns, id: \.turnId) { turn in
                        turnView(turn)
                    }
                    if let err = vm.timeline.error {
                        Text(err).foregroundColor(.red)
                    }
                }.padding(10)
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ msg: AgentMessage) -> some View {
        HStack(alignment: .top) {
            Text(msg.role == .user ? "You" : "Assistant")
                .font(.caption).foregroundColor(.secondary).frame(width: 70, alignment: .leading)
            Text(msg.content).textSelection(.enabled)
            Spacer()
        }.padding(8)
            .background(msg.role == .user ? Color.gray.opacity(0.05) : Color.blue.opacity(0.05))
            .cornerRadius(6)
    }

    @ViewBuilder
    private func turnView(_ turn: AssistantTurnSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(turn.items, id: \.id) { item in
                itemRow(item)
            }
            if let final = turn.finalAssistantMessage, !final.isEmpty {
                Text(final).font(.body).textSelection(.enabled).padding(6).background(Color.blue.opacity(0.08)).cornerRadius(6)
            }
        }.padding(4)
    }

    @ViewBuilder
    private func itemRow(_ item: AssistantItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.type.rawValue).font(.caption2.bold()).foregroundColor(.secondary)
                if let s = item.summary { Text(s).font(.caption2).foregroundColor(.secondary) }
                Spacer()
                Text(item.state.rawValue).font(.caption2).foregroundColor(.secondary)
            }
            if !item.body.isEmpty {
                Text(item.body).font(.system(.body, design: item.type == .tool ? .monospaced : .default)).textSelection(.enabled)
            }
            if let o = item.output, !o.isEmpty {
                Text(o).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
        }.padding(6).background(Color.gray.opacity(0.04)).cornerRadius(4)
    }

    private var composer: some View {
        VStack(spacing: 4) {
            TextEditor(text: $vm.prompt)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
            HStack {
                Spacer()
                Button("Send") { Task { await vm.send() } }
                    .disabled(vm.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.status == .running)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }.padding(8)
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
