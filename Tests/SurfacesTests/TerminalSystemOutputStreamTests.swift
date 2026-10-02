import AppKit
@testable import CoreModel
import XCTest

@testable import Surfaces

/// WHY: SCP results and oversize system text used to be converted to one `Data`
/// and handed to Ghostty whole. Past the 4 MiB cap the tail was lost, and a
/// rejected jumbo could leave the PTY reader paused with nothing to resume it.
/// The stream hands bounded slices over in order, behind a single owner.
@MainActor
final class TerminalSystemOutputStreamTests: XCTestCase {
  private func makeSurface(
    _ fake: StreamFakeNative?, title: String = "system output stream"
  ) throws -> TerminalSurface {
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: title,
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
    )
    if let fake {
      surface.installGhosttyNativeDriverForTesting(fake.driver())
      XCTAssertTrue(surface.prepareGhosttyHostForTesting())
    }
    return surface
  }

  /// 5 MiB+ of multibyte text with CSI sequences, so a slice cut inside a scalar
  /// or an escape would corrupt the byte stream.
  private func jumboPayload() -> String {
    String(repeating: "\u{1B}[31mé✓日本\u{1B}[0m line\r\n", count: 200_000)
  }

  func testDirectFiveMiBSystemTextReachesGhosttyWholeInOrderWithTheTrailingNotice() throws {
    let fake = StreamFakeNative()
    let surface = try makeSurface(fake)
    defer { fake.release(); surface.close() }
    let payload = jumboPayload()
    XCTAssertGreaterThan(payload.utf8.count, 5 * 1024 * 1024)

    XCTAssertTrue(surface.appendSystemText(payload + "SCP_END\r\n"))
    let expected = Data((payload + "SCP_END\r\n").utf8)
    try waitUntil("every byte must reach the parser", timeout: 30) {
      fake.fedData(for: 1).count >= expected.count && !surface.systemOutputOwnedForTesting
    }
    XCTAssertEqual(fake.fedData(for: 1).suffix(expected.count), expected)
    XCTAssertLessThanOrEqual(
      surface.ghosttyMaximumPendingOutputBytesForTesting, GhosttyTerminalView.maxPendingOutputBytes)
    XCTAssertEqual(surface.ownedGhosttyReplayOutputBytesForTesting, 0)
    XCTAssertEqual(surface.runtimeHealth().outputPartial, false)
  }

  func testStreamHoldsPTYBatchAndNoticesBehindSourceThenFlushesThemOnce() throws {
    let fake = StreamFakeNative(gated: true)
    let surface = try makeSurface(fake)
    defer { fake.release(); surface.close() }
    let payload = String(repeating: "S", count: 5 * 1024 * 1024)
    let lease = try XCTUnwrap(surface.reserveSystemOutput())
    XCTAssertNil(surface.reserveSystemOutput(), "a second source must be refused before any work")

    lease.deliver(payload, trailing: "[ssh upload completed]\n")

    surface.injectReaderOutputForTesting(Data("PTY_BATCH\r\n".utf8))
    surface.appendSystemText("LATE_NOTICE\r\n")
    XCTAssertGreaterThan(surface.systemOutputHeldBytesForTesting, 0)
    XCTAssertFalse(surface.appendSystemText(String(repeating: "J", count: 300 * 1024)),
                   "a jumbo write while another source streams is refused, not queued")

    fake.release()
    try waitUntil("source, notice, then held output must reach the parser", timeout: 20) {
      !surface.systemOutputOwnedForTesting && fake.tailContains("LATE_NOTICE")
    }
    let fed = String(decoding: fake.fedData(for: 1), as: UTF8.self)
    let notice = try XCTUnwrap(fed.range(of: "[ssh upload completed]\n"))
    let pty = try XCTUnwrap(fed.range(of: "PTY_BATCH\r\n"))
    let late = try XCTUnwrap(fed.range(of: "LATE_NOTICE\r\n"))
    XCTAssertLessThanOrEqual(notice.upperBound, pty.lowerBound)
    XCTAssertLessThanOrEqual(pty.upperBound, late.lowerBound)
    XCTAssertEqual(fed.components(separatedBy: "PTY_BATCH").count - 1, 1)
    XCTAssertEqual(surface.systemOutputHeldBytesForTesting, 0)
    XCTAssertTrue(surface.runtimeHealth().outputPartial, "the refused jumbo must be reported")
  }

  func testCloseDuringStreamReleasesTheSourceOnceAndLateDeliveryIsDropped() throws {
    let fake = StreamFakeNative(gated: true)
    let surface = try makeSurface(fake)
    defer { fake.release() }
    let lease = try XCTUnwrap(surface.reserveSystemOutput())
    lease.deliver(jumboPayload(), trailing: "END\n")
    XCTAssertTrue(surface.systemOutputOwnedForTesting)

    surface.close()
    lease.cancel()
    lease.cancel()
    XCTAssertFalse(surface.systemOutputOwnedForTesting)
    XCTAssertEqual(surface.systemOutputHeldBytesForTesting, 0)
    XCTAssertEqual(lease.remainingBytes, 0)
    XCTAssertNil(surface.reserveSystemOutput())

    let late = surface.reserveSystemOutput()
    late?.deliver("late", trailing: "")
    fake.release()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    XCTAssertFalse(String(decoding: fake.fedData, as: UTF8.self).contains("late"))
  }

  func testShellReaderPausesOnlyWhileStreamingAndResumesAfterwards() throws {
    let testRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("RC2SystemStream-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: testRoot) }
    let oldZDOTDIR = getenv("ZDOTDIR").map { String(cString: $0) }
    setenv("ZDOTDIR", testRoot.path, 1)
    setenv("HISTFILE", "/dev/null", 1)
    defer {
      if let oldZDOTDIR { setenv("ZDOTDIR", oldZDOTDIR, 1) } else { unsetenv("ZDOTDIR") }
    }
    let fake = StreamFakeNative(gated: true)
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(), title: "reader pause", launch: .shell(cwd: testRoot.path))
    defer { fake.release(); surface.close() }
    surface.installGhosttyNativeDriverForTesting(fake.driver())
    XCTAssertTrue(surface.prepareGhosttyHostForTesting())
    try waitUntil("the shell reader must be running") { surface.readerConfiguredForTesting }

    let lease = try XCTUnwrap(surface.reserveSystemOutput())
    XCTAssertFalse(surface.readerSuspendedForTesting, "a slow command must not pause the reader")
    lease.deliver(String(repeating: "S", count: 5 * 1024 * 1024), trailing: "END\n")
    XCTAssertTrue(surface.readerSuspendedForTesting)
    fake.release()
    try waitUntil("the reader must resume once the stream ends", timeout: 20) {
      !surface.systemOutputOwnedForTesting && !surface.readerSuspendedForTesting
    }
  }

  func testCancelledReservationFreesTheSlotWithoutOutput() throws {
    let surface = try makeSurface(nil)
    defer { surface.close() }
    let lease = try XCTUnwrap(surface.reserveSystemOutput())
    lease.cancel()
    XCTAssertFalse(surface.systemOutputOwnedForTesting)
    XCTAssertNotNil(surface.reserveSystemOutput())
  }

  func testWithoutNativeParserLargeOutputYieldsAndAccountsForRetainedSourceStorage() throws {
    let surface = try makeSurface(nil)
    defer { surface.close() }
    let payload = jumboPayload()
    let lease = try XCTUnwrap(surface.reserveSystemOutput())
    lease.deliver(payload)
    XCTAssertTrue(surface.systemOutputOwnedForTesting, "admission must not parse the whole payload on the interaction turn")
    var mainTurnRan = false
    DispatchQueue.main.async { mainTurnRan = true }
    try waitUntil("a queued main turn must run before the source finishes") { mainTurnRan }
    XCTAssertTrue(surface.systemOutputOwnedForTesting)
    XCTAssertLessThan(lease.remainingBytes, payload.utf8.count)
    XCTAssertEqual(lease.retainedBytes, payload.utf8.count, "a partially consumed string still owns its full storage")
    try waitUntil("the source must complete after yielding", timeout: 30) { !surface.systemOutputOwnedForTesting }
    XCTAssertEqual(lease.retainedBytes, 0)
    XCTAssertFalse(surface.readerSuspendedForTesting)
  }

  func testWithoutNativeParserTheStreamCompletesAndLeavesTheReaderRunning() throws {
    let surface = try makeSurface(nil)
    defer { surface.close() }
    XCTAssertTrue(surface.appendSystemText(jumboPayload()))
    try waitUntil("a stream without a native parser must still finish", timeout: 30) {
      !surface.systemOutputOwnedForTesting
    }
    XCTAssertFalse(surface.readerSuspendedForTesting)
    XCTAssertFalse(surface.liveOutputBackpressureActiveForTesting)
  }

  func testRejectedJumboPTYHandoffNeverLeavesTheReaderPausedWithoutWork() throws {
    let fake = StreamFakeNative(gated: true)
    let surface = try makeSurface(fake)
    defer { fake.release(); surface.close() }
    // Larger than the owner cap: it cannot be held, so nothing may wait on it.
    surface.injectReaderOutputForTesting(Data(repeating: 0x41, count: 5 * 1024 * 1024))
    XCTAssertEqual(surface.ownedGhosttyReplayOutputBytesForTesting, 0)
    XCTAssertFalse(surface.liveOutputBackpressureActiveForTesting)
    XCTAssertFalse(surface.readerSuspendedForTesting)
    XCTAssertTrue(surface.runtimeHealth().outputPartial)
  }

  private func waitUntil(
    _ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool
  ) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    XCTFail(message)
    throw StreamWaitTimeout()
  }
}

