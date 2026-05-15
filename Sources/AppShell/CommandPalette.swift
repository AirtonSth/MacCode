import Foundation
import AppKit
import CoreModel
import Surfaces
import DesignSystemKit

public struct PaletteCommand {
    public let id: String
    public let title: String
    public let subtitle: String
    public let keywords: [String]
    public let action: () -> Void

    public init(id: String, title: String, subtitle: String = "", keywords: [String] = [], action: @escaping () -> Void) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.keywords = keywords; self.action = action
    }
}

@MainActor
public final class CommandPalette: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    public let window: NSPanel
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private var all: [PaletteCommand] = []
    private var filtered: [PaletteCommand] = []
    public weak var router: AppCommandRouter?

    public init(router: AppCommandRouter) {
        self.router = router
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 360),
            styleMask: [.titled, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Command Palette"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        self.window = panel
        super.init()
        panel.delegate = self

        searchField.placeholderString = "Type a command…"
        searchField.font = .systemFont(ofSize: 15)
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(submit)
        searchField.drawsBackground = true
        searchField.backgroundColor = DS.NS.surfaceRaised
        searchField.textColor = DS.NS.text
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none

        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        col.width = 500
        tableView.addTableColumn(col)
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = DS.NS.surface.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DS.NS.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)
        container.addSubview(divider)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6)
        ])
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = DS.NS.surface
    }

    public func rebuildCommands() {
        guard let router = router else { return }
        var cmds: [PaletteCommand] = []
        cmds.append(PaletteCommand(id: "workspace.new", title: "New Workspace…", subtitle: "Choose a folder to use as cwd", keywords: ["workspace", "create", "open"]) { [weak self] in
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                _ = try? self?.router?.createWorkspace(name: url.lastPathComponent, cwd: url.path)
            }
        })
        if let wid = router.context?.state.window.selectedWorkspaceID {
            cmds.append(PaletteCommand(id: "surface.new.terminal", title: "New Terminal Surface", subtitle: "In current workspace", keywords: ["terminal", "shell"]) {
                _ = try? router.createSurface(workspace: wid, type: .terminal, paneID: nil, title: nil)
            })
            cmds.append(PaletteCommand(id: "surface.new.browser", title: "New Browser Surface", subtitle: "In current workspace", keywords: ["browser", "web"]) {
                _ = try? router.createSurface(workspace: wid, type: .browser, paneID: nil, title: nil)
            })
            cmds.append(PaletteCommand(id: "surface.new.agent", title: "New Agent App Surface", subtitle: "In current workspace", keywords: ["agent", "codex", "claude", "chat"]) {
                _ = try? router.createSurface(workspace: wid, type: .agentApp, paneID: nil, title: nil)
            })
        }
        cmds.append(PaletteCommand(id: "session.save", title: "Save Session Snapshot", keywords: ["snapshot", "session"]) { router.context?.saveSnapshot() })
        cmds.append(PaletteCommand(id: "app.quit", title: "Quit RemoteCode 2", keywords: ["exit", "quit"]) { NSApp.terminate(nil) })
        self.all = cmds
        applyFilter("")
    }

    public func toggle() {
        rebuildCommands()
        if window.isVisible {
            window.orderOut(nil)
        } else {
            searchField.stringValue = ""
            applyFilter("")
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(searchField)
        }
    }

    private func applyFilter(_ q: String) {
        let lower = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty {
            filtered = all
        } else {
            filtered = all.filter { c in
                if c.title.lowercased().contains(lower) { return true }
                if c.subtitle.lowercased().contains(lower) { return true }
                return c.keywords.contains { $0.contains(lower) }
            }
        }
        tableView.reloadData()
        if !filtered.isEmpty { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    @objc private func submit() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let cmd = filtered[row]
        window.orderOut(nil)
        cmd.action()
    }

    // MARK: NSTextFieldDelegate

    public func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    // MARK: NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: filtered[row].title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = DS.NS.text
        let subtitle = NSTextField(labelWithString: filtered[row].subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = DS.NS.textTertiary
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
