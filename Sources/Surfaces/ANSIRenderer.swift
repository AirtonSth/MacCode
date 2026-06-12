import Foundation
import AppKit
import DesignSystemKit

/// Minimal ANSI / VT100 emulator that converts a stream of bytes into an
/// NSAttributedString. Handles a useful subset: SGR (colors, bold,
/// italic, underline), CR/LF, BS, TAB, BEL, basic cursor-style erases
/// (ESC[K, ESC[2K, ESC[J, ESC[2J), ESC[?... private modes (ignored),
/// alternate-screen toggle (visual no-op), and OSC ... BEL/ST sequences
/// (ignored). Cursor positioning is approximate — we model output as a
/// linear append-only ring of rows; CSI H / CSI A/B/C/D adjust the
/// current row/col so simple TUIs render correctly enough for read use.
public final class ANSIRenderer {
    public static let defaultScrollbackLimit = 10_000

    public struct Cell {
        public var ch: Character
        public var fg: NSColor
        public var bg: NSColor
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool
        public var inverse: Bool

        public static let defaultFG = DS.NS.terminalFG
        public static let defaultBG = NSColor.clear
        public static let empty = Cell(ch: " ", fg: DS.NS.terminalFG, bg: NSColor.clear,
                                       bold: false, italic: false, underline: false, inverse: false)
    }

    public private(set) var rows: Int
    public private(set) var cols: Int
    public private(set) var grid: [[Cell]]
    public private(set) var cursorRow = 0
    public private(set) var cursorCol = 0
    public private(set) var scrollback: [[Cell]]
    public private(set) var usesAlternateScreen = false
    private let scrollbackLimit: Int
    private var savedGrid: [[Cell]]?
    private var savedCursor: (row: Int, col: Int)?
    private var savedNormalCursor: (row: Int, col: Int)?

    private var fg: NSColor = ANSIRenderer.Cell.defaultFG
    private var bg: NSColor = ANSIRenderer.Cell.defaultBG
    private var bold = false
    private var italic = false
    private var underline = false
    private var inverse = false
    private var cursorVisible = true

    /// Bumped on every content mutation so read-path snapshots can be memoized
    /// and only rebuilt when output actually changed (PERF-004).
    private var contentVersion: UInt64 = 0
    private var cachedSnapshot: (version: UInt64, value: NSAttributedString)?
    private var cachedANSIWithScrollback: (version: UInt64, value: String)?
    private var cachedANSIViewport: (version: UInt64, value: String)?

    private var basicColors: [NSColor]
    private var brightColors: [NSColor]

    public init(
        rows: Int = 40,
        cols: Int = 120,
        scrollbackLimit: Int = ANSIRenderer.defaultScrollbackLimit,
        themeColors: ANSIThemeColors? = nil
    ) {
        let palette = ANSIPaletteMapper.palette(from: themeColors)
        self.basicColors = palette.basic
        self.brightColors = palette.bright
        self.rows = rows
        self.cols = cols
        self.scrollback = []
        self.scrollbackLimit = max(0, scrollbackLimit)
        self.grid = Array(repeating: Array(repeating: Cell.empty, count: cols), count: rows)
    }

    private enum ParserState {
        case ground
        case esc
        case csi
        case osc
    }

    private var state: ParserState = .ground
    private var csiParams = ""
    private var csiIntermediate: UInt8 = 0
    private var oscBuffer = ""

    /// Maximum bytes accepted into oscBuffer before treating the sequence as
    /// malformed and aborting to ground. Real OSC payloads (window titles, etc.)
    /// are at most a few hundred bytes; 65536 is far above any legitimate value.
    static let oscBufferCap = 65_536

    private func emptyGrid(rows: Int? = nil, cols: Int? = nil) -> [[Cell]] {
        let rowCount = max(1, rows ?? self.rows)
        let colCount = max(1, cols ?? self.cols)
        return Array(repeating: Array(repeating: Cell.empty, count: colCount), count: rowCount)
    }

    public func feed(_ data: Data) {
        for byte in data {
            feed(byte: byte)
        }
    }

