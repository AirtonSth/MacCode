import XCTest
@testable import AppShell
import CoreModel
import SocketServer

@MainActor
final class LocalGitActivityBridgeTests: XCTestCase {
    func test_appContextBridgesLocalGitOutcomeWithSafeExactPayload() throws {
        let directory = NSTemporaryDirectory() + "RC2LocalGitBridge-\(UUID().uuidString)"
        _ = try AppContext(channel: .debug, appSupportOverride: directory)
        let workspaceID = WorkspaceID(UUID())
        let surfaceID = SurfaceID(UUID())
        var received: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { received.append($0) }
        defer { EventBus.shared.unsubscribe(token) }

        LocalGitActivityBus.shared.emit(LocalGitActivity(
            kind: "git.push",
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            succeeded: false
        ))

        let event = try XCTUnwrap(received.last)
        XCTAssertEqual(event.kind, "git.push")
        XCTAssertEqual(event.payload.objectValue, [
            "workspace_id": .string(workspaceID.value.uuidString),
            "surface_id": .string(surfaceID.value.uuidString),
            "ok": .bool(false)
        ])
    }
}
