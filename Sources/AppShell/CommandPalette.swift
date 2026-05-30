import Foundation
import AppKit
import Combine
import CoreModel
import Surfaces
import AgentRuntime
import DesignSystemKit

public struct PaletteCommand {
    public let id: String
    public let title: String
    public let subtitle: String
    public let keywords: [String]
    /// Resolved key chord (e.g. "⌘T") shown right-aligned for discoverability.
    public let shortcut: String?
    /// Long-tail entries hidden from the default (empty-query) view but
    /// reachable by search — see UX-006 so typing a truncated item's name finds it.
    public let defaultHidden: Bool
    public let action: () -> Void

    public init(id: String, title: String, subtitle: String = "", keywords: [String] = [], shortcut: String? = nil, defaultHidden: Bool = false, action: @escaping () -> Void) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.keywords = keywords
        self.shortcut = shortcut; self.defaultHidden = defaultHidden; self.action = action
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
    private var currentQuery: String = ""
    public weak var router: AppCommandRouter?

    /// PERF-003: cache project-script discovery so cmd+k never blocks the
    /// open keystroke on a filesystem scan. Keyed by workspace cwd; refreshed
    /// off-main and re-fed into the palette when it resolves.
    private var scriptCache: [String: [ProjectScript]] = [:]

    /// UX-004: when the palette is open we observe the live agent VM so the
    /// model rows appear as soon as loadModels() resolves, without reopening.
    private weak var observedAgentVM: AgentAppViewModel?
    private var agentModelObserver: AnyCancellable?

