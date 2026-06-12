import XCTest
@testable import AppShell

// WHY: per-file progress resets confuse users about total time remaining.
// SidebarViewModel.aggregateProgress + formatDownloadETA power the aggregate display;
// these tests guard against divide-by-zero, 100% overshoot, and nil-eta edge cases.
final class TokenSaverAggregateProgressTests: XCTestCase {

    // MARK: - aggregateProgress

    func test_aggregateProgress_halfDone_returns50PercentAnd5sETA() {
        // 50 MB done of 100 MB at 10 MB/s -> 50%, (100-50)/10 = 5 s
        let (percent, eta) = SidebarViewModel.aggregateProgress(
            downloadedBytes: 50, totalBytes: 100, bytesPerSec: 10)
        XCTAssertEqual(percent, 50)
        XCTAssertEqual(eta, 5)
    }

    func test_aggregateProgress_fullyDone_returns100PercentAndZeroETA() {
        // downloadedBytes == totalBytes -> 100%, eta 0
        let (percent, eta) = SidebarViewModel.aggregateProgress(
            downloadedBytes: 100, totalBytes: 100, bytesPerSec: 10)
        XCTAssertEqual(percent, 100)
        XCTAssertEqual(eta, 0)
    }

    func test_aggregateProgress_zeroBytesPerSec_returnsNilETA() {
        // bytesPerSec == 0 -> no divide-by-zero, eta is nil
        let (percent, eta) = SidebarViewModel.aggregateProgress(
            downloadedBytes: 50, totalBytes: 100, bytesPerSec: 0)
        XCTAssertEqual(percent, 50)
        XCTAssertNil(eta, "ETA must be nil when speed is zero to avoid divide-by-zero")
    }

    func test_aggregateProgress_totalBytesZero_returns0PercentAndNilETA() {
        // guard: totalBytes == 0 -> undefined fraction -> 0%, nil eta
        let (percent, eta) = SidebarViewModel.aggregateProgress(
            downloadedBytes: 0, totalBytes: 0, bytesPerSec: 5)
        XCTAssertEqual(percent, 0)
        XCTAssertNil(eta)
    }

    func test_aggregateProgress_downloadedExceedsTotal_clampsTo100() {
        // Overshot (e.g. estimate was low) -> never exceed 100%
        let (percent, _) = SidebarViewModel.aggregateProgress(
            downloadedBytes: 120, totalBytes: 100, bytesPerSec: 10)
        XCTAssertEqual(percent, 100)
    }

    func test_aggregateProgress_smallRemainder_etaRoundsToZero() {
        // 1 byte left at 10 B/s -> eta rounds to 0 s (not negative)
        let (_, eta) = SidebarViewModel.aggregateProgress(
            downloadedBytes: 99, totalBytes: 100, bytesPerSec: 10)
        XCTAssertEqual(eta, 0)
    }

    func test_aggregateProgress_negativeBytesPerSec_returnsNilETA() {
        // defensive: negative speed (clock skew) must not produce nonsense
        let (_, eta) = SidebarViewModel.aggregateProgress(
            downloadedBytes: 50, totalBytes: 100, bytesPerSec: -5)
        XCTAssertNil(eta)
    }

    // MARK: - formatDownloadETA

    func test_formatDownloadETA_underOneMinute_showsSeconds() {
        XCTAssertEqual(SidebarViewModel.formatDownloadETA(45), "45s")
    }

    func test_formatDownloadETA_exactMinute_showsMinutesOnly() {
        XCTAssertEqual(SidebarViewModel.formatDownloadETA(120), "2m")
    }

    func test_formatDownloadETA_minutesAndSeconds_showsBoth() {
        XCTAssertEqual(SidebarViewModel.formatDownloadETA(90), "1m 30s")
    }

    func test_formatDownloadETA_exactHour_showsHoursOnly() {
        XCTAssertEqual(SidebarViewModel.formatDownloadETA(3600), "1h")
    }

    func test_formatDownloadETA_hoursAndMinutes_showsBoth() {
        XCTAssertEqual(SidebarViewModel.formatDownloadETA(3660), "1h 1m")
    }

    func test_formatDownloadETA_zero_returnsZeroS() {
        XCTAssertEqual(SidebarViewModel.formatDownloadETA(0), "0s")
    }
}
