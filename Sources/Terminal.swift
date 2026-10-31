import AppKit

final class PTY {
    private(set) var pid: pid_t = 0
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var pending = Data()
    var onOutput: ((String) -> Void)?
    var onExit: (() -> Void)?

    func start(cwd: String, cols: Int, rows: Int, command: String? = nil) -> Bool {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = appName
        if env["LANG"] == nil {
            let lang = Locale.current.language.languageCode?.identifier ?? "en"
            let region = Locale.current.region?.identifier ?? "US"
            let name = "\(lang)_\(region).UTF-8"
            env["LANG"] = FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)") ? name : "en_US.UTF-8"
        }

        let shellC = strdup(shell)
        let cwdC = strdup(cwd)
        let login = strdup("-" + (shell as NSString).lastPathComponent)
        let argv: [UnsafeMutablePointer<CChar>?] = command.map { [login, strdup("-c"), strdup($0), nil] } ?? [login, nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            free(shellC)
            free(cwdC)
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let child = forkpty(&master, nil, nil, &size)
        if child < 0 { return false }
        if child == 0 {
            chdir(cwdC)
            execve(shellC, argv, envp)
            _exit(127)
        }

        pid = child
        fd = master
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        self.source = source
        return true
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 {
            finish()
            onExit?()
            return
        }
        pending.append(contentsOf: buffer[0..<n])
        let cut = Self.completeUTF8Length(pending)
        let text = String(decoding: pending.prefix(cut), as: UTF8.self)
        pending = Data(pending.dropFirst(cut))
        onOutput?(text)
    }

    private static func completeUTF8Length(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(4))
        for back in 1...bytes.count {
            let byte = bytes[bytes.count - back]
            if byte & 0xC0 == 0x80 { continue }
            let need = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return need > back ? data.count - back : data.count
        }
        return data.count
    }

    func write(_ text: String) {
        guard fd >= 0 else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { p in
            var offset = 0
            while offset < p.count {
                let n = Darwin.write(fd, p.baseAddress! + offset, p.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard fd >= 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &size)
    }

    func terminate() {
        guard fd >= 0 else { return }
        kill(pid, SIGHUP)
        finish()
    }

    private func finish() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd) }
        fd = -1
        let child = pid
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }
    }
}

struct TermStyle: Equatable {
    var fg: NSColor?
    var bg: NSColor?
    var bold = false
    var underline = false
    var inverse = false
}

struct Cell {
    var ch: String = " "
    var width: UInt8 = 1
    var style = TermStyle()
}

func cellWidth(_ v: UInt32) -> Int {
    switch v {
    case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
         0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
         0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
        return 2
    default:
        return 1
    }
}

final class TerminalEmulator {
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var screen: [[Cell]]
    private(set) var scrollback: [[Cell]] = []
    private(set) var cx = 0
    private(set) var cy = 0
    private(set) var cursorVisible = true
    private(set) var appCursor = false
    private(set) var bracketedPaste = false
    var onReply: ((String) -> Void)?

    private var style = TermStyle()
    private var wrapPending = false
    private var top = 0
    private var bottom: Int
    private var saved = (x: 0, y: 0, style: TermStyle())
    private var mainScreen: (screen: [[Cell]], x: Int, y: Int)?
    private let scrollbackLimit = 5000

