// Letterboard theme: a black ribbed-felt letter board in a light oak frame (like the Letterfolk / "Felt Like
// Sharing" boards), hung on jute cords. White plastic letters sit a little crooked. When text changes, the
// old letters lift out and new ones drop into the grooves; a session that needs you wiggles its letters.
import AppKit
import QuartzCore

private struct LetterLayout {
    var scale: CGFloat = 1
    var rows = 1
    static let colW: [CGFloat] = [40, 100, 268, 88]     // TIME, SESSION, NOW, STATUS (points at scale 1)
    static let gap: CGFloat = 13

    var s: CGFloat { scale }
    var frameW: CGFloat { 9 * s }
    var padX: CGFloat { 12 * s }
    var padTop: CGFloat { 8 * s }
    var padBottom: CGFloat { 8 * s }
    var rowH: CGFloat { 20 * s }
    var fontSize: CGFloat { 15.5 * s }
    var capH: CGFloat { fontSize * 0.70 }
    var cordLen: CGFloat { 20 * s }
    var shadowPad: CGFloat { 18 * s }

    var feltW: CGFloat { padX * 2 + (Self.colW.reduce(0, +) + Self.gap * CGFloat(Self.colW.count - 1)) * s }
    var feltH: CGFloat { padTop + capH + CGFloat(rows - 1) * rowH + padBottom + 2 * s }
    var felt: CGRect { CGRect(x: shadowPad + frameW, y: cordLen + frameW, width: feltW, height: feltH) }
    var board: CGRect { felt.insetBy(dx: -frameW, dy: -frameW) }
    var windowSize: CGSize { CGSize(width: board.width + shadowPad * 2, height: cordLen + board.height + shadowPad) }

    func colX(_ c: Int) -> CGFloat {
        var x = felt.minX + padX
        for i in 0..<c { x += (Self.colW[i] + Self.gap) * s }
        return x
    }
    func baseline(_ r: Int) -> CGFloat { felt.minY + padTop + capH + 1 * s + CGFloat(r) * rowH }
    func rowRect(_ r: Int) -> CGRect {
        CGRect(x: felt.minX, y: baseline(r) - capH - 9 * s, width: felt.width, height: capH + 14 * s)
    }
}

private struct LetterCol {
    var text: [Character] = []
    var color = 0
    var prev: [Character] = []
    var prevColor = 0
    var keep = 0                  // leading letters that didn't change (they stay put)
    var start: CFTimeInterval = -10
}

final class LetterBoardView: NSView, ThemeView {
    private var L = LetterLayout()
    private var cols: [[LetterCol]] = []
    private var wiggle: [Bool] = []
    private var background: CGImage?
    private var letters: [String: (img: CGImage, adv: CGFloat)] = [:]
    private var timer: Timer?
    var onFlap: ((Int) -> Void)?

    static let white = 0xf3f0e8, dimWhite = 0x9c978e
    static let statusColor: [SessionState: Int] = [.working: 0x6cb4ee, .needs: 0xf5c443, .turn: 0x7fd69b, .error: 0xf2705f, .idle: 0x8e8a83]
    static let outTime: CFTimeInterval = 0.14, inTime: CFTimeInterval = 0.24

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    var windowSize: CGSize { L.windowSize }
    var boardRect: CGRect { L.board }

    private var font: NSFont {
        NSFont(name: "DINCondensed-Bold", size: L.fontSize) ?? NSFont(name: "HelveticaNeue-CondensedBold", size: L.fontSize)
            ?? .boldSystemFont(ofSize: L.fontSize)
    }
    private var kern: CGFloat { 0.9 * L.s }

    func configure(rows: Int, scale: CGFloat) {
        if scale != L.scale { letters.removeAll() }
        L.rows = rows
        L.scale = scale
        while cols.count < rows { cols.append(Array(repeating: LetterCol(), count: 4)) }
        if cols.count > rows { cols.removeLast(cols.count - rows) }
        wiggle = Array(repeating: false, count: rows)
        background = nil
        needsDisplay = true
    }

    func show(_ rows: [RowData]) {
        let now = CACurrentMediaTime()
        for (r, row) in rows.enumerated() where r < cols.count {
            let textColor = row.state == .idle ? Self.dimWhite : Self.white
            let parts: [(String, Int)] = [
                (row.time, textColor), (row.name, textColor), (row.activity, textColor),
                (row.placeholder ? "" : row.statusWord, Self.statusColor[row.state] ?? Self.white),
            ]
            for (c, (s, color)) in parts.enumerated() {
                let width = LetterLayout.colW[c] * L.s
                let t = Array(fit(s.uppercased(), width: width, font: font, kern: kern))
                var col = cols[r][c]
                guard col.text != t || col.color != color else { continue }
                var keep = 0
                if col.color == color { while keep < min(t.count, col.text.count) && t[keep] == col.text[keep] { keep += 1 } }
                col.prev = col.text
                col.prevColor = col.color
                col.text = t
                col.color = color
                col.keep = keep
                col.start = now + Double(c) * 0.05
                cols[r][c] = col
                onFlap?(1)
            }
            wiggle[r] = row.state == .needs
        }
        startTimer()
    }

