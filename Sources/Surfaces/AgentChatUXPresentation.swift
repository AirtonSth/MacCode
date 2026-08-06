import Foundation
import CoreModel

// MARK: - System status strip (severity-ordered, capped)

/// Severity for the unified system strip above the composer.
/// Higher raw value wins when collapsing overflow.
public enum AgentSystemStripSeverity: Int, Sendable, Comparable, Equatable {
    case info = 0
    case warning = 1
    case error = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One dismissible/actionable status row candidate before collapse.
public struct AgentSystemStripItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let severity: AgentSystemStripSeverity
    public let message: String
    public let offersCopy: Bool
    public let offersRetry: Bool
    public let offersDismiss: Bool

    public init(
        id: String,
        severity: AgentSystemStripSeverity,
        message: String,
        offersCopy: Bool = true,
        offersRetry: Bool = false,
        offersDismiss: Bool = true
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.offersCopy = offersCopy
        self.offersRetry = offersRetry
        self.offersDismiss = offersDismiss
    }
}

/// Pure collapse for stacked banners → single strip.
/// WHY: stacked history/status/snapshot/queue banners compete for attention and
/// re-layout the composer; collapse keeps errors first and caps visible rows.
public enum AgentSystemStripPresentation {
    public static let defaultMaxVisible = 2

    public static func collapse(
        _ items: [AgentSystemStripItem],
        maxVisible: Int = defaultMaxVisible
    ) -> (visible: [AgentSystemStripItem], overflowCount: Int) {
        let cleaned = items.filter {
            !$0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Stable sort: severity desc, then original order.
        let ranked = cleaned.enumerated().sorted { a, b in
            if a.element.severity != b.element.severity {
                return a.element.severity > b.element.severity
            }
            return a.offset < b.offset
        }.map(\.element)
        let cap = max(1, maxVisible)
        if ranked.count <= cap {
            return (ranked, 0)
        }
        return (Array(ranked.prefix(cap)), ranked.count - cap)
    }

    /// Build candidates from the classic Agent column banner sources.
    public static func items(
        historyReplayNotice: String?,
        statusMessage: String?,
        providerSnapshotStatus: String?,
        standaloneQueueStatus: String?
    ) -> [AgentSystemStripItem] {
        var out: [AgentSystemStripItem] = []
        if let message = normalized(historyReplayNotice) {
            out.append(AgentSystemStripItem(
                id: "agent.history.replay.notice",
                severity: .info,
                message: message,
                offersCopy: false,
                offersRetry: false
            ))
        }
        if let message = normalized(statusMessage) {
            let isFailure = message.localizedCaseInsensitiveContains("fail")
                || message.localizedCaseInsensitiveContains("error")
            out.append(AgentSystemStripItem(
                id: "agent.status.message",
                severity: isFailure ? .error : .warning,
                message: message,
                offersCopy: true,
                offersRetry: false
            ))
        }
        if let message = normalized(providerSnapshotStatus) {
            out.append(AgentSystemStripItem(
                id: "agent.provider.snapshot.stale",
                severity: .warning,
                message: message,
                offersCopy: true,
                offersRetry: true
            ))
        }
        if let message = normalized(standaloneQueueStatus) {
            let isFailure = message.localizedCaseInsensitiveContains("fail")
            out.append(AgentSystemStripItem(
                id: "agent.queue.status",
                severity: isFailure ? .error : .warning,
                message: message,
                offersCopy: true,
                offersRetry: true
            ))
        }
        return out
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Working phase strip

public enum AgentWorkingPhase: Sendable, Equatable {
    case idle
    case thinking
    case tools
    case awaitingBackground
    case subagents(Int)

    public var accessibilityLabel: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .tools: return "Running tools"
        case .awaitingBackground: return "Awaiting background work"
        case .subagents(let n): return n == 1 ? "1 subagent active" : "\(n) subagents active"
        }
    }
}

/// Pure working-phase resolution for the unified header strip.
/// WHY: separate status/awaiting/shells/subagent pills duplicate signal; one phase
/// + optional elapsed is enough for run awareness without chrome noise.
public enum AgentWorkingStripPresentation {
    public static func phase(
        runIsLive: Bool,
        isAwaitingBackground: Bool,
        backgroundShellCount: Int,
        activeSubagentCount: Int,
        hasStreamingTools: Bool
    ) -> AgentWorkingPhase {
        if isAwaitingBackground || backgroundShellCount > 0 {
            return .awaitingBackground
        }
        if activeSubagentCount > 0 {
            return .subagents(activeSubagentCount)
        }
        if runIsLive {
            return hasStreamingTools ? .tools : .thinking
        }
        return .idle
    }

    public static func label(
        phase: AgentWorkingPhase,
        elapsedSeconds: Int?
    ) -> String? {
        let base: String
        switch phase {
        case .idle:
            return nil
        case .thinking:
            base = "Thinking"
        case .tools:
            base = "Tools"
        case .awaitingBackground:
            base = "Awaiting"
        case .subagents(let n):
            base = n == 1 ? "1 subagent" : "\(n) subagents"
        }
        guard let elapsedSeconds, elapsedSeconds > 0 else { return base }
        return "\(base) · \(formatElapsed(elapsedSeconds))"
    }

