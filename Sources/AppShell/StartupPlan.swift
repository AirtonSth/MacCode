import Foundation

/// PERF (cold launch): classifies the work `applicationDidFinishLaunching`
/// performs into two phases so the heavy restore work runs AFTER the first
/// frame paints rather than blocking it.
///
/// `criticalSync` steps MUST complete before the window is shown (they wire up
/// the context/router/servers the UI and clients depend on). `deferred` steps
/// are expensive and have no impact on the first frame -- the orphan provider
/// sweep (process scan), the persisted event-log read + JSON decode of up to
/// 256 payloads, and reinstantiating restored surfaces (which spawns a PTY per
/// restored terminal). Deferring them lets the "Restoring workspaces..."
/// affordance animate instead of the main thread stalling.
///
/// This is a pure, side-effect-free classifier so the phase split can be
/// asserted in isolation without touching AppKit or the app delegate.
public enum StartupStep: String, CaseIterable, Sendable {
    case bootstrapContext
    case installLifecycleRecorder
    case wireEventBus
    case buildRouterAndWindow
    case startSocketServer
    case configureDirectAccess
    case installMainMenu
    case showWindow

    // Deferred (post-first-frame) work.
    case orphanProviderSweep
    case decodeEventLog
    case restorePTYSurfaces
}

public enum StartupPhase: String, Sendable {
    case criticalSync
    case deferred
}

public enum StartupPlan {
    /// The three expensive, frame-irrelevant steps that must run after the
    /// first frame paints.
    public static let deferredSteps: Set<StartupStep> = [
        .orphanProviderSweep,
        .decodeEventLog,
        .restorePTYSurfaces,
    ]

    public static func phase(for step: StartupStep) -> StartupPhase {
        deferredSteps.contains(step) ? .deferred : .criticalSync
    }

    public static func steps(in phase: StartupPhase) -> [StartupStep] {
        StartupStep.allCases.filter { self.phase(for: $0) == phase }
    }
}
