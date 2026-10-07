import AppKit
@testable import CoreModel
import XCTest

@testable import Surfaces

/// Deterministic gates for the single-flight Ghostty output pump.
///
/// WHY: `ghostty_surface_process_output` can block on Ghostty's 64-slot app
/// mailbox until `ghostty_app_tick` runs on the main thread. If the main thread
/// is the one inside the C call, the app freezes forever. These tests replace
/// only the C calls with a fake so the ownership rules can be proven without a
/// window server: one chunk in flight, off main, main free while it blocks, a
/// surface freed only after its feed ended, and no effect from an older surface.
@MainActor
final class GhosttyOutputPumpTests: XCTestCase {
  func testFeedIsSingleFlightOffMainAndKeepsEveryByteInOrder() throws {
    let fake = FakeNative()
    let view = makeView(fake)
    var payload = Data()
    for index in 0..<30_000 { payload.append(UInt8(truncatingIfNeeded: index &* 31)) }

    XCTAssertTrue(view.processOutput(payload))
    try waitUntil("every byte must reach the parser") { fake.fedBytes == payload.count }

    XCTAssertEqual(fake.fedData, payload, "chunking must not reorder, cut, or duplicate bytes")
    XCTAssertEqual(fake.maxConcurrentFeeds, 1, "only one chunk may be inside the C parser")
    XCTAssertLessThanOrEqual(fake.largestChunk, GhosttyTerminalView.historyReplayChunkBytes)
    XCTAssertFalse(fake.fedOnMainThread, "the blocking C call must never run on the main thread")
    XCTAssertEqual(view.outputBytesOwned, 0)
  }

  func testMainThreadKeepsRunningWhileTheFeedIsBlocked() throws {
    let fake = FakeNative(gated: true)
    let view = makeView(fake)
    XCTAssertTrue(view.processOutput(Data(repeating: 0x41, count: 100 * 1024)))
    XCTAssertEqual(fake.entered.wait(timeout: .now() + 5), .success)

    var heartbeats = 0
    let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in heartbeats += 1 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    timer.invalidate()

    XCTAssertGreaterThan(heartbeats, 10, "main must stay free while a feed waits for a tick")
    XCTAssertTrue(view.feedInFlightForTesting)
    XCTAssertEqual(fake.feedCount, 1, "the next chunk must wait for the in-flight one")
    XCTAssertEqual(view.outputBytesOwned, 100 * 1024, "queued + in-flight bytes are all accounted")

    fake.release()
    try waitUntil("the queue must drain after the feed unblocks") { view.outputBytesOwned == 0 }
    XCTAssertEqual(fake.fedBytes, 100 * 1024)
  }

  func testCapRejectsWholeHandoffAndNeverDropsOrCutsBytes() throws {
    let fake = FakeNative(gated: true)
    let view = makeView(fake)
    var capacityNotifications = 0
    view.onOutputCapacityAvailable = { capacityNotifications += 1 }
    let cap = GhosttyTerminalView.maxPendingOutputBytes
    let first = Data(repeating: 0x61, count: cap - 10_000)

    XCTAssertTrue(view.processOutput(first))
    XCTAssertFalse(view.hasOutputCapacity(forHandoffBytes: 256 * 1024))
    XCTAssertFalse(
      view.processOutput(Data(repeating: 0x62, count: 20_000)),
      "a handoff that does not fit must be rejected whole for the owner to retain"
    )
    XCTAssertEqual(view.outputBytesOwned, first.count, "a rejected handoff must leave no partial bytes")
    XCTAssertEqual(view.droppedOutputBytes, 0)
    XCTAssertLessThanOrEqual(view.maximumPendingOutputBytesObservedForTesting, cap)

    fake.release()
    try waitUntil("the accepted bytes must drain") { fake.fedBytes == first.count }
    XCTAssertTrue(view.hasOutputCapacity(forHandoffBytes: 256 * 1024))
    XCTAssertGreaterThan(capacityNotifications, 0, "a paused owner must be told capacity returned")
    XCTAssertTrue(view.processOutput(Data(repeating: 0x62, count: 20_000)), "the retry must now fit")
  }