    private enum State { case ground, escape, csi, osc, oscEscape, charset }
    private var state = State.ground
    private var params = ""

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        bottom = rows - 1
        screen = []
        screen = (0..<rows).map { _ in blankLine() }
    }

    private func blankLine() -> [Cell] {
        [Cell](repeating: Cell(style: TermStyle(bg: style.bg)), count: cols)
    }

    private func fit(_ line: [Cell]) -> [Cell] {
        line.count >= cols ? Array(line.prefix(cols)) : line + [Cell](repeating: Cell(), count: cols - line.count)
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        guard newCols != cols || newRows != rows, newCols > 0, newRows > 0 else { return }
        cols = newCols
        screen = screen.map(fit)
        if screen.count > newRows {
            let lift = min(screen.count - newRows, cy)
            if mainScreen == nil { scrollback.append(contentsOf: screen.prefix(lift)) }
            screen.removeFirst(lift)
            cy -= lift
            screen = Array(screen.prefix(newRows))
        }
        rows = newRows
        while screen.count < rows { screen.append(blankLine()) }
        cx = min(cx, cols - 1)
        cy = min(cy, rows - 1)
        top = 0
        bottom = rows - 1
        wrapPending = false
    }

    func feed(_ text: String) {
        for scalar in text.unicodeScalars { process(scalar) }
    }

    private func process(_ s: Unicode.Scalar) {
        let v = s.value
        switch state {
        case .ground:
            ground(s)
        case .escape:
            escape(s)
        case .charset:
            state = .ground
        case .osc:
            if v == 0x07 { state = .ground } else if v == 0x1B { state = .oscEscape }
        case .oscEscape:
            state = .ground
        case .csi:
            if v == 0x1B { state = .escape; return }
            if (0x40...0x7E).contains(v) {
                state = .ground
                csi(Character(s))
            } else if v >= 0x20 {
                params.unicodeScalars.append(s)
            }
        }
    }

    private func ground(_ s: Unicode.Scalar) {
        switch s.value {
        case 0x1B: state = .escape
        case 0x0D: cx = 0; wrapPending = false
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x08: if cx > 0 { cx -= 1 }; wrapPending = false
        case 0x09: cx = min(cols - 1, (cx / 8 + 1) * 8)
        case 0..<0x20, 0x7F: break
        default: put(s)
        }
    }

    private func escape(_ s: Unicode.Scalar) {
        state = .ground
        switch s {
        case "[": state = .csi; params = ""
        case "]": state = .osc
        case "(", ")", "*", "+": state = .charset
        case "7": saved = (cx, cy, style)
        case "8": restoreCursor()
        case "D": lineFeed()
        case "E": cx = 0; lineFeed()
        case "M": reverseIndex()
        case "c": reset()
        default: break
        }
    }

    private func put(_ s: Unicode.Scalar) {
        if s.properties.generalCategory == .nonspacingMark || s.properties.generalCategory == .enclosingMark
            || (0xFE00...0xFE0F).contains(s.value) || s.value == 0x200D {
            let x = wrapPending ? cx : max(cx - 1, 0)
            var target = x
            if screen[cy][target].width == 0, target > 0 { target -= 1 }
            screen[cy][target].ch.unicodeScalars.append(s)
            return
        }
        let w = cellWidth(s.value)
        if wrapPending || (w == 2 && cx == cols - 1) {
            cx = 0
            lineFeed()
            wrapPending = false
        }
        screen[cy][cx] = Cell(ch: String(s), width: UInt8(w), style: style)
        if w == 2, cx + 1 < cols { screen[cy][cx + 1] = Cell(ch: "", width: 0, style: style) }
        cx += w
        if cx >= cols {
            cx = cols - 1
            wrapPending = true
        }
    }

    private func lineFeed() {
        wrapPending = false
        if cy == bottom { scrollUp(1) } else if cy < rows - 1 { cy += 1 }
    }

    private func reverseIndex() {
        if cy == top { scrollDown(1) } else if cy > 0 { cy -= 1 }
    }

    private func scrollUp(_ n: Int, from start: Int? = nil) {
        let first = start ?? top
        for _ in 0..<min(n, bottom - first + 1) {
            let line = screen.remove(at: first)
            if first == 0, mainScreen == nil {
                scrollback.append(line)
                if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
            }
            screen.insert(blankLine(), at: bottom)
        }
    }

    private func scrollDown(_ n: Int, from start: Int? = nil) {
        let first = start ?? top
        for _ in 0..<min(n, bottom - first + 1) {
            screen.remove(at: bottom)
            screen.insert(blankLine(), at: first)
        }
    }

    private func restoreCursor() {
        cx = min(saved.x, cols - 1)
        cy = min(saved.y, rows - 1)
        style = saved.style
        wrapPending = false
    }

    private func reset() {
        style = TermStyle()
        screen = (0..<rows).map { _ in blankLine() }
        cx = 0; cy = 0; top = 0; bottom = rows - 1
        wrapPending = false
        cursorVisible = true
        appCursor = false
        bracketedPaste = false
    }

    private func erase(row: Int, from: Int, to: Int) {
        guard from < to else { return }
        for x in max(from, 0)..<min(to, cols) { screen[row][x] = Cell(style: TermStyle(bg: style.bg)) }
    }

    private func csi(_ final: Character) {
        let isPrivate = params.hasPrefix("?")
        let body = params.trimmingCharacters(in: CharacterSet(charactersIn: "?>=! "))
        let p = body.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func arg(_ i: Int, _ fallback: Int = 1) -> Int { i < p.count && p[i] > 0 ? p[i] : fallback }
        let n = arg(0)
        if final != "m" { wrapPending = false }

        switch final {
        case "A": cy = max(cy - n, cy >= top ? top : 0)
        case "B", "e": cy = min(cy + n, cy <= bottom ? bottom : rows - 1)
        case "C", "a": cx = min(cx + n, cols - 1)
        case "D": cx = max(cx - n, 0)
        case "E": cx = 0; cy = min(cy + n, rows - 1)
        case "F": cx = 0; cy = max(cy - n, 0)
        case "G", "`": cx = min(n - 1, cols - 1)
        case "d": cy = min(n - 1, rows - 1)
        case "H", "f":
            cy = min(arg(0) - 1, rows - 1)
            cx = min(arg(1) - 1, cols - 1)
        case "J":
            switch p.first ?? 0 {
            case 0:
                erase(row: cy, from: cx, to: cols)
                for y in (cy + 1)..<max(rows, cy + 1) { screen[y] = blankLine() }
            case 1:
                erase(row: cy, from: 0, to: cx + 1)
                for y in 0..<cy { screen[y] = blankLine() }
            case 3:
                scrollback.removeAll()
                fallthrough
            default:
                screen = (0..<rows).map { _ in blankLine() }
            }
        case "K":
            switch p.first ?? 0 {
            case 0: erase(row: cy, from: cx, to: cols)
            case 1: erase(row: cy, from: 0, to: cx + 1)
            default: erase(row: cy, from: 0, to: cols)
            }
        case "L": if (top...bottom).contains(cy) { scrollDown(n, from: cy) }
        case "M": if (top...bottom).contains(cy) { scrollUp(n, from: cy) }
        case "P":
            let count = min(n, cols - cx)
            screen[cy].removeSubrange(cx..<(cx + count))
            screen[cy].append(contentsOf: [Cell](repeating: Cell(style: TermStyle(bg: style.bg)), count: count))
        case "@":
            let count = min(n, cols - cx)
            screen[cy].insert(contentsOf: [Cell](repeating: Cell(style: TermStyle(bg: style.bg)), count: count), at: cx)
            screen[cy].removeLast(count)
        case "X": erase(row: cy, from: cx, to: cx + n)
        case "S": scrollUp(n)
        case "T": scrollDown(n)
        case "r":
            let t = arg(0) - 1, b = arg(1, rows) - 1
            if t < b, b < rows { top = t; bottom = b }
            cx = 0; cy = 0
        case "s": saved = (cx, cy, style)
        case "u": restoreCursor()
        case "m": sgr(body.replacingOccurrences(of: ":", with: ";").split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 })
        case "h", "l":
            guard isPrivate else { break }
            let on = final == "h"
            for mode in p {
                switch mode {
                case 1: appCursor = on
                case 25: cursorVisible = on
                case 2004: bracketedPaste = on
                case 47, 1047, 1049: alternateScreen(on)
                default: break
                }
            }
        case "n":
            if p.first == 6 { onReply?("\u{1B}[\(cy + 1);\(cx + 1)R") }
            if p.first == 5 { onReply?("\u{1B}[0n") }
        case "c":
            if !params.hasPrefix(">") { onReply?("\u{1B}[?1;2c") }
        default:
            break
        }
    }

    private func alternateScreen(_ on: Bool) {
        if on, mainScreen == nil {
            mainScreen = (screen, cx, cy)
            screen = (0..<rows).map { _ in blankLine() }
            cx = 0; cy = 0
        } else if !on, let main = mainScreen {
            mainScreen = nil
            screen = main.screen.map(fit)
            while screen.count < rows { screen.append(blankLine()) }
            screen = Array(screen.prefix(rows))
            cx = min(main.x, cols - 1)
            cy = min(main.y, rows - 1)
        }
        top = 0
        bottom = rows - 1
    }

    private func sgr(_ codes: [Int]) {
        var i = 0
        let list = codes.isEmpty ? [0] : codes
        while i < list.count {
            let c = list[i]
            switch c {
            case 0: style = TermStyle()
            case 1: style.bold = true
            case 22: style.bold = false
            case 4: style.underline = true
            case 24: style.underline = false
            case 7: style.inverse = true
            case 27: style.inverse = false
            case 30...37: style.fg = TerminalPalette.color(c - 30)
            case 90...97: style.fg = TerminalPalette.color(c - 90 + 8)
            case 39: style.fg = nil
            case 40...47: style.bg = TerminalPalette.color(c - 40)
            case 100...107: style.bg = TerminalPalette.color(c - 100 + 8)
            case 49: style.bg = nil
            case 38, 48:
                var color: NSColor?
                if i + 2 < list.count, list[i + 1] == 5 {
                    color = TerminalPalette.color(list[i + 2])
                    i += 2
                } else if i + 4 < list.count, list[i + 1] == 2 {
                    color = NSColor(srgbRed: CGFloat(list[i + 2]) / 255, green: CGFloat(list[i + 3]) / 255,
                                    blue: CGFloat(list[i + 4]) / 255, alpha: 1)
                    i += 4
                }
                if c == 38 { style.fg = color } else { style.bg = color }
            default: break
            }
            i += 1
        }
    }
}

