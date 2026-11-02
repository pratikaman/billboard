// The split-flap board, styled after Vestaboard: a matte charcoal face with a continuous grid of recessed
// pockets, each holding a two-part flap; thin light characters; solid colour tiles. Everything is drawn in
// code (crisp at any size). Cells flip through the drum toward their target one flap at a time.
import AppKit
import QuartzCore

// MARK: - Glyphs

enum FlapStyle: Int { case dark, dim, red, orange, yellow, green, blue, violet }

struct Glyph: Hashable {
    var ch: Character
    var style: FlapStyle
    static let blank = Glyph(ch: " ", style: .dark)
    static func tile(_ s: FlapStyle) -> Glyph { Glyph(ch: " ", style: s) }
}

let drum: [Character] = Array(" ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,:-/'?!&+#_()")
let drumIndex: [Character: Int] = Dictionary(uniqueKeysWithValues: drum.enumerated().map { ($1, $0) })

/// Uppercases, strips accents, maps anything the drum can't show to a space, and fits to n cells
/// (cutting at a word boundary when that keeps most of the text).
func flapText(_ s: String, _ n: Int) -> [Character] {
    var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
    t = t.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "…", with: "...")
    var chars = t.map { drumIndex[$0] != nil ? $0 : " " }
    chars = chars.enumerated().filter { i, c in !(c == " " && i > 0 && chars[i - 1] == " ") }.map(\.1)
    while chars.first == " " { chars.removeFirst() }
    if chars.count > n {
        let cut = chars[0...n].lastIndex(of: " ")
        chars = Array(chars[0..<((cut ?? 0) >= n * 3 / 5 ? cut! : n)])
        while chars.last == " " || chars.last == "-" || chars.last == "," { chars.removeLast() }
        // don't end on a dangling filler word ("REBUILD, RELAUNCH AND")
        let fillers: Set<String> = ["AND", "THE", "TO", "OF", "A", "AN", "FOR", "IN", "ON", "WITH", "ITS", "OR"]
        if let sp = chars.lastIndex(of: " "), sp > n / 2, fillers.contains(String(chars[(sp + 1)...])) {
            chars = Array(chars[..<sp])
            while chars.last == " " || chars.last == "," { chars.removeLast() }
        }
    }
    return chars + Array(repeating: " ", count: max(0, n - chars.count))
}

// MARK: - Palette (sampled from Vestaboard product photos, neutralised)

enum Pal {
    static let face = (top: rgb(0x2a2a2c), bottom: rgb(0x222224))
    static let pocket = rgb(0x0b0b0c)
    static let flapTop = (rgb(0x252527), rgb(0x1f1f21))
    static let flapBottom = (rgb(0x1c1c1e), rgb(0x18181a))
    static let ink = rgb(0xe8e7e3)
    static let inkDim = rgb(0x77777a)
    static let label = rgb(0x8d8d90)
    static let tiles: [FlapStyle: NSColor] = [
        .red: rgb(0xda291c), .orange: rgb(0xff7500), .yellow: rgb(0xffb81c),
        .green: rgb(0x009a44), .blue: rgb(0x0084d5), .violet: rgb(0x702f8a),
    ]
    static func rgb(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}

// MARK: - Layout

struct BoardLayout {
    var scale: CGFloat = 1
    var rows = 1
    /// Column spans in cells; columns are separated by one always-blank pocket, like words on a Vestaboard.
    static let cols = [5, 11, 24, 11]          // TIME, SESSION, NOW, STATUS
    static let labels = ["TIME", "SESSION", "NOW", "STATUS"]
    static var cellsPerRow: Int { cols.reduce(0, +) + cols.count - 1 }
    /// Grid index of the k-th content cell (skipping separators).
    static let gridIndex: [Int] = {
        var out: [Int] = [], g = 0
        for (c, n) in cols.enumerated() { for _ in 0..<n { out.append(g); g += 1 }; if c < cols.count - 1 { g += 1 } }
        return out
    }()

