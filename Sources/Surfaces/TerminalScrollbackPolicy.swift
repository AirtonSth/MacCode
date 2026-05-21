import CoreGraphics

enum TerminalScrollbackPolicy {
    static let bottomTolerance: CGFloat = 4

    static func shouldAutoScroll(
        visibleMaxY: CGFloat,
        documentHeight: CGFloat,
        tolerance: CGFloat = bottomTolerance
    ) -> Bool {
        guard visibleMaxY.isFinite, documentHeight.isFinite, tolerance.isFinite else { return true }
        guard documentHeight > 0 else { return true }
        return visibleMaxY >= documentHeight - max(0, tolerance)
    }
}
