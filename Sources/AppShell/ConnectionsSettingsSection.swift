import SwiftUI
import CoreModel
import Persistence
import AgentRuntime
import DesignSystemKit
import Surfaces

@MainActor
final class ConnectionsSettingsModel: ObservableObject {
    @Published var connections: [AppConnection] = []
    @Published var error: String?
    @Published var busy: UUID?
    @Published var notice: String?
    @Published private(set) var loaded = false
    private var generation = 0
    let store: ConnectionStore
    let broker: ConnectionBroker
    init(store: ConnectionStore, broker: ConnectionBroker) { self.store = store; self.broker = broker }
    func reload() async {
        generation += 1
        let request = generation, store = store
        let result = await Task.detached(priority: .userInitiated) { Result { try store.list() } }.value
        guard request == generation, !Task.isCancelled else { return }
        loaded = true
        switch result {
        case .success(let rows): connections = rows
        case .failure: error = ConnectionError.storage.description
        }
    }
    func test(_ connection: AppConnection) async {
        busy = connection.id; error = nil; notice = nil
        defer { busy = nil }
        do { let count = try await broker.test(connection.id); notice = "\(connection.name): discovered \(count) tools. No service action was executed." }
        catch { self.error = (error as? ConnectionError)?.description ?? ConnectionError.unavailable.description }
        await reload()
    }
    func disconnect(_ connection: AppConnection) async {
        busy = connection.id; error = nil
        defer { busy = nil }
        do { try await broker.disconnect(connection.id) }
        catch { self.error = (error as? ConnectionError)?.description ?? ConnectionError.unavailable.description }
        await reload()
    }
}

/// One app-owned catalog shared by Agent App, bots and scheduled tasks.
struct ManualConnectionsSettingsSection: View {
    let context: AppContext
    @StateObject private var model: ConnectionsSettingsModel
    @State private var editing: AppConnection?
    @State private var creating = false
    init(context: AppContext) {
        self.context = context
        _model = StateObject(wrappedValue: ConnectionsSettingsModel(store: ConnectionStore(db: context.db), broker: context.connectionBroker))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack {
                Text("Services & MCP servers").font(DS.Font.bodyStrong)
                Spacer()
                Button("Add connection", systemImage: "plus") { creating = true }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("connections.add")
            }
            Text("Connect once to MacCode. Access follows your selected bots, workspaces and tasks across all models. Testing discovers tools; it does not run a service action.")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error { Text(error).font(DS.Font.body).foregroundStyle(DS.Palette.danger).textSelection(.enabled).accessibilityIdentifier("connections.error") }
            if let notice = model.notice { Text(notice).font(DS.Font.caption).foregroundStyle(DS.Palette.success).accessibilityIdentifier("connections.test.result") }
            if !model.loaded {
                ProgressView("Loading connections…").font(DS.Font.caption).accessibilityIdentifier("connections.loading")
            } else if model.connections.isEmpty && model.error == nil {
                Text("No services connected. Add a local or remote MCP server, or a Composio hosted MCP endpoint.")
                    .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).padding(DS.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading).dsPanel()
            }
            ForEach(model.connections.filter { $0.composio == nil }) { connection in
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    HStack {
                        Label(connection.name, systemImage: "puzzlepiece.extension").font(DS.Font.bodyStrong)
                        Spacer()
                        Text(connection.status.title).font(DS.Font.captionStrong)
                            .foregroundStyle(connection.status == .tested ? DS.Palette.success : DS.Palette.textSecondary)
                    }
                    Text([connection.kind.title, connection.account, connection.access.summary].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if let date = connection.testedAt { Text("Tools verified \(date.formatted(date: .abbreviated, time: .shortened))").font(DS.Font.caption2).foregroundStyle(DS.Palette.textTertiary) }
                    ViewThatFits(in: .horizontal) {
                        HStack { actions(connection) }
                        VStack(alignment: .leading) { actions(connection) }
                    }
                }
                .padding(DS.Space.lg).frame(maxWidth: .infinity, alignment: .leading).dsPanel()
                .accessibilityIdentifier("connections.row.\(connection.id.uuidString.lowercased())")
            }
        }
        .foregroundStyle(DS.Palette.text)
        .task { await model.reload() }
        .sheet(isPresented: $creating) {
            ConnectionEditor(context: context, broker: model.broker, connection: AppConnection(name: "", kind: .remoteMCP, endpoint: ""), isNew: true) { Task { await model.reload() } }
        }
        .sheet(item: $editing) { connection in
            ConnectionEditor(context: context, broker: model.broker, connection: connection, isNew: false) { Task { await model.reload() } }
        }
    }
    @ViewBuilder private func actions(_ connection: AppConnection) -> some View {
        Button(connection.status == .disconnected ? "Reconnect…" : "Manage…") { editing = connection }.accessibilityIdentifier("connections.manage.\(connection.id.uuidString.lowercased())")
        Button(model.busy == connection.id ? "Working…" : "Test tools") { Task { await model.test(connection) } }
            .disabled(model.busy != nil || connection.status == .disconnected)
            .accessibilityIdentifier("connections.test.\(connection.id.uuidString.lowercased())")
        if connection.status != .disconnected {
            Button("Disconnect", role: .destructive) { Task { await model.disconnect(connection) } }
                .disabled(model.busy != nil).accessibilityIdentifier("connections.disconnect.\(connection.id.uuidString.lowercased())")
        }
    }
}

