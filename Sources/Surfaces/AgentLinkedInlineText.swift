import AppKit
import SwiftUI
import DesignSystemKit

// MARK: - Pointing-hand cursor for split-opening controls

extension View {
    /// Show the pointing-hand cursor while the pointer is over this control.
    ///
    /// WHY: SwiftUI `.plain` buttons keep the default arrow on macOS 14. AppKit
    /// cursor rects need hit-testing, so a transparent overlay steals clicks;
    /// `NSCursor.push/pop` on hover matches Pet / Ghostty patterns and does not
    /// intercept mouse-down. Use only on discrete controls (not large text blocks).
    func dsPointingHandCursor() -> some View {
        modifier(DSPointingHandCursorModifier())
    }
}

private struct DSPointingHandCursorModifier: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                guard !pushed else { return }
                NSCursor.pointingHand.push()
                pushed = true
            } else if pushed {
                NSCursor.pop()
                pushed = false
            }
        }
        .onDisappear {
            if pushed {
                NSCursor.pop()
                pushed = false
            }
        }
    }
}

// MARK: - Selectable linked transcript text (AppKit)

/// Selectable attributed transcript text where **link runs use the pointing-hand cursor**.
///
/// WHY: SwiftUI `Text(AttributedString)` + `.textSelection(.enabled)` renders
/// `.link` runs with accent color/underline but keeps the I-beam over them on
/// macOS 14. AppKit `NSTextView.linkTextAttributes` defaults include
/// `NSCursor.pointingHand` (Apple docs) and `textView(_:clickedOnLink:at:)` routes
/// clicks through the same `openURL` environment used for open-in-split.
struct AgentLinkedInlineText: View {
    let text: String
    var fontSize: CGFloat = 13
    var fontWeight: NSFont.Weight = .regular
    var monospaced: Bool = false
    var textColor: NSColor = DS.NS.text
    var lineFragmentPadding: CGFloat = 0
    /// Extra spacing between lines (points), matching SwiftUI `.lineSpacing`.
    var lineSpacing: CGFloat = 0
    /// When false, skip NSCache store for live streaming partials (R4-B).
    var cacheResults: Bool = true

    var body: some View {
        AgentLinkedAttributedText(
            attributed: AgentMessageMarkdown.attributedInline(text, cache: cacheResults),
            font: Self.nsFont(size: fontSize, weight: fontWeight, monospaced: monospaced),
            textColor: textColor,
            lineFragmentPadding: lineFragmentPadding,
            lineSpacing: lineSpacing
        )
    }

