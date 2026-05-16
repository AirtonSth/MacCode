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
    private let tabStrip = NoDragStack()
    private let contentArea = NSView()
    private let addMenu = NSMenu()

    public init(pane: PaneNode, router: AppCommandRouter?, showsWorkspaceControls: Bool = true) {
        self.pane = pane
        self.router = router
        let v = PaneRootView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = DS.NS.bg.cgColor
        v.layer?.masksToBounds = true
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
            let busy = SurfaceRegistry.shared.surface(desc.id)?.isBusy ?? false
            let colorHex = TabColor.from(desc.metadata["color"])?.hex
            let sid = desc.id
            let tab = PaneTabButton(
                title: desc.title,
                symbol: Self.symbol(for: desc.type),
                selected: isSel,
                busy: busy,
                colorHex: colorHex,
                onSelect: { [weak self] in self?.selectSurface(sid) },
                onClose: { [weak self] in self?.closeSurface(sid) },
                onRename: { [weak self] in self?.promptRenameSurface(sid, current: desc.title) },
                onSetColor: { [weak self] raw in
                    guard let wid = self?.currentWorkspaceID() else { return }
                    try? self?.router?.setSurfaceColor(wid, sid, raw)
                }
            )
            tabStrip.addArrangedSubview(tab)
        }
        // Content area: the selected surface (or a styled placeholder).
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        contentArea.wantsLayer = true
        contentArea.layer?.backgroundColor = DS.NS.bg.cgColor
        contentArea.layer?.masksToBounds = true
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
        let addChoices: [(String, SurfaceType)] = [
            ("Terminal", .terminal),
            ("Browser", .browser),
            ("Agent App", .agentApp),
            ("Git", .rightSidebarTool)
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

        let rightCluster = NoDragStack(views: [splitColumns, splitRows])
        rightCluster.orientation = .horizontal
        rightCluster.spacing = DS.Space.sm
        rightCluster.translatesAutoresizingMaskIntoConstraints = false
        rightCluster.setContentHuggingPriority(.required, for: .horizontal)

        let headerBG = NSView()
        headerBG.wantsLayer = true
        headerBG.layer?.backgroundColor = DS.NS.surface.cgColor
        headerBG.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DS.NS.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(headerBG)
        headerBG.addSubview(tabStrip)
        headerBG.addSubview(rightCluster)
        v.addSubview(divider)
        v.addSubview(contentArea)
        NSLayoutConstraint.activate([
            headerBG.topAnchor.constraint(equalTo: v.topAnchor),
            headerBG.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            headerBG.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            headerBG.heightAnchor.constraint(equalToConstant: 34),

            tabStrip.leadingAnchor.constraint(equalTo: headerBG.leadingAnchor),
            tabStrip.topAnchor.constraint(equalTo: headerBG.topAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: headerBG.bottomAnchor),
            tabStrip.trailingAnchor.constraint(lessThanOrEqualTo: rightCluster.leadingAnchor, constant: -DS.Space.sm),

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
    }

    private func selectSurface(_ id: SurfaceID) {
        guard let wid = currentWorkspaceID() else { return }
        try? router?.focusSurface(workspace: wid, surface: id)
    }

    private func promptRenameSurface(_ id: SurfaceID, current: String) {
        guard let wid = currentWorkspaceID() else { return }
        let alert = NSAlert()
        alert.messageText = "Rename tab"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = current
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { try? router?.renameSurface(wid, id, v) }
        }
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
        ("Git", .rightSidebarTool),
        ("Markdown", .markdown),
        ("File Preview", .filePreview)
    ]

    private static func title(for type: SurfaceType) -> String {
        surfaceChoices.first(where: { $0.1 == type })?.0 ?? type.rawValue
    }

    /// A token-styled square icon button used for the split controls.
    private static func makeIconButton(symbol: String, help: String,
                                       target: AnyObject, action: Selector) -> NSButton {
        let b = NoDragButton(frame: .zero)
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

    @objc private func showAddMenu(_ sender: NSButton) {
        // Defer: popping the menu inside the mouse-up that triggered the
        // action makes the same event dismiss it immediately.
        DispatchQueue.main.async { [weak self, weak sender] in
            guard let self, let sender else { return }
            let origin = NSPoint(x: 0, y: sender.bounds.maxY + 4)
            self.addMenu.popUp(positioning: nil, at: origin, in: sender)
        }
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
    private let onRename: (() -> Void)?
    private let onSetColor: ((String) -> Void)?
    private var hovering = false
    private let selected: Bool

    init(title: String, symbol: String, selected: Bool, busy: Bool = false,
         colorHex: UInt32? = nil,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void,
         onRename: (() -> Void)? = nil, onSetColor: ((String) -> Void)? = nil) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.onRename = onRename
        self.onSetColor = onSetColor
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = (selected ? DS.NS.bg : DS.NS.surface).cgColor

        // A3: a busy surface shows a spinner where its icon would be.
        let icon: NSView
        if busy {
            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .small
            spin.isIndeterminate = true
            spin.startAnimation(nil)
            icon = spin
        } else {
            let iv = NSImageView()
            iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            iv.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            iv.contentTintColor = selected ? DS.NS.text : DS.NS.textTertiary
            icon = iv
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        label.textColor = selected ? DS.NS.text : DS.NS.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let close = NoDragButton(frame: .zero)
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

        if let hex = colorHex {
            let rail = NSView()
            rail.wantsLayer = true
            rail.layer?.backgroundColor = NSColor(hex: hex).cgColor
            rail.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rail)
            NSLayoutConstraint.activate([
                rail.leadingAnchor.constraint(equalTo: leadingAnchor),
                rail.topAnchor.constraint(equalTo: topAnchor),
                rail.bottomAnchor.constraint(equalTo: bottomAnchor),
                rail.widthAnchor.constraint(equalToConstant: 3)
            ])
        }

        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard onRename != nil || onSetColor != nil else { return }
        let menu = NSMenu()
        if onRename != nil {
            let r = NSMenuItem(title: "Rename…", action: #selector(renameTab), keyEquivalent: "")
            r.target = self
            menu.addItem(r)
        }
        if onSetColor != nil {
            let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let none = NSMenuItem(title: "None", action: #selector(colorTab(_:)), keyEquivalent: "")
            none.target = self; none.representedObject = ""
            sub.addItem(none)
            for c in TabColor.allCases {
                let mi = NSMenuItem(title: c.label, action: #selector(colorTab(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = c.rawValue
                sub.addItem(mi)
            }
            colorItem.submenu = sub
            menu.addItem(colorItem)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func renameTab() { onRename?() }
    @objc private func colorTab(_ sender: NSMenuItem) {
        onSetColor?((sender.representedObject as? String) ?? "")
    }

    required init?(coder: NSCoder) { fatalError() }

    // In the full-size-content titlebar band, AppKit would otherwise
    // treat clicks here as a window drag and the tab/close never fire.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Selection only fires if the close button didn't consume the click.
        onSelect()
    }

    func performSelectFromTitlebarClick() { onSelect() }

    @objc private func closeClicked() { onClose() }

    override func mouseEntered(with event: NSEvent) {
        if !selected { layer?.backgroundColor = DS.NS.surfaceRaised.cgColor }
    }
    override func mouseExited(with event: NSEvent) {
        if !selected { layer?.backgroundColor = DS.NS.surface.cgColor }
    }
}

// MARK: - Non-draggable header containers
//
// With `.fullSizeContentView` the tab bar lives inside the titlebar
// band. Container views default `mouseDownCanMoveWindow` to true, so
// AppKit starts a window drag on mouse-down and the buttons/tabs never
// receive the click. These subclasses opt the interactive subtree out
// of window dragging. (headerBG stays a plain NSView so its empty area
// can still drag the window.)

class NoDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class PaneRootView: NoDragView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsUpdateConstraints = true
        needsLayout = true
        updateConstraintsForSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
    }
}

final class NoDragStack: NSStackView {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class NoDragScroll: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class NoDragButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
}
