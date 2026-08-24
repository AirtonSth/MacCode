import Foundation
import XCTest
@testable import Surfaces

/// Opt-in qualification benchmark for the user-visible pause after typing in
/// Diff Find. The fixture is fixed at 10 MiB / 250,000 lines so before/after
/// samples exercise the same bytes, line count, query length, and hardware.
@MainActor
final class DiffPanelFindPerformanceTests: XCTestCase {
    func test_benchmarkTenMiBDiffFindSubmissionAndReadyWall() async throws {
        guard ProcessInfo.processInfo.environment["RC2_DIFF_FIND_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RC2_DIFF_FIND_BENCHMARK=1 to run the Diff Find qualification benchmark.")
        }

        let fixture = Self.makeFixture()
        XCTAssertEqual(fixture.utf8.count, 10 * 1024 * 1024)
        XCTAssertEqual(fixture.utf8.lazy.filter { $0 == 0x0A }.count, 250_000)

        let vm = DiffPanelViewModel(cwd: "/tmp", settings: nil, asyncLoad: false)
        vm.rawDiff = fixture
        let renderDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while vm.styledDiff.characters.isEmpty, ContinuousClock.now < renderDeadline {
            await Task.yield()
        }
        XCTAssertFalse(vm.styledDiff.characters.isEmpty, "render-cache warmup must finish before find timing")

        let warmupCount = 2
        let measuredCount = 5
        var submissionMS: [Double] = []
        var readyWallMS: [Double] = []

        for sample in -warmupCount..<measuredCount {
            vm.findQuery = ""
            let query = sample.isMultiple(of: 2) ? "needle00" : "needle01"
            XCTAssertEqual(query.utf8.count, 8)

            let start = ContinuousClock.now
            vm.findQuery = query
            let submitted = ContinuousClock.now
            let readyDeadline = start.advanced(by: .seconds(20))
            while vm.findMatchCount == 0, ContinuousClock.now < readyDeadline {
                await Task.yield()
            }
            let ready = ContinuousClock.now
            XCTAssertGreaterThan(vm.findMatchCount, 0, "the fixed fixture must produce matches")

            let submit = Self.milliseconds(start.duration(to: submitted))
            let wall = Self.milliseconds(start.duration(to: ready))
            if sample >= 0 {
                submissionMS.append(submit)
                readyWallMS.append(wall)
                print("DIFF_FIND_SAMPLE sample=\(sample) bytes=\(fixture.utf8.count) lines=250000 query_chars=8 main_actor_stall_ms=\(String(format: "%.3f", submit)) ready_wall_ms=\(String(format: "%.3f", wall)) matches=\(vm.findMatchCount)")
            }
        }

        print("DIFF_FIND_BENCHMARK warmups=\(warmupCount) n=\(measuredCount) bytes=\(fixture.utf8.count) lines=250000 query_chars=8 main_actor_stall_median_ms=\(String(format: "%.3f", Self.median(submissionMS))) ready_wall_median_ms=\(String(format: "%.3f", Self.median(readyWallMS)))")

        var eagerRenderMS: [Double] = []
        var cachedLookupMS: [Double] = []
        var checksum = 0
        for sample in -warmupCount..<measuredCount {
            let eagerStart = ContinuousClock.now
            let legacyLines = fixture.components(separatedBy: "\n")
            let legacySegments = DiffPanelViewModel.buildDiffSegments(fixture)
            checksum &+= legacyLines.count &+ legacySegments.count
            let eagerEnd = ContinuousClock.now

            let cachedStart = ContinuousClock.now
            checksum &+= vm.renderedDiffSegments.count
            let cachedEnd = ContinuousClock.now

            if sample >= 0 {
                eagerRenderMS.append(Self.milliseconds(eagerStart.duration(to: eagerEnd)))
                cachedLookupMS.append(Self.milliseconds(cachedStart.duration(to: cachedEnd)))
            }
        }
        XCTAssertGreaterThan(checksum, 0)
        XCTAssertLessThan(vm.renderedDiffSegments.count, 250_000,
                          "the cached row model must represent only the capped preview")
        print("DIFF_FIND_RENDER_BENCHMARK warmups=\(warmupCount) n=\(measuredCount) bytes=\(fixture.utf8.count) lines=250000 legacy_eager_main_actor_median_ms=\(String(format: "%.3f", Self.median(eagerRenderMS))) cached_descriptor_lookup_median_ms=\(String(format: "%.3f", Self.median(cachedLookupMS))) cached_lines=\(vm.renderedDiffSegments.count)")
    }

    private static func makeFixture() -> String {
        let targetBytes = 10 * 1024 * 1024
        let lineCount = 250_000
        let shortLineBytes = targetBytes / lineCount
        let longLineCount = targetBytes % lineCount
        var data = Data()
        data.reserveCapacity(targetBytes)

        for line in 0..<lineCount {
            let lineBytes = shortLineBytes + (line < longLineCount ? 1 : 0)
            let needle = line.isMultiple(of: 2) ? "needle00" : "needle01"
            let prefix = "+\(needle) \(String(format: "%06d", line)) "
            data.append(contentsOf: prefix.utf8)
            data.append(contentsOf: repeatElement(UInt8(ascii: "x"), count: lineBytes - prefix.utf8.count - 1))
            data.append(UInt8(ascii: "\n"))
        }

        return String(decoding: data, as: UTF8.self)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
