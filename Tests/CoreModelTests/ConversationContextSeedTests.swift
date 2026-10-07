import CryptoKit
import XCTest
@testable import CoreModel

/// WHY: a fresh Codex destination after failed resume must reconstruct prior
/// turns from a host-owned seed. A broken codec would either drop role/order
/// or let a partial document leak into the provider session.
final class ConversationContextSeedTests: XCTestCase {
    func test_versionIsRCSEED1v1() {
        XCTAssertEqual(ConversationContextSeed.version, "RCSEED1/1")
    }

    func test_roundtripPreservesRoleOrderAndPayloads() throws {
        // WHY: the destination must rebuild the conversation deterministically.
        let digest = "a".repeatedHex
        let document = try XCTUnwrap(ConversationContextSeed.encode(
            snapshotDigest: digest,
            items: [
                .init(role: .user, ordinal: 0, sourceMessageId: "u1", payload: "prior user"),
                .init(role: .assistant, ordinal: 1, sourceMessageId: "a1", payload: repeatingHuman),
            ]
        ))
        XCTAssertTrue(document.hasPrefix("RCSEED1/1\n"))
        XCTAssertTrue(document.contains("I\t0\tuser\thuman\t10\tu1\n"), "wire layout keeps the Human format field")
        let decoded = try XCTUnwrap(ConversationContextSeed.decode(document))
        XCTAssertEqual(decoded.snapshotDigest, digest)
        XCTAssertEqual(decoded.items.map(\.role), [.user, .assistant])
        XCTAssertEqual(decoded.items.map(\.ordinal), [0, 1])
        XCTAssertEqual(decoded.items.map(\.payload), ["prior user", repeatingHuman])
        XCTAssertEqual(ConversationContextSeed.encode(snapshotDigest: digest, items: decoded.items), document)
    }

    func test_emptyOrPartialDocumentsAreRejected() {
        // WHY: an incomplete seed would teach the fresh session a truncated
        // history. Fail closed instead of emitting a prefix.
        XCTAssertNil(ConversationContextSeed.encode(snapshotDigest: "ab", items: []))
        XCTAssertNil(ConversationContextSeed.decode(""))
        XCTAssertNil(ConversationContextSeed.decode("RCSEED1/1\n"))
        XCTAssertNil(ConversationContextSeed.decode("RCSEED1/1\nH\t1\tab\nI\t0\tuser\thuman\t4\nONLY"))
        XCTAssertNil(ConversationContextSeed.decode("RCW1\tA\t1\nO\tnope\n.\n"))
    }

    func test_oversizedSnapshotIsRejectedWithoutPartialEncode() {
        // WHY: crossing the seed bounds must not produce a truncated seed.
        let huge = String(repeating: "Z", count: ConversationContextSeed.maxEncodedBytes + 1)
        XCTAssertNil(ConversationContextSeed.encode(
            snapshotDigest: "cd",
            items: [.init(role: .user, ordinal: 0, sourceMessageId: "u", payload: huge)]
        ))
    }

    func test_snapshotExcludesCurrentPromptAndDigestsPriorOrder() {
        // WHY: the current user turn is sent separately. Including it in the
        // snapshot would duplicate the prompt on the fresh destination.
        let thread = AgentThreadID()
        let priorUser = AgentMessage(threadId: thread, role: .user, content: "first question")
        let priorAssistant = AgentMessage(threadId: thread, role: .assistant, content: repeatingHuman)
        let current = AgentMessage(threadId: thread, role: .user, content: "follow up now")
        let snapshot = ConversationContextSnapshot.capture(
            messages: [priorUser, priorAssistant, current],
            excludingCurrentUserText: "follow up now"
        )
        XCTAssertEqual(snapshot?.items.map(\.canonicalText), ["first question", repeatingHuman])
        XCTAssertEqual(snapshot?.items.map(\.role), [.user, .assistant])
        XCTAssertEqual(snapshot?.items.map(\.ordinal), [0, 1])
        XCTAssertFalse(snapshot?.items.contains(where: { $0.canonicalText == "follow up now" }) ?? true)

        let empty = ConversationContextSnapshot.capture(
            messages: [current],
            excludingCurrentUserText: "follow up now"
        )
        XCTAssertNil(empty, "no prior context must not invent an empty seed snapshot")
    }