    public static func formatElapsed(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        if m < 60 { return r == 0 ? "\(m)m" : "\(m)m \(r)s" }
        let h = m / 60
        let rm = m % 60
        return rm == 0 ? "\(h)h" : "\(h)h \(rm)m"
    }
}

// MARK: - Cat working strip (pet parity)

/// Rotating kitten activity verbs for the in-flight "… for Ns" strip.
///
/// WHY: Remote Code's pet is a cat — long runs feel friendlier when the
/// working line cycles through cat-like activities instead of a static
/// "Working for". Phrase is pure English; rotation is deterministic from
/// elapsed seconds (no extra timers, no locale).
public enum AgentWorkingCatCopy {
    /// Seconds each activity stays on screen before the next.
    public static let rotationSeconds: Int = 15

    /// 100 English cat activities (gerund / short phrase). Order is stable —
    /// index is `elapsed / rotationSeconds % count`.
    public static let activities: [String] = [
        "Working",
        "Scratching the Sofa",
        "Hunting Mice",
        "Eating Kibble",
        "Sleeping",
        "Purring",
        "Kneading the Blanket",
        "Chasing Laser Dots",
        "Staring Out the Window",
        "Knocking Pens Off the Desk",
        "Zooming Down the Hall",
        "Guarding the Cardboard Box",
        "Napping on the Keyboard",
        "Batting Yarn Balls",
        "Climbing the Cat Tree",
        "Hiding Under the Bed",
        "Watching Birds",
        "Grooming Fur",
        "Stretching in a Sunbeam",
        "Meowing at the Fridge",
        "Claiming the Warm Laptop",
        "Pouncing on Dust Bunnies",
        "Investigating the Grocery Bag",
        "Sitting in the Empty Sink",
        "Loafing on the Couch",
        "Chirping at Squirrels",
        "Stealing the Warm Seat",
        "Batting Cap Lids",
        "Inspecting the Suitcase",
        "Rolling on the Rug",
        "Headbutting the Monitor",
        "Snoozing on Clean Laundry",
        "Chasing the Red Dot",
        "Perching on the Fridge",
        "Burying Treats",
        "Patrolling the Bookshelf",
        "Licking a Paw",
        "Fluffing the Cat Bed",
        "Stalking Socks",
        "Hiding in the Closet",
        "Scratching the Post",
        "Blinking Slowly",
        "Begging for Tuna",
        "Sitting on Open Mail",
        "Chasing Tail",
        "Guarding the Doorway",
        "Sniffing the Shoes",
        "Curling Up in a Circle",
        "Watching the Fish Tank",
        "Pawing the Curtain",
        "Napping in a Box",
        "Meowing at 3 AM",
        "Claiming the Windowsill",
        "Batting Ice Cubes",
        "Investigating the Trash",
        "Stretching Like a Yawn",
        "Sitting on the Newspaper",
        "Chasing Shadows",
        "Grooming Whiskers",
        "Loafing on the Desk",
        "Hunting Crumbs",
        "Purring on the Lap",
        "Zooming at Midnight",
        "Knocking Over Cups",
        "Staring at Nothing",
        "Claiming the Suitcase",
        "Batting Phone Cords",
        "Sleeping on the Router",
        "Patrolling the Counter",
        "Sniffing the Delivery Box",
        "Kneading a Sweater",
        "Chirping at Bugs",
        "Guarding the Food Bowl",
        "Rolling in Catnip",
        "Climbing the Drapes",
        "Hiding Behind the Curtain",
        "Watching Raindrops",
        "Pouncing on Toes",
        "Sitting in the Laundry Basket",
        "Meowing for Attention",
        "Napping on the Printer",
        "Batting Hair Ties",
        "Inspecting the Keyboard",
        "Stealing the Armchair",
        "Chasing Moths",
        "Stretching on the Carpet",
        "Loafing by the Heater",
        "Hunting String",
        "Purring on the Pillow",
        "Knocking Down Magnets",
        "Claiming the Scanner Tray",
        "Staring Into the Void",
        "Grooming After Dinner",
        "Zooming Across Tiles",
        "Batting Bottle Caps",
        "Sleeping on the Charger",
        "Guarding the Mousepad",
        "Sniffing the Coffee Cup",
        "Kneading the Cushion",
        "Watching the Cursor",
    ]

    /// Activity phrase for the current elapsed window (no " for" suffix).
    public static func activity(
        elapsedSeconds: Int,
        activities: [String] = activities,
        rotationSeconds: Int = rotationSeconds
    ) -> String {
        let list = activities.isEmpty ? ["Working"] : activities
        let period = max(1, rotationSeconds)
        let index = max(0, elapsedSeconds) / period % list.count
        return list[index]
    }

    /// Display line: `"Purring for 20m 3s"`.
    public static func statusLabel(
        elapsedSeconds: Int,
        activities: [String] = activities,
        rotationSeconds: Int = rotationSeconds
    ) -> String {
        let phrase = activity(
            elapsedSeconds: elapsedSeconds,
            activities: activities,
            rotationSeconds: rotationSeconds
        )
        return "\(phrase) for \(AgentWorkingStripPresentation.formatElapsed(elapsedSeconds))"
    }