    public func feed(byte b: UInt8) {
        contentVersion &+= 1
        switch state {
        case .ground:
            handleGround(b)
        case .esc:
            handleEsc(b)
        case .csi:
            handleCSI(b)
        case .osc:
            handleOSC(b)
        }
    }

    private func handleGround(_ b: UInt8) {
        switch b {
        case 0x1B: // ESC
            state = .esc
        case 0x07: // BEL
            return
        case 0x08: // BS
            cursorCol = max(0, cursorCol - 1)
        case 0x09: // TAB
            let next = ((cursorCol / 8) + 1) * 8
            cursorCol = min(cols - 1, next)
        case 0x0A: // LF
            cursorRow += 1
            cursorCol = 0
            if cursorRow >= rows { scrollUp(); cursorRow = rows - 1 }
        case 0x0D: // CR
            cursorCol = 0
        case 0x00...0x06, 0x0B...0x0C, 0x0E...0x1A, 0x1C...0x1F, 0x7F:
            return
        default:
            // ASCII or UTF-8 leading byte
            if b < 0x80 {
                place(Character(UnicodeScalar(b)))
            } else {
                accumulateUTF8(b)
            }
        }
    }

    private var utf8Buf: [UInt8] = []

    private func accumulateUTF8(_ b: UInt8) {
        utf8Buf.append(b)
        if let str = String(bytes: utf8Buf, encoding: .utf8), !str.isEmpty {
            for ch in str { place(ch) }
            utf8Buf.removeAll(keepingCapacity: true)
        } else if utf8Buf.count >= 4 {
            // give up, drop bad bytes
            utf8Buf.removeAll(keepingCapacity: true)
        }
    }

    private func place(_ ch: Character) {
        if cursorCol >= cols {
            cursorCol = 0; cursorRow += 1
            if cursorRow >= rows { scrollUp(); cursorRow = rows - 1 }
        }
        var cell = Cell(ch: ch, fg: fg, bg: bg, bold: bold, italic: italic, underline: underline, inverse: inverse)
        if cell.inverse { swap(&cell.fg, &cell.bg) }
        grid[cursorRow][cursorCol] = cell
        cursorCol += 1
    }

    private func scrollUp() {
        if usesAlternateScreen {
            grid.removeFirst()
            grid.append(Array(repeating: Cell.empty, count: cols))
            return
        }
        appendScrollback(grid.removeFirst())
        grid.append(Array(repeating: Cell.empty, count: cols))
    }

    private func appendScrollback(_ row: [Cell], preserveBlank: Bool = true) {
        guard scrollbackLimit > 0 else { return }
        guard preserveBlank || row.contains(where: isVisibleContent) else { return }
        scrollback.append(row)
        if scrollback.count > scrollbackLimit {
            scrollback.removeFirst(scrollback.count - scrollbackLimit)
        }
    }

    private func isVisibleContent(_ cell: Cell) -> Bool {
        cell.ch != " " || cell.bg != NSColor.clear
    }

    private func handleEsc(_ b: UInt8) {
        switch b {
        case 0x5B: // '['
            state = .csi
            csiParams = ""
            csiIntermediate = 0
        case 0x5D: // ']'
            state = .osc
            oscBuffer = ""
        case 0x37, 0x38, 0x44, 0x4D, 0x45, 0x5C, 0x63: // 7 8 D M E \ c — minor controls, ignore
            if b == 0x37 {
                saveCursor()
            } else if b == 0x38 {
                restoreCursor()
            }
            state = .ground
        case 0x28, 0x29, 0x2A, 0x2B: // SCS — consume next byte
            csiIntermediate = b
            // expect one more byte then return to ground
            state = .csi
            csiParams = "_SCS_"
        default:
            state = .ground
        }
    }

