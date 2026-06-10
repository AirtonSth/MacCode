import XCTest
import Persistence

/// Verifies that channelFromBundleID correctly maps bundle identifiers to their
/// ReleaseChannel. This matters because the packaged stable app uses bundle id
/// "io.remotecode.desktop" (no suffix) and must not fall into .debug, which
/// would share /tmp/RemoteCodeDebug.sock and collide with dev builds.
final class ChannelBundleIDTests: XCTestCase {

    // MARK: - Exact-match cases

    func test_stableBundleID_returnsStable() {
        // The notarized release app ships with id "io.remotecode.desktop".
        // Resolving to any channel other than .stable causes it to collide
        // with debug socket paths and the wrong AppSupport directory.
        let result = ReleaseChannel.channelFromBundleID("io.remotecode.desktop")
        XCTAssertEqual(
            result, .stable,
            "Stable bundle id must resolve to .stable to use the correct socket/data dirs"
        )
    }

    func test_canaryBundleID_returnsCanary() {
        let result = ReleaseChannel.channelFromBundleID("io.remotecode.desktop.canary")
        XCTAssertEqual(
            result, .canary,
            "Canary bundle id must resolve to .canary to isolate its data dir from stable"
        )
    }

    func test_debugBundleID_returnsDebug() {
        let result = ReleaseChannel.channelFromBundleID("io.remotecode.desktop.debug")
        XCTAssertEqual(
            result, .debug,
            "Debug bundle id must resolve to .debug"
        )
    }

    // MARK: - Unknown / empty input falls back to .debug

    func test_unknownBundleID_returnsDebug() {
        // An unrecognised bundle id (e.g. in a test host) should default to
        // .debug, which is the safe, isolated path, rather than contaminating
        // stable data directories.
        let result = ReleaseChannel.channelFromBundleID("com.example.unknown")
        XCTAssertEqual(
            result, .debug,
            "Unknown bundle id must fall back to .debug, not .stable"
        )
    }

    func test_emptyBundleID_returnsDebug() {
        let result = ReleaseChannel.channelFromBundleID("")
        XCTAssertEqual(
            result, .debug,
            "Empty bundle id (missing Bundle.main.bundleIdentifier in test host) must fall back to .debug"
        )
    }

    // MARK: - Inverse round-trip: channelFromBundleID(channel.bundleID) == channel

    func test_roundTrip_stable() {
        let ch = ReleaseChannel.stable
        XCTAssertEqual(
            ReleaseChannel.channelFromBundleID(ch.bundleID), ch,
            "channelFromBundleID(channel.bundleID) must be identity for .stable"
        )
    }

    func test_roundTrip_canary() {
        let ch = ReleaseChannel.canary
        XCTAssertEqual(
            ReleaseChannel.channelFromBundleID(ch.bundleID), ch,
            "channelFromBundleID(channel.bundleID) must be identity for .canary"
        )
    }

    func test_roundTrip_debug() {
        let ch = ReleaseChannel.debug
        XCTAssertEqual(
            ReleaseChannel.channelFromBundleID(ch.bundleID), ch,
            "channelFromBundleID(channel.bundleID) must be identity for .debug"
        )
    }
}