    /// Stable VoiceOver / UITest label so assistive tech and tests still hear
    /// "Working for …" while the visible line rotates cat activities.
    public static func accessibilityLabel(elapsedSeconds: Int) -> String {
        "Working for \(AgentWorkingStripPresentation.formatElapsed(elapsedSeconds))"
    }
}

// MARK: - Composer chrome Simple / Power

public enum AgentComposerChromeMode: String, Sendable, Equatable, CaseIterable {
    case simple
    case power

    public mutating func toggle() {
        self = self == .simple ? .power : .simple
    }
}

public enum AgentComposerChromeControl: String, Sendable, Equatable, CaseIterable {
    case attach
    case model
    case sendStop
    case source
    case permission
    case execution
    case runAsUser
    case effort
}

/// Pure control visibility for composer Simple vs Power chrome.
/// macOS Agent App always paints `.power` (no collapse toggle). The simple set
/// remains for unit tests and any non-macOS caller that still densifies.
public enum AgentComposerChromePresentation {
    public static func controls(for mode: AgentComposerChromeMode) -> Set<AgentComposerChromeControl> {
        switch mode {
        case .simple:
            return [.attach, .model, .sendStop]
        case .power:
            return Set(AgentComposerChromeControl.allCases)
        }
    }

    public static func shows(_ control: AgentComposerChromeControl, mode: AgentComposerChromeMode) -> Bool {
        controls(for: mode).contains(control)
    }
}

// MARK: - Completed work density (perf)

/// Pure gate: whether finished-turn work blocks must be fully built.
/// WHY: stream ticks must not allocate tool groups when the disclosure is collapsed.
public enum AgentCompletedWorkPresentation {
    public static func shouldBuildBlocks(expandCompletedWork: Bool, workItemCount: Int) -> Bool {
        expandCompletedWork && workItemCount > 0
    }

    public static func collapsedLabel(workBlockCount: Int, durationText: String?) -> String {
        if let durationText, !durationText.isEmpty {
            return "Worked for \(durationText)"
        }
        if workBlockCount <= 0 { return "Worked" }
        return workBlockCount == 1 ? "Worked · 1 step" : "Worked · \(workBlockCount) steps"
    }
}

// MARK: - Transcript order (anti-disorder)

/// Stable total order for chat rows. Used by merge, paint window, and Lazy lists.
/// Order key: (sortTime ascending, id ascending). Rematerialization MUST preserve
/// the id sequence from the last structural merge — never re-sort by live payloads.
public enum AgentTranscriptOrder {
    public static func ordersBefore(
        lhsTime: TimeInterval,
        lhsId: String,
        rhsTime: TimeInterval,
        rhsId: String
    ) -> Bool {
        if lhsTime == rhsTime { return lhsId < rhsId }
        return lhsTime < rhsTime
    }

    /// True when each adjacent pair is non-decreasing under the total order.
    public static func isOrdered(
        times: [TimeInterval],
        ids: [String]
    ) -> Bool {
        guard times.count == ids.count, times.count > 1 else { return true }
        for i in 1..<times.count {
            if ordersBefore(
                lhsTime: times[i],
                lhsId: ids[i],
                rhsTime: times[i - 1],
                rhsId: ids[i - 1]
            ) {
                return false
            }
        }
        return true
    }

    /// Returns `entries` unchanged when already ordered; otherwise a fully sorted copy.
    public static func ensuringOrdered<T>(
        _ entries: [T],
        time: (T) -> TimeInterval,
        id: (T) -> String
    ) -> [T] {
        guard entries.count > 1 else { return entries }
        let times = entries.map(time)
        let ids = entries.map(id)
        if isOrdered(times: times, ids: ids) { return entries }
        return entries.sorted {
            ordersBefore(lhsTime: time($0), lhsId: id($0), rhsTime: time($1), rhsId: id($1))
        }
    }

    /// Rematerialize payloads by id map while **preserving** `orderedIds` sequence.
    /// Unknown ids are dropped (never inserted mid-list) so Lazy identity stays stable.
    public static func rematerializePreservingOrder<T>(
        orderedIds: [String],
        payloadsById: [String: T]
    ) -> [T] {
        var out: [T] = []
        out.reserveCapacity(orderedIds.count)
        for id in orderedIds {
            if let payload = payloadsById[id] {
                out.append(payload)
            }
        }
        return out
    }

    /// Chat rule: **Work so far** (turn row) → **final answer** (persisted assistant message).
    ///
    /// On open/hydration a durable assistant message can sort *before* its turn when
    /// `message.createdAt` is earlier than the turn's first-item sort anchor. That paints
    /// the long final answer above the "Work so far · N steps" disclosure. Move each
    /// matching assistant message to immediately after its turn so order stays stable.
    ///
    /// - Messages that already sit after their turn are left alone.
    /// - Prefer the **last** matching turn when several finals collide on text.
    public static func placingMatchingFinalsAfterTurns<Entry>(
        _ entries: [Entry],
        turnFinalText: (Entry) -> String?,
        assistantMessageText: (Entry) -> String?,
        textsMatch: (String, String) -> Bool
    ) -> [Entry] {
        guard entries.count > 1 else { return entries }

        var turnFinals: [(index: Int, final: String)] = []
        turnFinals.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            if let final = turnFinalText(entry)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !final.isEmpty {
                turnFinals.append((index, final))
            }
        }
        guard !turnFinals.isEmpty else { return entries }

