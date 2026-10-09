import XCTest
@testable import AppShell

final class TailcatEndpointDigestTests: XCTestCase {
    private static let validDigest = "15b48f53ead19fe5862e0892d09e068ca614eec2df67e6aa7c82eeca72e6f7c4"

    func testDigestMatchesTheIPhoneGoldenVectors() {
        // WHY: the iPhone compares `rc2_tc_dig` with the digest of the record
        // it saved. If the two apps disagree, every push tells the phone its
        // address is stale. The first two values are the ones frozen in iOS
        // `TailcatEndpointRecordTests.testDigestGoldenVector`; all three were
        // computed outside Swift (Python hashlib). "\u{FC}" is two UTF-8
        // bytes, so a character count in the length prefix fails.
        XCTAssertEqual(
            TailcatEndpointDigest.digest(
                buildId: "tailcat-golden+build1",
                endpoints: [
                    endpoint("blob-derp-\u{FC}", priority: 20),
                    endpoint("blob-direct-b", priority: 10, kind: .direct),
                    endpoint("blob-direct-a", priority: 10, kind: .direct),
                ]
            ),
            "bfa577f46400df0efb14089f423480503907ce9fdc37151114af695e3e99dd0c"
        )
        XCTAssertEqual(
            TailcatEndpointDigest.digest(buildId: "tailcat-golden+build1", endpoints: []),
            "ca0a6ba718179d6db1d18ff183f3610842303cc066b08a3c9d9014df86af68a3"
        )
        XCTAssertEqual(
            TailcatEndpointDigest.digest(
                buildId: "b",
                endpoints: [endpoint("x", priority: 0), endpoint("yz", priority: 1)]
            ),
            "9f87efa7f02525ca04f660c6545e4804a5045bef0883e783b71b1e0a89beecdf"
        )
    }

    func testDigestIgnoresKindPriorityValuesVersionAndLease() {
        // WHY: the Mac publishes again every 5 minutes, and that changes only
        // the version and the lease. A renewal must not look like a rotation.
        let build = TailcatTransportContract.buildID
        let derp = [endpoint("primary-blob", priority: 0), endpoint("fallback-blob", priority: 1)]
        let direct = [
            endpoint("primary-blob", priority: 0, kind: .direct),
            endpoint("fallback-blob", priority: 1, kind: .direct),
        ]
        let otherPriorities = [endpoint("primary-blob", priority: 5), endpoint("fallback-blob", priority: 9)]
        let published = host(endpoints: derp, leaseExpiresAt: "2026-10-09T10:15:00Z", version: 7)
        let renewed = host(endpoints: derp, leaseExpiresAt: "2026-10-09T10:20:00Z", version: 8)

        let expected = TailcatEndpointDigest.digest(buildId: build, endpoints: derp)
        XCTAssertEqual(expected, Self.validDigest)
        XCTAssertEqual(TailcatEndpointDigest.digest(buildId: build, endpoints: direct), expected)
        XCTAssertEqual(TailcatEndpointDigest.digest(buildId: build, endpoints: otherPriorities), expected)
        XCTAssertNotEqual(published, renewed)
        XCTAssertEqual(
            TailcatEndpointDigest.digest(buildId: renewed.transportBuildId, endpoints: renewed.endpoints),
            TailcatEndpointDigest.digest(buildId: published.transportBuildId, endpoints: published.endpoints)
        )
    }

    func testDigestOrdersEqualPrioritiesByBlobBytes() {
        // WHY: the catalog sorts by priority only, so two endpoints of one
        // priority can come back in either order; the digest must not move.
        XCTAssertEqual(
            TailcatEndpointDigest.digest(
                buildId: "b",
                endpoints: [endpoint("blob-b", priority: 3), endpoint("blob-a", priority: 3)]
            ),
            TailcatEndpointDigest.digest(
                buildId: "b",
                endpoints: [endpoint("blob-a", priority: 3), endpoint("blob-b", priority: 3)]
            )
        )

        // The tie is by UTF-8 bytes, as on the iPhone. These two blobs are
        // equal for `String ==` and `<` (canonical equivalence), so a sort
        // by `String <` would keep the input order and give two digests.
        let precomposed = endpoint("blob-\u{E9}", priority: 3)
        let decomposed = endpoint("blob-e\u{301}", priority: 3)
        let expected = "7177cf2f56c936789277a1ee879b5061599f61a3fef985a9565a417fefec9174"
        XCTAssertEqual(
            TailcatEndpointDigest.digest(buildId: "b", endpoints: [precomposed, decomposed]),
            expected
        )
        XCTAssertEqual(
            TailcatEndpointDigest.digest(buildId: "b", endpoints: [decomposed, precomposed]),
            expected
        )
    }

