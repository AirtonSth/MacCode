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

        // Split controls live on the RIGHT of the toolbar as two icon
        // buttons: columns (side-by-side, .right) and rows (stacked, .down).
        let splitColumns = Self.makeIconButton(
            symbol: "rectangle.split.2x1",
            help: "Split right (side by side)",
            target: self, action: #selector(splitHorizontal))
        let splitRows = Self.makeIconButton(
            symbol: "rectangle.split.1x2",
            help: "Split down (stacked)",
            target: self, action: #selector(splitVertical))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let toolbar = NSStackView(views: [addPopup, spacer, splitColumns, splitRows])
        toolbar.orientation = .horizontal
        toolbar.spacing = DS.Space.sm
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

    /// A token-styled square icon button used for the split controls.
    private static func makeIconButton(symbol: String, help: String,
                                       target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isBordered = false
        b.bezelStyle = .inline
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        b.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        b.contentTintColor = DS.NS.textSecondary
        b.toolTip = help
        b.target = target
        b.action = action
        b.wantsLayer = true
        b.layer?.cornerRadius = DS.Radius.control
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 26),
            b.heightAnchor.constraint(equalToConstant: 22)
        ])
        return b
    }

    @objc private func addFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let type = SurfaceType(rawValue: raw) else { return }
        performAdd(type, title: Self.title(for: type))
    }

    @objc private func splitHorizontal() {
        performSplit(.right, type: .agentApp, title: Self.title(for: .agentApp))
    }

    @objc private func splitVertical() {
        performSplit(.down, type: .agentApp, title: Self.title(for: .agentApp))
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

