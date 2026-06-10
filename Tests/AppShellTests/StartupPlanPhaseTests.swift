import XCTest
@testable import AppShell

/// PERF (cold launch): the startup-plan classifier must keep the three heavy,
/// frame-irrelevant steps OFF the pre-frame critical path. If any of them slip
/// back into `.criticalSync`, the main thread stalls before the first frame and
/// the "Restoring workspaces..." spinner cannot animate -- the exact regression
/// this split exists to prevent. These assertions fail the moment a heavy step
/// is reclassified, encoding *why* the split matters rather than restating it.
final class StartupPlanPhaseTests: XCTestCase {
    func test_heavyRestoreWork_isDeferredPastFirstFrame() {
        // The PTY-spawn restore, the up-to-256 event-log decode, and the
        // process-scan orphan sweep are the costly steps that must not block
        // the first frame.
        XCTAssertEqual(
            StartupPlan.phase(for: .restorePTYSurfaces), .deferred,
            "spawning a PTY per restored terminal must not block the first frame"
        )
        XCTAssertEqual(
            StartupPlan.phase(for: .decodeEventLog), .deferred,
            "reading + JSON-decoding up to 256 event payloads must not block the first frame"
        )
        XCTAssertEqual(
            StartupPlan.phase(for: .orphanProviderSweep), .deferred,
            "the orphan provider process scan must not block the first frame"
        )
    }

    func test_deferredSet_isExactlyTheThreeHeavySteps() {
        // Guards against silently deferring frame-critical wiring (which would
        // show a window with no router/servers) or forgetting to defer a heavy
        // step.
        XCTAssertEqual(
            StartupPlan.steps(in: .deferred),
            [.orphanProviderSweep, .decodeEventLog, .restorePTYSurfaces],
            "exactly the three heavy steps -- no more, no fewer -- are deferred"
        )
    }

    func test_frameCriticalWiring_staysSynchronous() {
        // The window cannot paint a usable first frame without these wired up,
        // so they must remain pre-frame.
        for step in [StartupStep.bootstrapContext,
                     .buildRouterAndWindow,
                     .startSocketServer,
                     .showWindow] {
            XCTAssertEqual(
                StartupPlan.phase(for: step), .criticalSync,
                "\(step.rawValue) is required to paint a usable first frame and must stay synchronous"
            )
        }
    }
}
