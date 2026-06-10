import XCTest
import AppKit
@testable import AppShell
import Persistence

/// Tests for `AppDelegate.aboutPanelOptions(version:build:channel:)`.
///
/// Business rules:
///   R1 — `.applicationVersion` always equals the supplied version string so
///         the About panel's human-readable version is accurate.
///   R2 — `.version` (build number) is included only when `build` is non-nil
///         AND differs from `version`; omitting it avoids the redundant
///         "1.2.3 (1.2.3)" display that AppKit shows when both keys carry the
///         same value.
///   R3 — For non-stable channels a `.credits` entry carrying the channel name
///         is included so QA/beta users can see which build track they are on.
///   R4 — For .stable the `.credits` key is absent; production users must not
///         see an internal channel label.
///
/// The helper is `nonisolated static` — no @MainActor, no AppKit side-effects.
final class AboutPanelOptionsTests: XCTestCase {

    // MARK: - R1: version always present

    func test_applicationVersion_alwaysPresent() {
        // R1: the displayed version string must reach the About panel exactly
        // as supplied — a mismatch would show a stale or wrong version to users.
        let opts = AppDelegate.aboutPanelOptions(version: "2.5.1", build: nil, channel: .stable)
        XCTAssertEqual(
            opts[.applicationVersion] as? String, "2.5.1",
            "applicationVersion must equal the supplied version — users read this to verify they are on the right release"
        )
    }

    // MARK: - R2: build included only when distinct

    func test_buildIncluded_whenDifferentFromVersion() {
        // R2: distinct build number must appear so support can cross-reference
        // the exact binary against CI artifacts.
        let opts = AppDelegate.aboutPanelOptions(version: "2.5.1", build: "789", channel: .stable)
        XCTAssertEqual(
            opts[.version] as? String, "789",
            "build must be included when it differs from version — support needs the build number to locate the correct CI artifact"
        )
    }

    func test_buildOmitted_whenMatchesVersion() {
        // R2: when build == version AppKit would render "1.2.3 (1.2.3)" — redundant;
        // the key must be absent so AppKit shows only one version line.
        let opts = AppDelegate.aboutPanelOptions(version: "1.2.3", build: "1.2.3", channel: .stable)
        XCTAssertNil(
            opts[.version],
            "version key must be absent when build == version — identical strings produce a redundant display line in the standard About panel"
        )
    }

    func test_buildOmitted_whenNil() {
        // R2: absent build must not inject a nil into the dict (AppKit would
        // crash or show "(null)").
        let opts = AppDelegate.aboutPanelOptions(version: "3.0.0", build: nil, channel: .stable)
        XCTAssertNil(
            opts[.version],
            "version key must be absent when build is nil — inserting nil would crash AppKit"
        )
    }

    // MARK: - R3: non-stable channel label present

    func test_channelLabel_presentForDebug() {
        // R3: debug builds must show the channel so developers know at a glance
        // which track they are running.
        let opts = AppDelegate.aboutPanelOptions(version: "1.0.0", build: nil, channel: .debug)
        let credits = opts[.credits] as? NSAttributedString
        XCTAssertNotNil(
            credits,
            "credits must be set for debug channel — engineers need channel provenance in the About panel"
        )
        XCTAssertTrue(
            credits?.string.contains("debug") == true,
            "credits string must contain the channel name so the channel is unambiguous"
        )
    }

    func test_channelLabel_presentForCanary() {
        // R3: canary builds distributed to beta testers must identify themselves
        // so testers can confirm they are on the canary track before filing a report.
        let opts = AppDelegate.aboutPanelOptions(version: "1.0.0", build: nil, channel: .canary)
        let credits = opts[.credits] as? NSAttributedString
        XCTAssertNotNil(
            credits,
            "credits must be set for canary channel"
        )
        XCTAssertTrue(
            credits?.string.contains("canary") == true,
            "credits string must contain 'canary' so testers can confirm their build track"
        )
    }

    // MARK: - R4: stable channel omits label

    func test_channelLabel_absentForStable() {
        // R4: production users must not see an internal "stable" label —
        // it is meaningless to end users and would look like a bug.
        let opts = AppDelegate.aboutPanelOptions(version: "1.0.0", build: nil, channel: .stable)
        XCTAssertNil(
            opts[.credits],
            "credits must be absent for stable channel — internal channel labels must not reach end users"
        )
    }

    // MARK: - Combined: version + distinct build + non-stable channel

    func test_allFieldsPresent_forDebugWithDistinctBuild() {
        // Compound: all three rules fire together for a typical CI debug build.
        let opts = AppDelegate.aboutPanelOptions(version: "0.9.0", build: "42", channel: .debug)
        XCTAssertEqual(opts[.applicationVersion] as? String, "0.9.0",
            "applicationVersion must be the short version string")
        XCTAssertEqual(opts[.version] as? String, "42",
            "build must be present and equal to the supplied build string")
        XCTAssertNotNil(opts[.credits],
            "credits must be present for a non-stable channel")
    }
}
