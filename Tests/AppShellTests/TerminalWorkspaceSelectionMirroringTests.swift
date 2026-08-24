import XCTest

@testable import AppShell
@testable import CoreModel
@testable import Persistence
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

  func testDeferredActiveBotNavigationKeepsOnlyTheLatestRequestedBot() async throws {
    let directory = NSTemporaryDirectory() + "RC2ActiveThreadBotNavigation-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let context = try AppContext(channel: .debug, appSupportOverride: directory)
    let router = AppCommandRouter(context: context)
    context.router = router
    let bots = BotsViewModel(context: context, router: router)
    router.botsViewModel = bots
    let firstBot = try bots.create(name: "First", title: "First route")
    let secondBot = try bots.create(name: "Second", title: "Latest route")
    bots.openDesk(firstBot)
    let vm = ActiveThreadsViewModel(context: context, router: router, loadImmediately: false)

    func item(for bot: BotDefinition) -> PetActiveThreadItem {
      PetActiveThreadItem(
        threadID: AgentThreadID(),
        workspaceID: nil,
        threadTitle: bot.name,
        route: .botsDesk(botID: bot.id)
      )
    }

    vm.openActive(item(for: firstBot))
    vm.openActive(item(for: secondBot))

    XCTAssertEqual(
      bots.selectedBotID,
      firstBot.id,
      "exact Bot hydration must not replace the cached Desk during the click turn"
    )
    for _ in 0..<20 where bots.selectedBotID != secondBot.id {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertEqual(
      bots.selectedBotID,
      secondBot.id,
      "a cancelled navigation task must not clear or supersede the latest Bot request"
    )
  }
}
