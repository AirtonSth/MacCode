import Foundation
import CoreModel
import DesignSystemKit
import Persistence
import SocketServer
import SwiftUI

enum WorkspaceAssignmentKind: String, CaseIterable, Identifiable {
    case bots, virtualMachines
    var id: Self { self }
    var title: String { self == .bots ? "Bots" : "Virtual machines" }
}

enum BotWorkspaceAssignmentResource: Hashable {
    case bot(BotID)
    case virtualMachine(UUID)
}

/// Existing resources only. Both workspace and resource menus mount this same
/// editor; all mutations go through the host's durable receipt/authority path.
struct WorkspaceResourceAssignmentView: View {
    let router: AppCommandRouter
    var workspaceID: WorkspaceID? = nil
    var resource: BotWorkspaceAssignmentResource? = nil
    var initialKind: WorkspaceAssignmentKind = .bots
    @Environment(\.dismiss) private var dismiss
    @State private var kind: WorkspaceAssignmentKind = .bots
    @State private var target: WorkspaceID?
    @State private var search = ""
    @State private var bots: [BotDefinition] = []
    @State private var machines: [BotVirtualMachine] = []
    @State private var loading = true
    @State private var saving = false
    @State private var revokeOtherContexts = false
    @State private var error: String?
    @State private var notice: String?

