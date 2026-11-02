// E-ink theme: a white-bezel three-colour e-paper sign (black / white / red, like SyncSign room displays)
// hung on thin steel cables. Real typography in mixed case. A row that changes does the e-paper partial
// refresh: a black flash, a white flash, then the new content with a fading ghost of the old one.
import AppKit
import QuartzCore

private struct InkLayout {
    var scale: CGFloat = 1
    var rows = 1
    static let colW: [CGFloat] = [36, 112, 300, 80]     // TIME, SESSION, NOW, STATUS
    static let gap: CGFloat = 10

    var s: CGFloat { scale }
    var bezel: CGFloat { 8 * s }
    var bezelBottom: CGFloat { 11 * s }
    var pad: CGFloat { 11 * s }
    var headerH: CGFloat { 17 * s }
    var rowH: CGFloat { 21 * s }
    var cableLen: CGFloat { 20 * s }
    var shadowPad: CGFloat { 18 * s }

    var screenW: CGFloat { pad * 2 + (Self.colW.reduce(0, +) + Self.gap * CGFloat(Self.colW.count - 1)) * s }
    var screenH: CGFloat { pad * 0.8 + headerH + CGFloat(rows) * rowH + pad * 0.5 }
    var screen: CGRect { CGRect(x: shadowPad + bezel, y: cableLen + bezel, width: screenW, height: screenH) }
    var board: CGRect {
        CGRect(x: screen.minX - bezel, y: screen.minY - bezel, width: screen.width + bezel * 2, height: screen.height + bezel + bezelBottom)
    }
    var windowSize: CGSize { CGSize(width: board.width + shadowPad * 2, height: cableLen + board.height + shadowPad) }

    func colX(_ c: Int) -> CGFloat {
        var x = screen.minX + pad
        for i in 0..<c { x += (Self.colW[i] + Self.gap) * s }
        return x
    }
    var headerRect: CGRect { CGRect(x: screen.minX, y: screen.minY + pad * 0.8, width: screen.width, height: headerH) }
    func rowRect(_ r: Int) -> CGRect {
        CGRect(x: screen.minX + 1, y: headerRect.maxY + CGFloat(r) * rowH, width: screen.width - 2, height: rowH)
    }
}

private struct InkRow {
    var cur: RowData?
    var prev: RowData?
    var changedAt: CFTimeInterval = -10
}

final class InkBoardView: NSView, ThemeView {
    private var L = InkLayout()
    private var rows: [InkRow] = []
    private var background: CGImage?
    private var timer: Timer?
    private var clock = ""
    var onFlap: ((Int) -> Void)?

    static let ink = rgb(0x1e1e1c), grey = rgb(0x7d7d79), red = rgb(0xb3202a), paper = rgb(0xe4e4df)
    static let blackFlash: CFTimeInterval = 0.09, whiteFlash: CFTimeInterval = 0.09, ghostFade: CFTimeInterval = 1.4

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    var windowSize: CGSize { L.windowSize }
    var boardRect: CGRect { L.board }

    private func font(_ name: String, _ size: CGFloat) -> NSFont {
        NSFont(name: name, size: size * L.s) ?? .systemFont(ofSize: size * L.s)
    }

    func configure(rows n: Int, scale: CGFloat) {
        L.rows = n
        L.scale = scale
        while rows.count < n { rows.append(InkRow()) }
        if rows.count > n { rows.removeLast(rows.count - n) }
        background = nil
        needsDisplay = true
    }

    func show(_ data: [RowData]) {
        let now = CACurrentMediaTime()
        for (r, row) in data.enumerated() where r < rows.count {
            var normal = row
            normal.blinkOn = true   // e-paper can't blink; ignore the attention phase
            guard rows[r].cur != normal else { continue }
            rows[r].prev = rows[r].cur
            rows[r].cur = normal
            rows[r].changedAt = now + Double(r) * 0.07
            onFlap?(1)
        }
        let c = timeFmt.string(from: Date())
        if c != clock { clock = c; setNeedsDisplay(L.headerRect) }
        startTimer()
    }

