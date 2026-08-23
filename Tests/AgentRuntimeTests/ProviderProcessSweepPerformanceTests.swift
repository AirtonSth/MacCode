import XCTest
import Darwin
@testable import AgentRuntime

final class ProviderProcessSweepPerformanceTests: XCTestCase {
    private struct Sample {
        let wallMilliseconds: Double
        let cpuMilliseconds: Double
        let groupEnumerations: Int
        let result: ProviderProcessSweepResult
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    /// Same-process A/B of the pre-checkpoint eager enumeration and production's
    /// lazy sweep. Primary metric: wall time for live exact current-owner rows;
    /// process CPU is reported as a corroborating metric (warmup=2, n=7).
    func test_microbench_liveCurrentOwnerRows_skipPerTagProcessTableEnumeration() throws {
        let warmup = 2
        let samples = 7
        let sweepsPerSample = 8
        let currentPID: pid_t = 700
        let ownerIdentity = ProviderProcessStartIdentity(seconds: 1, microseconds: 1)
        let rootIdentity = ProviderProcessStartIdentity(seconds: 2, microseconds: 1)

        for tagCount in [1, 8, 32] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("provider-sweep-perf-\(tagCount)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ProviderProcessOwnershipStore(fileURL: directory.appendingPathComponent("ownership.json"))
            let tags = (0..<tagCount).map { offset in
                let pid = pid_t(30_000 + offset)
                return SpawnedProcessTag(
                    pgid: pid,
                    spawnedAt: Date(timeIntervalSince1970: 100),
                    ownerPID: currentPID,
                    ownerStartIdentity: ownerIdentity,
                    provider: .codex,
                    managedKind: .provider,
                    executablePath: "/opt/codex",
                    startIdentity: rootIdentity,
                    isolatedProcessGroup: pid
                )
            }
            try store.replace(tags)

            func measure(eagerLegacyEnumeration: Bool) throws -> Sample {
                var enumerations = 0
                let processGroupMembers: (pid_t) -> [pid_t] = { group in
                    enumerations += 1
                    return ProcessTerminator.processGroupPIDs(group)
                }
                let cpuStart = processCPUSeconds()
                let wallStart = DispatchTime.now().uptimeNanoseconds
                var result = ProviderProcessSweepResult(
                    orphanRootPIDs: [],
                    terminatedPIDs: [],
                    failedPIDs: []
                )
                for _ in 0..<sweepsPerSample {
                    if eagerLegacyEnumeration {
                        // Exact removed work: the old loop loaded verified group
                        // members before checking the current owner/root fast path.
                        for tag in tags {
                            _ = processGroupMembers(tag.pgid)
                        }
                    }
                    result = try ProviderProcessSweeper.sweepPersistedOrphans(
                        store: store,
                        currentPID: currentPID,
                        minAge: 0,
                        ownerIsAlive: { _ in true },
                        ownerStartIdentity: { _ in ownerIdentity },
                        processCommand: { _ in nil },
                        processStartIdentity: { _ in rootIdentity },
                        descendantPIDs: { _ in [] },
                        processGroupMembers: processGroupMembers,
                        processIsAlive: { _ in true },
                        graceInterval: 0,
                        wait: { _ in },
                        sendSignal: { _, _ in false }
                    )
                }
                let wallEnd = DispatchTime.now().uptimeNanoseconds
                let cpuEnd = processCPUSeconds()
                return Sample(
                    wallMilliseconds: Double(wallEnd - wallStart) / 1_000_000,
                    cpuMilliseconds: (cpuEnd - cpuStart) * 1_000,
                    groupEnumerations: enumerations,
                    result: result
                )
            }

            for _ in 0..<warmup {
                _ = try measure(eagerLegacyEnumeration: true)
                _ = try measure(eagerLegacyEnumeration: false)
            }
            var before: [Sample] = []
            var after: [Sample] = []
            for sampleIndex in 0..<samples {
                if sampleIndex.isMultiple(of: 2) {
                    before.append(try measure(eagerLegacyEnumeration: true))
                    after.append(try measure(eagerLegacyEnumeration: false))
                } else {
                    after.append(try measure(eagerLegacyEnumeration: false))
                    before.append(try measure(eagerLegacyEnumeration: true))
                }
            }

            let beforeWall = median(before.map(\.wallMilliseconds))
            let afterWall = median(after.map(\.wallMilliseconds))
            let beforeCPU = median(before.map(\.cpuMilliseconds))
            let afterCPU = median(after.map(\.cpuMilliseconds))
            let wallImprovement = (beforeWall - afterWall) / beforeWall * 100
            let cpuImprovement = beforeCPU > 0 ? (beforeCPU - afterCPU) / beforeCPU * 100 : 0
            let expectedLegacyEnumerations = tagCount * sweepsPerSample
            let expectedResult = ProviderProcessSweepResult(
                orphanRootPIDs: [],
                terminatedPIDs: [],
                failedPIDs: []
            )

            XCTAssertTrue(before.allSatisfy { $0.groupEnumerations == expectedLegacyEnumerations })
            XCTAssertTrue(after.allSatisfy { $0.groupEnumerations == 0 })
            XCTAssertTrue(before.allSatisfy { $0.result == expectedResult })
            XCTAssertTrue(after.allSatisfy { $0.result == expectedResult })
            XCTAssertEqual(try store.load(), tags, "A/B sweeps must make identical ledger decisions")
            NSLog(
                "[perf-proof] providerSweep tags=%d sweeps=%d eager_wall_ms=%@ lazy_wall_ms=%@ wall_improvement_pct=%.2f eager_cpu_ms=%@ lazy_cpu_ms=%@ cpu_improvement_pct=%.2f eager_enumerations=%d lazy_enumerations=0 before_wall=%@ after_wall=%@ before_cpu=%@ after_cpu=%@",
                tagCount, sweepsPerSample,
                String(beforeWall), String(afterWall), wallImprovement,
                String(beforeCPU), String(afterCPU), cpuImprovement,
                expectedLegacyEnumerations,
                String(describing: before.map(\.wallMilliseconds)),
                String(describing: after.map(\.wallMilliseconds)),
                String(describing: before.map(\.cpuMilliseconds)),
                String(describing: after.map(\.cpuMilliseconds))
            )
            XCTAssertGreaterThan(
                wallImprovement,
                5,
                "lazy group enumeration must improve the live-root sweep by >5% for \(tagCount) tags"
            )
        }
    }
}
