import Foundation
import AppKit
import SwiftUI
import CoreModel
import AgentRuntime
import DesignSystemKit

@MainActor
public final class DiffPanelViewModel: ObservableObject {
    @Published public var cwd: String
    @Published public var summary: GitSummary
    @Published public var selectedPath: String?
    @Published public var rawDiff: String = ""
    @Published public var wordWrap: Bool = false
    @Published public var ignoreWhitespace: Bool = false

    public init(cwd: String) {
        self.cwd = cwd
        self.summary = GitDiff.summary(in: cwd)
    }

    public func refresh() {
        let cwd = self.cwd
        DispatchQueue.global().async { [weak self] in
            let s = GitDiff.summary(in: cwd)
            DispatchQueue.main.async { self?.summary = s }
        }
    }

    public func selectFile(_ path: String?) {
        selectedPath = path
        if let p = path {
            let cwd = self.cwd
            DispatchQueue.global().async { [weak self] in
                let d = GitDiff.diff(in: cwd, path: p)
                DispatchQueue.main.async { self?.rawDiff = d }
            }
        } else {
            rawDiff = ""
        }
    }
}

public struct DiffPanelView: View {
    @ObservedObject var vm: DiffPanelViewModel
    public init(vm: DiffPanelViewModel) { self.vm = vm }

    public var body: some View {
        HSplitView {
            fileList.frame(minWidth: 240, idealWidth: 280)
            diffBody.frame(minWidth: 420)
        }
        .background(DS.Palette.bg)
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeader("Changes", trailing: AnyView(
                DSIconButton("arrow.clockwise", help: "Refresh", action: vm.refresh)
            ))
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            if !vm.summary.isGitRepo {
                DSEmptyState(icon: "questionmark.folder", title: "Not a git repo",
                             subtitle: "Open a workspace backed by git to inspect changes.")
            } else if vm.summary.files.isEmpty {
                DSEmptyState(icon: "checkmark.seal", title: "No changes",
                             subtitle: "The working tree is clean.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                        ForEach(vm.summary.files, id: \.path) { f in
                            fileRow(f)
                        }
                    }.padding(DS.Space.sm)
                }
            }
        }
        .background(DS.Palette.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }

    @ViewBuilder
    private func fileRow(_ f: GitFileEntry) -> some View {
        let selected = vm.selectedPath == f.path
        Button { vm.selectFile(f.path) } label: {
            HStack(spacing: DS.Space.md) {
                Text(statusGlyph(f.status))
                    .font(DS.Font.monoSmall.weight(.bold))
                    .foregroundColor(statusColor(f.status)).frame(width: 14)
                Text(f.path).font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if !f.binary {
                    Text("+\(f.additions)").font(DS.Font.caption2.monospacedDigit()).foregroundColor(DS.Palette.success)
                    Text("−\(f.deletions)").font(DS.Font.caption2.monospacedDigit()).foregroundColor(DS.Palette.danger)
                }
            }
            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
            .background(selected ? DS.Palette.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var diffBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.lg) {
                Toggle("Wrap", isOn: $vm.wordWrap).controlSize(.small).font(DS.Font.caption)
                Toggle("Ignore WS", isOn: $vm.ignoreWhitespace).controlSize(.small).font(DS.Font.caption)
                Spacer()
                if let p = vm.selectedPath {
                    Text(p).font(DS.Font.monoSmall).foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
            .dsBar(edge: .bottom)
            ScrollView([.vertical, vm.wordWrap ? .init() : .horizontal]) {
                if vm.rawDiff.isEmpty {
                    Text("Select a file to view its diff.")
                        .font(DS.Font.bodyDense).foregroundColor(DS.Palette.textTertiary)
                        .padding(DS.Space.xl)
                } else {
                    Text(displayDiff)
                        .font(DS.Font.mono)
                        .textSelection(.enabled)
                        .padding(DS.Space.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(DS.Palette.bg)
        }
    }

    private var displayDiff: AttributedString {
        var out = AttributedString()
        for line in vm.rawDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            var seg = AttributedString(String(line) + "\n")
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                seg.foregroundColor = DS.Palette.success
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                seg.foregroundColor = DS.Palette.danger
            } else if line.hasPrefix("@@") {
                seg.foregroundColor = DS.Palette.accent
            } else if line.hasPrefix("diff --git") || line.hasPrefix("+++") || line.hasPrefix("---") {
                seg.foregroundColor = DS.Palette.warning
            } else {
                seg.foregroundColor = DS.Palette.textSecondary
            }
            out.append(seg)
        }
        return out
    }

    private func statusGlyph(_ s: GitFileStatus) -> String {
        switch s {
        case .added: return "A"; case .modified: return "M"; case .deleted: return "D"
        case .renamed: return "R"; case .copied: return "C"; case .untracked: return "?"
        case .unknown: return "•"
        }
    }
    private func statusColor(_ s: GitFileStatus) -> Color {
        switch s {
        case .added, .untracked: return DS.Palette.success
        case .deleted: return DS.Palette.danger
        case .renamed, .copied: return DS.Palette.warning
        default: return DS.Palette.textSecondary
        }
    }
}

@MainActor
public final class DiffPanelSurface: NSObject, Surface {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    public let viewModel: DiffPanelViewModel

    public init(workspaceID: WorkspaceID, cwd: String, title: String = "Diff") {
        self.descriptor = SurfaceDescriptor(type: .rightSidebarTool, title: title, iconName: "doc.text.magnifyingglass",
                                            metadata: ["workspace": workspaceID.value.uuidString, "cwd": cwd, "tool": "diff"])
        self.viewModel = DiffPanelViewModel(cwd: cwd)
        let host = NSHostingView(rootView: DiffPanelView(vm: viewModel))
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
    public func readText() -> String { viewModel.rawDiff }
    public func snapshot() -> [String: String] { ["selected": viewModel.selectedPath ?? ""] }
}
