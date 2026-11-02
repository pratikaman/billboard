// Themes: every look is an NSView that draws the same rows its own way. The app hands each theme plain
// RowData every half second; the theme decides how changes animate (flaps, LED roll, letters, ink refresh).
import AppKit

struct RowData: Equatable {
    var time: String          // "16:42"
    var name: String
    var activity: String      // as written (themes uppercase it if their medium needs to)
    var state: SessionState
    var agent: Agent = .claude
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

/// Codex's mark: the OpenAI logo (Simple Icons "openai", 24x24, y-down; SVG arcs pre-converted to cubics).
private let openAISVG = "M 22.282 9.821 C 22.825 8.186 22.637 6.397 21.766 4.91 C 20.457 2.632 17.826 1.46 15.256 2.01 C 13.808 0.4 11.611 -0.317 9.492 0.131 C 7.373 0.579 5.653 2.123 4.981 4.182 C 3.293 4.528 1.836 5.585 0.983 7.082 C -0.34 9.357 -0.04 12.227 1.726 14.178 C 1.181 15.812 1.367 17.602 2.237 19.089 C 3.547 21.369 6.18 22.541 8.751 21.989 C 9.895 23.277 11.538 24.01 13.26 24 C 15.894 24.002 18.227 22.302 19.032 19.794 C 20.719 19.447 22.176 18.391 23.029 16.894 C 24.337 14.623 24.035 11.769 22.282 9.821 Z M 13.26 22.429 C 12.209 22.431 11.19 22.062 10.383 21.388 L 10.525 21.308 L 15.304 18.55 C 15.546 18.408 15.695 18.149 15.696 17.869 L 15.696 11.132 L 17.716 12.3 C 17.737 12.31 17.751 12.33 17.754 12.352 L 17.754 17.935 C 17.749 20.415 15.74 22.424 13.26 22.429 Z M 3.599 18.304 C 3.072 17.393 2.883 16.326 3.065 15.29 L 3.207 15.375 L 7.99 18.134 C 8.231 18.275 8.529 18.275 8.77 18.134 L 14.613 14.765 L 14.613 17.097 C 14.612 17.122 14.6 17.145 14.58 17.159 L 9.74 19.95 C 7.589 21.189 4.842 20.452 3.599 18.304 Z M 2.341 7.896 C 2.872 6.979 3.71 6.281 4.706 5.923 L 4.706 11.6 C 4.703 11.879 4.851 12.139 5.094 12.277 L 10.909 15.631 L 8.889 16.799 C 8.866 16.811 8.84 16.811 8.818 16.799 L 3.987 14.013 C 1.841 12.769 1.105 10.023 2.341 7.872 Z M 18.937 11.751 L 13.104 8.364 L 15.119 7.2 C 15.141 7.188 15.168 7.188 15.19 7.2 L 20.02 9.991 C 21.528 10.861 22.398 12.523 22.253 14.258 C 22.108 15.993 20.975 17.488 19.344 18.096 L 19.344 12.418 C 19.335 12.14 19.181 11.886 18.937 11.751 Z M 20.948 8.728 L 20.806 8.643 L 16.032 5.861 C 15.79 5.719 15.489 5.719 15.247 5.861 L 9.409 9.23 L 9.409 6.897 C 9.406 6.873 9.417 6.85 9.437 6.836 L 14.268 4.049 C 15.779 3.179 17.657 3.26 19.088 4.258 C 20.518 5.256 21.243 6.99 20.948 8.709 Z M 8.306 12.863 L 6.287 11.699 C 6.266 11.687 6.252 11.666 6.248 11.643 L 6.248 6.074 C 6.251 4.33 7.26 2.745 8.84 2.005 C 10.419 1.266 12.283 1.506 13.624 2.621 L 13.482 2.701 L 8.704 5.459 C 8.462 5.601 8.313 5.86 8.311 6.14 Z M 9.404 10.498 L 12.006 8.998 L 14.613 10.498 L 14.613 13.497 L 12.016 14.997 L 9.409 13.497 Z"

/// Claude's mark: the Claude logo (Simple Icons "claude", 24x24, y-down).
private let claudeSVG = "M 4.714 15.956 L 9.432 13.308 L 9.511 13.078 L 9.432 12.95 L 9.201 12.95 L 8.412 12.902 L 5.716 12.829 L 3.379 12.732 L 1.114 12.61 L 0.543 12.489 L 0.009 11.785 L 0.064 11.432 L 0.543 11.111 L 1.229 11.171 L 2.747 11.275 L 5.024 11.432 L 6.675 11.53 L 9.122 11.785 L 9.511 11.785 L 9.565 11.627 L 9.432 11.53 L 9.329 11.432 L 6.973 9.836 L 4.423 8.148 L 3.087 7.176 L 2.365 6.684 L 2.001 6.223 L 1.843 5.215 L 2.498 4.493 L 3.379 4.553 L 3.603 4.614 L 4.496 5.3 L 6.402 6.776 L 8.892 8.609 L 9.256 8.913 L 9.402 8.809 L 9.42 8.737 L 9.256 8.463 L 7.902 6.017 L 6.457 3.527 L 5.813 2.495 L 5.643 1.876 C 5.583 1.621 5.54 1.409 5.54 1.147 L 6.287 0.134 L 6.7 0 L 7.695 0.134 L 8.114 0.498 L 8.734 1.913 L 9.735 4.141 L 11.29 7.17 L 11.745 8.069 L 11.988 8.901 L 12.079 9.156 L 12.237 9.156 L 12.237 9.01 L 12.364 7.304 L 12.601 5.209 L 12.832 2.514 L 12.911 1.755 L 13.287 0.844 L 14.034 0.352 L 14.617 0.631 L 15.096 1.317 L 15.03 1.761 L 14.744 3.612 L 14.186 6.515 L 13.821 8.457 L 14.034 8.457 L 14.277 8.215 L 15.26 6.909 L 16.912 4.845 L 17.64 4.025 L 18.49 3.121 L 19.037 2.69 L 20.069 2.69 L 20.828 3.819 L 20.488 4.985 L 19.425 6.332 L 18.545 7.474 L 17.282 9.174 L 16.493 10.534 L 16.566 10.643 L 16.754 10.625 L 19.607 10.018 L 21.149 9.738 L 22.989 9.423 L 23.821 9.811 L 23.912 10.206 L 23.584 11.013 L 21.617 11.499 L 19.31 11.961 L 15.874 12.774 L 15.831 12.805 L 15.88 12.865 L 17.428 13.011 L 18.09 13.047 L 19.711 13.047 L 22.728 13.272 L 23.517 13.794 L 23.991 14.432 L 23.912 14.917 L 22.698 15.537 L 21.058 15.148 L 17.233 14.237 L 15.922 13.909 L 15.74 13.909 L 15.74 14.019 L 16.833 15.087 L 18.836 16.897 L 21.344 19.228 L 21.471 19.805 L 21.15 20.26 L 20.81 20.212 L 18.606 18.554 L 17.756 17.807 L 15.831 16.186 L 15.704 16.186 L 15.704 16.356 L 16.147 17.006 L 18.49 20.527 L 18.612 21.608 L 18.442 21.96 L 17.835 22.173 L 17.167 22.051 L 15.795 20.127 L 14.38 17.959 L 13.239 16.016 L 13.099 16.095 L 12.425 23.35 L 12.109 23.721 L 11.381 24 L 10.774 23.539 L 10.452 22.792 L 10.774 21.316 L 11.162 19.392 L 11.478 17.862 L 11.763 15.961 L 11.933 15.33 L 11.921 15.288 L 11.781 15.306 L 10.349 17.273 L 8.169 20.218 L 6.445 22.063 L 6.032 22.227 L 5.316 21.857 L 5.382 21.195 L 5.783 20.606 L 8.169 17.57 L 9.608 15.688 L 10.537 14.602 L 10.531 14.444 L 10.476 14.444 L 4.138 18.56 L 3.008 18.706 L 2.523 18.25 L 2.583 17.504 L 2.814 17.261 L 4.721 15.949 Z"

/// Parses the absolute M/L/C/Z subset the two logo strings use.
private func svgPath(_ svg: String) -> CGPath {
    let p = CGMutablePath()
    let t = svg.split(separator: " ")
    var i = 0
    func n() -> CGFloat { defer { i += 1 }; return CGFloat(Double(t[i]) ?? 0) }
    while i < t.count {
        let op = t[i]; i += 1
        switch op {
        case "M": p.move(to: CGPoint(x: n(), y: n()))
        case "L": p.addLine(to: CGPoint(x: n(), y: n()))
        case "C":
            let c1 = CGPoint(x: n(), y: n()), c2 = CGPoint(x: n(), y: n())
            p.addCurve(to: CGPoint(x: n(), y: n()), control1: c1, control2: c2)
        default: p.closeSubpath()
        }
    }
    return p
}

let openAILogo = svgPath(openAISVG)
let claudeLogo = svgPath(claudeSVG)

/// Fills a 24x24 logo path into `rect` of a flipped (y-down) context.
func drawLogo(_ ctx: CGContext, _ logo: CGPath, in rect: CGRect, color: NSColor) {
    let k = min(rect.width, rect.height) / 24
    var tr = CGAffineTransform(translationX: rect.midX - 12 * k, y: rect.midY - 12 * k).scaledBy(x: k, y: k)
    guard let path = logo.copy(using: &tr) else { return }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
}

/// The agent's logo: Claude's starburst or OpenAI's knot (Codex).
func drawAgentLogo(_ ctx: CGContext, _ agent: Agent, in rect: CGRect, color: NSColor) {
    drawLogo(ctx, agent == .claude ? claudeLogo : openAILogo, in: rect, color: color)
}

/// Stable pseudo-random number in [-1, 1] for (a, b, c) — letter jitter that doesn't change between frames.
func jitter(_ a: Int, _ b: Int, _ c: Int) -> CGFloat {
    var h = UInt64(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663 ^ c &* 83492791)
    h ^= h >> 33; h = h &* 0xff51afd7ed558ccd; h ^= h >> 33
    return CGFloat(h % 2001) / 1000 - 1
}