        // messageIndex → turnIndex to insert after
        var moveAfterTurn: [Int: Int] = [:]
        for (index, entry) in entries.enumerated() {
            guard let text = assistantMessageText(entry)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            guard let match = turnFinals.last(where: { textsMatch(text, $0.final) }) else { continue }
            // Only lift messages that currently paint *above* their Work so far turn.
            if index < match.index {
                moveAfterTurn[index] = match.index
            }
        }
        guard !moveAfterTurn.isEmpty else { return entries }

        var pendingAfterTurn: [Int: [Entry]] = [:]
        for (messageIndex, turnIndex) in moveAfterTurn {
            pendingAfterTurn[turnIndex, default: []].append(entries[messageIndex])
        }
        let moved = Set(moveAfterTurn.keys)
        var out: [Entry] = []
        out.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            if moved.contains(index) { continue }
            out.append(entry)
            if let pending = pendingAfterTurn[index] {
                out.append(contentsOf: pending)
            }
        }
        return out
    }

    /// Lightweight final-text match for order repairs (no UI caches).
    /// Treats equal normalized/compact forms as the same answer.
    public static func finalTextsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = compactFinalText(lhs)
        let b = compactFinalText(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    private static func compactFinalText(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(min(text.utf8.count, 4_096))
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            out.unicodeScalars.append(scalar)
            if out.utf8.count >= 4_096 { break }
        }
        return out
    }
}

// MARK: - Turn chat composition (macOS ↔ iOS parity)

/// Single rule for every turn in the Agent chat:
/// **user message** (transcript) → **Work so far** (all non-final work) → **final agent message** only outside.
/// Live turns have no outside tool/group rows; the active stream lives inside Work so far when expanded.
public enum AgentTurnChatComposition {
    /// Split renderable turn items into work (disclosure) vs outside (final answer only).
    /// - Live / unfinished: everything is work; outside is empty.
    /// - Finished: `finalItemIDs` paint outside (or only via finalMessage field); rest is work.
    public static func splitItems<Item>(
        _ items: [Item],
        turnFinished: Bool,
        isFinalItem: (Item) -> Bool
    ) -> (work: [Item], outside: [Item]) {
        if !turnFinished {
            return (items, [])
        }
        var work: [Item] = []
        var outside: [Item] = []
        work.reserveCapacity(items.count)
        for item in items {
            if isFinalItem(item) {
                outside.append(item)
            } else {
                work.append(item)
            }
        }
        return (work, outside)
    }

    /// Live Work so far must own every non-final step (no active-tail leak outside).
    public static func liveOutsideBlocksMustBeEmpty() -> Bool { true }
}

// MARK: - Work disclosure layout (lazy viewport + densify)

/// Viewport bounds for expanded Work so far so only on-screen steps mount.
/// Nested LazyVStack only virtualizes when height is bounded (inner ScrollView).
public enum AgentWorkDisclosureLayout {
    /// Max height of the expanded work list (points).
    public static let maxViewportHeight: CGFloat = 420
    /// Hint for estimated step row height (layout assist / tests).
    public static let estimatedStepMinHeight: CGFloat = 36
    /// Max step blocks painted in the lazy list before "show earlier".
    public static let expandedPaintWindow = 48
    public static let expandedRevealPage = 48
    /// Diff card: collapsed by default; preview this many non-meta lines when open.
    public static let diffDefaultExpanded = false
    public static let diffPreviewLineLimit = 32

    /// Slice work blocks for paint: oldest may stay folded behind a reveal control.
    public static func paintSlice<T>(
        all: [T],
        revealCount: Int,
        window: Int = expandedPaintWindow
    ) -> (hiddenCount: Int, rows: [T]) {
        let cap = max(1, window)
        guard all.count > cap else { return (0, all) }
        let hiddenBase = all.count - cap
        let revealed = min(max(0, revealCount), hiddenBase)
        let start = hiddenBase - revealed
        return (hiddenBase - revealed, Array(all[start...]))
    }

    public static func advancedRevealCount(current: Int, hiddenBase: Int, page: Int = expandedRevealPage) -> Int {
        min(hiddenBase, max(0, current) + max(1, page))
    }

    /// Visible code lines for a diff card (non-meta), with optional full expand.
    public static func visibleDiffLines<Line>(
        _ lines: [Line],
        isMeta: (Line) -> Bool,
        showAll: Bool,
        previewLimit: Int = diffPreviewLineLimit
    ) -> (rows: [Line], hiddenCount: Int) {
        let code = lines.filter { !isMeta($0) }
        if showAll || code.count <= previewLimit {
            return (code, 0)
        }
        return (Array(code.prefix(previewLimit)), code.count - previewLimit)
    }
}