  func testArbitrarilyLargeHandoffIsRejectedWithoutAllocationAndChunkedFloodKeepsFullFidelity() throws {
    let fake = FakeNative()
    let view = makeView(fake)
    let cap = GhosttyTerminalView.maxPendingOutputBytes

    XCTAssertFalse(
      view.processOutput(Data(repeating: 0x63, count: cap + 1)),
      "the hard cap has no exception: an oversized handoff is returned to the caller"
    )
    XCTAssertFalse(view.processOutput(Data(repeating: 0x63, count: 64 * cap)))
    XCTAssertEqual(view.pendingOutputDiagnosticsForTesting.storageBytes, 0, "rejection must not allocate")
    XCTAssertEqual(view.outputBytesOwned, 0)
    XCTAssertEqual(view.droppedOutputBytes, 0)

    // The caller streams the same volume in bounded 256 KiB batches and retries
    // a refused batch after the parser made room; nothing is lost or reordered.
    var expected = Data()
    expected.reserveCapacity(3 * cap)
    for index in 0..<(3 * cap) { expected.append(UInt8(truncatingIfNeeded: index &* 7 &+ index >> 8)) }
    var offset = 0
    var refused = 0
    let deadline = Date().addingTimeInterval(30)
    while offset < expected.count {
      let end = min(offset + 256 * 1024, expected.count)
      if view.processOutput(expected.subdata(in: offset..<end)) {
        offset = end
      } else {
        refused += 1
        XCTAssertLessThan(Date(), deadline, "the parser must keep draining")
        if Date() > deadline { return }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
      }
      XCTAssertLessThanOrEqual(view.outputBytesOwned, cap)
    }
    try waitUntil("the whole stream must reach the parser", timeout: 30) { fake.fedBytes == expected.count }
    XCTAssertTrue(fake.fedData == expected, "chunked retry must deliver every byte once, in order")
    XCTAssertLessThanOrEqual(view.maximumPendingOutputBytesObservedForTesting, cap)
    XCTAssertEqual(view.droppedOutputBytes, 0)
    XCTAssertGreaterThan(refused, 0, "the fixture must actually exercise the retry path")
  }

