// Themes: every look is an NSView that draws the same rows its own way. The app hands each theme plain
// RowData every half second; the theme decides how changes animate (flaps, LED roll, letters, ink refresh).
import AppKit

struct RowData: Equatable {
    var time: String          // "16:42"
    var name: String
    var activity: String      // as written (themes uppercase it if their medium needs to)
    var state: SessionState
    var placeholder = false   // the "no sessions" row
    var blinkOn = true        // attention phase for NEEDS YOU, toggles every 1.2 s

    static let empty = RowData(time: "--:--", name: "No sessions", activity: "Start Claude to board", state: .idle, placeholder: true)

    var statusWord: String {
        switch state {
        case .working: return "Working"
        case .needs: return "Needs you"
        case .turn: return "Your turn"
        case .error: return "Error"
        case .idle: return "Idle"
        }
    }
}

protocol ThemeView: NSView {
    /// Window size for the current rows/scale (board + hanging hardware + shadow room).
    var windowSize: CGSize { get }
    /// The board itself in view coordinates (flipped, y down) — the area that fades on hover.
    var boardRect: CGRect { get }
    var onFlap: ((Int) -> Void)? { get set }
    func configure(rows: Int, scale: CGFloat)
    func show(_ rows: [RowData])
    /// Finish every animation now (snapshots).
    func settle()
}

enum Theme: String, CaseIterable {
    case flip, led, letter, ink

    var title: String {
        switch self {
        case .flip: return "Flipboard"
        case .led: return "LED Sign"
        case .letter: return "Letterboard"
        case .ink: return "E-Ink"
        }
    }

    func make() -> ThemeView {
        switch self {
        case .flip: return FlipBoardView(frame: .zero)
        case .led: return LEDBoardView(frame: .zero)
        case .letter: return LetterBoardView(frame: .zero)
        case .ink: return InkBoardView(frame: .zero)
        }
    }
}

// MARK: - Shared drawing helpers

func rgb(_ v: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}

/// Draws a CGImage right side up into a rect of a flipped (y-down) context.
func drawFlipped(_ ctx: CGContext, _ img: CGImage, in r: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: r.minX, y: r.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
    ctx.restoreGState()
}

func linearGradient(_ ctx: CGContext, _ colors: [NSColor], from: CGPoint, to: CGPoint, locations: [CGFloat]? = nil) {
    let cgColors = colors.map(\.cgColor) as CFArray
    guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cgColors, locations: locations) else { return }
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// An offscreen bitmap in flipped points (y down), for themes' cached backgrounds.
func makeFlippedContext(size: CGSize, scale px: CGFloat) -> CGContext? {
    let w = Int((size.width * px).rounded(.up)), h = Int((size.height * px).rounded(.up))
    guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: px, y: px)
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

/// Draws a single line of text with its baseline at `baseline` in a flipped context.
func drawText(_ ctx: CGContext, _ s: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func textWidth(_ s: String, font: NSFont, kern: CGFloat = 0) -> CGFloat {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: kern]
    return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs)), nil, nil, nil))
}

/// Longest prefix of `s` that fits `width`, cut at a word boundary when that keeps most of it.
func fit(_ s: String, width: CGFloat, font: NSFont, kern: CGFloat = 0) -> String {
    if textWidth(s, font: font, kern: kern) <= width { return s }
    var chars = Array(s)
    while !chars.isEmpty && textWidth(String(chars), font: font, kern: kern) > width { chars.removeLast() }
    let hard = chars.count
    if let sp = chars.lastIndex(of: " "), sp >= hard / 2 { chars = Array(chars[..<sp]) }   // don't leave half a word
    let fillers: Set<String> = ["and", "the", "to", "of", "a", "an", "for", "in", "on", "with", "its", "or"]
    if let sp = chars.lastIndex(of: " "), sp > hard / 2, fillers.contains(String(chars[(sp + 1)...]).lowercased()) {
        chars = Array(chars[..<sp])
    }
    while let l = chars.last, l == " " || l == "," || l == "-" { chars.removeLast() }
    return String(chars)
}

/// "EDITING main.swift" (older hook output) → "Editing main.swift"; already-normal text is left alone.
func sentenceCase(_ s: String) -> String {
    guard let first = s.split(separator: " ").first, first.count > 1,
          first == first.uppercased(), first.contains(where: \.isLetter) else { return s }
    let rest = s.dropFirst(first.count)
    let restIsCaps = rest == rest.uppercased()
    return first.prefix(1) + first.dropFirst().lowercased() + (restIsCaps ? rest.lowercased() : String(rest))
}

/// Stable pseudo-random number in [-1, 1] for (a, b, c) — letter jitter that doesn't change between frames.
func jitter(_ a: Int, _ b: Int, _ c: Int) -> CGFloat {
    var h = UInt64(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ c &* 83492791)
    h ^= h >> 33; h = h &* 0xff51afd7ed558ccd; h ^= h >> 33
    return CGFloat(h % 2001) / 1000 - 1
}