// MARK: - Work so far expand policy

/// Pure policy for default-open latest live "Work so far" and collapse-all on final.
/// UI only stores user overrides; this decides painted expanded state.
public enum AgentCompletedWorkExpandPolicy {
    /// - isLive / isLatestLiveTurn: only the current unfinished turn defaults open.
    /// - userExplicitlyExpanded: finished (or non-default) turns the user opened.
    /// - userCollapsedWhileLive: user hid the live default-open disclosure.
    public static func isExpanded(
        isLive: Bool,
        isLatestLiveTurn: Bool,
        userExplicitlyExpanded: Bool,
        userCollapsedWhileLive: Bool
    ) -> Bool {
        if isLive && isLatestLiveTurn {
            return !userCollapsedWhileLive
        }
        return userExplicitlyExpanded
    }

    /// Final assistant answer / turn finish: collapse every work disclosure.
    public static func clearedExpansionState() -> (expanded: Set<String>, collapsedLive: Set<String>) {
        ([], [])
    }

    /// Apply a user toggle. Returns updated override sets.
    public static func toggle(
        turnId: String,
        currentlyExpanded: Bool,
        isLive: Bool,
        isLatestLiveTurn: Bool,
        userExpanded: Set<String>,
        userCollapsedLive: Set<String>
    ) -> (expanded: Set<String>, collapsedLive: Set<String>) {
        var expanded = userExpanded
        var collapsed = userCollapsedLive
        if currentlyExpanded {
            expanded.remove(turnId)
            if isLive && isLatestLiveTurn {
                collapsed.insert(turnId)
            }
        } else {
            collapsed.remove(turnId)
            expanded.insert(turnId)
        }
        return (expanded, collapsed)
    }
}

// MARK: - Expanded work block growth (append-friendly)

/// Pure helpers so live expanded "Work so far" prefers append / prefix reuse
/// over treating every stream tick as a brand-new full block list.
public enum AgentCompletedWorkBlockGrowth {
    public static func isPrefixStableAppend(previousIds: [String], nextIds: [String]) -> Bool {
        guard nextIds.count >= previousIds.count else { return false }
        for i in previousIds.indices where previousIds[i] != nextIds[i] {
            return false
        }
        return true
    }

    /// First item index that must be re-blocked when growing previous → next.
    /// `previousIds.count` means fully reusable (identical length). `0` = full rebuild.
    public static func rebuildFromItemIndex(
        previousIds: [String],
        previousGroupable: [Bool],
        nextIds: [String]
    ) -> Int {
        guard isPrefixStableAppend(previousIds: previousIds, nextIds: nextIds) else {
            return 0
        }
        if nextIds.count == previousIds.count {
            return previousIds.count
        }
        // Trailing open groupable run may absorb newly settled tools.
        var openRunStart = previousIds.count
        while openRunStart > 0,
              openRunStart - 1 < previousGroupable.count,
              previousGroupable[openRunStart - 1] {
            openRunStart -= 1
        }
        return openRunStart
    }

    /// Longest leading block-id prefix shared by previous and next full builds.
    public static func reusableBlockPrefixCount(
        previousBlockIds: [String],
        nextBlockIds: [String]
    ) -> Int {
        var n = 0
        let limit = min(previousBlockIds.count, nextBlockIds.count)
        while n < limit && previousBlockIds[n] == nextBlockIds[n] {
            n += 1
        }
        return n
    }

    /// Documents growth mode for tests and callers.
    /// - reuse: same settled ids → keep previous block identities
    /// - append: previous block ids are a strict prefix of next → only suffix is new
    /// - in_place_last_plus_append: last block id stable (group grew) + optional new blocks
    /// - full_rebuild: not prefix-stable
    /// - partial_rebuild: reuse common block id prefix only
    public static func growthDecision(
        previousItemIds: [String],
        previousBlockIds: [String],
        nextItemIds: [String],
        nextBlockIds: [String]
    ) -> (mode: String, reusedCount: Int, appendedBlockIds: [String]) {
        guard isPrefixStableAppend(previousIds: previousItemIds, nextIds: nextItemIds) else {
            return ("full_rebuild", 0, nextBlockIds)
        }
        if nextItemIds.count == previousItemIds.count {
            return ("reuse", previousBlockIds.count, [])
        }
        if previousBlockIds.isEmpty {
            return ("append", 0, nextBlockIds)
        }
        if nextBlockIds.starts(with: previousBlockIds) {
            return ("append", previousBlockIds.count, Array(nextBlockIds.dropFirst(previousBlockIds.count)))
        }
        let common = reusableBlockPrefixCount(
            previousBlockIds: previousBlockIds,
            nextBlockIds: nextBlockIds
        )
        if common == previousBlockIds.count - 1,
           common < nextBlockIds.count,
           previousBlockIds.last == nextBlockIds[common] {
            return (
                "in_place_last_plus_append",
                common + 1,
                Array(nextBlockIds.dropFirst(common + 1))
            )
        }
        return ("partial_rebuild", common, Array(nextBlockIds.dropFirst(common)))
    }
}

