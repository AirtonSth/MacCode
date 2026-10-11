import Foundation
import SwiftUI
import AppKit
import DesignSystemKit

struct AgentMessageMarkdownBlock: Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case bullet(indent: Int)
        case numbered(number: Int, indent: Int)
        case code(language: String)
        case table(headers: [String], rows: [[String]])
        case blockquote
    }

    let kind: Kind
    let text: String
}

enum AgentMessageMarkdown {
    // F3: cache parsed blocks + attributed inline output keyed on the source text.
    // The markdown view re-evaluates `body` on every keystroke / streaming delta /
    // hover / window resize, and SwiftUI does NOT cache the AttributedString handed
    // to Text(...), so a custom tokenizer + Foundation `AttributedString(markdown:)`
    // ran for every visible block (and every table cell) on every pass. Persisted
    // message bodies are immutable, so after the first parse every re-render of
    // stable history is a cache hit; only the live streaming row (changing text)
    // reparses.
    //
    // R4-B: countLimit alone still retains every unique partial length during a
    // stream (each growing prefix is a distinct key). Bound occupancy with
    // totalCostLimit (UTF-8 cost) and allow callers to pass `cache: false` for
    // live rows so intermediate partials are never stored. NSCache is thread-safe;
    // these run on the main actor.
    private final class BlocksBox { let blocks: [AgentMessageMarkdownBlock]; init(_ b: [AgentMessageMarkdownBlock]) { blocks = b } }
    private final class AttributedBox { let value: AttributedString; init(_ v: AttributedString) { value = v } }

    /// Soft byte budget for cached markdown parse results (blocks + inline +
    /// prose share independent budgets). Finished 60 KiB replies still cache
    /// (~34 large replies per 2 MiB). Streaming partials still skip store
    /// via `cache: false`.
    static let blocksCacheCostLimit = 2 * 1_024 * 1_024
    static let inlineCacheCostLimit = 2 * 1_024 * 1_024
    /// Peak block-parse results retained process-wide (NSCache countLimit).
    static let blocksCacheCountLimit = 256
    /// Peak inline AttributedString results retained process-wide.
    static let inlineCacheCountLimit = 256

