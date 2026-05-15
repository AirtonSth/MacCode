import Foundation
import AppKit
import CoreModel

@MainActor
public protocol Surface: AnyObject {
    var descriptor: SurfaceDescriptor { get }
    var view: NSView { get }
    func focus()
    func unfocus()
    func close()
    func sendText(_ text: String)
    func readText() -> String
    func snapshot() -> [String: String]
}

@MainActor
public final class SurfaceRegistry {
    public static let shared = SurfaceRegistry()
    private var surfaces: [SurfaceID: Surface] = [:]

    public func register(_ s: Surface) { surfaces[s.descriptor.id] = s }
    public func unregister(_ id: SurfaceID) { surfaces.removeValue(forKey: id) }
    public func surface(_ id: SurfaceID) -> Surface? { surfaces[id] }
    public func all() -> [Surface] { Array(surfaces.values) }
}
