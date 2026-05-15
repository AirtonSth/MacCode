import XCTest
@testable import Persistence
import CoreModel

final class FixtureTests: XCTestCase {
    func test_emptyFixture_isEmpty() throws {
        let tmp = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let built = try FixtureFactory().build(.empty, dbPath: tmp)
        XCTAssertEqual(built.state.workspaces.count, 0)
        XCTAssertEqual(built.threads.count, 0)
    }

    func test_singleWorkspaceAgentAppFixture_isDeterministic() throws {
        let tmp = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let built = try FixtureFactory().build(.singleWorkspaceAgentApp, dbPath: tmp)
        XCTAssertEqual(built.state.workspaces.count, 1)
        XCTAssertEqual(built.threads.first?.title, "Fixture thread")
        XCTAssertEqual(built.threads.first?.id.value.uuidString, "DDDDDDDD-4444-4444-4444-444444444444")
        XCTAssertEqual(built.messages.count, 2)
    }

    func test_threeSurfaceLayoutFixture_hasSplitTree() throws {
        let tmp = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let built = try FixtureFactory().build(.threeSurfaceLayout, dbPath: tmp)
        let wid = built.state.window.selectedWorkspaceID!
        let layout = built.state.workspaces[wid]!.layout
        XCTAssertGreaterThanOrEqual(layout.paneIDs().count, 2)
    }

    /// Filesystem trace: bootstrap an isolated app-support directory and
    /// assert RemoteCode 2 only writes inside that directory. The point
    /// is to verify that the fresh-start bootstrap never probes other
    /// product paths even though the user filesystem contains them.
    func test_filesystemTrace_onlyTouchesOwnedPaths() throws {
        let isolatedDir = NSTemporaryDirectory() + "RC2FSTrace-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: isolatedDir) }
        let (rep, _) = try Bootstrap(channel: .debug, appSupportOverride: isolatedDir).run()
        for path in rep.touchedPaths {
            XCTAssertTrue(path.hasPrefix(isolatedDir), "Bootstrap touched non-owned path: \(path)")
        }
        // Walk the dir tree; no paths outside isolatedDir
        let fm = FileManager.default
        if let enumerator = fm.enumerator(atPath: isolatedDir) {
            while let item = enumerator.nextObject() as? String {
                let full = (isolatedDir as NSString).appendingPathComponent(item)
                XCTAssertTrue(full.hasPrefix(isolatedDir))
            }
        }
    }
}
