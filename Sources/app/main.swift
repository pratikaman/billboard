// Billboard — a split-flap board that hangs under the menu bar and shows what every Claude Code
// session is doing. State comes from billboard-hook (see Sources/hook) via /tmp/claude-billboard.
import AppKit
import AVFoundation

// MARK: - Preferences

enum Pref {
    static let d = UserDefaults.standard
    static var maxRows: Int { get { d.object(forKey: "rows") as? Int ?? 4 } set { d.set(newValue, forKey: "rows") } }
    static var scale: Double { get { d.object(forKey: "scale") as? Double ?? 1.0 } set { d.set(newValue, forKey: "scale") } }
    static var position: String { get { d.string(forKey: "position") ?? "center" } set { d.set(newValue, forKey: "position") } }
    static var fadeOnHover: Bool { get { d.object(forKey: "fade") as? Bool ?? true } set { d.set(newValue, forKey: "fade") } }
    static var hideWhenEmpty: Bool { get { d.object(forKey: "hideEmpty") as? Bool ?? false } set { d.set(newValue, forKey: "hideEmpty") } }
    static var sound: Bool { get { d.object(forKey: "sound") as? Bool ?? false } set { d.set(newValue, forKey: "sound") } }
    static var visible: Bool { get { d.object(forKey: "visible") as? Bool ?? true } set { d.set(newValue, forKey: "visible") } }
    static var theme: Theme { get { Theme(rawValue: d.string(forKey: "theme") ?? "") ?? .flip } set { d.set(newValue.rawValue, forKey: "theme") } }
}

// MARK: - Rows

let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

func rowData(_ s: Session, blinkOn: Bool) -> RowData {
    RowData(time: timeFmt.string(from: s.since), name: s.name, activity: s.activity, state: s.state, agent: s.agent, blinkOn: blinkOn)
}

/// Which sessions get a row: everything, unless there are more than `max` — then the ones that most
/// need attention, still shown in their stable first-seen order.
func pick(_ all: [Session], max: Int) -> [Session] {
    guard all.count > max else { return all }
    let ranked = all.sorted { a, b in a.state.rank != b.state.rank ? a.state.rank < b.state.rank : a.updated > b.updated }
    let keep = Set(ranked.prefix(max).map(\.sid))
    return all.filter { keep.contains($0.sid) }
}

// MARK: - Flap sound (synthesised clack, off by default)

final class Clacker {
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var buffers: [AVAudioPCMBuffer] = []
    private var next = 0
    private var started = false

    init() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        for v in 0..<4 {
            let n = 300
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            let p = b.floatChannelData![0]
            var lp: Float = 0
            let f0 = Float(1900 + v * 350)
            for i in 0..<n {
                let t = Float(i) / 44100
                lp += (Float.random(in: -1...1) - lp) * 0.35   // softened noise
                let body = sinf(2 * .pi * f0 * t) * expf(-t / 0.0016)
                p[i] = (lp * 0.8 + body * 0.6) * expf(-t / 0.0011)
            }
            buffers.append(b)
        }
        for _ in 0..<6 {
            let pl = AVAudioPlayerNode()
            engine.attach(pl)
            engine.connect(pl, to: engine.mainMixerNode, format: fmt)
            players.append(pl)
        }
        engine.mainMixerNode.outputVolume = 0.35
    }

    func clack(_ count: Int) {
        if !started { try? engine.start(); players.forEach { $0.play() }; started = true }
        let pl = players[next % players.count]
        next += 1
        pl.volume = min(1, 0.35 + Float(count) * 0.06)
        pl.scheduleBuffer(buffers[Int.random(in: 0..<buffers.count)], at: nil, options: [])
    }

    func stop() { if started { engine.stop(); started = false } }
}

// MARK: - App

