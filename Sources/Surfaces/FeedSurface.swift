import Foundation
import AppKit
import SwiftUI
import Combine
import CoreModel
import DesignSystemKit

/// Lightweight "feed" panel inspired by cmux's Feed (`docs/feed.md`).
/// Subscribes to the in-process event bus exposed through a callback
/// (kept dependency-free: SocketServer's EventBus is wired in
/// AppCommandRouter at construction time), and displays a reverse-
/// chronological log of agent / domain events.
@MainActor
public final class FeedPanelViewModel: ObservableObject {
    public struct Item: Identifiable, Equatable {
        public let id: Int64
        public let kind: String
        public let title: String
        public let ts: Date
    }

    @Published public private(set) var items: [Item] = []
    @Published public var filter: String = ""

    public func receive(seq: Int64, kind: String, title: String, ts: Double) {
        let item = Item(id: seq, kind: kind, title: title, ts: Date(timeIntervalSince1970: ts))
        items.insert(item, at: 0)
        if items.count > 200 { items = Array(items.prefix(200)) }
    }

    public var filtered: [Item] {
        guard !filter.isEmpty else { return items }
        let q = filter.lowercased()
        return items.filter { $0.kind.lowercased().contains(q) || $0.title.lowercased().contains(q) }
    }
}

public struct FeedPanelView: View {
    @ObservedObject var vm: FeedPanelViewModel
    public init(vm: FeedPanelViewModel) { self.vm = vm }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.md) {
                Text("FEED").font(DS.Font.caption2.weight(.semibold))
                    .tracking(0.6).foregroundColor(DS.Palette.textTertiary)
                Spacer()
                TextField("filter", text: $vm.filter)
                    .textFieldStyle(.plain)
                    .font(DS.Font.caption)
                    .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.xs)
                    .background(DS.Palette.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    .frame(maxWidth: 150)
            }
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
            .dsBar(edge: .bottom)
            if vm.filtered.isEmpty {
                DSEmptyState(icon: "dot.radiowaves.left.and.right",
                             title: "No activity",
                             subtitle: "Domain events (workspace, surface, notification, window) stream here as they happen.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(vm.filtered) { item in
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                HStack(spacing: DS.Space.sm) {
                                    Text("#\(item.id)")
                                        .font(DS.Font.caption2.monospacedDigit())
                                        .foregroundColor(DS.Palette.textTertiary)
                                    DSPill(item.kind, tone: kindTone(item.kind))
                                    Spacer()
                                    Text(item.ts, style: .time)
                                        .font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary)
                                }
                                if !item.title.isEmpty {
                                    Text(item.title).font(DS.Font.caption)
                                        .foregroundColor(DS.Palette.textSecondary).lineLimit(2)
                                }
                            }
                            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.md)
                            .background(DS.Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                        }
                    }.padding(DS.Space.md)
                }
                .background(DS.Palette.bg)
            }
        }
        .background(DS.Palette.surface)
    }

    private func kindTone(_ k: String) -> DSPill.Tone {
        if k.hasPrefix("notification") { return .warning }
        if k.hasPrefix("workspace") { return .accent }
        if k.hasPrefix("surface") { return .success }
        if k.hasPrefix("window") { return .accent }
        return .neutral
    }
}

@MainActor
public final class FeedPanelSurface: NSObject, Surface {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    public let viewModel = FeedPanelViewModel()
    public var subscriptionToken: AnyHashable?

    public init(workspaceID: WorkspaceID, title: String = "Feed") {
        self.descriptor = SurfaceDescriptor(type: .rightSidebarTool, title: title,
                                            iconName: "list.bullet.rectangle.portrait",
                                            metadata: ["workspace": workspaceID.value.uuidString, "tool": "feed"])
        let host = NSHostingView(rootView: FeedPanelView(vm: viewModel))
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        self.view = container
        super.init()
    }

    public func focus() { view.window?.makeFirstResponder(view) }
    public func unfocus() {}
    public func close() {}
    public func sendText(_ text: String) {}
    public func readText() -> String { viewModel.items.map(\.title).joined(separator: "\n") }
    public func snapshot() -> [String: String] { ["count": String(viewModel.items.count)] }
}
