import XCTest

@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Surfaces

@MainActor
final class TerminalOSCTitleWiringContractTests: XCTestCase {
  private var temporaryDirectories: [String] = []

  override func tearDown() {
    closeAndUnregisterAllSurfaces()
    for directory in temporaryDirectories {
      try? FileManager.default.removeItem(atPath: directory)
    }
    temporaryDirectories.removeAll()
    super.tearDown()
  }

  func testNewTerminalWiresOSCTitleToLayoutPersistenceEventAndRestart() throws {
    // WHY: Ghostty receives OSC title actions, but a newly-created terminal
    // is not mirrored unless its owning router persists and publishes them.
    let (context, router, directory) = try makeHarness()
    let workspace = try router.createWorkspace(name: "OSC new", cwd: NSTemporaryDirectory())
    let descriptor = try router.createSurface(
      workspace: workspace.id,
      type: .terminal,
      paneID: nil,
      title: "Before OSC"
    )
    let terminal = try XCTUnwrap(
      SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
    )

    XCTAssertNotNil(
      terminal.onRestartRequested,
      "new local terminals must retain the restart action when title wiring is configured"
    )
    let events = captureSurfaceRenamedEvents {
      terminal.onTitleChange?("build: passing")
    }

    try assertTitleChange(
      events,
      context: context,
      workspaceID: workspace.id,
      surfaceID: descriptor.id,
      title: "build: passing"
    )

    context.saveSnapshot()
    closeAndUnregisterAllSurfaces()
    let reloaded = try AppContext(channel: .debug, appSupportOverride: directory)
    XCTAssertEqual(
      surfaceTitle(in: reloaded, workspaceID: workspace.id, surfaceID: descriptor.id),
      "build: passing",
      "an OSC title must survive a fresh AppContext instead of existing only in the live tab view"
    )
  }

  func testRestoredTerminalWiresOSCTitleToLayoutPersistenceEventAndRestart() throws {
    // WHY: restore currently constructs TerminalSurface directly. Any callback
    // wired only in the new-surface path disappears after app relaunch.
    let (firstContext, firstRouter, directory) = try makeHarness()
    let workspace = try firstRouter.createWorkspace(
      name: "OSC restored", cwd: NSTemporaryDirectory())
    let descriptor = try firstRouter.createSurface(
      workspace: workspace.id,
      type: .terminal,
      paneID: nil,
      title: "Before restore"
    )
    firstContext.saveSnapshot()
    closeAndUnregisterAllSurfaces()

    let restoredContext = try AppContext(channel: .debug, appSupportOverride: directory)
    let restoredRouter = AppCommandRouter(context: restoredContext)
    restoredContext.router = restoredRouter
    restoredRouter.reinstantiateRestoredSurfaces()
    let terminal = try XCTUnwrap(
      SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
    )

    XCTAssertNotNil(
      terminal.onRestartRequested,
      "restored local terminals must retain the same restart action as newly-created terminals"
    )
    let events = captureSurfaceRenamedEvents {
      terminal.onTitleChange?("restored: active")
    }

    try assertTitleChange(
      events,
      context: restoredContext,
      workspaceID: workspace.id,
      surfaceID: descriptor.id,
      title: "restored: active"
    )

    restoredContext.saveSnapshot()
    closeAndUnregisterAllSurfaces()
    let reloaded = try AppContext(channel: .debug, appSupportOverride: directory)
    XCTAssertEqual(
      surfaceTitle(in: reloaded, workspaceID: workspace.id, surfaceID: descriptor.id),
      "restored: active",
      "a restored terminal's next OSC title must remain durable across another relaunch"
    )
  }