  func testCloseDefersNativeFreeToMainUntilTheInFlightFeedEndsAndFreesOnce() throws {
    let fake = FakeNative(gated: true)
    let view = makeView(fake)
    XCTAssertTrue(view.processOutput(Data(repeating: 0x65, count: 20_000)))
    XCTAssertEqual(fake.entered.wait(timeout: .now() + 5), .success)
    let generation = view.nativeSurfaceGenerationForTesting
    var delivered: [Data] = []
    view.onInputData = { delivered.append($0) }

    view.closeSurface(silent: true, releaseHostCallbacks: false)
    XCTAssertEqual(
      fake.events.filter { $0 == "occ:1:false" }.count,
      1,
      "close must stop the native renderer before the owner unmounts the layer, even when the free is deferred"
    )
    view.removeFromSuperview()
    XCTAssertEqual(fake.events.filter { $0 == "occ:1:false" }.count, 1)

    XCTAssertFalse(view.hasLiveSurfaceForTesting, "close must make the surface unavailable at once")
    XCTAssertEqual(view.nativeSurfaceStateForTesting, .closing(generation))
    view.writeInputData(Data("late".utf8), fromNativeGeneration: generation)
    XCTAssertTrue(delivered.isEmpty, "a closed surface must not leak input")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(fake.freeCount, 0, "main must not free (or wait) while the feed is in the parser")

    view.closeSurface(silent: true, releaseHostCallbacks: false)
    fake.release()
    try waitUntil("the feed completion must free the surface") { fake.freeCount == 1 }
    try waitUntil("the slot must finish closing") {
      view.nativeSurfaceStateForTesting == .closed(generation)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(fake.freeCount, 1, "the surface must be freed exactly once")
    let events = fake.events
    XCTAssertLessThan(
      try XCTUnwrap(events.firstIndex(of: "occ:1:false")),
      try XCTUnwrap(events.firstIndex(of: "free:1")),
      "renderer off must precede the free"
    )
    XCTAssertTrue(fake.freedOnMainThread, "ghostty_surface_free belongs on the main thread")
    XCTAssertEqual(fake.createCount, 1, "a plain close must not recreate")
    XCTAssertEqual(fake.fedBytes, 8 * 1024, "closed queue bytes must not reach any surface")
  }

  func testRepeatedResetsDuringAFeedRecreateOnceAfterFreeAndSeedLatestOnly() throws {
    let fake = FakeNative(gated: true)
    let view = makeView(fake)
    XCTAssertTrue(view.processOutput(Data(repeating: 0x66, count: 20_000)))
    XCTAssertEqual(fake.entered.wait(timeout: .now() + 5), .success)
    let oldGeneration = view.nativeSurfaceGenerationForTesting
    var delivered: [Data] = []
    view.onInputData = { delivered.append($0) }
    var replayCompletions = 0
    view.onHistoryReplayDrainCompleted = { replayCompletions += 1 }

    XCTAssertTrue(view.resetSurfaceOutput(Data("one".utf8)))
    XCTAssertTrue(view.resetSurfaceOutput(Data("two".utf8)))
    XCTAssertTrue(view.historyReplayDrainInProgressForTesting)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(fake.createCount, 1, "no second renderer may bind while the old surface is closing")

    fake.release()
    try waitUntil("the latest reset must seed the recreated surface") {
      fake.events.contains("feed:2")
    }
    try waitUntil("the replay must finish") { !view.historyReplayDrainInProgressForTesting }

    XCTAssertEqual(fake.createCount, 2)
    XCTAssertEqual(replayCompletions, 1, "the latest reset must finish its replay exactly once")
    let events = fake.events
    let freeOld = try XCTUnwrap(events.firstIndex(of: "free:1"))
    let createNew = try XCTUnwrap(events.firstIndex(of: "create:2"))
    XCTAssertLessThan(freeOld, createNew, "the new surface may exist only after the old one was freed")
    XCTAssertEqual(events.filter { $0 == "free:1" }.count, 1)
    XCTAssertEqual(fake.fedData(for: 2), Data("two".utf8), "only the latest reset may seed the new parser")

    view.writeInputData(Data("stale".utf8), fromNativeGeneration: oldGeneration)
    XCTAssertTrue(delivered.isEmpty, "an old surface's callbacks must not reach the recreated one")
    view.writeInputData(Data("fresh".utf8), fromNativeGeneration: view.nativeSurfaceGenerationForTesting)
    XCTAssertEqual(delivered, [Data("fresh".utf8)])
    XCTAssertFalse(view.isCurrentNativeGeneration(oldGeneration))
  }

  func testFullCapResetWhileOldFeedIsInFlightIsAcceptedWholeAndCompletesReplay() throws {
    let fake = FakeNative(gated: true)
    let view = makeView(fake)
    var completions = 0
    view.onHistoryReplayDrainCompleted = { completions += 1 }
    XCTAssertTrue(view.processOutput(Data(repeating: 0x41, count: 20_000)))
    XCTAssertEqual(fake.entered.wait(timeout: .now() + 5), .success)
    let cap = GhosttyTerminalView.maxPendingOutputBytes
    var seed = Data()
    for index in 0..<cap { seed.append(UInt8(truncatingIfNeeded: index &* 13)) }

    XCTAssertTrue(
      view.resetSurfaceOutput(seed),
      "the retired 8 KiB feed belongs to the old surface and must not shrink the new generation's budget"
    )
    XCTAssertTrue(view.historyReplayDrainInProgressForTesting)
    XCTAssertEqual(view.outputBytesOwned, cap)
    XCTAssertEqual(view.droppedOutputBytes, 0)
    XCTAssertLessThanOrEqual(view.retainedTerminalBytesEstimate, cap + 8 * 1024 + 2_000_000)

    fake.release()
    try waitUntil("the full seed must replay into the new generation", timeout: 30) { completions == 1 }
    XCTAssertTrue(fake.fedData(for: 2) == seed, "the seed must reach the new parser byte for byte")
    XCTAssertEqual(fake.createCount, 2)
    XCTAssertEqual(fake.events.filter { $0 == "free:1" }.count, 1)
    XCTAssertEqual(view.outputBytesOwned, 0)
  }

  func testCopyAllAndFindWaitForTheParserInsteadOfReadingNilAsEmpty() throws {
    let fake = FakeNative(gated: true)
    fake.viewportText = "viewport VISIBLE"
    fake.scrollbackText = "hay needle hay needle"
    let view = makeView(fake)
    var copied: [String] = []
    view.clipboardWriter = { copied.append($0) }
    XCTAssertEqual(view.accessibilityValueForTesting, "viewport VISIBLE")

    XCTAssertTrue(view.processOutput(Data(repeating: 0x41, count: 100 * 1024)))
    XCTAssertEqual(fake.entered.wait(timeout: .now() + 5), .success)
    view.copyViewportText()
    view.searchForTesting("needle")
    XCTAssertTrue(copied.isEmpty, "nothing may be copied from a stale or missing snapshot")
    XCTAssertEqual(view.findStateForTesting.label, "…", "pending search must not claim 0/0")
    XCTAssertEqual(view.pendingDrainActionCountForTesting, 2)
    XCTAssertEqual(
      view.accessibilityValueForTesting,
      "viewport VISIBLE",
      "accessibility keeps the last valid viewport while the parser drains"
    )

    fake.release()
    try waitUntil("copy and search must complete once the parser drained") {
      copied == ["viewport VISIBLE"] && view.findStateForTesting.label == "1/2"
    }
    XCTAssertEqual(view.findStateForTesting.matches, 2)
    XCTAssertEqual(view.pendingDrainActionCountForTesting, 0)
  }

  func testPendingFindSurvivesResetToTheLatestParserIncludingAnEmptySeed() throws {
    for seed in ["needle seed needle", ""] {
      let fake = FakeNative(gated: true)
      fake.scrollbackText = "old needle"
      let view = makeView(fake)
      defer { fake.release(); view.closeSurface(silent: true) }
      XCTAssertTrue(view.processOutput(Data("old output".utf8)))
      XCTAssertEqual(fake.entered.wait(timeout: .now() + 5), .success)
      view.searchForTesting("needle")
      XCTAssertEqual(view.findStateForTesting.label, "…")

      fake.scrollbackText = seed
      XCTAssertTrue(view.resetSurfaceOutput(Data(seed.utf8)))
      XCTAssertEqual(view.findStateForTesting.label, "…")
      fake.release()
      let expectedLabel = seed.isEmpty ? "0/0" : "1/2"
      try waitUntil("an open find must refresh after reset without another user action") {
        fake.createCount == 2 && view.findStateForTesting.label == expectedLabel
      }
      XCTAssertEqual(view.pendingDrainActionCountForTesting, 0)
      XCTAssertEqual(fake.fedData(for: 2), Data(seed.utf8))
    }
  }

  func testPendingCopyAndFindAreCancelledByCloseAndFindClose() throws {
    let fake = FakeNative(gated: true)
    fake.viewportText = "viewport"
    fake.scrollbackText = "needle"
    let view = makeView(fake)
    var copied: [String] = []
    view.clipboardWriter = { copied.append($0) }
    XCTAssertTrue(view.processOutput(Data(repeating: 0x41, count: 100 * 1024)))
    XCTAssertEqual(fake.entered.wait(timeout: .now() + 5), .success)

    view.copyViewportText()
    view.searchForTesting("needle")
    view.closeFindForTesting()
    XCTAssertEqual(view.pendingDrainActionCountForTesting, 1, "closing find cancels only its own request")
    view.closeSurface(silent: true, releaseHostCallbacks: false)
    XCTAssertEqual(view.pendingDrainActionCountForTesting, 0, "closing the surface cancels pending reads")

    fake.release()
    try waitUntil("the retired feed must finish") { fake.freeCount == 1 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    XCTAssertTrue(copied.isEmpty, "a cancelled copy must never reach the pasteboard")
    XCTAssertEqual(view.findStateForTesting.matches, 0)
  }

  func testFailedSurfaceCreationKeepsBufferedBytesForTheNextAttempt() throws {
    let fake = FakeNative(failFirstCreate: true)
    let view = GhosttyTerminalView(frame: .zero)
    view.nativeDriverForTesting = fake.driver()
    XCTAssertFalse(view.prepareHistoryReplayHost(), "a failed creation must tell the owner there is no host")

    XCTAssertTrue(view.processOutput(Data("before".utf8)))
    XCTAssertEqual(view.pendingOutputDiagnosticsForTesting.logicalBytes, 6)
    XCTAssertEqual(view.droppedOutputBytes, 0)

    XCTAssertTrue(view.prepareHistoryReplayHost())
    try waitUntil("buffered bytes must reach the surface once it exists") {
      fake.fedData(for: 1) == Data("before".utf8)
    }
  }

  func testSaturatedLiveQueuePausesOwnerKeepsWholeHandoffsInOrderAndResumes() throws {
    let fake = FakeNative(gated: true)
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "live output saturation",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
    )
    defer {
      fake.release()
      surface.close()
    }
    surface.installGhosttyNativeDriverForTesting(fake.driver())
    XCTAssertTrue(surface.prepareGhosttyHostForTesting())

    var expected = Data()
    var handoffs = 0
    while !surface.liveOutputBackpressureActiveForTesting {
      var handoff = Data(repeating: UInt8(0x30 + handoffs % 10), count: 256 * 1024 - 2)
      handoff.append(contentsOf: [0x0D, 0x0A])
      expected.append(handoff)
      surface.injectReaderOutputForTesting(handoff)
      handoffs += 1
      XCTAssertLessThan(handoffs, 40, "the owner must pause before the queue is exhausted")
    }
    // The placeholder banner already queued a few bytes, so the pause lands at
    // the first handoff after which one more full 256 KiB event might not fit.
    XCTAssertTrue((14...16).contains(handoffs), "paused after \(handoffs) handoffs")
    XCTAssertEqual(surface.ownedGhosttyReplayOutputBytesForTesting, 0)

    // A reader event already past its read when the pause lands, plus a notice.
    var racing = Data(repeating: 0x7A, count: 256 * 1024 - 2)
    racing.append(contentsOf: [0x0D, 0x0A])
    surface.injectReaderOutputForTesting(racing)
    expected.append(racing)
    let notice = "\r\nNOTICE\r\n"
    surface.appendSystemText(notice)
    expected.append(Data(notice.utf8))
    XCTAssertEqual(
      surface.ownedGhosttyReplayOutputBytesForTesting,
      racing.count + notice.utf8.count,
      "rejected handoffs stay whole and ordered in the owner FIFO"
    )
    XCTAssertLessThanOrEqual(
      surface.ghosttyMaximumPendingOutputBytesForTesting,
      GhosttyTerminalView.maxPendingOutputBytes
    )

    fake.release()
    try waitUntil("owner-held bytes must flow back in order", timeout: 20) {
      surface.ownedGhosttyReplayOutputBytesForTesting == 0
        && !surface.liveOutputBackpressureActiveForTesting
        && fake.fedBytes >= expected.count
        && fake.fedData(for: 1).suffix(expected.count) == expected
    }
    XCTAssertEqual(
      fake.fedData(for: 1).suffix(expected.count),
      expected,
      "FIFO across live, rejected, and notice bytes"
    )
    XCTAssertEqual(fake.maxConcurrentFeeds, 1)
  }

  func testReclaimWhileOwnerHoldsHandoffsNeitherDuplicatesNorLosesTheBudgetRetry() throws {
    let fake = FakeNative(gated: true)
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "reclaim under live pressure",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
    )
    defer {
      fake.release()
      surface.close()
    }
    surface.installGhosttyNativeDriverForTesting(fake.driver())
    XCTAssertTrue(surface.prepareGhosttyHostForTesting())
    surface.didBecomeVisible()

    var count = 0
    while !surface.liveOutputBackpressureActiveForTesting {
      var handoff = Data(repeating: 0x2E, count: 256 * 1024 - 2)
      handoff.append(contentsOf: [0x0D, 0x0A])
      surface.injectReaderOutputForTesting(handoff)
      count += 1
      XCTAssertLessThan(count, 40)
    }
    let marker = "RC2_OWNER_HELD_\(UUID().uuidString)"
    let tail = Data("\r\n\(marker)\r\n".utf8)
    var racing = Data(repeating: 0x7A, count: 256 * 1024 - tail.count)
    racing.append(tail)
    surface.injectReaderOutputForTesting(racing)
    XCTAssertGreaterThan(surface.ownedGhosttyReplayOutputBytesForTesting, 0, "the handoff must be owner-held")

    surface.reclaimTerminalMemoryForTesting()
    XCTAssertEqual(fake.createCount, 1, "no rebuild while an owner-held handoff is not yet in Ghostty")
    XCTAssertFalse(surface.terminalMemoryWasReclaimedForTesting)

    fake.release()
    try waitUntil("owner-held bytes must reach Ghostty", timeout: 20) {
      surface.ownedGhosttyReplayOutputBytesForTesting == 0 && fake.tailContains(marker)
    }
    XCTAssertEqual(fake.fedData(for: 1).ranges(of: Data(marker.utf8)).count, 1)

    surface.reclaimTerminalMemoryForTesting()
    XCTAssertTrue(surface.prepareGhosttyHostForTesting())
    try waitUntil("the deferred reclaim must rebuild the parser", timeout: 20) {
      fake.createCount == 2 && !surface.ghosttyReplayInProgressForTesting
    }
    let rebuilt = fake.fedData(for: 2)
    XCTAssertLessThanOrEqual(
      rebuilt.ranges(of: Data(marker.utf8)).count,
      1,
      "the owner-held handoff must reach the rebuilt parser at most once (seed XOR continuation)"
    )
    XCTAssertEqual(surface.readTextSnapshot().text.components(separatedBy: marker).count - 1, 1)
  }