    var pitchX: CGFloat { 12 * scale }
    var pitchY: CGFloat { 21 * scale }
    var flapW: CGFloat { 9.6 * scale }
    var flapH: CGFloat { 16.5 * scale }
    var padX: CGFloat { 13 * scale }
    var headerH: CGFloat { 17 * scale }
    var padBottom: CGFloat { 9 * scale }
    var rodLen: CGFloat { 22 * scale }
    var shadowPad: CGFloat { 20 * scale }

    var boardW: CGFloat { padX * 2 + CGFloat(Self.cellsPerRow) * pitchX - (pitchX - flapW) }
    var boardH: CGFloat { headerH + CGFloat(rows) * pitchY - (pitchY - flapH) + padBottom + 4 * scale }
    var windowSize: CGSize { CGSize(width: boardW + shadowPad * 2, height: rodLen + boardH + shadowPad) }
    var board: CGRect { CGRect(x: shadowPad, y: rodLen, width: boardW, height: boardH) }

    /// The pocket (recess) for grid cell g in row r; the flap sits inside it.
    func pocket(row r: Int, grid g: Int) -> CGRect {
        CGRect(x: board.minX + padX + CGFloat(g) * pitchX, y: board.minY + headerH + 2 * scale + CGFloat(r) * pitchY,
               width: flapW, height: flapH)
    }
    func cellRect(row r: Int, k: Int) -> CGRect { pocket(row: r, grid: Self.gridIndex[k]).insetBy(dx: 0.6 * scale, dy: 0.6 * scale) }
    func columnX(_ c: Int) -> CGFloat { pocket(row: 0, grid: Self.gridIndex[Self.cols.prefix(c).reduce(0, +)]).minX }
}

// MARK: - Cells

private struct Cell {
    var cur = Glyph.blank
    var next: Glyph?
    var target = Glyph.blank
    var stepsLeft = 0
    var flipStart: CFTimeInterval = 0
    var startAfter: CFTimeInterval = 0
    var rect = CGRect.zero
}

final class FlipBoardView: NSView {
    private(set) var layout = BoardLayout()
    var onFlap: ((Int) -> Void)?          // number of flaps that started this frame (for sound)

    private var cells: [[Cell]] = []      // [row][content cell k]
    private var background: CGImage?
    private var glyphCache: [Glyph: (top: CGImage, bottom: CGImage, size: CGSize)] = [:]
    private var timer: Timer?
    var frozen: CFTimeInterval?

    static let flipDuration: CFTimeInterval = 0.07
    static let maxSteps = 9

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func configure(layout l: BoardLayout) {
        if l.scale != layout.scale { glyphCache.removeAll() }
        layout = l
        let n = BoardLayout.gridIndex.count
        while cells.count < l.rows { cells.append(Array(repeating: Cell(), count: n)) }
        if cells.count > l.rows { cells.removeLast(cells.count - l.rows) }
        for r in 0..<l.rows { for k in 0..<n { cells[r][k].rect = l.cellRect(row: r, k: k) } }
        background = nil
        needsDisplay = true
    }

    /// Sets one row. `glyphs` holds every content cell of the row (columns concatenated, no separators).
    func setRow(_ r: Int, _ glyphs: [Glyph]) {
        guard r < cells.count else { return }
        let now = CACurrentMediaTime()
        for (k, g) in glyphs.enumerated() where k < cells[r].count {
            retarget(&cells[r][k], g, now: now, delay: Double(k) * 0.011 + Double(r) * 0.045)
        }
        startTimer()
    }

    func settle() {
        for r in cells.indices { for k in cells[r].indices { cells[r][k].cur = cells[r][k].target; cells[r][k].next = nil } }
        timer?.invalidate(); timer = nil
        needsDisplay = true
    }

