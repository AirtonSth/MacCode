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
