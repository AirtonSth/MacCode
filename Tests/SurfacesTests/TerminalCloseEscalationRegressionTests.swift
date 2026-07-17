import CoreModel
import Darwin
import XCTest

@testable import Surfaces

@MainActor
final class TerminalCloseEscalationRegressionTests: XCTestCase {
  func test_closeEscalatesAndReapsShellThatIgnoresHangupAndTerminate() throws {
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "close escalation",
      launch: .shell(cwd: NSTemporaryDirectory())
    )
    let marker = "RC2_CLOSE_READY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

    XCTAssertEqual(
      surface.sendTextStatus(
        "trap '' HUP TERM; printf '\\n\(marker)\\n'; while :; do sleep 1; done\n"),
      .accepted,
      "the terminal must accept the resistant-child setup before close escalation is exercised"
    )
    _ = try waitForSnapshot(surface, containing: marker)
    let pid = try XCTUnwrap(
      surface.runtimeHealth().childPID,
      "a live terminal must expose the child PID that close is responsible for reaping"
    )
    defer { forceCleanup(processGroupLeader: pid) }

    surface.close()

    XCTAssertTrue(
      waitUntil(timeout: 3) { !Self.processExists(pid) },
      "closing a tab must bound teardown and reap a shell that ignores SIGHUP/SIGTERM; one immortal child and blocked waitpid worker per tab causes long-term process/memory accumulation"
    )
  }

  private func waitForSnapshot(
    _ surface: TerminalSurface,
    containing marker: String,
    timeout: TimeInterval = 6
  ) throws -> TerminalTextSnapshot {
    let deadline = Date().addingTimeInterval(timeout)
    var last = surface.readTextSnapshot()
    while Date() < deadline {
      last = surface.readTextSnapshot()
      if last.text.contains(marker) { return last }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    XCTFail(
      "timed out waiting for resistant shell readiness; last tail=\(String(last.text.suffix(240)))")
    throw Timeout()
  }

  private func waitUntil(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() { return true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return predicate()
  }

  private static func processExists(_ pid: pid_t) -> Bool {
    if Darwin.kill(pid, 0) == 0 { return true }
    return errno != ESRCH
  }

  private func forceCleanup(processGroupLeader pid: pid_t) {
    guard Self.processExists(pid) else { return }
    _ = Darwin.kill(-pid, SIGKILL)
    _ = Darwin.kill(pid, SIGKILL)
    _ = waitUntil(timeout: 2) { !Self.processExists(pid) }
  }

  private struct Timeout: Error {}
}
