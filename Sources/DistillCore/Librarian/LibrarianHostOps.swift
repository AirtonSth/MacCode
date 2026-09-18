import Foundation
import CoreModel

/// Host-owned ops: PATH wrapper inventory, resume/replay evictions, unchanged
/// re-read stubs, the paid-authored deterministic codemod and predicate watch.
/// They never rewrite a live provider session — they transform host-owned
/// context (the caller passes it) and keep every original in the handle store.
enum LibrarianHostOps {
    // MARK: - path_wrappers

    static func pathWrappers(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let home = env.host.home()
        let managed = "\(home)/.remote-code/bin"
        let localBin = "\(home)/.local/bin"
        var rows: [String] = []
        if env.host.isDirectory(managed) {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: managed))?.sorted() ?? []
            for name in entries where !name.hasPrefix(".") {
                let path = "\(managed)/\(name)"
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "(file)"
                let exact = WrappedCommandCatalog.isExactOutputCommand(name) ? "exact-output:never-wrapped" : "wrapped"
                rows.append("\(name)\t\(exact)\t\(target)")
            }
        }
        var lines = ["path_wrappers managed_bin=\(managed) wrappers=\(rows.count)"]
        lines.append(contentsOf: rows)
        if env.host.fileExists("\(localBin)/distill") {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: "\(localBin)/distill")) ?? "(file)"
            lines.append("distill\tcli\t\(target)")
        }
        guard rows.count > 0 || env.host.fileExists("\(localBin)/distill") else {
            return LibrarianHandlerOutput(
                status: .unavailable,
                text: "no managed PATH wrappers installed under \(managed)",
                envelope: .unavailable(op: request.id, reason: "no_wrappers_installed", handle: nil),
                stage: .verbatim,
                originalForSavings: request.input
            )
        }
        let joined = lines.joined(separator: "\n")
        _ = store.put(joined)
        return LibrarianHandlerOutput(status: .ok, text: joined, originalForSavings: request.input)
    }

    // MARK: - stale_tool_result_evict / stale_tool_args_evict

    static func staleToolResultEvict(
        _ request: LibrarianRequest,
        resolved: ResolvedBox,
        store: LibrarianHandleStore
    ) async -> LibrarianHandlerOutput {
        evict(
            request,
            resolved: resolved,
            store: store,
            kinds: ["tool_result", "result", "tool_output"],
            keepRecent: 2,
            marker: "result"
        )
    }

    static func staleToolArgsEvict(
        _ request: LibrarianRequest,
        resolved: ResolvedBox,
        store: LibrarianHandleStore
    ) async -> LibrarianHandlerOutput {
        evict(
            request,
            resolved: resolved,
            store: store,
            kinds: ["tool_call", "tool_args", "tool_use", "args"],
            keepRecent: 2,
            marker: "args"
        )
    }

    private static func evict(
        _ request: LibrarianRequest,
        resolved: ResolvedBox,
        store: LibrarianHandleStore,
        kinds: Set<String>,
        keepRecent: Int,
        marker: String
    ) -> LibrarianHandlerOutput {
        guard let data = resolved.text.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var messages = root["messages"] as? [[String: Any]] else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "evict_needs_host_owned_json",
                text: "\(request.id) expects {\"messages\":[{\"kind\":\"tool_result\",\"content\":\"…\"}]}"
            )
        }
        let indices = messages.indices.filter { index in
            let kind = (messages[index]["kind"] as? String) ?? ""
            return kinds.contains(kind) && ((messages[index]["content"] as? String)?.isEmpty == false)
        }
        let evictable = indices.dropLast(keepRecent)
        var evicted = 0
        var savedBytes = 0
        var handles: [String] = []
        for index in evictable {
            guard var content = messages[index]["content"] as? String else { continue }
            let handle = store.put(content, kind: marker)
            handles.append(handle)
            savedBytes += content.utf8.count
            let path = (messages[index]["path"] as? String) ?? ""
            let hash = TokenEstimator.estimate(content)
            content = "[[rc:\(handle)]] \(marker)_elided bytes=\(content.utf8.count) est_tokens=\(hash)\(path.isEmpty ? "" : " path=\(path)")"
            messages[index]["content"] = content
            messages[index]["elided"] = true
            evicted += 1
        }
        root["messages"] = messages
        guard evicted > 0 else {
            return LibrarianHandlerOutput(
                status: .ok,
                text: "\(request.id) evicted=0 (nothing older than the last \(keepRecent) matches)",
                handle: resolved.handle,
                stage: .verbatim,
                originalForSavings: resolved.original
            )
        }
        let payload: String
        if let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
           let json = String(data: encoded, encoding: .utf8) {
            payload = json
        } else {
            payload = resolved.text
        }
        let header = "\(request.id) evicted=\(evicted) saved_bytes=\(savedBytes) handles=\(handles.count)"
        let text = header + "\n" + payload
        _ = store.put(text, handle: resolved.handle)
        return LibrarianHandlerOutput(status: .ok, text: text, handle: resolved.handle, originalForSavings: resolved.original)
    }

    // MARK: - unchanged_reread_stub

    static func unchangedRereadStub(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        let root = env.root(for: request)
        guard let relative = request.paths.first ?? request.fileName, !relative.isEmpty else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "missing_file",
                text: "unchanged_reread_stub needs a path"
            )
        }
        let path = LibrarianWorkspaceOps.absolute(relative, root: root)
        guard let current = env.host.readText(path, LibrarianWorkspaceFiles.maxFileBytes) else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "file_unreadable",
                text: "cannot read \(path)"
            )
        }
        let currentHandle = LibrarianHandleStore.makeHandle(current)
        let previous: String? = {
            guard let handle = request.handle, !handle.isEmpty else { return nil }
            return store.get(handle)
        }()
        guard let previous else {
            _ = store.put(current, handle: currentHandle, kind: "file")
            let lines = current.split(separator: "\n", omittingEmptySubsequences: false).count
            let payload = "unchanged_reread_stub path=\(relative) status=first_read lines=\(lines) handle=\(currentHandle)\n\(current)"
            _ = store.put(payload, handle: currentHandle)
            return LibrarianHandlerOutput(status: .ok, text: payload, handle: currentHandle, originalForSavings: current)
        }
        if previous == current {
            let lines = current.split(separator: "\n", omittingEmptySubsequences: false).count
            let stub = "unchanged_reread_stub path=\(relative) status=unchanged lines=\(lines) handle=\(currentHandle) (content identical to \(request.handle ?? "previous"); no bytes re-sent)"
            return LibrarianHandlerOutput(status: .ok, text: stub, handle: currentHandle, originalForSavings: previous)
        }
        let ranges = changedLineRanges(previous: previous, current: current)
        var stub = "unchanged_reread_stub path=\(relative) status=changed handle=\(currentHandle) changed_lines=\(ranges.count)"
        let previousLines = previous.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let currentLines = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for range in ranges.prefix(20) {
            let body = currentLines[(range.lowerBound - 1)..<min(range.upperBound, currentLines.count)]
                .joined(separator: "\n")
            stub += "\n@@ lines \(range.lowerBound)-\(range.upperBound) @@\n\(body)"
        }
        if previousLines.count != currentLines.count {
            stub += "\nline_count \(previousLines.count) -> \(currentLines.count)"
        }
        _ = store.put(current, handle: currentHandle, kind: "file")
        _ = store.put(stub, kind: "stub")
        return LibrarianHandlerOutput(status: .ok, text: stub, handle: currentHandle, originalForSavings: previous)
    }

    static func changedLineRanges(previous: String, current: String) -> [ClosedRange<Int>] {
        let old = previous.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var ranges: [ClosedRange<Int>] = []
        let maxCount = max(old.count, new.count)
        var index = 0
        while index < maxCount {
            let oldLine = index < old.count ? old[index] : nil
            let newLine = index < new.count ? new[index] : nil
            guard oldLine != newLine else { index += 1; continue }
            let start = index + 1
            var end = index + 1
            while end < maxCount {
                let o = end < old.count ? old[end] : nil
                let n = end < new.count ? new[end] : nil
                if o == n { break }
                end += 1
            }
            ranges.append(start...max(start, end))
            index = end
        }
        return ranges
    }

    // MARK: - batch_codemod_apply

    static func batchCodemodApply(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        guard let payload = request.payload?.data(using: .utf8),
              let spec = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let pattern = spec["pattern"] as? String, !pattern.isEmpty,
              let replacement = spec["replacement"] as? String else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "codemod_needs_paid_rule",
                text: #"batch_codemod_apply expects {"pattern":"…","replacement":"…","paths":[…],"apply":true}"#
            )
        }
        let root = env.root(for: request)
        let apply = (spec["apply"] as? Bool) ?? false
        let literal = (spec["literal"] as? Bool) ?? false
        let maxFiles = max(1, min(200, (spec["maxFiles"] as? Int) ?? 50))
        var files: [String] = []
        if let listed = spec["paths"] as? [String], !listed.isEmpty {
            files = listed.map { LibrarianWorkspaceOps.absolute($0, root: root) }
        } else {
            let index = await env.index(for: root)
            files = Array((await index.allPaths()).prefix(maxFiles))
        }
        guard !files.isEmpty else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "no_files",
                text: "batch_codemod_apply found no files under \(root)"
            )
        }
        var report: [String] = []
        var changed = 0
        var totalLineChanges = 0
        var revertHandles: [String] = []
        for path in files {
            guard let text = env.host.readText(path, LibrarianWorkspaceFiles.maxFileBytes) else { continue }
            let rewritten = literal
                ? text.replacingOccurrences(of: pattern, with: replacement)
                : (try? NSRegularExpression(pattern: pattern))?
                    .stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: replacement)
            guard let rewritten, rewritten != text else { continue }
            let relative = path.replacingOccurrences(of: root + "/", with: "")
            let ranges = changedLineRanges(previous: text, current: rewritten)
            totalLineChanges += ranges.count
            changed += 1
            let handle = store.put(text, kind: "codemod-original")
            revertHandles.append("\(relative)=\(handle)")
            if apply {
                _ = env.host.writeText(path, rewritten)
            }
            let preview = rewritten.split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(0)
                .joined()
            report.append("\(relative)\tchanged_lines=\(ranges.count)\toriginal=\(handle)\(preview.isEmpty ? "" : " \(preview)")")
        }
        guard changed > 0 else {
            return LibrarianHandlerOutput(
                status: .ok,
                text: "batch_codemod_apply apply=\(apply) files_scanned=\(files.count) files_changed=0",
                originalForSavings: request.input
            )
        }
        var lines = [
            "batch_codemod_apply apply=\(apply) files_scanned=\(files.count) files_changed=\(changed) changed_line_groups=\(totalLineChanges)",
            "revert: rc_retrieve <handle> restores the original bytes (apply=\(apply) wrote to disk: \(apply ? "yes" : "no"))"
        ]
        lines.append(contentsOf: report)
        lines.append("revert_map " + revertHandles.joined(separator: " "))
        let joined = lines.joined(separator: "\n")
        _ = store.put(joined)
        return LibrarianHandlerOutput(status: .ok, text: joined, originalForSavings: request.input)
    }

    // MARK: - predicate_watch

    static func predicateWatch(
        _ request: LibrarianRequest,
        store: LibrarianHandleStore,
        env: LibrarianOpEnvironment
    ) async -> LibrarianHandlerOutput {
        guard let command = request.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty,
              let pattern = request.pattern?.trimmingCharacters(in: .whitespacesAndNewlines), !pattern.isEmpty else {
            return LibrarianWorkspaceOps.missingArgument(
                request,
                reason: "watch_needs_approved_command",
                text: "predicate_watch needs an approved command and a pattern; RemoteCode never runs a locally-suggested command"
            )
        }
        let timeout = max(1, min(120, request.watchTimeoutSeconds ?? 30))
        let interval = max(0.2, min(10, request.watchIntervalSeconds ?? 1.5))
        let deadline = Date().addingTimeInterval(Double(timeout))
        var attempts = 0
        var lastOutput = ""
        var matched: [String] = []
        while Date() < deadline {
            attempts += 1
            let result = env.host.runProcess(LibrarianProcessInvocation(
                executable: command,
                arguments: request.arguments,
                cwd: env.root(for: request),
                timeout: min(Double(timeout), 30)
            ))
            lastOutput = result.stdout
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return LibrarianWorkspaceOps.missingArgument(
                    request,
                    reason: "invalid_pattern",
                    text: "predicate_watch pattern is not a valid regex"
                )
            }
            let ns = lastOutput as NSString
            let hits = regex.matches(in: lastOutput, range: NSRange(location: 0, length: ns.length))
            if !hits.isEmpty {
                let lines = lastOutput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                for hit in hits.prefix(20) {
                    let lineIndex = ns.substring(to: hit.range.location).split(separator: "\n").count - 1
                    if lineIndex >= 0, lineIndex < lines.count { matched.append(lines[lineIndex]) }
                }
                if matched.isEmpty { matched = hits.prefix(5).map { ns.substring(with: $0.range) } }
                let text = "predicate_watch matched after \(attempts) attempt(s):\n" + matched.joined(separator: "\n")
                _ = store.put(lastOutput)
                return LibrarianHandlerOutput(status: .ok, text: text, originalForSavings: request.input)
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        let tail = lastOutput.split(separator: "\n").suffix(10).joined(separator: "\n")
        let text = "predicate_watch no match after \(attempts) attempt(s) within \(timeout)s; last output tail:\n\(tail)"
        _ = store.put(lastOutput)
        return LibrarianHandlerOutput(
            status: .unavailable,
            text: text,
            envelope: .unavailable(op: request.id, reason: "watch_timeout", handle: nil),
            stage: .verbatim,
            originalForSavings: request.input
        )
    }
}
