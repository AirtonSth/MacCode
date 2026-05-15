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

        // Single "+" pull-down to add a surface to this pane, and a
        // "Split" pull-down with Horizontal / Vertical submenus.
        let addPopup = Self.makePullDown(title: "+")
        addPopup.menu?.addItem(.separator())
        for (label, type) in Self.surfaceChoices {
            let it = NSMenuItem(title: label, action: #selector(addFromMenu(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = type.rawValue
            addPopup.menu?.addItem(it)
        }

        let splitPopup = Self.makePullDown(title: "Split")
        splitPopup.menu?.addItem(.separator())
        for (dirLabel, dir) in [("Horizontal  →", "right"), ("Vertical  ↓", "down")] {
            let parent = NSMenuItem(title: dirLabel, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (label, type) in Self.surfaceChoices {
                let it = NSMenuItem(title: label, action: #selector(splitFromMenu(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = "\(dir)|\(type.rawValue)"
                sub.addItem(it)
            }
            parent.submenu = sub
            splitPopup.menu?.addItem(parent)
        }

        let toolbar = NSStackView(views: [addPopup, splitPopup, NSView()])
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

    /// Surfaces offered by the + and Split menus, in display order.
    static let surfaceChoices: [(String, SurfaceType)] = [
        ("Terminal", .terminal),
        ("Browser", .browser),
        ("Agent App", .agentApp),
        ("Diff Panel", .rightSidebarTool),
        ("Markdown", .markdown),
        ("File Preview", .filePreview)
    ]

    private static func title(for type: SurfaceType) -> String {
        surfaceChoices.first(where: { $0.1 == type })?.0 ?? type.rawValue
    }

    /// A token-styled pull-down NSPopUpButton whose first (index 0) item
    /// is the always-visible label.
    private static func makePullDown(title: String) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: true)
        p.translatesAutoresizingMaskIntoConstraints = false
        p.bezelStyle = .texturedRounded
        p.controlSize = .small
        p.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let head = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        p.menu?.addItem(head)
        return p
    }

    @objc private func addFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let type = SurfaceType(rawValue: raw) else { return }
        performAdd(type, title: Self.title(for: type))
    }

    @objc private func splitFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|")
        guard parts.count == 2,
              let dir = SplitDirection(rawValue: String(parts[0])),
              let type = SurfaceType(rawValue: String(parts[1])) else { return }
        performSplit(dir, type: type, title: Self.title(for: type))
    }

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