// MARK: - File edit diff (Cursor-style timeline card)

/// Pure extraction + line model for agent file edits shown inline in the thread.
/// WHY: users need to see what changed (path + red/green hunks), not a raw JSON/tool dump.
public enum AgentFileEditDiffPresentation {
    public enum LineKind: Sendable, Equatable {
        case meta
        case hunk
        case context
        case addition
        case deletion
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public var id: Int
        public var kind: LineKind
        /// Source text without the leading unified-diff marker for code lines.
        public var text: String
        public var oldLineNumber: Int?
        public var newLineNumber: Int?

        public init(
            id: Int,
            kind: LineKind,
            text: String,
            oldLineNumber: Int? = nil,
            newLineNumber: Int? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.oldLineNumber = oldLineNumber
            self.newLineNumber = newLineNumber
        }

        /// Number column: prefer new side for additions/context, old for deletions.
        public var displayLineNumber: Int? {
            switch kind {
            case .deletion: return oldLineNumber
            case .addition, .context: return newLineNumber ?? oldLineNumber
            case .meta, .hunk: return nil
            }
        }
    }

    public struct Model: Sendable, Equatable {
        public var path: String?
        public var lines: [Line]
        public var hiddenLineCount: Int

        public init(path: String?, lines: [Line], hiddenLineCount: Int = 0) {
            self.path = path
            self.lines = lines
            self.hiddenLineCount = hiddenLineCount
        }

        public var hasRenderableCode: Bool {
            lines.contains { $0.kind == .addition || $0.kind == .deletion || $0.kind == .context }
        }
    }

    public static let defaultMaxLines = 160

    /// True when this timeline item should paint as an Edit diff card.
    public static func shouldPresent(item: AssistantItem) -> Bool {
        if item.type == .fileChange { return model(for: item) != nil }
        // Claude Edit/Write and similar tools store structured JSON in body.
        if item.type == .tool || item.type == .commandExecution || item.type == .dynamicToolCall {
            return model(for: item) != nil
        }
        return false
    }

    public static func model(for item: AssistantItem, maxLines: Int = defaultMaxLines) -> Model? {
        let path = extractPath(from: item)
        guard let raw = extractDiffText(from: item), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let parsed = parseUnifiedDiff(raw, maxLines: maxLines)
        guard parsed.lines.contains(where: {
            $0.kind == .addition || $0.kind == .deletion || $0.kind == .context || $0.kind == .hunk
        }) else {
            // Still show path-only edits with a single meta line when we only know the path.
            if let path, !path.isEmpty {
                return Model(
                    path: path,
                    lines: [Line(id: 0, kind: .meta, text: "File updated")],
                    hiddenLineCount: 0
                )
            }
            return nil
        }
        let resolvedPath = path ?? parsed.inferredPath
        return Model(path: resolvedPath, lines: parsed.lines, hiddenLineCount: parsed.hidden)
    }

    public static func extractPath(from item: AssistantItem) -> String? {
        if let resource = item.resourcePath?.trimmingCharacters(in: .whitespacesAndNewlines), !resource.isEmpty {
            return resource
        }
        if let fromSummary = pathCandidate(in: item.summary ?? ""), !fromSummary.isEmpty {
            return fromSummary
        }
        for blob in [item.body, item.output ?? ""] {
            if let p = pathFromJSON(blob) { return p }
            if let p = pathFromUnifiedDiff(blob) { return p }
        }
        return nil
    }

    public static func extractDiffText(from item: AssistantItem) -> String? {
        for blob in [item.output ?? "", item.body] {
            let trimmed = blob.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if looksLikeDiff(trimmed) { return trimmed }
            if let fromJSON = diffFromJSONChanges(trimmed) { return fromJSON }
            if let fromEdit = synthesizeDiffFromEditJSON(trimmed) { return fromEdit }
            if let fromPatch = extractApplyPatchBlock(trimmed) { return fromPatch }
        }
        return nil
    }

    public static func looksLikeDiff(_ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(60) {
            let s = String(line)
            if s.hasPrefix("diff --git ") || s.hasPrefix("@@") || s.hasPrefix("--- ") || s.hasPrefix("+++ ") {
                return true
            }
            if s.hasPrefix("*** Begin Patch") || s.hasPrefix("*** Update File:") || s.hasPrefix("*** Add File:") {
                return true
            }
        }
        // Heuristic: several +/- code lines without being a bullet list.
        var plus = 0, minus = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(80) {
            if line.hasPrefix("+") && !line.hasPrefix("++") { plus += 1 }
            if line.hasPrefix("-") && !line.hasPrefix("--") { minus += 1 }
        }
        return plus + minus >= 2 && (plus > 0 || minus > 0)
    }

