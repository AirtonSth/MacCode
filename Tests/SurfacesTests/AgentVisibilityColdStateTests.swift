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
                appFootprintBytes: 1_000 * 1024 * 1024
            )
        )
        XCTAssertFalse(
            AgentVisibilityColdState.shouldPromoteReclamation(
                savedBytes: 10 * 1024 * 1024,
                appFootprintBytes: 1_000 * 1024 * 1024
            )
        )
    }
}
