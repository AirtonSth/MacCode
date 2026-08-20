import XCTest
@testable import DistillCore

/// End-to-end proof of the savings-attribution fix: the REAL `distill` CLI binary, run with
/// REMOTE_CODE_AGENT_PROVIDER set (which providerEnvironment now guarantees), records its
/// command-output savings under that provider — NOT "unknown". This is the bug that made the
/// per-provider report show "Claude Saved 0" while 285K sat under "unknown".
final class CLIProviderAttributionTests: XCTestCase {
    private actor RecordCapture {
        private(set) var records: [DistillSavingsRecord] = []
        func add(_ request: DistillRequest, _ response: DistillResponse) {
            if let r = DistillSavingsCalculator.record(for: request, response: response) { records.append(r) }
        }
    }

    func test_cliWithProviderEnvAttributesSavingsToProviderNotUnknown() async throws {
        let capture = RecordCapture()
        let config = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: NSTemporaryDirectory())
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: config,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore()
        ) { request, response, _ in
            await capture.add(request, response)
        }
        let ready = try await server.start()
        defer { server.stop() }

        let session = URLSession(configuration: .ephemeral)
        let recovery = TokenSaverRecoveryRequestContext(
            workspaceID: "workspace-attribution",
            projectID: "project-attribution",
            threadID: "thread-attribution",
            provider: "claude",
            attemptID: "attempt-attribution",
            operationID: "op-attribution",
            invocationID: UUID().uuidString.lowercased()
        )
        let cli = ManagedDistillCLI(
            arguments: ["Did it pass? Return PASS or FAIL only."],
            stdin: Data("build passed\n0 failures\n".utf8),
            state: .init(baseURL: ready.baseURL, authToken: "tok"),
            provider: "claude",
            recoveryContext: recovery,
            distillAdmission: { true }
        ) { request in
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return (data, status)
            } catch {
                return nil
            }
        }
        let result = await cli.run()
        XCTAssertEqual(result.exitCode, 0)

        // onSuccess is awaited before the HTTP response, so by now the record exists.
        let records = await capture.records
        let record = try XCTUnwrap(records.first, "the CLI run must produce a savings record")
        XCTAssertEqual(record.provider, "claude", "REMOTE_CODE_AGENT_PROVIDER=claude => savings attributed to claude, NOT unknown")
        // The mode now folds in the producing engine so the Token Saver breakdown shows
        // savings per technique; the deterministic test runtime tags it accordingly.
        XCTAssertEqual(record.mode, "command-output (deterministic)")
        XCTAssertEqual(record.routeStage, .deterministic)
        XCTAssertGreaterThan(record.savedTokens, 0, "and the saving is recorded")
    }

    func test_resolveProvider_prefersExplicitOverRecovery() {
        // WHY: REMOTE_CODE_AGENT_PROVIDER must win when both are present.
        let resolved = ManagedDistillCLI.resolveProvider(
            explicit: "claude",
            recoveryProvider: "codex"
        )
        XCTAssertEqual(resolved, "claude")
    }

    func test_resolveProvider_fallsBackToRecoveryWhenExplicitMissing() {
        // WHY: recovery-scope provider still attributes savings when env is empty.
        XCTAssertEqual(
            ManagedDistillCLI.resolveProvider(explicit: nil, recoveryProvider: "grok"),
            "grok"
        )
        XCTAssertEqual(
            ManagedDistillCLI.resolveProvider(explicit: "  ", recoveryProvider: "grok"),
            "grok"
        )
    }

    func test_resolveProvider_nilWhenBothMissing() {
        XCTAssertNil(ManagedDistillCLI.resolveProvider(explicit: nil, recoveryProvider: nil))
        XCTAssertNil(ManagedDistillCLI.resolveProvider(explicit: "", recoveryProvider: "  "))
    }
}
