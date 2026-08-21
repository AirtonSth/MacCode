import Foundation
import CoreModel

/// Splits one agent turn into chronological segments around interleaved chat
/// rows (bot peer replies, waiting indicators) so the transcript reads like a
/// real chat: every update appends in arrival order instead of the whole turn
/// repainting above messages that arrived mid-run.
///
/// Anti-disorder rules:
/// - Items are NEVER re-sorted: slices are contiguous cuts of the turn's
///   append-order `items`, with per-item times clamped monotonically so an
///   out-of-order timestamp can not move an item above a predecessor.
/// - The turn head always paints first: a boundary earlier than the first item
///   still cuts at index ≥ 1, matching the outer entry order (turn row before
///   its following messages).
/// - Message rows keep their relative order; a row that must not interleave
///   ends boundary collection and paints after the last segment, in order.
public enum AgentChatTurnSegmentation {
    /// One contiguous slice of a turn, painted as its own chat row.
    public struct TurnSegment: Equatable, Sendable {
        /// Synthetic copy of the turn: `items` is the slice; only the last
        /// segment keeps `finalAssistantMessage`. `turnId` is preserved so
        /// plan/token-saver lookups keyed by turn keep working.
        public let snapshot: AssistantTurnSnapshot
        public let firstItemId: String
        public let isFirst: Bool
        public let isLast: Bool

        public init(
            snapshot: AssistantTurnSnapshot,
            firstItemId: String,
            isFirst: Bool,
            isLast: Bool
        ) {
            self.snapshot = snapshot
            self.firstItemId = firstItemId
            self.isFirst = isFirst
            self.isLast = isLast
        }

        /// Stable list identity. The first segment keeps the plain turn row id
        /// so the head of a turn does not remount when its first boundary
        /// arrives; later segments key on their first item.
        public var rowId: String {
            isFirst ? "turn-\(snapshot.turnId)" : "turnseg-\(snapshot.turnId)-\(firstItemId)"
        }
    }

    /// A chat row that follows a turn in paint order.
    public struct FollowingRow<Row> {
        public let timeMs: Int64
        public let canInterleave: Bool
        public let row: Row

        public init(timeMs: Int64, canInterleave: Bool, row: Row) {
            self.timeMs = timeMs
            self.canInterleave = canInterleave
            self.row = row
        }
    }

    public enum WeaveElement<Row> {
        case segment(TurnSegment)
        case row(Row)
    }

    /// Non-decreasing copy of `times`: each value is clamped to at least its
    /// predecessor so out-of-order stamps can not reorder append-order content.
    public static func effectiveMonotonicTimes(_ times: [Int64]) -> [Int64] {
        var out: [Int64] = []
        out.reserveCapacity(times.count)
        var current = Int64.min
        for time in times {
            current = max(current, time)
            out.append(current)
        }
        return out
    }

    /// Cut indices into `itemTimesMs` (append order), one per boundary.
    /// `cuts[k]` is the index of the first item that paints AFTER boundary k.
    /// Cuts are non-decreasing and, when items exist, at least 1 (turn head
    /// always paints before any following row).
    public static func segmentCuts(
        itemTimesMs: [Int64],
        boundaryTimesMs: [Int64]
    ) -> [Int] {
        guard !itemTimesMs.isEmpty else {
            return Array(repeating: 0, count: boundaryTimesMs.count)
        }
        let effective = effectiveMonotonicTimes(itemTimesMs)
        var cuts: [Int] = []
        cuts.reserveCapacity(boundaryTimesMs.count)
        var itemIndex = 0
        var boundaryTime = Int64.min
        for time in boundaryTimesMs {
            boundaryTime = max(boundaryTime, time)
            while itemIndex < effective.count && effective[itemIndex] <= boundaryTime {
                itemIndex += 1
            }
            cuts.append(max(itemIndex, 1))
        }
        return cuts
    }

    /// Weaves one turn with the rows that follow it in paint order.
    ///
    /// Boundaries are the longest prefix of `following` with `canInterleave`;
    /// the first row that can not interleave ends collection, and it plus every
    /// later row paint after the last segment in their original order.
    ///
    /// Returns nil when nothing actually interleaves (no boundary cuts inside
    /// the item list) so the caller keeps its original single-turn row and
    /// existing identities/behavior stay untouched.
    public static func interleaved<Row>(
        turn: AssistantTurnSnapshot,
        following: [FollowingRow<Row>]
    ) -> [WeaveElement<Row>]? {
        guard !turn.items.isEmpty else { return nil }
        var boundaryCount = 0
        while boundaryCount < following.count && following[boundaryCount].canInterleave {
            boundaryCount += 1
        }
        guard boundaryCount > 0 else { return nil }
        let cuts = segmentCuts(
            itemTimesMs: turn.items.map(\.startedAtMs),
            boundaryTimesMs: following.prefix(boundaryCount).map(\.timeMs)
        )
        guard cuts.contains(where: { $0 < turn.items.count }) else { return nil }

        // Slice ranges: before boundary 0, between boundaries, after the last.
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(cuts.count + 1)
        var start = 0
        for cut in cuts {
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<turn.items.count)

        let nonEmpty = ranges.enumerated().filter { !$0.element.isEmpty }
        guard let firstIndex = nonEmpty.first?.offset,
              let lastIndex = nonEmpty.last?.offset else { return nil }

        var out: [WeaveElement<Row>] = []
        out.reserveCapacity(ranges.count + following.count)
        for (index, range) in ranges.enumerated() {
            if !range.isEmpty {
                let slice = Array(turn.items[range])
                let isFirst = index == firstIndex
                let isLast = index == lastIndex
                var snapshot = turn
                snapshot.items = slice
                if !isLast { snapshot.finalAssistantMessage = nil }
                snapshot.startedAtMs = slice.first?.startedAtMs ?? turn.startedAtMs
                out.append(.segment(TurnSegment(
                    snapshot: snapshot,
                    firstItemId: slice.first?.id ?? "",
                    isFirst: isFirst,
                    isLast: isLast
                )))
            }
            if index < boundaryCount {
                out.append(.row(following[index].row))
            }
        }
        for trailing in following[boundaryCount...] {
            out.append(.row(trailing.row))
        }
        return out
    }
}