  func testSpinnerOnlyOSCTitleFramesPublishOneStableRenameAndKeepBusyTitleLocal() throws {
    // WHY (C19): Claude/Distill TUIs animate a braille spinner as the first
    // title glyph ~3-4x/s. Forwarding every frame persisted and broadcast a
    // critical surface.renamed per frame, evicting the 128-event replay ring
    // and forcing iOS full baselines on reconnect. Only a real title change may
    // leave the Mac, but the raw spinner title must stay on the live surface
    // because busy detection reads it.
    let (context, router, _) = try makeHarness()
    let workspace = try router.createWorkspace(name: "OSC spinner", cwd: NSTemporaryDirectory())
    let descriptor = try router.createSurface(
      workspace: workspace.id,
      type: .terminal,
      paneID: nil,
      title: "Before OSC"
    )
    let terminal = try XCTUnwrap(
      SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface
    )
    let glyphs = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"]
    let frames = (0..<16).map { "\(glyphs[$0 % glyphs.count]) - Run tests - Distill" }

    let events = captureSurfaceRenamedEvents {
      for frame in frames { terminal.handleOSCTitle(frame) }
    }

    try assertTitleChange(
      events,
      context: context,
      workspaceID: workspace.id,
      surfaceID: descriptor.id,
      title: "Run tests - Distill"
    )
    XCTAssertEqual(
      terminal.descriptor.title,
      frames.last,
      "the live surface keeps the raw spinner title so isBusy still sees the spinner"
    )
    XCTAssertTrue(TerminalSurface.hasSpinnerTitle(terminal.descriptor.title))

    router.terminalTitleCoalescer.interval = 0.2
    let changed = captureSurfaceRenamedEvents {
      terminal.handleOSCTitle("⠋ - Fix build - Distill")
      pumpMainRunLoop(for: 0.4)
    }
    XCTAssertEqual(
      changed.first?.payload.objectValue?["title"]?.stringValue,
      "Fix build - Distill",
      "a real title change behind the spinner must still reach iOS"
    )
    XCTAssertEqual(changed.count, 1)
  }

  func testSixtyMixedSpinnerFramesScheduleNoSnapshotSaveAndPublishNoEvent() throws {
    // WHY (H3): Claude/Codex TUIs park ✳ when idle and animate braille or
    // ◐◓◑◒ while working, ~1 frame/s per busy terminal. Every frame used to
    // run a layout apply, a session_snapshots write, a full window refresh
    // and a persisted surface.renamed for iOS. Only the normalized title
    // ("Claude Code") is user state, so the spinner must cost nothing.
    let (context, router, _) = try makeHarness()
    router.terminalTitleCoalescer.interval = 0.2
    let (workspace, terminal) = try makeTerminal(router, name: "H3 spinner")
    terminal.handleOSCTitle("✳ Claude Code")
    XCTAssertEqual(
      surfaceTitle(in: context, workspaceID: workspace, surfaceID: terminal.descriptor.id),
      "Claude Code",
      "the first title commits on the same turn with the idle ✳ stripped"
    )
    pumpMainRunLoop(for: 0.3)

    let glyphs = ["◐", "◓", "◑", "◒", "⠂", "⠐", "✳", "✳️", "✶", "✻"]
    let frames = (0..<60).map { "\(glyphs[$0 % glyphs.count]) Claude Code" }
    let savesBefore = context.snapshotSaveScheduleCountForTesting
    let events = captureSurfaceRenamedEvents(surfaceID: terminal.descriptor.id) {
      for frame in frames { terminal.handleOSCTitle(frame) }
      pumpMainRunLoop(for: 0.4)
    }

    XCTAssertEqual(
      context.snapshotSaveScheduleCountForTesting - savesBefore, 0,
      "spinner-only frames must never schedule a session snapshot save")
    XCTAssertLessThanOrEqual(events.count, 1)
    XCTAssertEqual(events.count, 0, "the normalized title never changed, so iOS gets nothing")
    XCTAssertFalse(router.terminalTitleCoalescer.hasPendingWorkForTesting)
    XCTAssertEqual(terminal.descriptor.title, frames.last, "the live surface keeps the raw frame")
  }

