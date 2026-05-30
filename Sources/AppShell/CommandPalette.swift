import Foundation
import AppKit
import Combine
import CoreModel
import Surfaces
import AgentRuntime
import DesignSystemKit

/// UX-003: lightweight grouping used for section headers in the default view.
/// `rawValue` is the visible header label; `order` fixes section sequence.
public enum PaletteCategory: String, CaseIterable {
    case workspace = "Workspace"
    case surfaces  = "Surfaces"
    case project   = "Project"
    case agent     = "Agent"
    case navigation = "Navigation"
    case app       = "App"
}

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
    /// UX-003: section this command belongs to (drives default-view headers).
    public let category: PaletteCategory
    /// UX-010: leading SF Symbol for visual differentiation by command type.
    public let iconName: String?
    /// UX-011: destructive commands (Quit) render with a red tint and are
    /// de-prioritized in ranking so a single "q" never lands at row 0.
    public let destructive: Bool
    public let action: () -> Void

    public init(id: String, title: String, subtitle: String = "", keywords: [String] = [], shortcut: String? = nil, defaultHidden: Bool = false, category: PaletteCategory = .app, iconName: String? = nil, destructive: Bool = false, action: @escaping () -> Void) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.keywords = keywords
        self.shortcut = shortcut; self.defaultHidden = defaultHidden
        self.category = category; self.iconName = iconName; self.destructive = destructive
        self.action = action
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
    /// Section headers (UX-003) and overflow rows (UX-005) are also non-runnable.
    private var nonRunnableRowIDs: Set<String> = []

    /// UX-007: most-recently-used command IDs (newest first, capped). Used to
    /// float the last few used commands to the top of the empty-query view.
    private var recentCommandIDs: [String] = []
    private let recentLimit = 3

    /// QA-002: inspection seam — the ordered IDs currently visible (after
    /// filtering / sectioning) so unit tests can assert caps, ordering, and
    /// conditional inclusion without driving the NSPanel.
    var commandIDsForTesting: [String] { filtered.map(\.id) }

    /// QA-002: the full constructed catalog (pre-filter) for the same purpose.
    var allCommandIDsForTesting: [String] { all.map(\.id) }

    /// QA-009: records the last action attempted + whether it ran, so
    /// integration tests can assert success/failure rather than only side
    /// effects. Nil until the first `submit()`.
    private(set) var lastExecutedCommandID: String?

    public init(router: AppCommandRouter) {
        self.router = router
        let panel = NSPanel(
            // UX-013: drop `.titled` so the HUD palette floats without a chrome
            // title bar (Spotlight/Raycast look); Esc still dismisses.
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 360),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        // QA-001: stable identifier for XCUITest addressing.
        panel.identifier = NSUserInterfaceItemIdentifier("commandPalette.window")
        panel.setAccessibilityIdentifier("commandPalette.window")
        self.window = panel
        super.init()
        panel.delegate = self

        // UX-012: hint that scripts/threads/workspaces are searchable too.
        searchField.placeholderString = "Search commands, scripts, threads, workspaces…"
        searchField.font = .systemFont(ofSize: 15)
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(submit)
        searchField.drawsBackground = true
        searchField.backgroundColor = DS.NS.surfaceRaised
        searchField.textColor = DS.NS.text
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none
        // QA-001: stable identifier so UI automation can type into the field.
        searchField.setAccessibilityIdentifier("commandPalette.searchField")

        tableView.setAccessibilityIdentifier("commandPalette.table")
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
        cmds.append(PaletteCommand(id: "workspace.new", title: "New Workspace…", subtitle: "Choose a folder to use as cwd", keywords: ["workspace", "create", "open"], shortcut: "⌘N", category: .workspace, iconName: "folder.badge.plus") { [weak self] in
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                _ = try? self?.router?.createWorkspace(name: url.lastPathComponent, cwd: url.path)
            }
        })
        if let wid = router.context?.state.window.selectedWorkspaceID {
            cmds.append(PaletteCommand(id: "surface.new.terminal", title: "New Terminal Surface", subtitle: "In current workspace", keywords: ["terminal", "shell"], shortcut: "⌘T", category: .surfaces, iconName: "terminal") {
                _ = try? router.createSurface(workspace: wid, type: .terminal, paneID: nil, title: nil)
            })
            cmds.append(PaletteCommand(id: "surface.new.browser", title: "New Browser Surface", subtitle: "In current workspace", keywords: ["browser", "web"], shortcut: "⌘B", category: .surfaces, iconName: "globe") {
                _ = try? router.createSurface(workspace: wid, type: .browser, paneID: nil, title: nil)
            })
            cmds.append(PaletteCommand(id: "surface.new.agent", title: "New Agent App Surface", subtitle: "In current workspace", keywords: ["agent", "codex", "claude", "chat"], shortcut: "⌘G", category: .surfaces, iconName: "sparkles") {
                _ = try? router.createSurface(workspace: wid, type: .agentApp, paneID: nil, title: nil)
            })
            cmds.append(PaletteCommand(id: "surface.new.git", title: "New Git / Diff Surface", subtitle: "In current workspace", keywords: ["git", "diff", "changes", "history"], category: .surfaces, iconName: "arrow.triangle.branch") {
                _ = try? router.createSurface(workspace: wid, type: .rightSidebarTool, paneID: nil, title: "Git")
            })

            // Project scripts + open-in-editor (RC2-069, t3code parity).
            // UX-006/PERF-003: every discovered script is added (long tail is
            // search-reachable); only the default view is capped via
            // `defaultHidden`. Discovery is served from cache, refreshed off-main.
            let scriptCap = 12
            let scripts = cachedScripts(cwd: router.context?.state.workspaces[wid]?.cwd ?? "")
            for (i, s) in scripts.enumerated() {
                cmds.append(PaletteCommand(id: "project.run.\(s.name)", title: "Run: \(s.name)", subtitle: "\(s.command) · \(s.source)", keywords: ["run", "script", "task", s.name], defaultHidden: i >= scriptCap, category: .project, iconName: "play.circle") {
                    _ = try? router.projectRunScript(workspace: wid, name: s.name)
                })
            }
            // UX-005: when the default view hides scripts, show an overflow row
            // that reveals the rest (typing reaches them anyway via UX-006).
            appendOverflowRow(&cmds, hiddenCount: scripts.count - scriptCap, id: "project.run.more", noun: "scripts", category: .project)
            cmds.append(PaletteCommand(id: "project.open_in_editor", title: "Open Workspace in Editor", subtitle: "Cursor / VS Code / Zed / Xcode", keywords: ["open", "editor", "code", "cursor", "zed"], category: .project, iconName: "chevron.left.forwardslash.chevron.right") {
                _ = try? router.projectOpenInEditor(workspace: wid)
            })

            // Agent App commands — reach the live VM of the agent surface
            // in the selected workspace (t3code palette parity).
            if let agent = SurfaceRegistry.shared.all()
                .compactMap({ $0 as? AgentAppSurface })
                .first(where: { $0.descriptor.metadata["workspace"] == wid.value.uuidString }) {
                let vm = agent.viewModel
                // UX-IMP-010: mark the row matching the live selection so the
                // user sees what provider/model/thread is already active.
                let currentProvider = vm.provider
                let currentModel = vm.model
                let currentThread = vm.selectedThreadId
                cmds.append(PaletteCommand(id: "agent.provider.codex", title: "Agent: Use Codex", subtitle: Self.currentSubtitle("Switch provider", isCurrent: currentProvider == .codex), keywords: ["provider", "codex"], category: .agent, iconName: "cpu") {
                    vm.provider = .codex; Task { await vm.loadModels() }
                })
                cmds.append(PaletteCommand(id: "agent.provider.claude", title: "Agent: Use Claude", subtitle: Self.currentSubtitle("Switch provider", isCurrent: currentProvider == .claude), keywords: ["provider", "claude"], category: .agent, iconName: "cpu") {
                    vm.provider = .claude; Task { await vm.loadModels() }
                })
                cmds.append(PaletteCommand(id: "agent.thread.new", title: "Agent: New Thread", subtitle: "Start a fresh thread", keywords: ["thread", "new", "chat"], category: .agent, iconName: "plus.bubble") {
                    vm.createThread(title: "New thread")
                })
                cmds.append(PaletteCommand(id: "agent.plan.toggle", title: "Agent: Toggle Plan Sidebar", keywords: ["plan", "notes", "sidebar"], category: .agent, iconName: "sidebar.right") {
                    vm.showPlanSidebar.toggle()
                })
                // E2/UX-004: surface the provider's model catalog as quick-switches.
                // While the async load is in flight with no models yet, show a
                // disabled "Loading models…" row and observe the VM so the rows
                // appear the moment loadModels() resolves — no reopen required.
                if vm.availableModels.isEmpty && vm.modelListLoading {
                    cmds.append(PaletteCommand(id: "agent.model.loading", title: "Agent: Loading models…", subtitle: "Fetching the provider's model catalog", category: .agent, iconName: "hourglass") {})
                    nonRunnableRowIDs.insert("agent.model.loading")
                    observeAgentModels(vm)
                }
                // UX-006: add the full catalog; cap only the default view.
                let modelCap = 12
                for (i, m) in vm.availableModels.enumerated() {
                    cmds.append(PaletteCommand(id: "agent.model.\(m.id)", title: "Agent: Model → \(m.label)", subtitle: Self.currentSubtitle(m.provider.rawValue, isCurrent: m.id == currentModel), keywords: ["model", "switch", m.id, m.label.lowercased()], defaultHidden: i >= modelCap, category: .agent, iconName: "cube") {
                        vm.model = m.id
                    })
                }
                appendOverflowRow(&cmds, hiddenCount: vm.availableModels.count - modelCap, id: "agent.model.more", noun: "models", category: .agent)
                let threadCap = 9
                for (i, t) in vm.threads.enumerated() {
                    let n = i + 1
                    cmds.append(PaletteCommand(id: "agent.thread.jump.\(n)", title: "Agent: Jump to \(t.title)", subtitle: Self.currentSubtitle("Thread \(n) · \(t.provider.rawValue)", isCurrent: t.id == currentThread), keywords: ["thread", "jump", "\(n)"], defaultHidden: i >= threadCap, category: .agent, iconName: "bubble.left.and.bubble.right") {
                        vm.selectThread(t.id)
                    })
                }
                appendOverflowRow(&cmds, hiddenCount: vm.threads.count - threadCap, id: "agent.thread.more", noun: "threads", category: .agent)
            }
        }
        // Jump to any workspace (sidebar navigation parity).
        if let ctx = router.context {
            for ws in ctx.state.window.workspaces.compactMap({ ctx.state.workspaces[$0] }) {
                cmds.append(PaletteCommand(id: "workspace.jump.\(ws.id.value.uuidString)", title: "Switch to: \(ws.name)", subtitle: "Workspace · \(ws.cwd)", keywords: ["workspace", "switch", "jump", ws.name.lowercased()], category: .navigation, iconName: "arrow.right.circle") {
                    try? router.selectWorkspace(ws.id)
                })
            }
        }
        cmds.append(PaletteCommand(id: "session.save", title: "Save Session Snapshot", keywords: ["snapshot", "session"], category: .app, iconName: "camera") { router.context?.saveSnapshot() })
        // UX-011: Quit is destructive — red tint + de-prioritized in ranking.
        cmds.append(PaletteCommand(id: "app.quit", title: "Quit RemoteCode", keywords: ["exit", "quit"], shortcut: "⌘Q", category: .app, iconName: "power", destructive: true) { NSApp.terminate(nil) })
        self.all = cmds
        applyFilter(currentQuery)
    }

    /// UX-IMP-010: prefix an active row's subtitle with a check badge so the
    /// user sees the currently-selected provider/model/thread at a glance.
    private static func currentSubtitle(_ base: String, isCurrent: Bool) -> String {
        guard isCurrent else { return base }
        return base.isEmpty ? "✓ Current" : "✓ Current · \(base)"
    }

    /// UX-005: append a non-runnable "Show all N more <noun>…" row when the
    /// default view truncated a list, so the user knows the rest exist (and
    /// can reach them by typing — UX-006). No-op when nothing is hidden.
    private func appendOverflowRow(_ cmds: inout [PaletteCommand], hiddenCount: Int, id: String, noun: String, category: PaletteCategory) {
        guard hiddenCount > 0 else { return }
        cmds.append(PaletteCommand(id: id, title: "Show all \(hiddenCount) more \(noun)…", subtitle: "Type to search the full list", category: category, iconName: "ellipsis.circle") {})
        nonRunnableRowIDs.insert(id)
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
        if window.isVisible {
            hide()
        } else {
            currentQuery = ""
            rebuildCommands()
            searchField.stringValue = ""
            applyFilter("")
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(searchField)
        }
    }

    /// PERF-009: hide the panel and release the per-open command arrays so the
    /// ~40 closures capturing `router`/agent VMs don't stay resident while the
    /// palette is dismissed (they're rebuilt on the next open anyway).
    private func hide() {
        window.orderOut(nil)
        all.removeAll(keepingCapacity: true)
        filtered.removeAll(keepingCapacity: true)
        nonRunnableRowIDs.removeAll(keepingCapacity: true)
        observedAgentVM = nil
        agentModelObserver = nil
        tableView.reloadData()
    }

    private func applyFilter(_ q: String) {
        let lower = q.trimmingCharacters(in: .whitespacesAndNewlines)
        currentQuery = lower
        if lower.isEmpty {
            // UX-006: the default view hides the long tail; search sees it all.
            let visible = all.filter { !$0.defaultHidden }
            // UX-007: float the last few used commands to the top, then group
            // the rest into UX-003 sections with non-selectable headers.
            filtered = floatRecent(visible) + sectioned(visible, excludingRecent: true)
        } else {
            // UX-003: search results stay flat (no headers) for a tight list.
            // Overflow / loading rows (non-runnable) are excluded from ranking.
            // UX-011: de-prioritize destructive commands so a single "q" never
            // lands Quit at row 0 under the keyboard.
            let runnable = all.filter { !nonRunnableRowIDs.contains($0.id) }
            let ranked = CommandPaletteFilter.rank(runnable, query: lower) { ($0.title, $0.subtitle, $0.keywords) }
            filtered = ranked.filter { !$0.destructive } + ranked.filter { $0.destructive }
        }
        // UX-001: a no-match query shows an explicit, non-selectable row
        // instead of a blank panel.
        if filtered.allSatisfy({ nonRunnableRowIDs.contains($0.id) }) && !lower.isEmpty {
            let id = "palette.noresults"
            filtered = [PaletteCommand(id: id, title: "No commands matching “\(lower)”", subtitle: "Try a different term") {}]
            nonRunnableRowIDs.insert(id)
        }
        tableView.reloadData()
        resizeToFit()
        selectFirstRunnableRow()
    }

    /// UX-007: the recent commands (still present in `visible`), in MRU order,
    /// each tagged so it renders under a "Recent" affordance via subtitle.
    private func floatRecent(_ visible: [PaletteCommand]) -> [PaletteCommand] {
        guard !recentCommandIDs.isEmpty else { return [] }
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [PaletteCommand] = []
        let headerID = "palette.section.recent"
        for id in recentCommandIDs {
            guard let cmd = byID[id], !cmd.destructive else { continue }
            if out.isEmpty {
                out.append(headerRow(id: headerID, title: "Recent"))
            }
            out.append(cmd)
        }
        return out
    }

    /// UX-003: group `visible` commands into category sections with
    /// non-selectable header rows skipped by arrow nav. Recent commands are
    /// optionally excluded so they aren't shown twice.
    private func sectioned(_ visible: [PaletteCommand], excludingRecent: Bool) -> [PaletteCommand] {
        let recent = excludingRecent ? Set(recentCommandIDs) : []
        var out: [PaletteCommand] = []
        for category in PaletteCategory.allCases {
            let rows = visible.filter { $0.category == category && !recent.contains($0.id) }
            guard !rows.isEmpty else { continue }
            out.append(headerRow(id: "palette.section.\(category.rawValue.lowercased())", title: category.rawValue))
            out.append(contentsOf: rows)
        }
        return out
    }

    /// A non-selectable section header (UX-003); registered as non-runnable so
    /// Enter/arrow nav skip it.
    private func headerRow(id: String, title: String) -> PaletteCommand {
        nonRunnableRowIDs.insert(id)
        return PaletteCommand(id: id, title: title.uppercased(), action: {})
    }

    /// UX-014: size the panel height to fit up to 8 visible rows so a 2-result
    /// list isn't mostly empty and a 40-result list scrolls within bounds.
    private func resizeToFit() {
        let rowH: CGFloat = 30
        let chrome: CGFloat = 70   // search field + divider + paddings
        let rows = max(1, min(8, filtered.count))
        let target = chrome + CGFloat(rows) * rowH
        var frame = window.frame
        let delta = target - frame.height
        frame.origin.y += delta   // keep the top edge fixed while growing down
        frame.size.height = target
        window.setFrame(frame, display: true)
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
        // QA-008: log which command ran and whether it came from search vs the
        // default view, for flake diagnosis and MRU analytics.
        NSLog("CommandPalette: run id=%@ source=%@", cmd.id, currentQuery.isEmpty ? "default" : "search")
        // QA-009: record the executed command so integration tests can assert
        // it ran (side effects alone are hard to observe deterministically).
        lastExecutedCommandID = cmd.id
        // UX-007: bias future ordering toward recently-used commands.
        recordRecent(cmd.id)
        let action = cmd.action
        hide()
        action()
    }

    /// UX-007: push `id` to the front of the MRU list, dedup, cap at `recentLimit`.
    /// Dynamic per-instance IDs (workspace/model/thread jumps) are skipped so the
    /// "Recent" section stays stable across catalog rebuilds.
    private func recordRecent(_ id: String) {
        guard !id.contains(".jump.") else { return }
        recentCommandIDs.removeAll { $0 == id }
        recentCommandIDs.insert(id, at: 0)
        if recentCommandIDs.count > recentLimit {
            recentCommandIDs.removeLast(recentCommandIDs.count - recentLimit)
        }
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
            hide(); return true
        case #selector(NSResponder.insertNewline(_:)):
            submit(); return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        // UX-008: Page Up/Down jump a page of rows.
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            moveSelection(8); return true
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            moveSelection(-8); return true
        // UX-008: Home/End jump to the first/last runnable row.
        case #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            selectEdge(toEnd: false); return true
        case #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)):
            selectEdge(toEnd: true); return true
        default:
            return false
        }
    }

    /// UX-008: move selection by `delta`, wrapping at the ends and skipping
    /// non-runnable (header / empty-state / loading / overflow) rows.
    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let count = filtered.count
        let cur = tableView.selectedRow
        let start = cur >= 0 ? cur : (delta >= 0 ? -1 : 0)
        let step = delta >= 0 ? 1 : -1
        // First hop by the full delta (clamped), then walk to the nearest
        // runnable row in the step direction, wrapping around the list.
        var next = ((start + delta) % count + count) % count
        var guardCount = 0
        while nonRunnableRowIDs.contains(filtered[next].id) && guardCount < count {
            next = ((next + step) % count + count) % count
            guardCount += 1
        }
        guard !nonRunnableRowIDs.contains(filtered[next].id) else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    /// UX-008: select the first (or last) runnable row for Home/End.
    private func selectEdge(toEnd: Bool) {
        let indices = toEnd ? Array(filtered.indices.reversed()) : Array(filtered.indices)
        guard let idx = indices.first(where: { !nonRunnableRowIDs.contains(filtered[$0].id) }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        tableView.scrollRowToVisible(idx)
    }

    // MARK: NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    /// Empty-state and "Loading models…" rows are not selectable, so a mouse
    /// click can never land Enter on them (UX-001/UX-004).
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < filtered.count else { return false }
        return !nonRunnableRowIDs.contains(filtered[row].id)
    }

    /// UX-003: section headers are rendered as non-selectable caption rows.
    private func isHeader(_ id: String) -> Bool { id.hasPrefix("palette.section.") }

    private static let rowReuseID = NSUserInterfaceItemIdentifier("commandPalette.cell")

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cmd = filtered[row]
        let dimmed = nonRunnableRowIDs.contains(cmd.id)
        // PERF-001/002: recycle the cell view tree instead of allocating a
        // fresh NSTableCellView + labels + stack + constraints on every reload
        // and scroll tick; only the strings/colors are updated on reuse.
        let cell = (tableView.makeView(withIdentifier: Self.rowReuseID, owner: self) as? PaletteRowCellView)
            ?? PaletteRowCellView(identifier: Self.rowReuseID)
        cell.configure(with: cmd, dimmed: dimmed, isHeader: isHeader(cmd.id))
        // QA-001: per-row stable identifier for XCUITest (commandPalette.row.<id>).
        cell.setAccessibilityIdentifier("commandPalette.row.\(cmd.id)")
        return cell
    }
}