    private static let blocksCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = blocksCacheCountLimit
        cache.totalCostLimit = blocksCacheCostLimit
        return cache
    }()
    private static let inlineCache: NSCache<NSString, AttributedBox> = {
        let cache = NSCache<NSString, AttributedBox>()
        cache.countLimit = inlineCacheCountLimit
        cache.totalCostLimit = inlineCacheCostLimit
        return cache
    }()

    #if DEBUG
    // Test-only observability: how many times the uncached parse actually ran, so a
    // unit test can prove repeated renders of identical content hit the cache.
    nonisolated(unsafe) static var blocksComputeCountForTesting = 0
    /// Test-only: UTF-8 bytes tokenized by `computeBlocks` (live-tail proof).
    nonisolated(unsafe) static var blocksParsedUTF8BytesForTesting = 0
    nonisolated(unsafe) static var inlineComputeCountForTesting = 0
    /// Test-only: every `blocks(from:)` entry, including cache hits. Hover isolation
    /// must not increment this after the first parent body evaluation.
    nonisolated(unsafe) static var blocksLookupCountForTesting = 0
    /// Test-only: successful setObject admissions (not lookups).
    nonisolated(unsafe) static var blocksCacheStoreCountForTesting = 0
    nonisolated(unsafe) static var inlineCacheStoreCountForTesting = 0
    #endif

    /// Whether a source string is eligible to occupy NSCache.
    /// `cache: false` is live-only: never store, even under 48 KiB.
    static func shouldStoreMarkdownCache(textUTF8Count: Int, cache: Bool) -> Bool {
        cache && textUTF8Count > 0
    }

    /// CH-08: key by utf8 count + 64-bit hash so SwiftUI body does not rehash
    /// the full NSString on every pass.
    /// AA-28: one UTF-8 hash of the source text, handed down to the NSTextView
    /// wrapper as the row's content identity (see `AgentLinkedAttributedText`).
    static func sourceFingerprint(for text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text.utf8.count)
        hasher.combine(text)
        return hasher.finalize()
    }

    static func cacheKey(for text: String) -> NSString {
        cacheKey(for: text, fingerprint: sourceFingerprint(for: text))
    }

    /// AA-32: the cache key IS the source fingerprint prefixed by the byte
    /// count. Callers that already computed `sourceFingerprint(for:)` for the
    /// text-view identity pass it here instead of hashing the text again.
    static func cacheKey(for text: String, fingerprint: Int) -> NSString {
        "\(text.utf8.count):\(fingerprint)" as NSString
    }

    static func blocks(from text: String, cache: Bool = true) -> [AgentMessageMarkdownBlock] {
        #if DEBUG
        blocksLookupCountForTesting &+= 1
        #endif
        // Live streaming rows grow every paint tick. Re-tokenizing the whole
        // body each tick made a long reply O(n²); the prefix before the last
        // blank line outside a code fence is final, so parse (and cache) it
        // once and re-parse only the growing tail.
        if !cache {
            let chunks = stableLiveChunks(text)
            if chunks.count > 1 {
                var result: [AgentMessageMarkdownBlock] = []
                for (index, chunk) in chunks.enumerated() {
                    let isTail = index == chunks.count - 1
                    if isTail, !chunk.contains(where: { !$0.isWhitespace }) { break }
                    result += blocks(from: String(chunk), cache: !isTail)
                }
                return result
            }
        }
        let key = cacheKey(for: text)
        // Perf CH-04: `cache: false` (live streaming rows) must only skip the
        // STORE — the read still hits, so a body that was parsed while finished
        // (or by a sibling surface) is never re-parsed.
        if let cached = blocksCache.object(forKey: key) { return cached.blocks }
        let result = computeBlocks(from: text)
        let cost = text.utf8.count
        if shouldStoreMarkdownCache(textUTF8Count: cost, cache: cache) {
            blocksCache.setObject(BlocksBox(result), forKey: key, cost: cost)
            #if DEBUG
            blocksCacheStoreCountForTesting &+= 1
            #endif
        }
        return result
    }

    /// Splits at every blank line outside a ``` fence that follows visible
    /// content. `computeBlocks` flushes every block at such a line, so the
    /// concatenated per-chunk parses equal the full parse. All chunks but the
    /// last are final and cache; only the growing last chunk re-parses.
    static func stableLiveChunks(_ text: String) -> [Substring] {
        let utf8 = text.utf8
        var fenceOpen = false
        var lineStart = utf8.startIndex
        var chunkStart = utf8.startIndex
        var sawContent = false
        var chunks: [Substring] = []
        var index = utf8.startIndex
        while index < utf8.endIndex {
            if utf8[index] == UInt8(ascii: "\n") {
                let trimmed = text[lineStart..<index].drop(while: { $0 == " " || $0 == "\t" })
                let next = utf8.index(after: index)
                if trimmed.hasPrefix("```") {
                    fenceOpen.toggle()
                    sawContent = true
                } else if trimmed.allSatisfy(\.isWhitespace) {
                    if !fenceOpen, sawContent {
                        chunks.append(text[chunkStart..<lineStart])
                        chunkStart = next
                        sawContent = false
                    }
                } else {
                    sawContent = true
                }
                lineStart = next
            }
            index = utf8.index(after: index)
        }
        chunks.append(text[chunkStart...])
        return chunks
    }

    static func selectionGroups(from blocks: [AgentMessageMarkdownBlock]) -> [[AgentMessageMarkdownBlock]] {
        var groups: [[AgentMessageMarkdownBlock]] = []
        var prose: [AgentMessageMarkdownBlock] = []

        func flushProse() {
            guard !prose.isEmpty else { return }
            groups.append(prose)
            prose.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            switch block.kind {
            case .code, .table:
                flushProse()
                groups.append([block])
            default:
                prose.append(block)
            }
        }
        flushProse()
        return groups
    }

    private static let proseCache: NSCache<NSString, AttributedBox> = {
        let cache = NSCache<NSString, AttributedBox>()
        cache.countLimit = inlineCacheCountLimit
        cache.totalCostLimit = inlineCacheCostLimit
        return cache
    }()

    static func selectableProse(from blocks: [AgentMessageMarkdownBlock], compact: Bool, cache: Bool = true) -> AttributedString {
        let proseKey: NSString = {
            var hasher = Hasher()
            hasher.combine(compact)
            hasher.combine(blocks.count)
            for block in blocks {
                hasher.combine(block.text.utf8.count)
                hasher.combine(block.text)
            }
            return "prose:\(hasher.finalize())" as NSString
        }()
        if cache, let cached = proseCache.object(forKey: proseKey) {
            return cached.value
        }
        var result = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }

            let source: String
            let size: CGFloat
            let weight: Font.Weight
            let color: Color
            switch block.kind {
            case .paragraph:
                source = block.text
                size = 13
                weight = .regular
                color = DS.Palette.text
            case .heading(let level):
                source = block.text
                size = compact ? 13 : (level == 1 ? 18 : level == 2 ? 15 : 13)
                weight = .semibold
                color = DS.Palette.text
            case .bullet(let indent):
                source = String(repeating: "  ", count: indent) + "• " + block.text
                size = 13
                weight = .regular
                color = DS.Palette.text
            case .numbered(let number, let indent):
                source = String(repeating: "  ", count: indent) + "\(number). " + block.text
                size = 13
                weight = .regular
                color = DS.Palette.text
            case .blockquote:
                source = "▌ " + block.text
                size = 13
                weight = .regular
                color = DS.Palette.textSecondary
            case .code, .table:
                continue
            }

            // Perf CH-04: in a live streaming group only the LAST block can
            // still grow; stable earlier blocks are cached and read like
            // finished content so a token does not re-parse them.
            var line = attributedInline(source, cache: cache || index < blocks.count - 1)
            line.font = .system(size: size, weight: weight)
            line.foregroundColor = color
            result.append(line)
        }
        if cache {
            let cost = blocks.reduce(0) { $0 + $1.text.utf8.count }
            proseCache.setObject(AttributedBox(result), forKey: proseKey, cost: max(1, cost))
        }
        return result
    }

    private static func computeBlocks(from text: String) -> [AgentMessageMarkdownBlock] {
        #if DEBUG
        blocksComputeCountForTesting &+= 1
        blocksParsedUTF8BytesForTesting &+= text.utf8.count
        #endif
        var blocks: [AgentMessageMarkdownBlock] = []
        var paragraph: [String] = []
        var inFence = false
        var fenceLanguage = ""
        var fenceLines: [String] = []

        // Table accumulation: pending header cells + confirmed rows
        var tableHeaders: [String] = []
        var tableRows: [[String]] = []
        var inTable = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(AgentMessageMarkdownBlock(kind: .paragraph, text: paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        func flushTable() {
            guard inTable, !tableHeaders.isEmpty else { return }
            blocks.append(AgentMessageMarkdownBlock(
                kind: .table(headers: tableHeaders, rows: tableRows),
                text: ""
            ))
            tableHeaders.removeAll()
            tableRows.removeAll()
            inTable = false
        }

        // Parse a pipe-delimited row into trimmed cells (strips outer pipes).
        func tableCells(from line: String) -> [String] {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s = String(s.dropFirst()) }
            if s.hasSuffix("|") { s = String(s.dropLast()) }
            return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        // A GFM separator row contains only pipes, dashes, colons, and spaces.
        func isSeparatorRow(_ line: String) -> Bool {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("|") || s.contains("|") else { return false }
            let stripped = s.replacingOccurrences(of: "|", with: "")
                            .replacingOccurrences(of: "-", with: "")
                            .replacingOccurrences(of: ":", with: "")
                            .replacingOccurrences(of: " ", with: "")
            return stripped.isEmpty && s.contains("-")
        }

        // A pipe row: trimmed starts or ends with "|", or contains "|".
        func isPipeRow(_ line: String) -> Bool {
            let s = line.trimmingCharacters(in: .whitespaces)
            return s.hasPrefix("|") || (s.contains("|") && !s.hasPrefix(">"))
        }

        let rawLines = text.components(separatedBy: "\n")
        var i = rawLines.startIndex

        while i < rawLines.endIndex {
            let rawLine = rawLines[i]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            i = rawLines.index(after: i)

            if inFence {
                if trimmed.hasPrefix("```") {
                    flushTable()
                    blocks.append(AgentMessageMarkdownBlock(
                        kind: .code(language: fenceLanguage),
                        text: fenceLines.joined(separator: "\n")
                    ))
                    inFence = false
                    fenceLanguage = ""
                    fenceLines.removeAll()
                } else {
                    fenceLines.append(rawLine)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushTable()
                flushParagraph()
                inFence = true
                fenceLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if trimmed.isEmpty {
                flushTable()
                flushParagraph()
                continue
            }

            // GFM table detection: pipe row followed by separator on next line.
            if !inTable && isPipeRow(trimmed) {
                let nextIndex = i  // i already advanced
                if nextIndex < rawLines.endIndex {
                    let nextTrimmed = rawLines[nextIndex].trimmingCharacters(in: .whitespaces)
                    if isSeparatorRow(nextTrimmed) {
                        // Confirmed table start -- flush any pending paragraph.
                        flushParagraph()
                        tableHeaders = tableCells(from: trimmed)
                        tableRows.removeAll()
                        inTable = true
                        // Consume separator line.
                        i = rawLines.index(after: i)
                        continue
                    }
                }
            }

            // If inside table, consume data rows.
            if inTable {
                if isPipeRow(trimmed) {
                    tableRows.append(tableCells(from: trimmed))
                    continue
                } else {
                    // Non-pipe line ends the table.
                    flushTable()
                    // Fall through to re-process this line as normal.
                }
            }

            // Blockquote: lines starting with "> ".
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                let content = trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : ""
                blocks.append(AgentMessageMarkdownBlock(kind: .blockquote, text: content))
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(AgentMessageMarkdownBlock(kind: .heading(heading.level), text: heading.text))
                continue
            }

            if let list = listItem(from: rawLine) {
                flushParagraph()
                switch list.marker {
                case .bullet:
                    blocks.append(AgentMessageMarkdownBlock(kind: .bullet(indent: list.indent), text: list.text))
                case .numbered(let number):
                    blocks.append(AgentMessageMarkdownBlock(kind: .numbered(number: number, indent: list.indent), text: list.text))
                }
                continue
            }

            paragraph.append(rawLine)
        }

        if inFence {
            blocks.append(AgentMessageMarkdownBlock(
                kind: .code(language: fenceLanguage),
                text: fenceLines.joined(separator: "\n")
            ))
        }
        flushTable()
        flushParagraph()

        return blocks.isEmpty ? [AgentMessageMarkdownBlock(kind: .paragraph, text: text)] : blocks
    }

    static func attributedInline(_ text: String, cache: Bool = true, fingerprint: Int? = nil) -> AttributedString {
        let key = fingerprint.map { cacheKey(for: text, fingerprint: $0) } ?? cacheKey(for: text)
        // Perf CH-04: `cache: false` skips only the store; the read still hits.
        if let cached = inlineCache.object(forKey: key) { return cached.value }
        let result = computeAttributedInline(text)
        let cost = text.utf8.count
        if shouldStoreMarkdownCache(textUTF8Count: cost, cache: cache) {
            inlineCache.setObject(AttributedBox(result), forKey: key, cost: cost)
            #if DEBUG
            inlineCacheStoreCountForTesting &+= 1
            #endif
        }
        return result
    }

    private static func computeAttributedInline(_ text: String) -> AttributedString {
        #if DEBUG
        inlineComputeCountForTesting &+= 1
        #endif
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        let codeRanges = attributed.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)
        for range in codeRanges {
            attributed[range].font = DS.Font.monoSmall
            attributed[range].backgroundColor = DS.Palette.surfaceOverlay
            attributed[range].foregroundColor = DS.Palette.accent
        }
        return applyingDetectedLinks(to: attributed)
    }

    // MARK: Clickable mentions (UX-MAC_AGENT-OPEN-SPLIT)
    // Bare URLs and file-path mentions in transcript prose become tappable `.link`
    // runs so a click can open a Browser / Files split panel. File mentions use a
    // custom scheme carrying the raw token; the click handler resolves it against
    // the thread's working directory (detection stays a pure function of the text,
    // keeping the NSCache text-keyed).

    static let fileLinkScheme = "remotecode-file"

    static func fileLinkURL(for rawPath: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = fileLinkScheme
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "path", value: rawPath)]
        return comps.url
    }

    static func filePath(fromFileLink url: URL) -> String? {
        guard url.scheme == fileLinkScheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "path" })?.value
    }

    // Explicit-scheme / www. / localhost URLs only — no bare-domain detection, so
    // file names like "Reducer.swift" or "config.dev" never false-positive as web links.
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:https?://|file:///|www\.)[^\s<>"'\)\]\}]+|(?<![\w.])localhost:\d+[^\s<>"'\)\]\}]*"#
    )

    // Two shapes: rooted paths (`/abs`, `~/x`, `./x`, `../x`) and relative paths that
    // contain a slash AND end in a file extension (so "and/or" or "I/O" never match).
    // Both accept a trailing `:line(:col)` suffix.
    private static let pathRegex = try! NSRegularExpression(
        pattern: #"(?<![\w@.\-/])(?:~|\.{1,2})?/(?:[\w.\-+@]+/)*[\w.\-+@]+(?::\d+(?::\d+)?)?|(?<![\w@.\-/~])(?:[\w.\-+@]+/)+[\w.\-+@]+\.[A-Za-z]\w{0,7}(?::\d+(?::\d+)?)?"#
    )

    // Bare filenames ("Package.swift", "foo.test.ts") are only linked inside inline
    // code spans, where a file mention is unambiguous.
    private static let bareFilenameRegex = try! NSRegularExpression(
        pattern: #"(?<![\w.\-/~])[\w\-]+(?:\.[\w\-]+)*\.[A-Za-z]\w{0,7}(?::\d+(?::\d+)?)?(?![\w/])"#
    )

    static func applyingDetectedLinks(to source: AttributedString) -> AttributedString {
        var hasSlashOrDot = false
        for character in source.characters {
            if character == "/" || character == "." {
                hasSlashOrDot = true
                break
            }
        }
        guard hasSlashOrDot else { return source }

        // NSRange is native on NSAttributedString, so each match is O(1) instead of
        // `String.distance` + `AttributedString.Index` offset from startIndex.
        let ns = NSMutableAttributedString(attributedString: NSAttributedString(source))
        let nsText = ns.string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let sourceHasLinks = source.runs.contains { $0.link != nil }

        func rangesOverlap(_ a: NSRange, _ b: NSRange) -> Bool {
            a.location < b.location + b.length && b.location < a.location + a.length
        }
        func hasExistingLink(_ range: NSRange) -> Bool {
            guard sourceHasLinks else { return false }
            guard range.length > 0, NSMaxRange(range) <= ns.length else { return true }
            var found = false
            ns.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
                if value != nil {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }
        func markLink(_ range: NSRange, url: URL) {
            ns.addAttribute(.link, value: url, range: range)
            ns.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            ns.addAttribute(.foregroundColor, value: DS.NS.accent, range: range)
        }
        func mappedTrimmed(_ range: NSRange) -> NSRange? {
            let trimmed = trimmingTrailingPunctuation(nsText, range)
            return trimmed.length > 0 ? trimmed : nil
        }

        var claimed: [NSRange] = []

        for match in urlRegex.matches(in: ns.string, range: fullRange) {
            guard let range = mappedTrimmed(match.range), !hasExistingLink(range) else { continue }
            let token = nsText.substring(with: range)
            guard let url = normalizedWebURL(token) else { continue }
            if url.isFileURL {
                guard let fileLink = fileLinkURL(for: url.path) else { continue }
                markLink(range, url: fileLink)
            } else {
                markLink(range, url: url)
            }
            claimed.append(range)
        }

        for match in pathRegex.matches(in: ns.string, range: fullRange) {
            guard let range = mappedTrimmed(match.range),
                  !claimed.contains(where: { rangesOverlap($0, range) }),
                  !hasExistingLink(range) else { continue }
            guard let fileLink = fileLinkURL(for: nsText.substring(with: range)) else { continue }
            markLink(range, url: fileLink)
            claimed.append(range)
        }

        // Bare filenames: restricted to inline-code runs. Collect UTF-16 ranges
        // from the source runs before mutation (few spans; not the 50-match path).
        let codeNSRanges: [NSRange] = source.runs.compactMap { run in
            guard run.inlinePresentationIntent?.contains(.code) == true else { return nil }
            return NSRange(run.range, in: source)
        }
        for nsRange in codeNSRanges {
            for match in bareFilenameRegex.matches(in: ns.string, range: nsRange) {
                guard let range = mappedTrimmed(match.range),
                      !claimed.contains(where: { rangesOverlap($0, range) }),
                      !hasExistingLink(range) else { continue }
                guard let fileLink = fileLinkURL(for: nsText.substring(with: range)) else { continue }
                markLink(range, url: fileLink)
                claimed.append(range)
            }
        }

        // NSAttributedString keeps AppKit keys (link, underline, NSColor).
        // SwiftUI font/background/intent would otherwise drop on the way back.
        var result = AttributedString(ns)
        for run in source.runs {
            let nsRange = NSRange(run.range, in: source)
            guard nsRange.length > 0, let range = Range(nsRange, in: result) else { continue }
            if let font = run.font {
                result[range].font = font
            }
            if let backgroundColor = run.backgroundColor {
                result[range].backgroundColor = backgroundColor
            }
            if let intent = run.inlinePresentationIntent {
                result[range].inlinePresentationIntent = intent
            }
            let addedLink = run.link == nil && result[range].link != nil
            if addedLink { continue }
            if let foregroundColor = run.foregroundColor {
                result[range].foregroundColor = foregroundColor
            }
        }
        return result
    }

    /// "https://x", "file:///x" parse directly; "www.x" and "localhost:3000" get a
    /// scheme prepended so the resulting `.link` URL is loadable.
    static func normalizedWebURL(_ token: String) -> URL? {
        let lower = token.lowercased()
        if lower.hasPrefix("www.") { return URL(string: "https://\(token)") }
        if lower.hasPrefix("localhost:") { return URL(string: "http://\(token)") }
        return URL(string: token)
    }

    /// Sentence punctuation glued to a match ("see /a/b.swift.") is not part of the
    /// token. A trailing ")" is kept only when the token contains its "(".
    private static func trimmingTrailingPunctuation(_ text: NSString, _ range: NSRange) -> NSRange {
        var length = range.length
        while length > 0 {
            let last = text.substring(with: NSRange(location: range.location + length - 1, length: 1))
            if ".,;:!?\"'".contains(last) {
                length -= 1
            } else if last == ")", !(text.substring(with: NSRange(location: range.location, length: length)).contains("(")) {
                length -= 1
            } else {
                break
            }
        }
        return NSRange(location: range.location, length: length)
    }

    /// IMP-010: Copies `text` to the system general pasteboard.
    /// Extracted as a static helper so it can be unit-tested independently of the SwiftUI view.
    @MainActor
    static func copyCodeToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }
        guard (1...6).contains(level),
              line.dropFirst(level).first == " " else { return nil }
        let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    enum ListMarker: Equatable { case bullet, numbered(Int) }

    /// Detect bullet (`- ` / `* ` / `+ `) or ordered (`1. ` / `1) `) list items, capturing
    /// the indentation level so nested lists render with hanging indent. Ordered lists were
    /// previously rendered as run-on paragraphs ("malformatted") — this fixes that.
    static func listItem(from rawLine: String) -> (indent: Int, marker: ListMarker, text: String)? {
        let leadingSpaces = rawLine.prefix { $0 == " " }.count
        let indent = min(leadingSpaces / 2, 4)
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        // Bullet
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : (indent, .bullet, String(text))
        }
        // Ordered: digits then '.' or ')' then a space.
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let afterDigits = line.dropFirst(digits.count)
            if let sep = afterDigits.first, sep == "." || sep == ")" {
                let rest = afterDigits.dropFirst()
                if rest.first == " " {
                    let text = rest.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty, let number = Int(digits) {
                        return (indent, .numbered(number), String(text))
                    }
                }
            }
        }
        return nil
    }
}