private struct StreamWaitTimeout: Error {}

/// Stand-in for the C surface calls; records the exact byte stream the parser saw.
private final class StreamFakeNative: @unchecked Sendable {
  private let lock = NSLock()
  private let gate: DispatchSemaphore?
  private var created = 0
  private var fed: [Int: Data] = [:]
  private var fedAll = Data()

  init(gated: Bool = false) { gate = gated ? DispatchSemaphore(value: 0) : nil }

  func driver() -> GhosttyTerminalView.NativeDriverForTesting {
    GhosttyTerminalView.NativeDriverForTesting(
      create: { [self] in
        locked {
          created += 1
          return UnsafeMutableRawPointer(bitPattern: created)
        }
      },
      feed: { [self] surface, chunk in
        gate?.wait()
        locked {
          fed[Int(bitPattern: surface), default: Data()].append(chunk)
          fedAll.append(chunk)
        }
      },
      free: { _ in },
      setOcclusion: { _, _ in },
      read: { _ in nil }
    )
  }

  func release() {
    guard let gate else { return }
    for _ in 0..<4096 { gate.signal() }
  }

  var fedData: Data { locked { fedAll } }
  func fedData(for surface: Int) -> Data { locked { fed[surface] ?? Data() } }
  func tailContains(_ text: String) -> Bool {
    locked { String(decoding: fedAll.suffix(512), as: UTF8.self).contains(text) }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