    private func handleCSI(_ b: UInt8) {
        if csiParams == "_SCS_" { state = .ground; return }
        // collect parameter / intermediate bytes
        if (b >= 0x30 && b <= 0x3F) || b == 0x3B { // digit ; ? : etc
            csiParams.append(Character(UnicodeScalar(b)))
            return
        }
        if b >= 0x20 && b <= 0x2F {
            csiIntermediate = b
            return
        }
        if b >= 0x40 && b <= 0x7E {
            dispatchCSI(final: b)
            state = .ground
            return
        }
        // unknown, reset
        state = .ground
    }

    private func handleOSC(_ b: UInt8) {
        if b == 0x07 { // BEL terminator
            // ignore OSC payload (typically title sets)
            state = .ground
            return
        }
        if b == 0x1B { // start of ST? next char must be \
            // peek state will read next byte; simple model: just return to ground on next ESC
            state = .esc
            return
        }
        guard oscBuffer.count < ANSIRenderer.oscBufferCap else {
            // Malformed or adversarially large OSC: abort without retaining the data.
            oscBuffer = ""
            state = .ground
            return
        }
        oscBuffer.append(Character(UnicodeScalar(b)))
    }

    private func dispatchCSI(final: UInt8) {
        let isPrivateMode = csiParams.contains("?")
        let params = parseParams()
        let f = Character(UnicodeScalar(final))
        switch f {
        case "m":
            applySGR(params)
        case "H", "f":
            let r = max(1, params.first ?? 1) - 1
            let c = max(1, params.dropFirst().first ?? 1) - 1
            cursorRow = min(rows - 1, max(0, r))
            cursorCol = min(cols - 1, max(0, c))
        case "A":
            cursorRow = max(0, cursorRow - max(1, params.first ?? 1))
        case "B":
            cursorRow = min(rows - 1, cursorRow + max(1, params.first ?? 1))
        case "C":
            cursorCol = min(cols - 1, cursorCol + max(1, params.first ?? 1))
        case "D":
            cursorCol = max(0, cursorCol - max(1, params.first ?? 1))
        case "G":
            cursorCol = min(cols - 1, max(0, (params.first ?? 1) - 1))
        case "J":
            let mode = params.first ?? 0
            switch mode {
            case 0: clear(fromRow: cursorRow, fromCol: cursorCol, toEnd: true)
            case 1: clear(fromRow: 0, fromCol: 0, toEnd: false)
            case 2, 3:
                for r in 0..<rows {
                    grid[r] = Array(repeating: Cell.empty, count: cols)
                }
                cursorRow = 0; cursorCol = 0
            default: break
            }
        case "K":
            let mode = params.first ?? 0
            switch mode {
            case 0:
                for c in cursorCol..<cols { grid[cursorRow][c] = Cell.empty }
            case 1:
                for c in 0...cursorCol { grid[cursorRow][c] = Cell.empty }
            case 2:
                grid[cursorRow] = Array(repeating: Cell.empty, count: cols)
            default: break
            }
        case "s":
            saveCursor()
        case "u":
            restoreCursor()
        case "h", "l":
            if isPrivateMode {
                setPrivateModes(params, enabled: f == "h")
            }
        default:
            break
        }
    }

    private func setPrivateModes(_ params: [Int], enabled: Bool) {
        for mode in params {
            switch mode {
            case 25:
                cursorVisible = enabled
            case 47, 1047:
                if enabled {
                    enterAlternateScreen()
                } else {
                    leaveAlternateScreen()
                }
            case 1048:
                if enabled {
                    saveCursor()
                } else {
                    restoreCursor()
                }
            case 1049:
                if enabled {
                    enterAlternateScreen(saveNormalCursor: true)
                } else {
                    leaveAlternateScreen(restoreNormalCursor: true)
                }
            default:
                break
            }
        }
    }

    private func enterAlternateScreen(saveNormalCursor: Bool = false) {
        guard !usesAlternateScreen else { return }
        savedGrid = grid
        if saveNormalCursor {
            savedNormalCursor = (cursorRow, cursorCol)
        }
        grid = emptyGrid()
        cursorRow = 0
        cursorCol = 0
        usesAlternateScreen = true
    }

