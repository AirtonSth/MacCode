import XCTest
import CoreModel
import Darwin
import DistillCore
@testable import Persistence
@testable import AgentRuntime

/// Lifecycle begin/end + fail-open semantics for nested provider receipts.
/// Mirrors what `ProviderProxyRunner` does against the orchestration DB without
/// spawning provider CLIs.
final class ProviderProxyLifecycleTests: XCTestCase {
    private func makeRuntime(appSupport: String) throws -> (AgentOrchestrationRuntime, AgentOrchestrationRepository) {
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let repo = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: repo,
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false }
        )
        return (runtime, repo)
    }

    func test_beginEnd_recordsCompletedFailedCancelled() throws {
        // WHY: Subagents UI needs a single finalized receipt per nested provider run.
        let appSupport = NSTemporaryDirectory() + "RC2ProvProxyLife-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (runtime, repo) = try makeRuntime(appSupport: appSupport)
        let threadId = AgentThreadID()
        let parentRunId = AgentRunID()
        let parentCapability = AgentDelegationCapability.issue()
        _ = try runtime.recordExternalRoot(
            runId: parentRunId,
            threadId: threadId,
            provider: .codex,
            providerInstanceId: "codex",
            model: "gpt",
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                parentCapability
            )
        )

        for (status, label) in [
            (AgentRunStatus.completed, "ok"),
            (AgentRunStatus.failed, "fail"),
            (AgentRunStatus.cancelled, "cancel"),
        ] as [(AgentRunStatus, String)] {
            let runId = AgentRunID()
            let nodeId = ProviderProxyPolicy.makeNodeId(
                providerBasename: "grok",
                processIdentifier: 9,
                monotonicNanos: UInt64(label.hashValue.magnitude)
            )
            _ = try runtime.recordAuthorizedExternalChild(
                runId: runId,
                threadId: threadId,
                provider: .grok,
                providerInstanceId: "grok",
                model: "unknown",
                nodeId: nodeId,
                parentRunId: parentRunId,
                parentThreadId: threadId,
                parentCapability: parentCapability,
                childCapability: AgentDelegationCapability.issue(),
                requestedPermissionMode: .fullAccess
            )
            try runtime.finalizeReceipt(runId: runId, status: status)
            let receipt = try XCTUnwrap(try repo.receipt(runId: runId))
            XCTAssertEqual(receipt.lifecycleStatus, .finalized)
            XCTAssertEqual(receipt.finalRunStatus, status)
            // Second finalize is a no-op (exactly-once).
            try runtime.finalizeReceipt(runId: runId, status: .failed)
            let again = try XCTUnwrap(try repo.receipt(runId: runId))
            XCTAssertEqual(again.finalRunStatus, status, "finalize must stick to the first terminal status")
        }
    }

    func test_failOpen_whenScopeMissing_skipsReceipt() {
        // WHY: proxy without thread scope must not invent a Subagents row.
        XCTAssertFalse(ProviderProxyPolicy.hasTelemetryScope(environment: [
            "REMOTE_CODE_AGENT_PROVIDER": "codex",
            "PATH": "/usr/bin"
        ]))
    }

    func test_statusMapping_usedForReceiptFinalization() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvProxyStatus-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (runtime, repo) = try makeRuntime(appSupport: appSupport)
        let threadId = AgentThreadID()
        let parentRunId = AgentRunID()
        let parentCapability = AgentDelegationCapability.issue()
        _ = try runtime.recordExternalRoot(
            runId: parentRunId,
            threadId: threadId,
            provider: .codex,
            providerInstanceId: "codex",
            model: "gpt",
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                parentCapability
            )
        )
        let cases: [(Bool, Int32, AgentRunStatus)] = [
            (false, 0, .completed),
            (false, 1, .failed),
            (true, SIGINT, .cancelled),
            (true, SIGTERM, .cancelled),
        ]
        for (wasSignal, code, expected) in cases {
            let runId = AgentRunID()
            let nodeId = ProviderProxyPolicy.makeNodeId(
                providerBasename: "claude",
                processIdentifier: Int32(abs(code) + 1),
                monotonicNanos: UInt64(bitPattern: Int64(code)) &+ 1
            )
            _ = try runtime.recordAuthorizedExternalChild(
                runId: runId,
                threadId: threadId,
                provider: .claude,
                providerInstanceId: "claude",
                model: "test",
                nodeId: nodeId,
                parentRunId: parentRunId,
                parentThreadId: threadId,
                parentCapability: parentCapability,
                childCapability: AgentDelegationCapability.issue(),
                requestedPermissionMode: .fullAccess
            )
            let mapped = ProviderProxyPolicy.runStatus(
                wasUncaughtSignal: wasSignal,
                terminationStatus: code
            )
            XCTAssertEqual(mapped, expected)
            try runtime.finalizeReceipt(runId: runId, status: mapped)
            XCTAssertEqual(try repo.receipt(runId: runId)?.finalRunStatus, expected)
        }
    }
}
