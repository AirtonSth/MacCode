import Foundation

/// Thrown when the AgentRuntime resource bundle cannot be located. Catchable by
/// design — the packaged app must degrade to a logged reconcile failure, never abort.
enum AgentRuntimeResourceBundleError: Error, Equatable {
    case missingResource(String)
}

/// Resolves the SwiftPM `RemoteCode_AgentRuntime` resource bundle inside a real
/// `.app` package **without** using SPM's generated `Bundle.module`.
///
/// WHY: SwiftPM emits an accessor that only looks at:
///   1. `Bundle.main.bundleURL/RemoteCode_AgentRuntime.bundle` (app root — wrong
///      for a standard Contents/Resources layout)
///   2. A **hardcoded** developer `.build/.../RemoteCode_AgentRuntime.bundle` path
/// When either misses, the accessor `fatalError`s on first touch — uncatchable.
/// Developer machines still work because (2) exists; customers crashed at launch
/// on v2.0.85–v2.0.87 when `AgentSkillInstaller.reconcileRemoteCodeOrchestrate`
/// touched it from `AppContext.init` (RemoteCode.app abort + scheduled-task
/// LaunchAgent crash-loop).
///
/// Pass criteria: find `Contents/Resources/RemoteCode_AgentRuntime.bundle` first,
/// then other shipped candidates (including the scheduled-task agent geometry,
/// whose executable lives directly under Contents/Resources), then SPM build
/// products for unit tests — never call `Bundle.module` (it can abort the process).
enum AgentRuntimeResourceBundle {
    static let bundleFileName = "RemoteCode_AgentRuntime.bundle"

    /// Returns the resource bundle or throws a catchable error.
    static func bundle(
        main: Bundle = .main,
        fileManager: FileManager = .default,
        includeSwiftPMFallback: Bool = true
    ) throws -> Bundle {
        if let found = locate(
            main: main,
            fileManager: fileManager,
            includeSwiftPMFallback: includeSwiftPMFallback
        ) {
            return found
        }
        throw AgentRuntimeResourceBundleError.missingResource(bundleFileName)
    }

    /// Ordered candidates: packaged app first, then SPM test/build layouts.
    static func candidateURLs(
        main: Bundle = .main,
        fileManager: FileManager = .default,
        includeSwiftPMFallback: Bool = true
    ) -> [URL] {
        var urls: [URL] = []
        let name = bundleFileName

        if let resources = main.resourceURL {
            urls.append(resources.appendingPathComponent(name))
        }

        let mainURL = main.bundleURL
        // Standard macOS app: …/RemoteCode.app/Contents/Resources/…
        urls.append(
            mainURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(name)
        )
        // SPM-generated layout (also mirrored by package-app.sh as belt-and-suspenders)
        urls.append(mainURL.appendingPathComponent(name))

        if let exeDir = main.executableURL?.deletingLastPathComponent() {
            // …/Contents/MacOS → sibling Resources
            urls.append(
                exeDir
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent(name)
            )
            // Next to the executable (swift test / .build product dirs, and the
            // scheduled-task agent whose executable sits in Contents/Resources)
            urls.append(exeDir.appendingPathComponent(name))
        }

        // Walk up from the executable looking for an SPM product bundle
        // (unit tests: xctest binary lives under .build/.../).
        if var dir = main.executableURL?.deletingLastPathComponent() {
            for _ in 0..<12 {
                urls.append(dir.appendingPathComponent(name))
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }

        // Unit-test / local `swift test`: Bundle.main is the XCTest runner, not
        // our .app. Discover the package `.build` tree from this source file and
        // the process working directory so reconcile keeps working in tests
        // without ever touching the fatalError-prone Bundle.module accessor.
        if includeSwiftPMFallback {
            urls.append(contentsOf: swiftPMProductCandidateURLs(fileManager: fileManager))
        }

        // De-dupe while preserving order.
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            if seen.contains(path) { return false }
            seen.insert(path)
            return true
        }
    }

    /// `.build/<triple>/{debug,release}/RemoteCode_AgentRuntime.bundle` candidates.
    static func swiftPMProductCandidateURLs(
        fileManager: FileManager = .default
    ) -> [URL] {
        let name = bundleFileName
        var roots: [URL] = []
        roots.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))

        // Sources/AgentRuntime/AgentRuntimeResourceBundle.swift → package root (3 up).
        let thisFile = URL(fileURLWithPath: #filePath)
        let packageRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        roots.append(packageRoot)
        roots.append(packageRoot.appendingPathComponent(".build", isDirectory: true))

        var urls: [URL] = []
        for root in roots {
            urls.append(root.appendingPathComponent(name))
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                urls.append(child.appendingPathComponent(name))
                for config in ["debug", "release"] {
                    urls.append(
                        child
                            .appendingPathComponent(config, isDirectory: true)
                            .appendingPathComponent(name)
                    )
                }
            }
        }
        return urls
    }

    static func locate(
        main: Bundle = .main,
        fileManager: FileManager = .default,
        includeSwiftPMFallback: Bool = true
    ) -> Bundle? {
        for url in candidateURLs(
            main: main,
            fileManager: fileManager,
            includeSwiftPMFallback: includeSwiftPMFallback
        ) {
            let path = url.standardizedFileURL.path
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            // Must look like our resource bundle (directory ending in .bundle).
            guard path.hasSuffix(bundleFileName) else { continue }
            if let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }
}
