import CoreModel
import XCTest

@testable import Surfaces

final class TerminalSpawnEnvironmentContractTests: XCTestCase {
  func test_spawnEnvironmentIsPreparedCompletelyBeforeFork() {
    let workspaceID = WorkspaceID(UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
    let surfaceID = SurfaceID(UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
    let parent = [
      "NO_COLOR": "1",
      "ZDOTDIR": "/tmp/custom-zdotdir",
      "SHELL": "/bin/zsh",
      "USER_VALUE": "preserve-me",
    ]
    let startup = TerminalStartupEnvironment(
      parent: parent,
      workspaceID: workspaceID,
      surfaceID: surfaceID
    )

    let merged = startup.mergedEnvironment(parent: parent)

    XCTAssertNil(
      merged["NO_COLOR"],
      "environment removals must be resolved in the parent so the post-fork child never calls unsetenv"
    )
    XCTAssertEqual(merged["TERM"], "xterm-256color")
    XCTAssertEqual(merged["RC2_WORKSPACE_ID"], workspaceID.value.uuidString)
    XCTAssertEqual(merged["RC2_SURFACE_ID"], surfaceID.value.uuidString)
    XCTAssertEqual(
      merged["ZDOTDIR"],
      "/tmp/custom-zdotdir",
      "preparing an execve environment must preserve user shell configuration"
    )
    XCTAssertEqual(merged["USER_VALUE"], "preserve-me")
  }
}
