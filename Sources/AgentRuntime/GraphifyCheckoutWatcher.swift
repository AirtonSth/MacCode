import Foundation
import CoreServices

/// FSEvents watcher for a single checkout root. Marks dirty on source-like changes.
/// Never watches multi-repo parents — only the resolved product checkout.
/// Ignores noise under `.git`, `node_modules`, `graphify-out`, and `GRAPHIFY_OUT`.
public final class GraphifyCheckoutWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable () -> Void

    private let path: String
    private let handler: Handler
    /// Absolute paths/prefixes to ignore (e.g. ArtifactRoot when nested, graphify-out).
    private let ignoredPathPrefixes: [String]
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "io.remotecode.graphify.fsevents")

    public init(path: String, ignoredPathPrefixes: [String] = [], handler: @escaping Handler) {
        self.path = path
        self.ignoredPathPrefixes = ignoredPathPrefixes.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let paths = [path as CFString] as CFArray
            let flags = UInt(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
            )
            // 1.5s latency — batches event storms before callback.
            guard let created = FSEventStreamCreate(
                nil,
                { _, info, numEvents, eventPaths, _, _ in
                    guard let info else { return }
                    let watcher = Unmanaged<GraphifyCheckoutWatcher>.fromOpaque(info).takeUnretainedValue()
                    let count = Int(numEvents)
                    guard count > 0 else {
                        watcher.handler()
                        return
                    }
                    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                    if paths.isEmpty {
                        watcher.handler()
                        return
                    }
                    if paths.contains(where: { watcher.shouldNotify(for: $0) }) {
                        watcher.handler()
                    }
                },
                &context,
                paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.5,
                FSEventStreamCreateFlags(flags)
            ) else { return }
            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
        }
    }

    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// True when an FSEvent path is a real source change (not VCS/deps/graph output).
    func shouldNotify(for eventPath: String) -> Bool {
        let p = URL(fileURLWithPath: eventPath).standardizedFileURL.path
        let noiseDirNames: Set<String> = [
            ".git", "node_modules", "dist", ".next", "build", "vendor",
            "graphify-out", "__pycache__", ".venv", "coverage", ".turbo", ".cache"
        ]
        let parts = p.split(separator: "/").map(String.init)
        if parts.contains(where: { noiseDirNames.contains($0) }) {
            return false
        }
        for prefix in ignoredPathPrefixes {
            if p == prefix || p.hasPrefix(prefix + "/") {
                return false
            }
        }
        return true
    }
}