    /// Parse unified / apply-patch style text into numbered display lines.
    public static func parseUnifiedDiff(_ text: String, maxLines: Int = defaultMaxLines) -> (lines: [Line], hidden: Int, inferredPath: String?) {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [Line] = []
        out.reserveCapacity(min(rawLines.count, maxLines))
        var oldN = 0
        var newN = 0
        var inferredPath: String?
        var index = 0
        for raw in rawLines {
            if out.count >= maxLines { break }
            let line = raw
            if line.hasPrefix("diff --git ") {
                inferredPath = inferredPath ?? pathFromDiffGitLine(line)
                out.append(Line(id: index, kind: .meta, text: line)); index += 1
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                if line.hasPrefix("+++ ") {
                    inferredPath = inferredPath ?? pathFromDiffFileHeader(line)
                } else if inferredPath == nil {
                    inferredPath = pathFromDiffFileHeader(line)
                }
                out.append(Line(id: index, kind: .meta, text: line)); index += 1
                continue
            }
            if line.hasPrefix("*** Update File:") || line.hasPrefix("*** Add File:") || line.hasPrefix("*** Delete File:") {
                inferredPath = inferredPath ?? line.split(separator: ":", maxSplits: 1).last.map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
                out.append(Line(id: index, kind: .meta, text: line)); index += 1
                continue
            }
            if line.hasPrefix("*** Begin Patch") || line.hasPrefix("*** End Patch") {
                out.append(Line(id: index, kind: .meta, text: line)); index += 1
                continue
            }
            if line.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(line) {
                    oldN = o
                    newN = n
                }
                out.append(Line(id: index, kind: .hunk, text: line)); index += 1
                continue
            }
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                let text = String(line.dropFirst())
                out.append(Line(id: index, kind: .addition, text: text, oldLineNumber: nil, newLineNumber: newN))
                newN += 1
                index += 1
                continue
            }
            if line.hasPrefix("-") && !line.hasPrefix("---") {
                let text = String(line.dropFirst())
                out.append(Line(id: index, kind: .deletion, text: text, oldLineNumber: oldN, newLineNumber: nil))
                oldN += 1
                index += 1
                continue
            }
            // Context (leading space or plain)
            let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
            if line.hasPrefix(" ") || (!line.isEmpty && !line.hasPrefix("\\")) {
                out.append(Line(id: index, kind: .context, text: text, oldLineNumber: oldN, newLineNumber: newN))
                if !line.isEmpty {
                    oldN += 1
                    newN += 1
                }
                index += 1
            } else if line.hasPrefix("\\") {
                out.append(Line(id: index, kind: .meta, text: line)); index += 1
            }
        }
        let hidden = max(0, rawLines.count - out.count)
        return (out, hidden, inferredPath)
    }

    /// Claude Edit/Write JSON → synthetic unified-ish hunk.
    public static func synthesizeDiffFromEditJSON(_ body: String) -> String? {
        guard let obj = jsonObject(body) else { return nil }
        let path = (obj["file_path"] as? String)
            ?? (obj["path"] as? String)
            ?? (obj["filePath"] as? String)
            ?? "file"
        if let oldS = obj["old_string"] as? String, let newS = obj["new_string"] as? String {
            return buildSyntheticDiff(path: path, oldText: oldS, newText: newS)
        }
        if let content = (obj["content"] as? String) ?? (obj["new_string"] as? String),
           obj["old_string"] == nil {
            // Write / create: all additions
            var lines = ["*** Add File: \(path)", "@@"]
            for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("+\(line)")
            }
            return lines.joined(separator: "\n")
        }
        return nil
    }

    // MARK: - Internals

    private static func buildSyntheticDiff(path: String, oldText: String, newText: String) -> String {
        let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out = [
            "*** Update File: \(path)",
            "@@ -\(1),\(oldLines.count) +\(1),\(newLines.count) @@"
        ]
        for line in oldLines { out.append("-\(line)") }
        for line in newLines { out.append("+\(line)") }
        return out.joined(separator: "\n")
    }

    private static func diffFromJSONChanges(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        // { "changes": [ ... ] } or bare array
        let changes: [[String: Any]]
        if let dict = json as? [String: Any] {
            if let patch = dict["patch"] as? String, looksLikeDiff(patch) { return patch }
            if let diff = dict["diff"] as? String, looksLikeDiff(diff) { return diff }
            if let arr = dict["changes"] as? [[String: Any]] {
                changes = arr
            } else {
                return nil
            }
        } else if let arr = json as? [[String: Any]] {
            changes = arr
        } else {
            return nil
        }
        var chunks: [String] = []
        for change in changes {
            let path = (change["path"] as? String)
                ?? (change["file"] as? String)
                ?? (change["filename"] as? String)
                ?? "file"
            if let diff = (change["diff"] as? String)
                ?? (change["patch"] as? String)
                ?? (change["unified_diff"] as? String)
                ?? (change["unifiedDiff"] as? String),
               !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if looksLikeDiff(diff) {
                    chunks.append(diff)
                } else {
                    chunks.append("*** Update File: \(path)\n@@\n\(diff)")
                }
                continue
            }
            if let oldS = change["old_string"] as? String, let newS = change["new_string"] as? String {
                chunks.append(buildSyntheticDiff(path: path, oldText: oldS, newText: newS))
            }
        }
        guard !chunks.isEmpty else { return nil }
        return chunks.joined(separator: "\n")
    }

    private static func extractApplyPatchBlock(_ text: String) -> String? {
        guard text.contains("*** Begin Patch") || text.contains("*** Update File:") else { return nil }
        return text
    }

    private static func pathFromJSON(_ body: String) -> String? {
        guard let obj = jsonObject(body) else { return nil }
        for key in ["file_path", "path", "filePath", "filename", "file"] {
            if let p = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                return p
            }
        }
        if let changes = obj["changes"] as? [[String: Any]],
           let first = changes.first {
            for key in ["path", "file", "filename"] {
                if let p = (first[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                    return p
                }
            }
        }
        return nil
    }

    private static func pathFromUnifiedDiff(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(20) {
            let s = String(line)
            if s.hasPrefix("diff --git ") { return pathFromDiffGitLine(s) }
            if s.hasPrefix("+++ ") { return pathFromDiffFileHeader(s) }
            if s.hasPrefix("*** Update File:") || s.hasPrefix("*** Add File:") {
                return s.split(separator: ":", maxSplits: 1).last.map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    private static func pathCandidate(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.contains("/") || t.contains(".") else { return nil }
        // "Changed path/to/file.swift" / "1 file change · foo.ts"
        if let range = t.range(of: #"(/[^\s]+|\S+\.\w{1,8})"#, options: .regularExpression) {
            return String(t[range])
        }
        return nil
    }

    private static func pathFromDiffGitLine(_ line: String) -> String? {
        // diff --git a/foo b/foo
        let parts = line.split(separator: " ")
        guard parts.count >= 4 else { return nil }
        let b = String(parts[3])
        if b.hasPrefix("b/") { return String(b.dropFirst(2)) }
        return b
    }

    private static func pathFromDiffFileHeader(_ line: String) -> String? {
        // +++ b/path or --- a/path
        var rest = line
        if rest.hasPrefix("+++ ") || rest.hasPrefix("--- ") {
            rest = String(rest.dropFirst(4))
        }
        if rest == "/dev/null" { return nil }
        if rest.hasPrefix("a/") || rest.hasPrefix("b/") {
            return String(rest.dropFirst(2))
        }
        return rest.split(separator: "\t").first.map(String.init)
    }

    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        // @@ -12,4 +12,10 @@
        guard let re = try? NSRegularExpression(pattern: #"@@\s*-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s*@@"#) else {
            return nil
        }
        let ns = line as NSString
        guard let match = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 3,
              let oldR = Range(match.range(at: 1), in: line),
              let newR = Range(match.range(at: 2), in: line),
              let old = Int(line[oldR]),
              let new = Int(line[newR]) else { return nil }
        return (old, new)
    }

    private static func jsonObject(_ body: String) -> [String: Any]? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }
}

