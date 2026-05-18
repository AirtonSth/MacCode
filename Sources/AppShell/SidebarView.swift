import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoreModel
import Persistence
import Surfaces
import DesignSystemKit

@MainActor
public final class SidebarViewModel: ObservableObject {
    public weak var context: AppContext?
    public weak var router: AppCommandRouter?

    @Published public var workspaces: [Workspace] = []
    @Published public var selectedWorkspaceID: WorkspaceID?
    @Published public var selectedWorkspaceIDs: Set<WorkspaceID> = []
    public var draggingWorkspaceID: WorkspaceID?
    private var selectionAnchorID: WorkspaceID?

    public init(context: AppContext, router: AppCommandRouter) {
        self.context = context
        self.router = router
        reload()
    }

    public func reload() {
        guard let ctx = context else { return }
        workspaces = (try? router?.listWorkspaces()) ?? ctx.state.window.workspaces.compactMap { ctx.state.workspaces[$0] }
        selectedWorkspaceID = ctx.state.window.selectedWorkspaceID
        selectedWorkspaceIDs = selectedWorkspaceIDs.intersection(Set(workspaces.map(\.id)))
    }

    public func select(_ wid: WorkspaceID) {
        selectedWorkspaceIDs.removeAll()
        selectionAnchorID = wid
        try? router?.selectWorkspace(wid)
    }

    public func selectWorkspaceRow(_ ws: Workspace, extendingSelection: Bool) {
        if extendingSelection {
            extendWorkspaceSelection(to: ws.id)
        } else {
            select(ws.id)
        }
    }

    private func extendWorkspaceSelection(to id: WorkspaceID) {
        let anchor = selectionAnchorID ?? selectedWorkspaceID ?? id
        guard let start = workspaces.firstIndex(where: { $0.id == anchor }),
              let end = workspaces.firstIndex(where: { $0.id == id }) else {
            selectedWorkspaceIDs.insert(id)
            selectionAnchorID = id
            return
        }
        let range = start <= end ? start...end : end...start
        selectedWorkspaceIDs = Set(range.map { workspaces[$0].id })
    }

    public func newWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            _ = try? router?.createWorkspace(name: url.lastPathComponent, cwd: url.path)
        }
    }

    public func toggleSidebar() {
        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
    }

    // MARK: cmux-style workspace editing (AppKit prompts — reliable,
    // no SwiftUI sheet plumbing).

    private func prompt(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        field.placeholderString = title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn
            ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }

    public func renameWorkspace(_ ws: Workspace) {
        guard let name = prompt(title: "Rename workspace",
                                message: "New name for “\(ws.name)”.",
                                initial: ws.name), !name.isEmpty else { return }
        try? router?.renameWorkspace(ws.id, name)
    }

    public func editDescription(_ ws: Workspace) {
        let current = ws.metadata["description"] ?? ""
        guard let text = prompt(title: "Workspace description",
                                message: "Optional note for “\(ws.name)”.",
                                initial: current) else { return }
        try? router?.setWorkspaceDescription(ws.id, text)
    }

    public func setWorkspaceColor(_ ws: Workspace, _ color: String) {
        try? router?.setWorkspaceColor(ws.id, color)
    }

    public func setWorkspacePinned(_ ws: Workspace, _ pinned: Bool) {
        try? router?.setWorkspacePinned(ws.id, pinned)
        reload()
    }

    public func reorderWorkspace(_ dragged: WorkspaceID, before target: WorkspaceID) {
        guard dragged != target,
              let targetIndex = workspaces.firstIndex(where: { $0.id == target }) else { return }
        try? router?.reorderWorkspace(dragged, position: targetIndex)
        draggingWorkspaceID = nil
        reload()
    }

    public func removeWorkspace(_ ws: Workspace) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(ws.name)”?"
        alert.informativeText = "This removes the workspace and its tabs from RemoteCode. Files on disk are not touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? router?.closeWorkspace(ws.id)
        }
    }

    public func removeSelectedWorkspaces() {
        let ids = selectedWorkspaceIDs
        guard !ids.isEmpty else { return }
        let names = workspaces.filter { ids.contains($0.id) }.map(\.name)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(ids.count) workspaces?"
        alert.informativeText = "This removes the selected workspaces and their tabs from RemoteCode. Files on disk are not touched.\n\n" + names.joined(separator: "\n")
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for id in ids {
            try? router?.closeWorkspace(id)
        }
        selectedWorkspaceIDs.removeAll()
        selectionAnchorID = nil
        reload()
    }
}

