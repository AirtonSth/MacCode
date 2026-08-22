import CoreModel
import CryptoKit
import Foundation
import XCTest
@testable import AgentRuntime

final class DistillAppliedReceiptStreamVerifierTests: XCTestCase {
    private let scope = DistillAppliedReceiptStreamVerifier.Scope(
        rootRunID: "123e4567-e89b-12d3-a456-426614174000",
        key: Data(0..<32)
    )

    private func receipted(_ content: String, nonce: UInt8) throws -> String {
        let prefix = Data((content + "\n").utf8)
        let marker = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
            rootRunID: scope.rootRunID,
            payloadByteCount: prefix.count,
            payloadSHA256: Data(SHA256.hash(data: prefix)),
            key: scope.key,
            nonce: Data(repeating: nonce, count: 16)
        ))
        return String(decoding: prefix, as: UTF8.self) + marker + "\n"
    }

    func test_largeOutputAndSplitMarkerVerifyWithoutRetainingThePayload() throws {
        // WHY: live command output commonly exceeds UI caps. Receipt truth must
        // cover every byte even when the marker itself arrives across deltas.
        let wire = try receipted(String(repeating: "diagnostic line\n", count: 20_000), nonce: 1)
        let split = wire.index(wire.endIndex, offsetBy: -35)
        var verifier = DistillAppliedReceiptStreamVerifier()
        verifier.startItem(id: "tool", body: "", output: String(wire[..<split]))
        verifier.append(itemID: "tool", body: nil, output: String(wire[split...]))

        let verified = try XCTUnwrap(
            verifier.completeWithFingerprint(itemID: "tool", scope: scope)
        )
        let wireBytes = Data(wire.utf8)
        XCTAssertEqual(verified.output, AssistantContentFingerprint(
            byteCount: wireBytes.count,
            sha256: Data(SHA256.hash(data: wireBytes))
        ), "durable replay proof must cover every provider-visible byte")
        XCTAssertEqual(verified.body, AssistantContentFingerprint(
            byteCount: 0,
            sha256: Data(SHA256.hash(data: Data()))
        ))
    }

    func test_bytesAfterMarkerWrongRootAndWrongPayloadDoNotAttest() throws {
        // WHY: terminal placement and exact byte binding prevent quoted/replayed
        // syntax from becoming presentation truth.
        let valid = try receipted("compressed", nonce: 2)
        var trailing = DistillAppliedReceiptStreamVerifier()
        trailing.startItem(id: "trailing", body: "", output: valid + "after")
        XCTAssertFalse(trailing.complete(itemID: "trailing", scope: scope))

        var wrongRoot = DistillAppliedReceiptStreamVerifier()
        wrongRoot.startItem(id: "root", body: "", output: valid)
        XCTAssertFalse(wrongRoot.complete(
            itemID: "root",
            scope: .init(rootRunID: UUID().uuidString, key: scope.key)
        ))

        var changed = DistillAppliedReceiptStreamVerifier()
        changed.startItem(id: "changed", body: "", output: "changed" + valid)
        XCTAssertFalse(changed.complete(itemID: "changed", scope: scope))
    }

    func test_nonceIsConsumedOnceAndDeltaBeforeStartFailsSafe() throws {
        let valid = try receipted("compressed", nonce: 3)
        var verifier = DistillAppliedReceiptStreamVerifier()
        verifier.startItem(id: "first", body: "", output: valid)
        XCTAssertTrue(verifier.complete(itemID: "first", scope: scope))

        verifier.startItem(id: "replay", body: "", output: valid)
        XCTAssertFalse(verifier.complete(itemID: "replay", scope: scope))

        verifier.append(itemID: "late", body: nil, output: valid)
        verifier.startItem(id: "late", body: "", output: nil)
        XCTAssertFalse(verifier.complete(itemID: "late", scope: scope))
    }

    func test_standaloneFinalPayloadUsesTheSameBindingAndReplayGuard() throws {
        let valid = try receipted("final", nonce: 4)
        var verifier = DistillAppliedReceiptStreamVerifier()

        XCTAssertTrue(verifier.authenticateStandalone(valid, scope: scope))
        XCTAssertFalse(verifier.authenticateStandalone(valid, scope: scope))
    }

    func test_standaloneSanitizationValidationAllowsExactReplayWithoutMintingAuthority() throws {
        // WHY: providers repeat an authenticated assistant item in turnCompleted.
        // The replay may be stripped for display, but must not restore badge
        // authority after the nonce was already consumed.
        let valid = try receipted("final", nonce: 5)
        var verifier = DistillAppliedReceiptStreamVerifier()

        XCTAssertTrue(verifier.authenticateStandalone(valid, scope: scope))
        XCTAssertTrue(verifier.validatesStandaloneForSanitization(valid, scope: scope))
        XCTAssertFalse(verifier.authenticateStandalone(valid, scope: scope),
                       "display validation must not mint fresh receipt authority")
    }

    func test_nonceCapacityFailsClosedWithoutReenablingReplay() throws {
        // WHY: a pathological long run must stay memory-bounded without evicting
        // old nonces, because eviction would make a captured receipt reusable.
        let prefix = Data("bounded\n".utf8)
        let firstText = try receipted(prefix: prefix, nonce: nonce(0))
        var verifier = DistillAppliedReceiptStreamVerifier()

        XCTAssertTrue(verifier.authenticateStandalone(firstText, scope: scope))
        for index in 1..<DistillAppliedReceiptStreamVerifier.maximumTrackedReceiptNoncesPerRun {
            XCTAssertTrue(verifier.authenticateStandalone(
                try receipted(prefix: prefix, nonce: nonce(index)),
                scope: scope
            ))
        }

        XCTAssertFalse(verifier.authenticateStandalone(
            try receipted(
                prefix: prefix,
                nonce: nonce(DistillAppliedReceiptStreamVerifier.maximumTrackedReceiptNoncesPerRun)
            ),
            scope: scope
        ), "saturation must fail closed instead of growing the nonce set")
        XCTAssertFalse(verifier.authenticateStandalone(firstText, scope: scope),
                       "the oldest nonce must remain consumed after saturation")
    }

    private func nonce(_ value: Int) -> Data {
        var encoded = UInt64(value).bigEndian
        var data = Data(repeating: 0, count: 8)
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
        return data
    }

    private func receipted(prefix: Data, nonce: Data) throws -> String {
        let marker = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
            rootRunID: scope.rootRunID,
            payload: prefix,
            key: scope.key,
            nonce: nonce
        ))
        return String(decoding: prefix, as: UTF8.self) + marker
    }
}