  func testRapidRealTitleChangesCommitImmediatelyThenOnceWithTheLatestTitle() throws {
    // WHY (H3): a TUI that rewrites its title every second (task summary,
    // elapsed counter) must not persist and broadcast each rewrite. The first
    // change is acknowledged at once; a burst inside the window collapses into
    // one trailing commit of the newest title, persisted exactly once.
    let (context, router, directory) = try makeHarness()
    router.terminalTitleCoalescer.interval = 0.3
    let (workspace, terminal) = try makeTerminal(router, name: "H3 burst")
    let surfaceID = terminal.descriptor.id

    var savesBefore = context.snapshotSaveScheduleCountForTesting
    let immediate = captureSurfaceRenamedEvents(surfaceID: surfaceID) {
      terminal.handleOSCTitle("◐ Step 1")
    }
    XCTAssertEqual(immediate.map { $0.payload.objectValue?["title"]?.stringValue }, ["Step 1"])
    XCTAssertEqual(context.snapshotSaveScheduleCountForTesting - savesBefore, 1)

    savesBefore = context.snapshotSaveScheduleCountForTesting
    var burstSavesBeforeFlush = -1
    let trailing = captureSurfaceRenamedEvents(surfaceID: surfaceID) {
      terminal.handleOSCTitle("◑ Step 2")
      terminal.handleOSCTitle("◐ Step 3")
      terminal.handleOSCTitle("◑ Step 4")
      burstSavesBeforeFlush = context.snapshotSaveScheduleCountForTesting - savesBefore
      pumpMainRunLoop(for: 0.6)
    }
    XCTAssertEqual(burstSavesBeforeFlush, 0, "changes inside the window wait for the trailing edge")
    XCTAssertEqual(
      trailing.map { $0.payload.objectValue?["title"]?.stringValue }, ["Step 4"],
      "only the latest title in the burst reaches iOS, normalized")
    XCTAssertEqual(context.snapshotSaveScheduleCountForTesting - savesBefore, 1, "persisted once")
    XCTAssertEqual(surfaceTitle(in: context, workspaceID: workspace, surfaceID: surfaceID), "Step 4")

    context.saveSnapshot()
    closeAndUnregisterAllSurfaces()
    let reloaded = try AppContext(channel: .debug, appSupportOverride: directory)
    XCTAssertEqual(
      surfaceTitle(in: reloaded, workspaceID: workspace, surfaceID: surfaceID), "Step 4",
      "the coalesced title must survive a relaunch")
  }

  func testTitleThatReturnsToTheCommittedValueInsideTheWindowIsDropped() throws {
    // WHY (H3, A->B->A race): the trailing commit must compare against the
    // authoritative title, so a stale intermediate value never lands.
    let (context, router, _) = try makeHarness()
    router.terminalTitleCoalescer.interval = 0.3
    let (workspace, terminal) = try makeTerminal(router, name: "H3 aba")
    let surfaceID = terminal.descriptor.id
    terminal.handleOSCTitle("Build")

    let savesBefore = context.snapshotSaveScheduleCountForTesting
    let events = captureSurfaceRenamedEvents(surfaceID: surfaceID) {
      terminal.handleOSCTitle("Deploy")
      terminal.handleOSCTitle("Build")
      pumpMainRunLoop(for: 0.6)
    }
    XCTAssertTrue(events.isEmpty)
    XCTAssertEqual(context.snapshotSaveScheduleCountForTesting - savesBefore, 0)
    XCTAssertEqual(surfaceTitle(in: context, workspaceID: workspace, surfaceID: surfaceID), "Build")
  }

  func testPendingTitleForAClosedTerminalNeverCommits() throws {
    // WHY (H3): the trailing commit is deferred work; a tab closed inside the
    // window must not resurrect a rename event or a snapshot save.
    let (context, router, _) = try makeHarness()
    router.terminalTitleCoalescer.interval = 0.3
    let (_, terminal) = try makeTerminal(router, name: "H3 closed")
    let surfaceID = terminal.descriptor.id
    terminal.handleOSCTitle("First")

    let savesBefore = context.snapshotSaveScheduleCountForTesting
    let events = captureSurfaceRenamedEvents(surfaceID: surfaceID) {
      terminal.handleOSCTitle("Second")
      terminal.close()
      SurfaceRegistry.shared.unregister(surfaceID)
      pumpMainRunLoop(for: 0.6)
    }
    XCTAssertTrue(events.isEmpty)
    XCTAssertEqual(context.snapshotSaveScheduleCountForTesting - savesBefore, 0)
    XCTAssertFalse(router.terminalTitleCoalescer.hasPendingWorkForTesting)
  }