    /// Freezes every third changing cell at a fixed flip progress (QA snapshots of the flip itself).
    func freezeMidFlip(_ t: Double) {
        let now = CACurrentMediaTime()
        for r in cells.indices { for k in cells[r].indices where k % 3 == 0 && cells[r][k].cur != cells[r][k].target {
            let ti = drumIndex[cells[r][k].target.ch] ?? 0
            cells[r][k].next = Glyph(ch: drum[(ti - 1 + drum.count) % drum.count], style: cells[r][k].target.style)
            cells[r][k].flipStart = now - t * Self.flipDuration
        } }
        frozen = now
        needsDisplay = true
    }

    private func retarget(_ c: inout Cell, _ g: Glyph, now: CFTimeInterval, delay: Double) {
        guard c.target != g else { return }
        c.target = g
        let from = drumIndex[c.next?.ch ?? c.cur.ch] ?? 0, to = drumIndex[g.ch] ?? 0
        var dist = (to - from + drum.count) % drum.count
        if dist == 0 { dist = 1 }            // same letter, new colour: a single flap
        c.stepsLeft = min(dist, Self.maxSteps)
        if c.next == nil { c.startAfter = now + delay }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var busy = false, started = 0
        for r in cells.indices { for k in cells[r].indices {
            if let n = cells[r][k].next {
                setNeedsDisplay(cells[r][k].rect)
                if now - cells[r][k].flipStart >= Self.flipDuration { cells[r][k].cur = n; cells[r][k].next = nil }
                else { busy = true; continue }
            }
            var c = cells[r][k]
            guard c.cur != c.target else { continue }
            busy = true
            guard now >= c.startAfter else { continue }
            let ti = drumIndex[c.target.ch] ?? 0
            c.next = c.stepsLeft <= 1 ? c.target
                : Glyph(ch: drum[(ti - (c.stepsLeft - 1) + drum.count * 4) % drum.count], style: c.target.style)
            c.stepsLeft = max(0, c.stepsLeft - 1)
            c.flipStart = now
            cells[r][k] = c
            started += 1
            setNeedsDisplay(c.rect)
        } }
        if started > 0 { onFlap?(started) }
        if !busy { timer?.invalidate(); timer = nil }
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if background == nil { background = renderBackground() }
        if let bg = background { drawImage(ctx, bg, in: bounds) }
        let now = frozen ?? CACurrentMediaTime()
        for row in cells { for c in row where c.rect.intersects(dirty) { drawCell(ctx, c, now: now) } }
    }

    private func drawCell(_ ctx: CGContext, _ c: Cell, now: CFTimeInterval) {
        let r = c.rect
        let split = (r.minY + r.height * 0.5).rounded(.toNearestOrEven)
        let top = CGRect(x: r.minX, y: r.minY, width: r.width, height: split - r.minY)
        let bot = CGRect(x: r.minX, y: split, width: r.width, height: r.maxY - split)
        let cur = glyph(c.cur, r.size)
        guard let n = c.next else {
            drawImage(ctx, cur.top, in: top); drawImage(ctx, cur.bottom, in: bot); return
        }
        let nxt = glyph(n, r.size)
        let t = min(1, max(0, (now - c.flipStart) / Self.flipDuration))
        drawImage(ctx, nxt.top, in: top)       // revealed behind the falling flap
        drawImage(ctx, cur.bottom, in: bot)    // still showing until the flap lands on it
        if t < 0.5 {   // old top flap folds down toward the hinge, darkening as it turns away
            let k = CGFloat(cos(t * .pi))
            let rr = CGRect(x: top.minX, y: split - top.height * k, width: top.width, height: top.height * k)
            drawImage(ctx, cur.top, in: rr)
            ctx.setFillColor(NSColor(white: 0, alpha: 0.6 * CGFloat(t) * 2).cgColor); ctx.fill(rr)
        } else {       // new bottom flap swings down from the hinge
            let k = CGFloat(-cos(t * .pi))
            let rr = CGRect(x: bot.minX, y: split, width: bot.width, height: bot.height * k)
            ctx.setFillColor(NSColor(white: 0, alpha: 0.45 * (1 - k)).cgColor); ctx.fill(bot)
            drawImage(ctx, nxt.bottom, in: rr)
            ctx.setFillColor(NSColor(white: 0, alpha: 0.35 * (1 - k)).cgColor); ctx.fill(rr)
        }
    }

