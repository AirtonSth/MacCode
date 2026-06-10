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
    static func blocks(from text: String) -> [AgentMessageMarkdownBlock] {
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

    static func attributedInline(_ text: String) -> AttributedString {
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
        return attributed
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

struct AgentMessageMarkdownView: View {
    let text: String
    var compact: Bool = false

    /// IMP-010: tracks which code block (by enumeration offset) is hovered.
    @State private var hoveredCode: Int? = nil
    /// IMP-010: tracks which code block most recently had its copy action triggered,
    /// so the button can show transient "Copied" feedback.
    @State private var copiedCode: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? DS.Space.sm : DS.Space.md) {
            ForEach(Array(AgentMessageMarkdown.blocks(from: text).enumerated()), id: \.offset) { index, block in
                blockView(block, index: index)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: AgentMessageMarkdownBlock, index: Int) -> some View {
        switch block.kind {
        case .paragraph:
            Text(AgentMessageMarkdown.attributedInline(block.text))
                .font(DS.Font.body)
                .lineSpacing(compact ? 3 : 5)
        case .heading(let level):
            Text(AgentMessageMarkdown.attributedInline(block.text))
                .font(headingFont(level))
                .padding(.top, compact ? 0 : DS.Space.xs)
        case .bullet(let indent):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 4, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .padding(.top, 6)
                Text(AgentMessageMarkdown.attributedInline(block.text))
                    .font(DS.Font.body)
                    .lineSpacing(compact ? 3 : 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let number, let indent):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text("\(number).")
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.textSecondary)
                Text(AgentMessageMarkdown.attributedInline(block.text))
                    .font(DS.Font.body)
                    .lineSpacing(compact ? 3 : 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .table(let headers, let rows):
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(AgentMessageMarkdown.attributedInline(header))
                            .font(DS.Font.bodyStrong)
                            .padding(.horizontal, DS.Space.sm)
                            .padding(.vertical, DS.Space.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(DS.Palette.surface)
                Divider()
                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                            Text(AgentMessageMarkdown.attributedInline(cell))
                                .font(DS.Font.body)
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
                Text(AgentMessageMarkdown.attributedInline(block.text))
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineSpacing(compact ? 3 : 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, DS.Space.xs)

        case .code:
            // IMP-010: wrap code block in ZStack so a copy button can be
            // overlaid in the top-right corner without altering layout.
            ZStack(alignment: .topTrailing) {
                Text(block.text.isEmpty ? " " : block.text)
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.text)
                    .textSelection(.enabled)
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))

                // IMP-010: copy button — visible when this code block is hovered.
                if hoveredCode == index {
                    Button(action: {
                        AgentMessageMarkdown.copyCodeToPasteboard(block.text)
                        copiedCode = index
                        // Reset feedback after 1.2 s to match MarkdownSurface JS pattern.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if copiedCode == index { copiedCode = nil }
                        }
                    }) {
                        Text(copiedCode == index ? "Copied" : "Copy")
                            .font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textSecondary)
                            .padding(.horizontal, DS.Space.sm)
                            .padding(.vertical, DS.Space.xxs)
                            .background(DS.Palette.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    }
                    .buttonStyle(.plain)
                    .help("Copy code to clipboard")
                    .padding(DS.Space.sm)
                    .transition(.opacity)
                }
            }
            .onHover { inside in
                withAnimation(.easeInOut(duration: 0.12)) {
                    hoveredCode = inside ? index : nil
                }
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return compact ? DS.Font.bodyStrong : DS.Font.title2
        case 2: return compact ? DS.Font.bodyStrong : DS.Font.title3
        default: return DS.Font.bodyStrong
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
        Text(attributed)
            .font(DS.Font.monoSmall)
            .textSelection(.enabled)
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
            more.foregroundColor = DS.Palette.textTertiary
            out.append(more)
        }
        return out
    }
}
