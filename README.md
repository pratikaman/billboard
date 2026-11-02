# Billboard

A little board that hangs under your Mac's menu bar and shows what every **Claude Code** session is doing, live.

![Billboard themes: Flipboard, LED Sign, Letterboard, E-Ink](docs/themes.png)

Each running `claude` session gets a row:

| Column  | What it shows |
|---------|---------------|
| TIME    | When the current state began (turn started / finished) |
| SESSION | The project folder, or the session's title when the folder is generic (e.g. `~/Downloads`) |
| NOW     | What it's doing right now: `Editing main.swift`, a command's description, `Thinking`… |
| STATUS  | **Working** (blue) · **Needs you** (yellow, permission prompt or question, animates) · **Your turn** (green, fades to Idle after 15 min) · **Error** (red) |

Rows disappear when the session's process exits. The board fades out while your mouse is over it, so you can click whatever is underneath.

## Themes

Pick one from the tram icon in the menu bar → **Theme**:

- **Flipboard**: a Vestaboard-style split-flap board; letters flip through the drum when they change.
- **LED Sign**: an amber dot-matrix destination sign; long text scrolls like a ticker, changes roll up dot by dot.
- **Letterboard**: white plastic letters on ribbed black felt in an oak frame; new letters drop into the grooves, and a session that needs you wiggles.
- **E-Ink**: a three-colour (black/white/red) e-paper sign; changed rows do the e-paper refresh flash with a fading ghost.

Everything is drawn in code (CoreGraphics), so it stays crisp at any size. The menu also has max rows, size, position (left/center/right), hide-when-empty, and an optional synthesized flap sound.

## Install

Requires macOS 14+, the Swift toolchain (Xcode or Command Line Tools), and Claude Code.

```sh
git clone https://github.com/pratikaman/billboard.git
cd billboard
./build.sh            # builds Billboard.app and bin/billboard-hook
./install-hooks.py    # adds the hook to ~/.claude (and ~/.claude-sidekick / $CLAUDE_CONFIG_DIR if present)
open Billboard.app
```

`install-hooks.py` backs up each `settings.json` first (`settings.json.bak-<time>-billboard`) and leaves your other hooks alone. Running sessions pick the hook up straight away; they appear on the board the next time they do something.

To remove it: `./install-hooks.py --uninstall`, then quit Billboard from its menu.

## How it works

- `bin/billboard-hook` is a tiny Foundation-only Swift binary (~10 ms per call). Claude Code runs it on `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse(Failure)`, `Notification`, `Stop(Failure)` and `SessionEnd`. It keeps one small JSON file per session in `/tmp/claude-billboard/` with the state, a one-line activity, the cwd, and the PID of the `claude` process.
- `Billboard.app` polls that folder twice a second. It also tails each session's transcript for the AI-generated session title and for `[Request interrupted by user]` (Esc has no hook event). Rows whose `claude` process is gone are removed.
- Nothing leaves your machine.

### Development

```sh
./build.sh
# render a theme without opening a window (QA):
Billboard.app/Contents/MacOS/Billboard --snapshot out.png --theme led --needs
Billboard.app/Contents/MacOS/Billboard --snapshot out.png --theme letter --at 0.3   # 0.3 s into a change
# drive the live board with fake sessions:
Billboard.app/Contents/MacOS/Billboard --demo
```

Sources: `Sources/hook` (the hook), `Sources/app` (`Sessions.swift` reads state, `Themes.swift` defines the theme protocol, one file per theme, `main.swift` for the panel, menu and preferences).
