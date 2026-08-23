import Darwin
import Foundation
import XCTest
@testable import SocketServer

final class WebSocketDeltaMergeBenchmarkTests: XCTestCase {
    private final class WorkCounter {
        var parses = 0
        var encodes = 0
    }

    private struct CPUTime {
        let seconds: Double

        static func current() -> CPUTime {
            var usage = rusage()
            precondition(getrusage(RUSAGE_SELF, &usage) == 0)
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            return CPUTime(seconds: user + system)
        }
    }

    private struct Workload {
        let name: String
        let frameCount: Int
        let tokenBytes: Int
        let burstsPerSample: Int
    }

    func test_deltaMergeObserversCountActualLegacyAndLinearWork() throws {
        // WHY: a future left-fold regression must fail on observed parse/encode
        // operations, rather than leave only a timing symptom behind.
        let workload = Workload(name: "contract", frameCount: 8, tokenBytes: 24, burstsPerSample: 1)
        let frames = try makeFrames(workload)
        let legacyWork = WorkCounter()
        let legacy = try XCTUnwrap(legacyMergeInOrder(frames, work: legacyWork).first)
        let linearWork = WorkCounter()
        let linearResult = instrumentedLinearMerge(frames, work: linearWork)
        let linear = try XCTUnwrap(linearResult.merged.first)

        XCTAssertEqual(try canonicalJSON(linear), try canonicalJSON(legacy))
        XCTAssertEqual(linearResult.absorbed.count, workload.frameCount - 1)
        XCTAssertEqual(legacyWork.parses, 3 * workload.frameCount - 2)
        XCTAssertEqual(legacyWork.encodes, workload.frameCount - 1)
        XCTAssertEqual(linearWork.parses, workload.frameCount)
        XCTAssertEqual(linearWork.encodes, 1)
    }

    func test_deltaMergeBenchmark() throws {
        guard ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] == "1" else {
            throw XCTSkip("raw wire-byte comparison requires SWIFT_DETERMINISTIC_HASHING=1")
        }
        let workloads = [
            Workload(name: "realistic", frameCount: 64, tokenBytes: 24, burstsPerSample: 30),
            Workload(name: "adversarial", frameCount: 512, tokenBytes: 192, burstsPerSample: 3),
        ]

