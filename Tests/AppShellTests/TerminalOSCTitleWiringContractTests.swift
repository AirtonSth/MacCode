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

    let changed = captureSurfaceRenamedEvents {
      terminal.handleOSCTitle("⠋ - Fix build - Distill")
    }
    XCTAssertEqual(
      changed.first?.payload.objectValue?["title"]?.stringValue,
      "Fix build - Distill",
      "a real title change behind the spinner must still reach iOS"
    )
    XCTAssertEqual(changed.count, 1)
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
