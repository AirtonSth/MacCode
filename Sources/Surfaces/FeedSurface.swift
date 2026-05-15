import Foundation
import AppKit
import SwiftUI
import Combine
import CoreModel

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
            HStack {
                Text("Feed").font(.headline)
                Spacer()
                TextField("filter", text: $vm.filter).frame(maxWidth: 140)
            }.padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(vm.filtered) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text("#\(item.id)").font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                                Text(item.kind).font(.caption.bold()).foregroundColor(kindColor(item.kind))
                                Spacer()
                                Text(item.ts, style: .time).font(.caption2).foregroundColor(.secondary)
                            }
                            if !item.title.isEmpty {
                                Text(item.title).font(.caption).lineLimit(2)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(4)
                    }
                }.padding(8)
            }
        }
    }

    private func kindColor(_ k: String) -> Color {
        if k.hasPrefix("notification") { return .orange }
        if k.hasPrefix("workspace") { return .blue }
        if k.hasPrefix("surface") { return .green }
        if k.hasPrefix("window") { return .purple }
        return .primary
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