    func testDigestFramesTheBuildId() {
        // WHY: two addresses must never share a digest. Without the length
        // prefix "ab" + "c" and "a" + "bc" are the same byte stream.
        let first = TailcatEndpointDigest.digest(buildId: "ab", endpoints: [endpoint("c", priority: 0)])
        let second = TailcatEndpointDigest.digest(buildId: "a", endpoints: [endpoint("bc", priority: 0)])

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, "601d5476e2ccfe2c87a2bba7a322659734a05749d5b5aa781f513e4912db0d5f")
        XCTAssertEqual(second, "3fafa1cf2f19a7c1129beb20cf0983f73a489a221fc0dd2f16d1be292d089205")
    }

    func testDigestOfTheFakePublishedHost() {
        // WHY: these are the endpoints the supervisor test fakes publish. A
        // wake where only one relay starts publishes another set, and the
        // phone must be told: one relay missing is another digest.
        let build = TailcatTransportContract.buildID
        let primary = endpoint("primary-blob", priority: 0)
        let fallback = endpoint("fallback-blob", priority: 1)

        XCTAssertEqual(build.utf8.count, 57)
        XCTAssertEqual(
            TailcatEndpointDigest.digest(buildId: build, endpoints: [primary, fallback]),
            "15b48f53ead19fe5862e0892d09e068ca614eec2df67e6aa7c82eeca72e6f7c4"
        )
        XCTAssertEqual(
            TailcatEndpointDigest.digest(buildId: build, endpoints: [primary]),
            "fab36afaecc72a73b73665294ceb4ae63d78118c5568cf8bdda6660b252eb18e"
        )
        XCTAssertEqual(
            TailcatEndpointDigest.digest(buildId: build, endpoints: [fallback]),
            "be49e1b07bdbfa549a858fee8130cf6f2f795e3d7ac4d599194fad4d683fe5e3"
        )
    }

    func testIsValidAcceptsOnly64LowercaseHex() {
        // WHY: a malformed value must never reach a push; the iPhone rejects
        // the whole hint when the digest is not 64 lowercase hex characters.
        XCTAssertTrue(TailcatEndpointDigest.isValid(Self.validDigest))
        XCTAssertTrue(TailcatEndpointDigest.isValid(String(repeating: "0", count: 64)))
        XCTAssertTrue(
            TailcatEndpointDigest.isValid(TailcatEndpointDigest.digest(buildId: "b", endpoints: []))
        )

        XCTAssertFalse(TailcatEndpointDigest.isValid(""))
        XCTAssertFalse(TailcatEndpointDigest.isValid(String(Self.validDigest.dropLast())), "63 characters")
        XCTAssertFalse(TailcatEndpointDigest.isValid(Self.validDigest + "0"), "65 characters")
        XCTAssertFalse(TailcatEndpointDigest.isValid(Self.validDigest.uppercased()), "uppercase")
        let tail = String(Self.validDigest.dropFirst())
        XCTAssertFalse(TailcatEndpointDigest.isValid("g" + tail), "not hex")
        XCTAssertFalse(
            TailcatEndpointDigest.isValid("\u{FF11}" + tail),
            "64 characters, but a fullwidth digit is not one of the 16 bytes"
        )
    }

    func testMergeWritesTheDigestOnlyWithTheFourKeys() {
        // WHY: an iPhone that knows only the four keys must keep getting
        // them, and a digest that is malformed or belongs to an expired
        // publication must not ride in any push.
        let now = Date(timeIntervalSince1970: 1_000)
        let fourKeys = [
            PushConnectionHints.tailcatServerIdKey, PushConnectionHints.tailcatVersionKey,
            PushConnectionHints.tailcatLeaseExpiresKey, PushConnectionHints.tailcatBuildKey,
        ]
        func merged(digest: String?, lease: String = "2099-01-01T00:00:00Z") -> [String: String] {
            var hint = TailcatPushHint(
                serverId: "srv-1", version: 5, leaseExpiresAt: lease, transportBuildId: "build-1"
            )
            hint.endpointDigest = digest
            // The caller-supplied value stands for a stale or forged digest.
            return PushConnectionHints.merge(
                into: ["rc2_tc_dig": "caller-supplied"], tailcat: hint, watermark: "9", bootEpoch: "3", now: now
            )
        }

        XCTAssertEqual(PushConnectionHints.tailcatDigestKey, "rc2_tc_dig")

        let valid = merged(digest: Self.validDigest)
        XCTAssertEqual(valid["rc2_tc_dig"], Self.validDigest)
        XCTAssertTrue(fourKeys.allSatisfy { valid[$0] != nil })

        for malformed in [String(Self.validDigest.dropLast()), Self.validDigest.uppercased()] {
            let out = merged(digest: malformed)
            XCTAssertNil(out["rc2_tc_dig"], malformed)
            XCTAssertTrue(fourKeys.allSatisfy { out[$0] != nil }, "the four keys do not depend on the digest")
        }

        let noDigest = merged(digest: nil)
        XCTAssertNil(noDigest["rc2_tc_dig"], "a caller-supplied digest is removed when the hint has none")
        XCTAssertTrue(fourKeys.allSatisfy { noDigest[$0] != nil })

        let expired = merged(digest: Self.validDigest, lease: "1970-01-01T00:00:10Z")
        XCTAssertTrue(
            (fourKeys + ["rc2_tc_dig"]).allSatisfy { expired[$0] == nil },
            "an expired lease drops all five"
        )

        let noHint = PushConnectionHints.merge(
            into: ["rc2_tc_dig": "caller-supplied"], tailcat: nil, watermark: "9", bootEpoch: "3", now: now
        )
        XCTAssertNil(noHint["rc2_tc_dig"], "a caller-supplied digest never rides without a published host")
    }

    // MARK: - Fixtures

    private func endpoint(
        _ connBlob: String,
        priority: Int,
        kind: TailcatEndpointKind = .derp
    ) -> TailcatCatalogEndpoint {
        TailcatCatalogEndpoint(kind: kind, priority: priority, connBlob: connBlob)
    }

    private func host(
        endpoints: [TailcatCatalogEndpoint],
        leaseExpiresAt: String,
        version: Int64
    ) -> TailcatCatalogHost {
        TailcatCatalogHost(
            serverId: "srv-1",
            displayName: "Mac",
            endpoints: endpoints,
            transportBuildId: TailcatTransportContract.buildID,
            createdAt: "2026-10-09T10:00:00Z",
            updatedAt: "2026-10-09T10:00:00Z",
            leaseExpiresAt: leaseExpiresAt,
            version: version
        )
    }
}
