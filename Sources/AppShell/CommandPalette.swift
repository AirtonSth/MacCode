import Foundation
import AppKit
import CoreModel
import Surfaces
import AgentRuntime
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
            cmds.append(PaletteCommand(id: "surface.new.git", title: "New Git / Diff Surface", subtitle: "In current workspace", keywords: ["git", "diff", "changes", "history"]) {
                _ = try? router.createSurface(workspace: wid, type: .rightSidebarTool, paneID: nil, title: "Git")
            })

            // Project scripts + open-in-editor (RC2-069, t3code parity).
            for s in (try? router.projectScripts(workspace: wid))?.prefix(12) ?? [] {
                cmds.append(PaletteCommand(id: "project.run.\(s.name)", title: "Run: \(s.name)", subtitle: "\(s.command) · \(s.source)", keywords: ["run", "script", "task", s.name]) {
                    _ = try? router.projectRunScript(workspace: wid, name: s.name)
                })
            }
            cmds.append(PaletteCommand(id: "project.open_in_editor", title: "Open Workspace in Editor", subtitle: "Cursor / VS Code / Zed / Xcode", keywords: ["open", "editor", "code", "cursor", "zed"]) {
                _ = try? router.projectOpenInEditor(workspace: wid)
            })

            // Agent App commands — reach the live VM of the agent surface
            // in the selected workspace (t3code palette parity).
            if let agent = SurfaceRegistry.shared.all()
                .compactMap({ $0 as? AgentAppSurface })
                .first(where: { $0.descriptor.metadata["workspace"] == wid.value.uuidString }) {
                let vm = agent.viewModel
                cmds.append(PaletteCommand(id: "agent.provider.codex", title: "Agent: Use Codex", subtitle: "Switch provider", keywords: ["provider", "codex"]) {
                    vm.provider = .codex; Task { await vm.loadModels() }
                })
                cmds.append(PaletteCommand(id: "agent.provider.claude", title: "Agent: Use Claude", subtitle: "Switch provider", keywords: ["provider", "claude"]) {
                    vm.provider = .claude; Task { await vm.loadModels() }
                })
                cmds.append(PaletteCommand(id: "agent.thread.new", title: "Agent: New Thread", subtitle: "Start a fresh thread", keywords: ["thread", "new", "chat"]) {
                    vm.createThread(title: "New thread")
                })
                cmds.append(PaletteCommand(id: "agent.plan.toggle", title: "Agent: Toggle Plan Sidebar", keywords: ["plan", "notes", "sidebar"]) {
                    vm.showPlanSidebar.toggle()
                })
                // E2: surface the provider's model catalog as quick-switches.
                for m in vm.availableModels.prefix(12) {
                    cmds.append(PaletteCommand(id: "agent.model.\(m.id)", title: "Agent: Model → \(m.label)", subtitle: m.provider.rawValue, keywords: ["model", "switch", m.id, m.label.lowercased()]) {
                        vm.model = m.id
                    })
                }
                for (i, t) in vm.threads.prefix(9).enumerated() {
                    let n = i + 1
                    cmds.append(PaletteCommand(id: "agent.thread.jump.\(n)", title: "Agent: Jump to \(t.title)", subtitle: "Thread \(n) · \(t.provider.rawValue)", keywords: ["thread", "jump", "\(n)"]) {
                        vm.selectThread(t.id)
                    })
                }
            }
        }
        // Jump to any workspace (sidebar navigation parity).
        if let ctx = router.context {
            for ws in ctx.state.window.workspaces.compactMap({ ctx.state.workspaces[$0] }) {
                cmds.append(PaletteCommand(id: "workspace.jump.\(ws.id.value.uuidString)", title: "Switch to: \(ws.name)", subtitle: "Workspace · \(ws.cwd)", keywords: ["workspace", "switch", "jump", ws.name.lowercased()]) {
                    try? router.selectWorkspace(ws.id)
                })
            }
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
        let lower = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty {
            filtered = all
        } else {
            filtered = CommandPaletteFilter.rank(all, query: lower) { ($0.title, $0.subtitle, $0.keywords) }
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

    /// Esc dismisses the palette (documented behaviour); ↑/↓ move the
    /// selection; ↩ runs it. Without this Esc did nothing — the panel
    /// could only be closed by re-toggling.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)):
            window.orderOut(nil); return true
        case #selector(NSResponder.insertNewline(_:)):
            submit(); return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let cur = tableView.selectedRow
        let next = min(max(0, cur + delta), filtered.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
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