enum TerminalPalette {
    private static let base: [(Int, Int, Int)] = [
        (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16), (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
        (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67), (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
    ]

    static func color(_ index: Int) -> NSColor {
        let rgb: (Int, Int, Int)
        switch index {
        case 0..<16: rgb = base[index]
        case 16..<232:
            let i = index - 16
            let step = { (v: Int) in v == 0 ? 0 : 55 + v * 40 }
            rgb = (step(i / 36), step(i / 6 % 6), step(i % 6))
        case 232..<256:
            let g = 8 + (index - 232) * 10
            rgb = (g, g, g)
        default: rgb = (229, 229, 229)
        }
        return NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    }
}

final class TerminalView: NSView, NSTextInputClient {
    let emulator = TerminalEmulator(cols: 80, rows: 24)
    var onInput: ((String) -> Void)?
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private lazy var boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    private(set) lazy var cellSize = NSSize(width: ("M" as NSString).size(withAttributes: [.font: font]).width,
                                            height: ceil(font.ascender - font.descender + font.leading) + 2)
    private var marked = ""
    static var onSelect: ((String) -> Void)?
    private var anchor: (line: Int, col: Int)?
    private var selection: (start: (line: Int, col: Int), end: (line: Int, col: Int))?
    private var blinkTimer: Timer?
    private var blinkOn = true
    let padding: CGFloat = 6

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { resetBlink(); return true }
    override func resignFirstResponder() -> Bool {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true
        needsDisplay = true
        return true
    }

    func resetBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true
        needsDisplay = true
        guard Settings.terminalCursorBlink else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.window?.firstResponder === self else {
                self.blinkTimer?.invalidate()
                self.blinkTimer = nil
                return
            }
            self.blinkOn.toggle()
            self.setNeedsDisplay(self.cursorRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if selection != nil {
            selection = nil
            needsDisplay = true
        }
        anchor = Self.onSelect == nil ? nil : position(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let end = position(event)
        selection = (anchor.line, anchor.col) < (end.line, end.col) ? (anchor, end) : (end, anchor)
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
        let text = selectedText
        if !text.isEmpty { Self.onSelect?(text) }
    }

    private func position(_ event: NSEvent) -> (line: Int, col: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let line = min(max(Int(point.y / cellSize.height), 0), totalLines - 1)
        let col = min(max(Int(((point.x - padding) / cellSize.width).rounded()), 0), emulator.cols)
        return (line, col)
    }

    var selectedText: String {
        guard let selection, selection.start != selection.end else { return "" }
        return (selection.start.line...selection.end.line).map { index in
            let cells = line(index)
            let from = index == selection.start.line ? selection.start.col : 0
            let to = min(index == selection.end.line ? selection.end.col : cells.count, cells.count)
            guard from < to else { return "" }
            let text = cells[from..<to].filter { $0.width != 0 }.map(\.ch).joined()
            return String(text.reversed().drop { $0 == " " }.reversed())
        }.joined(separator: "\n")
    }

    var totalLines: Int { emulator.scrollback.count + emulator.rows }

    private func line(_ index: Int) -> [Cell] {
        let sb = emulator.scrollback
        return index < sb.count ? sb[index] : emulator.screen[index - sb.count]
    }

    private var cursorRect: NSRect {
        NSRect(x: padding + CGFloat(emulator.cx) * cellSize.width,
               y: CGFloat(emulator.scrollback.count + emulator.cy) * cellSize.height,
               width: cellSize.width, height: cellSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let defaultFg = NSColor.textColor
        let defaultBg = Settings.surfaceColor(.feed) ?? .textBackgroundColor
        defaultBg.setFill()
        dirtyRect.fill()

        let h = cellSize.height, w = cellSize.width
        let first = max(Int(dirtyRect.minY / h), 0)
        let last = min(Int(ceil(dirtyRect.maxY / h)), totalLines)
        guard first < last else { return }

        for row in first..<last {
            let cells = line(row)
            let y = CGFloat(row) * h
            var run = ""
            var runStart = 0
            var runStyle = TermStyle()

            if let selection, selection.start.line <= row, row <= selection.end.line {
                let from = row == selection.start.line ? selection.start.col : 0
                let to = row == selection.end.line ? selection.end.col : emulator.cols
                NSColor.selectedTextBackgroundColor.setFill()
                NSRect(x: padding + CGFloat(from) * w, y: y, width: CGFloat(max(to - from, 0)) * w, height: h).fill()
            }

            func colors(_ s: TermStyle) -> (NSColor, NSColor?) {
                let fg = s.fg ?? defaultFg
                return s.inverse ? (s.bg ?? defaultBg, fg) : (fg, s.bg)
            }
            func flush() {
                guard !run.isEmpty else { return }
                let (fg, _) = colors(runStyle)
                var attrs: [NSAttributedString.Key: Any] = [.font: runStyle.bold ? boldFont : font, .foregroundColor: fg]
                if runStyle.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                (run as NSString).draw(at: NSPoint(x: padding + CGFloat(runStart) * w, y: y + 1), withAttributes: attrs)
                run = ""
            }

            for (x, cell) in cells.enumerated() {
                let (_, bg) = colors(cell.style)
                if let bg {
                    bg.setFill()
                    NSRect(x: padding + CGFloat(x) * w, y: y, width: w * CGFloat(max(cell.width, 1)), height: h).fill()
                }
                if cell.width == 0 { continue }
                let ascii = cell.width == 1 && cell.ch.unicodeScalars.count == 1 && cell.ch.unicodeScalars.first!.isASCII
                if ascii, cell.style == runStyle, !run.isEmpty, runStart + run.count == x {
                    run += cell.ch
                    continue
                }
                flush()
                if ascii {
                    run = cell.ch
                    runStart = x
                    runStyle = cell.style
                } else {
                    run = cell.ch
                    runStart = x
                    runStyle = cell.style
                    flush()
                }
            }
            flush()
        }

        if emulator.cursorVisible {
            let rect = cursorRect
            if !marked.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: defaultFg,
                                                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                                                            .backgroundColor: defaultBg]
                (marked as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY + 1), withAttributes: attrs)
            } else if Settings.terminalCursorBar {
                if window?.firstResponder !== self || blinkOn {
                    NSColor.textColor.withAlphaComponent(window?.firstResponder === self ? 0.85 : 0.4).setFill()
                    NSRect(x: rect.minX, y: rect.minY + 1, width: 2, height: rect.height - 2).fill()
                }
            } else if window?.firstResponder === self {
                if blinkOn {
                    NSColor.textColor.withAlphaComponent(0.5).setFill()
                    rect.fill()
                }
            } else {
                NSColor.textColor.withAlphaComponent(0.5).setStroke()
                NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if selection != nil {
            selection = nil
            needsDisplay = true
        }
        if Settings.terminalCursorBlink { resetBlink() }
        if !marked.isEmpty {
            interpretKeyEvents([event])
            return
        }
        let flags = event.modifierFlags
        if let special = specialKey(event) {
            onInput?(special)
            return
        }
        if flags.contains(.control), let c = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first,
           (0x40...0x7F).contains(c.value) || c == " " {
            onInput?(String(UnicodeScalar(UInt8(c.value & 0x1F))))
            return
        }
        if flags.contains(.option), let c = event.charactersIgnoringModifiers, !c.isEmpty,
           c.unicodeScalars.allSatisfy({ $0.isASCII }) {
            onInput?("\u{1B}" + c)
            return
        }
        interpretKeyEvents([event])
    }

    private func specialKey(_ event: NSEvent) -> String? {
        guard let c = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        let option = event.modifierFlags.contains(.option)
        let prefix = emulator.appCursor ? "\u{1B}O" : "\u{1B}["
        switch Int(c.value) {
        case NSUpArrowFunctionKey: return prefix + "A"
        case NSDownArrowFunctionKey: return prefix + "B"
        case NSRightArrowFunctionKey: return option ? "\u{1B}f" : prefix + "C"
        case NSLeftArrowFunctionKey: return option ? "\u{1B}b" : prefix + "D"
        case NSHomeFunctionKey: return "\u{1B}[H"
        case NSEndFunctionKey: return "\u{1B}[F"
        case NSPageUpFunctionKey: return "\u{1B}[5~"
        case NSPageDownFunctionKey: return "\u{1B}[6~"
        case NSDeleteFunctionKey: return "\u{1B}[3~"
        case 0x0D, 0x03: return "\r"
        case 0x7F: return option ? "\u{1B}\u{7F}" : "\u{7F}"
        case 0x09: return "\t"
        case 0x19: return "\u{1B}[Z"
        case 0x1B: return "\u{1B}"
        default: return nil
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let body = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        onInput?(emulator.bracketedPaste ? "\u{1B}[200~" + body + "\u{1B}[201~" : body)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = ""
        needsDisplay = true
        if !text.isEmpty { onInput?(text) }
    }

    override func doCommand(by selector: Selector) {}

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        needsDisplay = true
    }

    func unmarkText() { marked = ""; needsDisplay = true }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (marked as NSString).length) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(cursorRect, to: nil))
    }
}