  func testUserRenameInsideTheWindowWinsOverAPendingOSCTitle() throws {
    // WHY (H3 review): the trailing commit is deferred work. A tab rename the
    // user makes (inline or from iOS) while an OSC title is pending is newer
    // state; the stale OSC title must never overwrite it or reach iOS.
    let (context, router, _) = try makeHarness()
    router.terminalTitleCoalescer.interval = 0.3
    let (workspace, terminal) = try makeTerminal(router, name: "H3 rename")
    let surfaceID = terminal.descriptor.id
    terminal.handleOSCTitle("A")

    let events = captureSurfaceRenamedEvents(surfaceID: surfaceID) {
      terminal.handleOSCTitle("B")
      XCTAssertTrue(router.terminalTitleCoalescer.hasPendingWorkForTesting)
      try? router.renameSurface(workspace, surfaceID, "Mine")
      pumpMainRunLoop(for: 0.6)
    }
    XCTAssertEqual(surfaceTitle(in: context, workspaceID: workspace, surfaceID: surfaceID), "Mine")
    XCTAssertFalse(
      events.contains { $0.payload.objectValue?["title"]?.stringValue == "B" },
      "the stale OSC title must not be broadcast after the user's rename")
    XCTAssertFalse(router.terminalTitleCoalescer.hasPendingWorkForTesting)

    terminal.handleOSCTitle("C")
    pumpMainRunLoop(for: 0.6)
    XCTAssertEqual(
      surfaceTitle(in: context, workspaceID: workspace, surfaceID: surfaceID), "C",
      "a title the TUI sets after the rename still mirrors, as before H3")
  }

  func testPendingTitleIsFlushedBeforeTheQuitSnapshot() throws {
    // WHY (H3 review): a real title still inside the throttle window when the
    // app quits must survive the relaunch; the quit path flushes it before the
    // final snapshot save.
    let (context, router, directory) = try makeHarness()
    router.terminalTitleCoalescer.interval = 30
    let (workspace, terminal) = try makeTerminal(router, name: "H3 quit")
    let surfaceID = terminal.descriptor.id
    terminal.handleOSCTitle("Old")

    let events = captureSurfaceRenamedEvents(surfaceID: surfaceID) {
      terminal.handleOSCTitle("Newest")
      XCTAssertEqual(surfaceTitle(in: context, workspaceID: workspace, surfaceID: surfaceID), "Old")
      router.flushPendingTerminalTitles()
    }
    XCTAssertEqual(events.map { $0.payload.objectValue?["title"]?.stringValue }, ["Newest"])
    XCTAssertFalse(router.terminalTitleCoalescer.hasPendingWorkForTesting)

    context.saveSnapshot()
    closeAndUnregisterAllSurfaces()
    let reloaded = try AppContext(channel: .debug, appSupportOverride: directory)
    XCTAssertEqual(
      surfaceTitle(in: reloaded, workspaceID: workspace, surfaceID: surfaceID), "Newest")
  }

  func testCommittedTitleReachesTheVisibleTabLabelAndSidebarButSpinnerFramesDoNot() throws {
    // WHY (H3 review): the commit patches the tab label in place instead of a
    // full window refresh. Without a window controller every other test passes
    // even if that patch is dropped, so drive a real MainWindowController.
    let (context, router, _) = try makeHarness()
    router.terminalTitleCoalescer.interval = 0.2
    let (workspace, terminal) = try makeTerminal(router, name: "H3 tab label")
    let surfaceID = terminal.descriptor.id
    let controller = MainWindowController(context: context, router: router)
    router.windowController = controller
    defer { router.windowController = nil; controller.window.orderOut(nil) }
    pumpMainRunLoop(for: 0.05)
    let tab = { () -> PaneTabButton? in
      controller.window.contentView?.layoutSubtreeIfNeeded()
      return self.allSubviews(of: controller.window.contentView ?? NSView())
        .compactMap { $0 as? PaneTabButton }
        .first { $0.accessibilityIdentifier() == "pane.tab.\(surfaceID.value.uuidString)" }
    }
    XCTAssertEqual(try XCTUnwrap(tab()).titleForTesting, "Before OSC")
    let tabBefore = try XCTUnwrap(tab())

    terminal.handleOSCTitle("⠋ Deploy")
    XCTAssertEqual(tabBefore.titleForTesting, "Deploy", "the committed title patches the visible label")
    XCTAssertTrue(tab() === tabBefore, "a title-only change must not rebuild the tab strip")
    let sidebarTitle = controller.sidebarWorkspacesForTesting
      .first { $0.id == workspace }
      .flatMap { ws in ws.layout.paneIDs().compactMap { ws.layout.find(paneID: $0) }
        .flatMap(\.surfaces).first { $0.id == surfaceID }?.title }
    XCTAssertEqual(sidebarTitle, "Deploy", "the sidebar's workspace snapshot follows the committed title")

    pumpMainRunLoop(for: 0.3)
    for glyph in ["⠙", "⠹", "⠸", "◐", "✳"] { terminal.handleOSCTitle("\(glyph) Deploy") }
    pumpMainRunLoop(for: 0.3)
    XCTAssertEqual(tabBefore.titleForTesting, "Deploy", "spinner frames leave the label as is")
  }

