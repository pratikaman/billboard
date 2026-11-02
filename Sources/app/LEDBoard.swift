// LED sign theme: an amber dot-matrix destination sign (like the Transign / Twin Vision bus signs). Every
// dot of the matrix is visible, lit or not. Text uses a 5x7 font; a column too long to fit scrolls like a
// ticker; changed text rolls up one dot row at a time, the way LED signs change.
import AppKit
import QuartzCore

// MARK: - 5x7 font

private let font5x7: [Character: [String]] = [
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
    "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
    "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
    "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
    "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
    "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
    ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
    ",": [".....", ".....", ".....", ".....", ".##..", "..#..", ".#..."],
    ":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
    "-": [".....", ".....", ".....", ".###.", ".....", ".....", "....."],
    "/": [".....", "....#", "...#.", "..#..", ".#...", "#....", "....."],
    "'": [".##..", "..#..", ".#...", ".....", ".....", ".....", "....."],
    "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
    "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
    "&": [".##..", "#..#.", "#.#..", ".#...", "#.#.#", "#..#.", ".##.#"],
    "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
    "#": [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],
    "_": [".....", ".....", ".....", ".....", ".....", ".....", "#####"],
    "(": ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],
    ")": [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],
    "@": [".###.", "#...#", "#.###", "#.#.#", "#.###", "#....", ".###."],
    "*": [".....", "#.#.#", ".###.", "#####", ".###.", "#.#.#", "....."],
    ">": [".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..."],
]

private func ledText(_ s: String) -> [Character] {
    let t = s.folding(options: [.diacriticInsensitive], locale: .current).uppercased()
    var out = t.map { font5x7[$0] != nil ? $0 : " " }
    out = out.enumerated().filter { i, c in !(c == " " && i > 0 && out[i - 1] == " ") }.map(\.1)
    while out.first == " " { out.removeFirst() }
    while out.last == " " { out.removeLast() }
    return out
}

// MARK: - Layout (in dots)

private struct LEDLayout {
    var scale: CGFloat = 1
    var rows = 1
    static let colChars = [5, 11, 24, 9]       // TIME, SESSION, NOW, STATUS
    static let gaps = [11, 8, 8]               // the first gap holds the agent mark
    static let margin = 4
    static let rowDots = 11                    // 7 lit rows + 4 spacing

    var p: CGFloat { 1.8 * scale }             // dot pitch
    var frameW: CGFloat { 7 * scale }
    var rodLen: CGFloat { 18 * scale }
    var shadowPad: CGFloat { 18 * scale }

    static var gridCols: Int { margin * 2 + colChars.reduce(0, +) * 6 - 1 + gaps.reduce(0, +) }
    var gridRows: Int { rows * Self.rowDots - 4 + 6 }

    var display: CGRect {
        CGRect(x: shadowPad + frameW, y: rodLen + frameW, width: CGFloat(Self.gridCols) * p, height: CGFloat(gridRows) * p)
    }
    var board: CGRect { display.insetBy(dx: -frameW, dy: -frameW) }
    var windowSize: CGSize { CGSize(width: board.width + shadowPad * 2, height: rodLen + board.height + shadowPad) }

    func colDot(_ c: Int) -> Int {
        var x = Self.margin
        for i in 0..<c { x += Self.colChars[i] * 6 - 1 + Self.gaps[i] }
        return x
    }
    /// Width in dots of column c (column 4 is the one-glyph agent mark).
    static func width(_ c: Int) -> Int { c == 4 ? 5 : colChars[c] * 6 - 1 }
    /// Rect of column c in row r (exactly the 7 dot rows of text).
    func cell(row r: Int, col c: Int) -> CGRect {
        let xDot = c == 4 ? colDot(0) + Self.width(0) + 3 : colDot(c)
        let x = display.minX + CGFloat(xDot) * p
        let y = display.minY + CGFloat(3 + r * Self.rowDots) * p
        return CGRect(x: x, y: y, width: CGFloat(Self.width(c)) * p, height: 7 * p)
    }
}

// MARK: - View

private struct LEDCell {
    var text: [Character] = []
    var color = 0
    var prevText: [Character] = []
    var prevColor = 0
    var rollStart: CFTimeInterval = -10
    var hidden = false
    var marqueeStart: CFTimeInterval = 0
}

