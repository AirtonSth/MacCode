import Foundation
import AppKit
import SwiftUI
import CoreModel
import AgentRuntime

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
            fileList.frame(minWidth: 220, idealWidth: 260)
            diffBody.frame(minWidth: 400)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changes").font(.headline)
                Spacer()
                Button(action: vm.refresh) { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }.padding(8)
            Divider()
            if !vm.summary.isGitRepo {
                Spacer()
                Text("Not a git repo").foregroundColor(.secondary).padding()
                Spacer()
            } else if vm.summary.files.isEmpty {
                Spacer()
                Text("No changes").foregroundColor(.secondary).padding()
                Spacer()
            } else {
                List(selection: Binding(
                    get: { vm.selectedPath },
                    set: { vm.selectFile($0) }
                )) {
                    ForEach(vm.summary.files, id: \.path) { f in
                        HStack {
                            Text(statusGlyph(f.status))
                                .font(.caption.monospaced())
                                .foregroundColor(statusColor(f.status))
                                .frame(width: 16)
                            Text(f.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if !f.binary {
                                Text("+\(f.additions)").font(.caption2.monospacedDigit()).foregroundColor(.green)
                                Text("-\(f.deletions)").font(.caption2.monospacedDigit()).foregroundColor(.red)
                            }
                        }.tag(f.path as String?)
                    }
                }.listStyle(.sidebar)
            }
        }
    }

    private var diffBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle("wrap", isOn: $vm.wordWrap).controlSize(.small)
                Toggle("ignore-ws", isOn: $vm.ignoreWhitespace).controlSize(.small)
                Spacer()
                if let p = vm.selectedPath { Text(p).font(.caption.monospaced()).foregroundColor(.secondary) }
            }.padding(6)
            Divider()
            ScrollView([.vertical, vm.wordWrap ? .init() : .horizontal]) {
                Text(vm.rawDiff.isEmpty ? "Select a file." : displayDiff)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var displayDiff: AttributedString {
        var out = AttributedString()
        for line in vm.rawDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            var seg = AttributedString(String(line) + "\n")
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                seg.foregroundColor = .green
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                seg.foregroundColor = .red
            } else if line.hasPrefix("@@") {
                seg.foregroundColor = .cyan
            } else if line.hasPrefix("diff --git") || line.hasPrefix("+++") || line.hasPrefix("---") {
                seg.foregroundColor = .yellow
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
        case .added, .untracked: return .green
        case .deleted: return .red
        case .renamed, .copied: return .yellow
        default: return .secondary
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