final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = SessionStore()
    var panel: Panel!
    var board: ThemeView!
    var rowsShown = 0
    var scaleShown: CGFloat = 0
    var statusItem: NSStatusItem!
    var sessions: [Session] = []
    var clacker: Clacker?
    var lastClack: CFTimeInterval = 0
    let demo = CommandLine.arguments.contains("--demo")
    let demoStart = Date()

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.title = "Billboard"
        installTheme(Pref.theme)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: "Billboard")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refresh()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.hoverFade() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.position(animate: false)
        }
        if Pref.visible { panel.orderFrontRegardless() }
    }

    // MARK: data → board

    func refresh() {
        sessions = demo ? demoSessions(since: demoStart) : store.load()
        let shown = pick(sessions, max: Pref.maxRows)
        if shown.isEmpty && Pref.hideWhenEmpty {
            if panel.isVisible { panel.orderOut(nil) }
        } else if Pref.visible && !panel.isVisible {
            panel.orderFrontRegardless()
        }
        let rows = max(1, shown.count)
        if rows != rowsShown || CGFloat(Pref.scale) != scaleShown { applyLayout(rows: rows) }
        let phase = Int(Date().timeIntervalSince1970 / 1.2) % 2 == 0
        board.show(shown.isEmpty ? [RowData.empty] : shown.map { rowData($0, blinkOn: phase) })
        let needsYou = sessions.contains { $0.state == .needs }
        statusItem.button?.image = NSImage(systemSymbolName: needsYou ? "tram.circle.fill" : "tram.fill", accessibilityDescription: "Billboard")
    }

    func applyLayout(rows: Int) {
        rowsShown = rows
        scaleShown = CGFloat(Pref.scale)
        board.configure(rows: rows, scale: scaleShown)
        position(animate: false)
    }

    func installTheme(_ t: Theme) {
        let v = t.make()
        v.onFlap = { [weak self] count in self?.flapped(count) }
        board = v
        panel.contentView = v
        rowsShown = 0
    }

    func position(animate: Bool) {
        guard let screen = NSScreen.screens.first else { return }   // the menu-bar screen
        let size = board.windowSize
        let visTop = screen.visibleFrame.maxY
        let top = visTop > screen.frame.maxY - 60 ? visTop : screen.frame.maxY - NSStatusBar.system.thickness
        let x: CGFloat
        switch Pref.position {
        case "left": x = screen.frame.minX + 60
        case "right": x = screen.frame.maxX - size.width - 60
        default: x = screen.frame.midX - size.width / 2
        }
        let frame = NSRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: animate)
    }

    func hoverFade() {
        guard panel.isVisible else { return }
        let m = NSEvent.mouseLocation
        let b = board.boardRect
        let boardOnScreen = NSRect(x: panel.frame.minX + b.minX, y: panel.frame.maxY - b.maxY, width: b.width, height: b.height)
        let inside = Pref.fadeOnHover && boardOnScreen.contains(m)
        let target: CGFloat = inside ? 0.12 : 1
        guard abs(panel.alphaValue - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = inside ? 0.15 : 0.35
            panel.animator().alphaValue = target
        }
    }

    func flapped(_ count: Int) {
        guard Pref.sound, panel.isVisible, panel.alphaValue > 0.5 else { return }
        let now = CACurrentMediaTime()
        guard now - lastClack > 0.028 else { return }
        lastClack = now
        if clacker == nil { clacker = Clacker() }
        clacker?.clack(count)
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ on: Bool? = nil, _ action: @escaping () -> Void) -> NSMenuItem {
            let i = ClosureItem(title: title, action: action)
            if let on { i.state = on ? .on : .off }
            return i
        }
        if sessions.isEmpty {
            let i = NSMenuItem(title: "No Claude sessions yet", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        for s in sessions {
            let status = rowData(s, blinkOn: true).statusWord
            let i = item("\(s.name) — \(status)\(s.agent == .codex ? "  (Codex)" : "")") { [weak self] in self?.open(s) }
            i.toolTip = [s.title, s.activity, s.cwd].filter { !$0.isEmpty }.joined(separator: "\n")
            menu.addItem(i)
        }
        menu.addItem(.separator())
        menu.addItem(item(panel.isVisible ? "Hide Billboard" : "Show Billboard") { [weak self] in
            guard let self else { return }
            Pref.visible = !panel.isVisible
            if Pref.visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        })
        let themes = NSMenu()
        for t in Theme.allCases {
            themes.addItem(item(t.title, Pref.theme == t) { [weak self] in
                guard let self, Pref.theme != t else { return }
                Pref.theme = t
                installTheme(t)
                refresh()
            })
        }
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themes
        menu.addItem(themeItem)
        let rows = NSMenu()
        for n in [2, 3, 4, 5, 6] { rows.addItem(item("\(n)", Pref.maxRows == n) { [weak self] in Pref.maxRows = n; self?.refresh() }) }
        let sizes = NSMenu()
        for (t, v) in [("Small", 0.85), ("Medium", 1.0), ("Large", 1.2)] {
            sizes.addItem(item(t, Pref.scale == v) { [weak self] in Pref.scale = v; self?.refresh() })
        }
        let pos = NSMenu()
        for p in ["left", "center", "right"] {
            pos.addItem(item(p.capitalized, Pref.position == p) { [weak self] in Pref.position = p; self?.position(animate: true) })
        }
        for (t, m) in [("Max Rows", rows), ("Size", sizes), ("Position", pos)] {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            i.submenu = m
            menu.addItem(i)
        }
        menu.addItem(item("Fade When Mouse Is Over It", Pref.fadeOnHover) { Pref.fadeOnHover.toggle() })
        menu.addItem(item("Hide When No Sessions", Pref.hideWhenEmpty) { [weak self] in Pref.hideWhenEmpty.toggle(); self?.refresh() })
        menu.addItem(item("Flap Sound", Pref.sound) { [weak self] in
            Pref.sound.toggle()
            if !Pref.sound { self?.clacker?.stop() }
        })
        menu.addItem(.separator())
        menu.addItem(item("Quit Billboard") { NSApp.terminate(nil) })
    }

    /// Reveals the session's folder in Finder.
    func open(_ s: Session) {
        guard !s.cwd.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.cwd)])
    }
}

