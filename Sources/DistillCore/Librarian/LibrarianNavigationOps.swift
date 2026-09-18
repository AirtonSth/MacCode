import Foundation

/// Code-navigation ops: real sourcekit-lsp queries, a native structural matcher,
/// the graphify CLI and a real changed-file notice.
enum LibrarianNavigationOps {
    private static let swiftExtensions: Set<String> = ["swift"]
    private static let languageIDs: [String: String] = [
        "swift": "swift", "ts": "typescript", "tsx": "typescriptreact", "js": "javascript",
        "jsx": "javascriptreact", "py": "python", "go": "go", "rs": "rust", "java": "java",
        "kt": "kotlin", "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "hpp": "cpp",
        "m": "objective-c", "mm": "objective-cpp", "json": "json", "yml": "yaml", "yaml": "yaml",
        "md": "markdown", "html": "html", "css": "css", "sh": "shellscript", "rb": "ruby"
    ]

    // MARK: - lsp_query

    static func lspQuery(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        guard let client = env.lsp else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "sourcekit_lsp_unavailable",
                text: "sourcekit-lsp is not installed on this host"
            )
        }
        let root = env.root(for: request)
        guard let file = targetFile(request, root: root, env: env) else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "missing_file",
                text: "lsp_query needs a path (workspace-relative) to query"
            )
        }
        guard let text = env.host.readText(file, LibrarianWorkspaceFiles.maxFileBytes) else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "file_unreadable",
                text: "cannot read \(file)"
            )
        }
        let operation = request.navigationOperation ?? defaultOperation(for: text, symbol: request.symbol ?? request.pattern)
        let symbol = (request.symbol ?? request.pattern ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let position = LSPTextPosition.locate(symbol: symbol, operation: operation, in: text)
        let languageID = languageIDs[(file as NSString).pathExtension.lowercased()] ?? "plaintext"
        let outcome = LibrarianLSPClient.query(
            client: client,
            root: root,
            file: file,
            text: text,
            languageID: languageID,
            operation: operation,
            position: position
        )
        guard outcome.launched else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "lsp_launch_failed",
                text: "sourcekit-lsp did not start"
            )
        }
        guard !outcome.items.isEmpty else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "lsp \(operation) found nothing for \(operation == "documentSymbol" ? file : symbol) (\(outcome.diagnostic))",
                envelope: .unavailable(op: request.id, reason: "lsp_no_result", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        var lines = ["lsp_query op=\(operation) file=\(file) results=\(outcome.items.count)"]
        lines.append(contentsOf: outcome.items.prefix(40).map { item in
            let relative = item.path.replacingOccurrences(of: root + "/", with: "")
            let detail = item.detail.isEmpty ? "" : " \(item.detail)"
            return "\(relative):\(item.line + 1):\(item.character + 1)\t\(item.kind)\(detail)"
        })
        let joined = lines.joined(separator: "\n")
        _ = store.put(joined)
        return LibrarianHandlerOutput(status: .ok, text: joined, originalForSavings: request.input)
    }

    private static func defaultOperation(for text: String, symbol: String?) -> String {
        guard let symbol, !symbol.isEmpty else { return "documentSymbol" }
        return text.contains(symbol) ? "definition" : "documentSymbol"
    }

    private static func targetFile(
        _ request: LibrarianRequest,
        root: String,
        env: LibrarianOpEnvironment
    ) -> String? {
        for candidate in request.paths {
            let absolute = LibrarianWorkspaceOps.absolute(candidate, root: root)
            if env.host.fileExists(absolute) { return absolute }
        }
        if let file = request.fileName, !file.isEmpty {
            let absolute = LibrarianWorkspaceOps.absolute(file, root: root)
            if env.host.fileExists(absolute) { return absolute }
        }
        return nil
    }

    // MARK: - ast_grep_query

    /// Native structural search. `$Name` matches one token (identifier, literal
    /// or punctuation-free atom) and captures it; every other token must match
    /// literally. Token-level on purpose: no AST dependency exists in this
    /// package, and the result says exactly which mode produced it.
    static func astGrepQuery(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let pattern = (request.pattern ?? request.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "missing_pattern",
                text: "ast_grep_query needs a pattern (use $X for one captured token)"
            )
        }
        let root = env.root(for: request)
        let index = await env.index(for: root)
        let paths: [String]
        if !request.paths.isEmpty {
            paths = request.paths.map { LibrarianWorkspaceOps.absolute($0, root: root) }.filter { env.host.fileExists($0) }
        } else {
            paths = await index.allPaths()
        }
        let matcher = LibrarianStructuralMatcher(pattern: pattern)
        var matches: [(path: String, line: Int, captures: [String], snippet: String)] = []
        for path in paths {
            guard let text = env.host.readText(path, LibrarianWorkspaceFiles.maxFileBytes) else { continue }
            for hit in matcher.matches(in: text) {
                matches.append((
                    LibrarianWorkspaceOps.absolute(path, root: root),
                    hit.line,
                    hit.captures,
                    hit.snippet
                ))
                if matches.count >= 200 { break }
            }
            if matches.count >= 200 { break }
        }
        guard !matches.isEmpty else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "ast_grep_query mode=native-token pattern=\(pattern) matches=0",
                envelope: .unavailable(op: request.id, reason: "no_structural_match", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        var lines = ["ast_grep_query mode=native-token pattern=\(pattern) matches=\(matches.count)"]
        for match in matches.prefix(60) {
            let relative = match.path.replacingOccurrences(of: root + "/", with: "")
            let captured = match.captures.isEmpty ? "" : " captures=\(match.captures.joined(separator: ","))"
            lines.append("\(relative):\(match.line + 1)\(captured)\t\(match.snippet)")
        }
        let joined = lines.joined(separator: "\n")
        _ = store.put(joined)
        return LibrarianHandlerOutput(status: .ok, text: joined, originalForSavings: request.input)
    }

    // MARK: - graphify_query

    static func graphifyQuery(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        guard let graph = env.graph else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "graphify_unavailable",
                text: "the graphify CLI is not installed on this host"
            )
        }
        let query = (request.question ?? request.pattern ?? request.input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "missing_query",
                text: "graphify_query needs a question"
            )
        }
        let root = env.root(for: request)
        let graphPath = resolveGraphPath(request: request, root: root, env: env)
        let subcommand = request.navigationOperation ?? "query"
        guard ["query", "path", "explain"].contains(subcommand) else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "unsupported_graph_command",
                text: "graphify_query supports query|path|explain"
            )
        }
        let result = graph.run([subcommand, query], graphPath)
        guard result.launched else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "graphify_launch_failed",
                text: "graphify did not start"
            )
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !output.isEmpty else {
            let reason = result.timedOut ? "graphify_timeout" : "graphify_failed"
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "graphify \(subcommand) unavailable (\(reason)): \(result.stderr.prefix(200))",
                envelope: .unavailable(op: request.id, reason: reason, handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        let bounded = String(output.prefix(20_000))
        _ = store.put(bounded)
        let header = "graphify_query op=\(subcommand) graph=\(graphPath ?? "auto") query=\(query)"
        return LibrarianHandlerOutput(status: .ok, text: "\(header)\n\(bounded)", originalForSavings: request.input)
    }

    static func resolveGraphPath(
        request: LibrarianRequest,
        root: String,
        env: LibrarianOpEnvironment
    ) -> String? {
        for candidate in request.paths where candidate.hasSuffix(".json") {
            let absolute = LibrarianWorkspaceOps.absolute(candidate, root: root)
            if env.host.fileExists(absolute) { return absolute }
        }
        if let fromEnv = env.processEnvironment["RC_GRAPHIFY_GRAPH_JSON"], !fromEnv.isEmpty, env.host.fileExists(fromEnv) {
            return fromEnv
        }
        for candidate in ["graphify-out/graph.json", ".graphify/graph.json"] {
            let absolute = "\(root)/\(candidate)"
            if env.host.fileExists(absolute) { return absolute }
        }
        return nil
    }

    // MARK: - workspace_change_notice

    static func workspaceChangeNotice(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let root = env.root(for: request)
        var rows: [(kind: String, path: String, detail: String)] = []
        var gitError: String?
        if let git = env.host.resolveTool("git") {
            let status = env.host.runProcess(LibrarianProcessInvocation(
                executable: git, arguments: ["status", "--porcelain", "--untracked-files=all"], cwd: root, timeout: 20
            ))
            if status.launched, status.exitCode == 0 {
                for line in status.stdout.split(separator: "\n") {
                    let text = String(line)
                    guard text.count > 3 else { continue }
                    let kind = String(text.prefix(2)).trimmingCharacters(in: .whitespaces)
                    let path = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    rows.append((kind.isEmpty ? "M" : kind, path, "working-tree"))
                }
            } else {
                gitError = "git status unavailable"
            }
            if let since = request.since, !since.isEmpty {
                let log = env.host.runProcess(LibrarianProcessInvocation(
                    executable: git,
                    arguments: ["log", "--since=\(since)", "--name-status", "--pretty=format:%h %ad %s", "--date=short"],
                    cwd: root,
                    timeout: 25
                ))
                if log.launched, log.exitCode == 0 {
                    for line in log.stdout.split(separator: "\n") {
                        let text = String(line)
                        let parts = text.split(separator: "\t", omittingEmptySubsequences: true).map(String.init)
                        guard parts.count >= 2 else { continue }
                        let kind = parts[0]
                        guard kind.count <= 3, kind.first?.isLetter == true else { continue }
                        rows.append((kind, parts[1], "since \(since)"))
                    }
                }
            }
        } else {
            gitError = "git not installed"
        }
        if let sinceDate = request.since.flatMap(ISO8601DateFormatter().date(from:)) {
            let index = await env.index(for: root)
            let paths = await index.allPaths()
            for path in paths {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let modified = attributes[.modificationDate] as? Date,
                      modified > sinceDate else { continue }
                rows.append(("M", path.replacingOccurrences(of: root + "/", with: ""), "mtime after \(request.since ?? "")"))
            }
        }
        var seen = Set<String>()
        let unique = rows.filter { seen.insert("\($0.kind) \($0.path)").inserted }
        guard !unique.isEmpty else {
            let suffix = gitError.map { " (\($0))" } ?? ""
            return LibrarianHandlerOutput(
                status: .ok,
                text: "workspace_change_notice root=\(root) changes=0\(suffix)",
                originalForSavings: request.input
            )
        }
        var lines = ["workspace_change_notice root=\(root) changes=\(unique.count)"]
        lines.append(contentsOf: unique.prefix(100).map { "\($0.kind)\t\($0.path)\t\($0.detail)" })
        let joined = lines.joined(separator: "\n")
        _ = store.put(joined)
        return LibrarianHandlerOutput(status: .ok, text: joined, originalForSavings: request.input)
    }
}