/// Copy-button chrome for a fenced code block. Hover/copied @State is local so
/// `AgentMessageMarkdownView` stays equatable on `text` and does not re-run
/// `blocks(from:)` when the pointer enters or leaves Copy.
struct CodeBlockCopyChrome: View {
    let text: String
    @State private var hovered = false
    @State private var copied = false
    @FocusState private var copyFocused: Bool

    /// Copy stays mounted so keyboard and VoiceOver reach it without a
    /// pointer; hover or keyboard focus only decides whether it is painted.
    nonisolated static func copyOpacity(hovered: Bool, focused: Bool) -> Double {
        hovered || focused ? 1 : 0
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AgentSelectablePlainText(
                text: text.isEmpty ? " " : text,
                fontSize: 11,
                monospaced: true,
                textColor: DS.NS.text
            )
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))

            Button(action: {
                AgentMessageMarkdown.copyCodeToPasteboard(text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    copied = false
                }
            }) {
                Text(copied ? "Copied" : "Copy")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, DS.Space.xxs)
                    .background(DS.Palette.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    // Fade the label, not the Button: a zero-opacity control
                    // can drop out of the accessibility tree.
                    .opacity(Self.copyOpacity(hovered: hovered, focused: copyFocused))
            }
            .buttonStyle(.plain)
            .focused($copyFocused)
            .accessibilityLabel(copied ? "Copied" : "Copy code")
            .accessibilityIdentifier("agent.codeBlock.copy")
            .help("Copy code to clipboard")
            .padding(DS.Space.sm)
        }
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.12)) {
                hovered = inside
            }
        }
    }
}