    func settle() {
        for r in rows.indices { rows[r].changedAt = -10 }
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
        let total = Self.blackFlash + Self.whiteFlash + Self.ghostFade
        for r in rows.indices where now - rows[r].changedAt < total + 0.05 || now < rows[r].changedAt {
            busy = true
            setNeedsDisplay(L.rowRect(r))
        }
        if !busy { timer?.invalidate(); timer = nil }
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if background == nil { background = renderBackground() }
        if let bg = background { drawFlipped(ctx, bg, in: bounds) }
        let now = CACurrentMediaTime()
        if L.headerRect.intersects(dirty) {
            let f = font("AvenirNext-Medium", 7.5)
            let w = textWidth(clock, font: f, kern: 0.6 * L.s)
            drawText(ctx, clock, font: f, color: Self.grey, x: L.screen.maxX - L.pad - w, baseline: L.headerRect.maxY - 6 * L.s, kern: 0.6 * L.s)
        }
        for r in rows.indices {
            let rect = L.rowRect(r)
            guard rect.intersects(dirty), let cur = rows[r].cur else { continue }
            let t = now - rows[r].changedAt
            if t >= 0 && t < Self.blackFlash {
                ctx.setFillColor(Self.ink.cgColor); ctx.fill(rect.insetBy(dx: 2 * L.s, dy: 1.5 * L.s))
                continue
            }
            if t >= Self.blackFlash && t < Self.blackFlash + Self.whiteFlash {
                ctx.setFillColor(rgb(0xf3f3ef).cgColor); ctx.fill(rect.insetBy(dx: 2 * L.s, dy: 1.5 * L.s))
                continue
            }
            if t < 0 {   // not refreshed yet: still showing the old content
                if let p = rows[r].prev { drawRow(ctx, p, rect: rect, alpha: 1) }
                continue
            }
            let g = 1 - (t - Self.blackFlash - Self.whiteFlash) / Self.ghostFade
            if g > 0, let p = rows[r].prev { drawRow(ctx, p, rect: rect, alpha: CGFloat(g) * 0.2) }
            drawRow(ctx, cur, rect: rect, alpha: 1)
        }
    }

    private func drawRow(_ ctx: CGContext, _ row: RowData, rect: CGRect, alpha: CGFloat) {
        let s = L.s
        let base = rect.minY + rect.height / 2 + 4 * s
        let idle = row.state == .idle
        let text = idle || row.placeholder ? Self.grey : Self.ink
        ctx.saveGState()
        ctx.setAlpha(alpha)
        if row.state == .needs {   // red accent bar, like the coloured block on a room sign
            ctx.setFillColor(Self.red.cgColor)
            ctx.fill(CGRect(x: L.screen.minX + 3 * s, y: rect.minY + 4 * s, width: 2.5 * s, height: rect.height - 8 * s))
        }
        let timeF = font("AvenirNextCondensed-DemiBold", 11.5)
        drawText(ctx, row.time, font: timeF, color: row.state == .needs ? Self.red : text, x: L.colX(0), baseline: base)
        let nameF = font("AvenirNext-DemiBold", 11.5)
        drawText(ctx, fit(row.name, width: InkLayout.colW[1] * s, font: nameF), font: nameF, color: text, x: L.colX(1), baseline: base)
        let actF = font("AvenirNext-Regular", 11.5)
        let act = fit(sentenceCase(row.activity), width: InkLayout.colW[2] * s, font: actF)
        drawText(ctx, act, font: actF, color: idle ? Self.grey : rgb(0x2c2c2a), x: L.colX(2), baseline: base)
        if !row.placeholder { drawPill(ctx, row.state, row.statusWord.uppercased(), rect: rect) }
        ctx.restoreGState()
    }

