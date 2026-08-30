import XCTest
@testable import AppShell
import SocketServer

final class MaterialWakeCoordinatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Shared singleton + park gate must not leak across tests (order independence).
        PendingWakeTestGate.shared.reset()
        MaterialWakeCoordinator.shared.stop()
    }

    override func tearDown() {
        PendingWakeTestGate.shared.reset()
        MaterialWakeCoordinator.shared.stop()
        super.tearDown()
    }

    func testStreamOnlyNeverAllowed() {
        let d = MaterialWakeCoordinator.shouldSilentWake(
            kind: "agent.item.delta",
            wakePhaseA: true,
            wakePhaseBGit: true
        )
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.reason, "stream_only")
    }

    func testPhaseAOffBlocksCriticalLifecycle() {
        let d = MaterialWakeCoordinator.shouldSilentWake(
            kind: "agent.run.completed",
            wakePhaseA: false,
            wakePhaseBGit: false
        )
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.reason, "phase_a_off")
    }

    func testPhaseAOnAllowsCompletedAndForceBootEpoch() {
        let completed = MaterialWakeCoordinator.shouldSilentWake(
            kind: "agent.run.completed",
            wakePhaseA: true,
            wakePhaseBGit: false
        )
        XCTAssertTrue(completed.allowed)
        XCTAssertFalse(completed.force)
        XCTAssertEqual(completed.reason, "agent.run.completed")

        let boot = MaterialWakeCoordinator.shouldSilentWake(
            kind: "host.boot_epoch",
            wakePhaseA: true,
            wakePhaseBGit: false
        )
        XCTAssertTrue(boot.allowed)
        XCTAssertTrue(boot.force)
        XCTAssertEqual(boot.reason, "host.boot_epoch")
    }

    func testPublishedAttentionKindsAllowedWhenFlagOn() {
        // WHY: suspended phones need a silent wake on approval / question /
        // error / notification.created — these are the real producer kinds.
        for kind in MaterialWakeTaxonomy.publishedAttentionKinds {
            let d = MaterialWakeCoordinator.shouldSilentWake(
                kind: kind,
                wakePhaseA: true,
                wakePhaseBGit: false,
                wakePublishedKinds: true
            )
            XCTAssertTrue(d.allowed, "\(kind) must wake when published-kinds flag is on")
            XCTAssertEqual(d.reason, kind)
            XCTAssertFalse(d.force, "\(kind) is not a force (boot) wake")
        }
    }

    func testPublishedKindsKillSwitchBlocksOnlyWidenedAllowlist() {
        // WHY: operators need a kill for attention flood without disabling
        // core run lifecycle wakes (started/completed/failed/boot).
        let request = MaterialWakeCoordinator.shouldSilentWake(
            kind: "agent.request.opened",
            wakePhaseA: true,
            wakePhaseBGit: false,
            wakePublishedKinds: false
        )
        XCTAssertFalse(request.allowed)
        XCTAssertEqual(request.reason, "published_kinds_off")

        let completed = MaterialWakeCoordinator.shouldSilentWake(
            kind: "agent.run.completed",
            wakePhaseA: true,
            wakePhaseBGit: false,
            wakePublishedKinds: false
        )
        XCTAssertTrue(completed.allowed, "core lifecycle must survive published-kinds kill")
    }

    func testPhaseBGitGated() {
        let off = MaterialWakeCoordinator.shouldSilentWake(
            kind: "git.push",
            wakePhaseA: true,
            wakePhaseBGit: false
        )
        XCTAssertFalse(off.allowed)
        let on = MaterialWakeCoordinator.shouldSilentWake(
            kind: "git.push",
            wakePhaseA: true,
            wakePhaseBGit: true
        )
        XCTAssertTrue(on.allowed)
    }

    func testFeatureFlagsDefaultsPhaseAAndKeepaliveOn() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePhaseAKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePublishedKindsKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePhaseBGitKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakeOutboxKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.selectiveCatchUpKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.transportKeepaliveExpKey)
        XCTAssertTrue(
            ConnectionFeatureFlags.wakePhaseAEnabled,
            "wake_phase_a defaults on so material silent wakes ship without a canary flip"
        )
        XCTAssertTrue(
            ConnectionFeatureFlags.wakePublishedKindsEnabled,
            "wake_published_kinds defaults on so real attention producers wake phones"
        )
        XCTAssertTrue(
            ConnectionFeatureFlags.transportKeepaliveExperimentEnabled,
            "transport keepalive defaults on (25s HTTP idle) for 3G RRC"
        )
        XCTAssertFalse(ConnectionFeatureFlags.wakePhaseBGitEnabled)
        XCTAssertFalse(ConnectionFeatureFlags.wakeOutboxEnabled)
        XCTAssertFalse(ConnectionFeatureFlags.selectiveCatchUpEnabled)
        XCTAssertEqual(ConnectionFeatureFlags.inventory().count, 6)

        // Kill switch: explicit false must win over default-on.
        defaults.set(false, forKey: ConnectionFeatureFlags.wakePhaseAKey)
        defaults.set(false, forKey: ConnectionFeatureFlags.wakePublishedKindsKey)
        defaults.set(false, forKey: ConnectionFeatureFlags.transportKeepaliveExpKey)
        XCTAssertFalse(ConnectionFeatureFlags.wakePhaseAEnabled)
        XCTAssertFalse(ConnectionFeatureFlags.wakePublishedKindsEnabled)
        XCTAssertFalse(ConnectionFeatureFlags.transportKeepaliveExperimentEnabled)
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePhaseAKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePublishedKindsKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.transportKeepaliveExpKey)
    }

    func testFlagValueUnsetUsesDefaultOn() {
        let defaults = UserDefaults.standard
        let key = "connection.flag.test_default_on_\(UUID().uuidString)"
        defaults.removeObject(forKey: key)
        XCTAssertTrue(ConnectionFeatureFlags.flagValue(key: key, defaultOn: true, defaults: defaults))
        XCTAssertFalse(ConnectionFeatureFlags.flagValue(key: key, defaultOn: false, defaults: defaults))
        defaults.set(false, forKey: key)
        XCTAssertFalse(ConnectionFeatureFlags.flagValue(key: key, defaultOn: true, defaults: defaults))
        defaults.set(true, forKey: key)
        XCTAssertTrue(ConnectionFeatureFlags.flagValue(key: key, defaultOn: false, defaults: defaults))
        defaults.removeObject(forKey: key)
    }

    func testSilentPayloadIncludesWatermarkSinceSeqAndBootEpoch() {
        let payload = MaterialWakeCoordinator.makeSilentPayload(
            eventSeq: 77,
            reason: "agent.run.completed",
            bootEpoch: "12",
            watermark: "80"
        )
        let data = payload.asPushData()
        XCTAssertEqual(data["rc2_catch_up"], "1")
        XCTAssertEqual(data["rc2_since_seq"], "77")
        XCTAssertEqual(data["rc2_boot_epoch"], "12")
        XCTAssertEqual(data["rc2_wm"], "80")
        XCTAssertEqual(data["rc2_schema"], SilentCatchUpV1.schemaVersion)
        // Privacy: free-form agent text cannot be smuggled via wm.
        let scrubbed = MaterialWakeCoordinator.makeSilentPayload(
            eventSeq: 1,
            reason: "x",
            bootEpoch: "not-a-number",
            watermark: "agent said hello"
        )
        XCTAssertNil(scrubbed.bootEpoch)
        XCTAssertNil(scrubbed.watermark)
    }

    func testSilentPayloadReasonForAttentionKinds() {
        // WHY: iOS / metrics attribute catch-up wakes via rc2_reason; each
        // real producer kind must survive makeSilentPayload sanitization.
        for kind in [
            "agent.request.opened",
            "agent.user_input.requested",
            "agent.run.error",
            "notification.created",
            "host.boot_epoch",
        ] {
            let payload = MaterialWakeCoordinator.makeSilentPayload(
                eventSeq: 9,
                reason: MaterialWakeTaxonomy.silentReason(forEventKind: kind),
                bootEpoch: "1",
                watermark: "9"
            )
            let data = payload.asPushData()
            XCTAssertNotNil(data["rc2_reason"], "reason for \(kind) must not be stripped")
            // Dots become underscores in the wire reason token.
            XCTAssertEqual(data["rc2_reason"], kind.replacingOccurrences(of: ".", with: "_"))
        }
    }

    func testPerClassCoalesceDoesNotLetRunProgressSwallowAttention() {
        // WHY: under the old global bucket, completed + request.opened in the
        // same 30s window produced one wake (the first). Attention must admit
        // even when run_progress already filled its own bucket.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var buckets: [String: Int] = [:]

        let run = PrivateNotificationBridge.shouldAdmitSilentCatchUp(
            force: false,
            coalesceClass: .runProgress,
            now: now,
            lastBuckets: buckets
        )
        XCTAssertTrue(run.shouldSend, "first run-progress wake in a bucket must send")
        buckets = run.updatedBuckets

        let runAgain = PrivateNotificationBridge.shouldAdmitSilentCatchUp(
            force: false,
            coalesceClass: .runProgress,
            now: now,
            lastBuckets: buckets
        )
        XCTAssertFalse(runAgain.shouldSend, "second run-progress in same 30s must coalesce")

        let attention = PrivateNotificationBridge.shouldAdmitSilentCatchUp(
            force: false,
            coalesceClass: .attention,
            now: now,
            lastBuckets: buckets
        )
        XCTAssertTrue(
            attention.shouldSend,
            "attention must not be swallowed by a prior run-progress wake in the same window"
        )

        let forced = PrivateNotificationBridge.shouldAdmitSilentCatchUp(
            force: true,
            coalesceClass: .boot,
            now: now,
            lastBuckets: attention.updatedBuckets
        )
        XCTAssertTrue(forced.shouldSend, "force (boot) always bypasses class buckets")
    }

    func testSameClassStillCoalescesWithinBucket() {
        // WHY: without same-class coalesce, N approvals in 30s would 429 the backend.
        let now = Date(timeIntervalSince1970: 1_700_000_030)
        let first = PrivateNotificationBridge.shouldAdmitSilentCatchUp(
            force: false,
            coalesceClass: .attention,
            now: now,
            lastBuckets: [:]
        )
        XCTAssertTrue(first.shouldSend)
        let second = PrivateNotificationBridge.shouldAdmitSilentCatchUp(
            force: false,
            coalesceClass: .attention,
            now: now,
            lastBuckets: first.updatedBuckets
        )
        XCTAssertFalse(second.shouldSend)

        // Next 30s window must re-admit.
        let later = Date(timeIntervalSince1970: 1_700_000_060)
        let third = PrivateNotificationBridge.shouldAdmitSilentCatchUp(
            force: false,
            coalesceClass: .attention,
            now: later,
            lastBuckets: first.updatedBuckets
        )
        XCTAssertTrue(third.shouldSend)
    }

    func testBucketMapRoundTripSurvivesUserDefaultsNSNumber() {
        // WHY: UserDefaults rehydrates ints as NSNumber; a naive [String: Int]
        // cast would empty the map and disable coalesce entirely (push flood).
        let suiteName = "test.silentCatchUp.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(["attention": 12, "run_progress": NSNumber(value: 12)], forKey: "private.silentCatchUp.lastBuckets")
        let loaded = PrivateNotificationBridge.loadBucketMap(from: suite)
        XCTAssertEqual(loaded["attention"], 12)
        XCTAssertEqual(loaded["run_progress"], 12)
    }

    // MARK: - Bounded pending queue (per coalesce class)

    func testInsertCoalescedBoundsDepthByClassAndKeepsNewest() {
        // WHY: a hung HTTPS POST must not let same-class material events grow
        // `pending` without limit; collapsing at enqueue to one slot per class
        // matches the downstream 30s per-class bucket (redundant items die anyway).
        var pending: [(coalesceClass: MaterialWakeCoalesceClass, hostHint: String, force: Bool, sinceSeq: String)] = []
        for i in 1...50 {
            MaterialWakeCoordinator.insertCoalesced(
                into: &pending,
                item: (.runProgress, "agent.run.completed", false, String(i))
            )
        }
        XCTAssertEqual(
            pending.count, 1,
            "same-class burst must collapse to one slot, not append unboundedly"
        )
        XCTAssertEqual(pending[0].sinceSeq, "50", "newest same-class payload must win")

        MaterialWakeCoordinator.insertCoalesced(
            into: &pending,
            item: (.attention, "agent.request.opened", false, "100")
        )
        MaterialWakeCoordinator.insertCoalesced(
            into: &pending,
            item: (.boot, "host.boot_epoch", true, "101")
        )
        for i in 51...80 {
            MaterialWakeCoordinator.insertCoalesced(
                into: &pending,
                item: (.runProgress, "agent.run.completed", false, String(i))
            )
        }
        XCTAssertLessThanOrEqual(
            pending.count,
            MaterialWakeCoordinator.maxPendingDepth,
            "depth must never exceed the number of coalesce classes"
        )
        XCTAssertEqual(pending.count, 3, "distinct classes each keep one slot")
        XCTAssertEqual(
            pending.first(where: { $0.coalesceClass == .runProgress })?.sinceSeq,
            "80",
            "run-progress slot must hold the newest seq after further replacements"
        )
        XCTAssertEqual(
            pending.first(where: { $0.coalesceClass == .boot })?.sinceSeq,
            "101",
            "force/boot must not be collapsed away by a run-progress storm"
        )
        XCTAssertTrue(
            pending.first(where: { $0.coalesceClass == .boot })?.force == true,
            "force flag on boot must survive non-force traffic"
        )
    }

    func testPendingQueueDepthStaysBoundedUnderSameClassBurst() async {
        // WHY: while delivery is blocked (slow HTTPS), a storm of identical
        // run-progress events must not grow the serial FIFO without limit.
        // Bound = one pending slot per class (here only run_progress).
        let coord = MaterialWakeCoordinator.shared
        coord.stop()
        PendingWakeTestGate.shared.reset()
        defer {
            PendingWakeTestGate.shared.release()
            coord.stop()
        }

        let firstParked = expectation(description: "first delivery parked")
        let lock = NSLock()
        var deliveredSeqs: [String] = []

        coord.setTestDelivererForTests { _, _, payload, _ in
            lock.lock()
            deliveredSeqs.append(payload.sinceSeq ?? "")
            let isFirst = deliveredSeqs.count == 1
            lock.unlock()
            if isFirst {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    // Park before signaling so release cannot race ahead of park.
                    PendingWakeTestGate.shared.park(cont)
                    firstParked.fulfill()
                }
            }
        }

        // Enqueue first item so drain starts and blocks inside deliverer.
        coord.enqueueForTests(
            hostHint: "agent.run.completed",
            force: false,
            payload: MaterialWakeCoordinator.makeSilentPayload(
                eventSeq: 1, reason: "agent.run.completed", bootEpoch: nil, watermark: "1"
            ),
            coalesceClass: .runProgress
        )
        await fulfillment(of: [firstParked], timeout: 2.0)

        // Burst while first delivery is hung — all same class.
        for seq in 2...40 {
            coord.enqueueForTests(
                hostHint: "agent.run.completed",
                force: false,
                payload: MaterialWakeCoordinator.makeSilentPayload(
                    eventSeq: Int64(seq), reason: "agent.run.completed", bootEpoch: nil, watermark: String(seq)
                ),
                coalesceClass: .runProgress
            )
        }
        let sawDepthWhileBlocked = coord.pendingWakeCountForTests()
        XCTAssertLessThanOrEqual(
            sawDepthWhileBlocked,
            1,
            "same-class burst while HTTPS is hung must leave at most one pending slot (got \(sawDepthWhileBlocked))"
        )
        XCTAssertLessThanOrEqual(
            sawDepthWhileBlocked,
            MaterialWakeCoordinator.maxPendingDepth,
            "pending must stay within the hard class-count bound"
        )

        // Unblock drain; remaining coalesced item should deliver newest seq.
        PendingWakeTestGate.shared.release()
        for _ in 0..<50 {
            lock.lock()
            let count = deliveredSeqs.count
            lock.unlock()
            if count >= 2 && coord.pendingWakeCountForTests() == 0 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        lock.lock()
        let seqs = deliveredSeqs
        lock.unlock()
        XCTAssertEqual(seqs.last, "40", "newest same-class payload must be the one delivered after coalesce")
        XCTAssertTrue(seqs.contains("1"), "in-flight first item must still complete (not dropped mid-delivery)")
        // At most first + one coalesced newest (not 40 deliveries).
        XCTAssertLessThanOrEqual(
            seqs.count, 2,
            "coalesce must collapse the storm; only in-flight + one newest pending should deliver"
        )
    }

    func testNewestSameClassPayloadIsDelivered() async {
        // WHY: phones need the freshest watermark/seq for catch-up, not a stale
        // earlier event that sat in an unbounded FIFO ahead of newer ones.
        let coord = MaterialWakeCoordinator.shared
        coord.stop()
        PendingWakeTestGate.shared.reset()
        defer {
            PendingWakeTestGate.shared.release()
            coord.stop()
        }

        let firstParked = expectation(description: "hold first")
        let lock = NSLock()
        var delivered: [(class: MaterialWakeCoalesceClass, seq: String)] = []

        coord.setTestDelivererForTests { _, _, payload, coalesceClass in
            lock.lock()
            let n = delivered.count
            delivered.append((coalesceClass, payload.sinceSeq ?? ""))
            lock.unlock()
            if n == 0 {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    PendingWakeTestGate.shared.park(cont)
                    firstParked.fulfill()
                }
            }
        }

        coord.enqueueForTests(
            hostHint: "agent.request.opened",
            force: false,
            payload: MaterialWakeCoordinator.makeSilentPayload(
                eventSeq: 10, reason: "agent.request.opened", bootEpoch: nil, watermark: "10"
            ),
            coalesceClass: .attention
        )
        await fulfillment(of: [firstParked], timeout: 2.0)

        for seq in [11, 12, 13, 99] {
            coord.enqueueForTests(
                hostHint: "agent.request.opened",
                force: false,
                payload: MaterialWakeCoordinator.makeSilentPayload(
                    eventSeq: Int64(seq), reason: "agent.request.opened", bootEpoch: nil, watermark: String(seq)
                ),
                coalesceClass: .attention
            )
        }
        XCTAssertEqual(
            coord.pendingWakeCountForTests(), 1,
            "attention class must keep a single pending slot for the burst"
        )
        PendingWakeTestGate.shared.release()

        for _ in 0..<50 {
            lock.lock()
            let count = delivered.count
            lock.unlock()
            if count >= 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        lock.lock()
        let attentionSeqs = delivered.filter { $0.class == .attention }.map(\.seq)
        lock.unlock()
        XCTAssertEqual(
            attentionSeqs.last, "99",
            "after same-class coalesce the delivered pending item must be the newest seq"
        )
    }

    func testForceItemSurvivesBurstOfNonForceItems() async {
        // WHY: Mac relaunch (host.boot_epoch / force) must never be dropped or
        // collapsed by a storm of run-progress wakes; force is its own class.
        let coord = MaterialWakeCoordinator.shared
        coord.stop()
        PendingWakeTestGate.shared.reset()
        defer {
            PendingWakeTestGate.shared.release()
            coord.stop()
        }

        let firstParked = expectation(description: "first delivery parked")
        let lock = NSLock()
        var deliveredForceFlags: [Bool] = []
        var deliveredClasses: [MaterialWakeCoalesceClass] = []

        coord.setTestDelivererForTests { _, force, _, coalesceClass in
            lock.lock()
            let isFirst = deliveredForceFlags.isEmpty
            deliveredForceFlags.append(force)
            deliveredClasses.append(coalesceClass)
            lock.unlock()
            if isFirst {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    PendingWakeTestGate.shared.park(cont)
                    firstParked.fulfill()
                }
            }
        }

        // Start drain with a non-force progress item so force is not yet in-flight.
        coord.enqueueForTests(
            hostHint: "agent.run.started",
            force: false,
            payload: MaterialWakeCoordinator.makeSilentPayload(
                eventSeq: 1, reason: "agent.run.started", bootEpoch: nil, watermark: "1"
            ),
            coalesceClass: .runProgress
        )
        await fulfillment(of: [firstParked], timeout: 2.0)

        for seq in 2...30 {
            coord.enqueueForTests(
                hostHint: "agent.run.completed",
                force: false,
                payload: MaterialWakeCoordinator.makeSilentPayload(
                    eventSeq: Int64(seq), reason: "agent.run.completed", bootEpoch: nil, watermark: String(seq)
                ),
                coalesceClass: .runProgress
            )
        }
        // Force boot arrives amid the storm.
        coord.enqueueForTests(
            hostHint: "host.boot_epoch",
            force: true,
            payload: MaterialWakeCoordinator.makeSilentPayload(
                eventSeq: 999, reason: "host.boot_epoch", bootEpoch: "42", watermark: "999"
            ),
            coalesceClass: .boot
        )
        // More non-force noise after force.
        for seq in 31...45 {
            coord.enqueueForTests(
                hostHint: "agent.run.completed",
                force: false,
                payload: MaterialWakeCoordinator.makeSilentPayload(
                    eventSeq: Int64(seq), reason: "agent.run.completed", bootEpoch: nil, watermark: String(seq)
                ),
                coalesceClass: .runProgress
            )
        }

        let depth = coord.pendingWakeCountForTests()
        XCTAssertLessThanOrEqual(
            depth,
            MaterialWakeCoordinator.maxPendingDepth,
            "mixed-class storm must still be class-bounded"
        )
        // Expect run_progress + boot still pending (first progress is in-flight).
        XCTAssertGreaterThanOrEqual(depth, 1, "force/boot must remain queued, not dropped")
        XCTAssertLessThanOrEqual(depth, 2, "only distinct classes (progress + boot) should remain pending")

        PendingWakeTestGate.shared.release()

        for _ in 0..<80 {
            lock.lock()
            let flags = deliveredForceFlags
            lock.unlock()
            if flags.contains(true) && coord.pendingWakeCountForTests() == 0 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        lock.lock()
        let flags = deliveredForceFlags
        let classes = deliveredClasses
        lock.unlock()
        XCTAssertTrue(
            flags.contains(true),
            "force/boot wake must be delivered after a non-force storm — relaunch catch-up must not be lost"
        )
        XCTAssertTrue(
            classes.contains(.boot),
            "boot coalesce class must appear in deliveries, not only progress"
        )
    }

    // MARK: - Runtime path (EventBus → start() subscription → handle → enqueue/deliver)

    func testEventBusPublishDeliversMaterialWakeThroughStartedCoordinator() async {
        // WHY: pure shouldSilentWake / enqueueForTests seams can pass while the
        // real start() EventBus subscription and handle(event:) classify-and-
        // enqueue body never run. This covers the host boot-epoch path that
        // AppContext publishes after start.
        //
        // No app Bootstrap: DEBUG test deliverer admits wakes with bridge == nil
        // (handle + drain). startForTests also subscribes from currentSeq so a
        // prior test's EventBus ring cannot flood this expectation.
        let coord = MaterialWakeCoordinator.shared
        defer { coord.stop() }

        // Ensure Phase A flags match production defaults (on).
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePhaseAKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePublishedKindsKey)
        XCTAssertTrue(ConnectionFeatureFlags.wakePhaseAEnabled)

        let lock = NSLock()
        var delivered: [(hint: String, force: Bool, reason: String?, coalesce: MaterialWakeCoalesceClass)] = []
        let got = expectation(description: "host.boot_epoch delivered via EventBus")

        #if DEBUG
        coord.setTestDelivererForTests { hint, force, payload, coalesceClass in
            guard hint == "host.boot_epoch" else { return }
            lock.lock()
            delivered.append((hint, force, payload.reason, coalesceClass))
            lock.unlock()
            got.fulfill()
        }
        coord.startForTests(
            bootEpochProvider: { "42" },
            watermarkProvider: { "7" }
        )
        #else
        XCTFail("runtime observation requires DEBUG test deliverer (tests always build DEBUG)")
        return
        #endif

        // Publish from the test thread (not from a subscriber) — EventBus
        // reentrancy precondition forbids publish-from-handler.
        EventBus.shared.publish(
            kind: .hostBootEpoch,
            payload: .object([
                "boot_epoch": .number(42),
                "server_id": .string("test-server"),
            ])
        )

        await fulfillment(of: [got], timeout: 2.0)
        lock.lock()
        let snaps = delivered
        lock.unlock()
        XCTAssertEqual(snaps.count, 1, "exactly one silent wake for host.boot_epoch")
        XCTAssertEqual(snaps[0].hint, "host.boot_epoch")
        XCTAssertTrue(snaps[0].force, "boot epoch is force/silentForce")
        XCTAssertEqual(snaps[0].coalesce, .boot)
        // Wire reason sanitizer maps dots → underscores (see SilentCatchUpV1).
        XCTAssertEqual(snaps[0].reason, "host_boot_epoch")
        #if DEBUG
        XCTAssertEqual(
            coord.testDelivererDivertCountForTests(), 1,
            "DEBUG diversion must be counted when test deliverer replaces bridge"
        )
        #endif
    }

    func testEventBusStreamOnlyKindProducesNoWake() async {
        // WHY: surface.output / agent.item.delta must never reach the drain queue
        // even when the coordinator is fully started and subscribed.
        let coord = MaterialWakeCoordinator.shared
        defer { coord.stop() }

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePhaseAKey)

        let lock = NSLock()
        var deliveredHints: [String] = []

        #if DEBUG
        coord.setTestDelivererForTests { hint, _, _, _ in
            lock.lock()
            deliveredHints.append(hint)
            lock.unlock()
        }
        coord.startForTests(bootEpochProvider: { "1" }, watermarkProvider: { "1" })
        #else
        XCTFail("runtime observation requires DEBUG test deliverer")
        return
        #endif

        EventBus.shared.publish(
            kind: .agentItemDelta,
            payload: .object(["text": .string("chunk")])
        )
        EventBus.shared.publish(
            kind: .surfaceOutput,
            payload: .object(["chunk": .string("x")])
        )

        // Bounded poll: drain Task would have enqueued if classify failed open.
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if coord.pendingWakeCountForTests() > 0 { break }
        }
        lock.lock()
        let hints = deliveredHints
        lock.unlock()
        XCTAssertTrue(hints.isEmpty, "stream-only kinds must not deliver (got \(hints))")
        XCTAssertEqual(coord.pendingWakeCountForTests(), 0, "stream-only must not leave pending wakes")
        #if DEBUG
        XCTAssertEqual(coord.testDelivererDivertCountForTests(), 0)
        #endif
    }

    func testEventBusAttentionKindClassifiesAndDelivers() async {
        // WHY: agent.request.opened is a real AppContext producer; start()+publish
        // must classify it as attention (non-force) and deliver.
        let coord = MaterialWakeCoordinator.shared
        defer { coord.stop() }

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePhaseAKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePublishedKindsKey)

        let lock = NSLock()
        var delivered: [(hint: String, force: Bool, coalesce: MaterialWakeCoalesceClass)] = []
        let got = expectation(description: "request.opened delivered")

        #if DEBUG
        coord.setTestDelivererForTests { hint, force, _, coalesceClass in
            guard hint == "agent.request.opened" else { return }
            lock.lock()
            delivered.append((hint, force, coalesceClass))
            lock.unlock()
            got.fulfill()
        }
        coord.startForTests(bootEpochProvider: { "3" }, watermarkProvider: { "9" })
        #else
        XCTFail("runtime observation requires DEBUG test deliverer")
        return
        #endif

        EventBus.shared.publish(
            kind: .agentRequestOpened,
            payload: .object(["requestId": .string("r1")])
        )

        await fulfillment(of: [got], timeout: 2.0)
        lock.lock()
        let snaps = delivered
        lock.unlock()
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps[0].hint, "agent.request.opened")
        XCTAssertFalse(snaps[0].force)
        XCTAssertEqual(snaps[0].coalesce, .attention)
    }
}

/// Parks the first test deliverer until `release()` so pending depth can be sampled mid-storm.
private final class PendingWakeTestGate: @unchecked Sendable {
    static let shared = PendingWakeTestGate()
    private let lock = NSLock()
    private var parked: CheckedContinuation<Void, Never>?
    private var pendingRelease = false

    func reset() {
        lock.lock()
        let cont = parked
        parked = nil
        pendingRelease = false
        lock.unlock()
        cont?.resume()
    }

    func park(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        if pendingRelease {
            pendingRelease = false
            lock.unlock()
            cont.resume()
            return
        }
        if let old = parked {
            parked = cont
            lock.unlock()
            old.resume()
            return
        }
        parked = cont
        lock.unlock()
    }

    func release() {
        lock.lock()
        if let cont = parked {
            parked = nil
            pendingRelease = false
            lock.unlock()
            cont.resume()
            return
        }
        pendingRelease = true
        lock.unlock()
    }
}
