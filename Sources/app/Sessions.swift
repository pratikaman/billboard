// Reads the per-session state files that billboard-hook writes (Claude Code and Codex CLI sessions alike),
// plus a little from each transcript: the session title, and interrupts, which have no hook event
// ("[Request interrupted by user" in Claude transcripts, "turn_aborted" in Codex rollouts).
import Foundation
import Darwin

enum SessionState: String {
    case working, needs, turn, error, idle

    var rank: Int { [.needs: 0, .error: 1, .turn: 2, .working: 3, .idle: 4][self]! }
}

enum Agent: String {
    case claude, codex
    var title: String { self == .claude ? "Claude" : "Codex" }
}

struct Session: Equatable {
    var sid: String
    var agent: Agent = .claude
    var cwd: String
    var title: String
    var state: SessionState
    var activity: String
    var since: Date        // when the current state began (turn start while working, finish time when done)
    var updated: Date
    var firstSeen: Date

    /// Short name for the SESSION column: the project folder, or the session title when the folder says nothing.
    var name: String {
        let folder = (cwd as NSString).lastPathComponent
        let generic: Set<String> = ["", "/", "Downloads", "Desktop", "Documents", "tmp", "scratchpad", NSUserName()]
        if (generic.contains(folder) || cwd == NSHomeDirectory()), !title.isEmpty { return title }
        return folder.isEmpty ? (title.isEmpty ? agent.title : title) : folder
    }
}

final class SessionStore {
    static let dir = "/tmp/claude-billboard"
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// A finished session counts as "your turn" this long, then fades to idle.
    var turnFreshness: TimeInterval = 15 * 60

    private struct TranscriptInfo { var path = ""; var offset: UInt64 = 0; var title = ""; var interruptedAt: Date?; var lastLookup = Date.distantPast }
    private var transcripts: [String: TranscriptInfo] = [:]
    private var firstSeen: [String: Date] = [:]
    private var codexTitles: [String: (mtime: Date, titles: [String: String])] = [:]   // per CODEX_HOME

    func load() -> [Session] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.dir) else { return [] }
        let now = Date()
        var out: [Session] = []
        for n in names where n.hasSuffix(".json") {
            let path = "\(Self.dir)/\(n)"
            guard let data = fm.contents(atPath: path),
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = j["sid"] as? String else { continue }
            let updated = Date(timeIntervalSince1970: j["updated"] as? Double ?? 0)
            let agent = Agent(rawValue: j["agent"] as? String ?? "") ?? .claude

            // Gone: the CLI process exited without SessionEnd (closed terminal, crash), or a stale file with no pid.
            if let pid = j["pid"] as? Int {
                if kill(pid_t(pid), 0) != 0 && errno == ESRCH { unlink(path); transcripts[sid] = nil; continue }
            } else if now.timeIntervalSince(updated) > 6 * 3600 { unlink(path); continue }

            var info = transcripts[sid] ?? TranscriptInfo()
            if let t = j["transcript"] as? String { info.path = t }
            let home = j["home"] as? String
            if agent == .codex, info.path.isEmpty, let home, now.timeIntervalSince(info.lastLookup) > 10 {
                info.lastLookup = now
                info.path = findCodexRollout(home: home, sid: sid) ?? ""
            }
            if !info.path.isEmpty { scan(info.path, &info) }
            if agent == .codex, let home, let t = codexTitle(home: home, sid: sid) { info.title = t }
            transcripts[sid] = info

            var state = SessionState(rawValue: j["state"] as? String ?? "idle") ?? .idle
            var activity = j["activity"] as? String ?? ""
            var since = Date(timeIntervalSince1970: j["since"] as? Double ?? updated.timeIntervalSince1970)
            if let at = info.interruptedAt, at > updated, state == .working || state == .needs {
                state = .turn; activity = "Interrupted"; since = at
            }
            if state == .turn || state == .error { since = max(updated, info.interruptedAt ?? .distantPast) }
            if state == .turn, now.timeIntervalSince(since) > turnFreshness { state = .idle }
            // A working session that has been silent for very long probably died mid-turn without a pid.
            if state == .working, j["pid"] == nil, now.timeIntervalSince(updated) > 30 * 60 { state = .idle }

            let seen = firstSeen[sid] ?? updated
            firstSeen[sid] = seen
            out.append(Session(sid: sid, agent: agent, cwd: j["cwd"] as? String ?? "", title: info.title, state: state,
                               activity: activity, since: since, updated: updated, firstSeen: seen))
        }
        return out.sorted { ($0.firstSeen, $0.sid) < ($1.firstSeen, $1.sid) }
    }

    /// Reads only the bytes added since last time (first time: the last 2 MB) and picks out the newest
    /// Claude {"type":"ai-title"} and any interrupt.
    private func scan(_ path: String, _ info: inout TranscriptInfo) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let end = (try? fh.seekToEnd()) ?? 0
        if info.offset == 0 { info.offset = end > 2_000_000 ? end - 2_000_000 : 0 }
        if end < info.offset { info.offset = 0 }   // rewritten
        guard end > info.offset else { return }
        try? fh.seek(toOffset: info.offset)
        guard let data = try? fh.read(upToCount: Int(end - info.offset)) else { return }
        // Only consume up to the last newline so a half-written line is read whole next time.
        guard let lastNL = data.lastIndex(of: 0x0A) else { return }
        info.offset += UInt64(lastNL - data.startIndex + 1)
        let chunk = data[data.startIndex...lastNL]
        for line in chunk.split(separator: 0x0A) {
            if line.count < 2000, line.range(of: Data("\"ai-title\"".utf8)) != nil,
               let j = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               let t = j["aiTitle"] as? String, !t.isEmpty {
                info.title = t
            } else if isInterrupt(line), let j = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let ts = j["timestamp"] as? String, let at = Self.iso.date(from: ts) ?? Self.isoPlain.date(from: ts) {
                info.interruptedAt = max(info.interruptedAt ?? .distantPast, at)
            }
        }
    }

    private func isInterrupt(_ line: Data.SubSequence) -> Bool {
        if line.range(of: Data("[Request interrupted by user".utf8)) != nil, line.range(of: Data("\"type\":\"user\"".utf8)) != nil { return true }
        return line.count < 4000 && line.range(of: Data("\"turn_aborted\"".utf8)) != nil
    }

    static let isoPlain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()

    /// Codex names each thread in $CODEX_HOME/session_index.jsonl ({"id":…,"thread_name":…}); re-read when it changes.
    private func codexTitle(home: String, sid: String) -> String? {
        let path = home + "/session_index.jsonl"
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        if codexTitles[home]?.mtime != mtime, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            var titles: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let id = j["id"] as? String, let name = j["thread_name"] as? String, !name.isEmpty else { continue }
                titles[id] = name
            }
            codexTitles[home] = (mtime, titles)
        }
        return codexTitles[home]?.titles[sid]
    }

    /// Codex keeps rollouts at $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<time>-<session id>.jsonl.
    private func findCodexRollout(home: String, sid: String) -> String? {
        let fm = FileManager.default
        let cal = Calendar(identifier: .gregorian)
        for back in 0..<3 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = String(format: "%@/sessions/%04d/%02d/%02d", home, c.year ?? 0, c.month ?? 0, c.day ?? 0)
            if let hit = (try? fm.contentsOfDirectory(atPath: dir))?.first(where: { $0.contains(sid) && $0.hasSuffix(".jsonl") }) {
                return dir + "/" + hit
            }
        }
        return nil
    }
}