    /// Status pill, right-aligned in the STATUS column, in the panel's three inks.
    private func drawPill(_ ctx: CGContext, _ state: SessionState, _ word: String, rect: CGRect) {
        let s = L.s
        let f = font("AvenirNext-Bold", 7.5)
        let kern = 0.9 * s
        let tw = textWidth(word, font: f, kern: kern) - kern
        let h = 13 * s, w = tw + 12 * s
        let right = L.colX(3) + InkLayout.colW[3] * s
        let pill = CGRect(x: right - w, y: rect.midY - h / 2, width: w, height: h)
        let path = CGPath(roundedRect: pill, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        var fg = Self.ink
        switch state {
        case .working: ctx.addPath(path); ctx.setFillColor(Self.ink.cgColor); ctx.fillPath(); fg = Self.paper
        case .needs: ctx.addPath(path); ctx.setFillColor(Self.red.cgColor); ctx.fillPath(); fg = rgb(0xf6f3f0)
        case .turn: ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.5 * s, dy: 0.5 * s), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
            ctx.setStrokeColor(Self.ink.cgColor); ctx.setLineWidth(1 * s); ctx.strokePath()
        case .error: ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.5 * s, dy: 0.5 * s), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
            ctx.setStrokeColor(Self.red.cgColor); ctx.setLineWidth(1 * s); ctx.strokePath(); fg = Self.red
        case .idle: fg = Self.grey
        }
        drawText(ctx, word, font: f, color: fg, x: pill.minX + 6 * s, baseline: pill.midY + 2.7 * s, kern: kern)
    }

    // MARK: background: cables, white bezel, paper, header, row rules

    private func renderBackground() -> CGImage? {
        let px = window?.backingScaleFactor ?? 2
        guard let ctx = makeFlippedContext(size: bounds.size, scale: px) else { return nil }
        let b = L.board, sc = L.screen, s = L.s

        // steel cables with a ceiling disc and crimp sleeves
        for f: CGFloat in [0.1, 0.9] {
            let cx = (b.minX + b.width * f).rounded()
            let cable = CGRect(x: cx - 0.5 * s, y: 0, width: 1 * s, height: L.cableLen + 1)
            ctx.saveGState(); ctx.clip(to: cable)
            linearGradient(ctx, [rgb(0x8a8a88), rgb(0xe2e2e0), rgb(0x7a7a78)], from: CGPoint(x: cable.minX, y: 0), to: CGPoint(x: cable.maxX, y: 0))
            ctx.restoreGState()
            let disc = CGRect(x: cx - 4.5 * s, y: 0, width: 9 * s, height: 2.4 * s)
            ctx.saveGState(); ctx.addPath(CGPath(roundedRect: disc, cornerWidth: 1 * s, cornerHeight: 1 * s, transform: nil)); ctx.clip()
            linearGradient(ctx, [rgb(0xf4f4f2), rgb(0xbdbdba)], from: CGPoint(x: 0, y: disc.minY), to: CGPoint(x: 0, y: disc.maxY)); ctx.restoreGState()
            let sleeve = CGRect(x: cx - 1.5 * s, y: L.cableLen - 5 * s, width: 3 * s, height: 5 * s)
            ctx.saveGState(); ctx.clip(to: sleeve)
            linearGradient(ctx, [rgb(0x9a9a98), rgb(0xf2f2f0), rgb(0x8c8c8a)], from: CGPoint(x: sleeve.minX, y: 0), to: CGPoint(x: sleeve.maxX, y: 0))
            ctx.restoreGState()
        }

        // white plastic bezel
        let rad = 8 * s
        let bez = CGPath(roundedRect: b, cornerWidth: rad, cornerHeight: rad, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s * px), blur: 16 * s * px, color: NSColor(white: 0, alpha: 0.38).cgColor)
        ctx.addPath(bez); ctx.setFillColor(rgb(0xf0f0ed).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(bez); ctx.clip()
        linearGradient(ctx, [rgb(0xfdfdfb), rgb(0xf1f1ee), rgb(0xe2e2de)], from: CGPoint(x: 0, y: b.minY), to: CGPoint(x: 0, y: b.maxY), locations: [0, 0.5, 1])
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: b.insetBy(dx: 0.25, dy: 0.25), cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setStrokeColor(rgb(0xb9b9b4).cgColor); ctx.setLineWidth(0.5); ctx.strokePath()

        // e-paper: matte off-white with fine grain, slightly recessed
        ctx.setFillColor(Self.paper.cgColor); ctx.fill(sc)
        ctx.saveGState(); ctx.clip(to: sc)
        for k in 0..<Int(sc.width * sc.height / (6 * s * s)) {
            let fx = sc.minX + (jitter(k, 3, 5) + 1) / 2 * sc.width
            let fy = sc.minY + (jitter(k, 7, 2) + 1) / 2 * sc.height
            let dark = jitter(k, 1, 1) > 0
            ctx.setFillColor(NSColor(white: dark ? 0 : 1, alpha: dark ? 0.035 : 0.06).cgColor)
            ctx.fill(CGRect(x: fx, y: fy, width: 0.6 * s, height: 0.6 * s))
        }
        linearGradient(ctx, [NSColor(white: 0, alpha: 0.10), NSColor(white: 0, alpha: 0)], from: CGPoint(x: 0, y: sc.minY), to: CGPoint(x: 0, y: sc.minY + 3 * s))

        // header labels and rule
        let lf = font("AvenirNext-DemiBold", 6.8)
        let hb = L.headerRect.maxY - 6 * s
        for (c, label) in ["TIME", "SESSION", "NOW", "STATUS"].enumerated() {
            drawText(ctx, label, font: lf, color: Self.grey, x: L.colX(c), baseline: hb, kern: 1.3 * s)   // clock sits right of STATUS
        }
        ctx.setFillColor(Self.ink.cgColor)
        ctx.fill(CGRect(x: sc.minX + L.pad, y: L.headerRect.maxY - 1.6 * s, width: sc.width - L.pad * 2, height: 0.8 * s))
        // dotted rules between rows
        ctx.setStrokeColor(rgb(0x9a9a96).cgColor); ctx.setLineWidth(0.5 * s)
        ctx.setLineDash(phase: 0, lengths: [0.8 * s, 1.8 * s])
        for r in 1..<max(1, L.rows) {
            let y = L.rowRect(r).minY
            ctx.move(to: CGPoint(x: sc.minX + L.pad, y: y)); ctx.addLine(to: CGPoint(x: sc.maxX - L.pad, y: y)); ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.restoreGState()
        ctx.setStrokeColor(rgb(0xa9a9a4).cgColor); ctx.setLineWidth(0.6 * s); ctx.stroke(sc)
        return ctx.makeImage()
    }
}
