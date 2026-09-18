import Foundation

/// Workspace intelligence ops: semantic search, repo map, encoder ranking,
/// transcript/session search and the analysis ops (project commands, branch
/// files, symbol references, test mapping, ownership, orphan files, call graph).
/// Every op reads the real workspace through the injected host seam.
enum LibrarianWorkspaceOps {
    // MARK: - Semantic search / repo map / encoder rank

    static func workspaceSemanticSearch(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let query = (request.question ?? request.pattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return missingArgument(request, reason: "missing_query", text: "workspace_semantic_search needs a question")
        }
        let root = env.root(for: request)
        let index = await env.index(for: root)
        let (hits, mode) = await index.search(query: query, topK: request.topK ?? 8)
        guard !hits.isEmpty else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "no workspace match for: \(query) (root \(root), mode \(mode))",
                envelope: .unavailable(op: request.id, reason: "no_workspace_match", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        let stats = await index.stats()
        var lines = ["workspace_semantic_search root=\(root) mode=\(mode) files=\(stats.files) query=\(query)"]
        for hit in hits {
            lines.append("\(hit.path):\(hit.startLine)-\(hit.endLine)\t\(String(format: "%.3f", hit.score))")
        }
        let text = lines.joined(separator: "\n")
        _ = store.put(text)
        return LibrarianHandlerOutput(status: .ok, text: text, originalForSavings: request.input)
    }

    static func repoMapBudget(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let root = env.root(for: request)
        let query = (request.question ?? request.pattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = max(200, request.budgetTokens ?? 2_000)
        let index = await env.index(for: root)
        let (entries, mode) = await index.repoMap(query: query, budgetTokens: budget)
        guard !entries.isEmpty else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "no repo map entries for root \(root)",
                envelope: .unavailable(op: request.id, reason: "no_repo_files", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        let map = entries.map { entry -> [String: Any] in
            [
                "path": entry.path,
                "score": (entry.score * 1000).rounded() / 1000,
                "lines": entry.lines,
                "symbols": entry.symbols
            ]
        }
        let text: String
        if let data = try? JSONSerialization.data(withJSONObject: ["root": root, "mode": mode, "budget_tokens": budget, "entries": map], options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            text = json
        } else {
            text = entries.map { "\($0.path) (\($0.lines) lines)" }.joined(separator: "\n")
        }
        _ = store.put(text)
        return LibrarianHandlerOutput(status: .ok, text: text, originalForSavings: request.input)
    }

    static func encoderRank(
        _ request: LibrarianRequest,
        resolved: ResolvedBox,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let query = (request.question ?? request.pattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return missingArgument(request, reason: "missing_query", text: "encoder_rank needs a question")
        }
        let path = request.paths.first ?? "input"
        let candidates = LibrarianChunker.chunks(path: path, text: resolved.text, window: 20, overlap: 4, maxChunks: 200)
        guard !candidates.isEmpty else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "no chunks to rank",
                envelope: .unavailable(op: request.id, reason: "no_chunks", handle: resolved.handle),
                stage: .verbatim,
                originalForSavings: resolved.original
            )
        }
        let index = await env.index(for: env.root(for: request))
        let (ranked, mode) = await index.rank(chunks: candidates, query: query, topK: request.topK ?? 8)
        let head = "encoder_rank mode=\(mode) chunks=\(candidates.count) query=\(query)"
        let body = ranked.map { hit in
            "\(hit.path):\(hit.startLine)-\(hit.endLine)\t\(String(format: "%.4f", hit.score))"
        }.joined(separator: "\n")
        let text = body.isEmpty ? head : head + "\n" + body
        _ = store.put(text, handle: resolved.handle)
        return LibrarianHandlerOutput(status: .ok, text: text, handle: resolved.handle, originalForSavings: resolved.original)
    }

    // MARK: - Transcript / history

    static func transcriptSearch(
        _ request: LibrarianRequest,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        guard let transcript = env.transcript else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "transcript store unavailable",
                envelope: .unavailable(op: request.id, reason: "transcript_store_unavailable", handle: request.handle),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        let query = (request.question ?? request.pattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = request.topK ?? 10
        let threadID = request.threadID.isEmpty ? nil : request.threadID
        let scopeThread = request.scopeToThread ? threadID : nil
        let hits = query.isEmpty
            ? transcript.recent(limit, scopeThread)
            : transcript.search(query, limit, scopeThread)
        guard let hits else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "transcript store could not be read (database unavailable)",
                envelope: .unavailable(op: request.id, reason: "transcript_store_unreadable", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        guard !hits.isEmpty else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: query.isEmpty ? "no persisted turns" : "no transcript hits for: \(query)",
                envelope: .unavailable(op: request.id, reason: "no_transcript_hits", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        var lines = ["\(request.id) hits=\(hits.count)\(query.isEmpty ? "" : " query=\(query)")"]
        for hit in hits {
            let snippet = hit.snippet.replacingOccurrences(of: "\n", with: " ")
            lines.append("thread=\(hit.threadID) role=\(hit.role) at=\(hit.createdAt)\t\(snippet.prefix(220))")
        }
        return LibrarianHandlerOutput(status: .ok, text: lines.joined(separator: "\n"), originalForSavings: request.input)
    }

    // MARK: - Suggested capabilities

    static func projectCommands(
        _ request: LibrarianRequest,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let root = env.root(for: request)
        var commands: [(kind: String, source: String, command: String)] = []
        if let text = env.host.readText("\(root)/Package.swift", 256 * 1024) {
            let packageName = firstMatch(text, pattern: #"name:\s*"([^"]+)""#) ?? "package"
            commands.append(("build", "Package.swift", "swift build"))
            commands.append(("test", "Package.swift", "swift test"))
            if text.contains(".executableTarget") || text.contains(".executable(") {
                commands.append(("run", "Package.swift", "swift run \(packageName)"))
            }
        }
        if let data = env.host.readText("\(root)/package.json", 256 * 1024),
           let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
           let scripts = object["scripts"] as? [String: String] {
            for (name, body) in scripts.sorted(by: { $0.key < $1.key }) {
                let kind: String
                switch name {
                case "build", "compile": kind = "build"
                case "test", "tests": kind = "test"
                case "start", "dev", "serve": kind = "run"
                default: kind = "task"
                }
                commands.append((kind, "package.json", "npm run \(name)  # \(body.prefix(60))"))
            }
        }
        if let makefile = env.host.readText("\(root)/Makefile", 256 * 1024) {
            for line in makefile.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix("#") else { continue }
                let target = line[..<colon].trimmingCharacters(in: .whitespaces)
                guard !target.isEmpty, !target.contains("="), !target.contains("$"), !target.contains(" ") else { continue }
                let kind: String
                switch target {
                case "test", "tests", "check": kind = "test"
                case "build", "all": kind = "build"
                case "run", "start", "dev": kind = "run"
                default: kind = "task"
                }
                commands.append((kind, "Makefile", "make \(target)"))
            }
        }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: root) {
            let workspaces = entries.filter { $0.hasSuffix(".xcworkspace") }.sorted()
            let projects = entries.filter { $0.hasSuffix(".xcodeproj") }.sorted()
            let container = workspaces.first ?? projects.first
            if let container {
                let scheme = (workspaces.isEmpty ? container.replacingOccurrences(of: ".xcodeproj", with: "") : container.replacingOccurrences(of: ".xcworkspace", with: ""))
                let flag = container.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
                commands.append(("build", container, "xcodebuild \(flag) \(container) -scheme \(scheme) build"))
                commands.append(("test", container, "xcodebuild \(flag) \(container) -scheme \(scheme) test"))
            }
        }
        if let readme = env.host.readText("\(root)/README.md", 256 * 1024) {
            for line in readme.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("```") == false, trimmed.contains("`") else { continue }
                for candidate in codeSpans(trimmed) where looksLikeCommand(candidate) {
                    commands.append(("documented", "README.md", candidate))
                }
            }
        }
        var seen = Set<String>()
        let unique = commands.filter { seen.insert($0.command).inserted }
        guard !unique.isEmpty else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "no build/test/run entry points detected under \(root)",
                envelope: .unavailable(op: request.id, reason: "no_project_commands", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        let text = unique.map { "\($0.kind)\t\($0.source)\t\($0.command)" }.joined(separator: "\n")
        return LibrarianHandlerOutput(status: .ok, text: text, originalForSavings: request.input)
    }

    static func branchFiles(
        _ request: LibrarianRequest,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let root = env.root(for: request)
        let baseRef = (request.baseRef ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = baseRef.isEmpty ? "origin/production" : baseRef
        guard let git = env.host.resolveTool("git") else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "git unavailable",
                envelope: .unavailable(op: request.id, reason: "git_unavailable", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        let mergeBase = env.host.runProcess(LibrarianProcessInvocation(
            executable: git, arguments: ["merge-base", "HEAD", base], cwd: root, timeout: 20
        ))
        var diffArgs = ["diff", "--name-status"]
        let reference: String?
        if mergeBase.launched, mergeBase.exitCode == 0,
           !mergeBase.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reference = mergeBase.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            diffArgs.append(reference!)
        } else {
            reference = nil
            diffArgs.append("HEAD")
        }
        let diff = env.host.runProcess(LibrarianProcessInvocation(
            executable: git, arguments: diffArgs, cwd: root, timeout: 30
        ))
        guard diff.launched, diff.exitCode == 0 else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "git diff failed (base \(base))",
                envelope: .unavailable(op: request.id, reason: "git_diff_failed", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        let rows = diff.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let uncommitted = env.host.runProcess(LibrarianProcessInvocation(
            executable: git, arguments: ["status", "--porcelain", "--untracked-files=all"], cwd: root, timeout: 20
        ))
        let dirtyRows = uncommitted.stdout.split(separator: "\n").map { line -> String in
            let text = String(line)
            guard text.count > 3 else { return text }
            let kind = String(text.prefix(2)).trimmingCharacters(in: .whitespaces)
            let path = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return "\(kind.isEmpty ? "M" : kind)\t\(path)\tworking-tree"
        }.filter { !$0.isEmpty }
        var lines = [
            "branch=\(currentBranch(git: git, root: root, env: env)) base=\(base) changed=\(rows.count) uncommitted=\(dirtyRows.count)"
        ]
        lines.append(contentsOf: rows)
        lines.append(contentsOf: dirtyRows)
        return LibrarianHandlerOutput(status: .ok, text: lines.joined(separator: "\n"), originalForSavings: request.input)
    }

    static func symbolReferences(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let symbol = (request.symbol ?? request.pattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty else {
            return missingArgument(request, reason: "missing_symbol", text: "symbol_references needs a symbol")
        }
        let root = env.root(for: request)
        let index = await env.index(for: root)
        let paths = await index.allPaths()
        var perFile: [(path: String, count: Int, samples: [String])] = []
        for path in paths {
            guard let text = await index.text(for: path) else { continue }
            var samples: [String] = []
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains(symbol) else { continue }
                if samples.count < 3 { samples.append("\(offset + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(160))") }
            }
            if !samples.isEmpty {
                perFile.append((path, samples.count, samples))
            }
        }
        let sorted = perFile.sorted { $0.count == $1.count ? $0.path < $1.path : $0.count > $1.count }
        guard !sorted.isEmpty else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "no references to \(symbol) under \(root)",
                envelope: .unavailable(op: request.id, reason: "no_symbol_references", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        var lines = ["symbol=\(symbol) files=\(sorted.count) references>=\(sorted.reduce(0) { $0 + $1.count })"]
        for entry in sorted.prefix(20) {
            lines.append("\(entry.path)\t\(entry.count)")
            lines.append(contentsOf: entry.samples.map { "  \($0)" })
        }
        let text = lines.joined(separator: "\n")
        _ = store.put(text)
        return LibrarianHandlerOutput(status: .ok, text: text, originalForSavings: request.input)
    }

    static func testMapping(
        _ request: LibrarianRequest,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let root = env.root(for: request)
        let index = await env.index(for: root)
        let paths = await index.allPaths()
        let sourcePath = request.paths.first.map { absolute($0, root: root) }
        var mappings: [(String, [String])] = []
        if let sourcePath, let text = env.host.readText(sourcePath, LibrarianWorkspaceFiles.maxFileBytes) {
            let symbols = LibrarianSymbolExtractor.symbols(in: text)
            let sourceStem = testStem(for: sourcePath)
            let sourceName = ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
            var hits: [String] = []
            for path in paths where path != sourcePath && isTestPath(path) {
                guard let candidate = await index.text(for: path) else { continue }
                let sameName = sourceName.count >= 4 && (path.contains(sourceName) || candidate.contains(sourceName))
                let sameStem = sourceStem.count >= 4 && path.lowercased().contains(sourceStem)
                let sharedSymbol = symbols.contains(where: { $0.count >= 4 && candidate.contains($0) })
                if sameName || sameStem || sharedSymbol { hits.append(path) }
            }
            mappings.append((sourcePath, hits))
        } else {
            for path in paths where isTestPath(path) {
                guard let testText = await index.text(for: path) else { continue }
                let symbols = Set(LibrarianSymbolExtractor.symbols(in: testText))
                guard !symbols.isEmpty else { continue }
                var owners: [String] = []
                for source in paths where !isTestPath(source) {
                    guard let sourceText = await index.text(for: source) else { continue }
                    let sourceSymbols = Set(LibrarianSymbolExtractor.symbols(in: sourceText))
                    if !symbols.isDisjoint(with: sourceSymbols) { owners.append(source) }
                    if owners.count >= 3 { break }
                }
                if !owners.isEmpty { mappings.append((path, owners)) }
            }
        }
        let rows = mappings
            .map { "\($0.0) -> \($0.1.isEmpty ? "no test file references its symbols" : $0.1.joined(separator: ", "))" }
            .sorted()
        guard !rows.isEmpty else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "no test mapping found under \(root)",
                envelope: .unavailable(op: request.id, reason: "no_test_mapping", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        return LibrarianHandlerOutput(status: .ok, text: rows.joined(separator: "\n"), originalForSavings: request.input)
    }

    static func ownership(
        _ request: LibrarianRequest,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let root = env.root(for: request)
        let path = request.paths.first.map { absolute($0, root: root) } ?? root
        var lines: [String] = []
        for candidate in ["CODEOWNERS", ".github/CODEOWNERS", "docs/CODEOWNERS"] {
            guard let text = env.host.readText("\(root)/\(candidate)", 128 * 1024) else { continue }
            let relative = path.replacingOccurrences(of: root + "/", with: "")
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 2 else { continue }
                if glob(parts[0], matches: relative) {
                    lines.append("rule=\(parts[0]) owners=\(parts.dropFirst().joined(separator: " ")) source=\(candidate)")
                }
            }
        }
        if let git = env.host.resolveTool("git") {
            let relative = path.replacingOccurrences(of: root + "/", with: "")
            let log = env.host.runProcess(LibrarianProcessInvocation(
                executable: git,
                arguments: ["log", "-n", "5", "--format=%an <%ae> %ad", "--date=short", "--", relative],
                cwd: root,
                timeout: 20
            ))
            let authors = log.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !authors.isEmpty {
                lines.append("recent_authors=\(authors.joined(separator: " | ")) source=git-log")
            }
        }
        guard !lines.isEmpty else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "no ownership rule for \(path)",
                envelope: .unavailable(op: request.id, reason: "no_ownership", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        return LibrarianHandlerOutput(status: .ok, text: lines.joined(separator: "\n"), originalForSavings: request.input)
    }

    static func orphanFiles(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let root = env.root(for: request)
        let index = await env.index(for: root)
        let paths = await index.allPaths()
        var referenced = Set<String>()
        var names: [(path: String, name: String, stem: String)] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            guard !name.isEmpty, !stem.isEmpty else { continue }
            if isTestPath(path) { continue }
            names.append((path, name, stem))
        }
        // One read per file, then a single reference pass over the bounded index.
        for entry in names {
            for other in paths where other != entry.path {
                guard let text = await index.text(for: other) else { continue }
                if text.contains(entry.name) || (entry.stem.count >= 4 && text.contains(entry.stem)) {
                    referenced.insert(entry.path)
                    break
                }
            }
        }
        let candidates = names.map(\.path)
        let orphans = candidates.filter { !referenced.contains($0) }.sorted()
        // Entry points are never "orphans" even when nothing references them.
        let entryPointNames: Set<String> = ["main.swift", "main.ts", "main.js", "index.html", "Package.swift", "app.py", "App.swift"]
        let filtered = orphans.filter { !entryPointNames.contains(($0 as NSString).lastPathComponent) }
        guard !filtered.isEmpty else {
            return LibrarianHandlerOutput(
                status: .ok,
                text: "orphan_files root=\(root) candidates=\(candidates.count) orphans=0",
                originalForSavings: request.input
            )
        }
        let text = ["orphan_files root=\(root) candidates=\(candidates.count) orphans=\(filtered.count)"]
            + filtered.prefix(50).map { "unreferenced\t\($0)" }
        let joined = text.joined(separator: "\n")
        _ = store.put(joined)
        return LibrarianHandlerOutput(status: .ok, text: joined, originalForSavings: request.input)
    }

    static func callGraph(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let symbol = (request.symbol ?? request.pattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty else {
            return missingArgument(request, reason: "missing_symbol", text: "call_graph needs a symbol")
        }
        let root = env.root(for: request)
        let index = await env.index(for: root)
        let paths = await index.allPaths()
        var callers: [String] = []
        var definitions: [String] = []
        var callees = Set<String>()
        for path in paths {
            guard let text = await index.text(for: path) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (offset, line) in lines.enumerated() {
                if line.contains("func \(symbol)") || line.contains("def \(symbol)") || line.contains("function \(symbol)")
                    || line.contains("class \(symbol)") || line.contains("struct \(symbol)") {
                    definitions.append("\(path):\(offset + 1) \(line.trimmingCharacters(in: .whitespaces).prefix(140))")
                    continue
                }
                guard line.contains("\(symbol)(") else { continue }
                let owner = enclosingDeclaration(lines: lines, at: offset) ?? "(top level)"
                callers.append("\(path):\(offset + 1) \(owner) -> \(symbol)")
                for callee in callNames(in: line) where callee != symbol {
                    callees.insert(callee)
                }
            }
        }
        guard !callers.isEmpty || !definitions.isEmpty else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "no call graph for \(symbol) under \(root)",
                envelope: .unavailable(op: request.id, reason: "no_call_graph", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        var lines = ["call_graph symbol=\(symbol) definitions=\(definitions.count) callers=\(callers.count) callees=\(callees.count)"]
        lines.append(contentsOf: definitions.prefix(10).map { "defines\t\($0)" })
        lines.append(contentsOf: callers.prefix(20).map { "calls\t\($0)" })
        if !callees.isEmpty {
            lines.append("callees\t\(callees.sorted().prefix(20).joined(separator: ", "))")
        }
        let text = lines.joined(separator: "\n")
        _ = store.put(text)
        return LibrarianHandlerOutput(status: .ok, text: text, originalForSavings: request.input)
    }

    // MARK: - Helpers

    static func missingArgument(_ request: LibrarianRequest, reason: String, text: String) -> LibrarianHandlerOutput {
        LibrarianHandlerOutput(
            status: .unavailable,
            text: text,
            envelope: .unavailable(op: request.id, reason: reason, handle: request.handle),
            stage: .verbatim,
            originalForSavings: request.input
        )
    }

    static func absolute(_ path: String, root: String) -> String {
        path.hasPrefix("/") ? path : "\(root)/\(path)"
    }

    /// Test-file stem for naming-convention mapping: WidgetTests.swift → widget.
    static func testStem(for path: String) -> String {
        var stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        for suffix in ["tests", "test", "spec", "specs"] where stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
            break
        }
        return stem
    }

    static func isTestPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.contains("test") || lowered.contains("spec/") || lowered.contains("__tests__")
    }

    /// Nearest enclosing declaration that owns a call site. Brace depth is
    /// tracked so a call inside `publishWidget` is not attributed to a sibling
    /// function declared just above it. Lexical, not AST.
    static func enclosingDeclaration(lines: [String], at index: Int) -> String? {
        var depth = 0
        var cursor = index - 1
        while cursor >= 0 {
            let line = lines[cursor]
            if depth == 0, let name = declarationName(in: line) { return name }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            cursor -= 1
        }
        return nil
    }

    static func declarationName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for keyword in ["func ", "def ", "function ", "class ", "struct ", "enum ", "protocol ", "interface "] {
            guard let range = trimmed.range(of: keyword) else { continue }
            let rest = trimmed[range.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { return String(name) }
        }
        return nil
    }

    /// Every `name(` call in a line, excluding keywords.
    static func callNames(in line: String) -> [String] {
        var names: [String] = []
        var current = ""
        let keywords: Set<String> = ["if", "for", "while", "switch", "guard", "return", "catch", "func", "init", "self", "print"]
        for character in line {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
                continue
            }
            if character == "(", !current.isEmpty {
                if !keywords.contains(current), current.count >= 3 { names.append(current) }
            }
            current = ""
        }
        return names
    }

    static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    static func codeSpans(_ line: String) -> [String] {
        var spans: [String] = []
        var current = ""
        var inside = false
        for character in line {
            if character == "`" {
                if inside, !current.isEmpty { spans.append(current) }
                current = ""
                inside.toggle()
                continue
            }
            if inside { current.append(character) }
        }
        return spans
    }

    static func looksLikeCommand(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("=") else { return false }
        let first = trimmed.split(separator: " ").first.map(String.init) ?? ""
        let known: Set<String> = [
            "swift", "npm", "yarn", "pnpm", "bun", "make", "cargo", "go", "python3", "python",
            "pytest", "xcodebuild", "bazel", "gradle", "./gradlew", "docker", "bundle", "rake", "deno"
        ]
        return known.contains(first) || first.hasPrefix("./")
    }

    static func glob(_ pattern: String, matches path: String) -> Bool {
        let cleaned = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        if cleaned == "*" { return true }
        if cleaned.hasSuffix("/") { return path.hasPrefix(cleaned) }
        if cleaned.contains("*") {
            let parts = cleaned.split(separator: "*").map(String.init)
            var remainder = path
            for (index, part) in parts.enumerated() where !part.isEmpty {
                guard let range = remainder.range(of: part) else { return false }
                if index == 0, !cleaned.hasPrefix("*"), range.lowerBound != remainder.startIndex { return false }
                remainder = String(remainder[range.upperBound...])
            }
            if !cleaned.hasSuffix("*"), let last = parts.last, !last.isEmpty { return remainder.isEmpty || path.hasSuffix(last) }
            return true
        }
        return path == cleaned || path.hasSuffix("/" + cleaned)
    }

    private static func currentBranch(git: String, root: String, env: LibrarianOpEnvironment) -> String {
        let result = env.host.runProcess(LibrarianProcessInvocation(
            executable: git, arguments: ["rev-parse", "--abbrev-ref", "HEAD"], cwd: root, timeout: 10
        ))
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
