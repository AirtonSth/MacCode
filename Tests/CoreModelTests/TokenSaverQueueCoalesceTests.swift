import XCTest
@testable import CoreModel

final class TokenSaverQueueCoalesceTests: XCTestCase {
    func test_defaultOff() {
        XCTAssertFalse(TokenSaverQueueCoalesce.defaultEnabled)
        let rt = TokenSaverQueueCoalesceRuntime()
        XCTAssertEqual(rt.decideCoalesce(intent(id: "1"), intent(id: "2")), .notLive)
        XCTAssertNil(rt.buildCheckpoint(
            receipts: [.init(id: "1", kind: "tool", value: "ok")],
            narrativeFromMLX: nil,
            pendingMutation: false,
            pendingApproval: false
        ))
    }

    func test_pairwiseCoalesceAndNonAdditiveCorpus() {
        let rt = TokenSaverQueueCoalesceRuntime()
        rt.live = true
        rt.setOptIn(true)
        let t1 = Data("hello".utf8)
        let t2 = Data("world".utf8)
        let a = intent(id: "1", text: t1)
        let b = intent(id: "2", text: t2)
        let preview = rt.coalescePreview([a, b])
        XCTAssertEqual(preview.decision, .coalesce)
        XCTAssertEqual(preview.retainedCanonical, [t1, t2])

        // Third non-additive drains whole batch
        let replace = intent(id: "3", kind: .replace, text: Data("nope".utf8))
        XCTAssertEqual(rt.coalescePreview([a, b, replace]).decision, .nonAdditive)

        // Dispatch race
        let started = intent(id: "4", dispatchStarted: true)
        XCTAssertEqual(rt.coalescePreview([a, started]).decision, .dispatchStarted)

        for kind: TokenSaverQueueCoalesceRuntime.IntentKind in [.replace, .contradict, .modeChange, .attachmentOrder] {
            XCTAssertEqual(rt.decideCoalesce(a, intent(id: "x", kind: kind)), .nonAdditive)
        }
    }

    func test_compactionCAS_durableRelaunch_andHandles() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ts-c18-\(UUID().uuidString)")
        let store = try TokenSaverQueueCoalesceRuntime.FileDurabilityStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rt = TokenSaverQueueCoalesceRuntime(store: store)
        rt.live = true
        rt.setProviderAuthority(head: "head-1", generation: 3)
        let op = TokenSaverQueueCoalesceRuntime.CompactionOperationID(
            providerHead: "head-1", generation: 3, boundary: "b", rawHistoryDigest: "rawd"
        )

        XCTAssertFalse(rt.admitCompaction(pendingTool: true, pendingApproval: false, op: op))
        XCTAssertFalse(rt.admitCompaction(pendingTool: false, pendingApproval: true, op: op))
        // Wrong head fails CAS
        let badOp = TokenSaverQueueCoalesceRuntime.CompactionOperationID(
            providerHead: "other", generation: 3, boundary: "b", rawHistoryDigest: "rawd"
        )
        XCTAssertFalse(rt.admitCompaction(pendingTool: false, pendingApproval: false, op: badOp))

        XCTAssertTrue(rt.admitCompaction(pendingTool: false, pendingApproval: false, op: op))
        // commit without prior admit fails on new op
        let op2 = TokenSaverQueueCoalesceRuntime.CompactionOperationID(
            providerHead: "head-1", generation: 3, boundary: "b2", rawHistoryDigest: "r2"
        )
        XCTAssertFalse(rt.commit(op: op2, projection: .raw))

        // Compact requires markers + omissions
        let om = TokenSaverQueueCoalesceRuntime.Omission(handle: "h1", original: Data("secret-omission".utf8))
        XCTAssertFalse(rt.commit(op: op, projection: .compact, compactProjectionText: "no marker", omissions: [om]))
        let text = "kept \(om.marker) tail"
        XCTAssertTrue(rt.commit(op: op, projection: .compact, compactProjectionText: text, omissions: [om]))
        XCTAssertEqual(rt.projection(for: op), .compact)
        // No mix
        XCTAssertFalse(rt.commit(op: op, projection: .raw))
        XCTAssertEqual(rt.retrieveOmission(handle: "h1"), Data("secret-omission".utf8))
        // Immutable handle
        XCTAssertFalse(store.saveOmission(handle: "h1", data: Data("other".utf8)))

        // Relaunch: new runtime + same durable store recovers projection (crash matrix)
        let rt2 = TokenSaverQueueCoalesceRuntime(store: try TokenSaverQueueCoalesceRuntime.FileDurabilityStore(directory: dir))
        rt2.live = true
        XCTAssertEqual(rt2.projection(for: op), .compact)
        XCTAssertEqual(rt2.retrieveOmission(handle: "h1"), Data("secret-omission".utf8))
        // Cannot re-admit already committed
        XCTAssertFalse(rt2.admitCompaction(pendingTool: false, pendingApproval: false, op: op))
    }

    func test_checkpointReceiptsOnly() {
        let rt = TokenSaverQueueCoalesceRuntime()
        rt.live = true
        XCTAssertNil(rt.buildCheckpoint(
            receipts: [.init(id: "1", kind: "tool", value: "ok")],
            narrativeFromMLX: "n",
            pendingMutation: true,
            pendingApproval: false
        ))
        XCTAssertNil(rt.buildCheckpoint(
            receipts: [.init(id: "1", kind: "tool", value: "ok")],
            narrativeFromMLX: "n",
            pendingMutation: false,
            pendingApproval: true
        ))
        XCTAssertNil(rt.buildCheckpoint(
            receipts: [],
            narrativeFromMLX: nil,
            pendingMutation: false,
            pendingApproval: false
        ))
        let long = String(repeating: "x", count: 600)
        let cp = rt.buildCheckpoint(
            receipts: [.init(id: "t1", kind: "tool", value: "done")],
            narrativeFromMLX: long,
            pendingMutation: false,
            pendingApproval: false
        )!
        XCTAssertEqual(cp.receipts.count, 1)
        XCTAssertFalse(cp.emitsProviderTurn)
        XCTAssertEqual(cp.narrative?.count, 500)
    }

    private func intent(
        id: String,
        kind: TokenSaverQueueCoalesceRuntime.IntentKind = .additive,
        text: Data = Data("t".utf8),
        dispatchStarted: Bool = false
    ) -> TokenSaverQueueCoalesceRuntime.QueuedIntent {
        .init(
            id: id,
            userID: "u1",
            threadID: "th1",
            provider: "claude",
            model: "sonnet",
            generation: 1,
            kind: kind,
            canonicalText: text,
            dispatchStarted: dispatchStarted
        )
    }
}