    func settle() {
        for r in cols.indices { for c in cols[r].indices { cols[r][c].start = -10 } }
        needsDisplay = true
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func animating(_ col: LetterCol, _ now: CFTimeInterval) -> Bool {
        let n = Double(max(col.text.count, col.prev.count))
        return now < col.start + Self.outTime + n * 0.022 + Self.inTime + 0.05
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var busy = false
        for r in cols.indices {
            if cols[r].contains(where: { animating($0, now) }) || wiggle[r] {
                busy = true
                setNeedsDisplay(L.rowRect(r))
            }
        }
        if !busy { timer?.invalidate(); timer = nil }
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if background == nil { background = renderBackground() }
        if let bg = background { drawFlipped(ctx, bg, in: bounds) }
        let now = CACurrentMediaTime()
        for r in cols.indices where L.rowRect(r).intersects(dirty) {
            for c in cols[r].indices { drawCol(ctx, cols[r][c], row: r, col: c, now: now) }
        }
    }

    private func drawCol(_ ctx: CGContext, _ col: LetterCol, row r: Int, col c: Int, now: CFTimeInterval) {
        let x0 = L.colX(c), base = L.baseline(r), s = L.s
        let t = now - col.start
        // wiggle: status letters of a session that needs you rock for half a second every 1.6 s
        var rock: CGFloat = 0
        if c == 3 && wiggle[r] {
            let ph = now.truncatingRemainder(dividingBy: 1.6)
            if ph < 0.5 { rock = CGFloat(sin(ph / 0.5 * .pi * 4) * (1 - ph / 0.5)) * 7 }
        }
        // outgoing letters (only those after the unchanged prefix)
        if t < Self.outTime + Double(col.prev.count) * 0.022 {
            var x = x0
            for (i, ch) in col.prev.enumerated() {
                let g = letter(ch, col.prevColor)
                if i >= col.keep {
                    let lt = max(0, min(1, (t - Double(i - col.keep) * 0.015) / Self.outTime))
                    if lt < 1 {
                        drawLetter(ctx, g.img, x: x, base: base - 6 * s * CGFloat(lt), alpha: 1 - CGFloat(lt), seed: (r, c, i), ch: ch, rock: 0)
                    }
                }
                x += g.adv
            }
        }
        // resting + incoming letters
        var x = x0
        let inStart = col.prev.count > col.keep ? Self.outTime * 0.8 : 0
        for (i, ch) in col.text.enumerated() {
            let g = letter(ch, col.color)
            if i < col.keep || t > 50 {
                drawLetter(ctx, g.img, x: x, base: base, alpha: 1, seed: (r, c, i), ch: ch, rock: rock)
            } else {
                let lt = (t - inStart - Double(i - col.keep) * 0.022) / Self.inTime
                if lt >= 0 {
                    let e = easeOutBack(min(1, lt))
                    drawLetter(ctx, g.img, x: x, base: base - 8 * s * (1 - e), alpha: min(1, CGFloat(lt) * 3), seed: (r, c, i), ch: ch, rock: rock)
                }
            }
            x += g.adv
        }
    }

    private func easeOutBack(_ t: Double) -> CGFloat {
        let c1 = 1.9, c3 = c1 + 1
        return CGFloat(1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2))
    }

