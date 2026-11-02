#!/usr/bin/env python3
"""Adds (or with --uninstall removes) Billboard's hook to every Claude Code config dir's settings.json.
Backs each file up first. Existing hooks are left alone."""
import json, os, sys, time, shutil

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bin", "billboard-hook")
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
          "Notification", "Stop", "StopFailure", "SessionEnd"]
TOOL_EVENTS = {"PreToolUse", "PostToolUse", "PostToolUseFailure"}
DIRS = [os.path.expanduser(d) for d in ("~/.claude", "~/.claude-sidekick")]
if os.environ.get("CLAUDE_CONFIG_DIR"):
    DIRS.append(os.path.expanduser(os.environ["CLAUDE_CONFIG_DIR"]))

uninstall = "--uninstall" in sys.argv
for d in dict.fromkeys(DIRS):
    path = os.path.join(d, "settings.json")
    if not os.path.isdir(d):
        continue
    cfg = json.load(open(path)) if os.path.exists(path) else {}
    if os.path.exists(path):
        shutil.copy2(path, f"{path}.bak-{int(time.time())}-billboard")
    hooks = cfg.setdefault("hooks", {})
    for ev in EVENTS:
        groups = hooks.get(ev, [])
        groups = [g for g in groups if not any("billboard-hook" in h.get("command", "") for h in g.get("hooks", []))]
        if not uninstall:
            g = {"hooks": [{"type": "command", "command": HOOK, "timeout": 5}]}
            if ev in TOOL_EVENTS:
                g = {"matcher": "*", **g}
            groups.append(g)
        if groups: hooks[ev] = groups
        else: hooks.pop(ev, None)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2); f.write("\n")
    os.replace(tmp, path)
    print(("removed from " if uninstall else "installed in ") + path)
