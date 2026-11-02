// Reads the per-session state files that billboard-hook writes, plus a little from each transcript
// (the AI-generated session title, and "[Request interrupted by user" which has no hook event).
import Foundation
import Darwin

enum SessionState: String {
    case working, needs, turn, error, idle

    var rank: Int { [.needs: 0, .error: 1, .turn: 2, .working: 3, .idle: 4][self]! }
}

struct Session: Equatable {
    var sid: String
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
        return folder.isEmpty ? (title.isEmpty ? "CLAUDE" : title) : folder
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

    private struct TranscriptInfo { var offset: UInt64 = 0; var title = ""; var interruptedAt: Date? }
    private var transcripts: [String: TranscriptInfo] = [:]
    private var firstSeen: [String: Date] = [:]

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

            // Gone: the CLI process exited without SessionEnd (closed terminal, crash), or a stale file with no pid.
            if let pid = j["pid"] as? Int {
                if kill(pid_t(pid), 0) != 0 && errno == ESRCH { unlink(path); transcripts[sid] = nil; continue }
            } else if now.timeIntervalSince(updated) > 6 * 3600 { unlink(path); continue }

            var info = transcripts[sid] ?? TranscriptInfo()
            if let t = j["transcript"] as? String { scan(t, &info) }
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
            out.append(Session(sid: sid, cwd: j["cwd"] as? String ?? "", title: info.title, state: state,
                               activity: activity, since: since, updated: updated, firstSeen: seen))
        }
        return out.sorted { ($0.firstSeen, $0.sid) < ($1.firstSeen, $1.sid) }
    }

    /// Reads only the bytes added since last time (first time: the last 2 MB) and picks out
    /// the newest {"type":"ai-title","aiTitle":…} and any user interrupt.
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
            } else if line.range(of: Data("[Request interrupted by user".utf8)) != nil,
                      line.range(of: Data("\"type\":\"user\"".utf8)) != nil,
                      let j = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let ts = j["timestamp"] as? String, let at = Self.iso.date(from: ts) {
                info.interruptedAt = max(info.interruptedAt ?? .distantPast, at)
            }
        }
    }
}
