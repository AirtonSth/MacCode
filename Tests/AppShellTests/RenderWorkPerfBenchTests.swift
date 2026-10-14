import XCTest
import AppKit
import SwiftUI
import Combine
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

    // MARK: - Shell host sizing passes

    private final class CountingHost<Root: View>: NSHostingView<Root> {
        var intrinsicCalls = 0
        override var intrinsicContentSize: NSSize {
            intrinsicCalls += 1
            return super.intrinsicContentSize
        }
    }

    private func makeContext() throws -> (AppContext, AppCommandRouter) {
        let dir = NSTemporaryDirectory() + "RC2RenderBench-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    /// Mount `host` the way MainWindowController.attachShellHost does (pinned to
    /// all four edges of the workspace content view) and drive `passes` VM
    /// publishes through SwiftUI + Auto Layout.
    private func driveShellHost<Root: View>(
        _ name: String,
        host: CountingHost<Root>,
        publish: () -> Void,
        passes: Int = 100
    ) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView()
        window.contentView = content
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        host.intrinsicCalls = 0
        bench(name) {
            for _ in 0..<passes {
                publish()
                RunLoop.main.run(until: Date())
                content.layoutSubtreeIfNeeded()
            }
        }
        print("PERF_COUNT name=\(name).intrinsicContentSizeCalls value=\(host.intrinsicCalls)")
        host.removeFromSuperview()
        window.close()
    }

    private func scheduledTasksHost(_ options: NSHostingSizingOptions) throws {
        let (ctx, router) = try makeContext()
        let vm = ScheduledTasksViewModel(context: ctx, router: router, loadImmediately: false)
        let host = CountingHost(rootView: ScheduledTasksRootView(vm: vm))
        host.sizingOptions = options
        print("PERF_SIZE name=shell.scheduledTasks.\(options.rawValue) intrinsic=\(host.intrinsicContentSize) fitting=\(host.fittingSize)")
        driveShellHost("shell.scheduledTasks.100publishes.options\(options.rawValue)", host: host) {
            vm.objectWillChange.send()
        }
    }

    private func activeThreadsHost(_ options: NSHostingSizingOptions) throws {
        let (ctx, router) = try makeContext()
        let vm = ActiveThreadsViewModel(context: ctx, router: router, loadImmediately: false)
        let host = CountingHost(rootView: ActiveThreadsRootView(vm: vm))
        host.sizingOptions = options
        print("PERF_SIZE name=shell.activeThreads.\(options.rawValue) intrinsic=\(host.intrinsicContentSize) fitting=\(host.fittingSize)")
        driveShellHost("shell.activeThreads.100publishes.options\(options.rawValue)", host: host) {
            vm.objectWillChange.send()
        }
    }

    func test_bench_shellHost_a_scheduledTasksStandard() throws { try scheduledTasksHost(.standardBounds) }
    func test_bench_shellHost_b_scheduledTasksMinSize() throws { try scheduledTasksHost([.minSize]) }
    func test_bench_shellHost_c_scheduledTasksStandardAgain() throws { try scheduledTasksHost(.standardBounds) }
    func test_bench_shellHost_d_activeThreadsStandard() throws { try activeThreadsHost(.standardBounds) }
    func test_bench_shellHost_e_activeThreadsMinSize() throws { try activeThreadsHost([.minSize]) }
    func test_bench_shellHost_f_activeThreadsNone() throws { try activeThreadsHost([]) }
    func test_bench_shellHost_g_activeThreadsStandardAgain() throws { try activeThreadsHost(.standardBounds) }
}
