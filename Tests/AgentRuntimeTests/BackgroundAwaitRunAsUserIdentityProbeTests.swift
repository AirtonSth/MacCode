import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: auto-continue request construction used to full-get 26 columns +
/// routing JSON just to copy `runAsUser` onto the follow-up `AgentRunRequest`.
final class BackgroundAwaitRunAsUserIdentityProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository,
        AgentMessageRepository,
        AgentRunRepository
    ) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentMessageRepository(db: db),
            AgentRunRepository(db: db)
        )
    }

    func test_continuationRequest_usesIdentityProbeWithoutDurableGet() throws {
        let (threadRepo, messageRepo, runRepo) = try makeRepos("bg-await-runasuser")
        let runAsUser = AgentRunAsUser(
            generatedUID: "gid-test",
            shortName: "probeuser",
            uid: 501,
            gid: 20,
            homePath: "/Users/probeuser",
            fullName: "Probe User"
        )
        let thread = AgentThread(
            title: "await",
            provider: .codex,
            model: "fake-model",
            runAsUser: runAsUser
        )
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let getsBefore = threadRepo.durableGetCountForTesting
        let probesBefore = threadRepo.identityProbeCountForTesting
        let request = coordinator.incompleteTurnContinuationRequestForTesting(threadId: thread.id)
        XCTAssertEqual(request.runAsUser, runAsUser)
        XCTAssertEqual(request.permissionMode, .fullAccess)
        XCTAssertEqual(
            threadRepo.identityProbeCountForTesting,
            probesBefore + 1,
            "continuation request must probe identity once for runAsUser"
        )
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore,
            "continuation request must not compile a full 26-column get just to copy runAsUser"
        )

        let missing = coordinator.incompleteTurnContinuationRequestForTesting(threadId: AgentThreadID())
        XCTAssertNil(missing.runAsUser)
        XCTAssertEqual(threadRepo.identityProbeCountForTesting, probesBefore + 2)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
    }

    func test_continuationRequest_sourceUsesIdentityProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "private func incompleteTurnContinuationRequest("))
        let end = try XCTUnwrap(source.range(of: "private func markStartFailure("))
        let body = String(source[range.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.identity(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_backgroundAwait_runAsUserIdentity_fasterThanDurableGet() throws {
        let (threadRepo, _, _) = try makeRepos("bg-await-runasuser-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = try threadRepo.identity(of: thread.id)
            _ = try threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.identity(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] bg-await runAsUser identity_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "identity probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
