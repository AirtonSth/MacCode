import Foundation
import AgentRuntime

/// Single-flight Agent App git header loads per workspace directory.
///
/// Every same-workspace Agent App tab reloads its branch chip and changed-files
/// header after each finished run, and each used to spawn its own set of git
/// processes. A request that arrives while a load runs cannot reuse that load:
/// it may have read the tree before the change the request is about. So it
/// joins one trailing load that starts when the current one ends, and every
/// owner receives only the newest result it asked for. A load that timed out
/// delivers nothing, so the header keeps what it showed.
@MainActor
final class AgentGitHeaderLoader {
    typealias Header = (branch: String?, summary: GitSummary)
    typealias Delivery = (Header) -> Void

    static let shared = AgentGitHeaderLoader(load: { AgentAppViewModel.loadGitHeader(cwd: $0) })

    private struct Pending {
        var running: [ObjectIdentifier: Delivery]
        var trailing: [ObjectIdentifier: Delivery] = [:]
    }

    private let loadHeader: @Sendable (String) -> Header?
    private var pending: [String: Pending] = [:]

    init(load: @escaping @Sendable (String) -> Header?) {
        loadHeader = load
    }

    func load(cwd: String, owner: AnyObject, deliver: @escaping Delivery) {
        let key = ObjectIdentifier(owner)
        if pending[cwd] != nil {
            pending[cwd]?.trailing[key] = deliver
            return
        }
        start(cwd: cwd, waiters: [key: deliver])
    }

    private func start(cwd: String, waiters: [ObjectIdentifier: Delivery]) {
        pending[cwd] = Pending(running: waiters)
        let loadHeader = self.loadHeader
        DispatchQueue.global().async {
            let header = loadHeader(cwd)
            DispatchQueue.main.async {
                self.finish(cwd: cwd, header: header)
            }
        }
    }

    private func finish(cwd: String, header: Header?) {
        guard let done = pending.removeValue(forKey: cwd) else { return }
        // An owner that asked again meanwhile only gets the newer load.
        if let header {
            for (key, deliver) in done.running where done.trailing[key] == nil {
                deliver(header)
            }
        }
        if !done.trailing.isEmpty {
            start(cwd: cwd, waiters: done.trailing)
        }
    }
}
