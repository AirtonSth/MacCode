import XCTest
import CryptoKit
@testable import DistillCore

final class DistillReversibleStoreServiceTests: XCTestCase {
    private final class InMemoryScopedStore: TokenSaverScopedRecoveryStoring, @unchecked Sendable {
        private struct Record {
            let original: Data
            let context: TokenSaverRecoveryRequestContext
            let capability: String
            var state: TokenSaverScopedRecoveryState
            var outcome: TokenSaverScopedDeliveryOutcome
        }
        private let lock = NSLock()
        private var records: [String: Record] = [:]
        private var operationIDs: [String] = []
        private var lastCapability = ""
        private(set) var preparedLane: String?
        /// Test seam: force prepareOriginal to throw so command-output unscoped fallback runs.
        var failPrepare = false

        private struct ForcedPrepareError: Error {}

        var capability: String {
            lock.lock(); defer { lock.unlock() }
            return lastCapability
        }

        func lookupInvocation(context: TokenSaverRecoveryRequestContext) throws -> TokenSaverScopedInvocationState? {
            lock.lock(); defer { lock.unlock() }
            guard let record = records[context.invocationID] else { return nil }
            return .init(state: record.state, transportOutcome: record.outcome)
        }

        func prepareOriginal(_ data: Data, context: TokenSaverRecoveryRequestContext, lane: String) throws -> TokenSaverScopedPreparation {
            lock.lock(); defer { lock.unlock() }
            if failPrepare { throw ForcedPrepareError() }
            operationIDs.append(context.operationID)
            preparedLane = lane
            let capability = "rcv1.\(UUID().uuidString.lowercased()).\(UUID().uuidString.lowercased())"
            lastCapability = capability
            records[context.invocationID] = .init(
                original: data,
                context: context,
                capability: capability,
                state: .prepared,
                outcome: .notSent
            )
            return .init(capability: capability, idempotencyKey: context.invocationID, readBackVerified: true)
        }

        func retrieveOriginal(capability: String, context: TokenSaverRecoveryRequestContext) throws -> Data? {
            lock.lock(); defer { lock.unlock() }
            guard let record = records.values.first(where: { $0.capability == capability }),
                  context.workspaceID == record.context.workspaceID,
                  context.projectID == record.context.projectID,
                  context.threadID == record.context.threadID,
                  context.provider == record.context.provider,
                  context.attemptID == record.context.attemptID else { return nil }
            return record.original
        }

        func markDelivered(capability: String, idempotencyKey: String, context: TokenSaverRecoveryRequestContext, outcome: TokenSaverScopedDeliveryOutcome) throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard var record = records[context.invocationID], record.capability == capability,
                  idempotencyKey == context.invocationID, outcome == .sentUnknown else { return false }
            record.state = .delivered
            record.outcome = outcome
            records[context.invocationID] = record
            return true
        }

        func ack(capability: String, idempotencyKey: String, context: TokenSaverRecoveryRequestContext) throws -> Bool { true }

        var preparedOperationIDs: [String] {
            lock.lock(); defer { lock.unlock() }
            return operationIDs
        }