// MARK: - Demo data (--demo, --snapshot)

func demoSessions(since start: Date) -> [Session] {
    let t = Date().timeIntervalSince(start)
    let base = Date().addingTimeInterval(-600)
    func s(_ id: String, _ cwd: String, _ st: SessionState, _ act: String, _ ago: Double) -> Session {
        Session(sid: id, agent: id == "ccc" ? .codex : .claude, cwd: cwd, title: "", state: st, activity: act,
                since: Date().addingTimeInterval(-ago), updated: Date(), firstSeen: base.addingTimeInterval(Double(id.count)))
    }
    let phase = Int(t / 4) % 4
    let acts = ["EDITING MAIN.SWIFT", "RUNNING BUILD.SH", "READING BOARD.SWIFT", "SEARCHING FLIPDURATION"]
    return [
        s("a", "/x/billboard", .working, acts[phase], 42),
        s("bb", "/x/forgotchi", phase == 2 ? .needs : .working, phase == 2 ? "RUN ./BUILD.SH" : "WRITING HOOK.SH", 190),
        s("ccc", "/x/dotfiles", phase >= 2 ? .turn : .working, phase >= 2 ? "DONE" : "AGENT REVIEW THE DIFF", 725),
        s("dddd", "/x/yeet", .idle, "DONE", 3600),
    ]
}

final class ClosureItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

// MARK: - Snapshot mode: Billboard --snapshot out.png [--rows N] [--scale S] [--flip 0.3] [--needs]

func snapshot(_ out: String) {
    let a = CommandLine.arguments
    func arg(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
    var all = demoSessions(since: Date().addingTimeInterval(a.contains("--needs") ? -9 : 0))
    if let n = arg("--rows").flatMap(Int.init) { all = Array(all.prefix(n)) }
    let theme = Theme(rawValue: arg("--theme") ?? "flip") ?? .flip
    let v = theme.make()
    let scale = CGFloat(Double(arg("--scale") ?? "1") ?? 1)
    v.configure(rows: max(1, all.count), scale: scale)
    v.frame = CGRect(origin: .zero, size: v.windowSize)
    v.show(all.isEmpty ? [RowData.empty] : all.map { rowData($0, blinkOn: true) })
    v.settle()
    if let f = arg("--flip").flatMap(Double.init), let fv = v as? FlipBoardView {   // freeze some flaps mid-fold
        var s = all[0]
        s.activity = "RUNNING BUILD.SH"
        fv.show([rowData(s, blinkOn: true)])
        fv.freezeMidFlip(f)
    }
    if let t = arg("--at").flatMap(Double.init) {   // re-show row 0 changed, then render `t` seconds into the change
        var s = all[0]
        s.activity = "Running build.sh"
        s.state = .needs
        v.show([rowData(s, blinkOn: true)] + all.dropFirst().map { rowData($0, blinkOn: true) })
        RunLoop.main.run(until: Date().addingTimeInterval(t))
    }
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) \(Int(v.windowSize.width))x\(Int(v.windowSize.height))pt")
}

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    snapshot(CommandLine.arguments[i + 1])
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