final class LEDBoardView: NSView, ThemeView {
    private var L = LEDLayout()
    private var cells: [[LEDCell]] = []
    private var background: CGImage?
    private var strips: [String: CGImage] = [:]
    private var sprites: [Int: CGImage] = [:]
    private var timer: Timer?
    var onFlap: ((Int) -> Void)?

    static let amber = 0xffa41c, dimAmber = 0x6b4810, claudeMark = 0xff6a3d, codexMark = 0xe8eef8
    static let statusColor: [SessionState: Int] = [.working: 0x4aa3ff, .needs: 0xffd21f, .turn: 0x39e26a, .error: 0xff3b30, .idle: 0x6b4810]
    static let rollStep: CFTimeInterval = 0.032
    static let marqueeStep: CFTimeInterval = 0.045

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    var windowSize: CGSize { L.windowSize }
    var boardRect: CGRect { L.board }

    func configure(rows: Int, scale: CGFloat) {
        if scale != L.scale { strips.removeAll(); sprites.removeAll() }
        L.rows = rows
        L.scale = scale
        while cells.count < rows { cells.append(Array(repeating: LEDCell(), count: 5)) }
        if cells.count > rows { cells.removeLast(cells.count - rows) }
        background = nil
        needsDisplay = true
    }

    func show(_ rows: [RowData]) {
        let now = CACurrentMediaTime()
        for (r, row) in rows.enumerated() where r < cells.count {
            let textColor = row.state == .idle ? Self.dimAmber : Self.amber
            let cols: [(String, Int)] = [
                (row.time, textColor),
                (String(flapText(row.name, LEDLayout.colChars[1])).trimmingCharacters(in: .whitespaces), textColor),
                (row.activity, textColor),
                (row.placeholder ? "" : row.statusWord, Self.statusColor[row.state] ?? Self.amber),
                (row.placeholder ? "" : (row.agent == .claude ? "*" : ">"), row.agent == .claude ? Self.claudeMark : Self.codexMark),
            ]
            for (c, (s, color)) in cols.enumerated() {
                let t = ledText(s)
                var cell = cells[r][c]
                if cell.text != t || cell.color != color {
                    cell.prevText = cell.text
                    cell.prevColor = cell.color
                    cell.text = t
                    cell.color = color
                    cell.rollStart = now + Double(c) * 0.06
                    cell.marqueeStart = now + 8 * Self.rollStep + 1.5
                    onFlap?(1)
                }
                let hide = c == 3 && row.state == .needs && !row.blinkOn
                if hide != cell.hidden { cell.hidden = hide; setNeedsDisplay(L.cell(row: r, col: c).insetBy(dx: -L.p, dy: -L.p)) }
                cells[r][c] = cell
            }
        }
        startTimer()
    }

    func settle() {
        for r in cells.indices { for c in cells[r].indices { cells[r][c].rollStart = -10; cells[r][c].marqueeStart = CACurrentMediaTime() + 100 } }
        needsDisplay = true
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var busy = false
        for r in cells.indices { for c in cells[r].indices {
            let cell = cells[r][c]
            let rolling = now - cell.rollStart < 9 * Self.rollStep
            let scrolls = cell.text.count * 6 - 1 > LEDLayout.width(c)
            if rolling || now < cell.rollStart || scrolls {
                busy = true
                setNeedsDisplay(L.cell(row: r, col: c).insetBy(dx: -L.p, dy: -L.p))
            }
        } }
        if !busy { timer?.invalidate(); timer = nil }
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if background == nil { background = renderBackground() }
        if let bg = background { drawFlipped(ctx, bg, in: bounds) }
        let now = CACurrentMediaTime()
        for r in cells.indices { for c in cells[r].indices {
            let rect = L.cell(row: r, col: c)
            guard rect.insetBy(dx: -L.p, dy: -L.p).intersects(dirty) else { continue }
            drawCell(ctx, cells[r][c], rect: rect, col: c, now: now)
        } }
    }

