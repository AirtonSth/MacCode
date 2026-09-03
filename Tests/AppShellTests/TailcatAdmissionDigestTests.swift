import Foundation
import SocketServer
import XCTest
@testable import AppShell

final class TailcatAdmissionDigestTests: XCTestCase {
    func testMetadataNoise_keepsAdmissionDigest_andChangesLegacyHash() {
        let baseline = snapshot(
            clients: [client(id: "client-0", node: peer(0xaa))]
        )
        let noisy = snapshot(
            revision: baseline.revision,
            clients: [
                client(
                    id: "client-0",
                    name: "Renamed iPhone",
                    node: peer(0xaa),
                    updatedAt: "2026-09-03T12:00:00Z",
                    leaseExpiresAt: "2026-09-13T00:00:00Z",
                    version: 9
                ),
            ]
        )

        XCTAssertEqual(
            baseline.admissionDigest,
            noisy.admissionDigest,
            "displayName / lease / updatedAt / version must not enter the admission digest"
        )
        XCTAssertNotEqual(
            baseline.hash,
            noisy.hash,
            "the legacy full-client hash must keep encoding metadata so it is never reinterpreted as the digest"
        )
        XCTAssertEqual(baseline.admissionDigest.count, 64)
        XCTAssertEqual(baseline.admissionDigest, baseline.admissionDigest.lowercased())
        XCTAssertTrue(baseline.admissionDigest.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(baseline.hash, baseline.admissionDigest)
    }

    func testClientOrder_doesNotChangeAdmissionDigest() {
        let a = snapshot(clients: [
            client(id: "b", node: peer(0xbb)),
            client(id: "a", node: peer(0xaa)),
        ])
        let b = snapshot(clients: [
            client(id: "a", node: peer(0xaa)),
            client(id: "b", node: peer(0xbb)),
        ])
        XCTAssertEqual(a.admissionDigest, b.admissionDigest)
        XCTAssertNotEqual(a.hash, b.hash, "legacy hash remains order-sensitive because it encodes the raw snapshot")
    }

    func testChangingNodePublic_changesAdmissionDigest() {
        let original = snapshot(clients: [client(id: "client-0", node: peer(0xaa))])
        let rotated = snapshot(clients: [client(id: "client-0", node: peer(0xbb))])
        XCTAssertNotEqual(original.admissionDigest, rotated.admissionDigest)
        XCTAssertNotEqual(original.hash, rotated.hash)
    }

    func testDroppingCompatibleClient_changesAdmissionDigest() {
        let two = snapshot(clients: [
            client(id: "client-0", node: peer(0xaa)),
            client(id: "client-1", node: peer(0xbb)),
        ])
        let one = snapshot(clients: [client(id: "client-0", node: peer(0xaa))])
        XCTAssertNotEqual(two.admissionDigest, one.admissionDigest)
    }

    func testIncompatibleClient_isExcludedFromAdmissionDigest() {
        let compatible = snapshot(clients: [client(id: "client-0", node: peer(0xaa))])
        let withIncompatible = snapshot(clients: [
            client(id: "client-0", node: peer(0xaa)),
            client(id: "legacy", node: peer(0xff), buildID: "tailcat-other"),
        ])
        XCTAssertEqual(compatible.admissionDigest, withIncompatible.admissionDigest)
        XCTAssertNotEqual(compatible.hash, withIncompatible.hash)
        XCTAssertEqual(withIncompatible.admittedNodePublics, [peer(0xaa)])
    }

    func testRevisionAndEpoch_doNotEnterAdmissionDigest() {
        let a = snapshot(epoch: "epoch-a", revision: 1, clients: [client(id: "client-0", node: peer(0xaa))])
        let b = snapshot(epoch: "epoch-b", revision: 99, clients: [client(id: "client-0", node: peer(0xaa))])
        XCTAssertEqual(a.admissionDigest, b.admissionDigest)
        XCTAssertNotEqual(a.hash, b.hash)
    }

    func testCatalogErrorClassification_splits401From403AndSubscription() {
        let unauthorized = TailcatCatalogError.http(status: 401, code: "unauthorized")
        let forbidden = TailcatCatalogError.http(status: 403, code: "forbidden")
        XCTAssertTrue(unauthorized.requiresReauthentication)
        XCTAssertFalse(unauthorized.deniesAuthorization)
        XCTAssertFalse(unauthorized.deniesSubscription)
        XCTAssertFalse(forbidden.requiresReauthentication)
        XCTAssertTrue(forbidden.deniesAuthorization)
        XCTAssertFalse(forbidden.deniesSubscription)
        XCTAssertFalse(TailcatCatalogError.invalidResponse.requiresReauthentication)
        XCTAssertFalse(TailcatCatalogError.invalidResponse.deniesAuthorization)
        XCTAssertFalse(TailcatCatalogError.invalidResponse.deniesSubscription)
    }

    func testLegacySecureState_decodesWithoutAdmissionDigest() throws {
        let json = Data("""
        {"accountID":"account-1","allowlistEpoch":"epoch-1","phase":"active","revision":3,"snapshotHash":"abc"}
        """.utf8)
        let state = try JSONDecoder().decode(TailcatSecureState.self, from: json)
        XCTAssertEqual(state.snapshotHash, "abc")
        XCTAssertNil(state.admissionDigest)
        XCTAssertFalse(
            TailcatAdmission.admittedPeersChanged(stored: state, snapshot: snapshot(
                clients: [client(id: "client-0", node: peer(0xaa))]
            )),
            "a pre-digest record must not treat the legacy hash as an admission digest"
        )
    }

    func testSecureState_dualWritesLegacyHashAndAdmissionDigest() throws {
        let snap = snapshot(clients: [client(id: "client-0", node: peer(0xaa))])
        let state = TailcatSecureState(
            phase: .active,
            accountID: "account-1",
            allowlistEpoch: snap.epoch,
            revision: snap.revision,
            snapshotHash: snap.hash,
            admissionDigest: snap.admissionDigest,
            eTag: "\"1\"",
            active: TailcatKeyVersion(
                primary: .init(privateKey: "p", publicKey: "pp"),
                fallback: .init(privateKey: "f", publicKey: "ff")
            ),
            pending: nil
        )
        let encoded = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["snapshotHash"] as? String, snap.hash)
        XCTAssertEqual(object["admissionDigest"] as? String, snap.admissionDigest)
        XCTAssertNotEqual(object["snapshotHash"] as? String, object["admissionDigest"] as? String)
    }

