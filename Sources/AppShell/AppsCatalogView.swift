import SwiftUI
import AppKit
import CoreModel
import Persistence
import AgentRuntime
import DesignSystemKit
import Surfaces

/// The same app catalog is opened from the sidebar and Settings.
struct ConnectionsSettingsSection: View {
    let context: AppContext
    @StateObject private var model: AppsCatalogModel
    @State private var search = ""
    @State private var category: String?
    @State private var showSetup = false
    @State private var showManual = false
    @State private var pendingToolkit: ComposioToolkit?
    @State private var selectingToolkit: ComposioToolkit?
    @State private var editingAccess: AppConnection?
    init(context: AppContext) {
        self.context = context
        _model = StateObject(wrappedValue: AppsCatalogModel(context: context))
    }
    private var managed: [AppConnection] { model.connections.filter { $0.composio != nil } }
    private var visibleToolkits: [ComposioToolkit] {
        if model.configured { return model.toolkits }
        return model.toolkits.filter { toolkit in
            (category == nil || toolkit.categories.contains { $0.id == category }) &&
            (search.isEmpty || "\(toolkit.name) \(toolkit.description)".localizedCaseInsensitiveContains(search))
        }
    }
    private var categories: [ComposioCategory] {
        var seen = Set<String>()
        let available = model.configured ? model.categories : FeaturedApps.toolkits.flatMap(\.categories)
        return available.filter { seen.insert($0.id).inserted }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            header
            HStack(spacing: DS.Space.md) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.Palette.textSecondary)
                TextField("Search apps", text: $search).textFieldStyle(.plain).accessibilityIdentifier("connections.catalog.search")
            }.padding(DS.Space.md).dsPanel()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.sm) {
                    categoryButton("All", id: nil)
                    ForEach(categories) { item in categoryButton(item.name, id: item.id) }
                }
            }
            if let error = model.error {
                Text(error).font(DS.Font.body).foregroundStyle(DS.Palette.danger)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("connections.catalog.error")
            }
            if let error = model.catalogError {
                Text(error).font(DS.Font.caption).foregroundStyle(DS.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("connections.catalog.loadError")
            }
            if let notice = model.notice { Text(notice).font(DS.Font.caption).foregroundStyle(DS.Palette.success).fixedSize(horizontal: false, vertical: true) }
            if let slug = model.connecting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Finish connecting \(model.toolkits.first { $0.slug == slug }?.name ?? slug) in your browser. Waiting for account verification…")
                        .font(DS.Font.body).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DS.Space.sm)
                    Button("Cancel") { model.cancel() }
                }.padding(DS.Space.lg).dsPanel().accessibilityIdentifier("connections.catalog.authorizing")
            }
            if !managed.isEmpty {
                Text("Connected Accounts").font(DS.Font.bodyStrong)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: DS.Space.md)], spacing: DS.Space.md) {
                    ForEach(managed) { connection in accountCard(connection) }
                }
            }
            HStack {
                Text(model.configured ? "Apps" : "Popular Apps").font(DS.Font.bodyStrong)
                Spacer()
                if model.loadingCatalog { ProgressView().controlSize(.small).accessibilityLabel("Loading apps") }
            }
            if !model.configured {
                HStack(alignment: .top) {
                    Image(systemName: "puzzlepiece.extension")
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        Text("Set up your app connections once").font(DS.Font.bodyStrong)
                        Text("MacCode uses your Composio project to open secure sign-in for each app. After setup, choose an app and connect your account. Your model does not own the connection.")
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        Button("Set Up App Connections…") { showSetup = true }.buttonStyle(DSSecondaryButtonStyle())
                    }
                }.padding(DS.Space.lg).dsPanel().accessibilityIdentifier("connections.catalog.setupRequired")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: DS.Space.md)], spacing: DS.Space.md) {
                ForEach(visibleToolkits) { toolkit in toolkitCard(toolkit) }
            }
            if visibleToolkits.isEmpty && !model.loadingCatalog {
                Text("No apps match your search.").font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary).padding(.vertical, DS.Space.lg)
            }
            if model.nextCursor != nil {
                Button("Load More Apps") { Task { await model.catalog(search: search, category: category, more: true) } }
                    .disabled(model.loadingCatalog).buttonStyle(DSSecondaryButtonStyle())
            }
            Divider().overlay(DS.Palette.line)
            DisclosureGroup(isExpanded: $showManual) {
                ManualConnectionsSettingsSection(context: context)
                    .padding(.top, DS.Space.lg)
            } label: {
                Label("Advanced · Manual MCP Servers", systemImage: "server.rack").font(DS.Font.bodyStrong)
            }.accessibilityIdentifier("connections.manual.disclosure")
        }
        .foregroundStyle(DS.Palette.text)
        .task { await model.load(); await model.catalog(search: search, category: category) }
        .task(id: "\(search)|\(category ?? "")") {
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            await model.catalog(search: search, category: category)
        }
        .onChange(of: showManual) { _, open in if !open { Task { await model.reloadLocal() } } }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $showSetup, onDismiss: {
            if model.configured { selectingToolkit = pendingToolkit; pendingToolkit = nil; Task { await model.catalog(search: search, category: category) } }
        }) { ComposioProjectSetupView(model: model) }
        .sheet(item: $selectingToolkit) { toolkit in
            AppConnectionAccessSheet(context: context, title: "Connect \(toolkit.name)", initialAccess: ConnectionAccess(), actionTitle: "Connect") { access in
                model.connect(toolkit, access: access) { url in
                    let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                    guard opened else { throw ComposioError.network }
                }
                return true
            }
        }
        .sheet(item: $editingAccess) { connection in
            AppConnectionAccessSheet(context: context, title: "\(connection.name) Access", initialAccess: connection.access, actionTitle: "Save Access", errorMessage: { model.error }) { access in
                await model.saveAccess(connection, access: access)
            }
        }
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack { headerCopy; Spacer(); headerActions }
            VStack(alignment: .leading, spacing: DS.Space.md) { headerCopy; headerActions }
        }
    }
    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("Apps & Connections").font(DS.Font.title2)
            Text("Connect once. Choose which bots, workspaces and tasks can use each account.")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var headerActions: some View {
        HStack {
            Button { Task { await model.refresh(); await model.catalog(search: search, category: category) } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.operationBusy || model.connecting != nil).help("Refresh connections").accessibilityLabel("Refresh connections").accessibilityIdentifier("connections.catalog.refresh")
            Button("MCP Servers", systemImage: "server.rack") { showManual.toggle() }.accessibilityIdentifier("connections.catalog.manual")
            Menu {
                Button("Composio Project…") { pendingToolkit = nil; showSetup = true }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help("Connection settings").accessibilityLabel("Connection settings")
        }.buttonStyle(DSSecondaryButtonStyle())
    }
    private func categoryButton(_ name: String, id: String?) -> some View {
        Button(name) { category = id }
            .buttonStyle(DSSecondaryButtonStyle())
            .foregroundStyle(category == id ? DS.Palette.accent : DS.Palette.textSecondary)
            .accessibilityValue(category == id ? "Selected" : "")
    }
    private func toolkitCard(_ toolkit: ComposioToolkit) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                appIcon(toolkit.slug)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(toolkit.name).font(DS.Font.bodyStrong)
                    Text(toolkit.description).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            HStack {
                let count = managed.filter { $0.composio?.toolkitSlug == toolkit.slug && $0.status != .disconnected }.count
                Text(count > 0 ? "\(count) account\(count == 1 ? "" : "s")" : "")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.success)
                Spacer()
                Button(count > 0 ? "Add Account…" : "Connect") {
                    if model.configured { selectingToolkit = toolkit }
                    else { pendingToolkit = toolkit; showSetup = true }
                }.buttonStyle(DSSecondaryButtonStyle()).disabled(model.connecting != nil)
                    .accessibilityIdentifier("connections.catalog.connect.\(toolkit.slug)")
            }
        }.padding(DS.Space.lg).frame(maxWidth: .infinity, alignment: .leading).dsPanel()
    }
    private func accountCard(_ connection: AppConnection) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                appIcon(connection.composio?.toolkitSlug ?? "")
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(connection.name).font(DS.Font.bodyStrong)
                    if !connection.account.isEmpty { Text(connection.account).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
                }
                Spacer(minLength: 0)
                Text(connection.status == .tested ? "Connected" : connection.status.title)
                    .font(DS.Font.captionStrong).foregroundStyle(connection.status == .tested ? DS.Palette.success : DS.Palette.textSecondary)
            }
            Text(connection.access.summary).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            ViewThatFits(in: .horizontal) {
                HStack { accountActions(connection) }
                VStack(alignment: .leading) { accountActions(connection) }
            }
        }.padding(DS.Space.lg).frame(maxWidth: .infinity, alignment: .leading).dsPanel()
    }
    @ViewBuilder private func accountActions(_ connection: AppConnection) -> some View {
        Button("Access…") { editingAccess = connection }.disabled(connection.status == .disconnected)
        if connection.status == .disconnected {
            Button("Reconnect…") {
                let slug = connection.composio?.toolkitSlug ?? ""
                selectingToolkit = model.toolkits.first { $0.slug == slug } ?? ComposioToolkit(slug: slug, name: connection.name, description: "")
            }.disabled(model.connecting != nil)
        } else {
            Button("Add Account…") {
                let slug = connection.composio?.toolkitSlug ?? ""
                selectingToolkit = model.toolkits.first { $0.slug == slug } ?? ComposioToolkit(slug: slug, name: connection.name, description: "")
            }.disabled(model.connecting != nil)
            Button("Disconnect", role: .destructive) { Task { await model.disconnect(connection) } }.disabled(model.operationBusy)
        }
    }
    private func appIcon(_ slug: String) -> some View {
        Image(systemName: ["github": "chevron.left.forwardslash.chevron.right", "linear": "line.3.horizontal.decrease.circle", "gmail": "envelope", "slack": "number", "notion": "doc.text", "googlesheets": "tablecells", "googledrive": "folder", "googlecalendar": "calendar"][slug] ?? "puzzlepiece.extension")
            .font(DS.Font.title2).foregroundStyle(DS.Palette.accent).frame(width: 36, height: 36)
            .background(DS.Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .accessibilityHidden(true)
    }
}
