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
    // Production hands the view bounded 256 KiB batches and retries a refused one
    // after the parser made room; a single >4 MiB call is rejected by design.
    XCTAssertFalse(view.processOutput(hiddenFlood), "the hard cap has no oversized-handoff exception")
    try feedInBoundedBatches(hiddenFlood, to: view)
    XCTAssertEqual(
      view.droppedOutputBytes,
      0,
      "a hidden terminal with a live Ghostty surface must process a >4 MiB burst instead of dropping its oldest bytes"
    )
    try waitUntil("the exact hidden flood tail must be readable before reveal", timeout: 12) {
      view.readViewportText()?.contains(hiddenDone) == true
    }

    // Queue a small renderable write, then detach before the feed finishes.
    // Hiding or reparenting changes the render generation but must never cancel
    // bytes already queued for the same parser.
    firstWindow.orderFrontRegardless()
    firstWindow.makeKey()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    view.setOcclusion(visible: true)
    XCTAssertTrue(
      view.isRenderableForTesting,
      "the fixture needs a live on-screen drawable to exercise the detach path"
    )
    view.processOutput(Data("\(staleGeneration)\r\n".utf8))
    view.removeFromSuperview()
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

  /// Ghostty's app mailbox holds 64 events and a feed that overflows it waits for
  /// a main-thread tick. Before the pump, a main-thread feed of 65 events froze
  /// the whole app. Here the main thread is held while the off-main feed fills
  /// the mailbox, then must receive every action, query reply, and byte in order.
  func testMailboxFloodOf65And1000EventsNeverFreezesMainAndKeepsEveryActionInOrder() throws {
    try requireNativeGhostty()
    for count in [65, 1000] {
      let view = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
      view.ownerIsClosing = { false }
      let window = makeWindow(containing: view)
      defer {
        view.ownerIsClosing = { true }
        view.closeSurface(silent: true)
        window.orderOut(nil)
      }
      view.setOcclusion(visible: true)
      view.forceRefresh()
      try waitUntil("the fixture must create a real Ghostty surface") { view.hasLiveSurfaceForTesting }

      var titles: [String] = []
      var replies = Data()
      view.onTitleChange = { titles.append($0) }
      view.onInputData = { replies.append($0) }
      var heartbeats = 0
      let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in heartbeats += 1 }
      defer { timer.invalidate() }

      let flood = Self.eventFlood(prefix: "E\(count)_", count: count, fillerBytes: 32 * 1024)
      XCTAssertTrue(view.processOutput(flood.data))
      Thread.sleep(forTimeInterval: 0.25)
      XCTAssertTrue(
        view.feedInFlightForTesting,
        "the fixture must hold a feed inside the full mailbox, the exact pre-fix deadlock shape"
      )
      let heartbeatsBeforeDrain = heartbeats

      try waitUntil("\(count) title actions must all arrive", timeout: 30) {
        titles.filter { $0.hasPrefix("E\(count)_") }.count >= count
      }
      try waitUntil("the whole payload must reach the parser", timeout: 30) {
        view.outputBytesOwned == 0
      }
      XCTAssertEqual(
        titles.filter { $0.hasPrefix("E\(count)_") },
        flood.titles,
        "every OSC 2 action must be delivered once and in order"
      )
      XCTAssertGreaterThan(heartbeats, heartbeatsBeforeDrain, "main must keep running while Ghostty drains")
      try waitUntil("query replies must reach the owner", timeout: 10) {
        Self.occurrences(of: "\u{1B}[?", in: replies) >= flood.queries
      }
      XCTAssertEqual(Self.occurrences(of: "\u{1B}[?", in: replies), flood.queries)

      var scrollback = ""
      try waitUntil("the drained parser must be readable", timeout: 10) {
        guard let text = view.readScrollbackText() else { return false }
        scrollback = text
        return text.contains(flood.endMarker)
      }
      var previous = scrollback.startIndex
      // Ghostty keeps a bounded scrollback, so only the newest lines are guaranteed.
      for index in [count - 30, count - 10, count - 1] {
        let marker = "E\(count)_txt\(index)."
        let range = try XCTUnwrap(scrollback.range(of: marker), "missing \(marker)")
        XCTAssertGreaterThanOrEqual(range.lowerBound, previous, "text order must match the input")
        previous = range.upperBound
      }
      XCTAssertEqual(view.droppedOutputBytes, 0)
    }
  }

  /// Chunk boundaries fall in the middle of a UTF-8 scalar and a CSI sequence;
  /// a cut anywhere in the pump would print replacement characters or "[31m".
  func testUTF8AndCSISplitAcrossPumpChunksAndHandoffsStayIntact() throws {
    try requireNativeGhostty()
    let chunk = GhosttyTerminalView.historyReplayChunkBytes
    let view = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    view.ownerIsClosing = { false }
    let window = makeWindow(containing: view)
    defer {
      view.ownerIsClosing = { true }
      view.closeSurface(silent: true)
      window.orderOut(nil)
    }
    view.setOcclusion(visible: true)
    view.forceRefresh()
    try waitUntil("the fixture must create a real Ghostty surface") { view.hasLiveSurfaceForTesting }

    var payload = Self.lines(untilCount: chunk - 1)
    payload.append(contentsOf: [0xC3])
    XCTAssertEqual(payload.count, chunk)
    payload.append(contentsOf: [0xA9])
    payload.append(Data("UTF8_OK\r\n".utf8))
    payload.append(Self.lines(untilCount: (2 * chunk) - 1 - payload.count))
    XCTAssertEqual(payload.count, (2 * chunk) - 1)
    payload.append(0x1B)
    payload.append(Data("[31mCSI_OK\u{1B}[0m\r\nSPLIT_END\r\n".utf8))

    // The first handoff ends inside the scalar, the second inside the CSI.
    let firstHandoff = payload.prefix(chunk)
    let secondHandoff = payload.dropFirst(chunk).prefix(chunk - 1)
    let rest = payload.dropFirst(2 * chunk - 1)
    XCTAssertTrue(view.processOutput(Data(firstHandoff)))
    XCTAssertTrue(view.processOutput(Data(secondHandoff)))
    XCTAssertTrue(view.processOutput(Data(rest)))

    var scrollback = ""
    try waitUntil("the split payload must be fully parsed", timeout: 10) {
      guard let text = view.readScrollbackText() else { return false }
      scrollback = text
      return text.contains("SPLIT_END")
    }
    XCTAssertTrue(scrollback.contains("\u{E9}UTF8_OK"), "UTF-8 scalar split at a chunk boundary")
    XCTAssertTrue(scrollback.contains("CSI_OK"))
    XCTAssertFalse(scrollback.contains("[31m"), "CSI split at a chunk boundary must be parsed, not printed")
    XCTAssertFalse(scrollback.contains("\u{FFFD}"))
  }

  /// Visible, hidden, reparented, reset and closed while the feed sits inside a
  /// full mailbox. Native free waits for the feed, effects of an older surface
  /// never reach the recreated one, and the main thread is never blocked.
  func testHideReparentResetAndCloseWhileMailboxIsFullNeverBlockOrLeak() throws {
    try requireNativeGhostty()
    let view = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    view.ownerIsClosing = { false }
    let firstWindow = makeWindow(containing: view)
    var secondWindow: NSWindow?
    defer {
      view.ownerIsClosing = { true }
      view.closeSurface(silent: true)
      firstWindow.orderOut(nil)
      secondWindow?.orderOut(nil)
    }
    view.setOcclusion(visible: true)
    view.forceRefresh()
    try waitUntil("the fixture must create a real Ghostty surface") { view.hasLiveSurfaceForTesting }
    var titles: [String] = []
    view.onTitleChange = { titles.append($0) }
    view.onInputData = { _ in }
    var heartbeats = 0
    let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in heartbeats += 1 }
    defer { timer.invalidate() }

    // 1. Flood, then hide, reparent and reset without ever yielding to a tick.
    XCTAssertTrue(view.processOutput(Self.eventFlood(prefix: "OLD_", count: 1000).data))
    Thread.sleep(forTimeInterval: 0.25)
    XCTAssertTrue(view.feedInFlightForTesting, "the fixture needs a feed blocked in the full mailbox")
    view.setOcclusion(visible: false)
    view.removeFromSuperview()
    secondWindow = makeWindow(containing: view)
    view.setOcclusion(visible: true)
    XCTAssertTrue(view.resetSurfaceOutput(Data("SEED_AFTER_RESET\r\n".utf8)))
    XCTAssertFalse(view.hasLiveSurfaceForTesting, "the old surface is closing until its feed ends")
    let creationsAtReset = view.surfaceCreationCountForTesting
    try waitUntil("the recreated surface must receive the reset seed", timeout: 30) {
      view.readScrollbackText()?.contains("SEED_AFTER_RESET") == true
    }
    XCTAssertEqual(view.surfaceCreationCountForTesting, creationsAtReset + 1)
    XCTAssertTrue(
      titles.filter { $0.hasPrefix("OLD_") }.isEmpty,
      "actions from the freed surface must not leak into the recreated one"
    )

    // 2. The recreated surface delivers a full flood in order.
    let second = Self.eventFlood(prefix: "NEW_", count: 65, fillerBytes: 256 * 1024)
    XCTAssertTrue(view.processOutput(second.data))
    Thread.sleep(forTimeInterval: 0.25)
    try waitUntil("the recreated surface must deliver every title", timeout: 30) {
      titles.filter { $0.hasPrefix("NEW_") }.count >= 65 && view.outputBytesOwned == 0
    }
    XCTAssertEqual(titles.filter { $0.hasPrefix("NEW_") }, second.titles)

    // 3. Close while the mailbox is full again.
    let third = Self.eventFlood(prefix: "LATE_", count: 1000)
    XCTAssertTrue(view.processOutput(third.data))
    Thread.sleep(forTimeInterval: 0.25)
    XCTAssertTrue(view.feedInFlightForTesting)
    let generation = view.nativeSurfaceGenerationForTesting
    view.closeSurface(silent: true, releaseHostCallbacks: false)
    XCTAssertFalse(view.hasLiveSurfaceForTesting)
    try waitUntil("the deferred free must complete once the feed returns", timeout: 30) {
      view.nativeSurfaceStateForTesting == .closed(generation)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertTrue(
      titles.filter { $0.hasPrefix("LATE_") }.isEmpty,
      "a closed view must not receive actions from its freed surface"
    )
    XCTAssertGreaterThan(heartbeats, 10, "the main thread must have kept running throughout")
  }

  private func feedInBoundedBatches(_ data: Data, to view: GhosttyTerminalView) throws {
    var offset = 0
    let deadline = Date().addingTimeInterval(30)
    while offset < data.count {
      let end = min(offset + 256 * 1024, data.count)
      if view.processOutput(data.subdata(in: offset..<end)) {
        offset = end
      } else {
        guard Date() < deadline else {
          XCTFail("the parser must keep draining while the producer retries")
          throw WaitTimeout()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
      }
    }
  }

  /// Closing and unmounting while the feed sits in a full mailbox, before any
  /// tick: the native renderer must already be off when the layer leaves its window.
  func testCloseAndUnmountWhileMailboxIsFullThenFreeAfterTheFeedReturns() throws {
    try requireNativeGhostty()
    let view = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    view.ownerIsClosing = { false }
    let window = makeWindow(containing: view)
    defer {
      view.ownerIsClosing = { true }
      view.closeSurface(silent: true)
      window.orderOut(nil)
    }
    view.setOcclusion(visible: true)
    view.forceRefresh()
    try waitUntil("the fixture must create a real Ghostty surface") { view.hasLiveSurfaceForTesting }
    var titles = 0
    view.onTitleChange = { _ in titles += 1 }
    var heartbeats = 0
    let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in heartbeats += 1 }
    defer { timer.invalidate() }

    XCTAssertTrue(view.processOutput(Self.eventFlood(prefix: "CU_", count: 1000).data))
    Thread.sleep(forTimeInterval: 0.25)
    XCTAssertTrue(view.feedInFlightForTesting)
    let generation = view.nativeSurfaceGenerationForTesting

    view.closeSurface(silent: true, releaseHostCallbacks: false)
    view.removeFromSuperview()
    window.orderOut(nil)
    XCTAssertFalse(view.hasLiveSurfaceForTesting)
    XCTAssertEqual(view.nativeSurfaceStateForTesting, .closing(generation))

    try waitUntil("the deferred free must complete after the feed returned", timeout: 30) {
      view.nativeSurfaceStateForTesting == .closed(generation)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(titles, 0, "a closed view must not apply actions from its retired surface")
    XCTAssertGreaterThan(heartbeats, 10)
  }

  /// Key and text input reach the native surface while a feed is blocked in the
  /// full mailbox (the parser releases the renderer lock while it waits).
  func testNativeKeyAndTextInputWhileFeedIsBlockedInFullMailbox() throws {
    try requireNativeGhostty()
    let view = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    view.ownerIsClosing = { false }
    let window = makeWindow(containing: view)
    defer {
      view.ownerIsClosing = { true }
      view.closeSurface(silent: true)
      window.orderOut(nil)
    }
    view.setOcclusion(visible: true)
    view.forceRefresh()
    try waitUntil("the fixture must create a real Ghostty surface") { view.hasLiveSurfaceForTesting }
    var received = Data()
    view.onInputData = { received.append($0) }

    XCTAssertTrue(view.processOutput(Self.eventFlood(prefix: "IN_", count: 1000).data))
    Thread.sleep(forTimeInterval: 0.25)
    XCTAssertTrue(view.feedInFlightForTesting, "input must be driven while the feed holds the full mailbox")

    let key = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "k",
      charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40
    ))
    view.keyDown(with: key)
    view.sendTextToSurfaceForTesting("TEXT_DURING_FEED")
    view.setOcclusion(visible: false)
    view.setOcclusion(visible: true)
    view.forceRefresh()

    try waitUntil("native key and text must reach the owner while the feed was blocked", timeout: 30) {
      let text = String(decoding: received, as: UTF8.self)
      return text.contains("k") && text.contains("TEXT_DURING_FEED") && view.outputBytesOwned == 0
    }
  }

  private func requireNativeGhostty() throws {
    guard ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1" else {
      throw XCTSkip("run with RC2_ENABLE_GHOSTTY_IN_TESTS=1 for the real Ghostty mailbox gate")
    }
  }

  private struct EventFlood {
    let data: Data
    let titles: [String]
    let queries: Int
    let endMarker: String
  }

  /// `count` OSC 2 titles, each followed by a text line ending in a standalone
  /// BEL, with a DA1 query every tenth event, then optional filler and an end marker.
  private static func eventFlood(prefix: String, count: Int, fillerBytes: Int = 0) -> EventFlood {
    var data = Data()
    var titles: [String] = []
    var queries = 0
    for index in 0..<count {
      titles.append("\(prefix)\(index)")
      data.append(Data("\u{1B}]2;\(prefix)\(index)\u{07}\(prefix)txt\(index).\u{07}\r\n".utf8))
      if index % 10 == 0 {
        data.append(Data("\u{1B}[c".utf8))
        queries += 1
      }
    }
    if fillerBytes > 0 {
      data.append(lines(untilCount: fillerBytes))
    }
    let end = "\(prefix)END"
    data.append(Data("\(end)\r\n".utf8))
    return EventFlood(data: data, titles: titles, queries: queries, endMarker: end)
  }

  /// Short printable lines totalling exactly `untilCount` bytes.
  private static func lines(untilCount: Int) -> Data {
    var data = Data()
    let line = Data((String(repeating: "x", count: 48) + "\r\n").utf8)
    while data.count + line.count <= untilCount { data.append(line) }
    data.append(Data(repeating: UInt8(ascii: "x"), count: untilCount - data.count))
    return data
  }

  private static func occurrences(of needle: String, in data: Data) -> Int {
    String(decoding: data, as: UTF8.self).components(separatedBy: needle).count - 1
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
