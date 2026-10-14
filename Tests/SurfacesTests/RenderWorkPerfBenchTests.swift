import XCTest
import AppKit
import SwiftUI
@testable import Surfaces
import CoreModel
@testable import Persistence
@testable import AgentRuntime

/// Timing benches for SwiftUI work that repeats with no visible change.
/// Skipped unless `RC_PERF_RENDER_BENCH=1`, so normal runs stay fast. Each
/// bench warms once, then prints the median of `RC_PERF_SAMPLES` (default 7).
@MainActor
final class SurfacesRenderWorkPerfBenchTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RC_PERF_RENDER_BENCH"] == "1" else {
            throw XCTSkip("RC_PERF_RENDER_BENCH is not set")
        }
    }

    private func samples(_ name: String, unit: String, _ body: () throws -> Double) rethrows {
        let count = Int(ProcessInfo.processInfo.environment["RC_PERF_SAMPLES"] ?? "") ?? 7
        _ = try body()
        var values: [Double] = []
        for _ in 0..<count { values.append(try body()) }
        let median = values.sorted()[values.count / 2]
        let rendered = values.map { String(format: "%.2f", $0) }.joined(separator: ",")
        print("PERF_BENCH name=\(name) median_\(unit)=\(String(format: "%.2f", median)) samples_\(unit)=[\(rendered)]")
    }

    private func elapsedMs(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    // MARK: - Agent App thread rail running set

    /// One rail body pass builds the running-id set over every filtered thread.
    /// A workspace rail is capped at `maxThreadsPerWorkspace` (20) on reload.
    func test_bench_threadRailRunningSet() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-rail-bench-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo, providers: [:])
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        for i in 0..<AgentThreadRepository.maxThreadsPerWorkspace {
            try threadRepo.upsert(AgentThread(workspaceId: workspaceID, title: "t\(i)", provider: .codex,
                                              model: "gpt-5.6-sol", status: .completed))
        }
        vm.reloadThreads()
        XCTAssertEqual(vm.filteredThreads.count, AgentThreadRepository.maxThreadsPerWorkspace)
        var sink = 0
        samples("agent.threadRail.runningSet.20threads.x100", unit: "ms") {
            elapsedMs {
                for _ in 0..<100 {
                    let runningThreadIds = railRunningThreadIds(vm)
                    sink &+= runningThreadIds.count
                }
            }
        }
        XCTAssertEqual(sink, 0)
    }

    /// Mirrors the expression the rail body evaluates (AgentAppSurface threadRail).
    /// Before the perf change it was a per-thread `isThreadStartingOrRunning` compactMap.
    private func railRunningThreadIds(_ vm: AgentAppViewModel) -> Set<AgentThreadID> {
        vm.startingOrRunningThreadIds(among: vm.filteredThreads)
    }

    // MARK: - Ultracode border while the window is not key

    /// Gradient frames the Ultracode border builds in 1 s while its composer
    /// sits in a window whose control state is `state`.
    private func borderFramesPerSecond(state: ControlActiveState, hidden: Bool = false) -> Int {
        let view = RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.black)
            .frame(width: 420, height: 90)
            .modifier(UltracodeBorder(active: true))
            .padding(24)
            .environment(\.controlActiveState, state)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 500, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFrontRegardless()
        host.isHidden = hidden
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let start = UltracodeBorder.frameCountForTesting
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let frames = UltracodeBorder.frameCountForTesting - start
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        return frames
    }

    func test_bench_ultracodeBorderFramesPerSecond() {
        for (label, state) in [("key", ControlActiveState.key), ("inactive", .inactive)] {
            samples("ultracode.border.framesPerSecond.\(label)", unit: "frames") {
                Double(borderFramesPerSecond(state: state))
            }
        }
        samples("ultracode.border.framesPerSecond.keyHiddenHost", unit: "frames") {
            Double(borderFramesPerSecond(state: .key, hidden: true))
        }
    }
}
