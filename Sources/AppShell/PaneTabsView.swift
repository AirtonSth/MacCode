import Foundation
import AppKit
import CoreModel
import Surfaces

@MainActor
public final class PaneTabsView: NSObject, NSTabViewDelegate {
    public let view: NSView
    public let pane: PaneNode
    public weak var router: AppCommandRouter?
    private let tabView = NSTabView()
    private let tabBar = NSView()

    public init(pane: PaneNode, router: AppCommandRouter?) {
        self.pane = pane
        self.router = router
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        self.view = v

        super.init()

        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self
        for desc in pane.surfaces {
            let item = NSTabViewItem(identifier: desc.id.value.uuidString)
            item.label = desc.title
            if let surface = SurfaceRegistry.shared.surface(desc.id) {
                let host = NSView()
                host.translatesAutoresizingMaskIntoConstraints = false
                let sv = surface.view
                sv.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(sv)
                NSLayoutConstraint.activate([
                    sv.topAnchor.constraint(equalTo: host.topAnchor),
                    sv.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    sv.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    sv.trailingAnchor.constraint(equalTo: host.trailingAnchor)
                ])
                item.view = host
            } else {
                let placeholder = NSTextField(labelWithString: "(missing surface \(desc.type.rawValue))")
                placeholder.textColor = .secondaryLabelColor
                placeholder.translatesAutoresizingMaskIntoConstraints = false
                let host = NSView()
                host.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(placeholder)
                NSLayoutConstraint.activate([
                    placeholder.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                    placeholder.centerYAnchor.constraint(equalTo: host.centerYAnchor)
                ])
                item.view = host
            }
            tabView.addTabViewItem(item)
            if pane.selectedSurfaceID == desc.id {
                tabView.selectTabViewItem(item)
            }
        }

        // Toolbar for + surface buttons
        let addTerminal = NSButton(title: "+ Term", target: self, action: #selector(addTerminal))
        let addBrowser = NSButton(title: "+ Browser", target: self, action: #selector(addBrowser))
        let addAgent = NSButton(title: "+ Agent", target: self, action: #selector(addAgent))
        let splitRight = NSButton(title: "↦ Split", target: self, action: #selector(splitRight))
        for b in [addTerminal, addBrowser, addAgent, splitRight] {
            b.bezelStyle = .recessed
            b.controlSize = .small
        }
        let toolbar = NSStackView(views: [addTerminal, addBrowser, addAgent, NSView(), splitRight])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(toolbar)
        v.addSubview(tabView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            toolbar.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            toolbar.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            toolbar.heightAnchor.constraint(equalToConstant: 22),
            tabView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),
            tabView.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            tabView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: v.trailingAnchor)
        ])
    }

    private func currentWorkspaceID() -> WorkspaceID? {
        router?.context?.state.window.selectedWorkspaceID
    }

    @objc private func addTerminal() { performAdd(.terminal, title: "terminal") }
    @objc private func addBrowser() { performAdd(.browser, title: "browser") }
    @objc private func addAgent() { performAdd(.agentApp, title: "Agent App") }
    @objc private func splitRight() { performSplit(.right, type: .agentApp, title: "Agent App") }

    /// Testable seam shared by the @objc button handlers.
    @discardableResult
    public func performAdd(_ type: SurfaceType, title: String) -> SurfaceDescriptor? {
        guard let wid = currentWorkspaceID() else { return nil }
        return try? router?.createSurface(workspace: wid, type: type, paneID: pane.id, title: title)
    }

    @discardableResult
    public func performSplit(_ direction: SplitDirection, type: SurfaceType, title: String) -> SurfaceDescriptor? {
        guard let wid = currentWorkspaceID() else { return nil }
        return try? router?.splitPane(workspace: wid, paneID: pane.id, direction: direction, surfaceType: type, title: title)
    }

    public func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let item = tabViewItem,
              let idStr = item.identifier as? String,
              let uuid = UUID(uuidString: idStr) else { return }
        let sid = SurfaceID(uuid)
        guard let wid = currentWorkspaceID() else { return }
        try? router?.focusSurface(workspace: wid, surface: sid)
    }
}

