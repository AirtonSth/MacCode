import Foundation
import AppKit
import CoreModel
import Surfaces
import DesignSystemKit

final class InteractiveTitlebarWindow: NSWindow {
    private weak var titlebarTabDragTarget: PaneTabButton?
    private var frameBeforeTitlebarZoom: NSRect?
    private var lastTitlebarClick: (time: TimeInterval, point: NSPoint)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, dispatchTitlebarDoubleClick(event) {
            return
        }
        if routeTitlebarTabDrag(event) {
            return
        }
        if event.type == .leftMouseDown, dispatchInteractiveTitlebarClick(event) {
            return
        }
        super.sendEvent(event)
    }

    private func routeTitlebarTabDrag(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard let tab = titlebarTab(at: event) else { return false }
            titlebarTabDragTarget = tab
            tab.mouseDown(with: event)
            return true
        case .leftMouseDragged:
            guard let tab = titlebarTabDragTarget else { return false }
            tab.mouseDragged(with: event)
            return true
        case .leftMouseUp:
            guard let tab = titlebarTabDragTarget else { return false }
            tab.mouseUp(with: event)
            titlebarTabDragTarget = nil
            return true
        default:
            return false
        }
    }

    private func dispatchTitlebarDoubleClick(_ event: NSEvent) -> Bool {
        guard let point = titlebarZoomPoint(for: event) else { return false }

        let isDoubleClick = event.clickCount == 2 || isRepeatedTitlebarClick(event, at: point)
        lastTitlebarClick = (event.timestamp, point)
        guard isDoubleClick else { return false }

        toggleTitlebarZoom()
        lastTitlebarClick = nil
        return true
    }

    private func titlebarZoomPoint(for event: NSEvent) -> NSPoint? {
        guard styleMask.contains(.fullSizeContentView),
              let contentView else { return nil }

        let point = contentView.convert(event.locationInWindow, from: nil)
        guard point.y >= contentView.bounds.height - 44 else { return nil }
        guard let hit = contentView.hitTest(point) else { return point }
        guard enclosingView(from: hit, as: NoDragButton.self) == nil,
              enclosingView(from: hit, as: PaneTabButton.self) == nil else { return nil }
        return point
    }

    private func isRepeatedTitlebarClick(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard let last = lastTitlebarClick else { return false }
        let interval = event.timestamp - last.time
        let distance = hypot(point.x - last.point.x, point.y - last.point.y)
        return interval <= NSEvent.doubleClickInterval && distance <= 4
    }

    private func toggleTitlebarZoom() {
        guard let screen else {
            performZoom(nil)
            return
        }
        if let previous = frameBeforeTitlebarZoom {
            setFrame(previous, display: true, animate: true)
            frameBeforeTitlebarZoom = nil
        } else {
            frameBeforeTitlebarZoom = frame
            setFrame(screen.visibleFrame, display: true, animate: true)
        }
    }

    private func titlebarTab(at event: NSEvent) -> PaneTabButton? {
        guard styleMask.contains(.fullSizeContentView),
              let contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard point.y >= contentView.bounds.height - 44,
              let hit = contentView.hitTest(point),
              enclosingView(from: hit, as: NoDragButton.self) == nil else { return nil }
        return enclosingView(from: hit, as: PaneTabButton.self)
    }

    private func dispatchInteractiveTitlebarClick(_ event: NSEvent) -> Bool {
        guard styleMask.contains(.fullSizeContentView),
              let contentView else { return false }

        let point = contentView.convert(event.locationInWindow, from: nil)
        guard point.y >= contentView.bounds.height - 44,
              let hit = contentView.hitTest(point) else { return false }

        if let button = enclosingView(from: hit, as: NoDragButton.self) {
            button.performClick(nil)
            return true
        }

        return false
    }

    private func enclosingView<T: NSView>(from view: NSView, as type: T.Type) -> T? {
        var current: NSView? = view
        while let candidate = current {
            if let typed = candidate as? T { return typed }
            current = candidate.superview
        }
        return nil
    }
}

private extension NSRect {
    func isNearlyEqual(to other: NSRect) -> Bool {
        abs(origin.x - other.origin.x) < 2 &&
        abs(origin.y - other.origin.y) < 2 &&
        abs(size.width - other.size.width) < 2 &&
        abs(size.height - other.size.height) < 2
    }
}

public extension Notification.Name {
    /// Posted by any sidebar-toggle button (sidebar header or pane header).
    static let rc2ToggleSidebar = Notification.Name("rc2.toggleSidebar")
    /// Posted by the window controller after the sidebar collapses /
    /// expands. userInfo["collapsed"] = Bool.
    static let rc2SidebarVisibility = Notification.Name("rc2.sidebarVisibility")
}