    private func drawImage(_ ctx: CGContext, _ img: CGImage, in r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    // MARK: flap tiles

    /// Renders (and caches) one flap with its character or colour, split into top and bottom halves.
    /// Drawn y-down in pixel space so the halves crop cleanly.
    private func glyph(_ g: Glyph, _ size: CGSize) -> (top: CGImage, bottom: CGImage, size: CGSize) {
        if let c = glyphCache[g], c.size == size { return c }
        let px = window?.backingScaleFactor ?? 2
        let w = Int((size.width * px).rounded()), h = Int((size.height * px).rounded())
        let W = CGFloat(w), H = CGFloat(h), mid = (H / 2).rounded()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)   // y-down
        let rad = 1.3 * px * layout.scale
        let topR = CGRect(x: 0, y: 0, width: W, height: mid), botR = CGRect(x: 0, y: mid, width: W, height: H - mid)
        func grad(_ r: CGRect, _ a: NSColor, _ b: NSColor) {
            let gr = CGGradient(colorsSpace: nil, colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])!
            ctx.saveGState(); ctx.clip(to: r)
            ctx.drawLinearGradient(gr, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
            ctx.restoreGState()
        }
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.clip()
        if let tile = Pal.tiles[g.style] {
            grad(topR, tile.blended(withFraction: 0.06, of: .white)!, tile)
            grad(botR, tile.blended(withFraction: 0.10, of: .black)!, tile.blended(withFraction: 0.18, of: .black)!)
        } else {
            grad(topR, Pal.flapTop.0, Pal.flapTop.1)
            grad(botR, Pal.flapBottom.0, Pal.flapBottom.1)
            if g.ch != " " {
                let font = NSFont(name: "HelveticaNeue-Medium", size: H * 0.64) ?? .systemFont(ofSize: H * 0.6, weight: .medium)
                let color = g.style == .dim ? Pal.inkDim : Pal.ink
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(g.ch), attributes: [.font: font, .foregroundColor: color]))
                let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: (W - b.width) / 2 - b.minX, y: (H + font.capHeight) / 2)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }
        // hinge shadow under the split, the split itself, and the lit lower lip of the bottom flap
        let gr = CGGradient(colorsSpace: nil, colors: [NSColor(white: 0, alpha: 0.22).cgColor, NSColor(white: 0, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
        ctx.saveGState(); ctx.clip(to: botR)
        ctx.drawLinearGradient(gr, start: CGPoint(x: 0, y: mid), end: CGPoint(x: 0, y: mid + H * 0.12), options: [])
        ctx.restoreGState()
        ctx.setFillColor(NSColor(white: 0, alpha: 0.75).cgColor)
        ctx.fill(CGRect(x: 0, y: mid - px * 0.25, width: W, height: max(1, px * 0.5)))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.05).cgColor)
        ctx.fill(CGRect(x: 0, y: mid - px * 0.35 - max(1, px * 0.5), width: W, height: max(1, px * 0.5)))   // top flap's lit edge
        ctx.setFillColor(NSColor(white: 1, alpha: 0.07).cgColor)
        ctx.fill(CGRect(x: 0, y: H - max(1, px * 0.6), width: W, height: max(1, px * 0.6)))
        let img = ctx.makeImage()!
        let m = Int(mid)
        let entry = (img.cropping(to: CGRect(x: 0, y: 0, width: w, height: m))!,
                     img.cropping(to: CGRect(x: 0, y: m, width: w, height: h - m))!, size)
        glyphCache[g] = entry
        return entry
    }

    // MARK: background: rods, frame, face, pockets, labels — rendered once per layout

