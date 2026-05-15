import Foundation
import AppKit
import SwiftUI
import CoreModel
import Persistence

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
            HStack {
                Text("Workspaces").font(.headline)
                Spacer()
                Button(action: { vm.newWorkspace() }) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
            }.padding(8)
            Divider()
            List(selection: Binding(
                get: { vm.selectedWorkspaceID },
                set: { if let id = $0 { vm.select(id) } }
            )) {
                ForEach(vm.workspaces, id: \.id) { ws in
                    Section(header: HStack {
                        Text(ws.name).font(.body).bold()
                        Spacer()
                        if ws.notificationsUnread > 0 {
                            Text("•\(ws.notificationsUnread)").font(.caption.bold()).foregroundColor(.accentColor)
                        }
                    }) {
                        ForEach(vm.threadsByWorkspace[ws.id] ?? [], id: \.id) { thread in
                            HStack(spacing: 6) {
                                Image(systemName: thread.status == .running ? "circle.fill" : "circle")
                                    .font(.caption2)
                                    .foregroundColor(thread.status == .running ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(thread.title).font(.caption).lineLimit(1)
                                    Text("\(thread.provider.rawValue) · \(thread.model)")
                                        .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                    }.tag(ws.id)
                }
            }
            .listStyle(.sidebar)
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
