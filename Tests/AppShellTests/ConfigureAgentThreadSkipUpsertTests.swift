import XCTest
@testable import AppShell
import CoreModel
import Persistence

/// WHY: every send called configureAgentThread which upserted the 26-column
/// row plus routing JSON even when picker/permission/run-as-user did not
/// change, and real picker mutations still rewrote title/status/unread/color
/// /pin/execution plus routing JSON.
@MainActor
final class ConfigureAgentThreadSkipUpsertTests: XCTestCase {
    func test_configureAgentThread_sourceSkipsNoOpUpsert() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppCommandRouter.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func configureAgentThread("))
        let end = try XCTUnwrap(source.range(of: "public func configureAgentThreadRouting("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadConfigUnchanged"))
        XCTAssertTrue(body.contains("func threadHasStarted()"))
        XCTAssertTrue(body.contains("guard !threadHasStarted()"))
        XCTAssertTrue(body.contains("threadWithoutRouting(of: thread)"))
        XCTAssertTrue(body.contains("setPickerConfig("))
        XCTAssertTrue(body.contains("updateProviderThreadId("))
        XCTAssertTrue(body.contains("routingConfiguration(of: thread)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: thread)"))
        XCTAssertFalse(body.contains("threadRepo.upsert(t)"))
        let skip = try XCTUnwrap(body.range(of: "threadConfigUnchanged"))
        let picker = try XCTUnwrap(body.range(of: "setPickerConfig("))
        XCTAssertLessThan(skip.lowerBound, picker.lowerBound)
        let attach = try XCTUnwrap(body.range(of: "routingConfiguration(of: thread)"))
        XCTAssertLessThan(picker.lowerBound, attach.lowerBound)
    }

    func test_configureAgentThread_sameConfigDoesNotRewriteUpdatedAtOrRouting() throws {
        let (ctx, router) = try makeRouter()
        var thread = AgentThread(
            title: "cfg",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised
        )
        thread.color = "purple"
        thread.pinned = true
        thread.hasUnread = true
        thread.executionMode = .worktree
        thread.baseBranch = "main"
        thread.worktreePath = "/tmp/wt"
        thread.status = .running
        thread.providerThreadId = "sess-keep"
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try ctx.threadRepo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.threadWithoutRoutingProbeCountForTesting
        let first = try router.configureAgentThread(
            thread: thread.id,
            provider: nil,
            model: nil,
            permissionMode: .supervised,
            reasoningEffort: nil
        )
        XCTAssertNil(first.routingConfiguration)
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertEqual(ctx.threadRepo.threadWithoutRoutingProbeCountForTesting, probesBefore + 1)
        let updatedAt = first.updatedAt
        let second = try router.configureAgentThread(
            thread: thread.id,
            provider: nil,
            model: nil,
            permissionMode: .supervised,
            reasoningEffort: nil
        )
        XCTAssertEqual(second.permissionMode, .supervised)
        XCTAssertEqual(second.updatedAt, updatedAt)
        XCTAssertNil(second.routingConfiguration)
        let stored = try XCTUnwrap(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(stored.updatedAt, updatedAt)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)

        let pickersBefore = ctx.threadRepo.setPickerConfigCountForTesting
        let cursorsBefore = ctx.threadRepo.updateProviderThreadIdCountForTesting
        let getsBeforeMutation = ctx.threadRepo.durableGetCountForTesting
        let mutated = try router.configureAgentThread(
            thread: thread.id,
            provider: nil,
            model: nil,
            permissionMode: .fullAccess,
            reasoningEffort: nil
        )
        XCTAssertEqual(mutated.permissionMode, .fullAccess)
        XCTAssertNotEqual(mutated.updatedAt, updatedAt)
        XCTAssertEqual(mutated.routingConfiguration?.policyDigest, digest)
        XCTAssertEqual(mutated.providerThreadId, "sess-keep")
        XCTAssertEqual(ctx.threadRepo.setPickerConfigCountForTesting, pickersBefore + 1)
        XCTAssertEqual(ctx.threadRepo.updateProviderThreadIdCountForTesting, cursorsBefore)
        XCTAssertEqual(ctx.threadRepo.durableGetCountForTesting, getsBeforeMutation)
        let storedMutated = try XCTUnwrap(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(storedMutated.permissionMode, .fullAccess)
        XCTAssertEqual(storedMutated.title, "cfg")
        XCTAssertEqual(storedMutated.color, "purple")
        XCTAssertTrue(storedMutated.pinned)
        XCTAssertTrue(storedMutated.hasUnread)
        XCTAssertEqual(storedMutated.executionMode, .worktree)
        XCTAssertEqual(storedMutated.baseBranch, "main")
        XCTAssertEqual(storedMutated.worktreePath, "/tmp/wt")
        XCTAssertEqual(storedMutated.status, .running)
        XCTAssertEqual(storedMutated.providerThreadId, "sess-keep")
        XCTAssertEqual(storedMutated.routingConfiguration?.policyDigest, digest)

        let cleared = try router.configureAgentThread(
            thread: thread.id,
            provider: nil,
            model: "other-model",
            permissionMode: .fullAccess,
            reasoningEffort: nil
        )
        XCTAssertEqual(cleared.model, "other-model")
        XCTAssertNil(cleared.providerThreadId)
        XCTAssertEqual(cleared.routingConfiguration?.policyDigest, digest)
        XCTAssertEqual(ctx.threadRepo.updateProviderThreadIdCountForTesting, cursorsBefore + 1)
        let storedCleared = try XCTUnwrap(try ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(storedCleared.model, "other-model")
        XCTAssertNil(storedCleared.providerThreadId)
        XCTAssertEqual(storedCleared.title, "cfg")
        XCTAssertEqual(storedCleared.status, .running)
        XCTAssertEqual(storedCleared.routingConfiguration?.policyDigest, digest)
    }

    func test_configureNoOp_fasterThanGetAndUpsert() throws {
        let (ctx, router) = try makeRouter()
        var thread = AgentThread(
            title: "bench",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised
        )
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try ctx.threadRepo.upsert(thread)
        _ = try router.configureAgentThread(
            thread: thread.id,
            provider: nil,
            model: nil,
            permissionMode: .supervised,
            reasoningEffort: nil
        )
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
            _ = try router.configureAgentThread(
                thread: thread.id,
                provider: nil,
                model: nil,
                permissionMode: .supervised,
                reasoningEffort: nil
            )
            if var copy = try ctx.threadRepo.get(id: thread.id) {
                copy.updatedAt = Date()
                try ctx.threadRepo.upsert(copy)
            }
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try router.configureAgentThread(
                        thread: thread.id,
                        provider: nil,
                        model: nil,
                        permissionMode: .supervised,
                        reasoningEffort: nil
                    )
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try ctx.threadRepo.get(id: thread.id) {
                        copy.updatedAt = Date()
                        try ctx.threadRepo.upsert(copy)
                    }
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] configure-thread-skip-upsert configure_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "no-op configure must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    func test_configureMutation_fasterThanGetAndUpsert() throws {
        let (ctx, router) = try makeRouter()
        var thread = AgentThread(
            title: "bench-mut",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised
        )
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
        func mutate(_ mode: AgentPermissionMode) throws {
            _ = try router.configureAgentThread(
                thread: thread.id,
                provider: nil,
                model: nil,
                permissionMode: mode,
                reasoningEffort: nil
            )
        }
        for _ in 0..<warmup {
            try mutate(.fullAccess)
            try mutate(.supervised)
            if var copy = try ctx.threadRepo.get(id: thread.id) {
                copy.permissionMode = .supervised
                copy.updatedAt = Date()
                try ctx.threadRepo.upsert(copy)
            }
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for i in 0..<iterations {
                    try mutate(i % 2 == 0 ? .fullAccess : .supervised)
                }
            })
            getSamples.append(try timeMs {
                for i in 0..<iterations {
                    if var copy = try ctx.threadRepo.get(id: thread.id) {
                        copy.permissionMode = i % 2 == 0 ? .fullAccess : .supervised
                        copy.updatedAt = Date()
                        try ctx.threadRepo.upsert(copy)
                    }
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] configure-thread-mutation-preserving-thread configure_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "mutation configure must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    func test_threadWithoutRouting_fasterThanDurableGet() throws {
        let (ctx, _) = try makeRouter()
        var thread = AgentThread(
            title: "omit-routing",
            provider: .codex,
            model: "fake-model"
        )
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
            _ = try ctx.threadRepo.threadWithoutRouting(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.threadWithoutRouting(of: thread.id)
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
            "[perf-proof] configure-without-routing omit_ms=%@ get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "threadWithoutRouting must beat get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRouter() throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "rc2-cfg-skip-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }
}