public struct AgentMessageMarkdownView: View, Equatable {
    let text: String
    var compact: Bool = false
    /// When false (live streaming rows), parse results are not inserted into NSCache
    /// so growing partial bodies cannot thrash occupancy (R4-B).
    var cacheResults: Bool = true

    public init(text: String, compact: Bool = false, cacheResults: Bool = true) {
        self.text = text
        self.compact = compact
        self.cacheResults = cacheResults
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.compact == rhs.compact && lhs.cacheResults == rhs.cacheResults
    }

    public var body: some View {
        let groups = AgentMessageMarkdown.selectionGroups(
            from: AgentMessageMarkdown.blocks(from: text, cache: cacheResults)
        )
        VStack(alignment: .leading, spacing: compact ? DS.Space.sm : DS.Space.md) {
            // Iterate the existing collection's indices instead of allocating an
            // enumerated Array on every SwiftUI body pass. Positional ids stay
            // because content-hash ids remount the live streaming group on every token.
            ForEach(groups.indices, id: \.self) { index in
                let group = groups[index]
                // Unary ForEach child (AvdLee list-patterns).
                Group {
                    if group.count == 1, let block = group.first, isIsolatedBlock(block) {
                        blockView(block)
                    } else {
                        // Perf CH-04: only the last group of a live row can still
                        // grow; earlier groups parse (and cache) like finished
                        // content so tokens do not re-parse stable paragraphs.
                        AgentLinkedAttributedText(
                            attributed: AgentMessageMarkdown.selectableProse(
                                from: group,
                                compact: compact,
                                cache: cacheResults || index < groups.count - 1
                            ),
                            font: .systemFont(ofSize: 13),
                            textColor: DS.NS.text,
                            lineFragmentPadding: 0,
                            lineSpacing: compact ? 3 : 5
                        )
                    }
                }
            }
        }
        // Selection lives inside AgentLinkedInlineText (NSTextView). Applying
        // SwiftUI `.textSelection` here would put an I-beam over the whole block
        // and hide the pointing-hand cursor on split-opening links.
    }

