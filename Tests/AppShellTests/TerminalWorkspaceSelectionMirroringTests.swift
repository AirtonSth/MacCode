import XCTest

@testable import AppShell
@testable import SocketServer
@testable import Surfaces

@MainActor
final class TerminalWorkspaceSelectionMirroringTests: XCTestCase {
  func testLocalWorkspaceSelectionPublishesExactlyOneCanonicalMirrorEvent() throws {
    let directory = NSTemporaryDirectory() + "RC2TerminalWorkspaceSelection-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let context = try AppContext(channel: .debug, appSupportOverride: directory)
    let router = AppCommandRouter(context: context)
    context.router = router
    let first = try router.createWorkspace(name: "first", cwd: NSTemporaryDirectory())
    _ = try router.createWorkspace(name: "second", cwd: NSTemporaryDirectory())
    defer {
      for surface in SurfaceRegistry.shared.all() {
        surface.close()
        SurfaceRegistry.shared.unregister(surface.descriptor.id)
      }
    }

    let startingSequence = EventBus.shared.snapshot().lastSeq
    var selectedEvents: [EventBus.Event] = []
    let token = EventBus.shared.subscribe(since: startingSequence) { event in
      guard event.kind == "workspace.selected" else { return }
      selectedEvents.append(event)
    }
    defer { EventBus.shared.unsubscribe(token) }

    try router.selectWorkspace(first.id)

    XCTAssertEqual(
      selectedEvents.count,
      1,
      "a local macOS workspace switch must emit once so iOS follows the active Terminal workspace"
    )
    XCTAssertEqual(
      selectedEvents.first?.payload.objectValue?["workspace_id"]?.stringValue,
      first.id.value.uuidString
    )

    try router.selectWorkspace(first.id)
    XCTAssertEqual(
      selectedEvents.count,
      1,
      "reselecting the already-active workspace must not emit a duplicate mirror event"
    )
  }
}
