import Foundation
import AppKit
import CoreModel
import Surfaces
import DesignSystemKit

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
        v.wantsLayer = true
        v.layer?.backgroundColor = DS.NS.bg.cgColor
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
                let placeholder = NSTextField(labelWithString: "missing surface · \(desc.type.rawValue)")
                placeholder.textColor = DS.NS.textTertiary
                placeholder.font = NSFont.systemFont(ofSize: 12)
                placeholder.translatesAutoresizingMaskIntoConstraints = false
                let host = NSView()
                host.wantsLayer = true
                host.layer?.backgroundColor = DS.NS.bg.cgColor
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

        // Toolbar for + surface buttons — token-styled flat buttons.
        func mkButton(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.isBordered = false
            b.bezelStyle = .inline
            b.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            b.contentTintColor = DS.NS.textSecondary
            b.wantsLayer = true
            b.layer?.cornerRadius = DS.Radius.control
            b.layer?.backgroundColor = DS.NS.surfaceRaised.cgColor
            let attr = NSMutableAttributedString(string: title, attributes: [
                .foregroundColor: DS.NS.textSecondary,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium)
            ])
            b.attributedTitle = attr
            return b
        }
        let addTerminal = mkButton("+ Term", #selector(addTerminal))
        let addBrowser = mkButton("+ Browser", #selector(addBrowser))
        let addAgent = mkButton("+ Agent", #selector(addAgent))
        let splitRight = mkButton("⇥ Split", #selector(splitRight))

        let toolbar = NSStackView(views: [addTerminal, addBrowser, addAgent, NSView(), splitRight])
        toolbar.orientation = .horizontal
        toolbar.spacing = DS.Space.md
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.md, bottom: 0, right: DS.Space.md)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let toolbarBG = NSView()
        toolbarBG.wantsLayer = true
        toolbarBG.layer?.backgroundColor = DS.NS.surface.cgColor
        toolbarBG.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DS.NS.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(toolbarBG)
        toolbarBG.addSubview(toolbar)
        v.addSubview(divider)
        v.addSubview(tabView)
        NSLayoutConstraint.activate([
            toolbarBG.topAnchor.constraint(equalTo: v.topAnchor),
            toolbarBG.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            toolbarBG.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            toolbarBG.heightAnchor.constraint(equalToConstant: 32),
            toolbar.leadingAnchor.constraint(equalTo: toolbarBG.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: toolbarBG.trailingAnchor),
            toolbar.centerYAnchor.constraint(equalTo: toolbarBG.centerYAnchor),
            divider.topAnchor.constraint(equalTo: toolbarBG.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            tabView.topAnchor.constraint(equalTo: divider.bottomAnchor),
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