        for workload in workloads {
            let frames = try makeFrames(workload)
            let legacyWork = WorkCounter()
            let legacyOutput = try XCTUnwrap(legacyMergeInOrder(frames, work: legacyWork).first)
            let linearWork = WorkCounter()
            let reference = instrumentedLinearMerge(frames, work: linearWork)
            let output = try XCTUnwrap(reference.merged.first)

            XCTAssertEqual(reference.merged.count, 1)
            XCTAssertEqual(reference.absorbed.count, workload.frameCount - 1)
            XCTAssertEqual(output, legacyOutput, "optimized wire bytes must match the legacy fold")
            XCTAssertEqual(legacyWork.parses, 3 * workload.frameCount - 2)
            XCTAssertEqual(legacyWork.encodes, workload.frameCount - 1)
            XCTAssertEqual(linearWork.parses, workload.frameCount)
            XCTAssertEqual(linearWork.encodes, 1)

            for _ in 0..<2 {
                _ = runLegacyBursts(frames: frames, count: workload.burstsPerSample)
                _ = runLinearBursts(frames: frames, count: workload.burstsPerSample)
            }

            var legacyWallSamples: [Double] = []
            var legacyCPUSamples: [Double] = []
            for sample in 1...7 {
                let measurement = measure {
                    runLegacyBursts(frames: frames, count: workload.burstsPerSample)
                }
                legacyWallSamples.append(measurement.wallMilliseconds)
                legacyCPUSamples.append(measurement.cpuMilliseconds)
                printSample(
                    phase: "legacy-paired",
                    workload: workload,
                    sample: sample,
                    measurement: measurement,
                    frames: frames,
                    output: legacyOutput,
                    work: legacyWork
                )
            }

            var linearWallSamples: [Double] = []
            var linearCPUSamples: [Double] = []
            for sample in 1...7 {
                let measurement = measure {
                    runLinearBursts(frames: frames, count: workload.burstsPerSample)
                }
                linearWallSamples.append(measurement.wallMilliseconds)
                linearCPUSamples.append(measurement.cpuMilliseconds)
                printSample(
                    phase: "optimized-paired",
                    workload: workload,
                    sample: sample,
                    measurement: measurement,
                    frames: frames,
                    output: output,
                    work: linearWork
                )
            }

            let legacyWall = median(legacyWallSamples)
            let linearWall = median(linearWallSamples)
            let legacyCPU = median(legacyCPUSamples)
            let linearCPU = median(linearCPUSamples)
            let wallImprovement = (legacyWall - linearWall) / legacyWall * 100
            let cpuImprovement = (legacyCPU - linearCPU) / legacyCPU * 100
            print(
                "WS_BATCH_BENCH_SUMMARY workload=\(workload.name) "
                    + "legacy_wall_median_ms=\(format(legacyWall)) "
                    + "optimized_wall_median_ms=\(format(linearWall)) "
                    + "wall_improvement_pct=\(format(wallImprovement)) "
                    + "legacy_cpu_median_ms=\(format(legacyCPU)) "
                    + "optimized_cpu_median_ms=\(format(linearCPU)) "
                    + "cpu_improvement_pct=\(format(cpuImprovement))"
            )
            XCTAssertGreaterThan(wallImprovement, 5, "wall-time gain must clear the qualification gate")
            XCTAssertGreaterThan(cpuImprovement, 5, "CPU gain must clear the qualification gate")
        }
    }

    func test_pressureCoalescerCountsLinearWorkPerDeltaKey() throws {
        // WHY: degrade runs only after the outbound queue is already under
        // pressure; repeated parse/encode of a growing delta frame amplifies
        // that pressure and must remain bounded to linear work.
        let workload = Workload(name: "pressure-contract", frameCount: 8, tokenBytes: 24, burstsPerSample: 1)
        let frames = try makeFrames(workload)
        let legacyWork = WorkCounter()
        let legacy = legacyPressureCoalesce(frames, work: legacyWork)
        let linearWork = WorkCounter()
        let linear = WebSocketOutboundQueue.coalesceApplicationFrames(
            frames,
            onParse: { linearWork.parses += 1 },
            onEncode: { linearWork.encodes += 1 }
        )

        XCTAssertEqual(linear.count, 1)
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(try canonicalJSON(XCTUnwrap(linear.first)), try canonicalJSON(XCTUnwrap(legacy.first)))
        XCTAssertEqual(legacyWork.parses, 3 * workload.frameCount - 2)
        XCTAssertEqual(legacyWork.encodes, workload.frameCount - 1)
        XCTAssertEqual(linearWork.parses, 2 * workload.frameCount)
        XCTAssertEqual(linearWork.encodes, 1)
    }

    func test_pressureCoalescerBenchmark() throws {
        guard ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] == "1" else {
            throw XCTSkip("raw wire-byte comparison requires SWIFT_DETERMINISTIC_HASHING=1")
        }
        let workload = Workload(name: "pressure-realistic", frameCount: 64, tokenBytes: 24, burstsPerSample: 30)
        let frames = try makeFrames(workload)
        let legacyWork = WorkCounter()
        let legacyOutput = legacyPressureCoalesce(frames, work: legacyWork)
        let linearWork = WorkCounter()
        let linearOutput = WebSocketOutboundQueue.coalesceApplicationFrames(
            frames,
            onParse: { linearWork.parses += 1 },
            onEncode: { linearWork.encodes += 1 }
        )
        let legacyFrame = try XCTUnwrap(legacyOutput.first)
        let linearFrame = try XCTUnwrap(linearOutput.first)

        XCTAssertEqual(linearOutput, legacyOutput, "optimized pressure-coalesced wire bytes must match the legacy fold")
        XCTAssertEqual(linearOutput.count, 1)
        XCTAssertEqual(legacyWork.parses, 3 * workload.frameCount - 2)
        XCTAssertEqual(legacyWork.encodes, workload.frameCount - 1)
        XCTAssertEqual(linearWork.parses, 2 * workload.frameCount)
        XCTAssertEqual(linearWork.encodes, 1)

        for _ in 0..<2 {
            _ = runLegacyPressureBursts(frames: frames, count: workload.burstsPerSample)
            _ = runLinearPressureBursts(frames: frames, count: workload.burstsPerSample)
        }

        var legacyWallSamples: [Double] = []
        var legacyCPUSamples: [Double] = []
        var linearWallSamples: [Double] = []
        var linearCPUSamples: [Double] = []
        for sample in 1...7 {
            let legacyMeasurement: (wallMilliseconds: Double, cpuMilliseconds: Double, checksum: UInt64)
            let linearMeasurement: (wallMilliseconds: Double, cpuMilliseconds: Double, checksum: UInt64)
            if sample.isMultiple(of: 2) {
                linearMeasurement = measure {
                    runLinearPressureBursts(frames: frames, count: workload.burstsPerSample)
                }
                legacyMeasurement = measure {
                    runLegacyPressureBursts(frames: frames, count: workload.burstsPerSample)
                }
            } else {
                legacyMeasurement = measure {
                    runLegacyPressureBursts(frames: frames, count: workload.burstsPerSample)
                }
                linearMeasurement = measure {
                    runLinearPressureBursts(frames: frames, count: workload.burstsPerSample)
                }
            }
            legacyWallSamples.append(legacyMeasurement.wallMilliseconds)
            legacyCPUSamples.append(legacyMeasurement.cpuMilliseconds)
            linearWallSamples.append(linearMeasurement.wallMilliseconds)
            linearCPUSamples.append(linearMeasurement.cpuMilliseconds)
            printSample(
                phase: "legacy-pressure",
                workload: workload,
                sample: sample,
                measurement: legacyMeasurement,
                frames: frames,
                output: legacyFrame,
                work: legacyWork
            )
            printSample(
                phase: "optimized-pressure",
                workload: workload,
                sample: sample,
                measurement: linearMeasurement,
                frames: frames,
                output: linearFrame,
                work: linearWork
            )
        }

        let legacyWall = median(legacyWallSamples)
        let linearWall = median(linearWallSamples)
        let legacyCPU = median(legacyCPUSamples)
        let linearCPU = median(linearCPUSamples)
        let wallImprovement = (legacyWall - linearWall) / legacyWall * 100
        let cpuImprovement = (legacyCPU - linearCPU) / legacyCPU * 100
        print(
            "WS_PRESSURE_COALESCE_BENCH_SUMMARY workload=\(workload.name) "
                + "legacy_wall_samples_ms=\(formatted(legacyWallSamples)) "
                + "optimized_wall_samples_ms=\(formatted(linearWallSamples)) "
                + "legacy_wall_median_ms=\(format(legacyWall)) "
                + "optimized_wall_median_ms=\(format(linearWall)) "
                + "wall_improvement_pct=\(format(wallImprovement)) "
                + "legacy_cpu_samples_ms=\(formatted(legacyCPUSamples)) "
                + "optimized_cpu_samples_ms=\(formatted(linearCPUSamples)) "
                + "legacy_cpu_median_ms=\(format(legacyCPU)) "
                + "optimized_cpu_median_ms=\(format(linearCPU)) "
                + "cpu_improvement_pct=\(format(cpuImprovement))"
        )
        XCTAssertGreaterThan(wallImprovement, 5, "wall-time gain must clear the qualification gate")
        XCTAssertGreaterThan(cpuImprovement, 5, "CPU gain must clear the qualification gate")
    }

    private func instrumentedLinearMerge(
        _ frames: [Data],
        work: WorkCounter
    ) -> (merged: [Data], absorbed: [Data]) {
        WebSocketEventBatcher.mergeAgentItemDeltasInOrder(
            frames,
            onParse: { work.parses += 1 },
            onEncode: { work.encodes += 1 }
        )
    }

    private func runLinearBursts(frames: [Data], count: Int) -> UInt64 {
        var checksum: UInt64 = 0
        for _ in 0..<count {
            let result = WebSocketEventBatcher.mergeAgentItemDeltasInOrder(frames)
            checksum &+= UInt64(result.merged.first?.count ?? 0)
            checksum &+= UInt64(result.absorbed.count)
        }
        return checksum
    }

    private func runLegacyBursts(frames: [Data], count: Int) -> UInt64 {
        var checksum: UInt64 = 0
        for _ in 0..<count {
            let merged = legacyMergeInOrder(frames)
            checksum &+= UInt64(merged.first?.count ?? 0)
            checksum &+= UInt64(max(0, frames.count - merged.count))
        }
        return checksum
    }

    private func runLinearPressureBursts(frames: [Data], count: Int) -> UInt64 {
        var checksum: UInt64 = 0
        for _ in 0..<count {
            let coalesced = WebSocketOutboundQueue.coalesceApplicationFrames(frames)
            checksum &+= UInt64(coalesced.first?.count ?? 0)
            checksum &+= UInt64(max(0, frames.count - coalesced.count))
        }
        return checksum
    }

    private func runLegacyPressureBursts(frames: [Data], count: Int) -> UInt64 {
        var checksum: UInt64 = 0
        for _ in 0..<count {
            let coalesced = legacyPressureCoalesce(frames)
            checksum &+= UInt64(coalesced.first?.count ?? 0)
            checksum &+= UInt64(max(0, frames.count - coalesced.count))
        }
        return checksum
    }

    private func makeFrames(_ workload: Workload) throws -> [Data] {
        try (0..<workload.frameCount).map { index in
            let prefix = "\(index):"
            let token = prefix + String(repeating: "x", count: max(0, workload.tokenBytes - prefix.utf8.count))
            return try JSONSerialization.data(withJSONObject: [
                "protocolVersion": 3,
                "type": "event",
                "connectionId": "benchmark-connection",
                "hostId": "benchmark-host",
                "bootEpoch": 7,
                "sequence": index + 1,
                "eventId": "7:\(index + 1)",
                "occurredAtEpochMs": 1_777_777_777_777 + index,
                "kind": "agent.item.delta",
                "payload": [
                    "thread_id": "benchmark-thread",
                    "turn_id": "benchmark-turn",
                    "item_id": "benchmark-item",
                    "body_append": token,
                    "summary": index % 17 == 0 ? "working-\(index)" : NSNull(),
                    "progress": Double(index) / Double(workload.frameCount),
                    "distill_applied": index == 0,
                ] as [String: Any],
            ] as [String: Any])
        }
    }

    private func legacyMergeInOrder(
        _ frames: [Data],
        work: WorkCounter? = nil
    ) -> [Data] {
        var result: [Data] = []
        var pending: Data?

        func flush() {
            if let pending { result.append(pending) }
            pending = nil
        }

        for frame in frames {
            work?.parses += 1
            guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  object["type"] as? String == "event",
                  object["kind"] as? String == "agent.item.delta" else {
                flush()
                result.append(frame)
                continue
            }
            if let current = pending {
                let merged: Data?
                if let work {
                    merged = WebSocketEventBatcher.mergeAgentItemDeltaFrames(
                        current,
                        frame,
                        onParse: { work.parses += 1 },
                        onEncode: { work.encodes += 1 }
                    )
                } else {
                    merged = WebSocketEventBatcher.mergeAgentItemDeltaFrames(current, frame)
                }
                if let merged {
                    pending = merged
                    continue
                }
            }
            flush()
            pending = frame
        }
        flush()
        return result
    }

    private func legacyPressureCoalesce(
        _ frames: [Data],
        work: WorkCounter? = nil
    ) -> [Data] {
        guard !frames.isEmpty else { return [] }
        var result: [Data] = []
        var keySlots: [String: Int] = [:]

        for frame in frames {
            work?.parses += 1
            guard let key = WebSocketOutboundQueue.coalescingKey(for: frame) else {
                result.append(frame)
                continue
            }
            if let index = keySlots[key] {
                if key.hasPrefix("agent.item.delta:") {
                    let merged: Data?
                    if let work {
                        merged = WebSocketEventBatcher.mergeAgentItemDeltaFrames(
                            result[index],
                            frame,
                            onParse: { work.parses += 1 },
                            onEncode: { work.encodes += 1 }
                        )
                    } else {
                        merged = WebSocketEventBatcher.mergeAgentItemDeltaFrames(result[index], frame)
                    }
                    if let merged {
                        result[index] = merged
                    } else {
                        result[index] = frame
                    }
                } else {
                    result[index] = frame
                }
            } else {
                keySlots[key] = result.count
                result.append(frame)
            }
        }
        return result
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func measure(_ body: () -> UInt64) -> (
        wallMilliseconds: Double,
        cpuMilliseconds: Double,
        checksum: UInt64
    ) {
        let cpuStart = CPUTime.current().seconds
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let checksum = body()
        let wallEnd = DispatchTime.now().uptimeNanoseconds
        let cpuEnd = CPUTime.current().seconds
        return (
            Double(wallEnd - wallStart) / 1_000_000,
            (cpuEnd - cpuStart) * 1_000,
            checksum
        )
    }

    private func printSample(
        phase: String,
        workload: Workload,
        sample: Int,
        measurement: (wallMilliseconds: Double, cpuMilliseconds: Double, checksum: UInt64),
        frames: [Data],
        output: Data,
        work: WorkCounter
    ) {
        print(
            "WS_BATCH_BENCH phase=\(phase) workload=\(workload.name) "
                + "sample=\(sample) frames_per_burst=\(workload.frameCount) "
                + "bursts=\(workload.burstsPerSample) wall_ms=\(format(measurement.wallMilliseconds)) "
                + "cpu_ms=\(format(measurement.cpuMilliseconds)) "
                + "input_bytes_per_burst=\(frames.reduce(0) { $0 + $1.count }) "
                + "output_bytes_per_burst=\(output.count) "
                + "full_frame_encodes_per_burst=\(work.encodes) "
                + "full_frame_parses_per_burst=\(work.parses) "
                + "output_fnv1a64=\(String(fnv1a64(output), radix: 16)) "
                + "checksum=\(measurement.checksum)"
        )
    }

    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func formatted(_ values: [Double]) -> String {
        "[" + values.map(format).joined(separator: ",") + "]"
    }

    private func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}
