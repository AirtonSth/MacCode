import Foundation
import SocketServer
import XCTest
@testable import AppShell

/// F5: what the supervisor tells the listener and the push bridge about the
/// published Tailcat endpoints, and what a network path change may start.
final class TailcatRotationSupervisorTests: XCTestCase {
    // Digests computed outside Swift (Python hashlib) for the build id of
    // `TailcatTransportContract.buildID` and the blobs the fake bridge returns.
    /// `primary-blob`, `fallback-blob`: the default fake.
    private static let constantBlobsDigest = "15b48f53ead19fe5862e0892d09e068ca614eec2df67e6aa7c82eeca72e6f7c4"
    /// `blobsFollowKeys`, first key pair (`public-1`, `public-2`).
    private static let firstKeysDigest = "e455e10a45f82ef02d4065571548ec8ad5034d3d246a4f9ab5d44c5413c9d73a"
    /// `blobsFollowKeys`, after one rotation (`public-3`, `public-4`).
    private static let secondKeysDigest = "fc22b2f2607f83cfb36710452da98c2769325610c92f98f9a4d49f37355f4455"

    /// WHY: the notice tells a phone on the LAN that its saved address is
    /// about to die. Sent after the stop it describes nothing the phone can
    /// still act on; sent twice it distrusts a good address.
    func testRotationWithALiveRuntimeAnnouncesTheRetiringDigestOnceBeforeStop() async throws {
        let catalog = FakeTailcatCatalog(snapshot: makeSnapshot(revision: 1, peers: [peer(0xa1)]))
        let listener = RecordingTailcatListener()
        let supervisor = makeSupervisor(
            bridge: FakeTailcatBridge(blobsFollowKeys: true),
            catalog: catalog,
            store: FakeTailcatStore(),
            listener: listener
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        XCTAssertEqual(listener.lastDigestEntry, "digest:\(Self.firstKeysDigest)")
        let entriesBeforeRotation = listener.entries.count

        // A device registered: admission changed while the runtime is live.
        await catalog.setSnapshot(makeSnapshot(revision: 2, peers: [peer(0xa1), peer(0xa2)]))
        await supervisor.reconcileNowForTesting()

        let rotation = Array(listener.entries.dropFirst(entriesBeforeRotation))
        let announced = try XCTUnwrap(
            rotation.firstIndex(of: "announce:\(Self.firstKeysDigest)"),
            "the retiring digest is the one the phones saved"
        )
        let stopped = try XCTUnwrap(rotation.firstIndex(of: "stop"))
        XCTAssertLessThan(announced, stopped, "the notice must be queued before the runtime stops")
        XCTAssertEqual(listener.lastDigestEntry, "digest:\(Self.secondKeysDigest)")

        await supervisor.reconcileNowForTesting()
        XCTAssertEqual(
            listener.announces,
            ["announce:\(Self.firstKeysDigest)"],
            "one notice per rotation, none for the reconciles around it"
        )
        await supervisor.setEnabled(false)
    }

    /// WHY: a phone told "rotating" when nothing rotates distrusts a good
    /// address and asks the catalog for nothing. Only new keys over a live
    /// runtime are a rotation; every other stop keeps or drops the address
    /// without a notice.
    func testFirstStartRenewalWakeRevokeAndDisableAnnounceNoRotation() async {
        let clock = RotationTestClock()
        let catalog = FakeTailcatCatalog(snapshot: makeSnapshot(revision: 1, peers: [peer(0xb1)]))
        let bridge = FakeTailcatBridge(blobsFollowKeys: true)
        let listener = RecordingTailcatListener()
        let supervisor = makeSupervisor(
            bridge: bridge,
            catalog: catalog,
            store: FakeTailcatStore(),
            listener: listener,
            clock: clock
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        // There is a digest to announce from here on, so a silent path below
        // is silent by rule, not for lack of a value.
        XCTAssertEqual(listener.lastDigestEntry, "digest:\(Self.firstKeysDigest)")
        XCTAssertEqual(listener.announces, [], "first start")

        clock.advance(TailcatTransportContract.renewalInterval)
        await supervisor.reconcileNowForTesting()
        let publishesAfterRenewal = await catalog.publishAccessTokens.count
        XCTAssertEqual(publishesAfterRenewal, 2, "the renewal must have run")
        XCTAssertEqual(listener.announces, [], "5-minute renewal")

        await supervisor.suspend()
        await supervisor.resume()
        XCTAssertEqual(bridge.startCalls.count, 4, "the wake must have restarted the runtime")
        XCTAssertEqual(listener.announces, [], "sleep then wake with the same keys")

        // Every device was removed: the runtime is revoked, not rotated.
        await catalog.setSnapshot(makeSnapshot(revision: 2, peers: []))
        await supervisor.reconcileNowForTesting()
        let activeAfterRevoke = await supervisor.hasActiveRuntimeForTesting
        XCTAssertFalse(activeAfterRevoke)
        XCTAssertEqual(listener.announces, [], "revoke")

        // New keys, but no runtime was serving the old ones any more.
        await catalog.setSnapshot(makeSnapshot(revision: 3, peers: [peer(0xb1)]))
        await supervisor.reconcileNowForTesting()
        XCTAssertEqual(listener.lastDigestEntry, "digest:\(Self.secondKeysDigest)")
        XCTAssertEqual(listener.announces, [], "start after a revoke")

        await supervisor.setEnabled(false)
        XCTAssertEqual(listener.announces, [], "disable")
    }

    /// WHY: the listener's digest goes into the welcome of a phone that asked.
    /// A digest offered while nothing is published is cached data shown as
    /// fresh: it names an address nobody serves.
    func testListenerDigestFollowsThePublishedHost() async {
        let clock = RotationTestClock()
        let catalog = FakeTailcatCatalog(snapshot: makeSnapshot(revision: 1, peers: [peer(0xc1)]))
        let listener = RecordingTailcatListener()
        let supervisor = makeSupervisor(
            bridge: FakeTailcatBridge(),
            catalog: catalog,
            store: FakeTailcatStore(),
            listener: listener,
            clock: clock
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        XCTAssertEqual(listener.lastDigestEntry, "digest:\(Self.constantBlobsDigest)", "after the publish")

        clock.advance(TailcatTransportContract.renewalInterval)
        await supervisor.reconcileNowForTesting()
        let publishes = await catalog.publishAccessTokens.count
        XCTAssertEqual(publishes, 2, "the renewal must have run")
        XCTAssertEqual(listener.lastDigestEntry, "digest:\(Self.constantBlobsDigest)", "after a renewal")

        await supervisor.suspend()
        XCTAssertEqual(listener.lastDigestEntry, "digest:nil", "asleep: nothing is served")

        await supervisor.resume()
        XCTAssertEqual(listener.lastDigestEntry, "digest:\(Self.constantBlobsDigest)", "after the wake republished")

        await supervisor.setEnabled(false)
        XCTAssertEqual(listener.lastDigestEntry, "digest:nil", "disabled: the host was deleted")
    }

    /// WHY: `rc2_tc_dig` must describe the publication the phone will read
    /// from the catalog, and `pushHint()` keeps its four facts for the
    /// callers that compare the whole value.
    func testPushHintWithEndpointDigestCarriesTheDigestOfThePublishedHost() async {
        let catalog = FakeTailcatCatalog(
            snapshot: makeSnapshot(revision: 1, peers: [peer(0xd1)]),
            leaseExpiresAt: "2099-01-01T00:00:00Z"
        )
        let supervisor = makeSupervisor(bridge: FakeTailcatBridge(), catalog: catalog, store: FakeTailcatStore())

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        let plain = await supervisor.pushHint()
        let withDigest = await supervisor.pushHintWithEndpointDigest()
        XCTAssertNotNil(plain)
        XCTAssertNil(plain?.endpointDigest, "pushHint() stays the four facts")
        XCTAssertEqual(withDigest?.endpointDigest, Self.constantBlobsDigest)
        XCTAssertEqual(withDigest?.serverId, plain?.serverId)
        XCTAssertEqual(withDigest?.version, plain?.version)
        XCTAssertEqual(withDigest?.leaseExpiresAt, plain?.leaseExpiresAt)
        XCTAssertEqual(withDigest?.transportBuildId, plain?.transportBuildId)

        await supervisor.setEnabled(false)
        let plainAfterDisable = await supervisor.pushHint()
        let withDigestAfterDisable = await supervisor.pushHintWithEndpointDigest()
        XCTAssertNil(plainAfterDisable)
        XCTAssertNil(withDigestAfterDisable, "a deleted host has no digest to push")
    }

    /// WHY: `renew` checks nothing after its awaited `PUT`, so its answer can
    /// arrive after the runtime was stopped. A welcome digest or a rotation
    /// push for an address nobody serves is cached data shown as fresh.
    func testRenewalAnsweredAfterStopOffersNoDigest() async {
        await assertRenewalAnsweredAfterStopOffersNoDigest("suspend") { await $0.suspend() }
        await assertRenewalAnsweredAfterStopOffersNoDigest("disable") { await $0.setEnabled(false) }
        // Disable deletes the host before it stops the runtime, so the answer
        // can also arrive while a runtime is still set.
        await assertRenewalAnsweredAfterStopOffersNoDigest("disable waiting for its DELETE", stop: nil)
    }

    /// WHY: the handler asks for the rotation push. It must follow every
    /// successful publish (the renewal is the retry of a lost push) and never
    /// a failed one: that would announce an address nobody answers on.
    func testPublishHandlerFiresAfterRotateAndRenewButNotAfterAFailedPublish() async {
        let clock = RotationTestClock()
        let catalog = FakeTailcatCatalog(snapshot: makeSnapshot(revision: 1, peers: [peer(0xe1)]))
        let published = RotationTestCounter()
        let supervisor = makeSupervisor(
            bridge: FakeTailcatBridge(),
            catalog: catalog,
            store: FakeTailcatStore(),
            clock: clock,
            publishHandler: { published.increment() }
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        XCTAssertEqual(published.value, 1, "after the first publish")

        clock.advance(TailcatTransportContract.renewalInterval)
        await supervisor.reconcileNowForTesting()
        XCTAssertEqual(published.value, 2, "after the renewal")

        await catalog.setPublishError(URLError(.timedOut))
        await catalog.setSnapshot(makeSnapshot(revision: 2, peers: [peer(0xe1), peer(0xe2)]))
        await supervisor.reconcileNowForTesting()
        let publishAttempts = await catalog.publishAccessTokens.count
        let activeAfterFailedPublish = await supervisor.hasActiveRuntimeForTesting
        XCTAssertEqual(publishAttempts, 3, "the rotation must have reached the PUT")
        XCTAssertFalse(activeAfterFailedPublish)
        XCTAssertEqual(published.value, 2, "a failed publish is not announced")
        await supervisor.setEnabled(false)
    }

    /// WHY: a path change on a healthy Mac must cost one catalog `GET` and
    /// nothing else. A restart drops live tunnels, a `PUT` raises `version`,
    /// and Settings must not show "Checking" when nothing is being checked.
    func testPathChangeOnHealthyRuntimeOnlyReadsTheCatalog() async {
        let catalog = FakeTailcatCatalog(snapshot: makeSnapshot(revision: 1, peers: [peer(0xf1)]))
        let bridge = FakeTailcatBridge()
        let statuses = FakeTailcatStatuses()
        let supervisor = makeSupervisor(
            bridge: bridge,
            catalog: catalog,
            store: FakeTailcatStore(),
            statusHandler: { statuses.append($0) }
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        let readsBefore = await catalog.hostAccessTokens.count
        let statusesBefore = statuses.values.count

        for _ in 0..<5 {
            await supervisor.networkPathChanged()
        }

        let readsAfter = await catalog.hostAccessTokens.count
        let publishes = await catalog.publishAccessTokens.count
        XCTAssertEqual(readsAfter, readsBefore + 5, "each settled change is one reconcile")
        XCTAssertEqual(bridge.startCalls.count, 2, "no restart")
        XCTAssertTrue(bridge.closedHandles.isEmpty, "no live tunnel dropped")
        XCTAssertEqual(publishes, 1, "no PUT outside the renewal interval")
        XCTAssertFalse(
            statuses.values.dropFirst(statusesBefore).contains(.checking),
            "no progress shown when nothing is being checked"
        )
        await supervisor.setEnabled(false)
    }

    /// WHY: path updates come in bursts. They must share the single flight:
    /// no parallel ticks and no catalog `GET` per event.
    func testPathChangesDuringAReconcileCoalesceIntoOneFollowUp() async {
        let catalog = FakeTailcatCatalog(snapshot: makeSnapshot(revision: 1, peers: [peer(0x11)]))
        let bridge = FakeTailcatBridge()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: FakeTailcatStore())

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        let readsBefore = await catalog.hostAccessTokens.count

        await catalog.holdNextHostCall()
        let reconcile = Task { await supervisor.reconcileNowForTesting() }
        let holding = await waitUntil { await catalog.isHoldingHost }
        XCTAssertTrue(holding, "a reconcile must be in flight")
        for _ in 0..<5 {
            await supervisor.networkPathChanged()
        }
        await catalog.releaseHostCall()
        await reconcile.value

        let readsAfter = await catalog.hostAccessTokens.count
        XCTAssertEqual(readsAfter, readsBefore + 2, "the held tick plus exactly one follow-up")
        XCTAssertEqual(bridge.startCalls.count, 2)
        await supervisor.setEnabled(false)
    }

    /// WHY: a path change must not bump the generation. That would discard a
    /// rotation waiting for its `PUT` and mint keys a second time, which is
    /// one more address change for every phone.
    func testPathChangeDoesNotDiscardARotationInFlight() async {
        let catalog = FakeTailcatCatalog(snapshot: makeSnapshot(revision: 1, peers: [peer(0x21)]))
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: store)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        XCTAssertEqual(bridge.startCalls.count, 2)

        await catalog.setSnapshot(makeSnapshot(revision: 2, peers: [peer(0x21), peer(0x22)]))
        await catalog.holdNextPublishCall()
        let rotation = Task { await supervisor.reconcileNowForTesting() }
        let holding = await waitUntil { await catalog.isHoldingPublish }
        XCTAssertTrue(holding, "the rotation must be waiting for its PUT")

        await supervisor.networkPathChanged()
        await catalog.releasePublishCall()
        await rotation.value

        let publishes = await catalog.publishAccessTokens.count
        let active = await supervisor.hasActiveRuntimeForTesting
        XCTAssertEqual(bridge.startCalls.count, 4, "one rotation: two more starts, not four")
        XCTAssertEqual(publishes, 2, "one more publish")
        XCTAssertTrue(active)
        XCTAssertEqual(store.state?.phase, .active)
        XCTAssertEqual(
            Set([store.state?.active?.primary.privateKey, store.state?.active?.fallback.privateKey].compactMap { $0 }),
            Set(bridge.startCalls.suffix(2).map(\.key.privateKey)),
            "the keys that were started are the keys that were published"
        )
        await supervisor.setEnabled(false)
    }

    /// WHY: the wake-before-network case. The catalog read of the wake fails,
    /// and the path change that follows must start the runtime without
    /// waiting for the 15 s poll (which is off here).
    func testPathChangeAfterAFailedReconcileStartsTheRuntimeWithoutThePoll() async {
        let catalog = FakeTailcatCatalog(snapshot: makeSnapshot(revision: 1, peers: [peer(0x31)]))
        let bridge = FakeTailcatBridge()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: FakeTailcatStore())

        await catalog.setUnavailable(true)
        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        let activeWhileDown = await supervisor.hasActiveRuntimeForTesting
        XCTAssertFalse(activeWhileDown)
        XCTAssertTrue(bridge.startCalls.isEmpty)

        await catalog.setUnavailable(false)
        await supervisor.networkPathChanged()

        let active = await supervisor.hasActiveRuntimeForTesting
        let publishes = await catalog.publishAccessTokens.count
        XCTAssertTrue(active, "the path change is the reconcile; nothing else runs in this test")
        XCTAssertEqual(bridge.startCalls.count, 2)
        XCTAssertEqual(publishes, 1)
        await supervisor.setEnabled(false)
    }

    /// WHY: a reconcile left pending when the Mac is told to sleep used to
    /// start a new tick after the stop, which restarted the runtime and
    /// published the Mac as reachable while it was going to sleep. A network
    /// trigger around sleep makes that pending reconcile likelier.
    func testReconcilePendingAtSuspendDoesNotRestartTheRuntime() async {
        let catalog = FakeTailcatCatalog(snapshot: makeSnapshot(revision: 1, peers: [peer(0x41)]))
        let bridge = FakeTailcatBridge()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: FakeTailcatStore())

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        let publishesBefore = await catalog.publishAccessTokens.count

        await catalog.holdNextHostCall()
        let reconcile = Task { await supervisor.reconcileNowForTesting() }
        let holding = await waitUntil { await catalog.isHoldingHost }
        XCTAssertTrue(holding, "a reconcile must be in flight")
        // Returns at once: it only marks one follow-up tick as pending.
        await supervisor.reconcileNowForTesting()

        await supervisor.suspend()
        await catalog.releaseHostCall()
        await reconcile.value

        let active = await supervisor.hasActiveRuntimeForTesting
        let publishesAfter = await catalog.publishAccessTokens.count
        XCTAssertFalse(active, "asleep means no runtime")
        XCTAssertEqual(bridge.startCalls.count, 2, "the pending tick must not start servers")
        XCTAssertEqual(publishesAfter, publishesBefore, "and must not publish the Mac as reachable")
        await supervisor.setEnabled(false)
    }

    /// WHY: macOS can report a path change during a dark wake. It must not
    /// start the runtime while the Mac is asleep, and the event is not lost:
    /// the wake's own reconcile covers it, with the same keys.
    func testPathChangeWhileSuspendedIsDroppedAndWakeStillReconciles() async {
        let catalog = FakeTailcatCatalog(snapshot: makeSnapshot(revision: 1, peers: [peer(0x51)]))
        let bridge = FakeTailcatBridge()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: FakeTailcatStore())

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        let keysBefore = Set(bridge.startCalls.map(\.key.privateKey))

        await supervisor.suspend()
        let readsBefore = await catalog.hostAccessTokens.count
        await supervisor.networkPathChanged()
        let readsAfter = await catalog.hostAccessTokens.count
        let activeWhileAsleep = await supervisor.hasActiveRuntimeForTesting
        XCTAssertEqual(readsAfter, readsBefore, "dropped: not even a catalog read")
        XCTAssertEqual(bridge.startCalls.count, 2)
        XCTAssertFalse(activeWhileAsleep)

        await supervisor.resume()
        let activeAfterWake = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeAfterWake)
        XCTAssertEqual(bridge.startCalls.count, 4)
        XCTAssertEqual(Set(bridge.startCalls.suffix(2).map(\.key.privateKey)), keysBefore)
        await supervisor.setEnabled(false)
    }

    /// WHY: when the first HTTP restart of a wake throws, `AppDelegate` skips
    /// `resume()` and the retry re-enables Tailcat through `setEnabled(true)`.
    /// That call must lift the sleep guard, or every reconcile is dropped and
    /// Tailcat stays down until the next sleep and wake.
    func testEnableAfterSuspendWithoutResumeReconcilesAgain() async {
        let catalog = FakeTailcatCatalog(snapshot: makeSnapshot(revision: 1, peers: [peer(0x71)]))
        let bridge = FakeTailcatBridge()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: FakeTailcatStore())

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        XCTAssertEqual(bridge.startCalls.count, 2)

        await supervisor.suspend()
        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        let active = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(active, "the reconcile after the re-enable must not be dropped as asleep")
        XCTAssertEqual(bridge.startCalls.count, 4)
        XCTAssertEqual(
            Set(bridge.startCalls.suffix(2).map(\.key.privateKey)),
            Set(bridge.startCalls.prefix(2).map(\.key.privateKey)),
            "with the same keys, as after a wake"
        )
        await supervisor.setEnabled(false)
    }

    /// The renewal `PUT` is held, `stop` runs, then the `PUT` is answered.
    /// A nil `stop` is a disable that is still waiting for its `DELETE` when
    /// the `PUT` is answered.
    private func assertRenewalAnsweredAfterStopOffersNoDigest(
        _ label: String,
        stop: ((TailcatRuntimeSupervisor) async -> Void)?
    ) async {
        let clock = RotationTestClock()
        let catalog = FakeTailcatCatalog(
            snapshot: makeSnapshot(revision: 1, peers: [peer(0x61)]),
            leaseExpiresAt: "2099-01-01T00:00:00Z"
        )
        let listener = RecordingTailcatListener()
        let published = RotationTestCounter()
        let supervisor = makeSupervisor(
            bridge: FakeTailcatBridge(),
            catalog: catalog,
            store: FakeTailcatStore(),
            listener: listener,
            clock: clock,
            publishHandler: { published.increment() }
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        XCTAssertEqual(listener.lastDigestEntry, "digest:\(Self.constantBlobsDigest)", label)
        XCTAssertEqual(published.value, 1, label)

        clock.advance(TailcatTransportContract.renewalInterval)
        await catalog.holdNextPublishCall()
        let renewal = Task { await supervisor.reconcileNowForTesting() }
        let holding = await waitUntil { await catalog.isHoldingPublish }
        XCTAssertTrue(holding, "\(label): the renewal must be waiting for its PUT")

        var pendingDisable: Task<Void, Never>?
        if let stop {
            await stop(supervisor)
        } else {
            await catalog.holdNextDeleteCall()
            pendingDisable = Task { await supervisor.setEnabled(false) }
            let deleting = await waitUntil { await catalog.isHoldingDelete }
            XCTAssertTrue(deleting, "\(label): the disable must be waiting for its DELETE")
        }
        await catalog.releasePublishCall()
        await renewal.value

        let publishes = await catalog.publishAccessTokens.count
        let hint = await supervisor.pushHintWithEndpointDigest()
        XCTAssertEqual(publishes, 2, "\(label): the renewal PUT was answered")
        XCTAssertEqual(listener.entries.last, "digest:nil", "\(label): no digest for a stopped runtime")
        XCTAssertNil(hint?.endpointDigest, label)
        XCTAssertEqual(published.value, 1, "\(label): nothing is published to announce")
        if let pendingDisable {
            await catalog.releaseDeleteCall()
            await pendingDisable.value
        }
        let hintAfterStop = await supervisor.pushHintWithEndpointDigest()
        XCTAssertNil(hintAfterStop, label)
        await supervisor.setEnabled(false)
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    private func makeSupervisor(
        bridge: FakeTailcatBridge,
        catalog: FakeTailcatCatalog,
        store: FakeTailcatStore,
        listener: any TailcatLoopbackListening = FakeTailcatListener(),
        clock: RotationTestClock = RotationTestClock(),
        publishHandler: @escaping TailcatRuntimeSupervisor.PublishHandler = {},
        statusHandler: @escaping TailcatRuntimeSupervisor.StatusHandler = { _ in }
    ) -> TailcatRuntimeSupervisor {
        TailcatRuntimeSupervisor(
            serverID: "server-1",
            displayName: "Test Mac",
            bridge: bridge,
            catalog: catalog,
            secureStore: store,
            sessionProvider: { Self.session },
            authenticator: TailcatRemoteConnectionAuthenticator(),
            listener: listener,
            now: { clock.now },
            automaticPolling: false,
            publishHandler: publishHandler,
            statusHandler: statusHandler
        )
    }

    private static let session = PrivateAccountSession(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        user: PrivateAccountUser(
            daysRemaing: nil,
            daysRemaining: 30,
            email: "subscriber@example.com",
            id: "account-1",
            subscribed: true
        )
    )

    private func peer(_ byte: UInt8) -> String {
        "nodekey:" + String(repeating: String(format: "%02x", byte), count: 32)
    }

    private func makeSnapshot(revision: Int64, peers: [String]) -> TailcatAllowlistSnapshot {
        TailcatAllowlistSnapshot(
            epoch: "epoch-rotation",
            revision: revision,
            clients: peers.enumerated().map { index, nodePublic in
                TailcatCatalogClient(
                    clientId: "client-\(index)",
                    displayName: "Client \(index)",
                    nodePublic: nodePublic,
                    transportBuildId: TailcatTransportContract.buildID,
                    createdAt: "2026-08-30T00:00:00Z",
                    updatedAt: "2026-08-30T00:00:00Z",
                    leaseExpiresAt: "2026-09-06T00:00:00Z",
                    version: 1
                )
            }
        )
    }
}

/// Records, in call order, what the supervisor tells the listener:
/// `digest:<value|nil>`, `announce:<digest>`, `stop`.
private final class RecordingTailcatListener: TailcatLoopbackListening, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var entries: [String] { lock.withLock { log } }
    var announces: [String] { entries.filter { $0.hasPrefix("announce:") } }
    var lastDigestEntry: String? { entries.last(where: { $0.hasPrefix("digest:") }) }

    func start() throws -> UInt16 { 45_123 }
    func stop() { lock.withLock { log.append("stop") } }
    func setPublishedEndpointDigest(_ digest: String?) {
        lock.withLock { log.append("digest:\(digest ?? "nil")") }
    }
    func announceRotation(retiringDigest: String) {
        lock.withLock { log.append("announce:\(retiringDigest)") }
    }
}

private final class RotationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)

    var now: Date { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

private final class RotationTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
