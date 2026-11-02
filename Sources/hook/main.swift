// billboard-hook — Claude Code hook. Reads the hook JSON on stdin and keeps one small state file per
// session in /tmp/claude-billboard/<session_id>.json for Billboard.app to show. Foundation only, so it
// starts in a few ms (PreToolUse hooks block the tool call while they run). Always exits 0, prints nothing.
import Foundation
import Darwin

let dir = "/tmp/claude-billboard"
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let j = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let sid = j["session_id"] as? String, !sid.isEmpty, !sid.contains("/") else { exit(0) }
let event = (j["hook_event_name"] as? String) ?? CommandLine.arguments.dropFirst().first ?? ""
let path = "\(dir)/\(sid).json"
mkdir(dir, 0o755)

if event == "SessionEnd" { unlink(path); exit(0) }

var s = ((try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
let now = Date().timeIntervalSince1970
s["sid"] = sid
s["updated"] = now
s["event"] = event
if let v = j["cwd"] as? String { s["cwd"] = v }
if let v = j["transcript_path"] as? String { s["transcript"] = v }
if s["pid"] == nil, let pid = claudeAncestor() { s["pid"] = pid }

let state = s["state"] as? String ?? "idle"
func set(_ st: String, _ activity: String? = nil) {
    s["state"] = st
    if let a = activity { s["activity"] = a }
}

switch event {
case "SessionStart":
    if s["activity"] == nil { set("idle", "Ready") }
case "UserPromptSubmit":
    set("working", "Thinking")
    s["since"] = now
    if let p = j["prompt"] as? String { s["prompt"] = String(p.prefix(300)) }
case "PreToolUse":
    let tool = j["tool_name"] as? String ?? "Tool"
    let inp = j["tool_input"] as? [String: Any] ?? [:]
    if s["since"] == nil || state != "working" && state != "needs" { s["since"] = now }
    switch tool {
    case "AskUserQuestion": set("needs", "Has a question")
    case "ExitPlanMode": set("needs", "Plan ready for review")
    default: set("working", describe(tool, inp))
    }
case "PostToolUse", "PostToolUseFailure":
    if state != "working" { set("working") }   // a permission was granted / question answered
case "Notification":
    switch j["notification_type"] as? String ?? "" {
    case "permission_prompt": set("needs")
    case "elicitation_dialog": set("needs", "Has a question")
    case "idle_prompt": if state == "working" || state == "needs" { set("turn", "Done") }
    default: break
    }
case "Stop":
    set("turn", "Done")
    if let m = j["last_assistant_message"] as? String { s["last"] = String(m.prefix(300)) }
case "StopFailure":
    set("error", ((j["error"] as? String) ?? (j["error_type"] as? String)).map { "Error: " + $0 } ?? "API error")
default:
    break
}

if let out = try? JSONSerialization.data(withJSONObject: s) {
    let tmp = path + ".\(getpid()).tmp"
    if FileManager.default.createFile(atPath: tmp, contents: out) { rename(tmp, path) }
}
exit(0)

// MARK: - helpers

/// Short board line for a tool call, e.g. "Editing main.swift". Themes uppercase/clip it as their medium needs.
func describe(_ tool: String, _ i: [String: Any]) -> String {
    func str(_ k: String) -> String { (i[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    func base(_ k: String) -> String { (str(k) as NSString).lastPathComponent }
    switch tool {
    case "Bash":
        let d = str("description")
        if !d.isEmpty { return d }
        let c = str("command").split(separator: "\n").first.map(String.init) ?? ""
        return "Run " + c
    case "Read": return "Reading " + base("file_path")
    case "Edit", "MultiEdit": return "Editing " + base("file_path")
    case "Write": return "Writing " + base("file_path")
    case "NotebookEdit": return "Editing " + base("notebook_path")
    case "Grep": return "Searching " + str("pattern")
    case "Glob": return "Finding " + str("pattern")
    case "WebSearch": return "Web search " + str("query")
    case "WebFetch": return "Reading " + (URL(string: str("url"))?.host ?? "web")
    case "Task", "Agent":
        let d = str("description")
        return d.isEmpty ? "Running an agent" : "Agent: " + d
    case "TodoWrite", "TaskCreate", "TaskUpdate": return "Planning"
    case "Skill": return "Skill " + str("skill")
    case "ToolSearch": return "Loading tools"
    case "Workflow": return "Running a workflow"
    case "Artifact": return "Publishing a page"
    default:
        if tool.hasPrefix("mcp__") {   // mcp__server__tool → "SERVER TOOL"
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            let server = parts.first.map { $0.replacingOccurrences(of: "plugin_", with: "").replacingOccurrences(of: "claude_ai_", with: "") } ?? ""
            let name = parts.dropFirst().joined(separator: " ")
            if server.contains("firecrawl") { return name.contains("search") ? "Web search " + str("query") : "Browsing " + (URL(string: str("url"))?.host ?? "web") }
            return (server + " " + name).replacingOccurrences(of: "_", with: " ")
        }
        return tool
    }
}

/// PID of the nearest ancestor process that is the claude CLI (the CLI that fired this hook).
func claudeAncestor() -> Int? {
    var pid = getppid()
    for _ in 0..<8 {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // ~/.local/bin/claude is a symlink to …/claude/versions/2.1.316, so p_comm is the version number
        var buf = [CChar](repeating: 0, count: 4096)
        let exe = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
        if exe.hasSuffix("/claude") || exe.contains("/claude/versions/") { return Int(pid) }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}