    func testNeedsRotation_isFalseWhenOnlyLeaseAndNameChanged() {
        let original = snapshot(clients: [client(id: "client-0", node: peer(0xaa))])
        let renamed = snapshot(clients: [
            client(
                id: "client-0",
                name: "Kitchen iPad",
                node: peer(0xaa),
                updatedAt: "2026-09-03T18:00:00Z",
                leaseExpiresAt: "2026-09-20T00:00:00Z",
                version: 4
            ),
        ])
        let stored = storedState(for: original)
        XCTAssertEqual(original.admissionDigest, renamed.admissionDigest)
        XCTAssertNotEqual(original.hash, renamed.hash)
        XCTAssertFalse(
            TailcatAdmission.needsRotation(
                stored: stored,
                snapshot: renamed,
                accountID: stored.accountID,
                hostPresent: true,
                eTagPresent: true,
                runtimePresent: true
            ),
            "lease/name noise must not restart transport when the admission digest matches"
        )
        XCTAssertFalse(TailcatAdmission.admittedPeersChanged(stored: stored, snapshot: renamed))
        XCTAssertNoThrow(
            try TailcatAdmission.validate(renamed, stored: stored, accountID: stored.accountID)
        )
    }

    func testNeedsRotation_isTrueWhenCompatiblePeerChanges() {
        let original = snapshot(clients: [client(id: "client-0", node: peer(0xaa))])
        let next = snapshot(revision: 2, clients: [client(id: "client-0", node: peer(0xcc))])
        let stored = storedState(for: original)
        XCTAssertTrue(
            TailcatAdmission.needsRotation(
                stored: stored,
                snapshot: next,
                accountID: stored.accountID,
                hostPresent: true,
                eTagPresent: true,
                runtimePresent: true
            )
        )
        XCTAssertTrue(TailcatAdmission.admittedPeersChanged(stored: stored, snapshot: next))
    }

    func testSameRevisionDifferentDigest_isRejected() {
        let original = snapshot(clients: [client(id: "client-0", node: peer(0xaa))])
        let conflicting = snapshot(clients: [client(id: "client-0", node: peer(0xcc))])
        XCTAssertEqual(original.revision, conflicting.revision)
        XCTAssertNotEqual(original.admissionDigest, conflicting.admissionDigest)
        XCTAssertThrowsError(
            try TailcatAdmission.validate(
                conflicting,
                stored: storedState(for: original),
                accountID: "account-1"
            )
        ) { error in
            XCTAssertEqual(error as? TailcatCatalogError, .invalidResponse)
        }
    }

    func testSupervisor_doesNotRotateWhenOnlyLeaseAndNameChanged() async throws {
        let original = snapshot(clients: [client(id: "client-0", node: peer(0xaa))])
        let renamed = snapshot(clients: [
            client(
                id: "client-0",
                name: "Renamed client",
                node: peer(0xaa),
                updatedAt: "2026-09-03T01:00:00Z",
                leaseExpiresAt: "2026-09-10T00:00:00Z",
                version: 8
            ),
        ])
        let catalog = FakeTailcatCatalog(snapshot: original)
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: store)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        XCTAssertEqual(bridge.startCalls.count, 2)
        XCTAssertEqual(store.state?.admissionDigest, original.admissionDigest)
        XCTAssertEqual(store.state?.snapshotHash, original.hash)