  func testPTYReaderPausesWhileSaturatedAndResumesWithoutLosingAByte() throws {
    let testRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("RC2LivePressure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: testRoot) }
    let oldZDOTDIR = getenv("ZDOTDIR").map { String(cString: $0) }
    setenv("ZDOTDIR", testRoot.path, 1)
    setenv("HISTFILE", "/dev/null", 1)
    defer {
      if let oldZDOTDIR { setenv("ZDOTDIR", oldZDOTDIR, 1) } else { unsetenv("ZDOTDIR") }
    }

    let fake = FakeNative(gated: true)
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "live pty saturation",
      launch: .shell(cwd: testRoot.path),
      outputBus: SurfaceOutputBus(flushDelay: 0)
    )
    defer {
      fake.release()
      surface.close()
    }
    surface.installGhosttyNativeDriverForTesting(fake.driver())
    let readerStream = ByteTap()
    surface.setReaderWillPublishForTesting { readerStream.append($0) }
    XCTAssertTrue(surface.prepareGhosttyHostForTesting())
    try waitUntil("the shell reader must be running") { surface.readerConfiguredForTesting }

    // BSD seq prints 1000000 as 1e+06.
    let lines = 999_999
    let marker = "RC2_LIVE_PRESSURE_DONE_\(UUID().uuidString)"
    let command = "printf '\\n\(marker)_BEGIN\\n'; /usr/bin/seq 1 \(lines); printf '\\n\(marker)\\n'\n"
    XCTAssertEqual(surface.sendTextStatus(command), .accepted)

    try waitUntil("a saturated Ghostty queue must pause the PTY reader", timeout: 20) {
      surface.readerPausedForLiveOutputForTesting
    }
    XCTAssertLessThanOrEqual(
      surface.ghosttyMaximumPendingOutputBytesForTesting,
      GhosttyTerminalView.maxPendingOutputBytes,
      "the queue must stay bounded while the producer is paused"
    )
    XCTAssertLessThanOrEqual(
      surface.ownedGhosttyReplayOutputBytesForTesting,
      256 * 1024 + 64 * 1024,
      "at most one racing handoff plus notices may be owner-held"
    )
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertTrue(surface.readerPausedForLiveOutputForTesting, "no resume before capacity returns")

    fake.release()
    try waitUntil("the shell must reach its final marker", timeout: 60) {
      fake.tailContains("\r\n\(marker)\r\n")
    }
    try waitUntil("the reader must resume after the queue drains", timeout: 20) {
      !surface.readerPausedForLiveOutputForTesting && !surface.liveOutputBackpressureActiveForTesting
    }
    let fed = fake.fedData(for: 1)
    XCTAssertEqual(fed.count, readerStream.count, "pause/resume must neither drop nor duplicate bytes")
    XCTAssertTrue(fed == readerStream.data, "the parser must see the PTY stream byte for byte, in order")
    let text = String(decoding: fed, as: UTF8.self)
    let body = try XCTUnwrap(text.components(separatedBy: "\n\(marker)_BEGIN\r\n").last)
    let numbers = try XCTUnwrap(body.components(separatedBy: "\n\(marker)\r\n").first)
        .split(whereSeparator: \.isNewline).compactMap { Int($0) }
    XCTAssertEqual(numbers.count, lines, "every produced line must be present")
    if let gap = zip(numbers, 1...).first(where: { $0 != $1 }) {
      XCTFail("stream is not the exact sequence: saw \(gap.0) where \(gap.1) was expected")
    }
    XCTAssertEqual(fake.maxConcurrentFeeds, 1)
  }