public struct SidebarRootView: View {
    @ObservedObject var vm: SidebarViewModel
    public init(vm: SidebarViewModel) { self.vm = vm }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44)

            HStack(spacing: DS.Space.xs) {
                Button { vm.newWorkspace() } label: {
                    sidebarActionRow(symbol: "folder.badge.plus", title: "New Workspace")
                }
                .buttonStyle(.plain)
                .help("Create new workspace")

                Button { vm.toggleSidebar() } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle sidebar")
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.bottom, DS.Space.lg)

            HStack(spacing: DS.Space.sm) {
                Text("Workspaces")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer(minLength: 0)
                if !vm.selectedWorkspaceIDs.isEmpty {
                    Button("Remove") { vm.removeSelectedWorkspaces() }
                        .buttonStyle(.plain)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.danger)
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.sm)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                    if vm.workspaces.isEmpty {
                        Text("No workspaces")
                            .font(DS.Font.body)
                            .foregroundColor(DS.Palette.textTertiary)
                            .padding(.horizontal, DS.Space.md)
                            .padding(.vertical, DS.Space.sm)
                    } else {
                        ForEach(vm.workspaces, id: \.id) { ws in
                            workspaceRow(ws)
                        }
                    }
                }
                .padding(.horizontal, DS.Space.sm)
            }.padding(.bottom, DS.Space.md)
        }
        // Subtle liquid-glass: a near-transparent tint over the
        // NSVisualEffectView the host sits in (see SidebarView).
        .background(DS.Palette.surface.opacity(0.55))
        // The sidebar material reaches the top edge; only its controls
        // start below the traffic-light band.
        .ignoresSafeArea(.container, edges: .top)
    }

    private func sidebarActionRow(symbol: String, title: String) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 20, height: 20)
                .foregroundColor(DS.Palette.text)
            Text(title)
                .font(DS.Font.bodyStrong)
                .foregroundColor(DS.Palette.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: 42)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(Color.white.opacity(0.001))
        )
    }

    @ViewBuilder
    private func workspaceRow(_ ws: Workspace) -> some View {
        let selected = vm.selectedWorkspaceID == ws.id
        let checked = vm.selectedWorkspaceIDs.contains(ws.id)
        let desc = ws.metadata["description"]
        let pinned = ws.metadata["pinned"] == "true"
        // A3: spinner when any surface in this workspace is busy.
        let busy = ws.layout.paneIDs().contains { pid in
            (ws.layout.find(paneID: pid)?.surfaces ?? []).contains {
                SurfaceRegistry.shared.surface($0.id)?.isBusy == true
            }
        }
        Button {
            vm.selectWorkspaceRow(ws, extendingSelection: NSEvent.modifierFlags.contains(.shift))
        } label: {
            HStack(spacing: DS.Space.sm) {
                if checked {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .regular))
                        .frame(width: 20, height: 20)
                        .foregroundColor(DS.Palette.accent)
                }
                Image(systemName: pinned ? "pin.fill" : "folder.fill")
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20, height: 20)
                    .foregroundColor(pinned ? DS.Palette.accent :
                        TabColor.from(ws.metadata["color"]).map { Color(hex: $0.hex) }
                        ?? DS.Palette.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ws.name).font(selected ? DS.Font.bodyStrong : DS.Font.body)
                        .foregroundColor(DS.Palette.text).lineLimit(1)
                    if let d = desc, !d.isEmpty {
                        Text(d).font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                if ws.notificationsUnread > 0 {
                    DSPill("\(ws.notificationsUnread)", tone: .accent)
                }
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(checked ? DS.Palette.accent.opacity(0.22)
                          : selected ? DS.Palette.selection.opacity(0.75)
                          : Color.white.opacity(0.001))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ws.cwd.isEmpty ? ws.name : ws.cwd)
        .onDrag {
            vm.draggingWorkspaceID = ws.id
            return NSItemProvider(object: ws.id.value.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: WorkspaceDropDelegate(vm: vm, target: ws))
        .contextMenu {
            Button { vm.setWorkspacePinned(ws, !pinned) } label: {
                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
            }
            Divider()
            Button("Rename…") { vm.renameWorkspace(ws) }
            Button("Edit description…") { vm.editDescription(ws) }
            Menu("Color") {
                Button("None") { vm.setWorkspaceColor(ws, "") }
                ForEach(TabColor.allCases, id: \.self) { c in
                    Button(c.label) { vm.setWorkspaceColor(ws, c.rawValue) }
                }
            }
            Divider()
            Button("Remove", role: .destructive) { vm.removeWorkspace(ws) }
        }
    }
}

private struct WorkspaceDropDelegate: DropDelegate {
    @ObservedObject var vm: SidebarViewModel
    let target: Workspace

    func dropEntered(info: DropInfo) {
        guard let dragged = vm.draggingWorkspaceID else { return }
        vm.reorderWorkspace(dragged, before: target.id)
    }

    func performDrop(info: DropInfo) -> Bool {
        vm.draggingWorkspaceID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

@MainActor
public final class SidebarView: NSObject {
    public let view: NSView
    public weak var context: AppContext?
    public weak var router: AppCommandRouter?
    private let viewModel: SidebarViewModel
    private let host: NSHostingView<SidebarRootView>

    public init(context: AppContext, router: AppCommandRouter) {
        self.context = context
        self.router = router
        self.viewModel = SidebarViewModel(context: context, router: router)
        let h = NSHostingView(rootView: SidebarRootView(vm: viewModel))
        h.translatesAutoresizingMaskIntoConstraints = false
        // NSHostingView is opaque by default; let the vibrancy show.
        h.wantsLayer = true
        h.layer?.backgroundColor = NSColor.clear.cgColor
        self.host = h
        // Subtle Liquid Glass: an under-window vibrancy material behind
        // the translucent SwiftUI sidebar. Chrome only — per design rules
        // glass never goes on main content.
        let container = NSVisualEffectView()
        container.material = .underWindowBackground
        container.blendingMode = .behindWindow
        container.state = .active
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: container.topAnchor),
            h.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            h.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        self.view = container
        super.init()
    }

    public func refresh() {
        viewModel.reload()
    }
}