    private func renderBackground() -> CGImage? {
        let px = window?.backingScaleFactor ?? 2
        let sz = bounds.size
        guard sz.width > 0, sz.height > 0,
              let ctx = CGContext(data: nil, width: Int(sz.width * px), height: Int(sz.height * px), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: px, y: px)
        ctx.translateBy(x: 0, y: sz.height); ctx.scaleBy(x: 1, y: -1)   // flipped points, like the view
        let L = layout, b = L.board, s = L.scale
        func grad(_ colors: [NSColor], _ from: CGPoint, _ to: CGPoint, locs: [CGFloat]? = nil) {
            let g = CGGradient(colorsSpace: nil, colors: colors.map(\.cgColor) as CFArray, locations: locs)!
            ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        // rods: thin matte-black tubes with a soft cylindrical highlight, a ceiling cup and a clamp
        for f: CGFloat in [0.12, 0.88] {
            let cx = (b.minX + b.width * f).rounded()
            let w = 2.2 * s
            let rod = CGRect(x: cx - w / 2, y: 0, width: w, height: L.rodLen + 1)
            ctx.saveGState(); ctx.clip(to: rod)
            grad([Pal.rgb(0x151516), Pal.rgb(0x5c5c60), Pal.rgb(0x262628), Pal.rgb(0x0e0e0f)],
                 CGPoint(x: rod.minX, y: 0), CGPoint(x: rod.maxX, y: 0), locs: [0, 0.35, 0.7, 1])
            ctx.restoreGState()
            let cup = CGRect(x: cx - 4.5 * s, y: 0, width: 9 * s, height: 3 * s)
            ctx.saveGState(); ctx.addPath(CGPath(roundedRect: cup, cornerWidth: 1.2 * s, cornerHeight: 1.2 * s, transform: nil)); ctx.clip()
            grad([Pal.rgb(0x111112), Pal.rgb(0x3a3a3d), Pal.rgb(0x111112)], CGPoint(x: cup.minX, y: 0), CGPoint(x: cup.maxX, y: 0)); ctx.restoreGState()
            let collar = CGRect(x: cx - 2.4 * s, y: L.rodLen - 4.5 * s, width: 4.8 * s, height: 5 * s)
            ctx.saveGState(); ctx.addPath(CGPath(roundedRect: collar, cornerWidth: 1.4 * s, cornerHeight: 1.4 * s, transform: nil)); ctx.clip()
            grad([Pal.rgb(0x0f0f10), Pal.rgb(0x4a4a4e), Pal.rgb(0x1c1c1e), Pal.rgb(0x0f0f10)],
                 CGPoint(x: collar.minX, y: 0), CGPoint(x: collar.maxX, y: 0), locs: [0, 0.35, 0.7, 1]); ctx.restoreGState()
        }

        // frame: soft drop shadow, then the matte face with a faint bevel
        let rad = 5 * s
        let frame = CGPath(roundedRect: b, cornerWidth: rad, cornerHeight: rad, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s * px), blur: 16 * s * px, color: NSColor(white: 0, alpha: 0.5).cgColor)
        ctx.addPath(frame); ctx.setFillColor(Pal.face.bottom.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(frame); ctx.clip()
        grad([Pal.face.top, Pal.face.bottom], CGPoint(x: 0, y: b.minY), CGPoint(x: 0, y: b.maxY))
        // bevel: light top edge, dark bottom edge
        ctx.setFillColor(NSColor(white: 1, alpha: 0.09).cgColor); ctx.fill(CGRect(x: b.minX, y: b.minY, width: b.width, height: 0.75 * s))
        ctx.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor); ctx.fill(CGRect(x: b.minX, y: b.maxY - 1 * s, width: b.width, height: 1 * s))
        ctx.restoreGState()
        // rim: a faint light edge so the board separates from dark windows behind it, then a dark inner line
        ctx.addPath(CGPath(roundedRect: b.insetBy(dx: 0.25, dy: 0.25), cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor); ctx.setLineWidth(0.5); ctx.strokePath()
        ctx.addPath(CGPath(roundedRect: b.insetBy(dx: 0.9, dy: 0.9), cornerWidth: rad - 0.7, cornerHeight: rad - 0.7, transform: nil))
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.55).cgColor); ctx.setLineWidth(0.6); ctx.strokePath()