  // MARK: - Fixtures

  private func makeView(_ fake: FakeNative) -> GhosttyTerminalView {
    let view = GhosttyTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    view.nativeDriverForTesting = fake.driver()
    XCTAssertTrue(view.prepareHistoryReplayHost())
    return view
  }

  private func waitUntil(
    _ message: String,
    timeout: TimeInterval = 10,
    predicate: () -> Bool
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() { return }
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    XCTFail(message)
    throw WaitTimeout()
  }

  private struct WaitTimeout: Error {}
}

/// Records exactly what the PTY reader published, before any Ghostty queueing.
private final class ByteTap: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  func append(_ chunk: Data) { lock.lock(); bytes.append(chunk); lock.unlock() }
  var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
  var count: Int { lock.lock(); defer { lock.unlock() }; return bytes.count }
}

/// Stand-in for the C surface calls. Surfaces are numbered pointers so the
/// event log can prove create/free/feed ordering across recreation.
private final class FakeNative: @unchecked Sendable {
  private let lock = NSLock()
  private let gate: DispatchSemaphore?
  private var failFirstCreate: Bool
  private var created = 0
  private var active = 0
  private var _maxConcurrentFeeds = 0
  private var _largestChunk = 0
  private var _feedCount = 0
  private var _freeCount = 0
  private var _fedOnMain = false
  private var _freedOnMain = true
  private var _events: [String] = []
  private var _fed: [Int: Data] = [:]
  private var _fedAll = Data()
  private var released = false
  let entered = DispatchSemaphore(value: 0)
  var viewportText: String?
  var scrollbackText: String?