        await catalog.setSnapshot(renamed)
        await supervisor.reconcileNowForTesting()

        XCTAssertEqual(bridge.startCalls.count, 2, "rename/lease renewal must not restart Tailcat servers")
        XCTAssertTrue(bridge.closedHandles.isEmpty)
        XCTAssertEqual(store.state?.phase, .active)
        XCTAssertEqual(store.state?.admissionDigest, renamed.admissionDigest)
        XCTAssertEqual(store.state?.snapshotHash, renamed.hash)
        let active = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(active)
        await supervisor.setEnabled(false)
    }

    func testCatalog401_doesNotRevokeAsRequiresSubscription() async throws {
        let snap = snapshot(clients: [client(id: "client-0", node: peer(0xaa))])
        let catalog = FakeTailcatCatalog(snapshot: snap)
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let statuses = FakeTailcatStatuses()
        let supervisor = makeSupervisor(
            bridge: bridge,
            catalog: catalog,
            store: store,
            statusHandler: { statuses.append($0) }
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        XCTAssertEqual(store.state?.phase, .active)
        let started = bridge.startCalls.count
        XCTAssertEqual(started, 2)

        await catalog.setHostError(TailcatCatalogError.http(status: 401, code: "unauthorized"))
        await supervisor.reconcileNowForTesting()

        XCTAssertFalse(
            statuses.values.contains(.requiresSubscription),
            "token expiry must not take the subscription-revoke path"
        )
        XCTAssertEqual(statuses.values.last, .requiresReauthentication)
        XCTAssertEqual(store.state?.phase, .active)
        XCTAssertEqual(bridge.startCalls.count, started)
        XCTAssertTrue(bridge.closedHandles.isEmpty)
        let active = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(active, "401 must not tear down a healthy runtime; refresh retry is Stage 5")
        await supervisor.setEnabled(false)
    }

    func testCatalog403_doesNotLookLikeHealthyActiveRuntime() async throws {
        let snap = snapshot(clients: [client(id: "client-0", node: peer(0xaa))])
        let catalog = FakeTailcatCatalog(snapshot: snap)
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let statuses = FakeTailcatStatuses()
        let supervisor = makeSupervisor(
            bridge: bridge,
            catalog: catalog,
            store: store,
            statusHandler: { statuses.append($0) }
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        let activeBefore = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeBefore)

        await catalog.setHostError(TailcatCatalogError.http(status: 403, code: "forbidden"))
        await supervisor.reconcileNowForTesting()

        XCTAssertNotEqual(statuses.values.last, .active)
        XCTAssertNotEqual(statuses.values.last, .requiresSubscription)
        let activeAfter = await supervisor.hasActiveRuntimeForTesting
        XCTAssertFalse(activeAfter)
        XCTAssertEqual(Set(bridge.closedHandles), [101, 202])
        XCTAssertNotEqual(store.state?.phase, .active)
    }

    private func makeSupervisor(
        bridge: FakeTailcatBridge,
        catalog: FakeTailcatCatalog,
        store: FakeTailcatStore,
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
            listener: FakeTailcatListener(),
            now: { Date(timeIntervalSince1970: 1_000) },
            automaticPolling: false,
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

    private func storedState(for snapshot: TailcatAllowlistSnapshot) -> TailcatSecureState {
        TailcatSecureState(
            phase: .active,
            accountID: "account-1",
            allowlistEpoch: snapshot.epoch,
            revision: snapshot.revision,
            snapshotHash: snapshot.hash,
            admissionDigest: snapshot.admissionDigest,
            eTag: "\"1\"",
            active: TailcatKeyVersion(
                primary: .init(privateKey: "active-primary", publicKey: "active-primary-public"),
                fallback: .init(privateKey: "active-fallback", publicKey: "active-fallback-public")
            ),
            pending: nil
        )
    }

    private func snapshot(
        epoch: String = "epoch-1",
        revision: Int64 = 1,
        clients: [TailcatCatalogClient]
    ) -> TailcatAllowlistSnapshot {
        TailcatAllowlistSnapshot(epoch: epoch, revision: revision, clients: clients)
    }

    private func client(
        id: String,
        name: String = "Client",
        node: String,
        buildID: String = TailcatTransportContract.buildID,
        createdAt: String = "2026-08-30T00:00:00Z",
        updatedAt: String = "2026-08-30T00:00:00Z",
        leaseExpiresAt: String = "2026-09-06T00:00:00Z",
        version: Int64 = 1
    ) -> TailcatCatalogClient {
        TailcatCatalogClient(
            clientId: id,
            displayName: name,
            nodePublic: node,
            transportBuildId: buildID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            leaseExpiresAt: leaseExpiresAt,
            version: version
        )
    }

    private func peer(_ byte: UInt8) -> String {
        "nodekey:" + String(repeating: String(format: "%02x", byte), count: 32)
    }
}