    /// Draws one plastic letter with its stable crooked angle and baseline wobble.
    private func drawLetter(_ ctx: CGContext, _ img: CGImage, x: CGFloat, base: CGFloat, alpha: CGFloat, seed: (Int, Int, Int), ch: Character, rock: CGFloat) {
        let px = window?.backingScaleFactor ?? 2
        let w = CGFloat(img.width) / px, h = CGFloat(img.height) / px
        let code = Int(ch.unicodeScalars.first?.value ?? 0)
        let angle = (jitter(seed.0, seed.1 * 31 + seed.2, code) * 1.8 + rock) * .pi / 180
        let dy = jitter(seed.2, seed.0 * 17 + code, seed.1) * 0.45 * L.s
        let pad = 3 * L.s
        // the letter image's baseline sits `pad + capH` below its top
        let rect = CGRect(x: x - pad, y: base + dy - L.capH - pad, width: w, height: h)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: angle)
        drawFlipped(ctx, img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    /// A white (or coloured) plastic letter with a soft shadow on the felt and a faint top-edge highlight.
    private func letter(_ ch: Character, _ color: Int) -> (img: CGImage, adv: CGFloat) {
        let key = "\(color)|\(ch)"
        if let l = letters[key] { return l }
        let f = font, s = L.s, pad = 3 * s
        let adv = textWidth(String(ch), font: f) + kern
        let size = CGSize(width: max(adv, 2 * s) + pad * 2, height: L.capH + pad * 2 + 2 * s)
        let px = window?.backingScaleFactor ?? 2
        let ctx = makeFlippedContext(size: size, scale: px)!
        let baseY = pad + L.capH
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0.5 * s * px, height: -1.1 * s * px), blur: 1.3 * s * px, color: NSColor(white: 0, alpha: 0.85).cgColor)
        drawText(ctx, String(ch), font: f, color: rgb(color), x: pad, baseline: baseY)
        ctx.restoreGState()
        // moulded plastic: slightly brighter top
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: size.width, height: pad + L.capH * 0.35))
        drawText(ctx, String(ch), font: f, color: NSColor(white: 1, alpha: 0.25), x: pad, baseline: baseY)
        ctx.restoreGState()
        let entry = (ctx.makeImage()!, adv)
        letters[key] = entry
        return entry
    }

    // MARK: background: cords, oak frame, ribbed felt

    private func renderBackground() -> CGImage? {
        let px = window?.backingScaleFactor ?? 2
        guard let ctx = makeFlippedContext(size: bounds.size, scale: px) else { return nil }
        let b = L.board, felt = L.felt, s = L.s

        // shadow + frame body
        let rad = 3 * s
        let outer = CGPath(roundedRect: b, cornerWidth: rad, cornerHeight: rad, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s * px), blur: 15 * s * px, color: NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.addPath(outer); ctx.setFillColor(rgb(0xd9ad7b).cgColor); ctx.fillPath()
        ctx.restoreGState()

        // oak: rails with grain running along them, mitred at the corners
        let fw = L.frameW
        let rails: [(CGRect, Bool)] = [
            (CGRect(x: b.minX, y: b.minY, width: b.width, height: fw), true),
            (CGRect(x: b.minX, y: b.maxY - fw, width: b.width, height: fw), true),
            (CGRect(x: b.minX, y: b.minY, width: fw, height: b.height), false),
            (CGRect(x: b.maxX - fw, y: b.minY, width: fw, height: b.height), false),
        ]
        ctx.saveGState(); ctx.addPath(outer); ctx.clip()
        for (i, (rail, horizontal)) in rails.enumerated() {
            ctx.saveGState()
            let path = CGMutablePath()   // mitre: trapezoid for each rail
            switch i {
            case 0: path.addLines(between: [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX - fw, y: b.minY + fw), CGPoint(x: b.minX + fw, y: b.minY + fw)])
            case 1: path.addLines(between: [CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.maxX - fw, y: b.maxY - fw), CGPoint(x: b.minX + fw, y: b.maxY - fw)])
            case 2: path.addLines(between: [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.minX + fw, y: b.minY + fw), CGPoint(x: b.minX + fw, y: b.maxY - fw), CGPoint(x: b.minX, y: b.maxY)])
            default: path.addLines(between: [CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX - fw, y: b.minY + fw), CGPoint(x: b.maxX - fw, y: b.maxY - fw), CGPoint(x: b.maxX, y: b.maxY)])
            }
            path.closeSubpath()
            ctx.addPath(path); ctx.clip()
            let light = i == 0 ? rgb(0xf0cc9c) : (i == 1 ? rgb(0xd2a473) : rgb(0xe4bb88))
            let dark = i == 1 ? rgb(0xc4955f) : rgb(0xd8ab78)
            if horizontal {
                linearGradient(ctx, [light, dark], from: CGPoint(x: 0, y: rail.minY), to: CGPoint(x: 0, y: rail.maxY))
            } else {
                linearGradient(ctx, [light, dark], from: CGPoint(x: rail.minX, y: 0), to: CGPoint(x: rail.maxX, y: 0))
            }
            // grain: thin wavy darker lines along the rail
            ctx.setLineWidth(0.45 * s)
            for k in 0..<7 {
                let gp = CGMutablePath()
                let off = (CGFloat(k) + 0.5) / 7 + jitter(i, k, 3) * 0.04
                let amp = (0.6 + abs(jitter(k, i, 9)) * 1.2) * s
                let freq = 0.018 + abs(jitter(i, k, 5)) * 0.02
                let len = horizontal ? rail.width : rail.height
                var tt: CGFloat = 0
                while tt <= len {
                    let wob = sin(tt * freq / s + CGFloat(k) * 1.7) * amp
                    let pt = horizontal ? CGPoint(x: rail.minX + tt, y: rail.minY + rail.height * off + wob * 0.35)
                                        : CGPoint(x: rail.minX + rail.width * off + wob * 0.35, y: rail.minY + tt)
                    if tt == 0 { gp.move(to: pt) } else { gp.addLine(to: pt) }
                    tt += 3 * s
                }
                ctx.addPath(gp)
                ctx.setStrokeColor(rgb(0x9c6e3e, 0.16 + abs(jitter(k, i, 1)) * 0.14).cgColor)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        // mitre seams
        ctx.setStrokeColor(rgb(0x8a5f33, 0.35).cgColor); ctx.setLineWidth(0.5 * s)
        for (a, z) in [(CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.minX + fw, y: b.minY + fw)),
                       (CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX - fw, y: b.minY + fw)),
                       (CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.minX + fw, y: b.maxY - fw)),
                       (CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.maxX - fw, y: b.maxY - fw))] {
            ctx.move(to: a); ctx.addLine(to: z); ctx.strokePath()
        }
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: b.insetBy(dx: 0.25, dy: 0.25), cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setStrokeColor(rgb(0x8a5f33, 0.55).cgColor); ctx.setLineWidth(0.5); ctx.strokePath()

        // felt with horizontal ribs
        ctx.setFillColor(rgb(0x1c1b1b).cgColor); ctx.fill(felt)
        ctx.saveGState(); ctx.clip(to: felt)
        var y = felt.minY + 1 * s
        while y < felt.maxY {
            ctx.setFillColor(rgb(0x0d0c0c).cgColor); ctx.fill(CGRect(x: felt.minX, y: y, width: felt.width, height: 0.75 * s))
            ctx.setFillColor(rgb(0x2b2928).cgColor); ctx.fill(CGRect(x: felt.minX, y: y + 0.75 * s, width: felt.width, height: 0.4 * s))
            y += 2.1 * s
        }
        // fibres: sparse light specks
        for k in 0..<Int(felt.width * felt.height / (40 * s * s)) {
            let fx = felt.minX + (jitter(k, 1, 7) + 1) / 2 * felt.width
            let fy = felt.minY + (jitter(k, 2, 11) + 1) / 2 * felt.height
            ctx.setFillColor(NSColor(white: 1, alpha: 0.05).cgColor)
            ctx.fill(CGRect(x: fx, y: fy, width: 0.5 * s, height: 0.5 * s))
        }
        // the frame casts a shadow onto the felt along the top and left
        linearGradient(ctx, [NSColor(white: 0, alpha: 0.6), NSColor(white: 0, alpha: 0)], from: CGPoint(x: 0, y: felt.minY), to: CGPoint(x: 0, y: felt.minY + 4 * s))
        linearGradient(ctx, [NSColor(white: 0, alpha: 0.45), NSColor(white: 0, alpha: 0)], from: CGPoint(x: felt.minX, y: 0), to: CGPoint(x: felt.minX + 3 * s, y: 0))
        ctx.restoreGState()

        // jute cords to brass eye screws on the top rail
        for f: CGFloat in [0.1, 0.9] {
            let cx = (b.minX + b.width * f).rounded()
            let eyeY = b.minY - 1.5 * s
            let cord = CGRect(x: cx - 0.9 * s, y: 0, width: 1.8 * s, height: eyeY - 1.5 * s)
            ctx.setFillColor(rgb(0xc9a56e).cgColor); ctx.fill(cord)
            ctx.saveGState(); ctx.clip(to: cord)
            ctx.setStrokeColor(rgb(0x8f6e3e, 0.8).cgColor); ctx.setLineWidth(0.5 * s)
            var ty = cord.minY
            while ty < cord.maxY + 3 * s {   // twist
                ctx.move(to: CGPoint(x: cord.minX, y: ty)); ctx.addLine(to: CGPoint(x: cord.maxX, y: ty - 1.6 * s)); ctx.strokePath()
                ty += 1.7 * s
            }
            ctx.restoreGState()
            let ring = CGRect(x: cx - 2.2 * s, y: eyeY - 2.2 * s, width: 4.4 * s, height: 4.4 * s)
            ctx.setStrokeColor(rgb(0xb8892e).cgColor); ctx.setLineWidth(1.1 * s); ctx.strokeEllipse(in: ring)
            ctx.setStrokeColor(rgb(0xf3d48a, 0.7).cgColor); ctx.setLineWidth(0.4 * s)
            ctx.addArc(center: CGPoint(x: ring.midX, y: ring.midY), radius: 2.2 * s, startAngle: .pi * 1.1, endAngle: .pi * 1.6, clockwise: false)
            ctx.strokePath()
        }
        return ctx.makeImage()
    }
}
