import Foundation
import AppKit
import SwiftUI
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

    public init(context: AppContext, router: AppCommandRouter) {
        self.context = context
        self.router = router
        reload()
    }

    public func reload() {
        guard let ctx = context else { return }
        workspaces = ctx.state.window.workspaces.compactMap { ctx.state.workspaces[$0] }
        selectedWorkspaceID = ctx.state.window.selectedWorkspaceID
    }

    public func select(_ wid: WorkspaceID) {
        try? router?.selectWorkspace(wid)
    }

    public func newWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            _ = try? router?.createWorkspace(name: url.lastPathComponent, cwd: url.path)
        }
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

    public func removeWorkspace(_ ws: Workspace) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(ws.name)”?"
        alert.informativeText = "This removes the workspace and its tabs from RemoteCode 2. Files on disk are not touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? router?.closeWorkspace(ws.id)
        }
    }
}

public struct SidebarRootView: View {
    @ObservedObject var vm: SidebarViewModel
    public init(vm: SidebarViewModel) { self.vm = vm }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44)

            Button { vm.newWorkspace() } label: {
                sidebarActionRow(symbol: "folder.badge.plus", title: "New Workspace")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.Space.md)
            .padding(.bottom, DS.Space.lg)

            Text("Workspaces")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
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
        // The host sits in a full-height window; without this SwiftUI
        // treats the titlebar as a safe area and pushes the header
        // below the traffic lights instead of beside them.
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
        let desc = ws.metadata["description"]
        // A3: spinner when any surface in this workspace is busy.
        let busy = ws.layout.paneIDs().contains { pid in
            (ws.layout.find(paneID: pid)?.surfaces ?? []).contains {
                SurfaceRegistry.shared.surface($0.id)?.isBusy == true
            }
        }
        Button { vm.select(ws.id) } label: {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20, height: 20)
                    .foregroundColor(TabColor.from(ws.metadata["color"]).map { Color(hex: $0.hex) }
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
                    .fill(selected ? DS.Palette.selection.opacity(0.75) : Color.white.opacity(0.001))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
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
