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
        XCTAssertEqual(store.saveOmission(handle: "h1", data: Data("other".utf8)), .conflict)
        XCTAssertEqual(store.saveOmission(handle: "h1", data: Data("secret-omission".utf8)), .alreadyIdentical)

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

    func test_admitRequiresInitializedAuthority() {
        let rt = TokenSaverQueueCoalesceRuntime()
        rt.live = true
        let op = TokenSaverQueueCoalesceRuntime.CompactionOperationID(
            providerHead: "h", generation: 1, boundary: "b", rawHistoryDigest: "r"
        )
        // Unset authority (empty head / zero gen) fails closed — no wildcards.
        XCTAssertFalse(rt.admitCompaction(pendingTool: false, pendingApproval: false, op: op))
        rt.setProviderAuthority(head: "h", generation: 1)
        XCTAssertTrue(rt.admitCompaction(pendingTool: false, pendingApproval: false, op: op))
    }

    func test_compactMarkers_requireExactBijection() {
        let rt = TokenSaverQueueCoalesceRuntime()
        rt.live = true
        rt.setProviderAuthority(head: "head-1", generation: 2)
        let op = TokenSaverQueueCoalesceRuntime.CompactionOperationID(
            providerHead: "head-1", generation: 2, boundary: "bx", rawHistoryDigest: "rx"
        )
        XCTAssertTrue(rt.admitCompaction(pendingTool: false, pendingApproval: false, op: op))
        let om = TokenSaverQueueCoalesceRuntime.Omission(handle: "h1", original: Data("orig".utf8))
        // Extra unresolved marker in text must fail.
        let extra = "kept \(om.marker) and [[rc:orphan]]"
        XCTAssertFalse(rt.commit(op: op, projection: .compact, compactProjectionText: extra, omissions: [om]))
        XCTAssertNil(rt.projection(for: op))
        XCTAssertNil(rt.retrieveOmission(handle: "h1"))
        // Malformed empty handle stub must fail
        XCTAssertFalse(rt.commit(
            op: op,
            projection: .compact,
            compactProjectionText: "\(om.marker) [[rc:]]",
            omissions: [om]
        ))
        // Missing marker fails
        XCTAssertFalse(rt.commit(op: op, projection: .compact, compactProjectionText: "no markers", omissions: [om]))
        // Exact bijection succeeds
        XCTAssertTrue(rt.commit(op: op, projection: .compact, compactProjectionText: "x \(om.marker) y", omissions: [om]))
        XCTAssertEqual(rt.retrieveOmission(handle: "h1"), Data("orig".utf8))
    }

    func test_rollback_doesNotDeletePreexistingIdenticalOmission() {
        let store = TokenSaverQueueCoalesceRuntime.MemoryDurabilityStore()
        // Pre-seed shared original used by a prior compact.
        XCTAssertEqual(store.saveOmission(handle: "shared", data: Data("keep-me".utf8)), .created)
        final class FailProjStore: TokenSaverQueueCoalesceRuntime.DurabilityStore, @unchecked Sendable {
            let inner: TokenSaverQueueCoalesceRuntime.MemoryDurabilityStore
            init(_ inner: TokenSaverQueueCoalesceRuntime.MemoryDurabilityStore) { self.inner = inner }
            func loadProjection(key: String) -> TokenSaverQueueCoalesceRuntime.Projection? { inner.loadProjection(key: key) }
            func saveProjection(key: String, projection: TokenSaverQueueCoalesceRuntime.Projection) -> Bool { false }
            func deleteProjection(key: String) { inner.deleteProjection(key: key) }
            func loadOmission(handle: String) -> Data? { inner.loadOmission(handle: handle) }
            func saveOmission(handle: String, data: Data) -> TokenSaverQueueCoalesceRuntime.OmissionSaveResult {
                inner.saveOmission(handle: handle, data: data)
            }
            func deleteOmission(handle: String) { inner.deleteOmission(handle: handle) }
        }
        let rt = TokenSaverQueueCoalesceRuntime(store: FailProjStore(store))
        rt.live = true
        rt.setProviderAuthority(head: "h", generation: 1)
        let op = TokenSaverQueueCoalesceRuntime.CompactionOperationID(
            providerHead: "h", generation: 1, boundary: "nb", rawHistoryDigest: "nr"
        )
        XCTAssertTrue(rt.admitCompaction(pendingTool: false, pendingApproval: false, op: op))
        let om = TokenSaverQueueCoalesceRuntime.Omission(handle: "shared", original: Data("keep-me".utf8))
        XCTAssertFalse(rt.commit(op: op, projection: .compact, compactProjectionText: om.marker, omissions: [om]))
        // Pre-existing original must survive projection CAS failure rollback.
        XCTAssertEqual(store.loadOmission(handle: "shared"), Data("keep-me".utf8))
    }

    func test_storeBeforeLoss_originalsBeforeProjection() {
        final class OrderStore: TokenSaverQueueCoalesceRuntime.DurabilityStore, @unchecked Sendable {
            private let lock = NSLock()
            var order: [String] = []
            var projections: [String: TokenSaverQueueCoalesceRuntime.Projection] = [:]
            var omissions: [String: Data] = [:]
            var failProjection = false
            func loadProjection(key: String) -> TokenSaverQueueCoalesceRuntime.Projection? {
                lock.lock(); defer { lock.unlock() }; return projections[key]
            }
            func saveProjection(key: String, projection: TokenSaverQueueCoalesceRuntime.Projection) -> Bool {
                lock.lock(); defer { lock.unlock() }
                order.append("proj")
                if failProjection { return false }
                if projections[key] != nil { return projections[key] == projection }
                projections[key] = projection
                return true
            }
            func deleteProjection(key: String) {
                lock.lock(); projections.removeValue(forKey: key); lock.unlock()
            }
            func loadOmission(handle: String) -> Data? {
                lock.lock(); defer { lock.unlock() }; return omissions[handle]
            }
            func saveOmission(handle: String, data: Data) -> TokenSaverQueueCoalesceRuntime.OmissionSaveResult {
                lock.lock(); defer { lock.unlock() }
                order.append("omit:\(handle)")
                if let existing = omissions[handle] {
                    return existing == data ? .alreadyIdentical : .conflict
                }
                omissions[handle] = data
                return .created
            }
            func deleteOmission(handle: String) {
                lock.lock(); omissions.removeValue(forKey: handle); lock.unlock()
            }
        }
        let store = OrderStore()
        let rt = TokenSaverQueueCoalesceRuntime(store: store)
        rt.live = true
        rt.setProviderAuthority(head: "h", generation: 1)
        let op = TokenSaverQueueCoalesceRuntime.CompactionOperationID(
            providerHead: "h", generation: 1, boundary: "b", rawHistoryDigest: "r"
        )
        XCTAssertTrue(rt.admitCompaction(pendingTool: false, pendingApproval: false, op: op))
        let om = TokenSaverQueueCoalesceRuntime.Omission(handle: "h1", original: Data("secret".utf8))
        XCTAssertTrue(rt.commit(op: op, projection: .compact, compactProjectionText: om.marker, omissions: [om]))
        XCTAssertEqual(store.order.first, "omit:h1")
        XCTAssertEqual(store.order.last, "proj")

        // Crash-before-projection: originals may exist; projection must not become compact without success.
        let store2 = OrderStore()
        store2.failProjection = true
        let rt2 = TokenSaverQueueCoalesceRuntime(store: store2)
        rt2.live = true
        rt2.setProviderAuthority(head: "h", generation: 1)
        let op2 = TokenSaverQueueCoalesceRuntime.CompactionOperationID(
            providerHead: "h", generation: 1, boundary: "b2", rawHistoryDigest: "r2"
        )
        XCTAssertTrue(rt2.admitCompaction(pendingTool: false, pendingApproval: false, op: op2))
        XCTAssertFalse(rt2.commit(op: op2, projection: .compact, compactProjectionText: om.marker, omissions: [om]))
        XCTAssertNil(store2.projections[op2.storageKey])
        // Rolled back omissions after failed projection publish
        XCTAssertNil(store2.omissions["h1"])
    }

    func test_concurrentRuntimes_exclusiveProjection() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ts-c18-cas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeA = try TokenSaverQueueCoalesceRuntime.FileDurabilityStore(directory: dir)
        let storeB = try TokenSaverQueueCoalesceRuntime.FileDurabilityStore(directory: dir)
        let a = TokenSaverQueueCoalesceRuntime(store: storeA)
        let b = TokenSaverQueueCoalesceRuntime(store: storeB)
        a.live = true; b.live = true
        a.setProviderAuthority(head: "h", generation: 1)
        b.setProviderAuthority(head: "h", generation: 1)
        let op = TokenSaverQueueCoalesceRuntime.CompactionOperationID(
            providerHead: "h", generation: 1, boundary: "shared", rawHistoryDigest: "raw"
        )
        XCTAssertTrue(a.admitCompaction(pendingTool: false, pendingApproval: false, op: op))
        XCTAssertTrue(b.admitCompaction(pendingTool: false, pendingApproval: false, op: op))
        XCTAssertTrue(a.commit(op: op, projection: .raw))
        // Second writer cannot overwrite with compact
        let om = TokenSaverQueueCoalesceRuntime.Omission(handle: "hx", original: Data("x".utf8))
        XCTAssertFalse(b.commit(op: op, projection: .compact, compactProjectionText: om.marker, omissions: [om]))
        XCTAssertEqual(a.projection(for: op), .raw)
        XCTAssertEqual(b.projection(for: op), .raw)
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