        // pockets: recessed slots with an inner shadow on top and a faint lit bottom lip
        for r in 0..<L.rows { for g in 0..<BoardLayout.cellsPerRow {
            let p = L.pocket(row: r, grid: g).insetBy(dx: -0.8 * s, dy: -0.8 * s)
            let pr = CGPath(roundedRect: p, cornerWidth: 1.8 * s, cornerHeight: 1.8 * s, transform: nil)
            ctx.addPath(pr); ctx.setFillColor(Pal.pocket.cgColor); ctx.fillPath()
            ctx.setFillColor(NSColor(white: 1, alpha: 0.06).cgColor)
            ctx.fill(CGRect(x: p.minX + 1 * s, y: p.maxY, width: p.width - 2 * s, height: 0.6 * s))
        } }
        // separator pockets get a blank flap too (always blank)
        let sep = Set(0..<BoardLayout.cellsPerRow).subtracting(BoardLayout.gridIndex)
        for r in 0..<L.rows { for g in sep {
            let rect = L.pocket(row: r, grid: g).insetBy(dx: 0.6 * s, dy: 0.6 * s)
            let gl = glyph(.blank, rect.size)
            let mid = (rect.minY + rect.height * 0.5).rounded(.toNearestOrEven)
            drawImage(ctx, gl.top, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: mid - rect.minY))
            drawImage(ctx, gl.bottom, in: CGRect(x: rect.minX, y: mid, width: rect.width, height: rect.maxY - mid))
        } }

        // column labels, small and quiet
        let font = NSFont(name: "HelveticaNeue-Medium", size: 7 * s) ?? .systemFont(ofSize: 7 * s, weight: .medium)
        for (c, label) in BoardLayout.labels.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
                .font: font, .kern: 1.4 * s, .foregroundColor: Pal.label]))
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: L.columnX(c), y: b.minY + L.headerH - 4.5 * s)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}

// MARK: - Theme conformance

extension FlipBoardView: ThemeView {
    var windowSize: CGSize { layout.windowSize }
    var boardRect: CGRect { layout.board }

    func configure(rows: Int, scale: CGFloat) {
        var l = BoardLayout()
        l.rows = rows
        l.scale = scale
        configure(layout: l)
    }

    func show(_ rows: [RowData]) {
        for (r, row) in rows.enumerated() { setRow(r, Self.glyphs(row)) }
    }

    /// STATUS = one solid colour tile, a gap, then the word. NEEDS YOU flaps its tile yellow/black.
    static func glyphs(_ row: RowData) -> [Glyph] {
        let text: FlapStyle = row.state == .idle ? .dim : .dark
        let c = BoardLayout.cols
        var g: [Glyph] = []
        for ch in flapText(row.time, c[0]) { g.append(Glyph(ch: ch, style: text)) }
        for ch in flapText(row.name, c[1]) { g.append(Glyph(ch: ch, style: text)) }
        for ch in flapText(row.activity, c[2]) { g.append(Glyph(ch: ch, style: text)) }
        if row.placeholder {
            for _ in 0..<c[3] { g.append(Glyph.blank) }
            return g
        }
        let tiles: [SessionState: FlapStyle] = [.working: .blue, .needs: .yellow, .turn: .green, .error: .red, .idle: .dark]
        let lit: FlapStyle = (row.state == .needs && !row.blinkOn) ? FlapStyle.dark : (tiles[row.state] ?? .dark)
        g.append(Glyph.tile(lit))
        g.append(Glyph.blank)
        for ch in flapText(row.statusWord, c[3] - 2) { g.append(Glyph(ch: ch, style: text)) }
        return g
    }
}
