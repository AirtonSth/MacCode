import Foundation
import Persistence
import SocketServer
import XCTest
@testable import AppShell

/// F5: a real supervisor and a real push bridge wired the way `AppDelegate`
/// wires them: the bridge reads the hint with the digest from the supervisor,
/// and every successful publish asks the bridge to announce.
///
/// The fake Tailcat library names the key in each blob (`blobsFollowKeys`), so
/// the digest stays the same only because the keys were reused. With constant
/// blobs a wake that minted new keys would read the same digest and the "no
/// push" cases would pass by construction.
final class TailcatRotationPushCompositionTests: XCTestCase {
    private static let legacyBucketKey = "private.silentCatchUp.lastBucket"
    private static let bucketsKey = "private.silentCatchUp.lastBuckets"
    private static let announcedDigestKey = "private.tailcat.announcedDigest.v1"
    // Digests computed outside Swift (Python hashlib) for the build id of
    // `TailcatTransportContract.buildID` and the blobs the fake bridge returns.
    /// First key pair (`public-1`, `public-2`).
    private static let firstKeysDigest = "e455e10a45f82ef02d4065571548ec8ad5034d3d246a4f9ab5d44c5413c9d73a"
    /// Second key pair (`public-3`, `public-4`).
    private static let secondKeysDigest = "fc22b2f2607f83cfb36710452da98c2769325610c92f98f9a4d49f37355f4455"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.legacyBucketKey)
        clearCoalesceBuckets()
    }

    /// WHY: the plan's three "none" cases. The rotation push exists for a
    /// changed address only: a first publish, a 5-minute renewal and a wake
    /// with the same keys each ask the bridge, and none of them may wake the
    /// phone. The 30 s bucket is cleared before each step so that the
    /// baseline, not the bucket, is what refuses.
    func testFirstPublishRenewalAndSameKeyWakeSendNoTailcatPush() async throws {
        let host = try makeHost()
        let app = launch(host)

        clearCoalesceBuckets()
        await app.supervisor.setEnabled(true)
        await app.supervisor.reconcileNowForTesting()
        let askedAfterPublish = await app.announces.settled()
        XCTAssertEqual(askedAfterPublish, 1, "the first publish asked the bridge")
        XCTAssertEqual(try announcedDigest(host), Self.firstKeysDigest, "and it only seeded the baseline")
        XCTAssertTrue(host.api.requests.isEmpty, "first publish")

        clearCoalesceBuckets()
        host.clock.advance(TailcatTransportContract.renewalInterval)
        await app.supervisor.reconcileNowForTesting()
        let askedAfterRenewal = await app.announces.settled()
        let publishesAfterRenewal = await host.catalog.publishAccessTokens.count
        XCTAssertEqual(publishesAfterRenewal, 2, "the renewal must have run")
        XCTAssertEqual(askedAfterRenewal, 2, "the renewal asked the bridge")
        XCTAssertTrue(host.api.requests.isEmpty, "5-minute renewal")

        clearCoalesceBuckets()
        await app.supervisor.suspend()
        await app.supervisor.resume()
        let askedAfterWake = await app.announces.settled()
        let digestAfterWake = await app.supervisor.pushHintWithEndpointDigest()?.endpointDigest
        XCTAssertEqual(host.tailcat.startCalls.count, 4, "the wake must have restarted the runtime")
        XCTAssertEqual(
            Set(host.tailcat.startCalls.suffix(2).map(\.key.publicKey)),
            Set(host.tailcat.startCalls.prefix(2).map(\.key.publicKey)),
            "with the same keys"
        )
        XCTAssertEqual(askedAfterWake, 3, "the wake's publish asked the bridge")
        XCTAssertEqual(digestAfterWake, Self.firstKeysDigest)
        XCTAssertTrue(host.api.requests.isEmpty, "sleep then wake with the same keys")
        await app.supervisor.setEnabled(false)
    }

    /// WHY: the one case the push exists for. New keys mean the address every
    /// phone saved is dead, so the Mac asks for exactly one silent push that
    /// carries the digest of the new address, and the renewals that follow
    /// (each of which asks again) must not repeat it.
    func testRotationSendsExactlyOneTailcatPushWithTheNewDigest() async throws {
        let host = try makeHost()
        let app = launch(host)
        await app.supervisor.setEnabled(true)
        await app.supervisor.reconcileNowForTesting()
        _ = await app.announces.settled()
        XCTAssertTrue(host.api.requests.isEmpty, "fixture: the first publish only seeds the baseline")

        // A device registered: admission changed while the runtime is live, so the keys rotate.
        clearCoalesceBuckets()
        await host.catalog.setSnapshot(makeSnapshot(revision: 2, peers: [peer(0xa1), peer(0xa2)]))
        await app.supervisor.reconcileNowForTesting()
        _ = await app.announces.settled()

        XCTAssertEqual(host.api.requests.count, 1, "one push for the rotation")
        let push = try XCTUnwrap(host.api.requests.first)
        XCTAssertTrue(push.silent)
        XCTAssertEqual(push.data["rc2_reason"], "tailcat_endpoint_changed")
        XCTAssertEqual(push.data["rc2_tc_dig"], Self.secondKeysDigest, "the digest of the new address")
        XCTAssertEqual(
            Set(push.data.keys),
            [
                "rc2_catch_up", "rc2_schema", "rc2_reason", "rc2_wm", "rc2_boot_epoch",
                "rc2_tc_sid", "rc2_tc_ver", "rc2_tc_exp", "rc2_tc_build", "rc2_tc_dig",
            ],
            "the supervisor's hint adds the digest and nothing else"
        )
        XCTAssertFalse(push.data.values.contains { $0.contains("blob") }, "never a ConnBlob (gate G9)")

        clearCoalesceBuckets()
        await app.supervisor.reconcileNowForTesting()
        _ = await app.announces.settled()
        clearCoalesceBuckets()
        host.clock.advance(TailcatTransportContract.renewalInterval)
        await app.supervisor.reconcileNowForTesting()
        let asked = await app.announces.settled()
        let publishes = await host.catalog.publishAccessTokens.count
        XCTAssertEqual(publishes, 3, "the renewal must have run")
        XCTAssertEqual(asked, 3, "the first publish, the rotation and the renewal each asked the bridge")
        XCTAssertEqual(host.api.requests.count, 1, "one push per rotation, none per reconcile or renewal")
        await app.supervisor.setEnabled(false)
    }

    /// WHY: a relaunch already costs one forced boot wake, so one that reuses
    /// the keys must not add a rotation push; and a relaunch that publishes
    /// another address must send one. That needs the baseline on disk: kept in
    /// memory, the third launch would seed it again and send nothing.
    func testRelaunchWithTheSameKeysSendsNoTailcatPushAndWithNewKeysSendsOne() async throws {
        let host = try makeHost()
        let first = launch(host)
        await first.supervisor.setEnabled(true)
        await first.supervisor.reconcileNowForTesting()
        _ = await first.announces.settled()
        XCTAssertEqual(try announcedDigest(host), Self.firstKeysDigest, "fixture: the first launch seeded the baseline")
        // Quit keeps the keys.
        await first.supervisor.shutdown()

        clearCoalesceBuckets()
        let second = launch(host)
        await second.supervisor.setEnabled(true)
        await second.supervisor.reconcileNowForTesting()
        let askedBySecond = await second.announces.settled()
        let digestOfSecond = await second.supervisor.pushHintWithEndpointDigest()?.endpointDigest
        XCTAssertEqual(askedBySecond, 1, "the relaunch's publish asked its own bridge")
        XCTAssertEqual(digestOfSecond, Self.firstKeysDigest, "keys reused: the same address")
        XCTAssertTrue(host.api.requests.isEmpty, "a relaunch with the same keys sends no rotation push")
        await second.supervisor.shutdown()

        // The stored keys are gone: this launch mints the next pair.
        try host.secureStore.clear()
        clearCoalesceBuckets()
        let third = launch(host)
        await third.supervisor.setEnabled(true)
        await third.supervisor.reconcileNowForTesting()
        _ = await third.announces.settled()

        XCTAssertEqual(host.api.requests.count, 1, "a relaunch with new keys announces the new address at once")
        let push = try XCTUnwrap(host.api.requests.first)
        XCTAssertTrue(push.silent)
        XCTAssertEqual(push.data["rc2_reason"], "tailcat_endpoint_changed")
        XCTAssertEqual(push.data["rc2_tc_dig"], Self.secondKeysDigest)
        await third.supervisor.shutdown()
    }

    /// WHY: no unit test builds an `AppDelegate` that creates its own
    /// supervisor. Without these three statements the Mac never sends the
    /// digest, never announces a rotation and never hears a path change, and
    /// every other test stays green. So the source is read.
    func testAppDelegateWiresTheDigestHintThePublishAnnounceAndThePathTrigger() throws {
        let appDelegate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AppShell/AppDelegate.swift")
        let code = try String(contentsOf: appDelegate, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(
            code.contains("supervisor.pushHintWithEndpointDigest()"),
            "the push hint source must carry the endpoint digest"
        )
        XCTAssertFalse(code.contains("supervisor.pushHint()"), "the four-fact hint would send no `rc2_tc_dig`")
        XCTAssertTrue(code.contains("publishHandler:"), "a publish must reach the push bridge")
        XCTAssertTrue(code.contains("announceTailcatEndpointIfChanged()"), "a publish must ask for the rotation push")
        XCTAssertTrue(
            code.contains("tailcatPathObserver = TailcatNetworkPathObserver"),
            "the network path observer must be created"
        )
        XCTAssertTrue(code.contains("networkPathChanged()"), "a path change must reach the supervisor")
        XCTAssertTrue(code.contains("tailcatPathObserver?.start()"), "an observer that is not started hears nothing")
    }

    // MARK: - Helpers

    /// What outlives one run of the app: the settings database (the bridge's
    /// baseline and budget), the stored keys, the Tailcat library and the catalog.
    private struct Host {
        let settings: SettingsRepository
        let accountStore: PrivateAccountSessionStore
        let targetStore: PrivatePushTargetStore
        let api: SilentWakeRecordingAPI
        let tailcat: FakeTailcatBridge
        let secureStore: FakeTailcatStore
        let catalog: FakeTailcatCatalog
        let clock: CompositionTestClock
    }

    /// One run of the app: its supervisor, its bridge and the announces it
    /// started. The publish handler holds the bridge weakly, as `AppDelegate`
    /// does, so this value is what keeps it alive.
    private struct Launch {
        let supervisor: TailcatRuntimeSupervisor
        let bridge: PrivateNotificationBridge
        let announces: AnnounceTasks
    }

    /// Its own settings database (never an `AppContext`, which builds a second
    /// bridge), a signed-in subscribed account and one push target.
    private func makeHost() throws -> Host {
        let tmp = NSTemporaryDirectory() + "rc2-tailcat-rotation-push-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let settings = SettingsRepository(db: db)
        let accountStore = PrivateAccountSessionStore(repo: settings)
        let targetStore = PrivatePushTargetStore(repo: settings)
        let api = SilentWakeRecordingAPI()
        accountStore.save(api.session)
        try targetStore.save(
            pushToken: "apns-token",
            pushTokenType: "apns",
            liveActivityToken: nil,
            deviceId: "device-1"
        )
        return Host(
            settings: settings,
            accountStore: accountStore,
            targetStore: targetStore,
            api: api,
            tailcat: FakeTailcatBridge(blobsFollowKeys: true),
            secureStore: FakeTailcatStore(),
            catalog: FakeTailcatCatalog(
                snapshot: makeSnapshot(revision: 1, peers: [peer(0xa1)]),
                leaseExpiresAt: "2099-01-01T00:00:00Z"
            ),
            clock: CompositionTestClock()
        )
    }

    /// The three statements of `AppDelegate`, except that the test keeps each
    /// announce task so it can wait for it.
    private func launch(_ host: Host) -> Launch {
        let bridge = PrivateNotificationBridge(
            accountStore: host.accountStore,
            pushTargetStore: host.targetStore,
            api: host.api,
            settings: host.settings
        )
        let announces = AnnounceTasks()
        let accountStore = host.accountStore
        let clock = host.clock
        let supervisor = TailcatRuntimeSupervisor(
            serverID: "server-1",
            displayName: "Test Mac",
            bridge: host.tailcat,
            catalog: host.catalog,
            secureStore: host.secureStore,
            sessionProvider: { accountStore.load() },
            authenticator: TailcatRemoteConnectionAuthenticator(),
            listener: FakeTailcatListener(),
            now: { clock.now },
            automaticPolling: false,
            publishHandler: { [weak bridge] in
                announces.add(Task { [weak bridge] in
                    guard let bridge else { return false }
                    await bridge.announceTailcatEndpointIfChanged()
                    return true
                })
            },
            statusHandler: { _ in }
        )
        bridge.setConnectionHintSources(
            tailcat: { await supervisor.pushHintWithEndpointDigest() },
            watermark: { "42" },
            bootEpoch: { "7" }
        )
        return Launch(supervisor: supervisor, bridge: bridge, announces: announces)
    }

    private func announcedDigest(_ host: Host) throws -> String? {
        try host.settings.get(Self.announcedDigestKey)
    }

    /// A real renewal is 300 s later, in another 30 s bucket.
    private func clearCoalesceBuckets() {
        UserDefaults.standard.removeObject(forKey: Self.bucketsKey)
    }

    private func peer(_ byte: UInt8) -> String {
        "nodekey:" + String(repeating: String(format: "%02x", byte), count: 32)
    }

    private func makeSnapshot(revision: Int64, peers: [String]) -> TailcatAllowlistSnapshot {
        TailcatAllowlistSnapshot(
            epoch: "epoch-rotation-push",
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

/// The announce tasks one supervisor's publish handler started.
private final class AnnounceTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Bool, Never>] = []

    func add(_ task: Task<Bool, Never>) { lock.withLock { tasks.append(task) } }

    /// Waits for every announce started so far and returns how many ran on a
    /// live bridge, so a "no push" step cannot pass because nothing asked.
    func settled() async -> Int {
        var ran = 0
        for task in lock.withLock({ tasks }) {
            if await task.value { ran += 1 }
        }
        return ran
    }
}

private final class CompositionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)

    var now: Date { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}
