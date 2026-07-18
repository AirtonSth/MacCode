import XCTest

@testable import CoreModel
@testable import Surfaces

@MainActor
final class TerminalContinuousPTYIntegrationTests: XCTestCase {
    func testContinuousPTYOutputStaysOrderedBoundedAndMainLoopResponsive() throws {
        let bus = SurfaceOutputBus(flushDelay: 0, maxBatchBytes: 64 * 1024)
        let collector = FrameCollector()
        bus.sink = { frame in collector.append(frame) }
        _ = bus.currentSequence(SurfaceID())

        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "continuous PTY fairness",
            launch: .shell(cwd: NSTemporaryDirectory()),
            outputBus: bus
        )
        defer { surface.close() }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let beginMarker = "RC2_STREAM_BEGIN_\(token)"
        let endMarker = "RC2_STREAM_END_\(token)"
        let payloadBytes = 8 * 1024 * 1024
        let timerProbe = MainLoopProbe()
        let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
            timerProbe.recordTick()
        }
        RunLoop.main.add(timer, forMode: .default)
        timerProbe.start()
        defer { timer.invalidate() }

        let command = "printf '\\n\(beginMarker)\\n'; "
            + "dd if=/dev/zero bs=65536 count=128 2>/dev/null | LC_ALL=C tr '\\000' 'A'; "
            + "printf '\\n\(endMarker)\\n'; exit 0\n"
        XCTAssertEqual(
            surface.sendTextStatus(command),
            .accepted,
            "a live terminal must accept the command that drives the sustained PTY stream"
        )

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, surface.runtimeHealth().processAlive {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertFalse(
            surface.runtimeHealth().processAlive,
            "the sustained-output command must reach EOF within the integration-test deadline"
        )
        timerProbe.finish()
        bus.flushNow(surface.descriptor.id)

        let raw = collector.data(for: surface.descriptor.id)
        let beginData = Data(beginMarker.utf8)
        let endData = Data(endMarker.utf8)
        let beginRange = try XCTUnwrap(
            raw.range(of: beginData, options: .backwards),
            "the PTY stream must contain the emitted begin marker, not only the echoed command"
        )
        let endRange = try XCTUnwrap(
            raw.range(of: endData, options: .backwards),
            "the PTY stream must contain the emitted end marker after all payload bytes"
        )
        XCTAssertLessThan(beginRange.upperBound, endRange.lowerBound)
        guard beginRange.upperBound <= endRange.lowerBound else {
            throw InvalidMarkerOrder()
        }

        let payload = trimTerminalNewlines(Data(raw[beginRange.upperBound..<endRange.lowerBound]))
        XCTAssertEqual(
            payload.count,
            payloadBytes,
            "the mirror output bus must receive every byte from a sustained PTY stream in order"
        )
        XCTAssertTrue(
            payload.allSatisfy { $0 == 65 },
            "an ordered PTY stream cannot contain gaps, duplicated segments, or interleaved bytes"
        )

        let diagnostics = surface.ptyReadDiagnosticsForTesting
        XCTAssertGreaterThan(diagnostics.maxBatchBytes, 0)
        XCTAssertLessThanOrEqual(
            diagnostics.maxBatchBytes,
            256 * 1024,
            "a continuously readable PTY must yield at the production byte cap"
        )
        XCTAssertLessThanOrEqual(
            diagnostics.maxReadCalls,
            64,
            "a continuously readable PTY must yield at the production read-call cap"
        )

        let sequences = collector.sequences(for: surface.descriptor.id)
        let firstSequence = try XCTUnwrap(
            sequences.first,
            "sustained terminal output must publish at least one real-time mirror frame"
        )
        XCTAssertEqual(
            sequences,
            Array(firstSequence...(firstSequence + sequences.count - 1)),
            "live mirror frames must remain strictly contiguous while the PTY is continuously readable"
        )
        XCTAssertGreaterThanOrEqual(
            timerProbe.tickCount,
            5,
            "the main run loop must continue servicing unrelated work throughout sustained output"
        )
        XCTAssertLessThan(
            timerProbe.maximumGap,
            0.75,
            "bounded PTY handoffs must prevent a sustained stream from monopolizing the main run loop"
        )
        print(
            "TerminalContinuousPTY bytes=\(payload.count) frames=\(sequences.count) "
                + "maxReadBatchBytes=\(diagnostics.maxBatchBytes) "
                + "maxReadCalls=\(diagnostics.maxReadCalls) "
                + "mainLoopTicks=\(timerProbe.tickCount) maxMainLoopGap=\(timerProbe.maximumGap)"
        )
    }

    private func trimTerminalNewlines(_ data: Data) -> Data {
        var lower = data.startIndex
        var upper = data.endIndex
        while lower < upper, data[lower] == 10 || data[lower] == 13 {
            lower = data.index(after: lower)
        }
        while lower < upper {
            let previous = data.index(before: upper)
            guard data[previous] == 10 || data[previous] == 13 else { break }
            upper = previous
        }
        return Data(data[lower..<upper])
    }

    private struct InvalidMarkerOrder: Error {}

    private final class FrameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [SurfaceOutputBus.OutputFrame] = []

        func append(_ frame: SurfaceOutputBus.OutputFrame) {
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }

        func data(for surfaceID: SurfaceID) -> Data {
            lock.lock()
            defer { lock.unlock() }
            return frames.lazy
                .filter { $0.surfaceID == surfaceID }
                .reduce(into: Data()) { $0.append($1.data) }
        }

        func sequences(for surfaceID: SurfaceID) -> [Int] {
            lock.lock()
            defer { lock.unlock() }
            return frames.filter { $0.surfaceID == surfaceID }.map(\.sequence)
        }
    }

    private final class MainLoopProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var timestamps: [TimeInterval] = []
        private var startedAt: TimeInterval = 0
        private var finishedAt: TimeInterval = 0

        func start() {
            lock.lock()
            startedAt = ProcessInfo.processInfo.systemUptime
            lock.unlock()
        }

        func recordTick() {
            lock.lock()
            timestamps.append(ProcessInfo.processInfo.systemUptime)
            lock.unlock()
        }

        func finish() {
            lock.lock()
            finishedAt = ProcessInfo.processInfo.systemUptime
            lock.unlock()
        }

        var tickCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return timestamps.count
        }

        var maximumGap: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            let points = [startedAt] + timestamps + [finishedAt]
            guard points.count > 1 else { return .infinity }
            return zip(points, points.dropFirst()).map { $1 - $0 }.max() ?? .infinity
        }
    }
}
