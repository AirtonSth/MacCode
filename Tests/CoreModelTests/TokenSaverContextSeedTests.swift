import CryptoKit
import XCTest
@testable import CoreModel

/// WHY: a fresh Codex destination after failed resume must reconstruct prior
/// turns from a host-owned seed. A broken codec would either drop role/order
/// or let a partial document leak into the provider session.
final class TokenSaverContextSeedTests: XCTestCase {
    func test_versionIsRCSEED1v1() {
        XCTAssertEqual(TokenSaverContextSeed.version, "RCSEED1/1")
    }

    func test_roundtripPreservesRoleOrderAndSelectedPayloads() throws {
        // WHY: the destination must rebuild the canonical conversation
        // deterministically from selected representations, not from a later
        // Human rewrite.
        let digest = "a".repeatedHex
        let document = try XCTUnwrap(TokenSaverContextSeed.encode(
            snapshotDigest: digest,
            items: [
                .init(role: .user, ordinal: 0, sourceMessageId: "u1", format: .human, payload: "prior user"),
                .init(role: .assistant, ordinal: 1, sourceMessageId: "a1", format: .rcs1, payload: rcs1Payload),
            ]
        ))
        XCTAssertTrue(document.hasPrefix("RCSEED1/1\n"))
        let decoded = try XCTUnwrap(TokenSaverContextSeed.decode(document))
        XCTAssertEqual(decoded.snapshotDigest, digest)
        XCTAssertEqual(decoded.items.map(\.role), [.user, .assistant])
        XCTAssertEqual(decoded.items.map(\.ordinal), [0, 1])
        XCTAssertEqual(decoded.items.map(\.format), [.human, .rcs1])
        XCTAssertEqual(decoded.items.map(\.payload), ["prior user", rcs1Payload])
        XCTAssertEqual(TokenSaverContextSeed.encode(snapshotDigest: digest, items: decoded.items), document)
    }

    func test_emptyOrPartialDocumentsAreRejected() {
        // WHY: an incomplete seed would teach the fresh session a truncated
        // history. Fail closed instead of emitting a prefix.
        XCTAssertNil(TokenSaverContextSeed.encode(snapshotDigest: "ab", items: []))
        XCTAssertNil(TokenSaverContextSeed.decode(""))
        XCTAssertNil(TokenSaverContextSeed.decode("RCSEED1/1\n"))
        XCTAssertNil(TokenSaverContextSeed.decode("RCSEED1/1\nH\t1\tab\nI\t0\tuser\thuman\t4\nONLY"))
        XCTAssertNil(TokenSaverContextSeed.decode("RCW1\tA\t1\nO\tnope\n.\n"))
    }

    func test_oversizedSnapshotIsRejectedWithoutPartialEncode() {
        // WHY: existing compact-span / transcript bounds are the host ceiling.
        // Crossing them must not produce a truncated seed.
        let huge = String(repeating: "Z", count: TokenSaverContextSeed.maxEncodedBytes + 1)
        XCTAssertNil(TokenSaverContextSeed.encode(
            snapshotDigest: "cd",
            items: [.init(role: .user, ordinal: 0, sourceMessageId: "u", format: .human, payload: huge)]
        ))
    }

    func test_snapshotExcludesCurrentPromptAndDigestsPriorOrder() {
        // WHY: the current user turn is sent separately. Including it in the
        // snapshot would duplicate the prompt on the fresh destination.
        let thread = AgentThreadID()
        let priorUser = AgentMessage(threadId: thread, role: .user, content: "first question")
        let priorAssistant = AgentMessage(threadId: thread, role: .assistant, content: repeatingHuman)
        let current = AgentMessage(threadId: thread, role: .user, content: "follow up now")
        let snapshot = try? XCTUnwrap(TokenSaverCanonicalConversationSnapshot.capture(
            messages: [priorUser, priorAssistant, current],
            persistedRCW1ByMessageId: [:],
            excludingCurrentUserText: "follow up now"
        ))
        XCTAssertEqual(snapshot?.items.map(\.canonicalText), ["first question", repeatingHuman])
        XCTAssertEqual(snapshot?.items.map(\.role), [.user, .assistant])
        XCTAssertEqual(snapshot?.items.map(\.ordinal), [0, 1])
        XCTAssertFalse(snapshot?.items.contains(where: { $0.canonicalText == "follow up now" }) ?? true)

        let empty = TokenSaverCanonicalConversationSnapshot.capture(
            messages: [current],
            persistedRCW1ByMessageId: [:],
            excludingCurrentUserText: "follow up now"
        )
        XCTAssertNil(empty, "no prior context must not invent an empty seed snapshot")
    }

    func test_snapshotDigestChangesWhenPriorConversationChanges() throws {
        let thread = AgentThreadID()
        let user = AgentMessage(threadId: thread, role: .user, content: "q")
        let assistant = AgentMessage(threadId: thread, role: .assistant, content: "a")
        let first = try XCTUnwrap(TokenSaverCanonicalConversationSnapshot.capture(
            messages: [user, assistant],
            persistedRCW1ByMessageId: [:],
            excludingCurrentUserText: "later"
        ))
        let extra = AgentMessage(threadId: thread, role: .assistant, content: "more")
        let second = try XCTUnwrap(TokenSaverCanonicalConversationSnapshot.capture(
            messages: [user, assistant, extra],
            persistedRCW1ByMessageId: [:],
            excludingCurrentUserText: "later"
        ))
        XCTAssertNotEqual(first.digest, second.digest)
    }

    private var repeatingHuman: String { String(repeating: "ABCDEFGH", count: 16) }
    private var rcs1Payload: String {
        RemoteCodeCompactSpan.encode(repeatingHuman) ?? "RCS1/1\nmissing"
    }
}

private extension String {
    var repeatedHex: String {
        SHA256.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
