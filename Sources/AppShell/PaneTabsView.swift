import Foundation
import AppKit
import CoreModel
import Surfaces
import DesignSystemKit

@MainActor
public final class PaneTabsView: NSObject {
    public let view: NSView
    public let pane: PaneNode
    public weak var router: AppCommandRouter?
    private let tabStrip = NSStackView()
    private let contentArea = NSView()

    public init(pane: PaneNode, router: AppCommandRouter?) {
        self.pane = pane
        self.router = router
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = DS.NS.bg.cgColor
        self.view = v

        super.init()

        // Custom tab strip: icon + truncating title + close button.
        let selectedID = pane.selectedSurfaceID ?? pane.surfaces.first?.id
        tabStrip.orientation = .horizontal
        tabStrip.spacing = 0
        tabStrip.alignment = .centerY
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        for desc in pane.surfaces {
            let isSel = desc.id == selectedID
            let tab = PaneTabButton(
                title: desc.title,
                symbol: Self.symbol(for: desc.type),
                selected: isSel,
                onSelect: { [weak self] in self?.selectSurface(desc.id) },
                onClose: { [weak self] in self?.closeSurface(desc.id) }
            )
            tabStrip.addArrangedSubview(tab)
        }
        let stripScroll = NSScrollView()
        stripScroll.drawsBackground = false
        stripScroll.borderType = .noBorder
        stripScroll.hasHorizontalScroller = false
        stripScroll.hasVerticalScroller = false
        stripScroll.horizontalScrollElasticity = .allowed
        stripScroll.translatesAutoresizingMaskIntoConstraints = false
        let stripDoc = NSView()
        stripDoc.translatesAutoresizingMaskIntoConstraints = false
        stripDoc.addSubview(tabStrip)
        stripScroll.documentView = stripDoc
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: stripDoc.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: stripDoc.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: stripDoc.topAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: stripDoc.bottomAnchor),
            stripDoc.heightAnchor.constraint(equalTo: stripScroll.heightAnchor)
        ])

        // Content area: the selected surface (or a styled placeholder).
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        contentArea.wantsLayer = true
        contentArea.layer?.backgroundColor = DS.NS.bg.cgColor
        if let selID = selectedID, let surface = SurfaceRegistry.shared.surface(selID) {
            let sv = surface.view
            sv.translatesAutoresizingMaskIntoConstraints = false
            contentArea.addSubview(sv)
            NSLayoutConstraint.activate([
                sv.topAnchor.constraint(equalTo: contentArea.topAnchor),
                sv.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
                sv.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
                sv.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor)
            ])
        } else {
            let label = NSTextField(labelWithString: pane.surfaces.isEmpty
                ? "Empty pane — use + to add a surface"
                : "missing surface")
            label.textColor = DS.NS.textTertiary
            label.font = NSFont.systemFont(ofSize: 12)
            label.translatesAutoresizingMaskIntoConstraints = false
            contentArea.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: contentArea.centerYAnchor)
            ])
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

        let tabStripBG = NSView()
        tabStripBG.wantsLayer = true
        tabStripBG.layer?.backgroundColor = DS.NS.surface.cgColor
        tabStripBG.translatesAutoresizingMaskIntoConstraints = false
        let divider2 = NSView()
        divider2.wantsLayer = true
        divider2.layer?.backgroundColor = DS.NS.line.cgColor
        divider2.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(toolbarBG)
        toolbarBG.addSubview(toolbar)
        v.addSubview(divider)
        v.addSubview(tabStripBG)
        tabStripBG.addSubview(stripScroll)
        v.addSubview(divider2)
        v.addSubview(contentArea)
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

            tabStripBG.topAnchor.constraint(equalTo: divider.bottomAnchor),
            tabStripBG.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            tabStripBG.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            tabStripBG.heightAnchor.constraint(equalToConstant: 34),
            stripScroll.topAnchor.constraint(equalTo: tabStripBG.topAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: tabStripBG.bottomAnchor),
            stripScroll.leadingAnchor.constraint(equalTo: tabStripBG.leadingAnchor),
            stripScroll.trailingAnchor.constraint(equalTo: tabStripBG.trailingAnchor),

            divider2.topAnchor.constraint(equalTo: tabStripBG.bottomAnchor),
            divider2.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            divider2.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            divider2.heightAnchor.constraint(equalToConstant: 1),

            contentArea.topAnchor.constraint(equalTo: divider2.bottomAnchor),
            contentArea.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: v.trailingAnchor)
        ])
    }

    private func selectSurface(_ id: SurfaceID) {
        guard let wid = currentWorkspaceID() else { return }
        try? router?.focusSurface(workspace: wid, surface: id)
    }

    private func closeSurface(_ id: SurfaceID) {
        guard let wid = currentWorkspaceID() else { return }
        try? router?.closeSurface(workspace: wid, surface: id)
    }

    static func symbol(for type: SurfaceType) -> String {
        switch type {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .agentApp: return "sparkles"
        case .markdown: return "doc.richtext"
        case .filePreview: return "doc"
        case .rightSidebarTool: return "sidebar.right"
        }
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

}

// MARK: - Custom tab button (icon · truncating title · close ×)

@MainActor
final class PaneTabButton: NSView {
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private var hovering = false
    private let selected: Bool

    init(title: String, symbol: String, selected: Bool,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = (selected ? DS.NS.bg : DS.NS.surface).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = selected ? DS.NS.text : DS.NS.textTertiary
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        label.textColor = selected ? DS.NS.text : DS.NS.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let close = NSButton(frame: .zero)
        close.isBordered = false
        close.bezelStyle = .inline
        close.imagePosition = .imageOnly
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        close.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        close.contentTintColor = DS.NS.textTertiary
        close.translatesAutoresizingMaskIntoConstraints = false
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = "Close tab"

        addSubview(icon); addSubview(label); addSubview(close)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16)
        ])

        // Right-edge separator between tabs.
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = DS.NS.line.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)
        NSLayoutConstraint.activate([
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.topAnchor.constraint(equalTo: topAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.widthAnchor.constraint(equalToConstant: 1)
        ])

        if selected {
            let underline = NSView()
            underline.wantsLayer = true
            underline.layer?.backgroundColor = DS.NS.accent.cgColor
            underline.translatesAutoresizingMaskIntoConstraints = false
            addSubview(underline)
            NSLayoutConstraint.activate([
                underline.leadingAnchor.constraint(equalTo: leadingAnchor),
                underline.trailingAnchor.constraint(equalTo: trailingAnchor),
                underline.bottomAnchor.constraint(equalTo: bottomAnchor),
                underline.heightAnchor.constraint(equalToConstant: 2)
            ])
        }

        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        // Selection only fires if the close button didn't consume the click.
        onSelect()
    }

    @objc private func closeClicked() { onClose() }

    override func mouseEntered(with event: NSEvent) {
        if !selected { layer?.backgroundColor = DS.NS.surfaceRaised.cgColor }
    }
    override func mouseExited(with event: NSEvent) {
        if !selected { layer?.backgroundColor = DS.NS.surface.cgColor }
    }
}

