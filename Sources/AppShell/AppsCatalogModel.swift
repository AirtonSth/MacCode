import Foundation
import SwiftUI
import CoreModel
import Persistence
import AgentRuntime

/// Presentation state only; service credentials and OAuth verification belong to the coordinator.
@MainActor
final class AppsCatalogModel: ObservableObject {
    @Published var configured = false
    @Published var loaded = false
    @Published var loadingCatalog = false
    @Published var toolkits = FeaturedApps.toolkits
    @Published var nextCursor: String?
    @Published var connections: [AppConnection] = []
    @Published var error: String?
    @Published var catalogError: String?
    @Published var categories: [ComposioCategory] = []
    @Published var notice: String?
    @Published var connecting: String?
    @Published var operationBusy = false
    let store: ConnectionStore
    let broker: ConnectionBroker
    let coordinator: ComposioOnboardingCoordinator
    private var catalogGeneration = 0
    private var connectionTask: Task<Void, Never>?

    init(context: AppContext) {
        store = ConnectionStore(db: context.db)
        broker = context.connectionBroker
        coordinator = ComposioOnboardingCoordinator(store: store, broker: broker)
    }
    init(store: ConnectionStore, broker: ConnectionBroker, coordinator: ComposioOnboardingCoordinator) {
        self.store = store; self.broker = broker; self.coordinator = coordinator
    }
    func load() async {
        do {
            configured = try await coordinator.isConfigured()
            await reloadLocal()
        } catch { self.error = error.localizedDescription }
        loaded = true
    }
    func reloadLocal() async {
        let store = store
        do { connections = try await Task.detached { try store.list() }.value }
        catch { self.error = ConnectionError.storage.description }
    }
    func catalog(search: String, category: String?, more: Bool = false) async {
        catalogGeneration += 1
        let generation = catalogGeneration
        guard configured else { toolkits = FeaturedApps.toolkits; nextCursor = nil; return }
        loadingCatalog = true
        defer { if generation == catalogGeneration { loadingCatalog = false } }
        let cursor = more ? nextCursor : nil
        do {
            let page = try await coordinator.catalog(search: search, category: category, cursor: cursor)
            guard generation == catalogGeneration, !Task.isCancelled else { return }
            if more {
                let existing = Set(toolkits.map(\.slug))
                toolkits += page.items.filter { !existing.contains($0.slug) }
            } else { toolkits = page.items }
            nextCursor = page.nextCursor
            var known = Set(categories.map(\.id))
            categories += page.items.flatMap(\.categories).filter { known.insert($0.id).inserted }
            catalogError = nil
        } catch {
            guard generation == catalogGeneration, !Task.isCancelled else { return }
            self.catalogError = error.localizedDescription
        }
    }
    func setup(key: String) async -> Bool {
        error = nil
        do { try await coordinator.setup(apiKey: key); configured = true; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func connect(_ toolkit: ComposioToolkit, access: ConnectionAccess, openURL: @escaping @Sendable (URL) async throws -> Void) {
        guard connecting == nil else { return }
        error = nil; notice = nil; connecting = toolkit.slug
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.connecting = nil; self.connectionTask = nil }
            do {
                _ = try await self.coordinator.connect(toolkit: toolkit, access: access, openURL: openURL)
                guard !Task.isCancelled else { return }
                self.notice = "\(toolkit.name) is connected. Access is limited to your selections."
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            await self.reloadLocal()
        }
    }
    func cancel() {
        connectionTask?.cancel()
        Task { await coordinator.cancel() }
    }
    func refresh() async {
        guard !operationBusy else { return }
        operationBusy = true; error = nil
        defer { operationBusy = false }
        do {
            if configured { _ = try await coordinator.refreshAccounts() }
            await reloadLocal()
        } catch { self.error = error.localizedDescription; await reloadLocal() }
    }
    func disconnect(_ connection: AppConnection) async {
        guard !operationBusy else { return }
        operationBusy = true; error = nil; notice = nil
        defer { operationBusy = false }
        do {
            if connection.composio != nil { try await coordinator.disconnect(connection.id) }
            else { try await broker.disconnect(connection.id) }
            notice = "\(connection.name) is disconnected."
        } catch { self.error = error.localizedDescription }
        await reloadLocal()
    }
    func saveAccess(_ connection: AppConnection, access: ConnectionAccess) async -> Bool {
        error = nil
        do {
            guard var current = try store.get(connection.id), current.revision == connection.revision,
                  current.status != .disconnected else { throw ConnectionError.stale }
            current.access = access
            // Access-only CAS: preserve verified account/transport state and never touch Keychain.
            try store.save(current, expectedRevision: connection.revision)
            await reloadLocal(); notice = "Access updated for \(connection.name)."; return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

/// A useful, searchable starting set before the user's project catalog is configured.
/// Connected badges always come from verified persisted accounts, never these entries.
enum FeaturedApps {
    static let development = ComposioCategory(id: "developer_tools", name: "Development")
    static let productivity = ComposioCategory(id: "productivity", name: "Productivity")
    static let communication = ComposioCategory(id: "communication", name: "Communication")
    static let toolkits: [ComposioToolkit] = [
        .init(slug: "github", name: "GitHub", description: "Repositories, issues and pull requests.", categories: [development]),
        .init(slug: "linear", name: "Linear", description: "Issues, projects and team planning.", categories: [development]),
        .init(slug: "gmail", name: "Gmail", description: "Email, labels and drafts.", categories: [communication]),
        .init(slug: "googlesheets", name: "Google Sheets", description: "Spreadsheets and structured data.", categories: [productivity]),
        .init(slug: "googledrive", name: "Google Drive", description: "Files, documents and shared folders.", categories: [productivity]),
        .init(slug: "googlecalendar", name: "Google Calendar", description: "Calendars, events and availability.", categories: [productivity]),
        .init(slug: "slack", name: "Slack", description: "Channels, messages and team conversations.", categories: [communication]),
        .init(slug: "notion", name: "Notion", description: "Pages, databases and workspace knowledge.", categories: [productivity]),
    ]
}
