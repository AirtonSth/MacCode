import CryptoKit
import CoreModel
import XCTest
@testable import DistillCore

final class DeferredDeliveryTokenTests: XCTestCase {
    private let key = Data(repeating: 0x31, count: 32)
    private let receiptKey = Data(repeating: 0x73, count: 32)

    private final class RecoveryStore: TokenSaverScopedRecoveryStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func prepareOriginal(
            _ data: Data,
            context: TokenSaverRecoveryRequestContext,
            lane: String
        ) throws -> TokenSaverScopedPreparation {
            let capability = "synthetic-capability"
            lock.withLock { values[capability] = data }
            return .init(capability: capability, idempotencyKey: context.operationID, readBackVerified: true)
        }

        func retrieveOriginal(capability: String, context: TokenSaverRecoveryRequestContext) throws -> Data? {
            lock.withLock { values[capability] }
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

    private struct FixedRuntime: DistillRuntime {
        func distill(_ request: DistillRequest) async throws -> String { "scheduled" }
        func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
            .init(output: "scheduled", stage: .deterministic)
        }
    }

    private func identity(
        invocation: String = "invocation-a",
        operation: String = "operation-a"
    ) -> DistillDeferredDeliveryAuthority.Identity {
        .init(
            provider: "codex",
            threadID: "synthetic-thread",
            rootRunID: "synthetic-root",
            attemptID: "synthetic-attempt",
            invocationID: invocation,
            operationID: operation,
            producerFamily: "managed-cli"
        )
    }

    private func issued(
        authority: DistillDeferredDeliveryAuthority,
        identity: DistillDeferredDeliveryAuthority.Identity? = nil,
        accounting: String = "short"
    ) -> String? {
        let identity = identity ?? self.identity()
        let prefix = DistillDeferredDelivery.providerVisiblePrefix(
            accountingOutput: accounting,
            recoveryConfirmations: []
        )!
        return authority.issue(
            identity: identity,
            original: String(repeating: "verbose synthetic line\n", count: 20),
            accountingOutput: accounting,
            recoveryConfirmations: [],
            providerVisiblePrefix: prefix,
            routeStage: .deterministic
        )
    }

    private func verify(
        _ token: String,
        authority: DistillDeferredDeliveryAuthority,
        identity: DistillDeferredDeliveryAuthority.Identity? = nil,
        accounting: String = "short"
    ) -> DistillDeferredDeliveryAuthority.Verified? {
        let identity = identity ?? self.identity()
        let prefix = DistillDeferredDelivery.providerVisiblePrefix(
            accountingOutput: accounting,
            recoveryConfirmations: []
        )!
        return authority.verify(
            token: token,
            identity: identity,
            original: String(repeating: "verbose synthetic line\n", count: 20),
            accountingOutput: accounting,
            recoveryConfirmations: [],
            providerVisiblePrefix: prefix,
            routeStage: .deterministic
        )
    }

    func test_serverOnlyKeyRejectsBearerAndStateReceiptKeyForgery() throws {
        // WHY: possession of the HTTP bearer or client-visible receipt key must
        // never grant authority to mint a delivered-savings attestation.
        let server = DistillDeferredDeliveryAuthority(keyGenerator: { self.key })
        let attacker = DistillDeferredDeliveryAuthority(keyGenerator: { self.receiptKey })
        let token = try XCTUnwrap(issued(authority: server))
        let forged = try XCTUnwrap(issued(authority: attacker))

        XCTAssertNotNil(verify(token, authority: server))
        XCTAssertNil(verify(forged, authority: server))
        XCTAssertFalse(token.contains(key.base64EncodedString()))
        XCTAssertFalse(token.contains(receiptKey.base64EncodedString()))

        let composedIdentity = identity(invocation: "é")
        let composedToken = try XCTUnwrap(issued(authority: server, identity: composedIdentity))
        let decomposedIdentity = identity(invocation: "e\u{301}")
        XCTAssertEqual(composedIdentity.invocationID, decomposedIdentity.invocationID)
        XCTAssertNotEqual(Data(composedIdentity.invocationID.utf8), Data(decomposedIdentity.invocationID.utf8))
        XCTAssertNil(verify(composedToken, authority: server, identity: decomposedIdentity),
                     "canonical Unicode equivalence cannot mint a second replay identity")
    }