final class TerminalPane: NSView {
    let terminal = TerminalView()
    private let scroll = NSScrollView()
    private let pty = PTY()
    private let cwd: String
    private let command: String?
    private var started = false
    var onExit: (() -> Void)?

    init(cwd: String, command: String? = nil) {
        self.cwd = cwd
        self.command = command
        super.init(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.documentView = terminal
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)

        terminal.onInput = { [weak self] in self?.pty.write($0) }
        terminal.emulator.onReply = { [weak self] in self?.pty.write($0) }
        pty.onOutput = { [weak self] in self?.receive($0) }
        pty.onExit = { [weak self] in
            self?.exited = true
            self?.onExit?()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applyColors), name: .settingsChanged, object: nil)
        applyColors()
    }

    @objc private func applyColors() {
        paint(.feed)
        scroll.backgroundColor = Settings.surfaceColor(.feed) ?? .textBackgroundColor
        if window?.firstResponder === terminal { terminal.resetBlink() } else { terminal.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { pty.terminate() }

    func stop() { pty.terminate() }

    var running: Bool { pty.pid > 0 && started && !exited }
    private var exited = false

    func show(_ text: String) {
        terminal.emulator.feed(text)
        updateDocumentSize(stickToBottom: true)
        terminal.needsDisplay = true
    }

    func focus() { window?.makeFirstResponder(terminal) }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let size = scroll.contentSize
        let cols = max(Int((size.width - terminal.padding * 2) / terminal.cellSize.width), 10)
        let rows = max(Int(size.height / terminal.cellSize.height), 3)
        if size.height > 0, !started {
            started = true
            terminal.emulator.resize(cols: cols, rows: rows)
            if !pty.start(cwd: cwd, cols: cols, rows: rows, command: command) {
                terminal.emulator.feed("シェルを起動できませんでした\r\n")
            }
        } else if cols != terminal.emulator.cols || rows != terminal.emulator.rows {
            terminal.emulator.resize(cols: cols, rows: rows)
            pty.resize(cols: cols, rows: rows)
        }
        updateDocumentSize(stickToBottom: true)
    }

    private func receive(_ text: String) {
        let clip = scroll.contentView
        let atBottom = clip.bounds.maxY >= terminal.frame.height - terminal.cellSize.height
        terminal.emulator.feed(text)
        updateDocumentSize(stickToBottom: atBottom)
        terminal.needsDisplay = true
    }

    private func updateDocumentSize(stickToBottom: Bool) {
        let size = scroll.contentSize
        let height = max(size.height, CGFloat(terminal.totalLines) * terminal.cellSize.height)
        if terminal.frame.size != NSSize(width: size.width, height: height) {
            terminal.frame = NSRect(x: 0, y: 0, width: size.width, height: height)
        }
        if stickToBottom {
            terminal.scroll(NSPoint(x: 0, y: height - size.height))
        }
    }
}