        var preparationCount: Int {
            lock.lock(); defer { lock.unlock() }
            return records.count
        }
    }
    /// In-memory CCR store for the HTTP boundary test (no Persistence dependency).
    private final class InMemoryReversibleStore: ReversibleStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var blobs: [String: Data] = [:]
        private(set) var storeCount = 0

        func storeOriginal(_ data: Data) throws -> String {
            let handle = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            lock.lock(); defer { lock.unlock() }
            blobs[handle] = data
            storeCount += 1
            return handle
        }

        func retrieveOriginal(_ handle: String) throws -> Data? {
            lock.lock(); defer { lock.unlock() }
            return blobs[handle]
        }
    }

    /// Runtime that discards its input — proves the original is recoverable even
    /// when the runtime returns something lossy/unrelated (store happens upstream).
    private struct DiscardingRuntime: DistillRuntime {
        func distill(_ request: DistillRequest) async throws -> String { "X" }
    }

    private actor CountingRuntime: DistillRuntime {
        private(set) var calls = 0
        let transform: @Sendable (String) -> String

        init(transform: @escaping @Sendable (String) -> String) {
            self.transform = transform
        }

        func distill(_ request: DistillRequest) async throws -> String {
            calls += 1
            return transform(request.input)
        }
    }

    private struct Retrieved: Decodable {
        let handle: String
        let found: Bool
        let original: String?
    }

    func test_legacyStoreBeforeLossPath_isQuarantinedUntilScopedRecoveryShips() async throws {
        let store = InMemoryReversibleStore()
        let configuration = try DistillServiceConfiguration(
            authToken: "tok",
            appSupportDirectory: NSTemporaryDirectory()
        )
        let scheduler = DistillScheduler(runtime: DiscardingRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            reversibleStore: store,
            reversibleStoreMinBytes: 1_024
        )
        let ready = try await server.start()
        defer { server.stop() }

        let big = String(repeating: "log line of stuff with detail\n", count: 1_200) // ~36k > 24k
        XCTAssertGreaterThan(big.utf8.count, 24_000)
        let request = DistillRequest(mode: .longText, input: big, maxOutputCharacters: 4_000)
        let body = try JSONEncoder().encode(request)

        let distill = try await http(ready.baseURL + "/v1/distill", method: "POST", token: "tok", body: body)
        XCTAssertEqual(distill.status, 200)
        let response = try JSONDecoder().decode(DistillResponse.self, from: distill.data)
        XCTAssertEqual(response.output, big, "unscoped recovery containment must preserve the provider input byte-for-byte")
        XCTAssertNil(response.originalHandle, "legacy raw hashes remain quarantined")
        XCTAssertEqual(store.storeCount, 0, "containment must not create new unscoped rows")
    }

    func test_smallInputIsNotStored_andUnknownHandleReturns404() async throws {
        let store = InMemoryReversibleStore()
        let configuration = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: NSTemporaryDirectory())
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            reversibleStore: store,
            reversibleStoreMinBytes: 1_024
        )
        let ready = try await server.start()
        defer { server.stop() }

        let request = DistillRequest(mode: .longText, input: "tiny input", maxOutputCharacters: 200)
        let body = try JSONEncoder().encode(request)
        let distill = try await http(ready.baseURL + "/v1/distill", method: "POST", token: "tok", body: body)
        XCTAssertEqual(distill.status, 200)
        let response = try JSONDecoder().decode(DistillResponse.self, from: distill.data)
        XCTAssertNil(response.originalHandle, "small inputs are not worth storing")
        XCTAssertEqual(store.storeCount, 0)

        let retrieve = try await http(ready.baseURL + "/v1/retrieve/deadbeef", token: "tok")
        XCTAssertEqual(retrieve.status, 403, "raw hashes default-deny before lookup")
    }

    func test_retrieveRequiresBearerToken() async throws {
        let store = InMemoryReversibleStore()
        let configuration = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: NSTemporaryDirectory())
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler, reversibleStore: store)
        let ready = try await server.start()
        defer { server.stop() }

        let retrieve = try await http(ready.baseURL + "/v1/retrieve/whatever") // no token
        XCTAssertEqual(retrieve.status, 401)
    }

    func test_optimizeWithoutAnyRecoveryStoreAlwaysReturnsVerbatim() async throws {
        let configuration = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: NSTemporaryDirectory())
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: DiscardingRuntime(), maxConcurrentRequests: 2)
        )
        let ready = try await server.start()
        defer { server.stop() }
        let original = "must survive nil recovery store"

        let result = try await http(
            ready.baseURL + "/v1/distill",
            method: "POST",
            token: "tok",
            body: try JSONEncoder().encode(DistillRequest(mode: .longText, input: original, runMode: .optimize))
        )
        let response = try JSONDecoder().decode(DistillResponse.self, from: result.data)
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(response.output, original)
        XCTAssertNil(response.originalHandle)
    }

    /// WHY: after a scoped prepare failure (opt-out / kill / retention deny),
    /// the server must NOT fall through to unscoped storage — that would bypass
    /// project governance and emit unrecoverable lossy output.
    func test_commandOutputOptimize_scopedPrepareFailure_doesNotBypassWithUnscopedStore() async throws {
        let unscoped = InMemoryReversibleStore()
        let scoped = InMemoryScopedStore()
        scoped.failPrepare = true
        let configuration = try DistillServiceConfiguration(
            authToken: "tok",
            appSupportDirectory: NSTemporaryDirectory()
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: DiscardingRuntime(), maxConcurrentRequests: 2),
            reversibleStore: unscoped,
            scopedRecoveryStore: scoped,
            reversibleStoreMinBytes: 1
        )
        let ready = try await server.start()
        defer { server.stop() }

        let original = "must stay verbatim when scoped prepare is denied"
        let scopeHeaders = [
            "X-RemoteCode-Workspace-ID": "workspace",
            "X-RemoteCode-Project-ID": "project",
            "X-RemoteCode-Thread-ID": "thread",
            "X-RemoteCode-Provider": "codex",
            "X-RemoteCode-Attempt-ID": "attempt",
            "X-RemoteCode-Invocation-ID": "invocation-deny",
            "X-RemoteCode-Operation-ID": "operation-deny",
        ]
        let distill = try await http(
            ready.baseURL + "/v1/distill",
            method: "POST",
            token: "tok",
            body: try JSONEncoder().encode(DistillRequest(
                mode: .commandOutput,
                input: original,
                runMode: .optimize,
                maxOutputCharacters: 64
            )),
            headers: scopeHeaders
        )
        let response = try JSONDecoder().decode(DistillResponse.self, from: distill.data)
        XCTAssertEqual(response.output, original, "governance deny must fail open to the exact original")
        XCTAssertNil(response.originalHandle)
        XCTAssertEqual(unscoped.storeCount, 0, "must not write unscoped after scoped prepare failure")
    }

    /// WHY: residual content-addressed SHA rows must NOT be served just because
    /// any non-empty scope headers are present — that is not scope-bound authz.
    func test_residualUnscopedSHA_isNotServedEvenWithFabricatedScope() async throws {
        let unscoped = InMemoryReversibleStore()
        let seeded = "historical unscoped original"
        let handle = try unscoped.storeOriginal(Data(seeded.utf8))
        let configuration = try DistillServiceConfiguration(
            authToken: "tok",
            appSupportDirectory: NSTemporaryDirectory()
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 1),
            reversibleStore: unscoped,
            scopedRecoveryStore: InMemoryScopedStore()
        )
        let ready = try await server.start()
        defer { server.stop() }

        let bare = try await http(ready.baseURL + "/v1/retrieve/\(handle)", token: "tok")
        XCTAssertEqual(bare.status, 403)

        let scoped = try await http(
            ready.baseURL + "/v1/retrieve/\(handle)",
            token: "tok",
            headers: [
                "X-RemoteCode-Workspace-ID": "workspace",
                "X-RemoteCode-Project-ID": "project",
                "X-RemoteCode-Thread-ID": "thread",
                "X-RemoteCode-Provider": "codex",
                "X-RemoteCode-Attempt-ID": "attempt",
            ]
        )
        XCTAssertEqual(scoped.status, 404, "SHA rows are not scope-bound; do not serve them")
        let bodyText = String(data: scoped.data, encoding: .utf8) ?? ""
        XCTAssertFalse(bodyText.contains(seeded))
    }

    func test_scopedOptimizeEmitsCapabilityAndManagedCLIRetrievesWithExactFiveFieldScope() async throws {
        let store = InMemoryScopedStore()
        let configuration = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: NSTemporaryDirectory())
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: DiscardingRuntime(), maxConcurrentRequests: 2),
            scopedRecoveryStore: store
        )
        let ready = try await server.start()
        defer { server.stop() }
        let scopeHeaders = [
            "X-RemoteCode-Workspace-ID": "workspace",
            "X-RemoteCode-Project-ID": "project",
            "X-RemoteCode-Thread-ID": "thread",
            "X-RemoteCode-Provider": "codex",
            "X-RemoteCode-Attempt-ID": "attempt",
            "X-RemoteCode-Invocation-ID": "invocation",
            "X-RemoteCode-Operation-ID": "operation",
        ]
        let original = "byte exact provider input"
        let request = DistillRequest(mode: .commandOutput, input: original, runMode: .optimize)
        let response = try await http(
            ready.baseURL + "/v1/distill",
            method: "POST",
            token: "tok",
            body: try JSONEncoder().encode(request),
            headers: scopeHeaders
        )
        XCTAssertEqual(response.status, 200)
        let distilled = try JSONDecoder().decode(DistillResponse.self, from: response.data)
        XCTAssertEqual(distilled.output, "X")
        XCTAssertEqual(distilled.originalHandle, store.capability)
        XCTAssertEqual(distilled.recoveryIdempotencyKey, "invocation")
        XCTAssertEqual(
            try JSONDecoder().decode(DistillResponse.self, from: JSONEncoder().encode(distilled)),
            distilled,
            "the optional recovery mutation identity must round-trip without breaking old response fields"
        )
        XCTAssertEqual(store.preparedLane, "deterministic_wrapper")

        let cli = ManagedDistillCLI(
            arguments: ["retrieve", store.capability],
            stdin: Data(),
            state: .init(baseURL: ready.baseURL, authToken: "tok")
        ) { request in
            var scoped = request
            for (header, value) in scopeHeaders where header != "X-RemoteCode-Operation-ID" {
                scoped.setValue(value, forHTTPHeaderField: header)
            }
            guard let result = try? await URLSession.shared.data(for: scoped) else { return nil }
            return (result.0, (result.1 as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let retrieved = await cli.run()
        XCTAssertEqual(retrieved.exitCode, 0)
        XCTAssertEqual(retrieved.stdout, Data(original.utf8))

        let client = DistillServiceClient(baseURL: URL(string: ready.baseURL)!, authToken: "tok")
        let clientOriginal = "semantic client input"
        let clientRequest = DistillRequest(mode: .longText, input: clientOriginal, runMode: .optimize)
        let clientContext = TokenSaverRecoveryRequestContext(
            workspaceID: "workspace", projectID: "project", threadID: "thread",
            provider: "codex", attemptID: "attempt", operationID: "semantic-prefix"
        )
        let clientResponse = try await client.distill(
            clientRequest,
            recoveryContext: clientContext
        )
        XCTAssertEqual(clientResponse.output, "X")
        XCTAssertEqual(clientResponse.originalHandle, store.capability)
        XCTAssertEqual(store.preparedLane, "semantic_prose")
        let terminalRetry = try await client.distill(clientRequest, recoveryContext: clientContext)
        XCTAssertEqual(terminalRetry.output, clientOriginal)
        XCTAssertNil(terminalRetry.originalHandle)
        _ = try await client.distill(
            DistillRequest(mode: .longText, input: "different semantic input", runMode: .optimize),
            recoveryContext: clientContext
        )
        let clientOperations = Array(store.preparedOperationIDs.suffix(2))
        XCTAssertNotEqual(clientOperations[0], clientOperations[1])
        XCTAssertTrue(clientOperations[0].hasPrefix("semantic-prefix:tscli1."))

        var wrongScope = scopeHeaders
        wrongScope["X-RemoteCode-Thread-ID"] = "other-thread"
        wrongScope.removeValue(forKey: "X-RemoteCode-Operation-ID")
        let denied = try await http(
            ready.baseURL + "/v1/retrieve/\(store.capability)", token: "tok", headers: wrongScope
        )
        XCTAssertEqual(denied.status, 404)
        let missing = try await http(ready.baseURL + "/v1/retrieve/\(store.capability)", token: "tok")
        XCTAssertEqual(missing.status, 404)

        let incompleteInput = Data("incomplete scope must remain byte exact".utf8)
        let incompleteCLI = ManagedDistillCLI(
            arguments: [], stdin: incompleteInput,
            state: .init(baseURL: ready.baseURL, authToken: "tok"),
            recoveryContext: ManagedDistillCLI.recoveryContext(environment: [
                "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace",
                "REMOTE_CODE_AGENT_PROVIDER": "codex",
            ])
        ) { request in
            guard let result = try? await URLSession.shared.data(for: request) else { return nil }
            return (result.0, (result.1 as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let incomplete = await incompleteCLI.run()
        XCTAssertEqual(incomplete.exitCode, 0)
        XCTAssertEqual(incomplete.stdout, incompleteInput)
    }

    func test_scopedUnchangedCandidateLeavesNoRecoveryRecord() async throws {
        let store = InMemoryScopedStore()
        let runtime = CountingRuntime(transform: { $0 })
        let server = DistillHTTPServer(
            configuration: try .init(authToken: "tok", appSupportDirectory: NSTemporaryDirectory()),
            scheduler: DistillScheduler(runtime: runtime, maxConcurrentRequests: 1),
            scopedRecoveryStore: store
        )
        let ready = try await server.start()
        defer { server.stop() }
        let request = DistillRequest(mode: .longText, input: "already optimal", runMode: .optimize)
        let response = try await http(
            ready.baseURL + "/v1/distill",
            method: "POST",
            token: "tok",
            body: try JSONEncoder().encode(request),
            headers: recoveryHeaders(invocationID: "unchanged", operationID: "same")
        )
        let decoded = try JSONDecoder().decode(DistillResponse.self, from: response.data)

        XCTAssertEqual(decoded.output, request.input)
        XCTAssertNil(decoded.originalHandle)
        XCTAssertEqual(store.preparationCount, 0)
        let unchangedCalls = await runtime.calls
        XCTAssertEqual(unchangedCalls, 1)
    }

    func test_terminalRetryDoesNotReoptimizeOrRevokeMarkerAndIndependentCallsRemainIndependent() async throws {
        let store = InMemoryScopedStore()
        let runtime = CountingRuntime(transform: { _ in "X" })
        let server = DistillHTTPServer(
            configuration: try .init(authToken: "tok", appSupportDirectory: NSTemporaryDirectory()),
            scheduler: DistillScheduler(runtime: runtime, maxConcurrentRequests: 1),
            scopedRecoveryStore: store
        )
        let ready = try await server.start()
        defer { server.stop() }
        let request = DistillRequest(mode: .longText, input: "identical private input", runMode: .optimize)

        func send(invocationID: String) async throws -> DistillResponse {
            let result = try await http(
                ready.baseURL + "/v1/distill",
                method: "POST",
                token: "tok",
                body: try JSONEncoder().encode(request),
                headers: recoveryHeaders(invocationID: invocationID, operationID: "stable-retry")
            )
            return try JSONDecoder().decode(DistillResponse.self, from: result.data)
        }

        let first = try await send(invocationID: "call-a")
        let firstHandle = try XCTUnwrap(first.originalHandle)
        let retry = try await send(invocationID: "call-a")
        XCTAssertEqual(retry.output, request.input)
        XCTAssertNil(retry.originalHandle)
        let retryCalls = await runtime.calls
        XCTAssertEqual(retryCalls, 1, "sent-unknown retry must not invoke the optimizer")
        XCTAssertEqual(
            try store.retrieveOriginal(
                capability: firstHandle,
                context: .init(
                    workspaceID: "workspace", projectID: "project", threadID: "thread",
                    provider: "codex", attemptID: "attempt", operationID: "stable-retry",
                    invocationID: "call-a"
                )
            ),
            Data(request.input.utf8),
            "terminal retry must not revoke an already emitted capability"
        )

        let independent = try await send(invocationID: "call-b")
        let secondHandle = try XCTUnwrap(independent.originalHandle)
        XCTAssertNotEqual(firstHandle, secondHandle)
        let independentCalls = await runtime.calls
        XCTAssertEqual(independentCalls, 1, "independent invocation may reuse the scheduler cache but still needs its own recovery record")
        XCTAssertEqual(store.preparationCount, 2)
    }

    func test_clientOver32MiBFailsOpenBeforeRequestForMiddleDifferentInputs() async throws {
        let store = InMemoryScopedStore()
        let runtime = CountingRuntime(transform: { _ in "should not run" })
        let server = DistillHTTPServer(
            configuration: try .init(authToken: "tok", appSupportDirectory: NSTemporaryDirectory()),
            scheduler: DistillScheduler(runtime: runtime, maxConcurrentRequests: 1),
            scopedRecoveryStore: store
        )
        let ready = try await server.start()
        defer { server.stop() }
        let client = DistillServiceClient(baseURL: try XCTUnwrap(URL(string: ready.baseURL)), authToken: "tok")
        let flank = String(repeating: "A", count: DistillServiceClient.stdinByteCap / 2 + 1_024)
        let firstInput = flank + "MIDDLE-ONE" + flank
        let secondInput = flank + "MIDDLE-TWO" + flank
        let context = TokenSaverRecoveryRequestContext(
            workspaceID: "workspace", projectID: "project", threadID: "thread",
            provider: "codex", attemptID: "attempt", operationID: "oversized"
        )

        let first = try await client.distill(
            DistillRequest(mode: .longText, input: firstInput, runMode: .optimize),
            recoveryContext: context
        )
        let second = try await client.distill(
            DistillRequest(mode: .longText, input: secondInput, runMode: .optimize),
            recoveryContext: context
        )

        XCTAssertEqual(first.output, firstInput)
        XCTAssertEqual(second.output, secondInput)
        XCTAssertNotEqual(first.output, second.output)
        XCTAssertNil(first.originalHandle)
        XCTAssertNil(second.originalHandle)
        XCTAssertEqual(store.preparationCount, 0)
        let oversizedCalls = await runtime.calls
        XCTAssertEqual(oversizedCalls, 0, "over-limit calls must not reach the service")
    }

    private func recoveryHeaders(invocationID: String, operationID: String) -> [String: String] {
        [
            "X-RemoteCode-Workspace-ID": "workspace",
            "X-RemoteCode-Project-ID": "project",
            "X-RemoteCode-Thread-ID": "thread",
            "X-RemoteCode-Provider": "codex",
            "X-RemoteCode-Attempt-ID": "attempt",
            "X-RemoteCode-Invocation-ID": invocationID,
            "X-RemoteCode-Operation-ID": operationID,
        ]
    }

    /// Wave -1 containment (T-003): a reversible store alone is not authorization.
    /// Without scope/capability grants, lossy optimize must never persist originals or emit handles.
    /// Fail-open keeps provider turns usable by returning the exact input verbatim.
    func test_waveMinus1_unscopedOptimizeWithStoreAttached_failsOpenWithoutHandleOrStoreWrite() async throws {
        let store = InMemoryReversibleStore()
        let configuration = try DistillServiceConfiguration(
            authToken: "tok",
            appSupportDirectory: NSTemporaryDirectory()
        )
        // Discarding runtime returns "X" so any unauthorized loss would be observable if the
        // server failed to fall back to the exact original under missing scope/capability.
        let scheduler = DistillScheduler(runtime: DiscardingRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            reversibleStore: store,
            reversibleStoreMinBytes: 1_024
        )
        let ready = try await server.start()
        defer { server.stop() }

        let original = String(repeating: "sensitive unscoped payload line\n", count: 1_200)
        XCTAssertGreaterThan(original.utf8.count, 24_000, "must exercise the large-input store path")
        let request = DistillRequest(
            mode: .longText,
            input: original,
            runMode: .optimize,
            maxOutputCharacters: 4_000
        )
        let body = try JSONEncoder().encode(request)

        let distill = try await http(ready.baseURL + "/v1/distill", method: "POST", token: "tok", body: body)
        XCTAssertEqual(distill.status, 200, "unscoped loss containment must fail open, not reject the turn")
        let response = try JSONDecoder().decode(DistillResponse.self, from: distill.data)

        XCTAssertEqual(
            response.output,
            original,
            "security intent: without scope/capability authorization, discard loss is not allowed; return exact original"
        )
        XCTAssertNil(
            response.originalHandle,
            "security intent: no originalHandle without scope-bound recovery capability — raw SHA is not an authz grant"
        )
        XCTAssertEqual(
            store.storeCount,
            0,
            "security intent: unscoped optimize must perform no new reversible-store write"
        )
        XCTAssertNotEqual(
            response.output,
            "X",
            "discarding runtime loss must not leak into the response under missing authorization"
        )
    }

    /// Wave -1 containment (T-003): bearer authentication proves process identity only.
    /// GET /v1/retrieve/<raw-sha256> must default-deny without an explicit recovery scope capability.
    func test_waveMinus1_bearerTokenAloneDoesNotAuthorizeRawSha256Retrieve() async throws {
        let store = InMemoryReversibleStore()
        let seededOriginal = "seeded secret original that must not be returned without recovery scope"
        let handle = try store.storeOriginal(Data(seededOriginal.utf8))
        XCTAssertEqual(store.storeCount, 1, "precondition: store is seeded before the retrieve probe")

        let configuration = try DistillServiceConfiguration(
            authToken: "tok",
            appSupportDirectory: NSTemporaryDirectory()
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            reversibleStore: store
        )
        let ready = try await server.start()
        defer { server.stop() }

        // Bearer is present (process auth) but no scope/capability authorization is supplied.
        let retrieve = try await http(ready.baseURL + "/v1/retrieve/\(handle)", token: "tok")
        XCTAssertEqual(
            retrieve.status,
            403,
            "security intent: default-deny unscoped recovery — bearer alone must not authorize raw-sha256 retrieve"
        )

        struct ErrorBody: Decodable {
            let error: String
            let message: String?
        }
        let errorBody = try JSONDecoder().decode(ErrorBody.self, from: retrieve.data)
        XCTAssertEqual(
            errorBody.error,
            "recovery_scope_required",
            "security intent: typed default-deny code must be recovery_scope_required, not a silent miss"
        )

        let bodyText = String(data: retrieve.data, encoding: .utf8) ?? ""
        XCTAssertFalse(
            bodyText.contains(seededOriginal),
            "security intent: never return original bytes when recovery scope is missing"
        )
        if let decoded = try? JSONDecoder().decode(Retrieved.self, from: retrieve.data) {
            XCTAssertNotEqual(
                decoded.original,
                seededOriginal,
                "security intent: retrieved payload must not carry the seeded original without scope"
            )
            XCTAssertFalse(
                decoded.found,
                "security intent: found=true would disclose successful unscoped recovery"
            )
        }
    }

    private func http(
        _ url: String,
        method: String = "GET",
        token: String? = nil,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = 5
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (header, value) in headers { request.setValue(value, forHTTPHeaderField: header) }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, data)
    }
}
