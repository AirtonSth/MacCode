import XCTest
import CoreModel
@testable import AppShell

/// Timing benches for SwiftUI work that repeats with no visible change.
/// Skipped unless `RC_PERF_RENDER_BENCH=1`, so normal runs stay fast. Each
/// bench warms once, then prints the median of `RC_PERF_SAMPLES` (default 7).
@MainActor
final class RenderWorkPerfBenchTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RC_PERF_RENDER_BENCH"] == "1" else {
            throw XCTSkip("RC_PERF_RENDER_BENCH is not set")
        }
    }

    private func bench(_ name: String, _ body: () throws -> Void) rethrows {
        let count = Int(ProcessInfo.processInfo.environment["RC_PERF_SAMPLES"] ?? "") ?? 7
        try body()
        var samples: [Double] = []
        for _ in 0..<count {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let median = samples.sorted()[samples.count / 2]
        let rendered = samples.map { String(format: "%.2f", $0) }.joined(separator: ",")
        print("PERF_BENCH name=\(name) median_ms=\(String(format: "%.2f", median)) samples_ms=[\(rendered)]")
    }

    // MARK: - Bots roster identity ink

    /// One roster pass = one `identityColor` per visible row. 20 rows, 10 passes.
    func test_bench_botsRosterIdentityHex() {
        let hues = ["pink", "coral", "amber", "green", "teal", "sky", "indigo", "violet"]
        let bots = (0..<20).map { i in
            (name: "Bench Bot \(i)", handle: "bench-\(i)",
             symbol: BotBlobatarSpec(hue: .named(hues[i % hues.count])).token)
        }
        var sink: UInt32 = 0
        bench("bots.rosterIdentityHex.20rows.x10") {
            for _ in 0..<10 {
                for bot in bots {
                    sink ^= BotsChrome.identityHex(name: bot.name, handle: bot.handle, symbol: bot.symbol)
                }
            }
        }
        XCTAssertNotEqual(sink, 0xFFFF_FFFF)
    }
}