final class TerminalFeed: NSView {
    var onRemove: (() -> Void)?
    var onEmpty: (() -> Void)?
    private let cwd: String
    private let bar: TabStrip
    private let container = NSView()
    private var plus: NSButton!
    private var sessions: [(tab: TabItemView, pane: TerminalPane)] = []
    private var counter = 0
    private(set) var selected: TerminalPane?

    init(cwd: String) {
        self.cwd = cwd
        let minus = FeedView.barButton(symbol: "minus", tip: "フィードを閉じる", target: nil, action: nil)
        bar = TabStrip(trailing: minus)
        super.init(frame: .zero)
        minus.target = self
        minus.action = #selector(minusClicked)
        plus = FeedView.barButton(symbol: "plus", tip: "新しいターミナル", target: self, action: #selector(plusClicked))
        bar.stack.addArrangedSubview(plus)
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        addSubview(container)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: bar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addSession()
    }

    required init?(coder: NSCoder) { fatalError() }

    func addSession() {
        counter += 1
        let pane = TerminalPane(cwd: cwd)
        let tab = TabItemView(title: counter == 1 ? "ターミナル" : "ターミナル \(counter)", closable: true)
        tab.onSelect = { [weak self, weak pane] in if let pane { self?.select(pane) } }
        tab.onClose = { [weak self, weak pane] in if let pane { self?.close(pane) } }
        tab.onRename = { [weak tab] in tab?.title = $0 }
        tab.draggable = true
        pane.onExit = { [weak self, weak pane] in if let pane { self?.close(pane) } }
        pane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: container.topAnchor),
            pane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        bar.stack.insertArrangedSubview(tab, at: bar.stack.arrangedSubviews.count - 1)
        sessions.append((tab, pane))
        select(pane)
    }

    private func select(_ pane: TerminalPane) {
        selected = pane
        for session in sessions {
            session.tab.selected = session.pane === pane
            session.pane.isHidden = session.pane !== pane
        }
        if let tab = sessions.first(where: { $0.pane === pane })?.tab { bar.reveal(tab) }
        DispatchQueue.main.async { pane.focus() }
    }

    private func close(_ pane: TerminalPane) {
        guard let index = sessions.firstIndex(where: { $0.pane === pane }) else { return }
        let order = bar.stack.arrangedSubviews.compactMap { view in sessions.first { $0.tab === view } }
        let position = order.firstIndex { $0.pane === pane } ?? index
        let session = sessions.remove(at: index)
        session.pane.onExit = nil
        session.pane.stop()
        session.pane.removeFromSuperview()
        session.tab.removeFromSuperview()
        if sessions.isEmpty {
            selected = nil
            onEmpty?()
        } else if selected === pane {
            let rest = order.filter { $0.pane !== pane }
            select(rest[min(position, rest.count - 1)].pane)
        }
    }

    func focus() { selected?.focus() }

    func stopAll() { sessions.forEach { $0.pane.stop() } }

    @objc private func plusClicked() { addSession() }

    @objc private func minusClicked() { onRemove?() }
}
