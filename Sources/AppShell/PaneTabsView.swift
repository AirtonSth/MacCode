import Foundation
import AppKit
import CoreModel
import SocketServer
import Surfaces
import DesignSystemKit

@MainActor
public struct PaneSplitContext {
    public let splitID: UUID
    public let paneIndex: Int
    public let ratios: [Double]
    public let orientation: SplitOrientation

    public init(splitID: UUID, paneIndex: Int, ratios: [Double], orientation: SplitOrientation = .horizontal) {
        self.splitID = splitID
        self.paneIndex = paneIndex
        self.ratios = ratios
        self.orientation = orientation
    }
}

@MainActor
public final class PaneTabsView: NSObject {
    public let view: NSView
    public let pane: PaneNode
    public weak var router: AppCommandRouter?
    private let splitContext: PaneSplitContext?
    private let workspaceIDOverride: WorkspaceID?
    private let tabStrip = PaneTabDropStack()
    private let tabScrollView = HorizontalTabScrollView()
    private let contentArea = NSView()
    private let addMenu = NSMenu()
    private let splitRightMenu = NSMenu()
    private let splitDownMenu = NSMenu()
    private var tabButtons: [SurfaceID: PaneTabButton] = [:]
    // PERF: ordered SurfaceIDs currently rendered in the strip. The diff
    // seam (`PaneTabsView.diffTabs`) compares this against the fresh pane
    // order to patch the strip in place instead of rebuilding it.
    private var currentSurfaceIDs: [SurfaceID] = []
    private var eventToken: UUID?

