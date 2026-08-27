import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// WHY: Token Saver same-user / persistent scope / env stamp used to full-get
/// 26 columns + routing JSON (often on MainActor) just for workspace, project,
/// model, instance, and run-as-user.
@MainActor
final class TokenSaverIdentityProbeTests: XCTestCase {
    func test_tokenSaverAgentEnvironment_usesIdentityProbeWithoutDurableGet() throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-identity-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }
        let thread = AgentThread(
            projectId: ProjectID(),
            workspaceId: WorkspaceID(),
            title: "identity",
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        try ctx.threadRepo.upsert(thread)
        let getsBefore = ctx.threadRepo.durableGetCountForTesting
        let probesBefore = ctx.threadRepo.identityProbeCountForTesting
        let env = ctx.tokenSaverAgentEnvironment(provider: .codex, threadId: thread.id)
        XCTAssertEqual(env["REMOTE_CODE_AGENT_MODEL"], "fake-model")
        XCTAssertEqual(env["RC_TOKEN_SAVER_WORKSPACE_ID"], thread.workspaceId?.value.uuidString)
        XCTAssertEqual(env["RC_TOKEN_SAVER_PROJECT_ID"], thread.projectId?.value.uuidString)
        XCTAssertEqual(
            ctx.threadRepo.identityProbeCountForTesting,
            probesBefore + 1,
            "env stamp must probe identity once for same-user, scope, and model"
        )
        XCTAssertEqual(
            ctx.threadRepo.durableGetCountForTesting,
            getsBefore,
            "env stamp must not compile a full 26-column get"
        )
        XCTAssertNil(try ctx.threadRepo.identity(of: AgentThreadID()))
    }

    func test_tokenSaverAgentEnvironment_sourceUsesIdentityProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppContext.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "func tokenSaverAgentEnvironment("))
        let end = try XCTUnwrap(source.range(of: "func isNestedAgentWorker("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.identity(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
        let scopeStart = try XCTUnwrap(source.range(of: "private func tokenSaverPersistentScope("))
        let scopeBody = String(source[scopeStart.lowerBound...].prefix(1800))
        XCTAssertFalse(scopeBody.contains("threadRepo.get(id: threadId)"))
        let sameStart = try XCTUnwrap(source.range(of: "private func tokenSaverIsSameUser(threadId: AgentThreadID)"))
        let sameBody = String(source[sameStart.lowerBound...].prefix(700))
        XCTAssertTrue(sameBody.contains("threadRepo.identity(of: threadId)"))
        XCTAssertFalse(sameBody.contains("threadRepo.get(id: threadId)"))
    }

    func test_tokenSaverIdentity_fasterThanDurableGet() throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-identity-bench-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
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
            _ = try ctx.threadRepo.identity(of: thread.id)
            _ = try ctx.threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try ctx.threadRepo.identity(of: thread.id)
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
            "[perf-proof] token-saver identity_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
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
