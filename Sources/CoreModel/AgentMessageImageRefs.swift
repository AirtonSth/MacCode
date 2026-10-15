import Foundation

/// One image an assistant message talks about (contract §4, Mac ↔ iOS).
///
/// The Mac renders these as the message's image gallery; the iPhone fetches
/// the Mac-local ones through `agent.message.image.get` using `ref`, which is
/// the reference exactly as it is written in the message (or the attachment id).
public struct AgentMessageImageRef: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// A message attachment stored by the host (e.g. a bot screenshot).
        case attachment(id: String?, path: String)
        /// An absolute local path (`/x.png`, `~/x.png` expanded, `file://` decoded).
        case localPath(String)
        /// An http(s) image URL.
        case remote(URL)
    }

    public let source: Source
    /// The literal reference: the attachment id (or path) for attachments,
    /// otherwise the token as written in the message content.
    public let ref: String
    public let displayName: String

    public init(source: Source, ref: String, displayName: String) {
        self.source = source
        self.ref = ref
        self.displayName = displayName
    }

    /// Local filesystem path for attachments and local refs; nil for remote.
    public var localPath: String? {
        switch source {
        case .attachment(_, let path), .localPath(let path): return path
        case .remote: return nil
        }
    }
}

/// Pure detection of the images an assistant message refers to, shared by the
/// Mac gallery and the host RPC. Order: image attachments first, then text
/// references in order of appearance; de-duplicated by resolved target.
public enum AgentMessageImageRefs {
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp",
    ]

    public static func hasImageExtension(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public static func isImageAttachment(_ attachment: AgentAttachment) -> Bool {
        if attachment.kind == .image { return true }
        if attachment.mimeType?.lowercased().hasPrefix("image/") == true { return true }
        return hasImageExtension(attachment.path) || hasImageExtension(attachment.displayName)
    }

    /// Resolves one text reference (`/abs`, `~/x`, `file://`, `http(s)://`) to
    /// a source when it names an image file; nil for anything else (relative
    /// paths, non-image extensions, other schemes).
    public static func source(forReference raw: String, homeDirectory: String = NSHomeDirectory()) -> AgentMessageImageRef.Source? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        let lower = token.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: token), url.host?.isEmpty == false,
                  imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return .remote(url)
        }
        let path: String
        if lower.hasPrefix("file://") {
            guard let url = URL(string: token), url.isFileURL, url.path.hasPrefix("/") else { return nil }
            path = url.path
        } else if token.hasPrefix("~/") {
            path = (homeDirectory as NSString).appendingPathComponent(String(token.dropFirst(2)))
        } else if token.hasPrefix("/") {
            path = token
        } else {
            return nil
        }
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix("/"), hasImageExtension(standardized) else { return nil }
        return .localPath(standardized)
    }

    public static func extract(
        content: String,
        attachments: [AgentAttachment] = [],
        homeDirectory: String = NSHomeDirectory()
    ) -> [AgentMessageImageRef] {
        var result: [AgentMessageImageRef] = []
        var seen = Set<String>()

        func add(_ ref: AgentMessageImageRef) {
            let key: String
            switch ref.source {
            case .attachment(_, let path), .localPath(let path): key = "file:" + path
            case .remote(let url): key = "url:" + url.absoluteString
            }
            guard seen.insert(key).inserted else { return }
            result.append(ref)
        }

        for attachment in attachments where isImageAttachment(attachment) {
            add(AgentMessageImageRef(
                source: .attachment(id: attachment.id, path: attachment.path),
                ref: attachment.id ?? attachment.sha256 ?? attachment.path,
                displayName: attachment.displayName
            ))
        }
        guard mayContainTextReference(content) else { return result }
        for token in textReferences(in: content) {
            guard let source = source(forReference: token, homeDirectory: homeDirectory) else { continue }
            add(AgentMessageImageRef(source: source, ref: token, displayName: displayName(for: source)))
        }
        return result
    }

    // MARK: - Text scanning

    /// Cheap pre-filter so ordinary replies never pay for the scanners below.
    /// One allocation-free pass over the UTF-8: called on every transcript
    /// row refresh, so it must stay cheap for long replies.
    public static func mayContainTextReference(_ content: String) -> Bool {
        let bytes = content.utf8
        var index = bytes.startIndex
        let bang = UInt8(ascii: "!"), bracket = UInt8(ascii: "["), dot = UInt8(ascii: ".")
        while index < bytes.endIndex {
            let byte = bytes[index]
            let next = bytes.index(after: index)
            if byte == bang, next < bytes.endIndex, bytes[next] == bracket { return true }
            if byte == dot, extensionFollows(bytes, from: next) { return true }
            index = next
        }
        return false
    }

    private static let extensionBytes: [[UInt8]] = imageExtensions.map { Array($0.utf8) }

    private static func extensionFollows(_ bytes: String.UTF8View, from start: String.Index) -> Bool {
        candidates: for ext in extensionBytes {
            var cursor = start
            for expected in ext {
                guard cursor < bytes.endIndex else { continue candidates }
                // ASCII lowercase fold; extensions are lowercase letters.
                let byte = bytes[cursor] | 0x20
                guard byte == expected else { continue candidates }
                cursor = bytes.index(after: cursor)
            }
            return true
        }
        return false
    }

    /// Candidate tokens in order of appearance: markdown image sources (not in
    /// code spans) and bare URLs/paths (in prose or inline code). Fenced code
    /// blocks are skipped: code is not "talking about" an image.
    static func textReferences(in content: String) -> [String] {
        var found: [(offset: Int, token: String)] = []
        var fence: (char: Character, length: Int)?
        var lineOffset = 0
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { lineOffset += line.utf16.count + 1 }
            let lead = line.drop(while: { $0 == " " || $0 == "\t" })
            if let open = fence {
                let run = lead.prefix(while: { $0 == open.char })
                if run.count >= open.length, lead.dropFirst(run.count).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
                continue
            }
            if let opener = fenceOpener(lead) {
                fence = opener
                continue
            }
            let ns = String(line) as NSString
            let codeSpans = inlineCodeRanges(in: ns)
            var claimed: [NSRange] = []
            for image in markdownImageSources(in: ns) where !codeSpans.contains(where: { NSIntersectionRange($0, image.whole).length > 0 }) {
                claimed.append(image.whole)
                found.append((lineOffset + image.whole.location, image.source))
            }
            let full = NSRange(location: 0, length: ns.length)
            var urlRanges: [NSRange] = []
            for match in urlRegex.matches(in: ns as String, range: full) {
                let range = trimmedToken(match.range, in: ns)
                guard range.length > 0, !claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                urlRanges.append(range)
                found.append((lineOffset + range.location, ns.substring(with: range)))
            }
            for match in pathRegex.matches(in: ns as String, range: full) {
                let range = trimmedToken(match.range, in: ns)
                guard range.length > 0,
                      !claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                      !urlRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                found.append((lineOffset + range.location, ns.substring(with: range)))
            }
        }
        return found.sorted { $0.offset < $1.offset }.map(\.token)
    }

    /// ``` or ~~~ (3+) opening a fence; a backtick fence's info string may not
    /// contain a backtick (that is an inline code span instead).
    static func fenceOpener<S: StringProtocol>(_ trimmed: S) -> (char: Character, length: Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        if first == "`", trimmed.dropFirst(run).contains("`") { return nil }
        return (first, run)
    }

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![\w/])(?:https?|file)://[^\s<>"'`\[\]{}|\\^]+"#
    )
    private static let pathRegex = try! NSRegularExpression(
        pattern: #"(?<![\w.~/\-:])(?:~/|/)[^\s<>"'`()\[\]{}|*]+"#
    )

    /// Drops sentence punctuation glued to a token, and a closing paren that
    /// has no opening one inside the token (`(see /a.png)`).
    private static func trimmedToken(_ range: NSRange, in text: NSString) -> NSRange {
        var length = range.length
        while length > 0 {
            let token = text.substring(with: NSRange(location: range.location, length: length))
            guard let last = token.last else { break }
            if ".,;:!?*_\"'".contains(last) {
                length -= 1
            } else if last == ")",
                      token.filter({ $0 == ")" }).count > token.filter({ $0 == "(" }).count {
                length -= 1
            } else {
                break
            }
        }
        return NSRange(location: range.location, length: length)
    }

    /// UTF-16 ranges of inline code spans (backtick runs of equal length).
    static func inlineCodeRanges(in line: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        let length = line.length
        let tick: unichar = 96
        var index = 0
        while index < length {
            guard line.character(at: index) == tick else { index += 1; continue }
            var run = 0
            while index + run < length, line.character(at: index + run) == tick { run += 1 }
            var search = index + run
            var closed = false
            while search < length {
                guard line.character(at: search) == tick else { search += 1; continue }
                var close = 0
                while search + close < length, line.character(at: search + close) == tick { close += 1 }
                if close == run {
                    ranges.append(NSRange(location: index, length: search + close - index))
                    index = search + close
                    closed = true
                    break
                }
                search += close
            }
            if !closed { index += run }
        }
        return ranges
    }

    /// `![alt](src "title")` sources, with balanced parentheses in `src` and
    /// `<...>` destinations.
    static func markdownImageSources(in line: NSString) -> [(whole: NSRange, source: String)] {
        var results: [(NSRange, String)] = []
        let text = line as String
        var searchStart = text.startIndex
        while let bang = text.range(of: "![", range: searchStart..<text.endIndex) {
            searchStart = bang.upperBound
            guard let closeBracket = text[bang.upperBound...].firstIndex(of: "]") else { break }
            let afterBracket = text.index(after: closeBracket)
            guard afterBracket < text.endIndex, text[afterBracket] == "(" else { continue }
            var cursor = text.index(after: afterBracket)
            while cursor < text.endIndex, text[cursor] == " " { cursor = text.index(after: cursor) }
            var source = ""
            if cursor < text.endIndex, text[cursor] == "<" {
                guard let end = text[cursor...].firstIndex(of: ">") else { continue }
                source = String(text[text.index(after: cursor)..<end])
                cursor = text.index(after: end)
            } else {
                var depth = 0
                let start = cursor
                while cursor < text.endIndex {
                    let character = text[cursor]
                    if character == " " || character == "\t" { break }
                    if character == "(" { depth += 1 }
                    if character == ")" {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    cursor = text.index(after: cursor)
                }
                source = String(text[start..<cursor])
            }
            // Optional title, then the closing paren.
            while cursor < text.endIndex, text[cursor] == " " { cursor = text.index(after: cursor) }
            if cursor < text.endIndex, text[cursor] == "\"" {
                guard let endQuote = text[text.index(after: cursor)...].firstIndex(of: "\"") else { continue }
                cursor = text.index(after: endQuote)
                while cursor < text.endIndex, text[cursor] == " " { cursor = text.index(after: cursor) }
            }
            guard cursor < text.endIndex, text[cursor] == ")", !source.isEmpty else { continue }
            let whole = NSRange(bang.lowerBound..<text.index(after: cursor), in: text)
            results.append((whole, source))
            searchStart = text.index(after: cursor)
        }
        return results
    }

    private static func displayName(for source: AgentMessageImageRef.Source) -> String {
        switch source {
        case .attachment(_, let path), .localPath(let path):
            return (path as NSString).lastPathComponent
        case .remote(let url):
            return url.lastPathComponent.isEmpty ? (url.host ?? url.absoluteString) : url.lastPathComponent
        }
    }
}