    private func drawCell(_ ctx: CGContext, _ cell: LEDCell, rect: CGRect, col: Int, now: CFTimeInterval) {
        guard !cell.hidden else { return }
        let p = L.p
        if col == 4, let mark = cell.text.first, mark == ">" || mark == "*", now - cell.rollStart > 0 {   // a backlit logo badge
            let side = 7 * p
            ctx.saveGState()
            let px = window?.backingScaleFactor ?? 2
            ctx.setShadow(offset: .zero, blur: 2.2 * p * px, color: rgb(cell.color, 0.7).cgColor)
            drawAgentLogo(ctx, mark == "*" ? .claude : .codex, in: CGRect(x: rect.midX - side / 2, y: rect.minY, width: side, height: side), color: rgb(cell.color))
            ctx.restoreGState()
            return
        }
        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: -p * 0.5, dy: -p * 0.5))
        let elapsed = now - cell.rollStart
        let step = elapsed < 0 ? 0 : min(8, Int(elapsed / Self.rollStep))
        if step < 8 {   // roll: old text moves up and out, new text comes up from below, one dot row per step
            drawStrip(ctx, cell.prevText, color: cell.prevColor, x: rect.minX, y: rect.minY - CGFloat(step) * p)
            drawStrip(ctx, cell.text, color: cell.color, x: rect.minX, y: rect.minY + CGFloat(8 - step) * p)
        } else {
            let textW = cell.text.count * 6 - 1
            let colW = Int((rect.width / p).rounded())
            if textW > colW {   // ticker: scroll left in whole dots, pause at the start of each lap
                let lap = textW + 18
                let t = max(0, now - cell.marqueeStart)
                let lapTime = Double(lap) * Self.marqueeStep + 2.0
                let inLap = t.truncatingRemainder(dividingBy: lapTime)
                let off = inLap < 2.0 ? 0 : Int((inLap - 2.0) / Self.marqueeStep)
                drawStrip(ctx, cell.text, color: cell.color, x: rect.minX - CGFloat(off) * p, y: rect.minY)
                drawStrip(ctx, cell.text, color: cell.color, x: rect.minX + CGFloat(lap - off) * p, y: rect.minY)
            } else {
                drawStrip(ctx, cell.text, color: cell.color, x: rect.minX, y: rect.minY)
            }
        }
        ctx.restoreGState()
    }

    private func drawStrip(_ ctx: CGContext, _ text: [Character], color: Int, x: CGFloat, y: CGFloat) {
        guard !text.isEmpty, let img = strip(text, color: color) else { return }
        let pad = L.p
        let w = CGFloat(text.count * 6 - 1) * L.p
        drawFlipped(ctx, img, in: CGRect(x: x - pad, y: y - pad, width: w + pad * 2, height: 7 * L.p + pad * 2))
    }

    /// Lit dots for a line of text (glow included), cached per text and colour.
    private func strip(_ text: [Character], color: Int) -> CGImage? {
        let key = "\(color)|" + String(text)
        if let s = strips[key] { return s }
        let p = L.p, pad = p
        let size = CGSize(width: CGFloat(text.count * 6 - 1) * p + pad * 2, height: 7 * p + pad * 2)
        let px = window?.backingScaleFactor ?? 2
        guard let ctx = makeFlippedContext(size: size, scale: px), let dot = sprite(color) else { return nil }
        for (i, ch) in text.enumerated() {
            guard let rowsBits = font5x7[ch] else { continue }
            for (yy, line) in rowsBits.enumerated() {
                for (xx, bit) in line.enumerated() where bit == "#" {
                    let cx = pad + CGFloat(i * 6 + xx) * p + p / 2
                    let cy = pad + CGFloat(yy) * p + p / 2
                    drawFlipped(ctx, dot, in: CGRect(x: cx - p, y: cy - p, width: p * 2, height: p * 2))
                }
            }
        }
        if strips.count > 400 { strips.removeAll() }
        strips[key] = ctx.makeImage()
        return strips[key]
    }

    /// One lit LED: a soft glow halo and a bright domed core.
    private func sprite(_ color: Int) -> CGImage? {
        if let s = sprites[color] { return s }
        let p = L.p
        let px = window?.backingScaleFactor ?? 2
        let size = CGSize(width: p * 2, height: p * 2)
        guard let ctx = makeFlippedContext(size: size, scale: px) else { return nil }
        let c = CGPoint(x: p, y: p)
        let base = rgb(color)
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [base.withAlphaComponent(0.42).cgColor, base.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: p, options: [])
        let r = 0.68 * p
        let hot = base.blended(withFraction: 0.55, of: .white)!
        let core = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [hot.cgColor, base.cgColor, base.blended(withFraction: 0.25, of: .black)!.cgColor] as CFArray,
                              locations: [0, 0.55, 1])!
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
        ctx.drawRadialGradient(core, startCenter: CGPoint(x: c.x - r * 0.2, y: c.y - r * 0.25), startRadius: 0, endCenter: c, endRadius: r, options: [])
        ctx.restoreGState()
        sprites[color] = ctx.makeImage()
        return sprites[color]
    }

    // MARK: background: cables, black housing, tinted glass, every unlit dot

    private func renderBackground() -> CGImage? {
        let px = window?.backingScaleFactor ?? 2
        guard let ctx = makeFlippedContext(size: bounds.size, scale: px) else { return nil }
        let b = L.board, d = L.display, s = L.scale, p = L.p

        // hanging cables with ceiling cups and crimp sleeves
        for f: CGFloat in [0.1, 0.9] {
            let cx = (b.minX + b.width * f).rounded()
            let cable = CGRect(x: cx - 0.6 * s, y: 0, width: 1.2 * s, height: L.rodLen + 1)
            ctx.saveGState(); ctx.clip(to: cable)
            linearGradient(ctx, [rgb(0x3a3a3c), rgb(0x9a9a9e), rgb(0x2a2a2c)], from: CGPoint(x: cable.minX, y: 0), to: CGPoint(x: cable.maxX, y: 0))
            ctx.restoreGState()
            ctx.setFillColor(rgb(0x1b1b1c).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: cx - 4 * s, y: 0, width: 8 * s, height: 2.5 * s), cornerWidth: 1 * s, cornerHeight: 1 * s, transform: nil)); ctx.fillPath()
            let sleeve = CGRect(x: cx - 1.6 * s, y: L.rodLen - 5 * s, width: 3.2 * s, height: 5 * s)
            ctx.saveGState(); ctx.clip(to: sleeve)
            linearGradient(ctx, [rgb(0x555558), rgb(0xc8c8cc), rgb(0x48484b)], from: CGPoint(x: sleeve.minX, y: 0), to: CGPoint(x: sleeve.maxX, y: 0))
            ctx.restoreGState()
        }

        // housing: black anodised aluminium with a soft shadow and a lit top edge
        let rad = 4 * s
        let housing = CGPath(roundedRect: b, cornerWidth: rad, cornerHeight: rad, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s * px), blur: 16 * s * px, color: NSColor(white: 0, alpha: 0.5).cgColor)
        ctx.addPath(housing); ctx.setFillColor(rgb(0x161617).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(housing); ctx.clip()
        linearGradient(ctx, [rgb(0x2b2b2d), rgb(0x161617), rgb(0x101011)], from: CGPoint(x: 0, y: b.minY), to: CGPoint(x: 0, y: b.maxY), locations: [0, 0.4, 1])
        ctx.setFillColor(NSColor(white: 1, alpha: 0.14).cgColor); ctx.fill(CGRect(x: b.minX, y: b.minY, width: b.width, height: 0.6 * s))
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: b.insetBy(dx: 0.25, dy: 0.25), cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor); ctx.setLineWidth(0.5); ctx.strokePath()

        // display window: near-black behind smoked glass
        ctx.setFillColor(rgb(0x050505).cgColor); ctx.fill(d)
        // unlit LEDs: dull dark dots over the whole matrix
        let off = rgb(0x231f1a)
        let r = 0.62 * p
        ctx.setFillColor(off.cgColor)
        for gy in 0..<L.gridRows {
            for gx in 0..<LEDLayout.gridCols {
                let cx = d.minX + (CGFloat(gx) + 0.5) * p, cy = d.minY + (CGFloat(gy) + 0.5) * p
                ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            }
        }
        ctx.fillPath()
        // glass: inner shadow at the top edge and a faint diagonal sheen
        ctx.saveGState(); ctx.clip(to: d)
        linearGradient(ctx, [NSColor(white: 0, alpha: 0.55), NSColor(white: 0, alpha: 0)], from: CGPoint(x: 0, y: d.minY), to: CGPoint(x: 0, y: d.minY + 3 * s))
        linearGradient(ctx, [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 0.035), NSColor(white: 1, alpha: 0)],
                       from: CGPoint(x: d.minX + d.width * 0.25, y: d.minY), to: CGPoint(x: d.minX + d.width * 0.45, y: d.maxY), locations: [0, 0.5, 1])
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.9).cgColor); ctx.setLineWidth(0.8 * s); ctx.stroke(d)
        return ctx.makeImage()
    }
}