    public init(pane: PaneNode, router: AppCommandRouter?, showsWorkspaceControls: Bool = true, splitContext: PaneSplitContext? = nil, workspaceID: WorkspaceID? = nil) {
        self.pane = pane
        self.router = router
        self.splitContext = splitContext
        self.workspaceIDOverride = workspaceID
        let v = PaneRootView()
        v.paneID = pane.id
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = DS.NS.bg.cgColor
        v.layer?.masksToBounds = true
        self.view = v

        super.init()

        // Custom tab strip: icon + truncating title + close button.
        let selectedID = pane.selectedSurfaceID ?? pane.surfaces.first?.id
        let paneMinimized = splitContext.map {
            Self.isPaneMinimized(paneIndex: $0.paneIndex, ratios: $0.ratios)
        } ?? false
        if paneMinimized, splitContext?.orientation == .horizontal {
            buildMinimizedSideRail(in: v, selectedSurfaceID: selectedID)
            return
        }

        tabStrip.orientation = .horizontal
        tabStrip.spacing = 0
        tabStrip.alignment = .centerY
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.onDropSurface = { [weak self] sid in self?.appendDroppedSurface(sid) ?? false }
        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.documentView = tabStrip
        for desc in pane.surfaces {
            let tab = makeTabButton(for: desc, in: pane, selectedID: selectedID)
            tabButtons[desc.id] = tab
            currentSurfaceIDs.append(desc.id)
            tabStrip.addArrangedSubview(tab)
        }

        // Content area: the selected surface (or a styled placeholder).
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        contentArea.wantsLayer = true
        contentArea.layer?.backgroundColor = DS.NS.bg.cgColor
        contentArea.layer?.masksToBounds = true
        contentArea.isHidden = paneMinimized
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
        addButton.setAccessibilityIdentifier("pane.add")
        Self.populateSurfaceMenu(addMenu, target: self, action: #selector(addFromMenu(_:)))
        Self.populateSurfaceMenu(splitRightMenu, target: self, action: #selector(splitFromMenu(_:)), direction: .right)
        Self.populateSurfaceMenu(splitDownMenu, target: self, action: #selector(splitFromMenu(_:)), direction: .down)
        tabStrip.addArrangedSubview(addButton)

        // Split controls live on the RIGHT of the toolbar as two icon
        // buttons: columns (side-by-side, .right) and rows (stacked, .down).
        let splitColumns = Self.makeIconButton(
            symbol: "rectangle.split.2x1",
            help: "Split right (side by side)",
            target: self, action: #selector(showSplitRightMenu(_:)))
        splitColumns.setAccessibilityIdentifier("pane.splitRight")
        let splitRows = Self.makeIconButton(
            symbol: "rectangle.split.1x2",
            help: "Split down (stacked)",
            target: self, action: #selector(showSplitDownMenu(_:)))
        splitRows.setAccessibilityIdentifier("pane.splitDown")

        var rightControls: [NSView] = [splitColumns, splitRows]
        if let splitContext {
            let minimized = Self.isPaneMinimized(paneIndex: splitContext.paneIndex, ratios: splitContext.ratios)
            let paneZoom = Self.makeIconButton(
                symbol: minimized ? "arrow.up.left.and.arrow.down.right" : "minus",
                help: minimized ? "Maximize pane" : "Minimize pane",
                target: self, action: #selector(togglePaneMinimized))
            rightControls.insert(paneZoom, at: 0)
        }

        let rightCluster = NoDragStack(views: rightControls)
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
        headerBG.addSubview(tabScrollView)
        headerBG.addSubview(rightCluster)
        v.addSubview(divider)
        v.addSubview(contentArea)
        NSLayoutConstraint.activate([
            headerBG.topAnchor.constraint(equalTo: v.topAnchor),
            headerBG.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            headerBG.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            headerBG.heightAnchor.constraint(equalToConstant: 34),

            tabScrollView.leadingAnchor.constraint(equalTo: headerBG.leadingAnchor),
            tabScrollView.topAnchor.constraint(equalTo: headerBG.topAnchor),
            tabScrollView.bottomAnchor.constraint(equalTo: headerBG.bottomAnchor),
            tabScrollView.trailingAnchor.constraint(equalTo: rightCluster.leadingAnchor, constant: -DS.Space.sm),

            tabStrip.leadingAnchor.constraint(equalTo: tabScrollView.contentView.leadingAnchor),
            tabStrip.topAnchor.constraint(equalTo: tabScrollView.contentView.topAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: tabScrollView.contentView.bottomAnchor),
            tabStrip.heightAnchor.constraint(equalTo: tabScrollView.heightAnchor),

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

        // Focus-follows-click: a mouseDown anywhere inside the pane root
        // (content area or tab header) records this pane as focused so
        // Cmd+W / Cmd+D act on the right pane. The closure is pure-ID
        // routing: no surface selection, no UI side effects.
        let paneID = pane.id
        v.onContentAreaMouseDown = { [weak self] in
            guard let self,
                  let wid = currentWorkspaceID(),
                  let ws = router?.context?.state.workspaces[wid],
                  let target = Self.focusPaneCommand(
                      currentFocusedPaneID: ws.focusedPaneID,
                      paneID: paneID,
                      workspaceID: wid) else { return }
            try? router?.focusPane(workspace: target.workspace, pane: target.pane)
        }

        // PERF-MAC_SHELL_WINDOW-001: the tab strip only reacts to
        // `files.state.updated`. Drop every other kind on the publishing
        // thread instead of bouncing the full EventBus firehose to main
        // just to discard it in `receive`.
        eventToken = EventBus.shared.subscribe(since: nil) { [weak self] event in
            guard event.kind == "files.state.updated" else { return }
            DispatchQueue.main.async { self?.receive(event) }
        }
        DispatchQueue.main.async { [weak self] in self?.scrollSelectedTabIntoView(selectedID) }
    }

    private func scrollSelectedTabIntoView(_ selectedID: SurfaceID?) {
        guard let selectedID, let tab = tabButtons[selectedID] else { return }
        tabScrollView.scrollDocumentViewToVisible(tab)
    }

    /// Test seam: the live button bound to `id` (nil if none), so the
    /// reconcile's in-place patching can be asserted without a window.
    func tabButtonForTesting(_ id: SurfaceID) -> PaneTabButton? { tabButtons[id] }

    /// Test seam: the SurfaceIDs currently rendered, in display order.
    var currentSurfaceIDsForTesting: [SurfaceID] { currentSurfaceIDs }

    /// Builds one tab button bound to `desc` within `pane`. Shared by the
    /// initial strip build and the reconcile's insert path so a freshly
    /// inserted button is wired identically to an initially-built one.
    private func makeTabButton(for desc: SurfaceDescriptor, in pane: PaneNode, selectedID: SurfaceID?) -> PaneTabButton {
        let sid = desc.id
        return PaneTabButton(
            surfaceID: sid,
            title: desc.title,
            symbol: Self.symbol(for: desc.type),
            selected: desc.id == selectedID,
            busy: Self.isSurfaceBusy(desc, router: router),
            dirty: surfaceIsUnsaved(sid),
            colorHex: TabColor.from(desc.metadata["color"])?.hex,
            onSelect: { [weak self] in self?.selectSurface(sid) },
            onClose: { [weak self] in self?.closeSurface(sid) },
            onCloseOthers: pane.surfaces.count > 1 ? { [weak self] in _ = self?.performCloseAllOthers(around: sid) } : nil,
            onCloseToLeft: Self.surfaceIDs(in: pane, before: sid).isEmpty ? nil : { [weak self] in _ = self?.performCloseToLeft(of: sid) },
            onCloseToRight: Self.surfaceIDs(in: pane, after: sid).isEmpty ? nil : { [weak self] in _ = self?.performCloseToRight(of: sid) },
            onRename: { [weak self] in self?.promptRenameSurface(sid, current: desc.title) },
            onSetColor: { [weak self] raw in
                guard let wid = self?.currentWorkspaceID() else { return }
                try? self?.router?.setSurfaceColor(wid, sid, raw)
            },
            onDropSurface: { [weak self] draggedID in
                self?.dropSurface(draggedID, before: sid) ?? false
            },
            onSplitSurface: { [weak self] draggedID, targetPane, direction in
                self?.performSplitSurface(draggedID, targetPane: targetPane, direction: direction) ?? false
            }
        )
    }

    /// PERF (P1): in-place tab-strip reconcile keyed by SurfaceID. Drives
    /// the pure `diffTabs` seam: when the SurfaceID set and order are
    /// unchanged, every surviving button is patched in place
    /// (selection / title / color / dirty) with NO structural mutation of
    /// the strip -- eliminating the full-rebuild flash. Structural deltas
    /// (insert / remove / reorder) rebuild only this pane's buttons; pane
    /// identity for the unchanged-shape case is preserved.
    ///
    /// Returns true when the strip was patched in place (no structural
    /// change), so the caller can skip a container teardown entirely.
    @discardableResult
    public func reconcile(to pane: PaneNode) -> Bool {
        let newIDs = pane.surfaces.map(\.id)
        let diff = Self.diffTabs(old: currentSurfaceIDs, new: newIDs)
        let selectedID = pane.selectedSurfaceID ?? pane.surfaces.first?.id
        let structural = !diff.inserts.isEmpty || !diff.removes.isEmpty || diff.reordered

        if structural {
            // Set or order changed: rebuild this pane's buttons. Cheaper
            // than the old whole-workspace teardown and still keyed off the
            // diff decision.
            for view in tabStrip.arrangedSubviews where view is PaneTabButton {
                tabStrip.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            tabButtons.removeAll(keepingCapacity: true)
            currentSurfaceIDs.removeAll(keepingCapacity: true)
            var insertIndex = 0
            for desc in pane.surfaces {
                let tab = makeTabButton(for: desc, in: pane, selectedID: selectedID)
                tabButtons[desc.id] = tab
                currentSurfaceIDs.append(desc.id)
                tabStrip.insertArrangedSubview(tab, at: insertIndex)
                insertIndex += 1
            }
            DispatchQueue.main.async { [weak self] in self?.scrollSelectedTabIntoView(selectedID) }
            return false
        }

        // Unchanged shape: patch each surviving button in place.
        for desc in pane.surfaces {
            guard let tab = tabButtons[desc.id] else { continue }
            tab.setSelected(desc.id == selectedID)
            tab.setTitle(desc.title)
            tab.setColorHex(TabColor.from(desc.metadata["color"])?.hex)
            tab.setDirty(surfaceIsUnsaved(desc.id))
            tab.setBusy(Self.isSurfaceBusy(desc, router: router))
        }
        return true
    }

    private func buildMinimizedSideRail(in root: NSView, selectedSurfaceID: SurfaceID?) {
        let restore = Self.makeIconButton(
            symbol: "arrow.up.left.and.arrow.down.right",
            help: "Maximize pane",
            target: self, action: #selector(togglePaneMinimized))

        let selected = selectedSurfaceID.flatMap { id in
            pane.surfaces.first(where: { $0.id == id })
        } ?? pane.surfaces.first
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: selected.map { Self.symbol(for: $0.type) } ?? "rectangle.dashed",
                             accessibilityDescription: selected?.title ?? "Minimized pane")
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = DS.NS.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.toolTip = selected?.title ?? "Minimized pane"

        let stack = NoDragStack(views: [restore, icon])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = DS.Space.md
        stack.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DS.NS.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        root.addSubview(divider)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: DS.Space.sm),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1)
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
        if surfaceIsUnsaved(id), !confirmCloseUnsavedSurface(id) { return }
        try? router?.closeSurface(workspace: wid, surface: id)
    }

    /// UX-MAC_SHELL_WINDOW-003: ⌘W close-tab seam. Closes this pane's
    /// selected surface through the same unsaved-changes confirm the tab
    /// "×" uses. Returns false when the pane has no surface to close so
    /// the caller can fall back to closing the window.
    @discardableResult
    public func closeSelectedSurface() -> Bool {
        guard let id = pane.selectedSurfaceID ?? pane.surfaces.first?.id else { return false }
        closeSurface(id)
        return true
    }

    @discardableResult
    public func performCloseAllOthers(around id: SurfaceID) -> Bool {
        closeSurfaces(Self.surfaceIDs(excluding: id, in: pane))
    }

    @discardableResult
    public func performCloseToLeft(of id: SurfaceID) -> Bool {
        closeSurfaces(Self.surfaceIDs(in: pane, before: id))
    }

    @discardableResult
    public func performCloseToRight(of id: SurfaceID) -> Bool {
        closeSurfaces(Self.surfaceIDs(in: pane, after: id))
    }

    private func closeSurfaces(_ ids: [SurfaceID]) -> Bool {
        guard let wid = currentWorkspaceID(), let router, !ids.isEmpty else { return false }
        for id in ids where surfaceIsUnsaved(id) {
            if !confirmCloseUnsavedSurface(id) { return false }
        }
        for id in ids {
            do {
                try router.closeSurface(workspace: wid, surface: id)
            } catch {
                return false
            }
        }
        return true
    }

    private static func surfaceIDs(excluding id: SurfaceID, in pane: PaneNode) -> [SurfaceID] {
        pane.surfaces.map(\.id).filter { $0 != id }
    }

    private static func surfaceIDs(in pane: PaneNode, before id: SurfaceID) -> [SurfaceID] {
        guard let index = pane.surfaces.firstIndex(where: { $0.id == id }), index > 0 else { return [] }
        return pane.surfaces[..<index].map(\.id)
    }

    private static func surfaceIDs(in pane: PaneNode, after id: SurfaceID) -> [SurfaceID] {
        guard let index = pane.surfaces.firstIndex(where: { $0.id == id }),
              index < pane.surfaces.index(before: pane.surfaces.endIndex) else { return [] }
        return pane.surfaces[pane.surfaces.index(after: index)...].map(\.id)
    }

    private func surfaceIsUnsaved(_ id: SurfaceID) -> Bool {
        if let desc = pane.surfaces.first(where: { $0.id == id }) {
            if desc.isDirty { return true }
            // PERF-MAC_SHELL_WINDOW-006: trust the dirty_count streamed via
            // `files.state.updated` when present (even "0") instead of a
            // synchronous per-tab RPC. Only when the descriptor carries no
            // dirty_count at all (state unknown) do we fall back to the RPC.
            if let raw = desc.metadata["dirty_count"] {
                return (Int(raw) ?? 0) > 0
            }
            guard desc.type == .files else { return false }
        }
        guard let state = try? router?.filesStateGet(surface: id).objectValue,
              case .array(let values) = state["dirty_paths"] ?? .array([]) else { return false }
        return values.contains { $0.stringValue != nil }
    }

    private func confirmCloseUnsavedSurface(_ id: SurfaceID) -> Bool {
        let title = pane.surfaces.first(where: { $0.id == id })?.title ?? "this tab"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(title)” with unsaved changes?"
        alert.informativeText = "Unsaved file edits in this tab will be discarded if you close it."
        alert.addButton(withTitle: "Close Without Saving")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func receive(_ event: EventBus.Event) {
        guard event.kind == "files.state.updated",
              let payload = event.payload.objectValue,
              let raw = payload["surface_id"]?.stringValue,
              let uuid = UUID(uuidString: raw) else { return }
        let surfaceID = SurfaceID(uuid)
        guard let tab = tabButtons[surfaceID],
              let state = payload["state"]?.objectValue,
              case .array(let values) = state["dirty_paths"] ?? .array([]) else { return }
        tab.setDirty(values.contains { $0.stringValue != nil })
    }

    func refreshBusyStates() {
        for desc in pane.surfaces {
            tabButtons[desc.id]?.setBusy(Self.isSurfaceBusy(desc, router: router))
        }
    }

    static func symbol(for type: SurfaceType) -> String {
        switch type {
        case .terminal: return "terminal"
        case .ssh: return "network"
        case .browser: return "globe"
        case .agentApp: return "sparkles"
        case .files: return "folder"
        case .markdown: return "doc.richtext"
        case .filePreview: return "doc"
        case .rightSidebarTool: return "sidebar.right"
        }
    }

    static func isSurfaceBusy(_ desc: SurfaceDescriptor, router: AppCommandRouter?) -> Bool {
        if SurfaceRegistry.shared.surface(desc.id)?.isBusy == true { return true }
        guard desc.type == .agentApp,
              let workspaceID = workspaceID(for: desc, router: router),
              let context = router?.context else { return false }
        return ((try? context.threadRepo.list(workspaceId: workspaceID)) ?? []).contains { $0.status == .running }
    }

    private static func workspaceID(for desc: SurfaceDescriptor, router: AppCommandRouter?) -> WorkspaceID? {
        if let raw = desc.metadata["workspace"], let uuid = UUID(uuidString: raw) {
            return WorkspaceID(uuid)
        }
        return router?.context?.state.window.selectedWorkspaceID
    }

    private func currentWorkspaceID() -> WorkspaceID? {
        workspaceIDOverride ?? router?.context?.state.window.selectedWorkspaceID
    }

    /// Surfaces offered by the + and Split menus, in display order.
    static let surfaceChoices: [(String, SurfaceType)] = [
        ("Terminal", .terminal),
        ("SSH", .ssh),
        ("Browser", .browser),
        ("Agent App", .agentApp),
        ("Files", .files),
        ("Git", .rightSidebarTool)
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

    private static func populateSurfaceMenu(_ menu: NSMenu, target: AnyObject, action: Selector, direction: SplitDirection? = nil) {
        menu.removeAllItems()
        for (label, type) in surfaceChoices {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = direction.map { "\($0.rawValue)|\(type.rawValue)" } ?? type.rawValue
            let image = NSImage(systemSymbolName: symbol(for: type), accessibilityDescription: label)
            image?.isTemplate = true
            item.image = image?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            menu.addItem(item)
        }
    }

    deinit {
        if let eventToken { EventBus.shared.unsubscribe(eventToken) }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        showMenu(addMenu, from: sender)
    }

    @objc private func showSplitRightMenu(_ sender: NSButton) {
        showMenu(splitRightMenu, from: sender)
    }

    @objc private func showSplitDownMenu(_ sender: NSButton) {
        showMenu(splitDownMenu, from: sender)
    }

    private func showMenu(_ menu: NSMenu, from sender: NSButton) {
        // Defer: popping the menu inside the mouse-up that triggered the
        // action makes the same event dismiss it immediately.
        DispatchQueue.main.async { [weak sender] in
            guard let sender else { return }
            let origin = NSPoint(x: 0, y: sender.bounds.maxY + 4)
            menu.popUp(positioning: nil, at: origin, in: sender)
        }
    }

    @objc private func addFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let type = SurfaceType(rawValue: raw) else { return }
        performAdd(type, title: Self.title(for: type))
    }

    @objc private func splitFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let direction = SplitDirection(rawValue: parts[0]),
              let type = SurfaceType(rawValue: parts[1]) else { return }
        performSplit(direction, type: type, title: Self.title(for: type))
    }

    /// Testable seam shared by the @objc button handlers.
    @discardableResult
    public func performAdd(_ type: SurfaceType, title: String) -> SurfaceDescriptor? {
        guard let wid = currentWorkspaceID() else { return nil }
        let desc = try? router?.createSurface(workspace: wid, type: type, paneID: pane.id, title: title)
        if let desc { focusNewlyCreatedSurface(desc.id, in: wid) }
        return desc
    }

    @discardableResult
    public func performSplit(_ direction: SplitDirection, type: SurfaceType, title: String) -> SurfaceDescriptor? {
        guard let wid = currentWorkspaceID() else { return nil }
        let desc = try? router?.splitPane(workspace: wid, paneID: pane.id, direction: direction, surfaceType: type, title: title)
        if let desc { focusNewlyCreatedSurface(desc.id, in: wid) }
        return desc
    }

    /// UX-MAC_SHELL_WINDOW-001: route a freshly created surface through
    /// the focus path so its input is first responder immediately — no
    /// extra click before the user can type.
    private func focusNewlyCreatedSurface(_ id: SurfaceID, in workspace: WorkspaceID) {
        try? router?.focusSurface(workspace: workspace, surface: id)
        router?.windowController?.repairSelectedTerminalFocus(reason: "new_surface")
    }

    @discardableResult
    public func performTogglePaneMinimized() -> Bool {
        guard let wid = currentWorkspaceID(), let splitContext else { return false }
        let ratios = Self.toggledPaneMinimizedRatios(paneIndex: splitContext.paneIndex, ratios: splitContext.ratios)
        do {
            try router?.paneResize(workspace: wid, splitID: splitContext.splitID, ratios: ratios)
            return true
        } catch {
            return false
        }
    }

    @objc private func togglePaneMinimized() {
        _ = performTogglePaneMinimized()
    }

    public static func toggledPaneMinimizedRatios(paneIndex: Int, ratios: [Double]) -> [Double] {
        guard ratios.indices.contains(paneIndex), ratios.count > 1 else { return ratios }
        if isPaneMinimized(paneIndex: paneIndex, ratios: ratios) {
            return Array(repeating: 1.0 / Double(ratios.count), count: ratios.count)
        }
        let minimized = 0.04
        let remaining = 1.0 - minimized
        let otherTotal = ratios.indices
            .filter { $0 != paneIndex }
            .map { ratios[$0] }
            .reduce(0, +)
        return ratios.indices.map {
            if $0 == paneIndex { return minimized }
            guard otherTotal > 0 else { return remaining / Double(ratios.count - 1) }
            return remaining * ratios[$0] / otherTotal
        }
    }

    public static func isPaneMinimized(paneIndex: Int, ratios: [Double]) -> Bool {
        guard ratios.indices.contains(paneIndex) else { return false }
        let normalized = SplitNode.normalize(ratios)
        return normalized[paneIndex] <= 0.08
    }

    /// Testable drop-position math. The index is the count of tab
    /// midpoints strictly left of the drop point.
    public static func dropInsertionIndex(tabMidXs: [CGFloat], dropX: CGFloat) -> Int {
        tabMidXs.filter { dropX > $0 }.count
    }

    /// PERF: in-place tab-strip reconcile. Pure diff between the old and
    /// new ordered SurfaceID lists so the strip can be patched in place —
    /// existing buttons keep their identity (no container rebuild, no
    /// resize-end flash). Buttons whose id survives are *updated* in
    /// place; only `inserts`/`removes` change the button set, and
    /// `reordered` flags when the surviving ids changed relative order.
    public struct TabStripDiff: Equatable {
        /// ids present in `old` but absent from `new` — buttons to remove.
        public let removes: [SurfaceID]
        /// (id, index-in-new) for ids absent from `old` — buttons to
        /// insert at that position in the new order.
        public let inserts: [(id: SurfaceID, index: Int)]
        /// ids present in BOTH lists, in new order — buttons to update in
        /// place (selection/title/color/dirty) without rebuilding.
        public let updates: [SurfaceID]
        /// true when the relative order of surviving ids differs between
        /// old and new (buttons must be reordered, not just updated).
        public let reordered: Bool

        public static func == (lhs: TabStripDiff, rhs: TabStripDiff) -> Bool {
            lhs.removes == rhs.removes
                && lhs.updates == rhs.updates
                && lhs.reordered == rhs.reordered
                && lhs.inserts.count == rhs.inserts.count
                && zip(lhs.inserts, rhs.inserts).allSatisfy { $0.id == $1.id && $0.index == $1.index }
        }
    }

    /// Pure focus-follows-click resolver. Returns the (workspaceID, paneID)
    /// that should receive focus when the user clicks into a pane's content
    /// area. Returns nil when the pane is already the focused one so the
    /// caller can skip a redundant state write (idempotent path).
    ///
    /// Pure: only ID comparisons — no AppKit, no MainActor dependency.
    nonisolated public static func focusPaneCommand(
        currentFocusedPaneID: PaneID?,
        paneID: PaneID,
        workspaceID: WorkspaceID
    ) -> (workspace: WorkspaceID, pane: PaneID)? {
        guard currentFocusedPaneID != paneID else { return nil }
        return (workspaceID, paneID)
    }

    /// Pure tab-strip diff. Order-preserving: `updates` and the surviving
    /// order are taken from `new`. `reordered` compares the surviving ids'
    /// order in `old` vs `new`.
    public static func diffTabs(old: [SurfaceID], new: [SurfaceID]) -> TabStripDiff {
        let oldSet = Set(old)
        let newSet = Set(new)
        let removes = old.filter { !newSet.contains($0) }
        var inserts: [(id: SurfaceID, index: Int)] = []
        var updates: [SurfaceID] = []
        for (index, id) in new.enumerated() {
            if oldSet.contains(id) {
                updates.append(id)
            } else {
                inserts.append((id: id, index: index))
            }
        }
        // Surviving ids in each list's own order; if those sequences
        // differ, the survivors were reordered.
        let survivorsOld = old.filter { newSet.contains($0) }
        let survivorsNew = new.filter { oldSet.contains($0) }
        let reordered = survivorsOld != survivorsNew
        return TabStripDiff(removes: removes, inserts: inserts, updates: updates, reordered: reordered)
    }

    public static func splitDropDirection(in bounds: NSRect, at point: NSPoint) -> SplitDirection? {
        guard bounds.contains(point) else { return nil }
        let rightIntent = point.x - bounds.midX
        // downIntent positive when point is in the lower half (NSRect: y=0 at bottom).
        let downIntent = bounds.midY - point.y
        let absH = abs(rightIntent)
        let absV = abs(downIntent)
        guard absH > 0 || absV > 0 else { return nil }
        if absH >= absV {
            return rightIntent >= 0 ? .right : .left
        } else {
            return downIntent >= 0 ? .down : .up
        }
    }

    @discardableResult
    public func performReorderSurface(_ surface: SurfaceID, toPane targetPane: PaneID, position: Int) -> Bool {
        guard let wid = currentWorkspaceID() else { return false }
        do {
            try router?.surfaceReorder(workspace: wid, surface: surface, toPane: targetPane, position: position)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func performSplitSurface(_ surface: SurfaceID, direction: SplitDirection) -> Bool {
        performSplitSurface(surface, targetPane: pane.id, direction: direction)
    }

    @discardableResult
    public func performSplitSurface(_ surface: SurfaceID, targetPane: PaneID, direction: SplitDirection) -> Bool {
        guard let wid = currentWorkspaceID() else { return false }
        do {
            try router?.splitSurface(workspace: wid, paneID: targetPane, surface: surface, direction: direction)
            return true
        } catch {
            return false
        }
    }

    private func dropSurface(_ surface: SurfaceID, before target: SurfaceID) -> Bool {
        guard surface != target,
              let position = dropPosition(for: surface, before: target) else { return false }
        return performReorderSurface(surface, toPane: pane.id, position: position)
    }

    private func appendDroppedSurface(_ surface: SurfaceID) -> Bool {
        // Guard the lone-tab self-drop: re-dropping a pane's only surface onto its
        // own tab strip would remove-then-reinsert into a pane that the removal can
        // prune, risking data loss. It is also a visual no-op, so refuse it early.
        if pane.surfaces.count == 1, pane.surfaces.first?.id == surface {
            return false
        }
        let position = adjustedPositionForSamePane(surface, targetPosition: pane.surfaces.count)
        return performReorderSurface(surface, toPane: pane.id, position: position)
    }

    private func dropPosition(for surface: SurfaceID, before target: SurfaceID) -> Int? {
        guard let targetIndex = pane.surfaces.firstIndex(where: { $0.id == target }) else { return nil }
        return adjustedPositionForSamePane(surface, targetPosition: targetIndex)
    }

    private func adjustedPositionForSamePane(_ surface: SurfaceID, targetPosition: Int) -> Int {
        guard let sourceIndex = pane.surfaces.firstIndex(where: { $0.id == surface }),
              sourceIndex < targetPosition else { return targetPosition }
        return max(0, targetPosition - 1)
    }

}

// MARK: - Custom tab button (icon · truncating title · close ×)

@MainActor
final class PaneTabButton: NSView {
    static let pasteboardType = NSPasteboard.PasteboardType("io.remotecode.surface-id")
    private static weak var highlightedTab: PaneTabButton?
    private static weak var highlightedStrip: PaneTabDropStack?
    private static weak var highlightedSplitRoot: PaneRootView?
    private static weak var dragGhost: TabDragGhostView?
    private let surfaceID: SurfaceID
    private var title: String
    private let symbol: String
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let onCloseOthers: (() -> Void)?
    private let onCloseToLeft: (() -> Void)?
    private let onCloseToRight: (() -> Void)?
    private let onRename: (() -> Void)?
    private let onSetColor: ((String) -> Void)?
    private let onDropSurface: ((SurfaceID) -> Bool)?
    private let onSplitSurface: ((SurfaceID, PaneID, SplitDirection) -> Bool)?
    private let iconContainer = NSView()
    private let dropIndicator = NSView()
    private var hovering = false
    private var dragStarted = false
    private var mouseDownLocation: NSPoint?
    private var selected: Bool
    private var busy = false
    private var dirty = false
    // PERF: in-place tab reconcile. These subviews used to be local to
    // init (baked once, then the whole strip was rebuilt on any change).
    // Storing them lets `setSelected`/`setTitle`/`setColor` patch a tab in
    // place keyed by SurfaceID, so a selection/title/color change does not
    // tear down and recreate the button (no resize-end flash).
    private let label = NSTextField(labelWithString: "")
    private let underline = NSView()
    private let colorRail = NSView()
    private static let dragActivationDistance: CGFloat = 8

    // MARK: - A11y helper (pure, no AppKit dependency, testable without MainActor)

    /// Builds the VoiceOver label string for a tab button.
    /// Pure: only string manipulation — safe to call from any context.
    nonisolated static func tabA11yLabel(title: String, isSelected: Bool, isDirty: Bool) -> String {
        var parts: [String] = [title]
        if isDirty { parts.append("unsaved changes") }
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    init(surfaceID: SurfaceID, title: String, symbol: String, selected: Bool, busy: Bool = false,
         dirty: Bool = false,
         colorHex: UInt32? = nil,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void,
         onCloseOthers: (() -> Void)? = nil,
         onCloseToLeft: (() -> Void)? = nil,
         onCloseToRight: (() -> Void)? = nil,
         onRename: (() -> Void)? = nil, onSetColor: ((String) -> Void)? = nil,
         onDropSurface: ((SurfaceID) -> Bool)? = nil,
         onSplitSurface: ((SurfaceID, PaneID, SplitDirection) -> Bool)? = nil) {
        self.surfaceID = surfaceID
        self.title = title
        self.symbol = symbol
        self.onSelect = onSelect
        self.onClose = onClose
        self.onCloseOthers = onCloseOthers
        self.onCloseToLeft = onCloseToLeft
        self.onCloseToRight = onCloseToRight
        self.onRename = onRename
        self.onSetColor = onSetColor
        self.onDropSurface = onDropSurface
        self.onSplitSurface = onSplitSurface
        self.selected = selected
        self.dirty = dirty
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = (selected ? DS.NS.bg : DS.NS.surface).cgColor
        // QA-MAC_SHELL_WINDOW-001: addressable tab for UI automation.
        setAccessibilityIdentifier("pane.tab.\(surfaceID.value.uuidString)")
        // A11y: role, label, selected state, and actions so VoiceOver can
        // navigate and operate tabs without a mouse.
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(Self.tabA11yLabel(title: title, isSelected: selected, isDirty: dirty))
        setAccessibilitySelected(selected)
        applyA11yCustomActions()

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.setContentHuggingPriority(.required, for: .horizontal)
        self.busy = busy
        installIcon(busy: busy)

        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        label.textColor = selected ? DS.NS.text : DS.NS.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let dirtyBadge = NSView()
        dirtyBadge.wantsLayer = true
        dirtyBadge.layer?.backgroundColor = DS.NS.warning.cgColor
        dirtyBadge.layer?.cornerRadius = 3.5
        dirtyBadge.translatesAutoresizingMaskIntoConstraints = false
        dirtyBadge.isHidden = !dirty
        dirtyBadge.toolTip = "Unsaved changes"

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
        close.setAccessibilityIdentifier("pane.tab.\(surfaceID.value.uuidString).close")

        addSubview(iconContainer); addSubview(label); addSubview(dirtyBadge); addSubview(close)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),

            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 14),
            iconContainer.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            dirtyBadge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 7),
            dirtyBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            dirtyBadge.widthAnchor.constraint(equalToConstant: 7),
            dirtyBadge.heightAnchor.constraint(equalToConstant: 7),

            close.leadingAnchor.constraint(equalTo: dirtyBadge.trailingAnchor, constant: 8),
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

        // Always create the selection underline and color rail (hidden
        // when inactive) so `setSelected`/`setColor` can toggle them in
        // place during reconcile instead of forcing a button rebuild.
        underline.wantsLayer = true
        underline.layer?.backgroundColor = DS.NS.accent.cgColor
        underline.translatesAutoresizingMaskIntoConstraints = false
        underline.isHidden = !selected
        addSubview(underline)
        NSLayoutConstraint.activate([
            underline.leadingAnchor.constraint(equalTo: leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor),
            underline.heightAnchor.constraint(equalToConstant: 2)
        ])

        colorRail.wantsLayer = true
        colorRail.layer?.backgroundColor = colorHex.map { NSColor(hex: $0).cgColor }
        colorRail.translatesAutoresizingMaskIntoConstraints = false
        colorRail.isHidden = colorHex == nil
        addSubview(colorRail)
        NSLayoutConstraint.activate([
            colorRail.leadingAnchor.constraint(equalTo: leadingAnchor),
            colorRail.topAnchor.constraint(equalTo: topAnchor),
            colorRail.bottomAnchor.constraint(equalTo: bottomAnchor),
            colorRail.widthAnchor.constraint(equalToConstant: 3)
        ])

        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = DS.NS.accent.cgColor
        dropIndicator.translatesAutoresizingMaskIntoConstraints = false
        dropIndicator.isHidden = true
        addSubview(dropIndicator)
        NSLayoutConstraint.activate([
            dropIndicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropIndicator.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            dropIndicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            dropIndicator.widthAnchor.constraint(equalToConstant: 3)
        ])

        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        registerForDraggedTypes([Self.pasteboardType])
    }

    func setBusy(_ busy: Bool) {
        guard self.busy != busy else { return }
        self.busy = busy
        installIcon(busy: busy)
    }

    /// PERF: in-place selection update used by the tab-strip reconcile.
    /// Re-styles this existing button instead of recreating it, so a focus
    /// change does not rebuild the strip.
    func setSelected(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        if !(hovering && !selected) {
            layer?.backgroundColor = (selected ? DS.NS.bg : DS.NS.surface).cgColor
        }
        label.font = NSFont.systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        label.textColor = selected ? DS.NS.text : DS.NS.textSecondary
        underline.isHidden = !selected
        // Icon tint tracks selection; reinstall to recolor (cheap, and
        // preserves the spinner when busy).
        installIcon(busy: busy)
        setAccessibilitySelected(selected)
        setAccessibilityLabel(Self.tabA11yLabel(title: title, isSelected: selected, isDirty: dirty))
    }

    /// PERF: in-place title update used by the reconcile (rename).
    func setTitle(_ title: String) {
        guard self.title != title else { return }
        self.title = title
        label.stringValue = title
        setAccessibilityLabel(Self.tabA11yLabel(title: title, isSelected: selected, isDirty: dirty))
    }

    var titleForTesting: String { title }
    var selectedForTesting: Bool { selected }

    /// PERF: in-place color-rail update used by the reconcile.
    func setColorHex(_ hex: UInt32?) {
        colorRail.layer?.backgroundColor = hex.map { NSColor(hex: $0).cgColor }
        colorRail.isHidden = hex == nil
    }

    private func installIcon(busy: Bool) {
        iconContainer.subviews.forEach { $0.removeFromSuperview() }
        let icon: NSView
        if busy {
            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .small
            spin.isIndeterminate = true
            spin.startAnimation(nil)
            icon = spin
        } else {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            image.contentTintColor = selected ? DS.NS.text : DS.NS.textTertiary
            icon = image
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            icon.widthAnchor.constraint(lessThanOrEqualTo: iconContainer.widthAnchor),
            icon.heightAnchor.constraint(lessThanOrEqualTo: iconContainer.heightAnchor)
        ])
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = contextMenu()
        guard !menu.items.isEmpty else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func contextMenuForTesting() -> NSMenu {
        contextMenu()
    }

    var surfaceIDForTesting: SurfaceID { surfaceID }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        addContextItem(menu, title: "Close all others", action: #selector(closeOthers), enabled: onCloseOthers != nil)
        addContextItem(menu, title: "Close all to left", action: #selector(closeToLeft), enabled: onCloseToLeft != nil)
        addContextItem(menu, title: "Close all to right", action: #selector(closeToRight), enabled: onCloseToRight != nil)

        if onRename != nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
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
                mi.image = Self.colorSwatchImage(hex: c.hex)
                sub.addItem(mi)
            }
            colorItem.submenu = sub
            menu.addItem(colorItem)
        }
        return menu
    }

    private func addContextItem(_ menu: NSMenu, title: String, action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = enabled ? self : nil
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func renameTab() { onRename?() }
    @objc private func closeOthers() { onCloseOthers?() }
    @objc private func closeToLeft() { onCloseToLeft?() }
    @objc private func closeToRight() { onCloseToRight?() }
    @objc private func colorTab(_ sender: NSMenuItem) {
        onSetColor?((sender.representedObject as? String) ?? "")
    }

    private static func colorSwatchImage(hex: UInt32) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
        NSColor(hex: hex).setFill()
        path.fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    required init?(coder: NSCoder) { fatalError() }

    // In the full-size-content titlebar band, AppKit would otherwise
    // treat clicks here as a window drag and the tab/close never fire.
    override var mouseDownCanMoveWindow: Bool { false }

    // PERF-MAC_SHELL_WINDOW-005: if this tab is torn out of its window
    // mid-drag (e.g. window closed during a drag), the static drag-feedback
    // refs would otherwise leak a ghost/highlight until the next clear.
    // Clearing on detach scopes cleanup to the originating window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { Self.clearDragFeedback() }
    }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
        mouseDownLocation = event.locationInWindow
        Self.clearDragFeedback()
    }

    override func mouseDragged(with event: NSEvent) {
        if !dragStarted {
            guard Self.hasMovedBeyondDragThreshold(from: mouseDownLocation,
                                                   to: event.locationInWindow,
                                                   threshold: Self.dragActivationDistance) else { return }
            dragStarted = true
        }
        updateDragGhost(with: event)
        updateManualDropFeedback(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        if dragStarted {
            performManualDrop(with: event)
            Self.clearDragFeedback()
        } else if event.modifierFlags.contains(.command) {
            // IMP-MAC_SHELL_WINDOW-006: ⌘-click closes the tab (browser
            // muscle memory); ⌥⌘-click closes the other tabs instead.
            if event.modifierFlags.contains(.option) {
                (onCloseOthers ?? onClose)()
            } else {
                onClose()
            }
        } else {
            onSelect()
        }
    }

    // UX-MAC_SHELL_WINDOW-015: middle-click closes the tab (browser/editor
    // expectation). Routes through onClose so the unsaved-changes confirm
    // runs exactly as the "×" button does.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onClose()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedSurface(from: sender).map { $0 == surfaceID ? [] : .move } ?? []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dragged = draggedSurface(from: sender) else { return false }
        return onDropSurface?(dragged) ?? false
    }

    private func draggedSurface(from info: NSDraggingInfo) -> SurfaceID? {
        guard let raw = info.draggingPasteboard.string(forType: Self.pasteboardType),
              let uuid = UUID(uuidString: raw) else { return nil }
        return SurfaceID(uuid)
    }

    private func performManualDrop(with event: NSEvent) {
        guard let contentView = window?.contentView else { return }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(point) else { return }
        routeManualDrop(hit: hit, contentPoint: point, in: contentView)
    }

    /// QA-MAC_SHELL_WINDOW-004: the drop-routing decision (tab vs strip vs
    /// split) extracted from the live mouse event so it can be exercised
    /// with a synthetic hit view + content-space point in tests, without a
    /// real drag gesture.
    func performManualDropForTesting(hit: NSView, contentPoint: NSPoint, in contentView: NSView) {
        routeManualDrop(hit: hit, contentPoint: contentPoint, in: contentView)
    }

    private func routeManualDrop(hit: NSView, contentPoint point: NSPoint, in contentView: NSView) {
        if let target = enclosingView(from: hit, as: PaneTabButton.self), target !== self {
            _ = target.onDropSurface?(surfaceID)
            return
        }
        if let strip = enclosingView(from: hit, as: PaneTabDropStack.self) {
            _ = strip.onDropSurface?(surfaceID)
            return
        }
        if let target = splitTarget(for: hit, contentPoint: point, in: contentView) {
            _ = onSplitSurface?(surfaceID, target.paneID, target.direction)
        }
    }

    private func updateManualDropFeedback(with event: NSEvent) {
        guard let contentView = window?.contentView else {
            Self.clearDragFeedback()
            return
        }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(point) else {
            Self.clearDragFeedback()
            return
        }
        if let target = enclosingView(from: hit, as: PaneTabButton.self), target !== self {
            Self.highlight(tab: target, strip: nil)
            return
        }
        if let strip = enclosingView(from: hit, as: PaneTabDropStack.self) {
            Self.highlight(tab: nil, strip: strip)
            return
        }
        if let target = splitTarget(for: hit, contentPoint: point, in: contentView) {
            Self.highlight(tab: nil, strip: nil, splitRoot: target.root, splitDirection: target.direction)
            return
        }
        Self.clearDragFeedback()
    }

    private func splitTarget(for hit: NSView, contentPoint: NSPoint, in contentView: NSView) -> (paneID: PaneID, direction: SplitDirection, root: PaneRootView)? {
        guard let root = enclosingView(from: hit, as: PaneRootView.self),
              let paneID = root.paneID else { return nil }
        let point = root.convert(contentPoint, from: contentView)
        guard let direction = PaneTabsView.splitDropDirection(in: root.bounds, at: point) else { return nil }
        return (paneID, direction, root)
    }

    private func updateDragGhost(with event: NSEvent) {
        guard let contentView = window?.contentView else { return }
        let point = contentView.convert(event.locationInWindow, from: nil)
        if Self.dragGhost == nil {
            let ghost = TabDragGhostView(title: title, symbol: symbol)
            contentView.addSubview(ghost)
            Self.dragGhost = ghost
        }
        Self.dragGhost?.move(near: point, in: contentView.bounds)
    }

    private static func highlight(tab: PaneTabButton?, strip: PaneTabDropStack?, splitRoot: PaneRootView? = nil, splitDirection: SplitDirection? = nil) {
        if highlightedTab !== tab {
            highlightedTab?.setDropHighlighted(false)
            highlightedTab = tab
            highlightedTab?.setDropHighlighted(true)
        }
        if highlightedStrip !== strip {
            highlightedStrip?.setAppendHighlighted(false)
            highlightedStrip = strip
            highlightedStrip?.setAppendHighlighted(true)
        }
        if highlightedSplitRoot !== splitRoot {
            highlightedSplitRoot?.setSplitDropHighlighted(false)
            highlightedSplitRoot = splitRoot
            highlightedSplitRoot?.setSplitDropHighlighted(splitRoot != nil, direction: splitDirection)
        } else if splitRoot != nil {
            highlightedSplitRoot?.setSplitDropHighlighted(true, direction: splitDirection)
        }
    }

    private static func clearDragFeedback() {
        highlightedTab?.setDropHighlighted(false)
        highlightedTab = nil
        highlightedStrip?.setAppendHighlighted(false)
        highlightedStrip = nil
        highlightedSplitRoot?.setSplitDropHighlighted(false)
        highlightedSplitRoot = nil
        dragGhost?.removeFromSuperview()
        dragGhost = nil
    }

    private func setDropHighlighted(_ active: Bool) {
        dropIndicator.isHidden = !active
        if active {
            layer?.backgroundColor = DS.NS.surfaceRaised.cgColor
        } else if hovering && !selected {
            layer?.backgroundColor = DS.NS.surfaceRaised.cgColor
        } else {
            layer?.backgroundColor = (selected ? DS.NS.bg : DS.NS.surface).cgColor
        }
    }

    private func enclosingView<T: NSView>(from view: NSView, as type: T.Type) -> T? {
        var current: NSView? = view
        while let candidate = current {
            if let typed = candidate as? T { return typed }
            current = candidate.superview
        }
        return nil
    }

    func performSelectFromTitlebarClick() { onSelect() }

    @objc private func closeClicked() { onClose() }

    func setDirty(_ dirty: Bool) {
        self.dirty = dirty
        subviews.first { $0.toolTip == "Unsaved changes" }?.isHidden = !dirty
        setAccessibilityLabel(Self.tabA11yLabel(title: title, isSelected: selected, isDirty: dirty))
    }

    /// A11y: register close and rename as named custom actions so
    /// VoiceOver users can invoke them from the Actions rotor without
    /// moving focus to the sub-buttons.
    private func applyA11yCustomActions() {
        var actions: [NSAccessibilityCustomAction] = []
        actions.append(NSAccessibilityCustomAction(name: "Close tab") { [weak self] in
            self?.onClose()
            return true
        })
        if onRename != nil {
            actions.append(NSAccessibilityCustomAction(name: "Rename tab") { [weak self] in
                self?.onRename?()
                return true
            })
        }
        setAccessibilityCustomActions(actions)
    }

    /// Test seam: how many custom actions are registered on this tab.
    var accessibilityCustomActionCountForTesting: Int {
        (accessibilityCustomActions() ?? []).count
    }

    static func hasMovedBeyondDragThreshold(from start: NSPoint?, to current: NSPoint, threshold: CGFloat) -> Bool {
        guard let start else { return false }
        return hypot(current.x - start.x, current.y - start.y) >= threshold
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if !selected { layer?.backgroundColor = DS.NS.surfaceRaised.cgColor }
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !selected { layer?.backgroundColor = DS.NS.surface.cgColor }
    }
}

@MainActor
final class TabDragGhostView: NSView {
    private let width: CGFloat = 210
    private let height: CGFloat = 30

    init(title: String, symbol: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.backgroundColor = DS.NS.surfaceRaised.withAlphaComponent(0.92).cgColor
        layer?.borderColor = DS.NS.accent.withAlphaComponent(0.65).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = DS.Radius.control
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.32
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        alphaValue = 0.96

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = DS.NS.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = DS.NS.text
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    func move(near point: NSPoint, in bounds: NSRect) {
        let x = min(max(point.x + 12, bounds.minX + 6), bounds.maxX - width - 6)
        let y = min(max(point.y - height - 10, bounds.minY + 6), bounds.maxY - height - 6)
        frame.origin = NSPoint(x: x, y: y)
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
    static let splitDropOverlayLayerName = "split-drop-preview"
    var paneID: PaneID?
    /// Called before super.mouseDown so content-area clicks route pane focus
    /// before AppKit dispatches the event into the surface subview hierarchy.
    var onContentAreaMouseDown: (() -> Void)?
    private let splitDropOverlay = CALayer()
    private var splitDropDirection: SplitDirection?

    override func mouseDown(with event: NSEvent) {
        onContentAreaMouseDown?()
        super.mouseDown(with: event)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSplitDropOverlay()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSplitDropOverlay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsUpdateConstraints = true
        needsLayout = true
        updateConstraintsForSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        splitDropOverlay.frame = splitDropPreviewFrame(in: bounds, direction: splitDropDirection)
    }

    func setSplitDropHighlighted(_ active: Bool, direction: SplitDirection? = nil) {
        if splitDropOverlay.superlayer == nil {
            configureSplitDropOverlay()
        }
        splitDropDirection = active ? direction : nil
        splitDropOverlay.isHidden = !active
        splitDropOverlay.backgroundColor = DS.NS.splitPreviewFill.cgColor
        splitDropOverlay.borderColor = DS.NS.splitPreviewStroke.cgColor
        splitDropOverlay.borderWidth = active ? 2 : 0
        splitDropOverlay.frame = splitDropPreviewFrame(in: bounds, direction: splitDropDirection)
    }

    private func configureSplitDropOverlay() {
        wantsLayer = true
        splitDropOverlay.name = Self.splitDropOverlayLayerName
        splitDropOverlay.backgroundColor = DS.NS.splitPreviewFill.cgColor
        splitDropOverlay.borderColor = DS.NS.splitPreviewStroke.cgColor
        splitDropOverlay.borderWidth = 0
        splitDropOverlay.cornerRadius = 6
        splitDropOverlay.zPosition = 1_000
        splitDropOverlay.isHidden = true
        splitDropOverlay.masksToBounds = true
        layer?.addSublayer(splitDropOverlay)
    }

    private func splitDropPreviewFrame(in bounds: NSRect, direction: SplitDirection?) -> NSRect {
        let target: NSRect
        switch direction {
        case .left:
            target = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .right:
            target = NSRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .up:
            target = NSRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: bounds.height / 2)
        case .down:
            target = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height / 2)
        case nil:
            target = bounds
        }
        return target.insetBy(dx: 2, dy: 2)
    }
}

class NoDragStack: NSStackView {
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
final class PaneTabDropStack: NoDragStack {
    var onDropSurface: ((SurfaceID) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureDropFeedback()
        registerForDraggedTypes([PaneTabButton.pasteboardType])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureDropFeedback()
        registerForDraggedTypes([PaneTabButton.pasteboardType])
    }

    func setAppendHighlighted(_ active: Bool) {
        layer?.borderWidth = active ? 1 : 0
        layer?.backgroundColor = active ? DS.NS.surfaceRaised.withAlphaComponent(0.45).cgColor : NSColor.clear.cgColor
    }

    private func configureDropFeedback() {
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.control
        layer?.borderColor = DS.NS.accent.cgColor
        layer?.borderWidth = 0
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedSurface(from: sender) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dragged = draggedSurface(from: sender) else { return false }
        return onDropSurface?(dragged) ?? false
    }

    private func draggedSurface(from info: NSDraggingInfo) -> SurfaceID? {
        guard let raw = info.draggingPasteboard.string(forType: PaneTabButton.pasteboardType),
              let uuid = UUID(uuidString: raw) else { return nil }
        return SurfaceID(uuid)
    }
}

class NoDragScroll: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class HorizontalTabScrollView: NoDragScroll {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        contentView.postsBoundsChangedNotifications = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) < abs(event.scrollingDeltaY),
              abs(event.scrollingDeltaY) > 0 else {
            super.scrollWheel(with: event)
            return
        }
        scrollHorizontally(by: -event.scrollingDeltaY)
    }

    func scrollDocumentViewToVisible(_ view: NSView) {
        guard let documentView else { return }
        let rect = view.convert(view.bounds, to: documentView).insetBy(dx: -20, dy: 0)
        documentView.scrollToVisible(rect)
    }

    func scrollHorizontally(by delta: CGFloat) {
        guard let documentView else { return }
        var bounds = contentView.bounds
        let maxX = max(0, documentView.bounds.width - bounds.width)
        bounds.origin.x = min(max(0, bounds.origin.x + delta), maxX)
        contentView.scroll(to: bounds.origin)
        reflectScrolledClipView(contentView)
    }
}

final class NoDragButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
}