    private func leaveAlternateScreen(restoreNormalCursor: Bool = false) {
        guard usesAlternateScreen else { return }
        grid = resized(grid: savedGrid ?? emptyGrid(), rows: rows, cols: cols)
        savedGrid = nil
        if restoreNormalCursor, let savedNormalCursor {
            cursorRow = min(rows - 1, max(0, savedNormalCursor.row))
            cursorCol = min(cols - 1, max(0, savedNormalCursor.col))
        } else {
            cursorRow = min(cursorRow, rows - 1)
            cursorCol = min(cursorCol, cols - 1)
        }
        savedNormalCursor = nil
        usesAlternateScreen = false
    }

    private func saveCursor() {
        savedCursor = (cursorRow, cursorCol)
    }

    private func restoreCursor() {
        guard let savedCursor else { return }
        cursorRow = min(rows - 1, max(0, savedCursor.row))
        cursorCol = min(cols - 1, max(0, savedCursor.col))
    }

    private func parseParams() -> [Int] {
        let trimmed = csiParams.replacingOccurrences(of: "?", with: "").replacingOccurrences(of: ">", with: "")
        if trimmed.isEmpty { return [] }
        var values: [Int] = []
        for segment in trimmed.split(separator: ";", omittingEmptySubsequences: false) {
            if segment.contains(":") {
                for part in segment.split(separator: ":", omittingEmptySubsequences: false) where !part.isEmpty {
                    values.append(Int(part) ?? 0)
                }
            } else {
                values.append(Int(segment) ?? 0)
            }
        }
        return values
    }

    private func clear(fromRow: Int, fromCol: Int, toEnd: Bool) {
        if toEnd {
            for c in fromCol..<cols { grid[fromRow][c] = Cell.empty }
            for r in (fromRow + 1)..<rows {
                grid[r] = Array(repeating: Cell.empty, count: cols)
            }
        } else {
            for r in 0..<fromRow { grid[r] = Array(repeating: Cell.empty, count: cols) }
            for c in 0...fromCol { grid[fromRow][c] = Cell.empty }
        }
    }

