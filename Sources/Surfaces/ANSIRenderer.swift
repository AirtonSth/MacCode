import Foundation
import AppKit

/// Minimal ANSI / VT100 emulator that converts a stream of bytes into an
/// NSAttributedString. Handles a useful subset: SGR (colors, bold,
/// italic, underline), CR/LF, BS, TAB, BEL, basic cursor-style erases
/// (ESC[K, ESC[2K, ESC[J, ESC[2J), ESC[?... private modes (ignored),
/// alternate-screen toggle (visual no-op), and OSC ... BEL/ST sequences
/// (ignored). Cursor positioning is approximate — we model output as a
/// linear append-only ring of rows; CSI H / CSI A/B/C/D adjust the
/// current row/col so simple TUIs render correctly enough for read use.
public final class ANSIRenderer {
    public struct Cell {
        public var ch: Character
        public var fg: NSColor
        public var bg: NSColor
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool
        public var inverse: Bool

        public static let empty = Cell(ch: " ", fg: .white, bg: .black,
                                       bold: false, italic: false, underline: false, inverse: false)
    }

    public private(set) var rows: Int
    public private(set) var cols: Int
    public private(set) var grid: [[Cell]]
    public private(set) var cursorRow = 0
    public private(set) var cursorCol = 0

    private var fg: NSColor = .white
    private var bg: NSColor = .black
    private var bold = false
    private var italic = false
    private var underline = false
    private var inverse = false

    public init(rows: Int = 40, cols: Int = 120) {
        self.rows = rows
        self.cols = cols
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

    public func feed(_ data: Data) {
        for byte in data {
            feed(byte: byte)
        }
    }

    public func feed(byte b: UInt8) {
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
        grid.removeFirst()
        grid.append(Array(repeating: Cell.empty, count: cols))
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
        oscBuffer.append(Character(UnicodeScalar(b)))
    }

    private func dispatchCSI(final: UInt8) {
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
        case "h", "l":
            // private modes — alt screen toggle etc.; ignore
            break
        default:
            break
        }
    }

    private func parseParams() -> [Int] {
        let trimmed = csiParams.replacingOccurrences(of: "?", with: "").replacingOccurrences(of: ">", with: "")
        if trimmed.isEmpty { return [] }
        return trimmed.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
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
            case 30...37: fg = ANSIRenderer.basicColors[p - 30]
            case 39: fg = .white
            case 40...47: bg = ANSIRenderer.basicColors[p - 40]
            case 49: bg = .black
            case 90...97: fg = ANSIRenderer.brightColors[p - 90]
            case 100...107: bg = ANSIRenderer.brightColors[p - 100]
            case 38, 48:
                // extended color: 38;5;N or 38;2;R;G;B
                if i + 1 < params.count {
                    let mode = params[i + 1]
                    if mode == 5, i + 2 < params.count {
                        let idx = params[i + 2]
                        let c = ANSIRenderer.color256(idx)
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
        fg = .white; bg = .black
        bold = false; italic = false; underline = false; inverse = false
    }

    private static let basicColors: [NSColor] = [
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),  // black
        NSColor(srgbRed: 0.80, green: 0.20, blue: 0.20, alpha: 1),  // red
        NSColor(srgbRed: 0.18, green: 0.60, blue: 0.18, alpha: 1),  // green
        NSColor(srgbRed: 0.80, green: 0.60, blue: 0.20, alpha: 1),  // yellow
        NSColor(srgbRed: 0.20, green: 0.40, blue: 0.80, alpha: 1),  // blue
        NSColor(srgbRed: 0.70, green: 0.30, blue: 0.70, alpha: 1),  // magenta
        NSColor(srgbRed: 0.20, green: 0.60, blue: 0.60, alpha: 1),  // cyan
        NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1)   // white
    ]
    private static let brightColors: [NSColor] = basicColors.map { c in
        let r = (c.redComponent + 1.0) / 2.0
        let g = (c.greenComponent + 1.0) / 2.0
        let b = (c.blueComponent + 1.0) / 2.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func color256(_ idx: Int) -> NSColor {
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

    public func snapshot() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for (i, row) in grid.enumerated() {
            // Trim trailing empties to keep lines tidy.
            var endCol = row.count - 1
            while endCol >= 0, row[endCol].ch == " " && row[endCol].bg == NSColor.black { endCol -= 1 }
            if endCol < 0 {
                if i < grid.count - 1 { out.append(NSAttributedString(string: "\n")) }
                continue
            }
            for c in 0...endCol {
                let cell = row[c]
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: cell.fg, .backgroundColor: cell.bg]
                if cell.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if cell.bold {
                    attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
                }
                out.append(NSAttributedString(string: String(cell.ch), attributes: attrs))
            }
            if i < grid.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    public func resize(rows newRows: Int, cols newCols: Int) {
        guard newRows > 0, newCols > 0 else { return }
        var newGrid = Array(repeating: Array(repeating: Cell.empty, count: newCols), count: newRows)
        for r in 0..<min(rows, newRows) {
            for c in 0..<min(cols, newCols) {
                newGrid[r][c] = grid[r][c]
            }
        }
        grid = newGrid
        rows = newRows
        cols = newCols
        cursorRow = min(cursorRow, newRows - 1)
        cursorCol = min(cursorCol, newCols - 1)
    }
}
