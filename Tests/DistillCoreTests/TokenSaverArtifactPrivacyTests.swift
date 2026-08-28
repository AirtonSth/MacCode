import CoreModel
import CryptoKit
import DistillSavingsPersistenceSupport
import Persistence
import XCTest
@testable import DistillCore

final class TokenSaverArtifactPrivacyTests: XCTestCase {
    private final class EventCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        func read() -> Int { lock.withLock { value } }
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
            return .init(
                capability: "synthetic-private-capability",
                idempotencyKey: context.operationID,
                readBackVerified: true
            )
        }

        func retrieveOriginal(
            capability: String,
            context: TokenSaverRecoveryRequestContext
        ) throws -> Data? {
            lock.withLock { original }
        }

        func markDelivered(
            capability: String,
            idempotencyKey: String,
            context: TokenSaverRecoveryRequestContext,
            outcome: TokenSaverScopedDeliveryOutcome
        ) throws -> Bool {
            try retrieveOriginal(capability: capability, context: context) != nil
        }

        func ack(
            capability: String,
            idempotencyKey: String,
            context: TokenSaverRecoveryRequestContext
        ) throws -> Bool { true }
    }

    private struct Runtime: DistillRuntime {
        let output: String
        func distill(_ request: DistillRequest) async throws -> String { output }
        func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
            .init(output: output, stage: .deterministic)
        }
    }

    func test_twoPostReceiptsAndArtifactsAreSyntheticAndRedacted() async throws {
        // WHY: the real two-POST path handles raw provider bytes and two signing
        // materials. Durable proof may retain their SHA-256 digests, never values.
        let original = String(repeating: "PRIVATE_ORIGINAL_SENTINEL_7D36\n", count: 60)
        let accounting = "PRIVATE_ACCOUNTING_SENTINEL_9A42"
        let bearer = "PRIVATE_BEARER_SENTINEL_31C8"
        let serverKey = Data(repeating: 0xa1, count: 32)
        let receiptKey = Data(repeating: 0xb2, count: 32)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenSaverPrivacy-\(UUID().uuidString)", isDirectory: true)
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        for directory in [
            appSupport,
            artifacts,
            root.appendingPathComponent("home", isDirectory: true),
            root.appendingPathComponent("workspace", isDirectory: true),
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let db = try SQLiteDB(path: root.appendingPathComponent("token-saver.sqlite").path)
        try Schema.migrate(db)
        let repository = TokenSaverSavingsRepository(db: db)
        let events = EventCounter()
        let recorder = DeferredSavingsRecorder(
            repository: repository,
            eventSink: { _ in events.increment() }
        )
        let configuration = try DistillServiceConfiguration(
            authToken: bearer,
            appSupportDirectory: appSupport.path,
            maxConcurrentRequests: 1
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: DistillScheduler(
                runtime: Runtime(output: accounting),
                maxConcurrentRequests: 1
            ),
            scopedRecoveryStore: RecoveryStore(),
            onSuccess: recorder.successHandler,
            deliveryReceiptKeyProvider: { receiptKey },
            deferredDeliveryAuthority: .init(keyGenerator: { serverKey })
        )
        let ready = try await server.start()
        let baseURL = try XCTUnwrap(URL(string: ready.baseURL))
        defer { server.stop() }

        let initial = DistillRequest(
            mode: .commandOutput,
            input: original,
            provider: "codex",
            recordSavings: false,
            producerFamily: "managed-retrieve-mcp",
            deferredOperationID: "synthetic-operation"
        )
        let phaseOneResult = try await post(initial, baseURL: baseURL, bearer: bearer)
        XCTAssertEqual(phaseOneResult.status, 200)
        let phaseOne = try JSONDecoder().decode(DistillResponse.self, from: phaseOneResult.data)
        let token = try XCTUnwrap(phaseOne.deferredDeliveryToken)
        let prefix = try XCTUnwrap(phaseOne.providerVisiblePrefix)
        let tokenPayload = try decodedTokenPayload(token)
        for forbidden in [
            original, accounting, serverKey.base64EncodedString(), receiptKey.base64EncodedString(),
            hex(serverKey), hex(receiptKey),
        ] {
            XCTAssertFalse(tokenPayload.contains(forbidden), "opaque authority token leaked raw material")
        }
        XCTAssertTrue(tokenPayload.contains(sha256(original)))
        XCTAssertTrue(tokenPayload.contains(sha256(accounting)))
        let marker = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
            rootRunID: "synthetic-root",
            payload: Data(prefix.utf8),
            key: receiptKey
        ))
        let delivered = prefix + marker + "\n"

        let phaseOneArtifact: [String: Any] = [
            "phase": 1,
            "status": phaseOneResult.status,
            "request_id_sha256": sha256(initial.id.uuidString.lowercased()),
            "original_sha256": sha256(original),
            "accounting_output_sha256": sha256(try XCTUnwrap(phaseOne.accountingOutput)),
            "deferred_token_sha256": sha256(token),
        ]
        try writeArtifact(phaseOneArtifact, to: artifacts.appendingPathComponent("phase-one.json"))
        XCTAssertEqual(try repository.summary().totalRuns, 0)
        XCTAssertEqual(events.read(), 0)

        let final = DistillRequest(
            id: initial.id,
            mode: initial.mode,
            input: original,
            provider: initial.provider,
            recordSavings: true,
            precomputedRouteStage: phaseOne.routeStage,
            precomputedRecoveryConfirmations: DistillDeferredDelivery.recoveryConfirmations(phaseOne),
            deferredDeliveryToken: token,
            accountingOutput: phaseOne.accountingOutput,
            deliveredOutput: delivered,
            producerFamily: initial.producerFamily,
            deferredOperationID: initial.deferredOperationID
        )
        let handoffDeadline = try XCTUnwrap(
            DistillDeferredDelivery.handoffDeadlineUnixMilliseconds()
        )
        XCTAssertNil(final.deferredHandoffDeadlineUnixMilliseconds)
        let phaseTwoResult = try await post(
            final,
            baseURL: baseURL,
            bearer: bearer,
            handoffDeadlineUnixMilliseconds: handoffDeadline
        )
        XCTAssertEqual(phaseTwoResult.status, 200, String(decoding: phaseTwoResult.data, as: UTF8.self))
        let phaseTwoArtifact: [String: Any] = [
            "phase": 2,
            "status": phaseTwoResult.status,
            "delivered_output_sha256": sha256(delivered),
            "repository_runs": try repository.summary().totalRuns,
            "event_count": events.read(),
        ]
        try writeArtifact(phaseTwoArtifact, to: artifacts.appendingPathComponent("phase-two.json"))

        let artifactURLs = try FileManager.default.contentsOfDirectory(
            at: artifacts,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var artifactData = Data()
        for artifactURL in artifactURLs {
            artifactData.append(try Data(contentsOf: artifactURL))
        }
        let artifactText = String(decoding: artifactData, as: UTF8.self)
        for forbidden in [
            original, accounting, token, bearer,
            serverKey.base64EncodedString(), receiptKey.base64EncodedString(),
            hex(serverKey), hex(receiptKey),
            "synthetic-private-capability", marker, root.path,
        ] {
            XCTAssertFalse(artifactText.contains(forbidden), "durable artifact leaked \(forbidden.prefix(24))")
        }
        for allowedDigest in [sha256(original), sha256(accounting), sha256(token), sha256(delivered)] {
            XCTAssertTrue(artifactText.contains(allowedDigest), "digest-only evidence is allowlisted")
        }
        XCTAssertEqual(try repository.summary().totalRuns, 1)
        XCTAssertEqual(events.read(), 1)
    }

    func test_receiptsAndUploadAllowlistAreRedacted() throws {
        // WHY: S-001 has exactly two source-bearing upload artifacts. Everything
        // else is metadata/digest-only, and neither class may contain user paths
        // or raw two-POST secrets.
        let expectedAllowlist = [
            "/private/tmp/remotecode-token-saver-bots-goal-20260827/plan/receipts/S-001/red-tests.patch",
            "/private/tmp/remotecode-token-saver-bots-goal-20260827/plan/receipts/S-001/red-hunks.json",
        ]
        let planURL = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_PLAN_REPORT"]
                ?? "/private/tmp/remotecode-token-saver-bots-goal-20260827/plan/plan-report.json"
        )
        var allowlist = expectedAllowlist
        if FileManager.default.fileExists(atPath: planURL.path) {
            let plan = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: planURL)) as? [String: Any]
            )
            let policy = try XCTUnwrap(plan["fixture_and_artifact_policy"] as? [String: Any])
            allowlist = try XCTUnwrap(policy["privacy_test_artifact_allowlist"] as? [String])
            XCTAssertEqual(allowlist, expectedAllowlist, "the frozen upload allowlist must not widen")
        }

        XCTAssertEqual(Set(allowlist.map { URL(fileURLWithPath: $0).lastPathComponent }), [
            "red-tests.patch", "red-hunks.json",
        ])
        let existingUploadArtifacts = allowlist.filter(FileManager.default.fileExists(atPath:))
        if FileManager.default.fileExists(atPath: planURL.path) {
            XCTAssertEqual(existingUploadArtifacts, allowlist, "the frozen workflow must scan both real S-001 artifacts")
        }

        let receiptsRoot = URL(fileURLWithPath: expectedAllowlist[0])
            .deletingLastPathComponent().deletingLastPathComponent()
        let durableArtifacts: [URL]
        if FileManager.default.fileExists(atPath: receiptsRoot.path) {
            durableArtifacts = try FileManager.default.subpathsOfDirectory(atPath: receiptsRoot.path)
                .map { receiptsRoot.appendingPathComponent($0) }
                .filter {
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                        && !isDirectory.boolValue
                }
        } else {
            durableArtifacts = []
        }
        let uploadPaths = Set(allowlist)
        let metadataArtifacts = durableArtifacts.filter { !uploadPaths.contains($0.path) }
        let forbiddenFragments = [
            "/Users/", NSUserName(), "PRIVATE_ORIGINAL_SENTINEL_7D36",
            "PRIVATE_ACCOUNTING_SENTINEL_9A42", "PRIVATE_BEARER_SENTINEL_31C8",
            "[[rcd:v2.", "synthetic-private-capability",
        ].filter { !$0.isEmpty }

        for artifact in metadataArtifacts {
            let text = String(decoding: try Data(contentsOf: artifact), as: UTF8.self)
            for forbidden in forbiddenFragments {
                XCTAssertFalse(text.contains(forbidden), "metadata artifact leaked \(forbidden): \(artifact.path)")
            }
        }
        for artifactPath in existingUploadArtifacts {
            let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: artifactPath)), as: UTF8.self)
            for forbidden in forbiddenFragments {
                XCTAssertFalse(text.contains(forbidden), "upload artifact leaked \(forbidden): \(artifactPath)")
            }
        }
    }

    private func post(
        _ body: DistillRequest,
        baseURL: URL,
        bearer: String,
        handoffDeadlineUnixMilliseconds: UInt64? = nil
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/distill"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        for (field, value) in [
            "Authorization": "Bearer \(bearer)",
            "Content-Type": "application/json",
            "X-RemoteCode-Delivery-Deferred": "1",
            "X-RemoteCode-Workspace-ID": "synthetic-workspace",
            "X-RemoteCode-Project-ID": "synthetic-project",
            "X-RemoteCode-Thread-ID": "synthetic-thread",
            "X-RemoteCode-Provider": "codex",
            "X-RemoteCode-Attempt-ID": "synthetic-attempt",
            "X-RemoteCode-Root-Run-ID": "synthetic-root",
            "X-RemoteCode-Invocation-ID": "synthetic-invocation",
            "X-RemoteCode-Operation-ID": "synthetic-operation",
            "X-RemoteCode-Producer-Family": "managed-retrieve-mcp",
        ] { request.setValue(value, forHTTPHeaderField: field) }
        if let handoffDeadlineUnixMilliseconds {
            request.setValue(
                String(handoffDeadlineUnixMilliseconds),
                forHTTPHeaderField: DistillDeferredDelivery.handoffDeadlineHeader
            )
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func writeArtifact(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func sha256(_ value: String) -> String {
        hex(Data(SHA256.hash(data: Data(value.utf8))))
    }

    private func decodedTokenPayload(_ token: String) throws -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3)
        var value = String(try XCTUnwrap(parts.dropFirst().first))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return String(decoding: try XCTUnwrap(Data(base64Encoded: value)), as: UTF8.self)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