@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate, NSSplitViewDelegate {
    public let window: NSWindow
    public weak var context: AppContext?
    public weak var router: AppCommandRouter?

    private let sidebar: SidebarView
    private let workspaceContainer = NSView()
    private let workspaceContent = NSView()
    private let collapsedWorkspaceHeader = NoDragView()
    private let collapsedWorkspaceLabel = NSTextField(labelWithString: "")
    private let collapsedPlusButton = NoDragButton(frame: .zero)
    private let collapsedSidebarButton = NoDragButton(frame: .zero)
    private let visibleWorkspaceHeader = NoDragView()
    private let visibleWorkspaceLabel = NSTextField(labelWithString: "")
    private let visibleNewWindowButton = NoDragButton(frame: .zero)
    private let split = NSSplitView()
    private let toolbarLabel = NSTextField(labelWithString: "RemoteCode")
    /// Retains the live pane controllers; their @objc button and tab
    /// targets die with them, so they must outlive a layout rebuild.
    private var paneControllers: [PaneTabsView] = []
    private var sidebarCollapsed = false
    private static let defaultSidebarWidth: CGFloat = 444
    private static let sidebarWidthSettingsKey = "sidebar.width"
    private var sidebarWidth: CGFloat = MainWindowController.defaultSidebarWidth
    private var didApplyInitialSidebarWidth = false
    private let collapsedHeaderHeight: CGFloat = 34
    private var splitTopConstraint: NSLayoutConstraint?
    private var workspaceContentTopConstraint: NSLayoutConstraint?
    private var workspaceWindows: [WorkspaceID: WorkspaceWindowController] = [:]
    private var detachedWorkspaceIDs: Set<WorkspaceID> = []

    public init(context: AppContext, router: AppCommandRouter) {
        self.context = context
        self.router = router
        self.sidebar = SidebarView(context: context, router: router)
        self.sidebarWidth = Self.storedSidebarWidth(context: context)

        let style: NSWindow.StyleMask = [.titled, .resizable, .closable, .miniaturizable]
        let win = InteractiveTitlebarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        win.title = "RemoteCode"
        // Unified titlebar: content runs full height, the system title
        // bar is transparent and titleless, so the traffic-light buttons
        // float over the app's own header row (the sidebar header).
        win.styleMask.insert(.fullSizeContentView)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = false
        win.minSize = NSSize(width: 900, height: 600)
        self.window = win

        super.init()
        win.delegate = self
        setupLayout()
        refreshFromState()
        win.center()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleToggleSidebar),
            name: .rc2ToggleSidebar, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleToggleSidebar() {
        sidebarCollapsed.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            sidebar.view.isHidden = sidebarCollapsed
            collapsedWorkspaceHeader.isHidden = !sidebarCollapsed
            visibleWorkspaceHeader.isHidden = sidebarCollapsed
            splitTopConstraint?.constant = sidebarCollapsed ? collapsedHeaderHeight : 0
            workspaceContentTopConstraint?.constant = sidebarCollapsed ? 0 : collapsedHeaderHeight
            updateCollapsedWorkspaceHeader()
            if !sidebarCollapsed {
                split.setPosition(sidebarWidth, ofDividerAt: 0)
            }
            window.contentView?.layoutSubtreeIfNeeded()
        }
        NotificationCenter.default.post(
            name: .rc2SidebarVisibility, object: nil,
            userInfo: ["collapsed": sidebarCollapsed])
    }

    private func setupLayout() {
        window.backgroundColor = DS.NS.bg
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = DS.NS.bg.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        workspaceContainer.translatesAutoresizingMaskIntoConstraints = false
        workspaceContent.translatesAutoresizingMaskIntoConstraints = false

        workspaceContainer.wantsLayer = true
        workspaceContainer.layer?.backgroundColor = DS.NS.bg.cgColor
        workspaceContent.wantsLayer = true
        workspaceContent.layer?.backgroundColor = DS.NS.bg.cgColor
        workspaceContainer.addSubview(workspaceContent)
        let workspaceTop = workspaceContent.topAnchor.constraint(equalTo: workspaceContainer.topAnchor, constant: collapsedHeaderHeight)
        workspaceContentTopConstraint = workspaceTop
        NSLayoutConstraint.activate([
            workspaceTop,
            workspaceContent.bottomAnchor.constraint(equalTo: workspaceContainer.bottomAnchor),
            workspaceContent.leadingAnchor.constraint(equalTo: workspaceContainer.leadingAnchor),
            workspaceContent.trailingAnchor.constraint(equalTo: workspaceContainer.trailingAnchor)
        ])
        configureCollapsedWorkspaceHeader()
        configureVisibleWorkspaceHeader()
        split.addArrangedSubview(sidebar.view)
        split.addArrangedSubview(workspaceContainer)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        content.addSubview(split)
        content.addSubview(visibleWorkspaceHeader)
        content.addSubview(collapsedWorkspaceHeader)
        collapsedWorkspaceHeader.isHidden = true
        let splitTop = split.topAnchor.constraint(equalTo: content.topAnchor, constant: 0)
        splitTopConstraint = splitTop
        NSLayoutConstraint.activate([
            splitTop,
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            visibleWorkspaceHeader.topAnchor.constraint(equalTo: content.topAnchor),
            visibleWorkspaceHeader.leadingAnchor.constraint(equalTo: workspaceContainer.leadingAnchor),
            visibleWorkspaceHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            visibleWorkspaceHeader.heightAnchor.constraint(equalToConstant: collapsedHeaderHeight),
            collapsedWorkspaceHeader.topAnchor.constraint(equalTo: content.topAnchor),
            collapsedWorkspaceHeader.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            collapsedWorkspaceHeader.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            collapsedWorkspaceHeader.heightAnchor.constraint(equalToConstant: collapsedHeaderHeight)
        ])
        window.contentView = content
        // give sidebar a default size
        DispatchQueue.main.async {
            self.split.setPosition(self.sidebarWidth, ofDividerAt: 0)
            self.didApplyInitialSidebarWidth = true
        }
    }

    public func show() {
        window.makeKeyAndOrderFront(nil)
    }

	    private func configureCollapsedWorkspaceHeader() {
	        collapsedWorkspaceHeader.translatesAutoresizingMaskIntoConstraints = false
	        collapsedWorkspaceHeader.wantsLayer = true
	        collapsedWorkspaceHeader.layer?.backgroundColor = DS.NS.surface.cgColor
	        collapsedWorkspaceHeader.layer?.masksToBounds = true

	        collapsedWorkspaceLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
	        collapsedWorkspaceLabel.textColor = DS.NS.text
	        collapsedWorkspaceLabel.alignment = .center
	        collapsedWorkspaceLabel.lineBreakMode = .byTruncatingTail
	        collapsedWorkspaceLabel.translatesAutoresizingMaskIntoConstraints = false

	        configureHeaderButton(collapsedPlusButton, symbol: "plus",
	                              help: "New workspace",
	                              action: #selector(newWorkspace))
	        configureHeaderButton(collapsedSidebarButton, symbol: "sidebar.left",
	                              help: "Toggle sidebar",
	                              action: #selector(handleToggleSidebar))

	        let divider = NSView()
	        divider.wantsLayer = true
	        divider.layer?.backgroundColor = DS.NS.line.cgColor
	        divider.translatesAutoresizingMaskIntoConstraints = false

	        collapsedWorkspaceHeader.addSubview(collapsedWorkspaceLabel)
	        collapsedWorkspaceHeader.addSubview(collapsedPlusButton)
	        collapsedWorkspaceHeader.addSubview(collapsedSidebarButton)
	        collapsedWorkspaceHeader.addSubview(divider)
	        NSLayoutConstraint.activate([
	            collapsedWorkspaceLabel.centerXAnchor.constraint(equalTo: collapsedWorkspaceHeader.centerXAnchor),
	            collapsedWorkspaceLabel.centerYAnchor.constraint(equalTo: collapsedWorkspaceHeader.centerYAnchor),
		            collapsedWorkspaceLabel.leadingAnchor.constraint(greaterThanOrEqualTo: collapsedSidebarButton.trailingAnchor, constant: DS.Space.sm),
		            collapsedWorkspaceLabel.trailingAnchor.constraint(lessThanOrEqualTo: collapsedPlusButton.leadingAnchor, constant: -DS.Space.sm),
		            collapsedPlusButton.trailingAnchor.constraint(equalTo: collapsedWorkspaceHeader.trailingAnchor, constant: -DS.Space.sm),
		            collapsedPlusButton.centerYAnchor.constraint(equalTo: collapsedWorkspaceHeader.centerYAnchor),
		            collapsedSidebarButton.leadingAnchor.constraint(equalTo: collapsedWorkspaceHeader.leadingAnchor, constant: 92),
		            collapsedSidebarButton.centerYAnchor.constraint(equalTo: collapsedWorkspaceHeader.centerYAnchor),
	            divider.leadingAnchor.constraint(equalTo: collapsedWorkspaceHeader.leadingAnchor),
	            divider.trailingAnchor.constraint(equalTo: collapsedWorkspaceHeader.trailingAnchor),
	            divider.bottomAnchor.constraint(equalTo: collapsedWorkspaceHeader.bottomAnchor),
	            divider.heightAnchor.constraint(equalToConstant: 1)
	        ])
	        updateCollapsedWorkspaceHeader()
	    }

        private func configureVisibleWorkspaceHeader() {
            visibleWorkspaceHeader.translatesAutoresizingMaskIntoConstraints = false
            visibleWorkspaceHeader.wantsLayer = true
            visibleWorkspaceHeader.layer?.backgroundColor = DS.NS.surface.cgColor
            visibleWorkspaceHeader.layer?.masksToBounds = true

            visibleWorkspaceLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            visibleWorkspaceLabel.textColor = DS.NS.text
            visibleWorkspaceLabel.alignment = .center
            visibleWorkspaceLabel.lineBreakMode = .byTruncatingTail
            visibleWorkspaceLabel.translatesAutoresizingMaskIntoConstraints = false
            configureHeaderButton(
                visibleNewWindowButton,
                symbol: "rectangle.on.rectangle",
                help: "Open in New Window",
                action: #selector(openSelectedWorkspaceInNewWindow)
            )

            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = DS.NS.line.cgColor
            divider.translatesAutoresizingMaskIntoConstraints = false

            visibleWorkspaceHeader.addSubview(visibleWorkspaceLabel)
            visibleWorkspaceHeader.addSubview(visibleNewWindowButton)
            visibleWorkspaceHeader.addSubview(divider)
            NSLayoutConstraint.activate([
                visibleWorkspaceLabel.centerXAnchor.constraint(equalTo: visibleWorkspaceHeader.centerXAnchor),
                visibleWorkspaceLabel.centerYAnchor.constraint(equalTo: visibleWorkspaceHeader.centerYAnchor),
                visibleWorkspaceLabel.leadingAnchor.constraint(greaterThanOrEqualTo: visibleWorkspaceHeader.leadingAnchor, constant: DS.Space.lg),
                visibleWorkspaceLabel.trailingAnchor.constraint(lessThanOrEqualTo: visibleNewWindowButton.leadingAnchor, constant: -DS.Space.sm),
                visibleNewWindowButton.trailingAnchor.constraint(equalTo: visibleWorkspaceHeader.trailingAnchor, constant: -DS.Space.sm),
                visibleNewWindowButton.centerYAnchor.constraint(equalTo: visibleWorkspaceHeader.centerYAnchor),
                divider.leadingAnchor.constraint(equalTo: visibleWorkspaceHeader.leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: visibleWorkspaceHeader.trailingAnchor),
                divider.bottomAnchor.constraint(equalTo: visibleWorkspaceHeader.bottomAnchor),
                divider.heightAnchor.constraint(equalToConstant: 1)
            ])
            updateCollapsedWorkspaceHeader()
        }

	    private func configureHeaderButton(_ button: NSButton, symbol: String, help: String, action: Selector) {
	        button.translatesAutoresizingMaskIntoConstraints = false
	        button.isBordered = false
	        button.bezelStyle = .inline
	        button.imagePosition = .imageOnly
	        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
	        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
	        button.contentTintColor = DS.NS.textSecondary
	        button.toolTip = help
	        button.target = self
	        button.action = action
	        button.wantsLayer = true
	        button.layer?.cornerRadius = DS.Radius.control
	        NSLayoutConstraint.activate([
	            button.widthAnchor.constraint(equalToConstant: 26),
	            button.heightAnchor.constraint(equalToConstant: 22)
	        ])
	    }

	    private func updateCollapsedWorkspaceHeader() {
	        guard let ctx = context,
	              let wid = ctx.state.window.selectedWorkspaceID,
	              let ws = ctx.state.workspaces[wid] else {
	            collapsedWorkspaceLabel.stringValue = "RemoteCode"
	            visibleWorkspaceLabel.stringValue = "RemoteCode"
                visibleNewWindowButton.isHidden = true
	            return
	        }
	        collapsedWorkspaceLabel.stringValue = ws.name
	        visibleWorkspaceLabel.stringValue = ws.name
            visibleNewWindowButton.isHidden = isWorkspaceOpenInNewWindow(wid)
	    }

	    @objc private func newWorkspace() {
	        let panel = NSOpenPanel()
	        panel.canChooseFiles = false
	        panel.canChooseDirectories = true
	        if panel.runModal() == .OK, let url = panel.url {
	            _ = try? router?.createWorkspace(name: url.lastPathComponent, cwd: url.path)
	        }
	    }

        @objc private func openSelectedWorkspaceInNewWindow() {
            guard let wid = context?.state.window.selectedWorkspaceID,
                  !isWorkspaceOpenInNewWindow(wid) else { return }
            openWorkspaceInNewWindow(wid)
        }

    public func refreshFromState() {
        let focusedInput = protectedFocusedView()
        sidebar.refresh()
        updateCollapsedWorkspaceHeader()
        rebuildWorkspaceContainer()
        for (workspaceID, controller) in Array(workspaceWindows) {
            guard context?.state.workspaces[workspaceID] != nil else {
                workspaceWindows.removeValue(forKey: workspaceID)
                detachedWorkspaceIDs.remove(workspaceID)
                controller.closeFromOwner()
                continue
            }
            controller.refreshFromState()
        }
        restoreProtectedFocus(focusedInput)
    }

    public func focusSurface(_ id: SurfaceID) {
        if let s = SurfaceRegistry.shared.surface(id) {
            s.focus()
        }
    }

    public var hasProtectedInputFocus: Bool {
        protectedFocusedView() != nil
    }

    private func protectedFocusedView() -> NSView? {
        guard let responder = window.firstResponder as? NSView,
              responder is NSTextView else { return nil }
        return responder
    }

    private func restoreProtectedFocus(_ focusedView: NSView?) {
        guard let focusedView,
              focusedView.window === window,
              focusedView.isDescendant(of: workspaceContent) else { return }
        window.makeFirstResponder(focusedView)
    }

    private var extraWindows: [WindowID: NSWindow] = [:]

    public func openAdditionalWindow(for w: AppWindow) {
        if let existing = extraWindows[w.id] { existing.makeKeyAndOrderFront(nil); return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = w.title
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "Window \(w.id.value.uuidString.prefix(8))\nuse the sidebar / CLI (rc2 workspace.move_to_window) to attach workspaces.")
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor)
        ])
        win.contentView = v
        win.center()
        win.makeKeyAndOrderFront(nil)
        extraWindows[w.id] = win
    }

    public func openWorkspaceInNewWindow(_ workspaceID: WorkspaceID) {
        guard let ctx = context, let router, ctx.state.workspaces[workspaceID] != nil else { return }
        if let existing = workspaceWindows[workspaceID] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        detachedWorkspaceIDs.insert(workspaceID)
        if ctx.state.window.selectedWorkspaceID == workspaceID,
           let fallback = ctx.state.window.workspaces.first(where: { $0 != workspaceID }) {
            try? router.selectWorkspace(fallback)
        } else {
            refreshFromState()
        }
        let controller = WorkspaceWindowController(
            workspaceID: workspaceID,
            context: ctx,
            router: router,
            onBack: { [weak self] in self?.returnWorkspaceToSidebar(workspaceID) },
            onClose: { [weak self] in self?.workspaceWindowClosed(workspaceID) }
        )
        workspaceWindows[workspaceID] = controller
        updateCollapsedWorkspaceHeader()
        controller.show()
    }

    public func workspaceWindow(for workspaceID: WorkspaceID) -> NSWindow? {
        workspaceWindows[workspaceID]?.window
    }

    public func isWorkspaceOpenInNewWindow(_ workspaceID: WorkspaceID) -> Bool {
        workspaceWindows[workspaceID] != nil
    }

    private func returnWorkspaceToSidebar(_ workspaceID: WorkspaceID) {
        let controller = workspaceWindows.removeValue(forKey: workspaceID)
        detachedWorkspaceIDs.remove(workspaceID)
        if sidebarCollapsed {
            handleToggleSidebar()
        }
        try? router?.selectWorkspace(workspaceID)
        refreshFromState()
        window.makeKeyAndOrderFront(nil)
        controller?.closeFromOwner()
    }

    private func workspaceWindowClosed(_ workspaceID: WorkspaceID) {
        workspaceWindows.removeValue(forKey: workspaceID)
        detachedWorkspaceIDs.remove(workspaceID)
        if context?.state.workspaces[workspaceID] != nil {
            try? router?.selectWorkspace(workspaceID)
        }
        refreshFromState()
        window.makeKeyAndOrderFront(nil)
    }

    private func rebuildWorkspaceContainer() {
        window.disableScreenUpdatesUntilFlush()
        for sub in workspaceContent.subviews { sub.removeFromSuperview() }
        // Drop references to the previous pane controllers; new ones are
        // created below. Without retaining them their @objc button/tab
        // targets are deallocated and clicks silently no-op.
        paneControllers.removeAll()
        guard let ctx = context,
              let wid = ctx.state.window.selectedWorkspaceID,
              let ws = ctx.state.workspaces[wid],
              !detachedWorkspaceIDs.contains(wid) else {
            let empty = makeEmptyState()
            workspaceContent.addSubview(empty)
            pin(empty, to: workspaceContent)
            return
        }
        var primaryControlsAvailable = true
        let layoutView = buildLayoutView(node: ws.layout, primaryControlsAvailable: &primaryControlsAvailable)
        attachRootLayoutView(layoutView)
        // Freshly built pane headers default to "sidebar visible"; if it
        // is actually collapsed, re-sync them so the workspace name shows.
        if sidebarCollapsed {
            NotificationCenter.default.post(
                name: .rc2SidebarVisibility, object: nil,
                userInfo: ["collapsed": true])
        }
    }

    private func attachRootLayoutView(_ layoutView: NSView) {
        layoutView.translatesAutoresizingMaskIntoConstraints = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            workspaceContent.addSubview(layoutView)
            NSLayoutConstraint.activate([
                layoutView.topAnchor.constraint(equalTo: workspaceContent.topAnchor),
                layoutView.bottomAnchor.constraint(equalTo: workspaceContent.bottomAnchor),
                layoutView.leadingAnchor.constraint(equalTo: workspaceContent.leadingAnchor),
                layoutView.trailingAnchor.constraint(equalTo: workspaceContent.trailingAnchor)
            ])
            layoutView.needsLayout = true
            layoutView.layoutSubtreeIfNeeded()
            if let split = layoutView as? RatioSplitView {
                split.relayoutNow()
            }
        }
    }

    private func makeEmptyState() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = DS.NS.bg.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "square.split.2x2", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .light)
        icon.contentTintColor = DS.NS.textTertiary
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "No workspace selected")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = DS.NS.textSecondary
        title.translatesAutoresizingMaskIntoConstraints = false

        let sub = NSTextField(labelWithString: "Press ⌘N or the sidebar + button to open a folder as a workspace.")
        sub.font = NSFont.systemFont(ofSize: 12)
        sub.textColor = DS.NS.textTertiary
        sub.alignment = .center
        sub.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, title, sub])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor)
        ])
        return v
    }

    private func buildLayoutView(node: LayoutNode, primaryControlsAvailable: inout Bool, splitContext: PaneSplitContext? = nil) -> NSView {
        switch node {
        case .pane(let p):
            let showsWorkspaceControls = primaryControlsAvailable
            primaryControlsAvailable = false
            let ptv = PaneTabsView(
                pane: p,
                router: router,
                showsWorkspaceControls: showsWorkspaceControls,
                splitContext: splitContext
            )
            paneControllers.append(ptv)
            return ptv.view
        case .split(let s):
            let split = RatioSplitView()
            split.isVertical = (s.orientation == .horizontal)
            split.dividerStyle = .thin
            split.ratios = s.ratios.map { CGFloat($0) }
            let splitID = s.id
            if let wid = context?.state.window.selectedWorkspaceID {
                split.onRatiosChanged = { [weak self] ratios in
                    try? self?.router?.paneResize(workspace: wid, splitID: splitID, ratios: ratios.map(Double.init))
                }
            }
            for (index, child) in s.children.enumerated() {
                let childSplitContext = PaneSplitContext(splitID: s.id, paneIndex: index, ratios: s.ratios, orientation: s.orientation)
                let cv = buildLayoutView(node: child, primaryControlsAvailable: &primaryControlsAvailable, splitContext: childSplitContext)
                // Frame-managed (NOT arranged / NOT autolayout): the
                // RatioSplitView owns every subview frame so the split
                // is exactly proportional.
                cv.translatesAutoresizingMaskIntoConstraints = true
                cv.autoresizingMask = []
                split.addSubview(cv)
            }
            return split
        }
    }

    private func pin(_ child: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        ])
    }

    // MARK: NSWindowDelegate
    public func windowWillClose(_ notification: Notification) {
        context?.saveSnapshot()
    }

    // MARK: NSSplitViewDelegate
    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === split, dividerIndex == 0 else { return proposedMinimumPosition }
        return 180
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard splitView === split, dividerIndex == 0 else { return proposedMaximumPosition }
        return max(220, splitView.bounds.width - 520)
    }

    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let splitView = notification.object as? NSSplitView,
              splitView === split,
              didApplyInitialSidebarWidth,
              !sidebarCollapsed else { return }
        sidebarWidth = sidebar.view.frame.width
        try? context?.settingsRepo.set(Self.sidebarWidthSettingsKey, "\(Double(sidebarWidth))")
    }

    private static func storedSidebarWidth(context: AppContext) -> CGFloat {
        guard let raw = (try? context.settingsRepo.get(sidebarWidthSettingsKey)) ?? nil,
              let value = Double(raw) else {
            return defaultSidebarWidth
        }
        return min(560, max(180, CGFloat(value)))
    }
}

