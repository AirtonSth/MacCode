import CoreModel
import DistillSavingsPersistenceSupport
import Persistence
import XCTest
@testable import DistillCore

final class DeferredDeliveryServiceRepositoryIntegrationTests: XCTestCase {
    private final class EventCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        func read() -> Int { lock.withLock { value } }
    }
    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var milliseconds: UInt64
        init(_ milliseconds: UInt64) { self.milliseconds = milliseconds }
        func set(_ milliseconds: UInt64) { lock.withLock { self.milliseconds = milliseconds } }
        func date() -> Date {
            lock.withLock { Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }
        }
    }
    private final class RecoveryStore: TokenSaverScopedRecoveryStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var original: Data?
        func prepareOriginal(
            _ data: Data,
            context: TokenSaverRecoveryRequestContext,
            lane: String
        ) throws -> TokenSaverScopedPreparation {
            lock.withLock { original = data }
            return .init(capability: "synthetic-capability", idempotencyKey: context.operationID, readBackVerified: true)
        }
        func retrieveOriginal(capability: String, context: TokenSaverRecoveryRequestContext) throws -> Data? {
            lock.withLock { original }
        }
        func markDelivered(
            capability: String,
            idempotencyKey: String,
            context: TokenSaverRecoveryRequestContext,
            outcome: TokenSaverScopedDeliveryOutcome
        ) throws -> Bool { try retrieveOriginal(capability: capability, context: context) != nil }
        func ack(
            capability: String,
            idempotencyKey: String,
            context: TokenSaverRecoveryRequestContext
        ) throws -> Bool { true }
    }

    private struct Runtime: DistillRuntime {
        func distill(_ request: DistillRequest) async throws -> String { "scheduled" }
        func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
            .init(output: "scheduled", stage: .deterministic)
        }
    }

    func test_phaseOneTokenAndPhaseTwoAccountingTraverseProductionRecorderToRepository() async throws {
        // WHY: reproduce clean production startup: the server is already ready
        // before the controller writes receipt_key. Only the final, observable
        // handoff may create one durable delivered row.
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeferredDeliveryRepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repository = TokenSaverSavingsRepository(db: db)
        let events = EventCounter()
        let recorder = DeferredSavingsRecorder(
            repository: repository,
            eventSink: { _ in events.increment() }
        )
        let receiptKey = Data(repeating: 0x45, count: 32)
        let configuration = try DistillServiceConfiguration(
            authToken: "synthetic-bearer",
            appSupportDirectory: appSupport.path,
            maxConcurrentRequests: 1
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: Runtime(), maxConcurrentRequests: 1),
            scopedRecoveryStore: RecoveryStore(),
            onSuccess: recorder.successHandler,
            deliveryReceiptKeyProvider: {
                DistillDeliveryReceiptKeyFileProvider.load(appSupportDirectory: appSupport.path)
            },
            deferredDeliveryAuthority: .init(keyGenerator: { Data(repeating: 0x19, count: 32) })
        )
        let baseURL = try await server.start().baseURL
        defer { server.stop() }

        let initial = DistillRequest(
            mode: .commandOutput,
            input: String(repeating: "verbose synthetic output\n", count: 40),
            provider: nil,
            recordSavings: false,
            producerFamily: "managed-cli"
        )
        let phaseOneResult = try await post(initial, baseURL: baseURL)
        XCTAssertEqual(phaseOneResult.status, 200)
        let phaseOne = try JSONDecoder().decode(DistillResponse.self, from: phaseOneResult.data)
        XCTAssertNotNil(phaseOne.deferredDeliveryToken)
        XCTAssertEqual(try repository.summary().totalRuns, 0)

        let stateDirectory = appSupport.appendingPathComponent("Distill", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let state = stateDirectory.appendingPathComponent("DistillCLIState.json")
        let encodedKey = try XCTUnwrap(DistillAppliedReceipt.encodeReceiptKey(receiptKey))
        let stateData = try JSONSerialization.data(withJSONObject: [
            "base_url": baseURL,
            "auth_token": "synthetic-bearer",
            "receipt_key": encodedKey,
        ])
        try stateData.write(to: state, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)

        let prefix = try XCTUnwrap(phaseOne.providerVisiblePrefix)
        let marker = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
            rootRunID: "synthetic-root", payload: Data(prefix.utf8), key: receiptKey
        ))
        let final = DistillRequest(
            id: initial.id,
            mode: initial.mode,
            input: initial.input,
            provider: initial.provider,
            recordSavings: true,
            precomputedRouteStage: phaseOne.routeStage,
            precomputedRecoveryConfirmations: [
                .init(capability: "synthetic-capability", idempotencyKey: "operation-a"),
            ],
            deferredDeliveryToken: phaseOne.deferredDeliveryToken,
            accountingOutput: phaseOne.accountingOutput,
            deliveredOutput: prefix + marker + "\n",
            producerFamily: "managed-cli",
            deferredHandoffDeadlineUnixMilliseconds: DistillDeferredDelivery.handoffDeadlineUnixMilliseconds()
        )
        let missingHeader = try await post(final, baseURL: baseURL, includeDeadlineHeader: false)
        XCTAssertEqual(missingHeader.status, 409, "body deadline cannot substitute for the handoff header")
        XCTAssertEqual(try repository.summary().totalRuns, 0)
        let missingDeferredHeader = try await post(
            final,
            baseURL: baseURL,
            includeDeferredHeader: false
        )
        XCTAssertEqual(missingDeferredHeader.status, 409, "phase two is not admitted without the managed deferred header")
        XCTAssertEqual(try repository.summary().totalRuns, 0)
        let phaseTwoResult = try await post(final, baseURL: baseURL)
        XCTAssertEqual(phaseTwoResult.status, 200, String(decoding: phaseTwoResult.data, as: UTF8.self))
        let replayResult = try await post(final, baseURL: baseURL)
        XCTAssertEqual(replayResult.status, 200, "lost-200 replay remains idempotent")
        var summary = try repository.summary()
        XCTAssertEqual(summary.totalRuns, 1)
        XCTAssertGreaterThan(summary.totalSavedTokens, 0)
        XCTAssertEqual(summary.savings(for: "codex")?.runs, 1, "header provider is authoritative when body provider is nil")
        XCTAssertEqual(events.read(), 1, "replay emits no second production savings event")
        XCTAssertEqual(try repository.savedTokens(forThreadID: "synthetic-thread"), summary.totalSavedTokens)

        let distinctInitial = DistillRequest(
            mode: initial.mode,
            input: initial.input,
            provider: nil,
            recordSavings: false,
            producerFamily: "managed-cli"
        )
        let distinctPhaseOneResult = try await post(
            distinctInitial, baseURL: baseURL, invocationID: "invocation-b"
        )
        let distinctPhaseOne = try JSONDecoder().decode(DistillResponse.self, from: distinctPhaseOneResult.data)
        let distinctPrefix = try XCTUnwrap(distinctPhaseOne.providerVisiblePrefix)
        let distinctMarker = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
            rootRunID: "synthetic-root", payload: Data(distinctPrefix.utf8), key: receiptKey
        ))
        let distinctFinal = DistillRequest(
            id: distinctInitial.id,
            mode: distinctInitial.mode,
            input: distinctInitial.input,
            recordSavings: true,
            precomputedRouteStage: distinctPhaseOne.routeStage,
            precomputedRecoveryConfirmations: [
                .init(capability: "synthetic-capability", idempotencyKey: "operation-a"),
            ],
            deferredDeliveryToken: distinctPhaseOne.deferredDeliveryToken,
            accountingOutput: distinctPhaseOne.accountingOutput,
            deliveredOutput: distinctPrefix + distinctMarker + "\n",
            producerFamily: "managed-cli",
            deferredHandoffDeadlineUnixMilliseconds: DistillDeferredDelivery.handoffDeadlineUnixMilliseconds()
        )
        let distinctFinalResult = try await post(
            distinctFinal, baseURL: baseURL, invocationID: "invocation-b"
        )
        XCTAssertEqual(distinctFinalResult.status, 200)
        summary = try repository.summary()
        XCTAssertEqual(summary.totalRuns, 2)
        XCTAssertEqual(events.read(), 2, "distinct invocation over identical bytes is a distinct delivery")

        // The frozen gate selects this method by exact name. Keep the real HTTP
        // deadline/cancellation cases reachable through that production proof.
        try await test_serverProcessingPastHandoffDeadlinePermanentlyRecordsZero()
        try await test_HTTPDeadlineCutoffsAndCancellationRacePreserveCommitSemantics()
    }

    func test_serverProcessingPastHandoffDeadlinePermanentlyRecordsZero() async throws {
        // WHY: transport cancellation cannot undo a server write. The server
        // must re-check the client handoff deadline immediately before persistence.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repository = TokenSaverSavingsRepository(db: db)
        let events = EventCounter()
        let recorder = DeferredSavingsRecorder(
            repository: repository,
            eventSink: { _ in events.increment() }
        )
        let receiptKey = Data(repeating: 0x46, count: 32)
        let configuration = try DistillServiceConfiguration(
            authToken: "synthetic-bearer",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 1
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: Runtime(), maxConcurrentRequests: 1),
            scopedRecoveryStore: RecoveryStore(),
            onSuccess: recorder.successHandler,
            deliveryReceiptKeyProvider: {
                Thread.sleep(forTimeInterval: 0.30)
                return receiptKey
            },
            deferredDeliveryAuthority: .init(keyGenerator: { Data(repeating: 0x20, count: 32) })
        )
        let baseURL = try await server.start().baseURL
        defer { server.stop() }

        let initial = DistillRequest(
            mode: .commandOutput,
            input: String(repeating: "late synthetic output\n", count: 40),
            provider: "codex",
            recordSavings: false,
            producerFamily: "managed-cli"
        )
        let phaseOneResult = try await post(initial, baseURL: baseURL)
        XCTAssertEqual(phaseOneResult.status, 200)
        let phaseOne = try JSONDecoder().decode(DistillResponse.self, from: phaseOneResult.data)
        let prefix = try XCTUnwrap(phaseOne.providerVisiblePrefix)
        let marker = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
            rootRunID: "synthetic-root", payload: Data(prefix.utf8), key: receiptKey
        ))
        let final = DistillRequest(
            id: initial.id,
            mode: initial.mode,
            input: initial.input,
            provider: initial.provider,
            recordSavings: true,
            precomputedRouteStage: phaseOne.routeStage,
            deferredDeliveryToken: phaseOne.deferredDeliveryToken,
            accountingOutput: phaseOne.accountingOutput,
            deliveredOutput: prefix + marker + "\n",
            producerFamily: "managed-cli",
            deferredHandoffDeadlineUnixMilliseconds: DistillDeferredDelivery.handoffDeadlineUnixMilliseconds()
        )
        let phaseTwoResult = try await post(final, baseURL: baseURL)
        XCTAssertEqual(phaseTwoResult.status, 409)
        XCTAssertEqual(try repository.summary().totalRuns, 0)
        XCTAssertEqual(events.read(), 0)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(try repository.summary().totalRuns, 0, "late response cannot create a row afterward")
        XCTAssertEqual(events.read(), 0)
    }

    func test_HTTPDeadlineCutoffsAndCancellationRacePreserveCommitSemantics() async throws {
        // WHY: the server clock, not URLSession cancellation or response timing,
        // decides whether an observable provider handoff may mutate the ledger.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repository = TokenSaverSavingsRepository(db: db)
        let events = EventCounter()
        let recorder = DeferredSavingsRecorder(
            repository: repository,
            eventSink: { _ in events.increment() }
        )
        let clock = MutableClock(10_000)
        let receiptKey = Data(repeating: 0x47, count: 32)
        let configuration = try DistillServiceConfiguration(
            authToken: "synthetic-bearer",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 1
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: Runtime(), maxConcurrentRequests: 1),
            scopedRecoveryStore: RecoveryStore(),
            onSuccess: { request, response, threadID in
                await recorder.successHandler(request, response, threadID)
                if request.cacheState == "retain-phase-two-response" {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.40) {
                            continuation.resume()
                        }
                    }
                }
            },
            deliveryReceiptKey: receiptKey,
            deferredDeliveryClock: { clock.date() },
            deferredDeliveryAuthority: .init(keyGenerator: { Data(repeating: 0x21, count: 32) })
        )
        let baseURL = try await server.start().baseURL
        defer { server.stop() }

        func finalRequest(
            invocation: String,
            producer: String,
            deadline: UInt64
        ) async throws -> DistillRequest {
            let initial = DistillRequest(
                mode: .commandOutput,
                input: String(repeating: "deadline synthetic output\n", count: 40),
                provider: "codex",
                recordSavings: false,
                producerFamily: producer
            )
            let result = try await post(
                initial,
                baseURL: baseURL,
                invocationID: invocation,
                producerFamily: producer
            )
            XCTAssertEqual(result.status, 200)
            let phaseOne = try JSONDecoder().decode(DistillResponse.self, from: result.data)
            let prefix = try XCTUnwrap(phaseOne.providerVisiblePrefix)
            let marker = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
                rootRunID: "synthetic-root", payload: Data(prefix.utf8), key: receiptKey
            ))
            return DistillRequest(
                id: initial.id,
                mode: initial.mode,
                input: initial.input,
                provider: initial.provider,
                recordSavings: true,
                precomputedRouteStage: phaseOne.routeStage,
                precomputedRecoveryConfirmations: DistillDeferredDelivery.recoveryConfirmations(phaseOne),
                deferredDeliveryToken: phaseOne.deferredDeliveryToken,
                accountingOutput: phaseOne.accountingOutput,
                deliveredOutput: prefix + marker + "\n",
                producerFamily: producer,
                deferredHandoffDeadlineUnixMilliseconds: deadline
            )
        }

        let equal = try await finalRequest(invocation: "deadline-equal", producer: "managed-cli", deadline: 10_000)
        let equalResult = try await post(equal, baseURL: baseURL, invocationID: "deadline-equal")
        XCTAssertEqual(equalResult.status, 409, "now == deadline is too late")
        XCTAssertEqual(try repository.summary().totalRuns, 0)

        clock.set(9_999)
        let before = try await finalRequest(invocation: "deadline-before", producer: "managed-cli", deadline: 10_000)
        let beforeResult = try await post(before, baseURL: baseURL, invocationID: "deadline-before")
        XCTAssertEqual(beforeResult.status, 200, "deadline - 1ms commits")
        XCTAssertEqual(try repository.summary().totalRuns, 1)

        clock.set(20_499)
        let claude = try await finalRequest(invocation: "deadline-claude", producer: "claude-sdk", deadline: 20_500)
        let claudeResult = try await post(
            claude,
            baseURL: baseURL,
            invocationID: "deadline-claude",
            producerFamily: "claude-sdk"
        )
        XCTAssertEqual(claudeResult.status, 200, "Claude's fixed 500ms handoff window uses the same server cutoff")
        XCTAssertEqual(try repository.summary().totalRuns, 2)

        clock.set(30_000)
        let late = try await finalRequest(invocation: "deadline-late", producer: "managed-cli", deadline: 30_100)
        let continuousClock = ContinuousClock()
        let lateStarted = continuousClock.now
        await DistillDeferredDelivery.awaitBestEffortHandoff(timeoutNanoseconds: 100_000_000) {
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { /* deliberately ignore cancellation */ }
            clock.set(30_100)
            _ = try? await self.post(late, baseURL: baseURL, invocationID: "deadline-late")
        }
        XCTAssertLessThan(lateStarted.duration(to: continuousClock.now), .milliseconds(275))
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(try repository.summary().totalRuns, 2, "late send is permanently rejected")

        clock.set(40_000)
        let committed = try await finalRequest(invocation: "deadline-committed", producer: "managed-cli", deadline: 40_250)
        let retainedResponse = DistillRequest(
            id: committed.id,
            mode: committed.mode,
            priority: committed.priority,
            input: committed.input,
            question: committed.question,
            provider: committed.provider,
            recordSavings: committed.recordSavings == true,
            runMode: committed.effectiveRunMode,
            cacheState: "retain-phase-two-response",
            precomputedRouteStage: committed.precomputedRouteStage,
            precomputedRecoveryConfirmations: committed.precomputedRecoveryConfirmations,
            deferredDeliveryToken: committed.deferredDeliveryToken,
            accountingOutput: committed.accountingOutput,
            deliveredOutput: committed.deliveredOutput,
            producerFamily: committed.producerFamily,
            deferredHandoffDeadlineUnixMilliseconds: committed.deferredHandoffDeadlineUnixMilliseconds
        )
        let committedStarted = continuousClock.now
        await DistillDeferredDelivery.awaitBestEffortHandoff(timeoutNanoseconds: 100_000_000) {
            _ = try? await self.post(retainedResponse, baseURL: baseURL, invocationID: "deadline-committed")
        }
        XCTAssertLessThan(committedStarted.duration(to: continuousClock.now), .milliseconds(275))
        XCTAssertEqual(try repository.summary().totalRuns, 3, "commit before cutoff survives a retained response")
        XCTAssertEqual(events.read(), 3)
    }

    func test_mainAndHTTPServerUseSameProductionSuccessHandler() throws {
        // WHY: production and integration must not drift to duplicate mappings.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteCodeDistillService/RemoteCodeDistillServiceMain.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("onSuccess: deferredSavingsRecorder.successHandler"))
        XCTAssertTrue(source.contains("DistillDeliveryReceiptKeyFileProvider.load"))
        XCTAssertFalse(source.contains("loadDeliveryReceiptKey(appSupportDirectory:"))
    }

    private func post(
        _ body: DistillRequest,
        baseURL: String,
        invocationID: String = "invocation-a",
        producerFamily: String = "managed-cli",
        includeDeadlineHeader: Bool = true,
        includeDeferredHeader: Bool = true
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: baseURL + "/v1/distill")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.httpBody = try JSONEncoder().encode(body)
        for (field, value) in [
            "Authorization": "Bearer synthetic-bearer",
            "Content-Type": "application/json",
            "X-RemoteCode-Delivery-Deferred": "1",
            "X-RemoteCode-Workspace-ID": "workspace",
            "X-RemoteCode-Project-ID": "project",
            "X-RemoteCode-Thread-ID": "synthetic-thread",
            "X-RemoteCode-Provider": "codex",
            "X-RemoteCode-Attempt-ID": "synthetic-attempt",
            "X-RemoteCode-Root-Run-ID": "synthetic-root",
            "X-RemoteCode-Invocation-ID": invocationID,
            "X-RemoteCode-Operation-ID": "operation-a",
            "X-RemoteCode-Producer-Family": producerFamily,
        ] { request.setValue(value, forHTTPHeaderField: field) }
        if !includeDeferredHeader {
            request.setValue(nil, forHTTPHeaderField: "X-RemoteCode-Delivery-Deferred")
        }
        if includeDeadlineHeader, let deadline = body.deferredHandoffDeadlineUnixMilliseconds {
            request.setValue(
                String(deadline),
                forHTTPHeaderField: DistillDeferredDelivery.handoffDeadlineHeader
            )
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
