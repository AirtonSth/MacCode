import SwiftUI
import CoreModel
import Persistence
import AgentRuntime
import DesignSystemKit
import Surfaces

struct AppConnectionAccessSheet: View {
    let context: AppContext
    let title: String
    let actionTitle: String
    let action: @MainActor (ConnectionAccess) async -> Bool
    let errorMessage: @MainActor () -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var access: ConnectionAccess
    @State private var bots: [BotDefinition] = []
    @State private var tasks: [ScheduledTask] = []
    @State private var busy = false
    @State private var loadError: String?
    init(context: AppContext, title: String, initialAccess: ConnectionAccess, actionTitle: String,
         errorMessage: @escaping @MainActor () -> String? = { nil }, action: @escaping @MainActor (ConnectionAccess) async -> Bool) {
        self.context = context; self.title = title; self.actionTitle = actionTitle; self.action = action; self.errorMessage = errorMessage
        _access = State(initialValue: initialAccess)
    }
    var body: some View {
        AgentChoiceSheet(icon: "puzzlepiece.extension", tint: DS.Palette.accent, title: title,
                         subtitle: "Choose who can use this account. You can change access later.",
                         accessibilityIdentifier: "connections.access", onClose: { if !busy { dismiss() } }) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                Toggle("Allow All Bots, Workspaces and Tasks", isOn: $access.allRuns)
                    .accessibilityIdentifier("connections.access.allRuns")
                if !access.allRuns {
                    if let loadError { Text(loadError).foregroundStyle(DS.Palette.danger).font(DS.Font.caption) }
                    Text("Bots").font(DS.Font.bodyStrong)
                    ForEach(bots, id: \.id) { bot in accessToggle(bot.name, id: bot.id.value.uuidString.lowercased(), values: $access.botIDs) }
                    Text("Workspaces").font(DS.Font.bodyStrong)
                    ForEach(context.state.workspaces.values.sorted { $0.name < $1.name }) { workspace in
                        accessToggle(workspace.name, id: workspace.id.value.uuidString.lowercased(), values: $access.workspaceIDs)
                    }
                    if !tasks.isEmpty {
                        Text("Scheduled Tasks").font(DS.Font.bodyStrong)
                        ForEach(tasks) { task in accessToggle(task.title, id: task.id.uuidString.lowercased(), values: $access.taskIDs) }
                    }
                    if access.botIDs.isEmpty && access.workspaceIDs.isEmpty && access.taskIDs.isEmpty && access.threadIDs.isEmpty {
                        Text("No access is granted yet. You can connect an account now and choose access later.")
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let message = errorMessage() {
                    Text(message).font(DS.Font.caption).foregroundStyle(DS.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("connections.access.error")
                }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                    Spacer()
                    Button(busy ? "Saving…" : actionTitle) {
                        busy = true
                        Task { if await action(access) { dismiss() }; busy = false }
                    }.buttonStyle(DSPrimaryButtonStyle()).disabled(busy || loadError != nil).accessibilityIdentifier("connections.access.confirm")
                }
            }.padding(DS.Space.lg)
        } footer: { EmptyView() }
        .task {
            do { bots = try context.botStore.listCached(); tasks = try ScheduledTaskStore(db: context.db).list() }
            catch { loadError = "Access choices could not be loaded. Close this window and try again." }
        }
    }
    private func accessToggle(_ title: String, id: String, values: Binding<[String]>) -> some View {
        Toggle(title, isOn: Binding(get: { values.wrappedValue.contains(id) }, set: { selected in
            if selected { if !values.wrappedValue.contains(id) { values.wrappedValue.append(id) } }
            else { values.wrappedValue.removeAll { $0 == id } }
        }))
    }
}

struct ComposioProjectSetupView: View {
    @ObservedObject var model: AppsCatalogModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var busy = false
    var body: some View {
        AgentChoiceSheet(icon: "puzzlepiece.extension", tint: DS.Palette.accent,
                         title: "Set Up App Connections", subtitle: "One-time setup for your own Composio project.",
                         accessibilityIdentifier: "connections.project", onClose: { if !busy { dismiss() } }) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                Text("Use a project API key from your Composio account. MacCode stores it in this Mac's Keychain and uses it to open secure account authorization. It is not sent to your language model.")
                    .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                Link("Open Composio Project Settings", destination: URL(string: "https://platform.composio.dev/")!)
                SecureField(model.configured ? "Replacement project API key" : "Composio project API key", text: $key)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("connections.project.key")
                Text("Each app opens its own authorization page. Your accounts and projects connected in OpenMausBot are not copied into MacCode.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.error { Text(error).font(DS.Font.caption).foregroundStyle(DS.Palette.danger).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Button("Cancel") { key = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                    Spacer()
                    Button(busy ? "Verifying…" : "Save and Continue") {
                        busy = true
                        Task {
                            if await model.setup(key: key) { key = ""; dismiss() }
                            busy = false
                        }
                    }.buttonStyle(DSPrimaryButtonStyle()).disabled(busy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("connections.project.save")
                }
            }.padding(DS.Space.lg)
        } footer: { EmptyView() }
    }
}