  init(gated: Bool = false, failFirstCreate: Bool = false) {
    self.gate = gated ? DispatchSemaphore(value: 0) : nil
    self.failFirstCreate = failFirstCreate
  }

  func driver() -> GhosttyTerminalView.NativeDriverForTesting {
    GhosttyTerminalView.NativeDriverForTesting(
      create: { [self] in create() },
      feed: { [self] surface, chunk in feed(surface, chunk) },
      free: { [self] surface in free(surface) },
      setOcclusion: { [self] surface, visible in
        locked { _events.append("occ:\(Int(bitPattern: surface)):\(visible)") }
      },
      read: { [self] screen in locked { screen ? scrollbackText : viewportText } }
    )
  }

  /// Lets every present and future feed finish. Future feeds skip the gate
  /// entirely: a fixed permit count ran out after 4,096 feeds and wedged a
  /// multi-megabyte stream on the 4,097th chunk.
  func release() {
    guard let gate else { return }
    locked { released = true }
    for _ in 0..<4096 { gate.signal() }
  }

  var createCount: Int { locked { created } }
  var freeCount: Int { locked { _freeCount } }
  var feedCount: Int { locked { _feedCount } }
  var maxConcurrentFeeds: Int { locked { _maxConcurrentFeeds } }
  var largestChunk: Int { locked { _largestChunk } }
  var fedOnMainThread: Bool { locked { _fedOnMain } }
  var freedOnMainThread: Bool { locked { _freedOnMain } }
  var events: [String] { locked { _events } }
  var fedBytes: Int { locked { _fedAll.count } }
  var fedData: Data { locked { _fedAll } }
  func fedData(for surface: Int) -> Data { locked { _fed[surface] ?? Data() } }
  func tailContains(_ text: String) -> Bool {
    locked { String(decoding: _fedAll.suffix(512), as: UTF8.self).contains(text) }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private func create() -> UnsafeMutableRawPointer? {
    locked {
      if failFirstCreate {
        failFirstCreate = false
        return nil
      }
      created += 1
      _events.append("create:\(created)")
      return UnsafeMutableRawPointer(bitPattern: created)
    }
  }

  private func feed(_ surface: UnsafeMutableRawPointer, _ chunk: Data) {
    let id = Int(bitPattern: surface)
    locked {
      active += 1
      _maxConcurrentFeeds = max(_maxConcurrentFeeds, active)
      _largestChunk = max(_largestChunk, chunk.count)
      _feedCount += 1
      if Thread.isMainThread { _fedOnMain = true }
      _events.append("feed:\(id)")
    }
    entered.signal()
    if let gate, !locked({ released }) { gate.wait() }
    locked {
      _fed[id, default: Data()].append(chunk)
      _fedAll.append(chunk)
      active -= 1
    }
  }

  private func free(_ surface: UnsafeMutableRawPointer) {
    let id = Int(bitPattern: surface)
    locked {
      _freeCount += 1
      if !Thread.isMainThread { _freedOnMain = false }
      _events.append("free:\(id)")
    }
  }
}

private extension Data {
  func ranges(of needle: Data) -> [Range<Int>] {
    guard !needle.isEmpty, count >= needle.count else { return [] }
    var result: [Range<Int>] = []
    var start = startIndex
    while let range = self[start...].range(of: needle) {
      result.append(range)
      start = range.upperBound
    }
    return result
  }
}
