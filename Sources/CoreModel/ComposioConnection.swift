import Foundation

public struct ComposioCategory: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Public catalog metadata only; never contains provider credentials or auth links.
public struct ComposioToolkit: Codable, Equatable, Sendable, Identifiable {
    public var slug: String
    public var name: String
    public var description: String
    public var logoURL: URL?
    public var categories: [ComposioCategory]
    public var managedAuthSchemes: [String]
    public var id: String { slug }
    public var supportsManagedAuth: Bool { !managedAuthSchemes.isEmpty }
    public init(slug: String, name: String, description: String, logoURL: URL? = nil, categories: [ComposioCategory] = [], managedAuthSchemes: [String] = ["OAUTH2"]) {
        self.slug = slug; self.name = name; self.description = description; self.logoURL = logoURL
        self.categories = categories; self.managedAuthSchemes = managedAuthSchemes
    }
}

public struct ComposioCatalogPage: Equatable, Sendable {
    public var items: [ComposioToolkit]
    public var nextCursor: String?
    public init(items: [ComposioToolkit], nextCursor: String? = nil) { self.items = items; self.nextCursor = nextCursor }
}

public struct ComposioConnectionMetadata: Codable, Equatable, Sendable {
    public var toolkitSlug: String
    public var connectedAccountID: String
    public var userID: String
    public init(toolkitSlug: String, connectedAccountID: String, userID: String) {
        self.toolkitSlug = toolkitSlug; self.connectedAccountID = connectedAccountID; self.userID = userID
    }
}