/// Token-level structural matcher: `$Name` captures one token, everything else
/// must match literally. Deterministic, dependency-free and honest about mode.
public struct LibrarianStructuralMatcher: Sendable {
    public struct Match: Sendable, Equatable {
        public let line: Int
        public let captures: [String]
        public let snippet: String
    }

    private let patternTokens: [String]
    private let wildcardIndices: Set<Int>

    public init(pattern: String) {
        let tokens = Self.tokenize(pattern).filter { $0 != ";" }
        self.patternTokens = tokens
        self.wildcardIndices = Set(tokens.enumerated().compactMap { index, token in
            token.hasPrefix("$") && token.count > 1 ? index : nil
        })
    }

    public var tokenCount: Int { patternTokens.count }

    public func matches(in text: String, limit: Int = 200) -> [Match] {
        guard patternTokens.count >= 2 else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [Match] = []
        for (lineIndex, line) in lines.enumerated() {
            let lineTokens = Self.tokenize(line)
            guard lineTokens.count >= patternTokens.count else { continue }
            var start = 0
            while start + patternTokens.count <= lineTokens.count {
                if let captures = matchWindow(lineTokens, at: start) {
                    found.append(Match(
                        line: lineIndex,
                        captures: captures,
                        snippet: line.trimmingCharacters(in: .whitespaces).prefix(200).description
                    ))
                    start += patternTokens.count
                } else {
                    start += 1
                }
                if found.count >= limit { return found }
            }
        }
        return found
    }

    private func matchWindow(_ tokens: [String], at start: Int) -> [String]? {
        var captures: [String] = []
        for offset in patternTokens.indices {
            let patternToken = patternTokens[offset]
            let token = tokens[start + offset]
            if wildcardIndices.contains(offset) {
                captures.append(token)
            } else if patternToken != token {
                return nil
            }
        }
        return captures
    }

    /// Identifier/number/punctuation tokenizer shared by pattern and text.
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let character = chars[index]
            if character.isLetter || character.isNumber || character == "_" || character == "$" || character == "." {
                current.append(character)
                index += 1
                continue
            }
            flush()
            if character.isWhitespace {
                index += 1
                continue
            }
            // Two-character operators stay together so `==` never matches `=`.
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            if let next, "=!<>+-*/&|^%".contains(character), "=<>".contains(next) {
                tokens.append("\(character)\(next)")
                index += 2
                continue
            }
            tokens.append(String(character))
            index += 1
        }
        flush()
        return tokens
    }
}
