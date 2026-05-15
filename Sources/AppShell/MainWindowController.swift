import Foundation
import AppKit
import CoreModel
import Surfaces
import DesignSystemKit

@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate {
    public let window: NSWindow
    public weak var context: AppContext?
    public weak var router: AppCommandRouter?

    private let sidebar: SidebarView
    private let workspaceContainer = NSView()
    private let split = NSSplitView()
    private let toolbarLabel = NSTextField(labelWithString: "RemoteCode 2")
    /// Retains the live pane controllers; their @objc button and tab
    /// targets die with them, so they must outlive a layout rebuild.
    private var paneControllers: [PaneTabsView] = []

    public init(context: AppContext, router: AppCommandRouter) {
        self.context = context
        self.router = router
        self.sidebar = SidebarView(context: context, router: router)

        let style: NSWindow.StyleMask = [.titled, .resizable, .closable, .miniaturizable]
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        win.title = "RemoteCode 2"
        win.titlebarAppearsTransparent = false
        win.minSize = NSSize(width: 900, height: 600)
        self.window = win

        super.init()
        win.delegate = self
        setupLayout()
        refreshFromState()
        win.center()
    }

    private func setupLayout() {
        window.backgroundColor = DS.NS.bg
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = DS.NS.bg.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        workspaceContainer.translatesAutoresizingMaskIntoConstraints = false

        workspaceContainer.wantsLayer = true
        workspaceContainer.layer?.backgroundColor = DS.NS.bg.cgColor
        split.addArrangedSubview(sidebar.view)
        split.addArrangedSubview(workspaceContainer)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sidebar.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        window.contentView = content
        // give sidebar a default size
        DispatchQueue.main.async {
            self.split.setPosition(240, ofDividerAt: 0)
        }
    }

    public func show() {
        window.makeKeyAndOrderFront(nil)
    }

    public func refreshFromState() {
        sidebar.refresh()
        rebuildWorkspaceContainer()
    }

    public func focusSurface(_ id: SurfaceID) {
        if let s = SurfaceRegistry.shared.surface(id) {
            s.focus()
        }
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

    private func rebuildWorkspaceContainer() {
        for sub in workspaceContainer.subviews { sub.removeFromSuperview() }
        // Drop references to the previous pane controllers; new ones are
        // created below. Without retaining them their @objc button/tab
        // targets are deallocated and clicks silently no-op.
        paneControllers.removeAll()
        guard let ctx = context,
              let wid = ctx.state.window.selectedWorkspaceID,
              let ws = ctx.state.workspaces[wid] else {
            let empty = makeEmptyState()
            workspaceContainer.addSubview(empty)
            pin(empty, to: workspaceContainer)
            return
        }
        let layoutView = buildLayoutView(node: ws.layout)
        layoutView.translatesAutoresizingMaskIntoConstraints = false
        workspaceContainer.addSubview(layoutView)
        pin(layoutView, to: workspaceContainer)
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

    private func buildLayoutView(node: LayoutNode) -> NSView {
        switch node {
        case .pane(let p):
            let ptv = PaneTabsView(pane: p, router: router)
            paneControllers.append(ptv)
            return ptv.view
        case .split(let s):
            let split = NSSplitView()
            split.isVertical = (s.orientation == .horizontal)
            split.dividerStyle = .thin
            for child in s.children {
                let cv = buildLayoutView(node: child)
                cv.translatesAutoresizingMaskIntoConstraints = false
                split.addArrangedSubview(cv)
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
}
