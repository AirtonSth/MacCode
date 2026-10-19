import XCTest
import CoreModel
import RemoteCodeTreaty
@testable import AppShell

/// A busy terminal or SSH tab is real running work, so Activity, the sidebar
/// "N running" line and the Pet must count it. Browser loads and project-script
/// tabs (which already have their own row) must not be counted twice.
final class ActivityBusySurfaceTests: XCTestCase {
    private func surface(_ type: SurfaceType, title: String = "npm run dev") -> ActiveSurfaceItem {
        let id = SurfaceID(UUID())
        return ActiveSurfaceItem(id: id.value, workspaceID: WorkspaceID(UUID()), workspaceName: "ws",
                                 surfaceID: id, title: title, type: type)
    }

    func test_busyTerminalAndSSHBecomeRunningItems_browserAndScriptTabsDoNot() {
        let terminal = surface(.terminal)
        let ssh = surface(.ssh, title: "")
        let browser = surface(.browser)
        let script = surface(.terminal)

        let items = ActivityService.busySurfaceItems(
            [terminal, ssh, browser, script], excluding: [script.surfaceID.value], now: Date()
        )

        XCTAssertEqual(items.map(\.surfaceID), [terminal.surfaceID.value, ssh.surfaceID.value])
        XCTAssertTrue(items.allSatisfy { $0.state == .running && !$0.blocking && !$0.needsAction })
        XCTAssertEqual(items.first?.workspaceID, terminal.workspaceID.value, "row must count toward its workspace")
        XCTAssertEqual(items.last?.title, "SSH", "an untitled SSH tab still needs a readable label")
    }
}