    static func nsFont(size: CGFloat, weight: NSFont.Weight, monospaced: Bool) -> NSFont {
        if monospaced {
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
}

struct AgentSelectablePlainText: View {
    let text: String
    var fontSize: CGFloat = 13
    var textColor: NSColor = DS.NS.text
    var lineSpacing: CGFloat = 0
    var maximumNumberOfLines: Int? = nil

    var body: some View {
        AgentLinkedAttributedText(
            attributed: AttributedString(text),
            font: .systemFont(ofSize: fontSize),
            textColor: textColor,
            lineFragmentPadding: 0,
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines
        )
    }
}

struct AgentLinkedAttributedText: View {
    let attributed: AttributedString
    let font: NSFont
    let textColor: NSColor
    let lineFragmentPadding: CGFloat
    let lineSpacing: CGFloat
    var maximumNumberOfLines: Int? = nil

    @Environment(\.openURL) private var openURL

    var body: some View {
        AgentLinkedInlineTextRepresentable(
            attributed: attributed,
            font: font,
            textColor: textColor,
            lineFragmentPadding: lineFragmentPadding,
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines,
            openURL: openURL
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Last presentation applied to an `NSTextView` for a linked transcript cell.
///
/// WHY: SwiftUI re-calls `updateNSView` for every parent body refresh (e.g. one
/// streaming token). Rebuilding `NSAttributedString` for every stable older row
/// saturates the main thread. Cache the full semantic presentation so equal
/// rows skip conversion and layout; plain-string fingerprints are insufficient
/// because identical characters can carry different link destinations.
struct AgentLinkedInlineTextAppliedState {
    let attributed: AttributedString
    let font: NSFont
    let textColor: NSColor
    let lineSpacing: CGFloat
    let maximumNumberOfLines: Int?
    let lineFragmentPadding: CGFloat
}

/// Pure dirty-flag plan for transcript text updates (test seam).
struct AgentLinkedInlineTextUpdatePlan: Equatable {
    let storageDirty: Bool
    let heightDirty: Bool
    let maximumNumberOfLinesDirty: Bool
    let lineFragmentPaddingDirty: Bool

    var isNoOp: Bool {
        !storageDirty && !heightDirty && !maximumNumberOfLinesDirty && !lineFragmentPaddingDirty
    }

    /// Compare previous applied state to the next presentation.
    ///
    /// - storageDirty: rebuild attributed storage (text, font, color, line spacing).
    /// - heightDirty: intrinsic height / layout may change (not color-only).
    static func make(
        previous: AgentLinkedInlineTextAppliedState?,
        next: AgentLinkedInlineTextAppliedState
    ) -> AgentLinkedInlineTextUpdatePlan {
        guard let previous else {
            return AgentLinkedInlineTextUpdatePlan(
                storageDirty: true,
                heightDirty: true,
                maximumNumberOfLinesDirty: true,
                lineFragmentPaddingDirty: true
            )
        }
        let attributedChanged = previous.attributed != next.attributed
        let fontChanged = !previous.font.isEqual(next.font)
        let textColorChanged = !previous.textColor.isEqual(next.textColor)
        let lineSpacingChanged = previous.lineSpacing != next.lineSpacing
        let maximumLinesChanged = previous.maximumNumberOfLines != next.maximumNumberOfLines
        let paddingChanged = previous.lineFragmentPadding != next.lineFragmentPadding
        return AgentLinkedInlineTextUpdatePlan(
            storageDirty: attributedChanged || fontChanged || textColorChanged || lineSpacingChanged,
            heightDirty: attributedChanged || fontChanged || lineSpacingChanged
                || maximumLinesChanged || paddingChanged,
            maximumNumberOfLinesDirty: maximumLinesChanged,
            lineFragmentPaddingDirty: paddingChanged
        )
    }
}

/// Internal so unit tests can assert link runs carry pointingHand after conversion.
struct AgentLinkedInlineTextRepresentable: NSViewRepresentable {
    let attributed: AttributedString
    let font: NSFont
    let textColor: NSColor
    let lineFragmentPadding: CGFloat
    let lineSpacing: CGFloat
    var maximumNumberOfLines: Int? = nil
    let openURL: OpenURLAction

    func makeCoordinator() -> Coordinator {
        Coordinator(openURL: openURL)
    }

    func makeNSView(context: Context) -> IntrinsicHeightTextView {
        let tv = IntrinsicHeightTextView(usingTextLayoutManager: false)
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.allowsUndo = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = lineFragmentPadding
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(
            width: 10_000,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.minSize = .zero
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        // Apple: default linkTextAttributes are blue + underline + pointing hand.
        // Keep pointing hand even when we restyle color to the DS accent.
        tv.linkTextAttributes = [
            .foregroundColor: DS.NS.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        apply(to: tv, context: context)
        return tv
    }

    func updateNSView(_ tv: IntrinsicHeightTextView, context: Context) {
        // Always refresh routing even when presentation is unchanged.
        context.coordinator.openURL = openURL
        context.coordinator.textView = tv
        apply(to: tv, context: context)
    }

    private func apply(to tv: IntrinsicHeightTextView, context: Context) {
        let next = AgentLinkedInlineTextAppliedState(
            attributed: attributed,
            font: font,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines,
            lineFragmentPadding: lineFragmentPadding
        )
        let plan = AgentLinkedInlineTextUpdatePlan.make(
            previous: context.coordinator.applied,
            next: next
        )
        // WHY: Parent transcript refreshes re-enter updateNSView for every
        // mounted row. Skip conversion/layout when the cell is semantically
        // identical so only the actively streaming row pays rebuild cost.
        guard !plan.isNoOp else { return }

        if plan.maximumNumberOfLinesDirty {
            tv.textContainer?.maximumNumberOfLines = maximumNumberOfLines ?? 0
            tv.textContainer?.lineBreakMode = maximumNumberOfLines == nil
                ? .byWordWrapping
                : .byTruncatingTail
        }
        if plan.lineFragmentPaddingDirty {
            tv.textContainer?.lineFragmentPadding = lineFragmentPadding
        }
        if plan.storageDirty {
            let ns = Self.makeNSAttributedString(
                attributed: attributed,
                font: font,
                textColor: textColor,
                lineSpacing: lineSpacing
            )
            Self.applyTextStorage(ns, to: tv)
            tv.font = font
            tv.textColor = textColor
        }
        if plan.heightDirty {
            tv.invalidateIntrinsicContentSize()
            tv.needsLayout = true
        }
        context.coordinator.applied = next
    }

    static func applyTextStorage(_ next: NSAttributedString, to textView: NSTextView) {
        guard textView.textStorage?.isEqual(to: next) != true else { return }
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(next)
        let location = min(selection.location, next.length)
        let length = min(selection.length, next.length - location)
        textView.setSelectedRange(NSRange(location: location, length: length))
    }

    static func makeNSAttributedString(
        attributed: AttributedString,
        font: NSFont,
        textColor: NSColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let base = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let full = NSRange(location: 0, length: base.length)
        if full.length > 0 {
            // Apply base typography without clobbering existing link attributes.
            base.enumerateAttributes(in: full, options: []) { attrs, range, _ in
                var next = attrs
                if next[.font] == nil {
                    next[.font] = font
                }
                if next[.foregroundColor] == nil, next[.link] == nil {
                    next[.foregroundColor] = textColor
                }
                if lineSpacing > 0 {
                    let para = (next[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                        ?? NSMutableParagraphStyle()
                    para.lineSpacing = lineSpacing
                    next[.paragraphStyle] = para
                }
                // Ensure every link run carries the pointing-hand cursor attribute
                // even if conversion dropped temporary link attributes.
                if next[.link] != nil {
                    next[.cursor] = NSCursor.pointingHand
                    next[.foregroundColor] = DS.NS.accent
                    next[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                base.setAttributes(next, range: range)
            }
        }
        return base
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction
        weak var textView: NSTextView?
        /// Last presentation successfully applied to this view's storage/layout.
        var applied: AgentLinkedInlineTextAppliedState?

        init(openURL: OpenURLAction) {
            self.openURL = openURL
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let u = link as? URL {
                url = u
            } else if let s = link as? String {
                url = URL(string: s)
            } else {
                url = nil
            }
            guard let url else { return false }
            // Route through the same OpenURLAction as SwiftUI Text links so
            // AgentAppView's open-in-split handler stays in charge.
            _ = openURL(url)
            return true
        }
    }
}

/// NSTextView that reports vertical intrinsic size for SwiftUI layout.
final class IntrinsicHeightTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let height = max(ceil(used.height + textContainerInset.height * 2), font?.boundingRectForFont.height ?? 14)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, let textContainer else { return }
        let target = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if abs(textContainer.containerSize.width - width) > 0.5 {
            textContainer.containerSize = target
            invalidateIntrinsicContentSize()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
}
