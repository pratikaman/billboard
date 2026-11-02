#!/usr/bin/env python3
"""Adds (or with --uninstall removes) Billboard's hook for Claude Code and Codex CLI.

  ./install-hooks.py                         Claude: ~/.claude (+ ~/.claude-sidekick, $CLAUDE_CONFIG_DIR if present)
                                             Codex:  $CODEX_HOME, or ~/.codex
  ./install-hooks.py --codex-home ~/.codex-x  Codex home(s) to use instead (repeatable), e.g. for a `codex` alias
                                             that sets CODEX_HOME
  ./install-hooks.py --no-claude / --no-codex
  ./install-hooks.py --uninstall

Every file is backed up first (<file>.bak-<time>-billboard) and other hooks are left alone.

Codex only runs a hook the user has trusted. Trust lives in $CODEX_HOME/config.toml as
[hooks.state."<hooks.json>:<event>:<group>:<handler>"] trusted_hash = "sha256:<hash of the normalized hook>".
This script writes those records for Billboard's own hooks (inside a marked block) so Codex doesn't ask you
to review them in /hooks. If a future Codex changes the hash format, Codex simply asks once.
"""
import hashlib, json, os, re, shutil, sys, time

ROOT = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(ROOT, "bin", "billboard-hook")
STAMP = int(time.time())
args = sys.argv[1:]
uninstall = "--uninstall" in args


def backup(path):
    if os.path.exists(path):
        shutil.copy2(path, f"{path}.bak-{STAMP}-billboard")


def write_atomic(path, text):
    tmp = path + ".tmp-billboard"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def is_ours(group):
    return any("billboard-hook" in h.get("command", "") for h in group.get("hooks", []))


# ---------------------------------------------------------------- Claude Code

CLAUDE_EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                 "Notification", "Stop", "StopFailure", "SessionEnd"]
CLAUDE_TOOL_EVENTS = {"PreToolUse", "PostToolUse", "PostToolUseFailure"}


def claude(config_dir):
    path = os.path.join(config_dir, "settings.json")
    cfg = json.load(open(path)) if os.path.exists(path) else {}
    backup(path)
    hooks = cfg.setdefault("hooks", {})
    for ev in CLAUDE_EVENTS:
        groups = [g for g in hooks.get(ev, []) if not is_ours(g)]
        if not uninstall:
            g = {"hooks": [{"type": "command", "command": HOOK, "timeout": 5}]}
            groups.append({"matcher": "*", **g} if ev in CLAUDE_TOOL_EVENTS else g)
        if groups:
            hooks[ev] = groups
        else:
            hooks.pop(ev, None)
    write_atomic(path, json.dumps(cfg, indent=2) + "\n")
    print(("removed from " if uninstall else "installed in ") + path)


# ---------------------------------------------------------------- Codex CLI

# (event, matcher or None). SessionEnd is left out on purpose: Billboard drops a row when the codex
# process exits anyway, and Codex clamps that event's timeout, which changes its trust hash.
CODEX_EVENTS = [("SessionStart", None), ("UserPromptSubmit", None), ("PreToolUse", "*"),
                ("PermissionRequest", "*"), ("PostToolUse", "*"), ("Stop", None)]
BEGIN, END = "# >>> billboard hook trust (managed by install-hooks.py)", "# <<< billboard hook trust"


def snake(name):
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def codex_hash(event, matcher, command):
    """Codex's trusted_hash: sha256 of key-sorted compact JSON of the normalized hook identity
    (codex-rs hooks/src/engine/discovery.rs + config/src/fingerprint.rs). Checked against hashes Codex 0.159 saved."""
    ident = {"event_name": snake(event),
             "hooks": [{"async": False, "command": command, "timeout": 600, "type": "command"}]}
    if matcher is not None:
        ident["matcher"] = matcher
    blob = json.dumps(ident, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return "sha256:" + hashlib.sha256(blob.encode()).hexdigest()


def codex(home):
    default = os.path.expanduser("~/.codex")
    # Codex keys trust by the hooks.json path; it resolves a symlinked custom CODEX_HOME, not the default one.
    home = home if os.path.abspath(home) == default else os.path.realpath(home)
    hooks_path = os.path.join(home, "hooks.json")
    toml_path = os.path.join(home, "config.toml")
    command = f"{HOOK} codex"

    data = json.load(open(hooks_path)) if os.path.exists(hooks_path) else {"hooks": {}}
    backup(hooks_path)
    hooks = data.setdefault("hooks", {})
    trust = {}
    shifted = False
    for ev, matcher in CODEX_EVENTS:
        groups = hooks.get(ev, [])
        mine = [i for i, g in enumerate(groups) if is_ours(g)]
        current = (len(mine) == 1 and groups[mine[0]].get("hooks", [{}])[0].get("command") == command
                   and groups[mine[0]].get("matcher") == matcher)
        if uninstall or not current:
            if mine and mine[-1] != len(groups) - 1:
                shifted = True   # removing ours moves later groups, whose trust records then point elsewhere
            groups = [g for g in groups if not is_ours(g)]
            if not uninstall:
                g = {"hooks": [{"type": "command", "command": command}]}
                groups.append({"matcher": matcher, **g} if matcher is not None else g)
        if not uninstall:
            idx = next(i for i, g in enumerate(groups) if is_ours(g))
            trust[f"{hooks_path}:{snake(ev)}:{idx}:0"] = codex_hash(ev, matcher, command)
        if groups:
            hooks[ev] = groups
        else:
            hooks.pop(ev, None)
    write_atomic(hooks_path, json.dumps(data, indent=2) + "\n")

    # trust records in config.toml: drop our old block, update any stale record for the same key in place,
    # and append the rest in a fresh block
    text = open(toml_path).read() if os.path.exists(toml_path) else ""
    backup(toml_path)
    text = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n?", "", text, flags=re.S)
    block = []
    for key, value in trust.items():
        header = f'[hooks.state."{key}"]'
        if header in text:
            pattern = re.escape(header) + r'(\n(?:(?!\[).*\n)*?)trusted_hash\s*=\s*"[^"]*"'
            new, n = re.subn(pattern, lambda m: header + m.group(1) + f'trusted_hash = "{value}"', text, count=1)
            if n:
                text = new
                continue
        block += [header, f'trusted_hash = "{value}"', ""]
    if block:
        text = text.rstrip("\n") + "\n\n" + BEGIN + "\n" + "\n".join(block) + END + "\n"
    write_atomic(toml_path, text)
    print(("removed from " if uninstall else "installed in ") + hooks_path + " (+ trust in config.toml)")
    if shifted:
        print("  note: hooks added after Billboard's moved up one slot; Codex may ask you to re-trust them in /hooks")


# ---------------------------------------------------------------- main

if "--no-claude" not in args:
    dirs = [os.path.expanduser(d) for d in ("~/.claude", "~/.claude-sidekick")]
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        dirs.append(os.path.expanduser(os.environ["CLAUDE_CONFIG_DIR"]))
    for d in dict.fromkeys(dirs):
        if os.path.isdir(d):
            claude(d)

if "--no-codex" not in args:
    homes = [os.path.expanduser(args[i + 1]) for i, a in enumerate(args) if a == "--codex-home" and i + 1 < len(args)]
    if not homes:
        homes = [os.path.expanduser(os.environ.get("CODEX_HOME") or "~/.codex")]
    for h in dict.fromkeys(homes):
        if os.path.isdir(h):
            codex(h)
        elif "--codex-home" in args:
            print(f"skipped {h}: not a directory")