    private func isIsolatedBlock(_ block: AgentMessageMarkdownBlock) -> Bool {
        switch block.kind {
        case .code, .table: return true
        default: return false
        }
    }

    /// Inline markdown that opens Files/Browser splits on link click and shows
    /// the pointing-hand cursor over those links (AppKit NSTextView).
    @ViewBuilder
    private func linkedInline(
        _ source: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular,
        color: NSColor = DS.NS.text,
        lineSpacing: CGFloat = 5
    ) -> some View {
        AgentLinkedInlineText(
            text: source,
            fontSize: size,
            fontWeight: weight,
            textColor: color,
            lineSpacing: compact ? min(lineSpacing, 3) : lineSpacing,
            cacheResults: cacheResults
        )
    }

    @ViewBuilder
    private func blockView(_ block: AgentMessageMarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            linkedInline(block.text, lineSpacing: compact ? 3 : 5)
        case .heading(let level):
            linkedInline(block.text, size: headingSize(level), weight: .semibold, lineSpacing: 2)
                .padding(.top, compact ? 0 : DS.Space.xs)
        case .bullet(let indent):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 4, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .padding(.top, 6)
                linkedInline(block.text, lineSpacing: compact ? 3 : 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let number, let indent):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text("\(number).")
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.textSecondary)
                linkedInline(block.text, lineSpacing: compact ? 3 : 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .table(let headers, let rows):
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(headers.indices, id: \.self) { headerIndex in
                        let header = headers[headerIndex]
                        linkedInline(header, weight: .semibold, lineSpacing: 2)
                            .padding(.horizontal, DS.Space.sm)
                            .padding(.vertical, DS.Space.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(DS.Palette.surface)
                Divider()
                // Data rows
                ForEach(rows.indices, id: \.self) { rowIndex in
                    let row = rows[rowIndex]
                    HStack(spacing: 0) {
                        ForEach(row.indices, id: \.self) { colIndex in
                            let cell = row[colIndex]
                            linkedInline(cell, lineSpacing: 2)
                                .padding(.horizontal, DS.Space.sm)
                                .padding(.vertical, DS.Space.xs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if colIndex < row.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .background(rowIndex % 2 == 0 ? Color.clear : DS.Palette.surface.opacity(0.5))
                    if rowIndex < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))

        case .blockquote:
            HStack(alignment: .top, spacing: DS.Space.sm) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(DS.Palette.accent.opacity(0.5))
                    .frame(width: 3)
                linkedInline(block.text, color: DS.NS.textSecondary, lineSpacing: compact ? 3 : 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, DS.Space.xs)

        case .code:
            CodeBlockCopyChrome(text: block.text)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        if compact { return 13 }
        switch level {
        case 1: return 18
        case 2: return 15
        default: return 13
        }
    }
}

/// UX-MAC_AGENT-006: monospace diff preview for approval requests, colorizing
/// +/-/@@/header lines. Caps rendered lines so a large patch can't dominate.
struct DiffPreviewText: View {
    private let attributed: AttributedString

    init(_ diff: String, maxLines: Int = 200) {
        self.attributed = Self.render(diff, maxLines: maxLines)
    }

    var body: some View {
        AgentLinkedAttributedText(
            attributed: attributed,
            font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            textColor: DS.NS.text,
            lineFragmentPadding: 0,
            lineSpacing: 0
        )
    }

    private static func render(_ diff: String, maxLines: Int) -> AttributedString {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(maxLines)
        var out = AttributedString()
        for line in shown {
            var seg = AttributedString(String(line) + "\n")
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                seg.foregroundColor = DS.Palette.success
                seg.backgroundColor = DS.Palette.success.opacity(0.08)
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                seg.foregroundColor = DS.Palette.danger
                seg.backgroundColor = DS.Palette.danger.opacity(0.08)
            } else if line.hasPrefix("@@") {
                seg.foregroundColor = DS.Palette.accent
            } else if line.hasPrefix("diff --git") || line.hasPrefix("+++") || line.hasPrefix("---") {
                seg.foregroundColor = DS.Palette.warning
            } else {
                seg.foregroundColor = DS.Palette.textSecondary
            }
            out.append(seg)
        }
        if lines.count > maxLines {
            var more = AttributedString("… \(lines.count - maxLines) more lines")
            more.foregroundColor = DS.Palette.textSecondary
            out.append(more)
        }
        return out
    }
}

/// Cursor-style "Edit path" card with line numbers and red/green hunks.
struct AgentFileEditDiffCard: View {
    let model: AgentFileEditDiffPresentation.Model
    var initiallyExpanded: Bool = false
    @State private var expanded: Bool
    @State private var showAllLines = false

    init(
        model: AgentFileEditDiffPresentation.Model,
        initiallyExpanded: Bool = AgentWorkDisclosureLayout.diffDefaultExpanded
    ) {
        self.model = model
        self.initiallyExpanded = initiallyExpanded
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let visible = AgentWorkDisclosureLayout.visibleDiffLines(
            model.lines,
            isMeta: { $0.kind == .meta },
            showAll: showAllLines
        )
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Text("Edit")
                        .font(DS.Font.caption.weight(.semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                    if let path = model.path, !path.isEmpty {
                        AgentSelectablePlainText(
                            text: path,
                            fontSize: 11,
                            textColor: DS.NS.warning,
                            maximumNumberOfLines: 1
                        )
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                }
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide file edit diff" : "Show file edit diff")
            .accessibilityIdentifier("agent.fileEdit.header")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible.rows) { line in
                        diffLineRow(line)
                    }
                    if visible.hiddenCount > 0 {
                        Button {
                            showAllLines = true
                        } label: {
                            Text("Show \(visible.hiddenCount) more lines")
                                .font(DS.Font.caption2)
                                .foregroundColor(DS.Palette.accent)
                                .padding(.horizontal, DS.Space.sm)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent.fileEdit.showMore")
                    } else if model.hiddenLineCount > 0 {
                        Text("… \(model.hiddenLineCount) more lines truncated")
                            .font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textSecondary)
                            .padding(.horizontal, DS.Space.sm)
                            .padding(.vertical, 4)
                    }
                }
                .background(DS.Palette.surface)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .accessibilityIdentifier("agent.fileEdit.diff")
    }

    @ViewBuilder
    private func diffLineRow(_ line: AgentFileEditDiffPresentation.Line) -> some View {
        let bg: Color = {
            switch line.kind {
            case .addition: return DS.Palette.success.opacity(0.14)
            case .deletion: return DS.Palette.danger.opacity(0.16)
            case .hunk: return DS.Palette.accent.opacity(0.06)
            default: return Color.clear
            }
        }()
        let fg: Color = {
            switch line.kind {
            case .addition: return DS.Palette.success
            case .deletion: return DS.Palette.danger
            case .hunk: return DS.Palette.accent
            case .context: return DS.Palette.textSecondary
            case .meta: return DS.Palette.textTertiary
            }
        }()
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.displayLineNumber.map(String.init) ?? " ")
                .font(DS.Font.monoSmall.monospacedDigit())
                .foregroundColor(DS.Palette.textTertiary)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 8)
            Text(displayText(for: line))
                .font(DS.Font.monoSmall)
                .foregroundColor(fg)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.trailing, DS.Space.sm)
        .background(bg)
    }

    private func displayText(for line: AgentFileEditDiffPresentation.Line) -> String {
        switch line.kind {
        case .addition: return line.text.isEmpty ? " " : line.text
        case .deletion: return line.text.isEmpty ? " " : line.text
        case .hunk: return line.text
        case .context, .meta: return line.text.isEmpty ? " " : line.text
        }
    }
}
