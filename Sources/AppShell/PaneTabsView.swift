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
    // Leading edge of the header: an always-visible sidebar toggle, plus
    // an accent workspace pill (folder icon + name) shown only while the
    // sidebar is collapsed, so the active workspace stays obvious.
    private let leadingBox = NSStackView()
    private let wsPill = NSStackView()
    private let wsLabel = NSTextField(labelWithString: "")

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

        // Chrome-style flat "+" that sits right after the last tab.
        // Clicking it pops the surface-type menu under the button.
        let addButton = Self.makeIconButton(
            symbol: "plus",
            help: "New surface",
            target: self, action: #selector(showAddMenu(_:)))
        let addMenu = NSMenu()
        let addChoices: [(String, SurfaceType)] = [
            ("Terminal", .terminal),
            ("Browser", .browser),
            ("Agent App", .agentApp)
        ]
        for (label, type) in addChoices {
            let it = NSMenuItem(title: label, action: #selector(addFromMenu(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = type.rawValue
            let img = NSImage(systemSymbolName: Self.symbol(for: type), accessibilityDescription: label)
            img?.isTemplate = true
            it.image = img?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            addMenu.addItem(it)
        }
        addButton.menu = addMenu
        tabStrip.addArrangedSubview(addButton)

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

        // Git lives at the workspace level: this button opens a Git tab
        // (changed files + diff) in the current pane.
        let gitButton = Self.makeIconButton(
            symbol: "arrow.triangle.branch",
            help: "Open Git (changed files & diff)",
            target: self, action: #selector(openGit))

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 16).isActive = true

        // Subtle separator splitting the unified header into two zones:
        // the scrollable tab strip (left) and the action cluster (right).
        let zoneSep = NSBox()
        zoneSep.boxType = .separator
        zoneSep.translatesAutoresizingMaskIntoConstraints = false
        zoneSep.heightAnchor.constraint(equalToConstant: 16).isActive = true

        // Single unified header row: tabs scroll on the left, the action
        // cluster (+ · git · split) stays pinned on the right.
        let rightCluster = NSStackView(views: [zoneSep, gitButton, sep, splitColumns, splitRows])
        rightCluster.orientation = .horizontal
        rightCluster.spacing = DS.Space.sm
        rightCluster.translatesAutoresizingMaskIntoConstraints = false
        rightCluster.setContentHuggingPriority(.required, for: .horizontal)

        // Leading block (collapsed-sidebar only): restore button + the
        // active workspace name, so the user still knows where they are.
        let sidebarToggle = Self.makeIconButton(
            symbol: "sidebar.left", help: "Toggle sidebar",
            target: self, action: #selector(toggleSidebar))
        let folderIcon = NSImageView()
        folderIcon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        folderIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        folderIcon.contentTintColor = DS.NS.accent
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.setContentHuggingPriority(.required, for: .horizontal)

        wsLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        wsLabel.textColor = DS.NS.text
        wsLabel.lineBreakMode = .byTruncatingTail
        wsLabel.translatesAutoresizingMaskIntoConstraints = false
        wsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Accent capsule = "you are in this workspace". Mirrors the
        // folder rows in the sidebar so the link is obvious.
        wsPill.orientation = .horizontal
        wsPill.spacing = DS.Space.xs
        wsPill.alignment = .centerY
        wsPill.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.md, bottom: 0, right: DS.Space.md)
        wsPill.translatesAutoresizingMaskIntoConstraints = false
        wsPill.wantsLayer = true
        wsPill.layer?.cornerRadius = 11
        wsPill.layer?.borderWidth = 1
        wsPill.layer?.backgroundColor = DS.NS.accent.withAlphaComponent(0.18).cgColor
        wsPill.layer?.borderColor = DS.NS.accent.withAlphaComponent(0.55).cgColor
        wsPill.addArrangedSubview(folderIcon)
        wsPill.addArrangedSubview(wsLabel)
        wsPill.isHidden = true

        leadingBox.orientation = .horizontal
        leadingBox.spacing = DS.Space.sm
        leadingBox.alignment = .centerY
        // Default (sidebar visible): small inset, pane sits right of the
        // sidebar. When collapsed the inset grows to clear the traffic
        // lights (this header then sits at the window's left edge).
        leadingBox.edgeInsets = NSEdgeInsets(top: 0, left: DS.Space.sm, bottom: 0, right: DS.Space.sm)
        leadingBox.translatesAutoresizingMaskIntoConstraints = false
        leadingBox.addArrangedSubview(sidebarToggle)
        leadingBox.addArrangedSubview(wsPill)

        let headerBG = NSView()
        headerBG.wantsLayer = true
        headerBG.layer?.backgroundColor = DS.NS.surface.cgColor
        headerBG.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DS.NS.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(headerBG)
        headerBG.addSubview(leadingBox)
        headerBG.addSubview(stripScroll)
        headerBG.addSubview(rightCluster)
        v.addSubview(divider)
        v.addSubview(contentArea)
        NSLayoutConstraint.activate([
            headerBG.topAnchor.constraint(equalTo: v.topAnchor),
            headerBG.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            headerBG.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            headerBG.heightAnchor.constraint(equalToConstant: 34),

            leadingBox.leadingAnchor.constraint(equalTo: headerBG.leadingAnchor),
            leadingBox.topAnchor.constraint(equalTo: headerBG.topAnchor),
            leadingBox.bottomAnchor.constraint(equalTo: headerBG.bottomAnchor),
            wsLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            wsPill.heightAnchor.constraint(equalToConstant: 22),

            stripScroll.leadingAnchor.constraint(equalTo: leadingBox.trailingAnchor),
            stripScroll.topAnchor.constraint(equalTo: headerBG.topAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: headerBG.bottomAnchor),
            stripScroll.trailingAnchor.constraint(equalTo: rightCluster.leadingAnchor, constant: -DS.Space.sm),

            rightCluster.trailingAnchor.constraint(equalTo: headerBG.trailingAnchor, constant: -DS.Space.md),
            rightCluster.centerYAnchor.constraint(equalTo: headerBG.centerYAnchor),

            divider.topAnchor.constraint(equalTo: headerBG.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            contentArea.topAnchor.constraint(equalTo: divider.bottomAnchor),
            contentArea.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: v.trailingAnchor)
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(sidebarVisibilityChanged(_:)),
            name: .rc2SidebarVisibility, object: nil)
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

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func toggleSidebar() {
        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
    }

    @objc private func sidebarVisibilityChanged(_ note: Notification) {
        let collapsed = (note.userInfo?["collapsed"] as? Bool) ?? false
        wsPill.isHidden = !collapsed
        if collapsed { wsLabel.stringValue = currentWorkspaceName() }
        // Clear the traffic lights only when this header is at the
        // window's left edge (sidebar gone).
        leadingBox.edgeInsets = NSEdgeInsets(
            top: 0, left: collapsed ? 84 : DS.Space.sm,
            bottom: 0, right: DS.Space.sm)
    }

    private func currentWorkspaceName() -> String {
        guard let ctx = router?.context,
              let wid = ctx.state.window.selectedWorkspaceID,
              let ws = ctx.state.workspaces[wid] else { return "" }
        return ws.name
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        guard let menu = sender.menu else { return }
        let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    @objc private func addFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let type = SurfaceType(rawValue: raw) else { return }
        performAdd(type, title: Self.title(for: type))
    }

    @objc private func splitHorizontal() {
        performSplit(.right, type: .terminal, title: Self.title(for: .terminal))
    }

    @objc private func splitVertical() {
        performSplit(.down, type: .terminal, title: Self.title(for: .terminal))
    }

    @objc private func openGit() {
        // The Git surface is the workspace changed-files + diff view.
        performAdd(.rightSidebarTool, title: "Git")
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

