import XCTest
@testable import AppShell

final class MaterialWakeTaxonomyTests: XCTestCase {
    func testPhaseACriticalLifecycleClassifications() {
        // WHY: run lifecycle kinds already have producers; they must keep waking
        // a suspended phone for started/completed/failed transitions.
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "agent.run.started"), .criticalAlertAndSilent)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "agent.run.completed"), .criticalAlertAndSilent)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "agent.run.failed"), .criticalAlertAndSilent)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "host.boot_epoch"), .silentForce)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "device.revoke"), .criticalAlert)
    }

    func testPublishedAttentionKindsReplacePhantoms() {
        // WHY: AppContext publishes these kinds for approval / question / error /
        // notification UX. The old phantom names (agent.approval, …) had zero
        // publishers, so phones never woke on those user-facing states.
        XCTAssertEqual(
            MaterialWakeTaxonomy.classification(forEventKind: "agent.request.opened"),
            .criticalAlertAndSilent
        )
        XCTAssertEqual(
            MaterialWakeTaxonomy.classification(forEventKind: "agent.user_input.requested"),
            .criticalAlertAndSilent
        )
        XCTAssertEqual(
            MaterialWakeTaxonomy.classification(forEventKind: "agent.run.error"),
            .criticalAlertAndSilent
        )
        XCTAssertEqual(
            MaterialWakeTaxonomy.classification(forEventKind: "notification.created"),
            .silent
        )

        // Retired phantom allowlist entries must fail closed (streamOnly).
        for phantom in [
            "agent.approval",
            "agent.question",
            "agent.attention",
            "agent.run.cancelled",
            "host.identity",
            "session.unauthorized",
        ] {
            XCTAssertEqual(
                MaterialWakeTaxonomy.classification(forEventKind: phantom),
                .streamOnly,
                "\(phantom) has no host publisher and must not wake"
            )
        }
    }

    func testStreamOnlyNeverPush() {
        // WHY: surface.output / agent.item.delta fire per chunk; prefix matching
        // them would push on every keystroke of model output.
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "surface.output"), .streamOnly)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "agent.item.delta"), .streamOnly)
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "heartbeat"), .streamOnly)
        XCTAssertFalse(MaterialWakeTaxonomy.phaseAAllowsSilent(.streamOnly))
    }

    func testUnknownDefaultsStreamOnly() {
        // WHY: fail-closed on flood — unknown kinds must never auto-push.
        XCTAssertEqual(MaterialWakeTaxonomy.classification(forEventKind: "totally.unknown.event"), .streamOnly)
    }

    func testCoalesceClassesKeepAttentionSeparateFromRunProgress() {
        // WHY: a single global 30s bucket let run.completed swallow the next
        // approval/question/error. Separate classes make that impossible.
        XCTAssertEqual(
            MaterialWakeTaxonomy.coalesceClass(forEventKind: "agent.run.completed"),
            .runProgress
        )
        XCTAssertEqual(
            MaterialWakeTaxonomy.coalesceClass(forEventKind: "agent.run.started"),
            .runProgress
        )
        XCTAssertEqual(
            MaterialWakeTaxonomy.coalesceClass(forEventKind: "agent.request.opened"),
            .attention
        )
        XCTAssertEqual(
            MaterialWakeTaxonomy.coalesceClass(forEventKind: "agent.user_input.requested"),
            .attention
        )
        XCTAssertEqual(
            MaterialWakeTaxonomy.coalesceClass(forEventKind: "agent.run.error"),
            .attention
        )
        XCTAssertEqual(
            MaterialWakeTaxonomy.coalesceClass(forEventKind: "agent.run.failed"),
            .attention
        )
        XCTAssertEqual(
            MaterialWakeTaxonomy.coalesceClass(forEventKind: "notification.created"),
            .notification
        )
        XCTAssertEqual(
            MaterialWakeTaxonomy.coalesceClass(forEventKind: "host.boot_epoch"),
            .boot
        )
        XCTAssertNotEqual(
            MaterialWakeTaxonomy.coalesceClass(forEventKind: "agent.run.completed"),
            MaterialWakeTaxonomy.coalesceClass(forEventKind: "agent.request.opened"),
            "attention must not share a coalesce bucket with run progress"
        )
    }

    func testSilentCatchUpV1PayloadPrivacyAndParse() {
        let payload = SilentCatchUpV1(
            catchUp: true,
            watermark: "42",
            sinceSeq: "100",
            bootEpoch: "7",
            reason: "run_completed"
        )
        let data = payload.asPushData()
        XCTAssertEqual(data["rc2_catch_up"], "1")
        XCTAssertEqual(data["rc2_schema"], SilentCatchUpV1.schemaVersion)
        XCTAssertEqual(data["rc2_wm"], "42")
        XCTAssertEqual(data["rc2_since_seq"], "100")
        XCTAssertEqual(data["rc2_boot_epoch"], "7")
        XCTAssertEqual(data["rc2_reason"], "run_completed")
        // Must not accept free-form agent text as watermark.
        let scrubbed = SilentCatchUpV1(watermark: "agent said hello", reason: "x; DROP TABLE")
        XCTAssertNil(scrubbed.watermark)
        XCTAssertEqual(scrubbed.reason, "x__drop_table")

        let parsed = SilentCatchUpV1.parse([
            "rc2_catch_up": "1",
            "rc2_wm": "9",
            "unknown_future": "x",
        ])
        XCTAssertEqual(parsed?.watermark, "9")
        XCTAssertTrue(parsed?.catchUp == true)
    }

    func testPhaseAAllowsSilentMatrix() {
        XCTAssertTrue(MaterialWakeTaxonomy.phaseAAllowsSilent(.criticalAlertAndSilent))
        XCTAssertTrue(MaterialWakeTaxonomy.phaseAAllowsSilent(.silent))
        XCTAssertTrue(MaterialWakeTaxonomy.phaseAAllowsSilent(.silentForce))
        XCTAssertFalse(MaterialWakeTaxonomy.phaseAAllowsSilent(.criticalAlert))
        XCTAssertFalse(MaterialWakeTaxonomy.phaseAAllowsSilent(.silentOrAlert))
        XCTAssertTrue(MaterialWakeTaxonomy.shouldForceSilent(.silentForce))
    }

    func testPublishedAttentionKindsAnchoredToHostEventBusPublishSites() throws {
        // WHY: the kill-switch set must track kinds the host actually publishes.
        // A hand-copied literal of `publishedAttentionKinds` is tautological —
        // it cannot fail when the constant drifts away from real producers.
        // Anchor: scan the host publish sites (AppContext agent attention +
        // notification.created publishers) and require exact set equality.
        let hostAttentionProducerKinds: Set<String> = [
            // AppContext.swift — agent.request.opened / user_input / run.error
            "agent.request.opened",
            "agent.user_input.requested",
            "agent.run.error",
            // AppCommandRouter.swift + AppDelegate.swift — notification.created
            "notification.created",
        ]

        let publishedInHostSources = try Self.eventBusPublishKinds(inRelativePaths: [
            "Sources/AppShell/AppContext.swift",
            "Sources/AppShell/AppCommandRouter.swift",
            "Sources/AppShell/AppDelegate.swift",
        ])

        for kind in hostAttentionProducerKinds {
            XCTAssertTrue(
                publishedInHostSources.contains(kind),
                "host source must still publish \(kind); allowlist is useless without a producer"
            )
        }

        XCTAssertEqual(
            MaterialWakeTaxonomy.publishedAttentionKinds,
            hostAttentionProducerKinds,
            "kill-switch set must equal the host attention EventBus producer kinds"
        )
        XCTAssertTrue(MaterialWakeTaxonomy.phaseAKinds.isSuperset(of: MaterialWakeTaxonomy.publishedAttentionKinds))
        XCTAssertTrue(MaterialWakeTaxonomy.phaseAKinds.contains("host.boot_epoch"))

        // Boot-identity force wake is also a real host publish (AppContext start).
        XCTAssertTrue(
            publishedInHostSources.contains("host.boot_epoch"),
            "AppContext must still publish host.boot_epoch after MaterialWakeCoordinator.start"
        )
    }

    func testDeviceRevokeHasRealPublisher() throws {
        // WHY: device.revoke was taxonomy-only with zero publishers, so a
        // revoked/kicked device never woke the material-wake path. LocalAuthAdapter
        // must publish the kind with the device id.
        let published = try Self.eventBusPublishKinds(inRelativePaths: [
            "Sources/AppShell/LocalAuthAdapter.swift",
        ])
        XCTAssertTrue(
            published.contains("device.revoke"),
            "LocalAuthAdapter.revokeDevice must EventBus.publish(kind: device.revoke)"
        )
        XCTAssertEqual(
            MaterialWakeTaxonomy.classification(forEventKind: "device.revoke"),
            .criticalAlert
        )
        XCTAssertTrue(MaterialWakeTaxonomy.phaseACoreKinds.contains("device.revoke"))
    }

    func testGitConflictIsDeadTaxonomyStreamOnly() {
        // WHY: no git-conflict detector exists in SocketServer/AppShell; listing
        // it as Phase B silentOrAlert invents a wake path that can never fire
        // from a real producer. Unknown/dead kinds fail closed as stream_only.
        XCTAssertEqual(
            MaterialWakeTaxonomy.classification(forEventKind: "git.conflict"),
            .streamOnly
        )
        XCTAssertEqual(
            MaterialWakeTaxonomy.coalesceClass(forEventKind: "git.conflict"),
            .other,
            "dead kinds must not share the real git coalesce bucket"
        )
        // Real git producers remain Phase B.
        for kind in ["git.commit", "git.push", "git.checkout", "git.branch_created"] {
            XCTAssertEqual(
                MaterialWakeTaxonomy.classification(forEventKind: kind),
                .silentOrAlert,
                "\(kind) still has a real publisher and stays Phase B"
            )
        }
    }

    /// Extract `EventBus.shared.publish(kind: "…")` string literals from host sources.
    private static func eventBusPublishKinds(inRelativePaths paths: [String]) throws -> Set<String> {
        // Tests/AppShellTests/ThisFile.swift → repo root.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pattern = try NSRegularExpression(
            pattern: #"EventBus\.shared\.publish\(\s*kind:\s*"([^"]+)""#,
            options: []
        )
        var kinds = Set<String>()
        for relative in paths {
            let url = repoRoot.appendingPathComponent(relative)
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            pattern.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 2,
                      let swiftRange = Range(match.range(at: 1), in: text) else { return }
                kinds.insert(String(text[swiftRange]))
            }
        }
        XCTAssertFalse(kinds.isEmpty, "expected to find EventBus.publish sites in host sources")
        return kinds
    }
}