    private var workspaces: [Workspace] {
        (router.context?.state.workspaces.values.map { $0 } ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack {
                Text(resource == nil ? "Attach existing resources" : "Move to workspace")
                    .font(DS.Font.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
            }
            Text("Bots become exclusive to the workspace. Existing identities, conversations and computer files are preserved.")
                .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let workspaceID {
                Text("Workspace · \(scopeName(workspaceID))").font(DS.Font.bodyStrong)
            } else {
                Picker("Destination", selection: $target) {
                    Text("General").tag(WorkspaceID?.none)
                    ForEach(workspaces) { workspace in Text(workspace.name).tag(Optional(workspace.id)) }
                }
                .accessibilityIdentifier("workspace.assignment.destination")
                .disabled(saving || loading)
            }
            if resource == nil {
                Picker("Resources", selection: $kind) {
                    ForEach(WorkspaceAssignmentKind.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                TextField("Search existing resources", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("workspace.assignment.search")
            }
            if kind == .bots {
                Toggle("Revoke access outside this workspace", isOn: $revokeOtherContexts)
                    .font(DS.Font.body)
                    .disabled(saving)
                    .accessibilityIdentifier("workspace.assignment.revokeOutside")
                Text("If required, select this to remove access in General and other workspaces. Stored history remains; conversations using revoked access cannot continue there.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.md) {
                    if kind == .bots {
                        ForEach(visibleBots, id: \.id) { bot in
                            assignmentRow(name: bot.name, scope: bot.workspaceID, assigned: bot.workspaceID == target) {
                                await moveBot(bot)
                            }
                            .accessibilityIdentifier("workspace.assignment.bot.\(bot.id.value.uuidString)")
                        }
                    } else {
                        ForEach(visibleMachines) { machine in
                            assignmentRow(name: machine.name, scope: machine.workspaceID, assigned: machine.workspaceID == target) {
                                await moveMachine(machine)
                            }
                            .accessibilityIdentifier("workspace.assignment.vm.\(machine.id.uuidString)")
                        }
                    }
                    if !loading && (kind == .bots ? visibleBots.isEmpty : visibleMachines.isEmpty) {
                        Text("No existing resources match.").font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
            }
            .frame(minHeight: 150, maxHeight: 380)
            if loading || saving { ProgressView(saving ? "Saving assignment…" : "Loading existing resources…").controlSize(.small) }
            if let error {
                Text(error).font(DS.Font.body).foregroundStyle(DS.Palette.danger)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workspace.assignment.error")
                Button("Refresh resources") { Task { await reload() } }.disabled(saving)
            }
            if let notice {
                Text(notice).font(DS.Font.caption).foregroundStyle(DS.Palette.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.xl)
        .frame(minWidth: 320, idealWidth: 560, maxWidth: 680)
        .task {
            target = workspaceID
            switch resource {
            case .bot: kind = .bots
            case .virtualMachine: kind = .virtualMachines
            case nil: kind = initialKind
            }
            await reload()
            if workspaceID == nil {
                switch resource {
                case .bot(let id): target = bots.first { $0.id == id }?.workspaceID
                case .virtualMachine(let id): target = machines.first { $0.id == id }?.workspaceID
                case nil: break
                }
            }
        }
    }

    private var visibleBots: [BotDefinition] {
        bots.filter { bot in
            if let resource, resource != .bot(bot.id) { return false }
            return search.isEmpty || bot.name.localizedCaseInsensitiveContains(search) || scopeName(bot.workspaceID).localizedCaseInsensitiveContains(search)
        }
    }

    private var visibleMachines: [BotVirtualMachine] {
        machines.filter { machine in
            if let resource, resource != .virtualMachine(machine.id) { return false }
            return search.isEmpty || machine.name.localizedCaseInsensitiveContains(search) || scopeName(machine.workspaceID).localizedCaseInsensitiveContains(search)
        }
    }

    private func scopeName(_ id: WorkspaceID?) -> String {
        guard let id else { return "General" }
        return workspaces.first { $0.id == id }?.name ?? "Workspace unavailable"
    }

    private func assignmentRow(name: String, scope: WorkspaceID?, assigned: Bool, action: @escaping () async -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.md) {
                rowIdentity(name: name, scope: scope)
                Spacer(minLength: DS.Space.md)
                assignmentButton(assigned: assigned, action: action)
            }
            VStack(alignment: .leading, spacing: DS.Space.md) {
                rowIdentity(name: name, scope: scope)
                assignmentButton(assigned: assigned, action: action)
            }
        }
        .padding(DS.Space.lg)
        .background(DS.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func rowIdentity(name: String, scope: WorkspaceID?) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(name).font(DS.Font.bodyStrong).fixedSize(horizontal: false, vertical: true)
            Text("Current · \(scopeName(scope))").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private func assignmentButton(assigned: Bool, action: @escaping () async -> Void) -> some View {
        Button(assigned ? "Assigned" : (workspaceID == nil ? "Move" : "Attach")) { Task { await action() } }
            .disabled(assigned || saving || loading || (target != nil && !workspaces.contains { $0.id == target }))
    }

    @MainActor private func reload() async {
        guard let store = router.context?.botStore else { error = "Bot runtime is unavailable."; loading = false; return }
        loading = true
        defer { loading = false }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                (try store.list(includeHidden: true), try store.listVirtualMachines())
            }.value
            guard !Task.isCancelled else { return }
            bots = loaded.0
            machines = loaded.1
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func moveBot(_ bot: BotDefinition) async {
        guard let revision = bot.currentRevisionID, let hostID = router.context?.liveActivityHostIdentity.serverId else {
            error = "The current bot or host is unavailable. Refresh resources."; return
        }
        await save(method: "bot.workspace.transfer", params: [
            "bot_id": .string(bot.id.value.uuidString.lowercased()), "host_id": .string(hostID),
            "workspace_id": workspaceValue(target), "expected_workspace_id": workspaceValue(bot.workspaceID),
            "expected_current_revision_id": .string(revision.value.uuidString.lowercased()),
            "revoke_other_contexts": .bool(revokeOtherContexts),
        ], name: bot.name)
    }

    @MainActor private func moveMachine(_ machine: BotVirtualMachine) async {
        await save(method: "bot.vm.transfer", params: [
            "vm_id": .string(machine.id.uuidString.lowercased()), "workspace_id": workspaceValue(target),
            "expected_workspace_id": workspaceValue(machine.workspaceID),
        ], name: machine.name)
    }

    private func workspaceValue(_ id: WorkspaceID?) -> JSONValue {
        id.map { .string($0.value.uuidString.lowercased()) } ?? .null
    }

    @MainActor private func save(method: String, params: [String: JSONValue], name: String) async {
        saving = true; error = nil; notice = nil
        defer { saving = false }
        var params = params
        params["client_request_id"] = .string(UUID().uuidString.lowercased())
        do {
            let result = try await router.dispatchPairedBotRemote(method: method, params: params)
            guard case .object(let receipt) = result, receipt["status"] == .string("completed") else {
                if case .object(let receipt) = result, case .object(let readback) = receipt["readback"],
                   case .string(let message) = readback["error"] {
                    error = message
                } else { error = "The assignment was not completed. Refresh resources before trying again." }
                return
            }
            notice = "\(name) is assigned to \(scopeName(target))."
            await reload()
        } catch { self.error = error.localizedDescription }
    }
}
