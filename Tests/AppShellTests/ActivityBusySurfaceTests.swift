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

/// Every open tab is listed under "Open Tabs"; only busy shell work spins. Browser loads
/// flicker on each navigation, so a loading browser tab must not spin.
final class SidebarActiveSurfaceRowsTests: XCTestCase {
    func test_onlyBusyNonBrowserTabsSpin() {
        let ws = WorkspaceID(UUID())
        func item(_ type: SurfaceType) -> ActiveSurfaceItem {
            let id = SurfaceID(UUID())
            return ActiveSurfaceItem(id: id.value, workspaceID: ws, workspaceName: "Test", surfaceID: id, title: "\(type)", type: type)
        }
        let terminal = item(.terminal), ssh = item(.ssh), files = item(.files), browser = item(.browser)
        let busy: Set<SurfaceID> = [terminal.surfaceID, ssh.surfaceID, browser.surfaceID]
        let spinning = SidebarViewModel.busyTabs([terminal, ssh, files, browser]) { busy.contains($0.surfaceID) }
        XCTAssertEqual(spinning.map(\.surfaceID), [terminal.surfaceID, ssh.surfaceID])
    }
}
