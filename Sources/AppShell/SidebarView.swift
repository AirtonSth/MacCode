import Foundation
import AppKit
import CoreModel

@MainActor
public final class SidebarView: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    public let view: NSView
    public weak var context: AppContext?
    public weak var router: AppCommandRouter?

    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private let addButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "Workspaces")

    public init(context: AppContext, router: AppCommandRouter) {
        self.context = context
        self.router = router
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container

        super.init()

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addButton.title = "+"
        addButton.bezelStyle = .recessed
        addButton.controlSize = .small
        addButton.target = self
        addButton.action = #selector(createWorkspaceClicked)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [titleLabel, NSView(), addButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .sourceList
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.dataSource = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = "Name"
        col.width = 200
        tableView.addTableColumn(col)
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }

    public func refresh() {
        tableView.reloadData()
        guard let ctx = context else { return }
        if let sel = ctx.state.window.selectedWorkspaceID,
           let idx = ctx.state.window.workspaces.firstIndex(of: sel) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    @objc private func createWorkspaceClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to use as the workspace cwd"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                _ = try router?.createWorkspace(name: url.lastPathComponent, cwd: url.path)
            } catch {
                NSSound.beep()
            }
        }
    }

    // MARK: NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        context?.state.window.workspaces.count ?? 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        if let ctx = context, row < ctx.state.window.workspaces.count {
            let wid = ctx.state.window.workspaces[row]
            if let ws = ctx.state.workspaces[wid] {
                cell.textField?.stringValue = ws.name
            }
        }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard let ctx = context, row >= 0, row < ctx.state.window.workspaces.count else { return }
        let wid = ctx.state.window.workspaces[row]
        try? router?.selectWorkspace(wid)
    }
}
