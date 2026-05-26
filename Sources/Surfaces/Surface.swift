import Foundation
import AppKit
import CoreModel

@MainActor
public protocol Surface: AnyObject {
    var descriptor: SurfaceDescriptor { get }
    var view: NSView { get }
    func focus()
    func unfocus()
    func didBecomeVisible()
    func didBecomeHidden()
    func close()
    func sendText(_ text: String)
    func readText() -> String
    func snapshot() -> [String: String]
}

public extension Surface {
    /// A3: surface has work in flight (agent run, etc.) → spinner on tab.
    var isBusy: Bool { false }
    func didBecomeVisible() {}
    func didBecomeHidden() {}
}

@MainActor
public final class SurfaceRegistry {
    public static let shared = SurfaceRegistry()
    private var surfaces: [SurfaceID: Surface] = [:]
    private var visibleSurfaceIDs = Set<SurfaceID>()

    public func register(_ s: Surface) { surfaces[s.descriptor.id] = s }
    public func unregister(_ id: SurfaceID) {
        surfaces.removeValue(forKey: id)
        visibleSurfaceIDs.remove(id)
    }
    public func surface(_ id: SurfaceID) -> Surface? { surfaces[id] }
    public func all() -> [Surface] { Array(surfaces.values) }
    public func isVisible(_ id: SurfaceID) -> Bool { visibleSurfaceIDs.contains(id) }

    public func setVisibleSurfaceIDs(_ ids: Set<SurfaceID>) {
        guard ids != visibleSurfaceIDs else { return }
        let hidden = visibleSurfaceIDs.subtracting(ids)
        let shown = ids.subtracting(visibleSurfaceIDs)
        visibleSurfaceIDs = ids
        for id in hidden { surfaces[id]?.didBecomeHidden() }
        for id in shown { surfaces[id]?.didBecomeVisible() }
    }
}
