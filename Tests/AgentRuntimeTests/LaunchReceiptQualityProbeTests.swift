import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: launch receipt reconcile still full-got the 10-column agent_runs row
/// and hydrated every `agent_messages` blob just to stamp quality/usage.
final class LaunchReceiptQualityProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: AgentOrchestrationRuntime.rolloutFlagKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AgentOrchestrationRuntime.rolloutFlagKey)
        super.tearDown()
    }

    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository,
        AgentMessageRepository,
        AgentRunRepository,
        AgentOrchestrationRepository
    ) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentMessageRepository(db: db),
            AgentRunRepository(db: db),
            AgentOrchestrationRepository(db: db)
        )
    }

    private func coordinator(
        threadRepo: AgentThreadRepository,
        messageRepo: AgentMessageRepository,
        runRepo: AgentRunRepository,
        receipts: AgentOrchestrationRepository
    ) -> AgentRunCoordinator {
        AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            orchestrationRuntime: AgentOrchestrationRuntime(
                repository: receipts,
                packageVerification: { true },
                rolloutGate: { true },
                killSwitch: { false }
            ),
            providers: [:]
        )
    }

    private func seedCompletedReceipt(
        threadRepo: AgentThreadRepository,
        messageRepo: AgentMessageRepository,
        runRepo: AgentRunRepository,
        receipts: AgentOrchestrationRepository,
        assistantContent: String,
        extraUserMessages: Int = 0,
        userPayload: String = "u"
    ) throws -> (AgentThread, AgentRunID) {
        var thread = AgentThread(title: "launch-quality", provider: .codex, model: "fake-model")
        thread.status = .completed
        try threadRepo.upsert(thread)
        let runId = AgentRunID()
        try runRepo.upsert(AgentRun(
            id: runId,
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .completed,
            finishedAt: Date(),
            errorMessage: String(repeating: "e", count: 32 * 1024)
        ))
        if extraUserMessages > 0 {
            let created = Date().addingTimeInterval(-Double(extraUserMessages))
            for index in 0..<extraUserMessages {
                try messageRepo.append(AgentMessage(
                    threadId: thread.id,
                    role: .user,
                    content: userPayload,
                    createdAt: created.addingTimeInterval(TimeInterval(index))
                ))
            }
        }
        try messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .assistant,
            content: assistantContent
        ))
        let runtime = AgentOrchestrationRuntime(
            repository: receipts,
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false }
        )
        _ = try runtime.recordExternalRoot(
            runId: runId,
            threadId: thread.id,
            provider: .codex,
            providerInstanceId: "codex",
            model: "fake-model",
            permissionMode: .supervised,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                "launch-quality:\(runId.value.uuidString)"
            )
        )
        return (thread, runId)
    }

    func test_reconcileOnLaunch_sourceUsesThreadIdAndAssistantOutputProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "try orchestrationRuntime?.reconcileReceipts("))
        let end = try XCTUnwrap(source.range(of: "for thread in try threadRepo.list() where thread.status == .running {"))
        let body = String(source[range.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("runRepo.threadId(of: runId)"))
        XCTAssertTrue(body.contains("messageRepo.hasNonEmptyAssistantMessage(threadId: threadId)"))
        XCTAssertFalse(body.contains("runRepo.get(id: runId)"))
        XCTAssertFalse(body.contains("messageRepo.list(threadId:"))
    }

    func test_reconcileOnLaunch_usesProbesWithoutDurableGetOrFullList() throws {
        let (threadRepo, messageRepo, runRepo, receipts) = try makeRepos("launch-quality")
        let payload = String(repeating: "u", count: 8 * 1024)
        let (_, runId) = try seedCompletedReceipt(
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            runRepo: runRepo,
            receipts: receipts,
            assistantContent: "done",
            extraUserMessages: 24,
            userPayload: payload
        )
        let coordinator = coordinator(
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            runRepo: runRepo,
            receipts: receipts
        )
        let getsBefore = runRepo.durableGetCountForTesting
        let threadIdBefore = runRepo.threadIdProbeCountForTesting
        let listBefore = messageRepo.fullListCountForTesting
        let probeBefore = messageRepo.assistantOutputProbeCountForTesting
        try coordinator.reconcileOnLaunch()
        XCTAssertGreaterThanOrEqual(
            runRepo.threadIdProbeCountForTesting,
            threadIdBefore + 1,
            "launch quality/usage must probe thread_id instead of compiling error_message"
        )
        XCTAssertEqual(
            messageRepo.assistantOutputProbeCountForTesting,
            probeBefore + 1,
            "launch quality must probe assistant output once"
        )
        XCTAssertEqual(
            runRepo.durableGetCountForTesting,
            getsBefore,
            "launch receipt reconcile must not compile a full 10-column get"
        )
        XCTAssertEqual(
            messageRepo.fullListCountForTesting,
            listBefore,
            "launch quality must not hydrate the full message history"
        )
        XCTAssertEqual(
            try receipts.receipt(runId: runId)?.qualityOutcome,
            "verified:output-present"
        )
    }

    func test_assistantOutputProbe_matchesListPresenceWithoutFullList() throws {
        let (threadRepo, messageRepo, _, _) = try makeRepos("launch-quality-match")
        let thread = AgentThread(title: "match", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        try messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: "ask"))
        try messageRepo.append(AgentMessage(threadId: thread.id, role: .assistant, content: "  \n\t  "))
        XCTAssertFalse(try messageRepo.hasNonEmptyAssistantMessage(threadId: thread.id))
        try messageRepo.append(AgentMessage(threadId: thread.id, role: .assistant, content: "reply"))
        let listBefore = messageRepo.fullListCountForTesting
        XCTAssertTrue(try messageRepo.hasNonEmptyAssistantMessage(threadId: thread.id))
        XCTAssertEqual(messageRepo.fullListCountForTesting, listBefore)
        XCTAssertTrue(
            try messageRepo.list(threadId: thread.id).contains {
                $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        )
    }

    func test_assistantOutputProbe_fasterThanFullList() throws {
        let (threadRepo, messageRepo, _, _) = try makeRepos("launch-quality-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "m", count: 32 * 1024)
        let created = Date().addingTimeInterval(-40)
        for index in 0..<40 {
            try messageRepo.append(AgentMessage(
                threadId: thread.id,
                role: .user,
                content: payload,
                createdAt: created.addingTimeInterval(TimeInterval(index))
            ))
        }
        try messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .assistant,
            content: "done",
            createdAt: Date()
        ))
        let warmup = 3
        let samples = 5
        let iterations = 20
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
            _ = try messageRepo.hasNonEmptyAssistantMessage(threadId: thread.id)
            _ = try messageRepo.list(threadId: thread.id)
        }
        var probeSamples: [Double] = []
        var listSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        listSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try messageRepo.hasNonEmptyAssistantMessage(threadId: thread.id)
                }
            })
            listSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try messageRepo.list(threadId: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let listMed = median(listSamples)
        let improvement = (listMed - probeMed) / listMed * 100.0
        NSLog(
            "[perf-proof] launch-quality assistant_probe_ms=%@ full_list_ms=%@ improvement_pct=%.2f probe=%@ list=%@",
            String(probeMed), String(listMed), improvement,
            String(describing: probeSamples),
            String(describing: listSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "assistant output probe must beat full list by ≥5% (got \(improvement)%; probe=\(probeMed)ms list=\(listMed)ms)"
        )
    }
}
