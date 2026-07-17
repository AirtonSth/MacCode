import Foundation
import AppKit
import CoreModel

@MainActor
public protocol Surface: AnyObject {
    var descriptor: SurfaceDescriptor { get }
    var view: NSView { get }
    var isBusy: Bool { get }
    func focus()
    func unfocus()
    func didBecomeVisible()
    func didBecomeHidden()
    func close()
    func closeForApplicationTermination() -> SurfaceTerminationBarrier?
    func sendText(_ text: String)
    func readText() -> String
    func snapshot() -> [String: String]
}

public extension Surface {
    /// A3: surface has work in flight (agent run, etc.) → spinner on tab.
    var isBusy: Bool { false }
    func didBecomeVisible() {}
    func didBecomeHidden() {}
    func closeForApplicationTermination() -> SurfaceTerminationBarrier? {
        close()
        return nil
    }
}

/// Work started by a surface that application termination must not abandon.
/// Every group starts before this value is returned, so the app delegate can
/// launch all terminal dispositions first and then wait against one global
/// deadline instead of paying a full timeout once per tab.
public final class SurfaceTerminationBarrier: @unchecked Sendable {
    private let groups: [DispatchGroup]
    private let completionChecks: [@Sendable () -> Bool]
    private let applicationTerminationContinuations: [
        @MainActor @Sendable (DispatchTime) -> Bool
    ]
    private let applicationTerminationChildren: [SurfaceTerminationBarrier]

    init(
        groups: [DispatchGroup],
        completionChecks: [@Sendable () -> Bool] = [],
        applicationTerminationContinuations: [
            @MainActor @Sendable (DispatchTime) -> Bool
        ] = [],
        applicationTerminationChildren: [SurfaceTerminationBarrier] = []
    ) {
        self.groups = groups
        self.completionChecks = completionChecks
        self.applicationTerminationContinuations = applicationTerminationContinuations
        self.applicationTerminationChildren = applicationTerminationChildren
    }

    public convenience init(combining barriers: [SurfaceTerminationBarrier]) {
        self.init(
            groups: barriers.flatMap(\.groups),
            completionChecks: barriers.flatMap(\.completionChecks),
            applicationTerminationContinuations: barriers.flatMap(
                \.applicationTerminationContinuations
            ),
            applicationTerminationChildren: barriers
        )
    }

    public func wait(until deadline: DispatchTime) -> Bool {
        waitForGroups(until: deadline) && completionChecksSucceeded()
    }

    public func waitForGroups(until deadline: DispatchTime) -> Bool {
        for group in groups where group.wait(timeout: deadline) == .timedOut {
            return false
        }
        return true
    }

    public func completionChecksSucceeded() -> Bool {
        completionChecks.allSatisfy { $0() }
    }

    /// Application termination owns the MainActor synchronously. A terminal
    /// reader may finish publishing bytes while that actor waits, but history
    /// mutation must still occur on the actor before the durable writer is
    /// joined. Run those bounded continuations after initial groups publish and
    /// against the same global deadline; no nested AppKit run loop is required.
    @MainActor
    public func waitForApplicationTermination(until deadline: DispatchTime) -> Bool {
        if !applicationTerminationChildren.isEmpty {
            var completed = true
            for child in applicationTerminationChildren {
                completed = child.waitForApplicationTermination(until: deadline) && completed
            }
            return completed
        }
        guard waitForGroups(until: deadline) else { return false }
        for continuation in applicationTerminationContinuations {
            guard continuation(deadline) else { return false }
        }
        return completionChecksSucceeded()
    }

    /// Restart callers must not block AppKit while waiting for history and PTY
    /// disposition. The synchronous form remains for `applicationWillTerminate`,
    /// where AppKit requires the process to stay alive until the global deadline.
    public func waitAsync(until deadline: DispatchTime) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(returning: wait(until: deadline))
            }
        }
    }

    public func waitForGroupsAsync(until deadline: DispatchTime) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(returning: waitForGroups(until: deadline))
            }
        }
    }
}

@MainActor
public final class SurfaceRegistry {
    public static let shared = SurfaceRegistry()
    private var surfaces: [SurfaceID: Surface] = [:]
    private var visibleSurfaceIDs = Set<SurfaceID>()

    public func register(_ s: Surface) {
        surfaces[s.descriptor.id] = s
        if visibleSurfaceIDs.contains(s.descriptor.id) {
            s.didBecomeVisible()
        } else {
            s.didBecomeHidden()
        }
    }
    public func unregister(_ id: SurfaceID) {
        surfaces.removeValue(forKey: id)
        visibleSurfaceIDs.remove(id)
    }
    public func surface(_ id: SurfaceID) -> Surface? { surfaces[id] }
    public func all() -> [Surface] { Array(surfaces.values) }
    public func isVisible(_ id: SurfaceID) -> Bool { visibleSurfaceIDs.contains(id) }
    public func visibleSurfaceIDsSnapshot() -> Set<SurfaceID> { visibleSurfaceIDs }

    public func setVisibleSurfaceIDs(_ ids: Set<SurfaceID>) {
        guard ids != visibleSurfaceIDs else { return }
        let hidden = visibleSurfaceIDs.subtracting(ids)
        let shown = ids.subtracting(visibleSurfaceIDs)
        visibleSurfaceIDs = ids
        for id in hidden { surfaces[id]?.didBecomeHidden() }
        for id in shown { surfaces[id]?.didBecomeVisible() }
    }
}
