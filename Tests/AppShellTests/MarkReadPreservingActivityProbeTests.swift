import XCTest
@testable import AppShell
import CoreModel
import Persistence

/// WHY: open/select compiled the 26-column agent_threads row plus routing
/// JSON then upserted the full row just to clear has_unread, which also
/// hitchs already-read reselects.
@MainActor
final class MarkReadPreservingActivityProbeTests: XCTestCase {
    func test_markAgentThreadRead_sourceUsesMarkReadPreservingActivityNotGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func markAgentThreadRead("))
        let end = try XCTUnwrap(source.range(of: "public func listAgentModels("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.markReadPreservingActivity(of: thread)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: thread)"))
        XCTAssertFalse(body.contains("threadRepo.upsert(t)"))
    }

    func test_markReadPreservingActivity_clearsUnreadWithoutDurableGetOrRoutingRewrite() throws {
        let ctx = try makeContext("match")
        let workspace = WorkspaceID()
        var thread = AgentThread(
            workspaceId: workspace,
            title: "unread",
            provider: .codex,
            model: "fake-model"
        )
        thread.hasUnread = true
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        thread.updatedAt = stamped
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try ctx.threadRepo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let marksBefore = ctx.threadRepo.markReadPreservingActivityCountForTesting

        let cleared = try XCTUnwrap(try ctx.threadRepo.markReadPreservingActivity(of: thread.id))
        XCTAssertTrue(cleared.cleared)
        XCTAssertEqual(cleared.workspaceId, workspace)
        XCTAssertEqual(cleared.updatedAt.timeIntervalSince1970, stamped.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(ctx.threadRepo.markReadPreservingActivityCountForTesting, marksBefore + 1)
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)

        let stored = try XCTUnwrap(try ctx.threadRepo.get(id: thread.id))
        XCTAssertFalse(stored.hasUnread)
        XCTAssertEqual(stored.updatedAt.timeIntervalSince1970, stamped.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)

        let again = try XCTUnwrap(try ctx.threadRepo.markReadPreservingActivity(of: thread.id))
        XCTAssertFalse(again.cleared)
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore + 1)
        XCTAssertNil(try ctx.threadRepo.markReadPreservingActivity(of: AgentThreadID()))
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore + 1)
    }

    func test_markReadPreservingActivity_fasterThanDurableGet() throws {
        let ctx = try makeContext("bench")
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        thread.hasUnread = false
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try ctx.threadRepo.upsert(thread)
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
            _ = try ctx.threadRepo.markReadPreservingActivity(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.markReadPreservingActivity(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] mark-read-preserving-activity markRead_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "markReadPreservingActivity must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeContext(_ label: String) throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc2-mark-read-\(label)-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }
}