    func test_arbitraryPrecomputedOutputNeverReceivesToken() async throws {
        // WHY: client-provided positive deltas remain ordinary, unauthenticated
        // data until the server independently reproduces or schedules them.
        let (server, baseURL) = try await server(runtime: FixedRuntime())
        defer { server.stop() }
        let request = DistillRequest(
            mode: .commandOutput,
            input: String(repeating: "arbitrary original\n", count: 30),
            provider: "codex",
            recordSavings: false,
            precomputedOutput: "invented",
            precomputedRouteStage: .deterministic,
            producerFamily: "managed-cli"
        )
        let result = try await post(request, baseURL: baseURL)

        XCTAssertEqual(result.status, 409)
        XCTAssertFalse(String(decoding: result.data, as: UTF8.self).contains("deferredDeliveryToken"))
    }

    func test_realPhaseOneAndRecomputedLosslessPrepassIssueValidToken() async throws {
        // WHY: both authorized producers use the same server-owned primitive;
        // no client-side signing exception exists for the fast prepass.
        let (server, baseURL) = try await server(runtime: FixedRuntime())
        defer { server.stop() }
        let scheduler = DistillRequest(
            mode: .commandOutput,
            input: String(repeating: "verbose scheduled output line\n", count: 30),
            provider: "codex",
            recordSavings: false,
            producerFamily: "managed-cli"
        )
        let schedulerResult = try await post(scheduler, baseURL: baseURL)
        XCTAssertEqual(schedulerResult.status, 200)
        let schedulerResponse = try JSONDecoder().decode(DistillResponse.self, from: schedulerResult.data)
        XCTAssertNotNil(schedulerResponse.deferredDeliveryToken)
        XCTAssertEqual(schedulerResponse.accountingOutput, "scheduled")

        TokenSaverWaveLiveRollout.activate(.waveA)
        defer { TokenSaverWaveLiveRollout.resetForTesting() }
        let line = "same synthetic log line é repeated for exact collapse"
        let original = String(repeating: line + "\n", count: 20) + "exit code: 0\n"
        let recomputed = try XCTUnwrap(TokenSaverWaveLosslessPrepass.apply(input: original)?.output)
        let prepass = DistillRequest(
            mode: .commandOutput,
            input: original,
            provider: "codex",
            recordSavings: false,
            precomputedOutput: recomputed,
            precomputedRouteStage: .deterministic,
            producerFamily: "managed-cli",
            deterministicLosslessPrepass: true
        )
        let prepassResult = try await post(prepass, baseURL: baseURL)
        XCTAssertEqual(prepassResult.status, 200)
        XCTAssertNotNil(try JSONDecoder().decode(DistillResponse.self, from: prepassResult.data).deferredDeliveryToken)

        let substituted = DistillRequest(
            mode: .commandOutput,
            input: original,
            provider: "codex",
            recordSavings: false,
            precomputedOutput: recomputed + "substitution",
            precomputedRouteStage: .deterministic,
            producerFamily: "managed-cli",
            deterministicLosslessPrepass: true
        )
        let substitutedResult = try await post(substituted, baseURL: baseURL)
        XCTAssertEqual(substitutedResult.status, 409)

        let canonicallyEquivalentOutput = recomputed.decomposedStringWithCanonicalMapping
        XCTAssertEqual(recomputed, canonicallyEquivalentOutput)
        XCTAssertNotEqual(Data(recomputed.utf8), Data(canonicallyEquivalentOutput.utf8))
        let unicodeSubstitution = DistillRequest(
            mode: .commandOutput,
            input: original,
            provider: "codex",
            recordSavings: false,
            precomputedOutput: canonicallyEquivalentOutput,
            precomputedRouteStage: .deterministic,
            producerFamily: "managed-cli",
            deterministicLosslessPrepass: true
        )
        let unicodeResult = try await post(unicodeSubstitution, baseURL: baseURL)
        XCTAssertEqual(unicodeResult.status, 409)
        let wrongStage = DistillRequest(
            mode: .commandOutput,
            input: original,
            provider: "codex",
            recordSavings: false,
            precomputedOutput: recomputed,
            precomputedRouteStage: .llmMLX,
            producerFamily: "managed-cli",
            deterministicLosslessPrepass: true
        )
        let wrongStageResult = try await post(wrongStage, baseURL: baseURL)
        XCTAssertEqual(wrongStageResult.status, 409)
    }

