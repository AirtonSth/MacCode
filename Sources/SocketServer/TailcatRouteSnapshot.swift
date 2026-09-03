/// Effective Tailcat route reported by the bridge.
///
/// Encodes only the allowlisted cohort. Peer IP, hostname, and other
/// addressing material must never appear on this type.
public enum TailcatRouteSnapshot: String, Codable, Sendable, Equatable, CaseIterable {
    case direct
    case remoteCodeDERP
    case publicDERP
    case unknown
}
