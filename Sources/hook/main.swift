// billboard-hook — a Claude Code / Codex CLI hook. Reads the hook JSON on stdin and keeps one small state
// file per session in /tmp/claude-billboard/<session_id>.json for Billboard.app to show. Foundation only, so
// it starts in a few ms (PreToolUse hooks block the tool call while they run). Always exits 0, prints nothing.
//
//   billboard-hook          — called by Claude Code
//   billboard-hook codex    — called by Codex CLI (its hooks.json uses the same event names)
import Foundation
import Darwin

let dir = "/tmp/claude-billboard"
let agent = CommandLine.arguments.dropFirst().contains("codex") ? "codex" : "claude"
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let j = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let sid = j["session_id"] as? String, !sid.isEmpty, !sid.contains("/") else { exit(0) }
let event = j["hook_event_name"] as? String ?? ""
let path = "\(dir)/\(sid).json"
mkdir(dir, 0o755)

if event == "SessionEnd" { unlink(path); exit(0) }

var s = ((try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
let now = Date().timeIntervalSince1970
s["sid"] = sid
s["agent"] = agent
s["updated"] = now
s["event"] = event
if let v = j["cwd"] as? String { s["cwd"] = v }
if let v = j["transcript_path"] as? String, !v.isEmpty { s["transcript"] = v }
if agent == "codex", s["home"] == nil {   // where this Codex keeps session titles and rollouts
    s["home"] = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
}
if s["pid"] == nil, let pid = agentAncestor() { s["pid"] = pid }

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
    case "AskUserQuestion", "request_user_input": set("needs", "Has a question")
    case "ExitPlanMode": set("needs", "Plan ready for review")
    default: set("working", describe(tool, inp))
    }
case "PermissionRequest":   // Codex asks before running something (Claude Code uses Notification for this)
    set("needs")
case "PostToolUse", "PostToolUseFailure":
    if state != "working" { set("working") }   // a permission was granted / question answered
case "PreCompact":
    set("working", "Compacting the context")
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
    case "Bash", "shell", "exec_command", "local_shell", "unified_exec":
        let d = str("description")
        if !d.isEmpty { return d }
        if let parts = i["command"] as? [String] { return shellLine(parts.last ?? parts.joined(separator: " ")) }
        return shellLine(str("command").isEmpty ? str("cmd") : str("command"))
    case "apply_patch":   // Codex edits files with a patch: "*** Update File: path"
        return patchLine(str("command").isEmpty ? str("input") : str("command"))
    case "Read": return "Reading " + base("file_path")
    case "Edit", "MultiEdit": return "Editing " + base("file_path")
    case "Write": return "Writing " + base("file_path")
    case "NotebookEdit": return "Editing " + base("notebook_path")
    case "Grep": return "Searching " + str("pattern")
    case "Glob": return "Finding " + str("pattern")
    case "WebSearch", "web_search": return "Web search " + str("query")
    case "WebFetch": return "Reading " + (URL(string: str("url"))?.host ?? "web")
    case "Task", "Agent", "spawn_agent":
        let d = str("description")
        return d.isEmpty ? "Running an agent" : "Agent: " + d
    case "TodoWrite", "TaskCreate", "TaskUpdate", "update_plan": return "Planning"
    case "view_image": return "Looking at an image"
    case "Skill": return "Skill " + str("skill")
    case "ToolSearch", "tool_search": return "Loading tools"
    case "Workflow": return "Running a workflow"
    case "Artifact": return "Publishing a page"
    default:
        if tool.hasPrefix("mcp__") {   // mcp__server__tool → "server tool"
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            let server = parts.first.map { $0.replacingOccurrences(of: "plugin_", with: "").replacingOccurrences(of: "claude_ai_", with: "") } ?? ""
            let name = parts.dropFirst().joined(separator: " ")
            if server.contains("firecrawl") { return name.contains("search") ? "Web search " + str("query") : "Browsing " + (URL(string: str("url"))?.host ?? "web") }
            return (server + " " + name).replacingOccurrences(of: "_", with: " ")
        }
        return tool.replacingOccurrences(of: "_", with: " ")
    }
}

/// A shell command as a board line. Codex reads and searches through the shell, so the common read-only
/// commands get named ("Reading Board.swift", "Searching flipDuration"); anything else is "Run <command>".
func shellLine(_ raw: String) -> String {
    var c = raw.split(separator: "\n").first.map(String.init) ?? ""
    // unwrap `bash -lc '…'` / `zsh -c "…"`
    for pre in ["bash -lc ", "bash -c ", "zsh -lc ", "zsh -c ", "/bin/bash -lc ", "/bin/zsh -lc ", "sh -c "] where c.hasPrefix(pre) {
        c = String(c.dropFirst(pre.count)).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
    }
    if c.hasPrefix("cd "), let amp = c.range(of: "&& ") { c = String(c[amp.upperBound...]) }
    let words = c.split(separator: " ").map(String.init)
    guard let cmd = words.first.map({ ($0 as NSString).lastPathComponent }) else { return "Run a command" }
    let args = words.dropFirst().filter { !$0.hasPrefix("-") }
    func clean(_ w: String) -> String { w.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
    switch cmd {
    case "cat", "sed", "head", "tail", "nl", "less", "bat":
        if let f = args.last(where: { $0.contains(".") || $0.contains("/") }) { return "Reading " + (clean(f) as NSString).lastPathComponent }
    case "rg", "grep", "ag":
        if let p = args.first { return "Searching " + clean(p) }
    case "ls", "find", "tree", "fd": return "Looking around the files"
    case "git": return "Git " + (args.first ?? "")
    default: break
    }
    return "Run " + c
}

/// "*** Update File: Sources/app/Board.swift" → "Editing Board.swift" (+N when the patch touches more files).
func patchLine(_ patch: String) -> String {
    var files: [(String, String)] = []
    for line in patch.split(separator: "\n") {
        for (marker, verb) in [("*** Update File: ", "Editing"), ("*** Add File: ", "Creating"), ("*** Delete File: ", "Deleting")]
        where line.hasPrefix(marker) {
            files.append((verb, (String(line.dropFirst(marker.count)) as NSString).lastPathComponent))
        }
    }
    guard let first = files.first else { return "Editing files" }
    return "\(first.0) \(first.1)" + (files.count > 1 ? " +\(files.count - 1)" : "")
}

/// PID of the nearest ancestor that is the agent CLI that fired this hook.
func agentAncestor() -> Int? {
    var pid = getppid()
    for _ in 0..<8 {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // ~/.local/bin/claude is a symlink to …/claude/versions/2.1.316, so p_comm is the version number;
        // Codex's native binary lives at …/codex/packages/standalone/releases/<v>/bin/codex
        var buf = [CChar](repeating: 0, count: 4096)
        let exe = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
        if agent == "claude" && (exe.hasSuffix("/claude") || exe.contains("/claude/versions/")) { return Int(pid) }
        if agent == "codex" && exe.hasSuffix("/codex") { return Int(pid) }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}