    /// Empty-state / loading rows are non-selectable and must no-op on Enter.
    private var nonRunnableRowIDs: Set<String> = []

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
        // UX-009: double-clicking a row runs it (single click just selects).
        tableView.target = self
        tableView.doubleAction = #selector(submit)
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
        nonRunnableRowIDs.removeAll()
        observedAgentVM = nil
        agentModelObserver = nil
        var cmds: [PaletteCommand] = []
        cmds.append(PaletteCommand(id: "workspace.new", title: "New Workspace…", subtitle: "Choose a folder to use as cwd", keywords: ["workspace", "create", "open"], shortcut: "⌘N") { [weak self] in
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                _ = try? self?.router?.createWorkspace(name: url.lastPathComponent, cwd: url.path)
            }
        })
        if let wid = router.context?.state.window.selectedWorkspaceID {
            cmds.append(PaletteCommand(id: "surface.new.terminal", title: "New Terminal Surface", subtitle: "In current workspace", keywords: ["terminal", "shell"], shortcut: "⌘T") {
                _ = try? router.createSurface(workspace: wid, type: .terminal, paneID: nil, title: nil)
            })
            cmds.append(PaletteCommand(id: "surface.new.browser", title: "New Browser Surface", subtitle: "In current workspace", keywords: ["browser", "web"], shortcut: "⌘B") {
                _ = try? router.createSurface(workspace: wid, type: .browser, paneID: nil, title: nil)
            })
            cmds.append(PaletteCommand(id: "surface.new.agent", title: "New Agent App Surface", subtitle: "In current workspace", keywords: ["agent", "codex", "claude", "chat"], shortcut: "⌘G") {
                _ = try? router.createSurface(workspace: wid, type: .agentApp, paneID: nil, title: nil)
            })
            cmds.append(PaletteCommand(id: "surface.new.git", title: "New Git / Diff Surface", subtitle: "In current workspace", keywords: ["git", "diff", "changes", "history"]) {
                _ = try? router.createSurface(workspace: wid, type: .rightSidebarTool, paneID: nil, title: "Git")
            })

            // Project scripts + open-in-editor (RC2-069, t3code parity).
            // UX-006/PERF-003: every discovered script is added (long tail is
            // search-reachable); only the default view is capped via
            // `defaultHidden`. Discovery is served from cache, refreshed off-main.
            let scripts = cachedScripts(cwd: router.context?.state.workspaces[wid]?.cwd ?? "")
            for (i, s) in scripts.enumerated() {
                cmds.append(PaletteCommand(id: "project.run.\(s.name)", title: "Run: \(s.name)", subtitle: "\(s.command) · \(s.source)", keywords: ["run", "script", "task", s.name], defaultHidden: i >= 12) {
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
                // E2/UX-004: surface the provider's model catalog as quick-switches.
                // While the async load is in flight with no models yet, show a
                // disabled "Loading models…" row and observe the VM so the rows
                // appear the moment loadModels() resolves — no reopen required.
                if vm.availableModels.isEmpty && vm.modelListLoading {
                    cmds.append(PaletteCommand(id: "agent.model.loading", title: "Agent: Loading models…", subtitle: "Fetching the provider's model catalog") {})
                    nonRunnableRowIDs.insert("agent.model.loading")
                    observeAgentModels(vm)
                }
                // UX-006: add the full catalog; cap only the default view.
                for (i, m) in vm.availableModels.enumerated() {
                    cmds.append(PaletteCommand(id: "agent.model.\(m.id)", title: "Agent: Model → \(m.label)", subtitle: m.provider.rawValue, keywords: ["model", "switch", m.id, m.label.lowercased()], defaultHidden: i >= 12) {
                        vm.model = m.id
                    })
                }
                for (i, t) in vm.threads.enumerated() {
                    let n = i + 1
                    cmds.append(PaletteCommand(id: "agent.thread.jump.\(n)", title: "Agent: Jump to \(t.title)", subtitle: "Thread \(n) · \(t.provider.rawValue)", keywords: ["thread", "jump", "\(n)"], defaultHidden: i >= 9) {
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
        cmds.append(PaletteCommand(id: "app.quit", title: "Quit RemoteCode", keywords: ["exit", "quit"], shortcut: "⌘Q") { NSApp.terminate(nil) })
        self.all = cmds
        applyFilter(currentQuery)
    }

    /// PERF-003: serve project scripts from an in-memory cache so opening the
    /// palette never blocks on `ProjectScripts.discover` (a filesystem scan).
    /// On a cache miss the cmd+k path returns immediately with no scripts and
    /// schedules an off-main discovery that re-feeds the palette on completion.
    private func cachedScripts(cwd: String) -> [ProjectScript] {
        if let cached = scriptCache[cwd] { return cached }
        guard !cwd.isEmpty else { return [] }
        Task.detached(priority: .userInitiated) { [weak self] in
            let scripts = ProjectScripts.discover(in: cwd)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scriptCache[cwd] = scripts
                // Only refresh if the user is still looking at this palette.
                if self.window.isVisible { self.rebuildCommands() }
            }
        }
        return []
    }

    /// UX-004: refresh the open palette once the agent VM finishes loading
    /// models, so the disabled "Loading models…" row is replaced live.
    private func observeAgentModels(_ vm: AgentAppViewModel) {
        observedAgentVM = vm
        agentModelObserver = vm.$availableModels
            .receive(on: RunLoop.main)
            .sink { [weak self] models in
                guard let self, self.window.isVisible, !models.isEmpty else { return }
                self.rebuildCommands()
            }
    }

    public func toggle() {
        currentQuery = ""
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
        currentQuery = lower
        if lower.isEmpty {
            // UX-006: the default view hides the long tail; search sees it all.
            filtered = all.filter { !$0.defaultHidden }
        } else {
            filtered = CommandPaletteFilter.rank(all, query: lower) { ($0.title, $0.subtitle, $0.keywords) }
        }
        // UX-001: a no-match query shows an explicit, non-selectable row
        // instead of a blank panel.
        if filtered.isEmpty && !lower.isEmpty {
            let id = "palette.noresults"
            filtered = [PaletteCommand(id: id, title: "No commands matching “\(lower)”", subtitle: "Try a different term") {}]
            nonRunnableRowIDs.insert(id)
        }
        tableView.reloadData()
        selectFirstRunnableRow()
    }

    /// Empty-state and loading rows are non-runnable; keep selection on the
    /// first row the user can actually invoke.
    private func selectFirstRunnableRow() {
        guard let idx = filtered.firstIndex(where: { !nonRunnableRowIDs.contains($0.id) }) else {
            tableView.deselectAll(nil); return
        }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
    }

    @objc private func submit() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let cmd = filtered[row]
        guard !nonRunnableRowIDs.contains(cmd.id) else { return }
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
        var next = min(max(0, cur + delta), filtered.count - 1)
        // Skip non-runnable (empty-state / loading) rows in the step direction.
        let step = delta >= 0 ? 1 : -1
        while next > 0 && next < filtered.count - 1 && nonRunnableRowIDs.contains(filtered[next].id) {
            next += step
        }
        guard next >= 0, next < filtered.count, !nonRunnableRowIDs.contains(filtered[next].id) else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    /// Empty-state and "Loading models…" rows are not selectable, so a mouse
    /// click can never land Enter on them (UX-001/UX-004).
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < filtered.count else { return false }
        return !nonRunnableRowIDs.contains(filtered[row].id)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cmd = filtered[row]
        let dimmed = nonRunnableRowIDs.contains(cmd.id)
        let cell = NSTableCellView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: cmd.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = dimmed ? DS.NS.textTertiary : DS.NS.text
        let subtitle = NSTextField(labelWithString: cmd.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = DS.NS.textTertiary
        let labels = NSStackView(views: subtitle.stringValue.isEmpty ? [title] : [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        labels.translatesAutoresizingMaskIntoConstraints = false

        // UX-002: right-aligned chord hint for commands that have one. A
        // low-hugging spacer fills the gap so the chord pins to the trailing edge.
        var rowViews: [NSView] = [labels]
        if let shortcut = cmd.shortcut {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let chord = NSTextField(labelWithString: shortcut)
            chord.font = .systemFont(ofSize: 12, weight: .medium)
            chord.textColor = DS.NS.textTertiary
            chord.setContentHuggingPriority(.required, for: .horizontal)
            chord.setContentCompressionResistancePriority(.required, for: .horizontal)
            rowViews.append(spacer)
            rowViews.append(chord)
        }
        let hstack = NSStackView(views: rowViews)
        hstack.orientation = .horizontal
        hstack.alignment = .centerY
        hstack.spacing = 8
        hstack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(hstack)
        NSLayoutConstraint.activate([
            hstack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            hstack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            hstack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
