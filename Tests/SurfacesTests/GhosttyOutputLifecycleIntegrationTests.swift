import AppKit
import XCTest

@testable import Surfaces

/// Runtime regression for output that crosses Ghostty's AppKit lifecycle.
///
/// WHY: a terminal can receive bytes before its view is attached, while its tab
/// is hidden, and while AppKit temporarily reparents it through a nil window.
/// Those are normal workspace operations; losing the queued tail at any one of
/// them leaves macOS frozen on old content and makes the iOS mirror disagree.
@MainActor
final class GhosttyOutputLifecycleIntegrationTests: XCTestCase {
  func testOutputSurvivesPreAttachHiddenFloodDetachAndStaleFlushGeneration() throws {
    guard ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1" else {
      throw XCTSkip("run with RC2_ENABLE_GHOSTTY_IN_TESTS=1 for the real Ghostty lifecycle gate")
    }

    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let preAttach = "RC2_GHOSTTY_PREATTACH_\(token)"
    let hiddenDone = "RC2_GHOSTTY_HIDDEN_DONE_\(token)"
    let staleGeneration = "RC2_GHOSTTY_STALE_GENERATION_\(token)"
    let detached = "RC2_GHOSTTY_DETACHED_\(token)"
    let view = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    view.ownerIsClosing = { false }

    // Feed output before a live C surface exists. Attaching must drain it into
    // Ghostty in order instead of keeping only bytes that arrived after attach.
    view.processOutput(Data("\u{1B}[2J\u{1B}[H\(preAttach)\r\n".utf8))

    let firstWindow = makeWindow(containing: view)
    defer {
      view.ownerIsClosing = { true }
      view.closeSurface(silent: true)
      firstWindow.orderOut(nil)
    }
    view.setOcclusion(visible: true)
    view.forceRefresh()
    try waitUntil("pre-attach bytes must reach the real Ghostty surface") {
      view.readScrollbackText()?.contains(preAttach) == true
    }

    // A single payload larger than the 4 MiB pending cap takes the production
    // overflow branch. Because a live surface exists, all bytes must be handed
    // to Ghostty without front-truncation. Carriage returns keep scrollback
    // bounded while still forcing Ghostty to parse the full payload.
    view.setOcclusion(visible: false)
    var hiddenFlood = Data()
    let progress = Data("RC2_GHOSTTY_PROGRESS_\(token)\r".utf8)
    hiddenFlood.reserveCapacity((4 * 1024 * 1024) + progress.count + hiddenDone.utf8.count)
    while hiddenFlood.count <= 4 * 1024 * 1024 {
      hiddenFlood.append(progress)
    }
    hiddenFlood.append(Data("\r\n\(hiddenDone)\r\n".utf8))
    view.processOutput(hiddenFlood)
    XCTAssertEqual(
      view.droppedOutputBytes,
      0,
      "a hidden terminal with a live Ghostty surface must process a >4 MiB burst instead of dropping its oldest bytes"
    )
    try waitUntil("the exact hidden flood tail must be readable before reveal", timeout: 12) {
      view.readViewportText()?.contains(hiddenDone) == true
    }

    // Queue a small renderable write (20 ms delayed flush), then detach before
    // its callback fires. The stale generation callback must schedule the
    // current generation and preserve the bytes while the view is windowless.
    firstWindow.orderFrontRegardless()
    firstWindow.makeKey()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    view.setOcclusion(visible: true)
    XCTAssertTrue(
      view.isRenderableForTesting,
      "the fixture needs a live on-screen drawable to exercise the delayed-flush generation path"
    )
    view.processOutput(Data("\(staleGeneration)\r\n".utf8))
    let scheduled = view.outputFlushGenerationForTesting
    XCTAssertEqual(
      scheduled.scheduled,
      scheduled.current,
      "the fixture must have a delayed current-generation flush before detaching"
    )
    view.removeFromSuperview()
    XCTAssertGreaterThan(
      view.outputFlushGenerationForTesting.current,
      scheduled.current,
      "detaching must invalidate the already-scheduled flush generation"
    )
    RunLoop.main.run(until: Date().addingTimeInterval(0.12))
    view.processOutput(Data("\(detached)\r\n".utf8))

    let secondWindow = makeWindow(containing: view)
    defer { secondWindow.orderOut(nil) }
    view.setOcclusion(visible: true)
    view.forceRefresh()
    try waitUntil("detached and stale-generation bytes must survive reattach") {
      guard let text = view.readScrollbackText() else { return false }
      return text.contains(preAttach)
        && text.contains(hiddenDone)
        && text.contains(staleGeneration)
        && text.contains(detached)
    }
    XCTAssertEqual(view.droppedOutputBytes, 0)
  }

  private func makeWindow(containing view: NSView) -> NSWindow {
    let window = RuntimeVisibleTestWindow(
      contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentView = NSView(frame: window.contentLayoutRect)
    view.frame = window.contentView?.bounds ?? .zero
    view.autoresizingMask = [.width, .height]
    window.contentView?.addSubview(view)
    window.alphaValue = 1
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.orderFrontRegardless()
    window.makeKey()
    return window
  }

  private func waitUntil(
    _ message: String,
    timeout: TimeInterval = 6,
    predicate: () -> Bool
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() { return }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTFail(message)
    throw WaitTimeout()
  }

  private struct WaitTimeout: Error {}

  /// XCTest does not own an activated app, so AppKit reports test windows as
  /// occluded even after `orderFrontRegardless`. Override only that signal; the
  /// window is still a real ordered NSWindow with a real CAMetalLayer/display.
  private final class RuntimeVisibleTestWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
  }
}