    private func applySGR(_ params: [Int]) {
        if params.isEmpty {
            reset(); return
        }
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0: reset()
            case 1: bold = true
            case 3: italic = true
            case 4: underline = true
            case 7: inverse = true
            case 22: bold = false
            case 23: italic = false
            case 24: underline = false
            case 27: inverse = false
            case 30...37: fg = basicColors[p - 30]
            case 39: fg = ANSIRenderer.Cell.defaultFG
            case 40...47: bg = basicColors[p - 40]
            case 49: bg = ANSIRenderer.Cell.defaultBG
            case 90...97: fg = brightColors[p - 90]
            case 100...107: bg = brightColors[p - 100]
            case 38, 48:
                // extended color: 38;5;N or 38;2;R;G;B
                if i + 1 < params.count {
                    let mode = params[i + 1]
                    if mode == 5, i + 2 < params.count {
                        let idx = params[i + 2]
                        let c = color256(idx)
                        if p == 38 { fg = c } else { bg = c }
                        i += 2
                    } else if mode == 2, i + 4 < params.count {
                        let r = CGFloat(params[i + 2]) / 255.0
                        let g = CGFloat(params[i + 3]) / 255.0
                        let b = CGFloat(params[i + 4]) / 255.0
                        let c = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
                        if p == 38 { fg = c } else { bg = c }
                        i += 4
                    }
                }
            default: break
            }
            i += 1
        }
    }

    private func reset() {
        fg = ANSIRenderer.Cell.defaultFG; bg = ANSIRenderer.Cell.defaultBG
        bold = false; italic = false; underline = false; inverse = false
    }

    private func color256(_ idx: Int) -> NSColor {
        if idx < 8 { return basicColors[idx] }
        if idx < 16 { return brightColors[idx - 8] }
        if idx < 232 {
            let v = idx - 16
            let r = (v / 36) % 6
            let g = (v / 6) % 6
            let b = v % 6
            let f: (Int) -> CGFloat = { $0 == 0 ? 0 : CGFloat(40 * $0 + 55) / 255.0 }
            return NSColor(srgbRed: f(r), green: f(g), blue: f(b), alpha: 1)
        }
        // 232..255 grayscale
        let g = CGFloat(8 + 10 * (idx - 232)) / 255.0
        return NSColor(srgbRed: g, green: g, blue: g, alpha: 1)
    }

    /// When true, the cell at (cursorRow, cursorCol) is drawn as a solid
    /// inverse block so the caret is always visible (cmux/terminal style).
    public var showCursor = true

    public func snapshot() -> NSAttributedString {
        if let cachedSnapshot, cachedSnapshot.version == contentVersion {
            return cachedSnapshot.value
        }
        let value = buildSnapshot()
        cachedSnapshot = (contentVersion, value)
        return value
    }

    private func buildSnapshot() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = DS.NS.terminalFont()
        let curRow = cursorRow
        let curCol = min(cursorCol, cols - 1)
        let allRows = usesAlternateScreen ? grid : scrollback + grid
        let cursorRenderedRow = usesAlternateScreen ? curRow : scrollback.count + curRow
        for (i, row) in allRows.enumerated() {
            // Trim trailing empties to keep lines tidy.
            var endCol = row.count - 1
            while endCol >= 0, row[endCol].ch == " " && row[endCol].bg == NSColor.clear { endCol -= 1 }
            // Always render up to (and including) the cursor on its row
            // so a caret at end-of-line / on a blank line still shows.
            if showCursor, cursorVisible, i == cursorRenderedRow { endCol = max(endCol, curCol) }
            if endCol < 0 {
                if i < allRows.count - 1 { out.append(NSAttributedString(string: "\n")) }
                continue
            }
            for c in 0...endCol {
                let cell = row[c]
                let isCursor = showCursor && cursorVisible && i == cursorRenderedRow && c == curCol
                var fg = cell.fg
                var bg = cell.bg
                if isCursor {
                    // Solid block: invert — fill with foreground color,
                    // glyph (if any) painted in the background color.
                    bg = ANSIRenderer.Cell.defaultFG
                    fg = ANSIRenderer.Cell.defaultBG == NSColor.clear ? DS.NS.terminalBG : ANSIRenderer.Cell.defaultBG
                }
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg, .backgroundColor: bg]
                if cell.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if cell.bold {
                    attrs[.font] = DS.NS.terminalFont(weight: .bold)
                }
                out.append(NSAttributedString(string: String(cell.ch), attributes: attrs))
            }
            if i < allRows.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    public func ansiSnapshot(includeScrollback: Bool = false) -> String {
        if includeScrollback {
            if let cachedANSIWithScrollback, cachedANSIWithScrollback.version == contentVersion {
                return cachedANSIWithScrollback.value
            }
            let value = buildANSISnapshot(includeScrollback: true)
            cachedANSIWithScrollback = (contentVersion, value)
            return value
        }
        if let cachedANSIViewport, cachedANSIViewport.version == contentVersion {
            return cachedANSIViewport.value
        }
        let value = buildANSISnapshot(includeScrollback: false)
        cachedANSIViewport = (contentVersion, value)
        return value
    }

    private func buildANSISnapshot(includeScrollback: Bool) -> String {
        let allRows = usesAlternateScreen || !includeScrollback ? grid : scrollback + grid
        var out = ""
        var currentStyle: ANSIStyle?
        for (i, row) in allRows.enumerated() {
            var endCol = row.count - 1
            while endCol >= 0, row[endCol].ch == " " && row[endCol].bg == NSColor.clear { endCol -= 1 }
            if endCol >= 0 {
                for c in 0...endCol {
                    let cell = row[c]
                    let style = ANSIStyle(cell: cell, isCursor: false)
                    if style != currentStyle {
                        out += style.sequence
                        currentStyle = style
                    }
                    out.append(cell.ch)
                }
            }
            if i < allRows.count - 1 {
                out.append("\n")
            }
        }
        if currentStyle != nil {
            out += "\u{001B}[0m"
        }
        return out
    }

    public func ansiSnapshot(matchingVisibleText visibleText: String) -> String {
        let full = ansiSnapshot(includeScrollback: true)
        let ansiLines = full.components(separatedBy: "\n")
        let plainLines = ansiLines.map(Self.strippingANSIControls)
        var latestStyledLineByText: [String: String] = [:]
        for (plain, ansi) in zip(plainLines, ansiLines) {
            let key = Self.normalizeVisibleLine(plain)
            guard !key.isEmpty else { continue }
            latestStyledLineByText[key] = ansi
        }

        let matched = visibleText
            .components(separatedBy: "\n")
            .map { line -> String in
                let key = Self.normalizeVisibleLine(line)
                guard !key.isEmpty else { return "" }
                return latestStyledLineByText[key] ?? ANSIStyle.defaultSequence + line
            }
            .joined(separator: "\n")
        return matched.contains("\u{001B}") ? matched + "\u{001B}[0m" : matched
    }

    private static func normalizeVisibleLine(_ line: String) -> String {
        var normalized = line
        while normalized.last == " " {
            normalized.removeLast()
        }
        return normalized
    }

    private static func strippingANSIControls(_ line: String) -> String {
        var output = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "\u{001B}" {
                let next = line.index(after: index)
                guard next < line.endIndex, line[next] == "[" else {
                    index = next
                    continue
                }
                var scan = line.index(after: next)
                while scan < line.endIndex {
                    let scalar = line[scan].unicodeScalars.first?.value ?? 0
                    let after = line.index(after: scan)
                    if scalar >= 0x40 && scalar <= 0x7E {
                        index = after
                        break
                    }
                    scan = after
                    if scan == line.endIndex {
                        index = scan
                    }
                }
            } else {
                output.append(line[index])
                index = line.index(after: index)
            }
        }
        return output
    }

    private struct ANSIStyle: Equatable {
        var foreground: RGB?
        var background: RGB?
        var bold: Bool
        var italic: Bool
        var underline: Bool

        init(cell: Cell, isCursor: Bool) {
            var fg = cell.fg
            var bg = cell.bg
            if isCursor {
                bg = ANSIRenderer.Cell.defaultFG
                fg = ANSIRenderer.Cell.defaultBG == NSColor.clear ? DS.NS.terminalBG : ANSIRenderer.Cell.defaultBG
            }
            foreground = RGB(fg)
            background = bg == NSColor.clear ? nil : RGB(bg)
            bold = cell.bold
            italic = cell.italic
            underline = cell.underline
        }

        var sequence: String {
            var codes = ["0"]
            if bold { codes.append("1") }
            if italic { codes.append("3") }
            if underline { codes.append("4") }
            if let foreground {
                codes.append("38;2;\(foreground.red);\(foreground.green);\(foreground.blue)")
            }
            if let background {
                codes.append("48;2;\(background.red);\(background.green);\(background.blue)")
            }
            return "\u{001B}[\(codes.joined(separator: ";"))m"
        }

        static var defaultSequence: String { "\u{001B}[0;38;2;242;242;242m" }
    }

    private struct RGB: Equatable {
        var red: Int
        var green: Int
        var blue: Int

        init?(_ color: NSColor) {
            guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
            red = Self.byte(srgb.redComponent)
            green = Self.byte(srgb.greenComponent)
            blue = Self.byte(srgb.blueComponent)
        }

        private static func byte(_ value: CGFloat) -> Int {
            min(255, max(0, Int((value * 255).rounded())))
        }
    }

    public func cursorOffset(in rendered: String) -> Int {
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return 0 }
        let rowOffset = usesAlternateScreen ? 0 : scrollback.count
        let row = min(rowOffset + cursorRow, lines.count - 1)
        var offset = 0
        for i in 0..<row {
            offset += (lines[i] as NSString).length + 1
        }
        offset += min(cursorCol, (lines[row] as NSString).length)
        return min(offset, (rendered as NSString).length)
    }

    public func resize(rows newRows: Int, cols newCols: Int) {
        guard newRows > 0, newCols > 0 else { return }
        contentVersion &+= 1
        let removedTopRows = max(0, rows - newRows)
        if removedTopRows > 0, !usesAlternateScreen {
            for row in grid.prefix(removedTopRows) {
                appendScrollback(resized(row: Array(row), cols: newCols), preserveBlank: false)
            }
        }
        grid = resized(grid: grid, rows: newRows, cols: newCols)
        if let savedGrid {
            self.savedGrid = resized(grid: savedGrid, rows: newRows, cols: newCols)
        }
        rows = newRows
        cols = newCols
        cursorRow = min(max(0, cursorRow - removedTopRows), newRows - 1)
        cursorCol = min(cursorCol, newCols - 1)
        if let savedNormalCursor {
            self.savedNormalCursor = (
                row: min(max(0, savedNormalCursor.row - removedTopRows), newRows - 1),
                col: min(savedNormalCursor.col, newCols - 1)
            )
        }
    }

    private func resized(grid oldGrid: [[Cell]], rows newRows: Int, cols newCols: Int) -> [[Cell]] {
        let keptRows = Array(oldGrid.suffix(min(oldGrid.count, newRows)))
        var newGrid = keptRows.map { resized(row: $0, cols: newCols) }
        while newGrid.count < newRows {
            newGrid.append(Array(repeating: Cell.empty, count: newCols))
        }
        return newGrid
    }

    private func resized(row: [Cell], cols newCols: Int) -> [Cell] {
        if row.count == newCols { return row }
        if row.count > newCols { return Array(row.prefix(newCols)) }
        return row + Array(repeating: Cell.empty, count: newCols - row.count)
    }

    // MARK: - Test-visible buffer size accessors
    // WHY: oscBuffer and utf8Buf are private parser state; exposing raw counts
    // (not the contents) lets fuzz tests assert the bounded-buffer invariant
    // without opening any real security surface. These are the narrowest
    // accessors that satisfy the test contract (todo-QA item 104).
    var oscBufferCount: Int { oscBuffer.count }
    var utf8BufCount: Int { utf8Buf.count }

    // MARK: - Theme palette export seam

    /// Convert a flat array of up to 16 raw RGB triples (indices 0-15) into an
    /// `ANSIThemeColors` value suitable for passing to `ANSIRenderer.init(themeColors:)`.
    ///
    /// This is a pure, nonisolated static function — it has no dependency on
    /// AppKit state, actor context, or Ghostty runtime — so it can be unit-tested
    /// directly and called from any context.
    ///
    /// WHY: when a Mac session mirror snapshot is sent to iOS, the ANSI escape
    /// codes in `ansiSnapshot` carry no color values — they reference palette
    /// indices (SGR 31 = "red"). iOS re-renders those codes through its own
    /// ANSIRenderer. If iOS uses hardcoded defaults while the Mac loaded a custom
    /// Ghostty theme, the same output looks different on each device. Passing the
    /// resolved Mac palette inside (or alongside) the snapshot eliminates the drift.
    ///
    /// - Parameter entries: Array of `(index, r, g, b)` tuples where `index` is
    ///   the ANSI palette index (0-7 basic, 8-15 bright). Entries outside 0...15
    ///   are silently ignored.
    /// - Returns: An `ANSIThemeColors` whose `colors` dictionary contains only the
    ///   provided entries, mapped to `NSColor(srgbRed:green:blue:alpha:)`.
    public nonisolated static func ansiThemeColors(
        from entries: [(index: Int, r: UInt8, g: UInt8, b: UInt8)]
    ) -> ANSIThemeColors {
        var map: [Int: NSColor] = [:]
        for entry in entries where (0...15).contains(entry.index) {
            map[entry.index] = NSColor(
                srgbRed:  CGFloat(entry.r) / 255.0,
                green:    CGFloat(entry.g) / 255.0,
                blue:     CGFloat(entry.b) / 255.0,
                alpha:    1.0
            )
        }
        return ANSIThemeColors(map)
    }
}