@MainActor
private final class WorkspaceWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let workspaceID: WorkspaceID
    private weak var context: AppContext?
    private weak var router: AppCommandRouter?
    private let content = NSView()
    private let workspaceContent = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var paneControllers: [PaneTabsView] = []
    private var closingFromOwner = false
    private let onBack: () -> Void
    private let onClose: () -> Void

    init(workspaceID: WorkspaceID, context: AppContext, router: AppCommandRouter, onBack: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.workspaceID = workspaceID
        self.context = context
        self.router = router
        self.onBack = onBack
        self.onClose = onClose
        let win = InteractiveTitlebarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.styleMask.insert(.fullSizeContentView)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = false
        win.minSize = NSSize(width: 760, height: 520)
        self.window = win
        super.init()
        win.delegate = self
        setupLayout()
        refreshFromState()
        win.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    func closeFromOwner() {
        closingFromOwner = true
        window.orderOut(nil)
    }

    func refreshFromState() {
        guard let ws = context?.state.workspaces[workspaceID] else {
            closeFromOwner()
            return
        }
        window.title = ws.name
        titleLabel.stringValue = ws.name
        for subview in workspaceContent.subviews { subview.removeFromSuperview() }
        paneControllers.removeAll()
        var primaryControlsAvailable = true
        let layout = buildLayoutView(node: ws.layout, primaryControlsAvailable: &primaryControlsAvailable)
        layout.translatesAutoresizingMaskIntoConstraints = true
        layout.frame = workspaceContent.bounds
        layout.autoresizingMask = [.width, .height]
        workspaceContent.addSubview(layout)
        if let split = layout as? RatioSplitView {
            split.relayoutNow()
        }
    }

    private func setupLayout() {
        window.backgroundColor = DS.NS.bg
        content.wantsLayer = true
        content.layer?.backgroundColor = DS.NS.bg.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        workspaceContent.wantsLayer = true
        workspaceContent.layer?.backgroundColor = DS.NS.bg.cgColor
        workspaceContent.translatesAutoresizingMaskIntoConstraints = false

        let header = NoDragView()
        header.wantsLayer = true
        header.layer?.backgroundColor = DS.NS.surface.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let backButton = NoDragButton(frame: .zero)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isBordered = false
        backButton.bezelStyle = .inline
        backButton.imagePosition = .imageOnly
        backButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Back to sidebar")
        backButton.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        backButton.contentTintColor = DS.NS.textSecondary
        backButton.toolTip = "Back to sidebar"
        backButton.target = self
        backButton.action = #selector(backToSidebar)

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = DS.NS.text
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DS.NS.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(backButton)
        header.addSubview(titleLabel)
        header.addSubview(divider)
        content.addSubview(header)
        content.addSubview(workspaceContent)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),

            backButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 92),
            backButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 26),
            backButton.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: DS.Space.sm),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -DS.Space.lg),

            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            workspaceContent.topAnchor.constraint(equalTo: header.bottomAnchor),
            workspaceContent.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            workspaceContent.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            workspaceContent.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        window.contentView = content
    }

    private func buildLayoutView(node: LayoutNode, primaryControlsAvailable: inout Bool, splitContext: PaneSplitContext? = nil) -> NSView {
        switch node {
        case .pane(let pane):
            let showsWorkspaceControls = primaryControlsAvailable
            primaryControlsAvailable = false
            let ptv = PaneTabsView(
                pane: pane,
                router: router,
                showsWorkspaceControls: showsWorkspaceControls,
                splitContext: splitContext,
                workspaceID: workspaceID
            )
            paneControllers.append(ptv)
            return ptv.view
        case .split(let splitNode):
            let split = RatioSplitView()
            split.isVertical = (splitNode.orientation == .horizontal)
            split.dividerStyle = .thin
            split.ratios = splitNode.ratios.map { CGFloat($0) }
            let splitID = splitNode.id
            split.onRatiosChanged = { [weak self] ratios in
                guard let self else { return }
                try? self.router?.paneResize(workspace: self.workspaceID, splitID: splitID, ratios: ratios.map(Double.init))
            }
            for (index, child) in splitNode.children.enumerated() {
                let childSplitContext = PaneSplitContext(splitID: splitNode.id, paneIndex: index, ratios: splitNode.ratios, orientation: splitNode.orientation)
                let childView = buildLayoutView(node: child, primaryControlsAvailable: &primaryControlsAvailable, splitContext: childSplitContext)
                childView.translatesAutoresizingMaskIntoConstraints = true
                childView.autoresizingMask = []
                split.addSubview(childView)
            }
            return split
        }
    }

    @objc private func backToSidebar() {
        onBack()
    }

    func windowWillClose(_ notification: Notification) {
        if !closingFromOwner {
            onClose()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closingFromOwner else { return true }
        onBack()
        return false
    }
}

