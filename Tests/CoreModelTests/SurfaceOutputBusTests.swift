import XCTest
@testable import CoreModel

final class SurfaceOutputBusTests: XCTestCase {
    func testFlushNowDeliversPendingTerminalOutputSynchronouslyForHistoryRead() {
        let bus = SurfaceOutputBus()
        let surfaceID = SurfaceID()
        var chunks: [String] = []
        var seqs: [Int] = []

        bus.sink = { id, seq, data in
            guard id == surfaceID else { return }
            seqs.append(seq)
            chunks.append(String(decoding: data, as: UTF8.self))
        }

        bus.emit(surfaceID, Data("complete ".utf8))
        bus.emit(surfaceID, Data("history".utf8))
        bus.flushNow(surfaceID)

        XCTAssertEqual(chunks, ["complete history"],
                       "surface.read_history must be able to flush the current terminal batch before returning an authoritative snapshot")
        XCTAssertEqual(seqs, [1])
    }

    func testBurstTerminalOutputIsBatchedBeforeMirrorDelivery() {
        let bus = SurfaceOutputBus()
        let surfaceID = SurfaceID()
        let delivered = expectation(description: "batched terminal output delivered")
        var chunks: [String] = []
        var seqs: [Int] = []

        bus.sink = { id, seq, data in
            guard id == surfaceID else { return }
            seqs.append(seq)
            chunks.append(String(decoding: data, as: UTF8.self))
            delivered.fulfill()
        }

        bus.emit(surfaceID, Data("long ".utf8))
        bus.emit(surfaceID, Data("command ".utf8))
        bus.emit(surfaceID, Data("output".utf8))

        XCTAssertTrue(
            chunks.isEmpty,
            "Burst terminal output should not synchronously fan out one mirror event per PTY read; batching protects the Mac UI and iOS mirror during noisy commands."
        )
        wait(for: [delivered], timeout: 1.0)
        XCTAssertEqual(chunks, ["long command output"])
        XCTAssertEqual(seqs, [1],
                       "batched terminal output must publish one monotonic per-surface seq per delivered mirror chunk")
    }
}