private struct ConnectionEditor: View {
    let context: AppContext
    let broker: ConnectionBroker
    let isNew: Bool
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppConnection
    @State private var arguments: String
    @State private var credentials = ""
    @State private var protectedEndpoint = ""
    @State private var error: String?
    @State private var busy = false
    @State private var bots: [BotDefinition] = []
    @State private var tasks: [ScheduledTask] = []
    init(context: AppContext, broker: ConnectionBroker, connection: AppConnection, isNew: Bool, saved: @escaping () -> Void) {
        self.context = context; self.broker = broker; self.isNew = isNew; self.saved = saved
        _draft = State(initialValue: connection)
        _arguments = State(initialValue: String(data: (try? JSONEncoder().encode(connection.arguments)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]")
    }
    var body: some View {
        AgentChoiceSheet(icon: "puzzlepiece.extension", tint: DS.Palette.accent, title: isNew ? "Add connection" : "Manage connection", subtitle: isNew ? "Services belong to MacCode, independently of your model." : "These are the current settings. Edit them and save to apply.", accessibilityIdentifier: "connections.editor", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                TextField("Service name", text: $draft.name).accessibilityIdentifier("connections.editor.name")
                TextField("Account label (optional)", text: $draft.account).accessibilityIdentifier("connections.editor.account")
                Picker("Type", selection: $draft.kind) { ForEach(ConnectionKind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) } }
                    .accessibilityIdentifier("connections.editor.kind")
                if draft.kind == .stdio {
                    TextField("Absolute executable path", text: $draft.endpoint)
                        .font(DS.Font.mono).accessibilityIdentifier("connections.editor.endpoint")
                } else {
                    SecureField(isNew || draft.status == .disconnected ? "HTTPS MCP endpoint" : "Protected endpoint (empty keeps current)", text: $protectedEndpoint)
                        .font(DS.Font.mono).accessibilityIdentifier("connections.editor.endpoint")
                    if !isNew { Text("Endpoint stored securely for \(URL(string: draft.endpoint)?.host ?? "this service").").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
                }
                if draft.kind == .stdio {
                    TextField("Arguments as JSON array", text: $arguments).font(DS.Font.mono).accessibilityIdentifier("connections.editor.arguments")
                }
                SecureField(draft.kind == .stdio ? "Protected environment JSON (optional)" : "Protected headers JSON (optional)", text: $credentials)
                    .accessibilityIdentifier("connections.editor.credentials")
                Text(isNew ? "The full remote endpoint and protected credentials stay in this Mac's Keychain. Enter headers or environment values as a JSON object. Keep secrets out of local command arguments." : draft.status == .disconnected ? (draft.kind == .stdio ? "Re-enter required environment credentials to reconnect. Disconnect removed protected values from Keychain." : "Re-enter the full remote endpoint and any required credentials to reconnect. Disconnect removed protected values from Keychain.") : "Leave protected fields empty to keep their current values. Enter replacement headers or environment values as a JSON object. Disconnect removes protected values from Keychain.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text("Supports stdio and Streamable HTTP with MCP handshake versions 2024-11-05, 2025-03-26, 2025-06-18 and 2025-11-25. Newer protocols require a compatible endpoint.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                if draft.kind == .composio {
                    Text("Use the hosted session MCP URL and its authentication headers from your own Composio project. This does not create a Composio project or authorize third-party accounts. Complete OAuth consent in Composio first.")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Link("Composio MCP setup", destination: URL(string: "https://docs.composio.dev/docs/sessions-via-mcp")!)
                }
                Toggle("Allow all bots, workspaces and tasks", isOn: $draft.access.allRuns).accessibilityIdentifier("connections.editor.allRuns")
                if !draft.access.allRuns {
                    DisclosureGroup("Selected access") {
                        VStack(alignment: .leading, spacing: DS.Space.md) {
                            Text("Bots").font(DS.Font.captionStrong)
                            ForEach(bots, id: \.id) { bot in scopeToggle(bot.name, id: bot.id.value.uuidString.lowercased(), values: $draft.access.botIDs) }
                            Text("Workspaces").font(DS.Font.captionStrong)
                            ForEach(context.state.workspaces.values.sorted { $0.name < $1.name }) { workspace in scopeToggle(workspace.name, id: workspace.id.value.uuidString.lowercased(), values: $draft.access.workspaceIDs) }
                            Text("Scheduled tasks").font(DS.Font.captionStrong)
                            ForEach(tasks) { task in scopeToggle(task.title, id: task.id.uuidString.lowercased(), values: $draft.access.taskIDs) }
                            if bots.isEmpty && context.state.workspaces.isEmpty && tasks.isEmpty { Text("Create a bot, workspace or task to grant selected access.").font(DS.Font.caption) }
                        }
                    }
                }
                if let error { Text(error).font(DS.Font.caption).foregroundStyle(DS.Palette.danger).accessibilityIdentifier("connections.editor.error") }
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button(busy ? "Saving…" : "Save connection") { Task { await save() } }.buttonStyle(DSPrimaryButtonStyle()).disabled(busy)
                        .accessibilityIdentifier("connections.editor.save")
                }
            }.padding(DS.Space.lg)
        } footer: { EmptyView() }
        .task {
            do { bots = try context.botStore.listCached(); tasks = try ScheduledTaskStore(db: context.db).list() }
            catch { self.error = "Access choices could not be loaded. Existing grants are preserved." }
        }
    }
    private func scopeToggle(_ label: String, id: String, values: Binding<[String]>) -> some View {
        Toggle(label, isOn: Binding(get: { values.wrappedValue.contains(id) }, set: { selected in
            if selected { if !values.wrappedValue.contains(id) { values.wrappedValue.append(id) } }
            else { values.wrappedValue.removeAll { $0 == id } }
        }))
    }
    private func save() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if draft.kind == .stdio {
                guard let parsed = try? JSONDecoder().decode([String].self, from: Data(arguments.utf8)) else { throw ConnectionError.invalidConfiguration }
                draft.arguments = parsed
            } else {
                draft.arguments = []
                if draft.status == .disconnected && protectedEndpoint.isEmpty { throw ConnectionError.endpointRequired }
                if !protectedEndpoint.isEmpty { draft.endpoint = protectedEndpoint }
            }
            var protected: [String: String]?
            if !credentials.isEmpty {
                guard let parsed = try? JSONDecoder().decode([String: String].self, from: Data(credentials.utf8)) else { throw ConnectionError.invalidConfiguration }
                protected = parsed
            }
            try await broker.save(draft, credentials: protected, expectedRevision: isNew ? nil : draft.revision)
            credentials = ""; saved(); dismiss()
        } catch { self.error = (error as? ConnectionError)?.description ?? ConnectionError.storage.description }
    }
}