/// Reusable palette row: icon + (title / subtitle) + trailing chord. Built
/// once, mutated on reuse (PERF-002). Section headers reuse the same tree with
/// the icon/subtitle/chord hidden and a caption-styled title (UX-003).
private final class PaletteRowCellView: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let chord = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        translatesAutoresizingMaskIntoConstraints = false

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = DS.NS.textTertiary
        chord.font = .systemFont(ofSize: 12, weight: .medium)
        chord.textColor = DS.NS.textTertiary
        chord.setContentHuggingPriority(.required, for: .horizontal)
        chord.setContentCompressionResistancePriority(.required, for: .horizontal)

        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let hstack = NSStackView(views: [icon, labels, spacer, chord])
        hstack.orientation = .horizontal
        hstack.alignment = .centerY
        hstack.spacing = 8
        hstack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hstack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            hstack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hstack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hstack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(with cmd: PaletteCommand, dimmed: Bool, isHeader: Bool) {
        if isHeader {
            // UX-003: caption-styled, no icon/subtitle/chord.
            icon.isHidden = true
            titleLabel.stringValue = cmd.title
            titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
            titleLabel.textColor = DS.NS.textTertiary
            subtitleLabel.isHidden = true
            chord.stringValue = ""
            chord.isHidden = true
            return
        }
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        // UX-010: leading SF Symbol per command type. UX-011: destructive
        // commands (Quit) render title + icon in the danger tint.
        if let iconName = cmd.iconName, let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            icon.image = image
            icon.contentTintColor = cmd.destructive ? DS.NS.danger : (dimmed ? DS.NS.textTertiary : DS.NS.textSecondary)
            icon.isHidden = false
        } else {
            icon.image = nil
            icon.isHidden = true
        }
        titleLabel.stringValue = cmd.title
        titleLabel.textColor = cmd.destructive ? DS.NS.danger : (dimmed ? DS.NS.textTertiary : DS.NS.text)
        subtitleLabel.stringValue = cmd.subtitle
        subtitleLabel.isHidden = cmd.subtitle.isEmpty
        chord.stringValue = cmd.shortcut ?? ""
        chord.isHidden = cmd.shortcut == nil
    }
}
