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

/// Busy terminal/SSH tabs are listed under their workspace above Bots so the user sees
/// live shell work without opening Activity; browser loads would flicker and stay out.
final class SidebarActiveSurfaceRowsTests: XCTestCase {
    func test_groupsBusyShellTabsByWorkspace_excludesBrowser() {
        let ws = WorkspaceID(UUID())
        func item(_ type: SurfaceType) -> ActiveSurfaceItem {
            let id = SurfaceID(UUID())
            return ActiveSurfaceItem(id: id.value, workspaceID: ws, workspaceName: "Test", surfaceID: id, title: "\(type)", type: type)
        }
        let terminal = item(.terminal), ssh = item(.ssh), browser = item(.browser)
        let rows = SidebarViewModel.activeSurfaceRows([terminal, ssh, browser])
        XCTAssertEqual(rows[ws]?.map(\.surfaceID), [terminal.surfaceID, ssh.surfaceID])
    }
}
