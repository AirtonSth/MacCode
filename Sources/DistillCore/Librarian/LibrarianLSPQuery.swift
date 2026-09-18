import Foundation

public struct LSPResolvedItem: Sendable, Equatable {
    public let path: String
    public let line: Int
    public let character: Int
    public let kind: String
    public let detail: String
}

public struct LSPQueryOutcome: Sendable {
    public let launched: Bool
    public let items: [LSPResolvedItem]
    public let diagnostic: String
}

public enum LSPTextPosition {
    /// 0-based (line, character) of the first occurrence of `symbol`.
    public static func locate(symbol: String, operation: String, in text: String) -> (line: Int, character: Int) {
        guard operation != "documentSymbol" || !symbol.isEmpty else { return (0, 0) }
        guard !symbol.isEmpty else { return (0, 0) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            guard let range = line.range(of: symbol) else { continue }
            return (index, line.distance(from: line.startIndex, to: range.lowerBound))
        }
        return (0, 0)
    }
}

extension LibrarianLSPClient {
    /// One short-lived sourcekit-lsp session: initialize → didOpen → query →
    /// shutdown. Anything unexpected returns `launched` with a diagnostic so the
    /// op reports a real failure instead of inventing symbols.
    public static func query(
        client: LibrarianLSPClient,
        root: String,
        file: String,
        text: String,
        languageID: String,
        operation: String,
        position: (line: Int, character: Int)
    ) -> LSPQueryOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: client.executable)
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return LSPQueryOutcome(launched: false, items: [], diagnostic: "launch failed")
        }
        defer {
            try? stdinPipe.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        let writer = stdinPipe.fileHandleForWriting
        let reader = LSPFrameReader(handle: stdoutPipe.fileHandleForReading)
        let deadline = Date().addingTimeInterval(max(3, client.timeout))

        func send(id: Int?, method: String, params: [String: Any]) -> Bool {
            var payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            if let id { payload["id"] = id }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
            var frame = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
            frame.append(data)
            return (try? writer.write(contentsOf: frame)) != nil
        }

        guard send(id: 1, method: "initialize", params: [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": "file://" + root.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).orEmpty(root),
            "capabilities": ["textDocument": ["documentSymbol": [:], "definition": [:], "references": [:], "hover": [:]]]
        ]) else {
            return LSPQueryOutcome(launched: true, items: [], diagnostic: "initialize write failed")
        }
        guard (reader.readResponse(id: 1, deadline: deadline)) != nil else {
            return LSPQueryOutcome(launched: true, items: [], diagnostic: "initialize timed out")
        }
        _ = send(id: nil, method: "initialized", params: [:])
        let uri = "file://" + file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).orEmpty(file)
        _ = send(id: nil, method: "textDocument/didOpen", params: [
            "textDocument": ["uri": uri, "languageId": languageID, "version": 1, "text": text]
        ])

        let method: String
        var params: [String: Any] = ["textDocument": ["uri": uri]]
        switch operation {
        case "documentSymbol":
            method = "textDocument/documentSymbol"
        case "references":
            method = "textDocument/references"
            params["position"] = ["line": position.line, "character": position.character]
            params["context"] = ["includeDeclaration": true]
        case "hover":
            method = "textDocument/hover"
            params["position"] = ["line": position.line, "character": position.character]
        default:
            method = "textDocument/definition"
            params["position"] = ["line": position.line, "character": position.character]
        }
        guard send(id: 2, method: method, params: params) else {
            return LSPQueryOutcome(launched: true, items: [], diagnostic: "query write failed")
        }
        guard let response = reader.readResponse(id: 2, deadline: deadline) else {
            return LSPQueryOutcome(launched: true, items: [], diagnostic: "\(operation) timed out")
        }
        _ = send(id: 3, method: "shutdown", params: [:])
        _ = send(id: nil, method: "exit", params: [:])
        let items = parse(response: response, operation: operation, root: root, uri: uri, text: text)
        return LSPQueryOutcome(launched: true, items: items, diagnostic: items.isEmpty ? "no results" : "")
    }

    private static func parse(
        response: [String: Any],
        operation: String,
        root: String,
        uri: String,
        text: String
    ) -> [LSPResolvedItem] {
        guard let result = response["result"] else { return [] }
        if let direct = result as? [String: Any] {
            return [parseHover(direct, root: root, uri: uri)].compactMap { $0 }
        }
        if operation == "documentSymbol", let symbols = result as? [[String: Any]] {
            return symbols.flatMap { symbol -> [LSPResolvedItem] in
                var out: [LSPResolvedItem] = []
                let name = symbol["name"] as? String ?? ""
                let kind = symbolKindName(symbol["kind"] as? Int)
                let locationRange = (symbol["location"] as? [String: Any])?["range"] as? [String: Any]
                let range = (symbol["range"] as? [String: Any]) ?? locationRange
                let start = range?["start"] as? [String: Any]
                let line = start?["line"] as? Int ?? 0
                let character = start?["character"] as? Int ?? 0
                out.append(LSPResolvedItem(path: uriPath(uri), line: line, character: character, kind: kind, detail: name))
                if let children = symbol["children"] as? [[String: Any]] {
                    out.append(contentsOf: children.compactMap { child in
                        guard let name = child["name"] as? String else { return nil }
                        let childRange = (child["range"] as? [String: Any])?["start"] as? [String: Any]
                        return LSPResolvedItem(
                            path: uriPath(uri),
                            line: childRange?["line"] as? Int ?? 0,
                            character: childRange?["character"] as? Int ?? 0,
                            kind: symbolKindName(child["kind"] as? Int),
                            detail: name
                        )
                    })
                }
                return out
            }
        }
        guard let locations = result as? [[String: Any]] else { return [] }
        return locations.compactMap { location in
            guard let locationURI = location["uri"] as? String ?? (location["targetUri"] as? String),
                  let range = location["range"] as? [String: Any] ?? ((location["targetSelectionRange"] as? [String: Any])),
                  let start = range["start"] as? [String: Any] else { return nil }
            let line = start["line"] as? Int ?? 0
            let character = start["character"] as? Int ?? 0
            let snippet = lineSnippet(path: uriPath(locationURI), line: line, text: text)
            return LSPResolvedItem(
                path: uriPath(locationURI),
                line: line,
                character: character,
                kind: operation,
                detail: snippet
            )
        }
    }

    private static func parseHover(_ result: [String: Any], root: String, uri: String) -> LSPResolvedItem? {
        let contents = result["contents"]
        let detail: String
        if let text = contents as? String {
            detail = text
        } else if let object = contents as? [String: Any], let value = object["value"] as? String {
            detail = value
        } else if let object = contents as? [String: Any], let value = object["language"] as? String {
            detail = value
        } else {
            return nil
        }
        return LSPResolvedItem(path: uriPath(uri), line: 0, character: 0, kind: "hover", detail: detail.prefix(200).description)
    }

    private static func uriPath(_ uri: String) -> String {
        guard uri.hasPrefix("file://") else { return uri }
        let raw = String(uri.dropFirst("file://".count))
        return raw.removingPercentEncoding ?? raw
    }

    private static func lineSnippet(path: String, line: Int, text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard line >= 0, line < lines.count else { return "" }
        return lines[line].trimmingCharacters(in: .whitespaces).prefix(140).description
    }

    private static func symbolKindName(_ kind: Int?) -> String {
        switch kind {
        case 1: return "file"
        case 2: return "module"
        case 5: return "class"
        case 6: return "method"
        case 7: return "property"
        case 8: return "field"
        case 9: return "constructor"
        case 10: return "enum"
        case 11: return "interface"
        case 12: return "function"
        case 13: return "variable"
        case 14: return "constant"
        case 22: return "enumMember"
        case 23: return "struct"
        case 26: return "typeParameter"
        default: return "symbol"
        }
    }
}

/// Content-Length framed reader with a deadline. Reads only complete frames and
/// never blocks past the deadline, so a wedged LSP server cannot hang the op.
final class LSPFrameReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readResponse(id: Int, deadline: Date) -> [String: Any]? {
        while Date() < deadline {
            if let payload = nextPayload() {
                guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                if let responseID = object["id"] as? Int, responseID == id {
                    return object
                }
                continue
            }
            guard waitForData(until: deadline) else { return nil }
            let chunk = handle.availableData
            if chunk.isEmpty {
                usleep(5_000)
                continue
            }
            buffer.append(chunk)
        }
        return nil
    }

    private func nextPayload() -> Data? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(data: buffer[buffer.startIndex..<headerRange.lowerBound], encoding: .utf8) ?? ""
        var contentLength = 0
        for line in headerText.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        guard contentLength > 0 else {
            buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
            return nil
        }
        let bodyStart = headerRange.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let payload = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return payload
    }

    private func waitForData(until deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(1, min(250, remaining * 1000)))
        return poll(&descriptor, 1, milliseconds) > 0
    }
}

private extension Optional where Wrapped == String {
    func orEmpty(_ fallback: String) -> String { self ?? fallback }
}