/// Split view that lays out its panes by explicit ratios instead of
/// AppKit's content-hugging heuristics. A fresh split has ratios
/// [0.5, 0.5], so each new pane is exactly half the old pane's width
/// (vertical divider) or height (horizontal divider). Ratios are kept
/// on live resize too.
final class RatioSplitView: NSView {
    var ratios: [CGFloat] = []
    var onRatiosChanged: (([CGFloat]) -> Void)?
    var isVertical = true { didSet { needsLayout = true } }
    var dividerStyle: NSSplitView.DividerStyle = .thin
    var dividerThickness: CGFloat { DS.ResizeDivider.thickness }
    private let collapsedRatioThreshold: CGFloat = 0.08
    private var collapsedExtent: CGFloat { isVertical ? 44 : 35 }
    private let dividerHitSlop: CGFloat = 6
    private let minimumDragRatio: CGFloat = 0.08
    private var dragDividerIndex: Int?
    private var dragStartPoint: NSPoint?
    private var dragStartRatios: [CGFloat] = []
    private var dividerLayers: [CALayer] = []
    private var dividerGripLayers: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = DS.NS.bg.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = DS.NS.bg.cgColor
        layer?.masksToBounds = true
    }

    func relayoutNow() { layoutByRatios() }
    func adjustSubviews() { layoutByRatios() }

    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutByRatios() }
    override func layout() {
        super.layout()
        layoutByRatios()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutByRatios()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard subviews.count > 1 else { return }
        for index in 0..<(subviews.count - 1) {
            addCursorRect(dividerRect(afterSubviewAt: index), cursor: isVertical ? .resizeLeftRight : .resizeUpDown)
        }
        layoutDividerLayers()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = dividerIndex(at: point) else {
            super.mouseDown(with: event)
            return
        }
        dragDividerIndex = index
        dragStartPoint = point
        dragStartRatios = normalizedRatios(for: subviews.count)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = dragDividerIndex,
              let start = dragStartPoint else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let delta = isVertical ? point.x - start.x : start.y - point.y
        applyDividerDrag(dividerIndex: index, delta: delta)
    }

    override func mouseUp(with event: NSEvent) {
        if dragDividerIndex != nil {
            onRatiosChanged?(ratios)
        }
        dragDividerIndex = nil
        dragStartPoint = nil
        dragStartRatios = []
        super.mouseUp(with: event)
    }

    func applyDividerDrag(dividerIndex: Int, delta: CGFloat) {
        let n = subviews.count
        guard n > 1,
              dividerIndex >= 0,
              dividerIndex < n - 1 else { return }

        let base = dragStartRatios.count == n ? dragStartRatios : normalizedRatios(for: n)
        let extent = max(1, (isVertical ? bounds.width : bounds.height) - dividerThickness * CGFloat(n - 1))
        let ratioDelta = delta / extent
        var next = base
        let first = max(minimumDragRatio, min(1 - minimumDragRatio, base[dividerIndex] + ratioDelta))
        let pairTotal = base[dividerIndex] + base[dividerIndex + 1]
        let second = pairTotal - first
        guard second >= minimumDragRatio else {
            next[dividerIndex] = pairTotal - minimumDragRatio
            next[dividerIndex + 1] = minimumDragRatio
            ratios = SplitNode.normalize(next.map(Double.init)).map { CGFloat($0) }
            layoutByRatios()
            return
        }
        next[dividerIndex] = first
        next[dividerIndex + 1] = second
        ratios = SplitNode.normalize(next.map(Double.init)).map { CGFloat($0) }
        layoutByRatios()
    }

    private func dividerIndex(at point: NSPoint) -> Int? {
        guard subviews.count > 1 else { return nil }
        for index in 0..<(subviews.count - 1) where dividerRect(afterSubviewAt: index).contains(point) {
            return index
        }
        return nil
    }

    private func dividerRect(afterSubviewAt index: Int) -> NSRect {
        let frame = subviews[index].frame
        if isVertical {
            return NSRect(
                x: frame.maxX - dividerHitSlop,
                y: bounds.minY,
                width: dividerHitSlop * 2 + dividerThickness,
                height: bounds.height
            )
        }
        return NSRect(
            x: bounds.minX,
            y: frame.minY - dividerHitSlop - dividerThickness,
            width: bounds.width,
            height: dividerHitSlop * 2 + dividerThickness
        )
    }

    private func layoutByRatios() {
        let n = subviews.count
        guard n >= 1, bounds.width > 0, bounds.height > 0 else { return }
        let dt = dividerThickness
        let norm = normalizedRatios(for: n)

        let collapsed = Set(norm.indices.filter { norm[$0] <= collapsedRatioThreshold && n > 1 })

        if isVertical {
            let fixed = min(bounds.width, CGFloat(collapsed.count) * collapsedExtent)
            let avail = max(0, bounds.width - dt * CGFloat(n - 1) - fixed)
            let flexibleTotal = norm.indices
                .filter { !collapsed.contains($0) }
                .map { norm[$0] }
                .reduce(0, +)
            var x: CGFloat = 0
            for (i, sv) in subviews.enumerated() {
                let w: CGFloat
                if collapsed.contains(i) {
                    w = min(collapsedExtent, max(0, bounds.width - x))
                } else if i == n - 1 {
                    w = max(0, bounds.width - x)
                } else {
                    let share = flexibleTotal > 0 ? norm[i] / flexibleTotal : 1.0 / CGFloat(max(1, n - collapsed.count))
                    w = (avail * share).rounded()
                }
                sv.frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
                relayoutChild(sv)
                x += w + dt
            }
        } else {
            let fixed = min(bounds.height, CGFloat(collapsed.count) * collapsedExtent)
            let avail = max(0, bounds.height - dt * CGFloat(n - 1) - fixed)
            let flexibleTotal = norm.indices
                .filter { !collapsed.contains($0) }
                .map { norm[$0] }
                .reduce(0, +)
            var y: CGFloat = bounds.height
            for (i, sv) in subviews.enumerated() {
                let h: CGFloat
                if collapsed.contains(i) {
                    h = min(collapsedExtent, max(0, y))
                } else if i == n - 1 {
                    h = max(0, y)
                } else {
                    let share = flexibleTotal > 0 ? norm[i] / flexibleTotal : 1.0 / CGFloat(max(1, n - collapsed.count))
                    h = (avail * share).rounded()
                }
                y -= h
                sv.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
                relayoutChild(sv)
                y -= dt
            }
        }
        layoutDividerLayers()
    }

    private func relayoutChild(_ child: NSView) {
        child.needsLayout = true
        if let split = child as? RatioSplitView {
            split.layoutByRatios()
        } else {
            child.layoutSubtreeIfNeeded()
        }
    }

    private func normalizedRatios(for count: Int) -> [CGFloat] {
        if ratios.count == count {
            let total = ratios.reduce(0, +)
            if total > 0 { return ratios.map { $0 / total } }
        }
        return Array(repeating: 1.0 / CGFloat(max(count, 1)), count: count)
    }

    private func layoutDividerLayers() {
        let count = max(0, subviews.count - 1)
        ensureDividerLayers(count: count)
        guard count > 0 else { return }
        for index in 0..<count {
            let dividerFrame: CGRect
            if isVertical {
                dividerFrame = CGRect(x: subviews[index].frame.maxX,
                                      y: bounds.minY,
                                      width: dividerThickness,
                                      height: bounds.height)
            } else {
                dividerFrame = CGRect(x: bounds.minX,
                                      y: subviews[index].frame.minY - dividerThickness,
                                      width: bounds.width,
                                      height: dividerThickness)
            }
            let divider = dividerLayers[index]
            let grip = dividerGripLayers[index]
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            divider.frame = dividerFrame
            grip.frame = CGRect(
                x: (dividerFrame.width - (isVertical ? DS.ResizeDivider.gripThickness : DS.ResizeDivider.gripLength)) / 2,
                y: (dividerFrame.height - (isVertical ? DS.ResizeDivider.gripLength : DS.ResizeDivider.gripThickness)) / 2,
                width: isVertical ? DS.ResizeDivider.gripThickness : DS.ResizeDivider.gripLength,
                height: isVertical ? DS.ResizeDivider.gripLength : DS.ResizeDivider.gripThickness
            )
            CATransaction.commit()
        }
    }

    private func ensureDividerLayers(count: Int) {
        while dividerLayers.count < count {
            let divider = CALayer()
            divider.backgroundColor = DS.NS.line.cgColor
            divider.zPosition = 999
            let grip = CALayer()
            grip.backgroundColor = DS.NS.lineStrong.cgColor
            grip.cornerRadius = DS.ResizeDivider.gripThickness / 2
            grip.zPosition = 1_000
            divider.addSublayer(grip)
            layer?.addSublayer(divider)
            dividerLayers.append(divider)
            dividerGripLayers.append(grip)
        }
        while dividerLayers.count > count {
            dividerLayers.removeLast().removeFromSuperlayer()
            dividerGripLayers.removeLast()
        }
    }
}
