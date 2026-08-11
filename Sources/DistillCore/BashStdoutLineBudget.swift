import Foundation
import CoreModel

/// T-TO-01: head/tail line budget for noisy bash/build/test stdout with recovery handle.
/// Exact-output commands are never routed here (CommandWrapPolicy passthrough).
public enum BashStdoutLineBudget: Sendable {
    /// Default hard line budget for terminal-to-agent compressible stdout.
    public static let defaultMaxLines = 80
    public static let defaultKeepLast = 16

    public struct Result: Sendable, Equatable {
        public let text: String
        public let applied: Bool
        public let originalLineCount: Int
        public let keptLineCount: Int

        public init(text: String, applied: Bool, originalLineCount: Int, keptLineCount: Int) {
            self.text = text
            self.applied = applied
            self.originalLineCount = originalLineCount
            self.keptLineCount = keptLineCount
        }
    }

    /// When stdout exceeds `maxLines`, keep first/last windows and cite the reversible handle.
    /// Callers MUST store-before-loss so `handle` recovers full bytes via `[[rc:<handle>]]`.
    public static func apply(
        _ input: String,
        handle: String,
        maxLines: Int = defaultMaxLines,
        keepLast: Int = defaultKeepLast
    ) -> Result {
        let lines = input.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let count = lines.count
        let cap = max(8, maxLines)
        let tail = max(2, min(keepLast, cap / 2))
        guard count > cap else {
            return Result(text: input, applied: false, originalLineCount: count, keptLineCount: count)
        }
        let headCount = max(1, cap - tail - 2)
        let head = lines.prefix(headCount).map(String.init)
        let last = lines.suffix(tail).map(String.init)
        let marker = SR2WirePolicy.recoveryMarker(for: handle)
        let elided = count - headCount - tail
        var out: [String] = []
        out.append(contentsOf: head)
        out.append("… [\(elided) lines elided; full stdout \(marker)] …")
        out.append(contentsOf: last)
        return Result(
            text: out.joined(separator: "\n"),
            applied: true,
            originalLineCount: count,
            keptLineCount: headCount + tail + 1
        )
    }
}