    func test_crossInstanceRestartAndExpiryBoundaryAreHonestZero() throws {
        // WHY: in-memory authority deliberately makes restart and expiry fail
        // closed for accounting while provider output remains fail-open.
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64 = 1_000
            func read() -> UInt64 { lock.withLock { value } }
            func set(_ value: UInt64) { lock.withLock { self.value = value } }
        }
        let clock = Clock()
        let first = DistillDeferredDeliveryAuthority(
            keyGenerator: { self.key },
            nowMilliseconds: { clock.read() }
        )
        let restarted = DistillDeferredDeliveryAuthority(
            keyGenerator: { Data(repeating: 0x32, count: 32) },
            nowMilliseconds: { clock.read() }
        )
        let token = try XCTUnwrap(issued(authority: first))

        XCTAssertNil(verify(token, authority: restarted))
        clock.set(999)
        XCTAssertNil(verify(token, authority: first), "future-issued tokens must fail closed")
        clock.set(1_000 + DistillDeferredDelivery.ordinaryTTLMilliseconds - 1)
        XCTAssertNotNil(verify(token, authority: first))
        clock.set(1_000 + DistillDeferredDelivery.ordinaryTTLMilliseconds)
        XCTAssertNil(verify(token, authority: first))
    }

    func test_ordinaryAndMemberCanonicalPayloadAndMACGoldenVectors() throws {
        // WHY: issue/verify symmetry cannot detect a wire-order regression. These
        // fixed vectors lock both canonical payload bytes and their HMAC.
        let authority = DistillDeferredDeliveryAuthority(
            keyGenerator: { self.key },
            nowMilliseconds: { 1_000 }
        )
        let ordinaryIdentity = DistillDeferredDeliveryAuthority.Identity(
            provider: "codex", threadID: "thread", rootRunID: "root", attemptID: "attempt",
            invocationID: "invocation", operationID: "operation", producerFamily: "managed-cli"
        )
        let prefix = "short\n"
        let ordinary = try XCTUnwrap(authority.issue(
            identity: ordinaryIdentity,
            original: "original",
            accountingOutput: "short",
            recoveryConfirmations: [],
            providerVisiblePrefix: prefix,
            routeStage: .deterministic
        ))
        XCTAssertEqual(
            ordinary,
            "v1.aW8ucmVtb3RlY29kZS5kZWZlcnJlZC1kZWxpdmVyeQEAAAAAAAAAAnYxAQAAAAAAAAAFY29kZXgBAAAAAAAAAAZ0aHJlYWQBAAAAAAAAAARyb290AQAAAAAAAAAHYXR0ZW1wdAEAAAAAAAAACmludm9jYXRpb24BAAAAAAAAAAlvcGVyYXRpb24BAAAAAAAAAAttYW5hZ2VkLWNsaQEAAAAAAAAADWRldGVybWluaXN0aWMBAAAAAAAAAEAwNjgyYzVmMjA3NmYwOTljMzRjZmRkMTVhOWUwNjM4NDllZDQzN2E0OTY3N2U2ZmNjNWI0MTk4Yzc2NTc1YmU1AQAAAAAAAABAZjliMDA3OGI1ZGY1OTZkMmVhMTkwMTBjMDAxYmJkMDA5ZTY1MWRlMmM1N2U4ZmI3ZTM1NWYzMWViOWQzZjczOQEAAAAAAAAAQGM5NmM0MjdhYzZkOGUwODk4NGNiOTZlNTcyYmJkYzcxMzkyMjY3ZTMyMDE0NTE4NGE3YzJjNGRmZGI0N2I5MGMBAAAAAAAAAEBjOTYyZmExYmUzMTE5ODFmMGY5NjU4NTdlODliMDAwNzA3ZjljZWEwN2EwNjlkMDczNDYxMzA4ZjMwMTkyMDBmAAAAAAAAA-gAAAAAAAB5GA.5IDs05Cx8h1GHupGshsabNnhA4qsVh4VN_l2yWxAOAQ"
        )

        let descriptor = DistillDeferredChunkDescriptor(
            index: 1, count: 3, originalUTF8ByteOffset: 8,
            originalUTF8ByteLength: 8, aggregateOperationID: "aggregate"
        )
        let memberIdentity = DistillDeferredDeliveryAuthority.Identity(
            provider: "codex", threadID: "thread", rootRunID: "root", attemptID: "attempt",
            invocationID: "invocation.member.1", operationID: "aggregate.member.1", producerFamily: "managed-cli"
        )
        let member = try XCTUnwrap(authority.issue(
            identity: memberIdentity,
            original: "original",
            accountingOutput: "short",
            recoveryConfirmations: [],
            providerVisiblePrefix: prefix,
            routeStage: .deterministic,
            chunk: descriptor,
            question: "question"
        ))
        XCTAssertEqual(
            member,
            "member-v1.aW8ucmVtb3RlY29kZS5kZWZlcnJlZC1kZWxpdmVyeQEAAAAAAAAACW1lbWJlci12MQEAAAAAAAAABWNvZGV4AQAAAAAAAAAGdGhyZWFkAQAAAAAAAAAEcm9vdAEAAAAAAAAAB2F0dGVtcHQBAAAAAAAAABNpbnZvY2F0aW9uLm1lbWJlci4xAQAAAAAAAAAJYWdncmVnYXRlAQAAAAAAAAALbWFuYWdlZC1jbGkBAAAAAAAAAA1kZXRlcm1pbmlzdGljAQAAAAAAAAABMQEAAAAAAAAAATMBAAAAAAAAAAE4AQAAAAAAAAABOAEAAAAAAAAAQDA2ODJjNWYyMDc2ZjA5OWMzNGNmZGQxNWE5ZTA2Mzg0OWVkNDM3YTQ5Njc3ZTZmY2M1YjQxOThjNzY1NzViZTUBAAAAAAAAAEAxZjUwODdkYjkxOWNlZDVjMTIzYzdmNTA3ZDNmY2NlODE4Y2IwY2Y2ZTc3YzJmOTVhOGEzNWU5NTFlMDNmZGI5AQAAAAAAAABAZjliMDA3OGI1ZGY1OTZkMmVhMTkwMTBjMDAxYmJkMDA5ZTY1MWRlMmM1N2U4ZmI3ZTM1NWYzMWViOWQzZjczOQEAAAAAAAAAATUBAAAAAAAAAEBjOTZjNDI3YWM2ZDhlMDg5ODRjYjk2ZTU3MmJiZGM3MTM5MjI2N2UzMjAxNDUxODRhN2MyYzRkZmRiNDdiOTBjAQAAAAAAAABAYzk2MmZhMWJlMzExOTgxZjBmOTY1ODU3ZTg5YjAwMDcwN2Y5Y2VhMDdhMDY5ZDA3MzQ2MTMwOGYzMDE5MjAwZgAAAAAAAAPoAAAAAAABY3g.X8V78kiyT-yjdjt3XN4qKmkFTg-Ki6TBspoMHdq2iGI"
        )
    }

    func test_exactProviderVisiblePrefixHandlesEmptyTrailingLFAndRejectsMarkerSubstitutionDuplicateSuffixAndCRLF() throws {
        // WHY: accounting bytes are marker-free, while provider-visible bytes
        // have one exact authenticated terminal delivery receipt.
        XCTAssertEqual(
            DistillDeferredDelivery.providerVisiblePrefix(accountingOutput: "", recoveryConfirmations: []),
            "\n"
        )
        XCTAssertEqual(
            DistillDeferredDelivery.providerVisiblePrefix(accountingOutput: "body\n", recoveryConfirmations: []),
            "body\n"
        )
        XCTAssertNil(DistillDeferredDelivery.providerVisiblePrefix(
            accountingOutput: "body [[rcd:v2:fake]]",
            recoveryConfirmations: []
        ))

        let prefix = "body\n"
        let marker = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
            rootRunID: "synthetic-root",
            payload: Data(prefix.utf8),
            key: receiptKey
        ))
        let exact = prefix + marker + "\n"
        XCTAssertTrue(DistillHTTPServer.validateDeferredDeliveredOutput(
            exact, prefix: prefix, rootRunID: "synthetic-root", receiptKey: receiptKey
        ))
        for mutation in [
            prefix + "[[rcd:v2.fake.fake]]\n",
            prefix + marker + "\n" + marker + "\n",
            prefix + marker + "\r\n",
            "substituted\n" + marker + "\n",
            prefix + "suffix" + marker + "\n",
        ] {
            XCTAssertFalse(DistillHTTPServer.validateDeferredDeliveredOutput(
                mutation, prefix: prefix, rootRunID: "synthetic-root", receiptKey: receiptKey
            ))
        }
        let composedPrefix = "é\n"
        let composedMarker = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
            rootRunID: "synthetic-root",
            payload: Data(composedPrefix.utf8),
            key: receiptKey
        ))
        XCTAssertFalse(DistillHTTPServer.validateDeferredDeliveredOutput(
            "e\u{301}\n" + composedMarker + "\n",
            prefix: composedPrefix,
            rootRunID: "synthetic-root",
            receiptKey: receiptKey
        ), "canonically equivalent Unicode is still byte-distinct provider output")
    }

    private func server(
        runtime: any DistillRuntime
    ) async throws -> (DistillHTTPServer, String) {
        let configuration = try DistillServiceConfiguration(
            authToken: "synthetic-bearer",
            appSupportDirectory: NSTemporaryDirectory(),
            maxConcurrentRequests: 1
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(runtime: runtime, maxConcurrentRequests: 1),
            scopedRecoveryStore: RecoveryStore(),
            deliveryReceiptKey: receiptKey,
            deferredDeliveryAuthority: DistillDeferredDeliveryAuthority(keyGenerator: { self.key })
        )
        return (server, try await server.start().baseURL)
    }

    private func post(
        _ body: DistillRequest,
        baseURL: String
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: baseURL + "/v1/distill")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer synthetic-bearer", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-RemoteCode-Delivery-Deferred")
        request.setValue("workspace", forHTTPHeaderField: "X-RemoteCode-Workspace-ID")
        request.setValue("project", forHTTPHeaderField: "X-RemoteCode-Project-ID")
        request.setValue("synthetic-thread", forHTTPHeaderField: "X-RemoteCode-Thread-ID")
        request.setValue("codex", forHTTPHeaderField: "X-RemoteCode-Provider")
        request.setValue("synthetic-attempt", forHTTPHeaderField: "X-RemoteCode-Attempt-ID")
        request.setValue("synthetic-root", forHTTPHeaderField: "X-RemoteCode-Root-Run-ID")
        request.setValue("invocation-a", forHTTPHeaderField: "X-RemoteCode-Invocation-ID")
        request.setValue("operation-a", forHTTPHeaderField: "X-RemoteCode-Operation-ID")
        request.setValue("managed-cli", forHTTPHeaderField: "X-RemoteCode-Producer-Family")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