  private func allSubviews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
  }

  private func makeTerminal(
    _ router: AppCommandRouter, name: String
  ) throws -> (WorkspaceID, TerminalSurface) {
    let workspace = try router.createWorkspace(name: name, cwd: NSTemporaryDirectory())
    let descriptor = try router.createSurface(
      workspace: workspace.id, type: .terminal, paneID: nil, title: "Before OSC")
    let terminal = try XCTUnwrap(SurfaceRegistry.shared.surface(descriptor.id) as? TerminalSurface)
    return (workspace.id, terminal)
  }

  private func pumpMainRunLoop(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
    }
  }

  private func captureSurfaceRenamedEvents(
    surfaceID: SurfaceID, _ body: () -> Void
  ) -> [EventBus.Event] {
    captureSurfaceRenamedEvents(body).filter {
      $0.payload.objectValue?["id"]?.stringValue == surfaceID.value.uuidString
    }
  }

  private func makeHarness() throws -> (AppContext, AppCommandRouter, String) {
    let directory = NSTemporaryDirectory() + "RC2TerminalOSC-" + UUID().uuidString
    temporaryDirectories.append(directory)
    let context = try AppContext(channel: .debug, appSupportOverride: directory)
    let router = AppCommandRouter(context: context)
    context.router = router
    return (context, router, directory)
  }

  private func closeAndUnregisterAllSurfaces() {
    let surfaces = SurfaceRegistry.shared.all()
    for surface in surfaces {
      surface.close()
    }
    for surface in surfaces {
      SurfaceRegistry.shared.unregister(surface.descriptor.id)
    }
  }

  private func captureSurfaceRenamedEvents(_ body: () -> Void) -> [EventBus.Event] {
    let startSequence = EventBus.shared.snapshot().lastSeq
    var events: [EventBus.Event] = []
    let token = EventBus.shared.subscribe(since: startSequence) { event in
      guard event.kind == "surface.renamed" else { return }
      events.append(event)
    }
    defer { EventBus.shared.unsubscribe(token) }
    body()
    return events
  }

  private func assertTitleChange(
    _ events: [EventBus.Event],
    context: AppContext,
    workspaceID: WorkspaceID,
    surfaceID: SurfaceID,
    title: String
  ) throws {
    XCTAssertEqual(
      surfaceTitle(in: context, workspaceID: workspaceID, surfaceID: surfaceID),
      title,
      "OSC title handling must update the authoritative layout before refreshing the tab"
    )
    XCTAssertEqual(
      events.count,
      1,
      "one OSC title action must emit exactly one surface.renamed event for iOS"
    )
    let payload = try XCTUnwrap(events.first?.payload.objectValue)
    XCTAssertEqual(payload["workspace_id"]?.stringValue, workspaceID.value.uuidString)
    XCTAssertEqual(payload["id"]?.stringValue, surfaceID.value.uuidString)
    XCTAssertEqual(payload["title"]?.stringValue, title)
    XCTAssertEqual(
      Set(payload.keys),
      ["workspace_id", "id", "title"],
      "OSC title mirroring must use the canonical surface.renamed payload schema"
    )
  }

  private func surfaceTitle(
    in context: AppContext,
    workspaceID: WorkspaceID,
    surfaceID: SurfaceID
  ) -> String? {
    guard let workspace = context.state.workspaces[workspaceID] else { return nil }
    for paneID in workspace.layout.paneIDs() {
      if let descriptor = workspace.layout.find(paneID: paneID)?.surfaces.first(where: {
        $0.id == surfaceID
      }) {
        return descriptor.title
      }
    }
    return nil
  }
}
