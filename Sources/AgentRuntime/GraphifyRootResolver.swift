import Foundation
import CoreModel

/// Classifies workspaces and resolves Graphify working-set roots.
/// Never returns a multi-repo parent container as a graph root.
public struct GraphifyRootResolver: Sendable {
    public var pinnedRoots: [String]
    public var stickyLastTouchedRoot: String?

    public init(pinnedRoots: [String] = [], stickyLastTouchedRoot: String? = nil) {
        self.pinnedRoots = pinnedRoots
        self.stickyLastTouchedRoot = stickyLastTouchedRoot
    }

    public func classify(workspaceCwd: String) -> GraphifyWorkspaceKind {
        let cwd = URL(fileURLWithPath: workspaceCwd).standardizedFileURL.path
        if let id = GraphifyGitProbe.identity(at: cwd) {
            return .singleRepo(id.checkout)
        }
        let children = GraphifyGitProbe.discoverChildRepos(containerCwd: cwd)
        if children.isEmpty {
            return .plainFolder(cwd)
        }
        if children.count == 1 {
            return .singleRepo(children[0])
        }
        return .multiRepoContainer(children: children)
    }

    public func resolve(
        threadId: UUID? = nil,
        threadCwd: String?,
        worktreePath: String?,
        workspaceCwd: String,
        attachmentPaths: [String] = []
    ) -> GraphifyThreadWorkingSet {
        let kind = classify(workspaceCwd: workspaceCwd)
        switch kind {
        case .singleRepo(let checkout):
            let binding = GraphifyRootBinding(
                checkout: checkout,
                status: .missing,
                reason: "single_repo"
            )
            return GraphifyThreadWorkingSet(
                threadId: threadId,
                workspaceKind: "singleRepo",
                roots: [binding],
                ambiguous: false
            )

        case .plainFolder(let path):
            // Plain non-git folder: no graphify root by default (fail-open empty).
            _ = path
            return GraphifyThreadWorkingSet(
                threadId: threadId,
                workspaceKind: "plainFolder",
                roots: [],
                ambiguous: false
            )

        case .multiRepoContainer(let children):
            var byKey: [GraphifyRepoKey: GraphifyRootBinding] = [:]

            func add(_ path: String?, reason: String) {
                guard let path, !path.isEmpty else { return }
                guard let id = GraphifyGitProbe.identity(at: path) else { return }
                // Only accept identities that match a discovered product child
                // OR resolve under the container (worktrees of those repos).
                let container = URL(fileURLWithPath: workspaceCwd).standardizedFileURL.path
                let top = id.checkout.displayRoot
                let underContainer = top.hasPrefix(container + "/") || top == container
                let matchesChild = children.contains { $0.key == id.checkout.key }
                guard underContainer || matchesChild else { return }
                // Never treat the multi-repo parent itself as a root.
                if top == container { return }
                if byKey[id.checkout.key] == nil {
                    byKey[id.checkout.key] = GraphifyRootBinding(
                        checkout: id.checkout,
                        status: .missing,
                        reason: reason
                    )
                }
            }

            add(worktreePath, reason: "worktree")
            add(threadCwd, reason: "thread_cwd")
            for path in attachmentPaths {
                add(path, reason: "attachment")
            }
            for pin in pinnedRoots {
                add(pin, reason: "pinned")
            }
            if byKey.isEmpty, let sticky = stickyLastTouchedRoot {
                add(sticky, reason: "sticky_pin")
            }

            let roots = byKey.values.sorted { $0.checkout.displayRoot < $1.checkout.displayRoot }
            return GraphifyThreadWorkingSet(
                threadId: threadId,
                workspaceKind: "multiRepoContainer",
                roots: roots,
                ambiguous: roots.isEmpty
            )
        }
    }
}