// MARK: - Thread rail row copy

/// Pure thread-row subtitle + monogram for denser rail scanning.
public enum AgentThreadRailRowCopy {
    public static func monogram(for provider: AgentProvider) -> String {
        switch provider {
        case .codex: return "X"
        case .claude: return "C"
        case .grok: return "G"
        }
    }

    public static func subtitle(
        provider: AgentProvider,
        model: String,
        updatedAt: Date,
        now: Date = Date()
    ) -> String {
        let modelPart = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = relativeTime(from: updatedAt, now: now)
        if modelPart.isEmpty {
            return "\(provider.rawValue) · \(time)"
        }
        return "\(provider.rawValue) · \(shortModel(modelPart)) · \(time)"
    }

    public static func shortModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 28 { return trimmed }
        return String(trimmed.prefix(25)) + "…"
    }

    public static func relativeTime(from date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 45 { return "now" }
        if seconds < 3600 { return "\(max(1, seconds / 60))m" }
        if seconds < 86_400 { return "\(max(1, seconds / 3600))h" }
        if seconds < 86_400 * 7 { return "\(max(1, seconds / 86_400))d" }
        return "\(max(1, seconds / (86_400 * 7)))w"
    }
}

// MARK: - Empty starters (shared copy)

public struct AgentEmptyConversationStarter: Sendable, Equatable, Identifiable {
    public var id: String { title }
    public let icon: String
    public let title: String
    public let prompt: String

    public init(icon: String, title: String, prompt: String) {
        self.icon = icon
        self.title = title
        self.prompt = prompt
    }
}

public enum AgentEmptyConversationStarters {
    /// Canonical starters — keep macOS/iOS copy aligned.
    public static let all: [AgentEmptyConversationStarter] = [
        AgentEmptyConversationStarter(
            icon: "magnifyingglass",
            title: "Explain this codebase",
            prompt: "Give me a high-level tour of this codebase: the main modules, how they fit together, and where to start reading."
        ),
        AgentEmptyConversationStarter(
            icon: "ant",
            title: "Find and fix a bug",
            prompt: "Find a bug in the current changes and fix it. Show me the diff and explain the root cause."
        ),
        AgentEmptyConversationStarter(
            icon: "checklist",
            title: "Plan a change",
            prompt: "I want to add a feature. Help me plan it step by step before writing any code."
        ),
        AgentEmptyConversationStarter(
            icon: "text.alignleft",
            title: "Write tests",
            prompt: "Add tests for the most recently changed files. Cover the edge cases."
        )
    ]
}
