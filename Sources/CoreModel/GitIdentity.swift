import Foundation

/// The host user's git author identity, given to guest commands and in-guest
/// agent runs so their commits carry the user's name and email.
public struct GitIdentity: Equatable, Sendable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}
