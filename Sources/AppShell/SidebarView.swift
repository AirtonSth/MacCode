import Foundation
import AppKit
import SwiftUI
import CoreModel
import Persistence
import DesignSystemKit

@MainActor
public final class SidebarViewModel: ObservableObject {
    public weak var context: AppContext?
    public weak var router: AppCommandRouter?

    @Published public var workspaces: [Workspace] = []
    @Published public var selectedWorkspaceID: WorkspaceID?
    @Published public var threadsByWorkspace: [WorkspaceID: [AgentThread]] = [:]

    public init(context: AppContext, router: AppCommandRouter) {
        self.context = context
        self.router = router
        reload()
    }

    public func reload() {
        guard let ctx = context else { return }
        workspaces = ctx.state.window.workspaces.compactMap { ctx.state.workspaces[$0] }
        selectedWorkspaceID = ctx.state.window.selectedWorkspaceID
        var map: [WorkspaceID: [AgentThread]] = [:]
        for ws in workspaces {
            map[ws.id] = (try? ctx.threadRepo.list(workspaceId: ws.id)) ?? []
        }
        threadsByWorkspace = map
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
}

public struct SidebarRootView: View {
    @ObservedObject var vm: SidebarViewModel
    public init(vm: SidebarViewModel) { self.vm = vm }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Palette.accent)
                Text("RemoteCode 2")
                    .font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                Spacer()
                DSIconButton("plus", help: "New workspace") { vm.newWorkspace() }
            }
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
            .dsBar(edge: .bottom)

            if vm.workspaces.isEmpty {
                DSEmptyState(icon: "folder.badge.plus",
                             title: "No workspaces",
                             subtitle: "Press ⌘N or the + button to open a folder as a workspace.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(vm.workspaces, id: \.id) { ws in
                            workspaceSection(ws)
                        }
                    }.padding(DS.Space.sm)
                }
            }
        }
        .background(DS.Palette.surface)
    }

    @ViewBuilder
    private func workspaceSection(_ ws: Workspace) -> some View {
        let selected = vm.selectedWorkspaceID == ws.id
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Button { vm.select(ws.id) } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "folder")
                        .font(.system(size: 11)).foregroundColor(DS.Palette.textSecondary)
                    Text(ws.name).font(DS.Font.bodyStrong)
                        .foregroundColor(DS.Palette.text).lineLimit(1)
                    Spacer(minLength: 0)
                    if ws.notificationsUnread > 0 {
                        DSPill("\(ws.notificationsUnread)", tone: .accent)
                    }
                }
                .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
                .background(selected ? DS.Palette.selection : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(vm.threadsByWorkspace[ws.id] ?? [], id: \.id) { thread in
                HStack(spacing: DS.Space.sm) {
                    Circle()
                        .fill(thread.status == .running ? DS.Palette.success : DS.Palette.textTertiary)
                        .frame(width: 5, height: 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(thread.title).font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary).lineLimit(1)
                        Text("\(thread.provider.rawValue) · \(thread.model)")
                            .font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, DS.Space.xxl).padding(.trailing, DS.Space.md)
                .padding(.vertical, DS.Space.xs)
            }
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
        self.host = h
        let container = NSView()
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
