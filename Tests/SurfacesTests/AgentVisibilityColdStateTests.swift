import XCTest
@testable import Surfaces

/// S6: visibility cold-state generation safety + checkpoint retention.
final class AgentVisibilityColdStateTests: XCTestCase {
    func test_hideReveal_generationSafeAndPreservesCheckpoint() {
        var session = AgentVisibilitySession()
        let checkpoint = AgentPresentationCheckpoint(
            durableSequence: 10,
            lastAppliedDurableSequence: 9,
            selectedThreadId: "t1",
            composerText: "draft",
            attachmentIds: ["a1"],
            browserURL: "https://example.com",
            browserTitle: "Example",
            stopOwned: true
        )
        session = AgentVisibilityColdState.didBecomeHidden(session: session, checkpoint: checkpoint)
        XCTAssertEqual(session.state, .hidden)
        XCTAssertEqual(session.checkpoint.composerText, "draft")
        XCTAssertEqual(session.checkpoint.browserURL, "https://example.com")
        XCTAssertTrue(session.checkpoint.stopOwned)
        XCTAssertTrue(session.retainsCompactDirtyOnly)

        session = AgentVisibilityColdState.beginReveal(session: session)
        XCTAssertEqual(session.state, .restoring)
        let gen = session.generation
        let done = AgentVisibilityColdState.completeReveal(
            session: session,
            expectedGeneration: gen,
            appliedThroughSequence: 12
        )
        XCTAssertEqual(done?.state, .visible)
        XCTAssertEqual(done?.checkpoint.lastAppliedDurableSequence, 12)

        let stale = AgentVisibilityColdState.completeReveal(
            session: session,
            expectedGeneration: gen - 1,
            appliedThroughSequence: 99
        )
        XCTAssertNil(stale)
    }

    func test_globalLRU_disabledUntilMeasuredBreach() {
        XCTAssertFalse(AgentVisibilityColdState.globalAgentLRUEnabled)
    }

    func test_promotionThreshold() {
        XCTAssertTrue(
            AgentVisibilityColdState.shouldPromoteReclamation(
                savedBytes: 200 * 1024 * 1024,
                appFootprintBytes: 1_000 * 1024 * 1024,
                revealP95Ms: 100,
                revealP99Ms: 200,
                mainActorStallMs: 50,
                duplicateOrMissingEvents: false
            )
        )
        XCTAssertFalse(
            AgentVisibilityColdState.shouldPromoteReclamation(
                savedBytes: 10 * 1024 * 1024,
                appFootprintBytes: 1_000 * 1024 * 1024,
                revealP95Ms: 100,
                revealP99Ms: 200,
                mainActorStallMs: 50,
                duplicateOrMissingEvents: false
            )
        )
        XCTAssertFalse(
            AgentVisibilityColdState.shouldPromoteReclamation(
                savedBytes: 200 * 1024 * 1024,
                appFootprintBytes: 1_000 * 1024 * 1024,
                revealP95Ms: 900,
                revealP99Ms: 200,
                mainActorStallMs: 50,
                duplicateOrMissingEvents: false
            ),
            "reveal p95 breach must block promotion"
        )
    }

    func test_completeReveal_rejectsDuplicateAndIncompleteCatchUp() {
        var session = AgentVisibilitySession()
        session = AgentVisibilityColdState.didBecomeHidden(
            session: session,
            checkpoint: AgentPresentationCheckpoint(durableSequence: 10, lastAppliedDurableSequence: 9)
        )
        session = AgentVisibilityColdState.beginReveal(session: session)
        let gen = session.generation
        let first = AgentVisibilityColdState.completeReveal(
            session: session,
            expectedGeneration: gen,
            appliedThroughSequence: 10
        )
        XCTAssertEqual(first?.state, .visible)
        // Duplicate completion after visible must fail.
        XCTAssertNil(
            AgentVisibilityColdState.completeReveal(
                session: first!,
                expectedGeneration: gen,
                appliedThroughSequence: 11
            )
        )
        // Incomplete catch-up while restoring must fail.
        session = AgentVisibilityColdState.beginReveal(session: first!)
        XCTAssertNil(
            AgentVisibilityColdState.completeReveal(
                session: session,
                expectedGeneration: session.generation,
                appliedThroughSequence: 5
            )
        )
    }
}