    func test_snapshotExcludesCurrentUserByMessageIdWhenContentDiffers() {
        // WHY: Desk stores Human on the run-id user row while the provider
        // prompt is the compiled envelope. Text equality would keep the
        // current turn in the seed and duplicate it on Codex fresh fallback.
        let thread = AgentThreadID()
        let priorUser = AgentMessage(threadId: thread, role: .user, content: "first question")
        let priorAssistant = AgentMessage(threadId: thread, role: .assistant, content: repeatingHuman)
        let current = AgentMessage(
            id: AgentMessageID(),
            threadId: thread,
            role: .user,
            content: "teammate line"
        )
        let snapshot = ConversationContextSnapshot.capture(
            messages: [priorUser, priorAssistant, current],
            excludingCurrentUserText: "compiled provider envelope",
            excludingCurrentUserMessageId: current.id
        )
        XCTAssertEqual(snapshot?.items.map(\.canonicalText), ["first question", repeatingHuman])
        XCTAssertFalse(
            snapshot?.items.contains(where: { $0.messageId == current.id.value.uuidString }) ?? true
        )
        let empty = ConversationContextSnapshot.capture(
            messages: [current],
            excludingCurrentUserText: "compiled provider envelope",
            excludingCurrentUserMessageId: current.id
        )
        XCTAssertNil(empty, "excluding the only row by id must not invent a seed")
    }

    func test_snapshotDigestChangesWhenPriorConversationChanges() throws {
        let thread = AgentThreadID()
        let user = AgentMessage(threadId: thread, role: .user, content: "q")
        let assistant = AgentMessage(threadId: thread, role: .assistant, content: "a")
        let first = try XCTUnwrap(ConversationContextSnapshot.capture(
            messages: [user, assistant],
            excludingCurrentUserText: "later"
        ))
        let extra = AgentMessage(threadId: thread, role: .assistant, content: "more")
        let second = try XCTUnwrap(ConversationContextSnapshot.capture(
            messages: [user, assistant, extra],
            excludingCurrentUserText: "later"
        ))
        XCTAssertNotEqual(first.digest, second.digest)
    }

    func test_preparedSeedOmitsCurrentPromptAndCarriesStoredText() throws {
        // WHY: the fresh session must get the stored Human text of every prior
        // turn, never the current prompt, which is sent on its own.
        let snapshot = try XCTUnwrap(ConversationContextSnapshot.capture(
            messages: [
                AgentMessage(threadId: AgentThreadID(), role: .user, content: "prior user"),
                AgentMessage(threadId: AgentThreadID(), role: .assistant, content: repeatingHuman),
                AgentMessage(threadId: AgentThreadID(), role: .user, content: "current"),
            ],
            excludingCurrentUserText: "current"
        ))
        let prepared = try XCTUnwrap(ConversationContextSeed.prepare(snapshot: snapshot))
        XCTAssertEqual(prepared.document.items.map(\.role), [.user, .assistant])
        XCTAssertEqual(prepared.document.items.map(\.payload), ["prior user", repeatingHuman])
        XCTAssertEqual(ConversationContextSeed.decode(prepared.encoded), prepared.document)
    }

    func test_prepareRejectsASnapshotWhoseDigestDoesNotMatchItsItems() throws {
        // WHY: a stale or tampered snapshot must not be sent as current context.
        let snapshot = try XCTUnwrap(ConversationContextSnapshot.capture(
            messages: [AgentMessage(threadId: AgentThreadID(), role: .user, content: "q")],
            excludingCurrentUserText: nil
        ))
        let forged = ConversationContextSnapshot(items: snapshot.items, digest: "b".repeatedHex)
        XCTAssertNil(ConversationContextSeed.prepare(snapshot: forged))
    }

    private var repeatingHuman: String { String(repeating: "ABCDEFGH", count: 16) }
}

private extension String {
    var repeatedHex: String {
        SHA256.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
