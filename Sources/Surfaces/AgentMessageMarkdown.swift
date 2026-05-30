import Foundation
import SwiftUI
import DesignSystemKit

struct AgentMessageMarkdownBlock: Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case bullet
        case code(language: String)
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

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(AgentMessageMarkdownBlock(kind: .paragraph, text: paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if inFence {
                if trimmed.hasPrefix("```") {
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
                flushParagraph()
                inFence = true
                fenceLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(AgentMessageMarkdownBlock(kind: .heading(heading.level), text: heading.text))
                continue
            }

            if let bullet = bulletText(from: trimmed) {
                flushParagraph()
                blocks.append(AgentMessageMarkdownBlock(kind: .bullet, text: bullet))
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

    private static func bulletText(from line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text)
    }
}

struct AgentMessageMarkdownView: View {
    let text: String
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? DS.Space.sm : DS.Space.md) {
            ForEach(Array(AgentMessageMarkdown.blocks(from: text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: AgentMessageMarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            Text(AgentMessageMarkdown.attributedInline(block.text))
                .font(DS.Font.body)
                .lineSpacing(compact ? 3 : 5)
        case .heading(let level):
            Text(AgentMessageMarkdown.attributedInline(block.text))
                .font(headingFont(level))
                .padding(.top, compact ? 0 : DS.Space.xs)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 4, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                Text(AgentMessageMarkdown.attributedInline(block.text))
                    .font(DS.Font.body)
                    .lineSpacing(compact ? 3 : 5)
            }
        case .code:
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
