# Billboard

**Now boarding: every Claude Code and Codex session you forgot you started.**

You have seven terminal tabs open. One of them has been politely waiting forty minutes for you to click "Allow". Another finished an hour ago and has been staring into the void ever since. You don't know which. Nobody knows which.

Billboard is a tiny departures board that hangs from your Mac's menu bar and tells you, in big honest letters, what every Claude Code and Codex CLI session is doing. Yes, both. It doesn't take sides; it just reports who's slacking. Like an airport, but the flights are refactors and the delays are your fault.

![Billboard themes: Flipboard, LED Sign, Letterboard, E-Ink](docs/themes.png)

## Reading the board

| Column  | Translation |
|---------|-------------|
| TIME    | When this state began. Big number in the past + YOUR TURN = you've been ghosting your AI. |
| logo    | Which airline: the coral Claude starburst is Claude Code, the OpenAI knot is Codex. |
| SESSION | The project folder, or the session's title if the folder is useless (looking at you, `~/Downloads`). |
| NOW     | What it's doing: `Editing main.swift`, `Running the tests`, `Thinking` (same as you, but faster). |
| STATUS  | See below. |

| Status | Colour | Meaning |
|--------|--------|---------|
| **WORKING** | blue | On time. Doing your job for you. Don't interrupt. |
| **NEEDS YOU** | yellow, blinking/flapping/wiggling | Gate hold. It wants permission or has a question. It will wait forever. It's very polite. Don't test it. |
| **YOUR TURN** | green | Landed. Baggage on carousel 3. Go read what it did. |
| **ERROR** | red | Cancelled. Probably the API, probably not your fault. Probably. |
| **IDLE** | grey | Finished 15+ minutes ago and has stopped expecting anything from you. |

When a session ends, its row departs. When your mouse goes over the board, it fades away so you can click whatever was underneath. It's a board, not a hostage situation.

## Pick your terminal

Click the 🚊 tram in the menu bar → **Theme**:

- **Flipboard**: a Vestaboard-style split-flap board. Letters clatter through the drum when anything changes. Turn on Flap Sound if your coworkers deserve it.
- **LED Sign**: an amber dot-matrix bus sign. Long text scrolls like a ticker. Gives "last bus to Refactorville" energy.
- **Letterboard**: white plastic letters on black felt in an oak frame. Letters drop into the grooves a little crooked, like a café menu. NEEDS YOU makes the letters wiggle, which is the most passive-aggressive thing a letter can do.
- **E-Ink**: a calm black/white/red e-paper sign, like a meeting-room display. Changes do the e-paper flash and leave a ghost of the old text, because it's haunted by your unfinished tasks.

The same menu also has max rows, size, left/center/right position, hide-when-empty, and Flap Sound (off by default, for the sake of open-plan offices everywhere).

## Install with a prompt

You have an AI that can use a terminal. Make it install its own surveillance board. Paste this into Claude Code (or Codex, it's not proud):

```text
Install Billboard (https://github.com/pratikaman/billboard) on this Mac:

1. Clone the repo to ~/billboard and run ./build.sh there. It needs the Xcode Command Line Tools;
   if swiftc is missing, tell me to run `xcode-select --install` and stop.
2. Check whether I start Codex through a shell alias or function that sets CODEX_HOME (look in my
   ~/.zshrc / ~/.bashrc). If I do, remember that directory.
3. Run ./install-hooks.py in ~/billboard, adding `--codex-home <that dir>` if step 2 found one.
   It backs up every file it touches and ADDS Billboard's hook next to my existing hooks: Claude
   Code's settings.json (~/.claude, and $CLAUDE_CONFIG_DIR if I use one) and Codex's hooks.json
   (~/.codex or the --codex-home dir), plus the matching trust records in that Codex config.toml.
   Afterwards, check every file it touched still parses and that my other hooks are still there.
4. Run: open ~/billboard/Billboard.app
5. Tell me to look just under my menu bar.
```

Sessions that are already open check in the next time they do something. If a session never shows up, restart it so it reloads its hooks.

## Install like it's 2019

```sh
git clone https://github.com/pratikaman/billboard.git ~/billboard
cd ~/billboard
./build.sh            # builds Billboard.app and bin/billboard-hook
./install-hooks.py    # Claude Code: ~/.claude (+ $CLAUDE_CONFIG_DIR) · Codex: $CODEX_HOME or ~/.codex
open Billboard.app
```

Launch Codex through an alias with its own `CODEX_HOME` (say `alias codey='CODEX_HOME=~/.codex-codey codex'`)? Point the installer at it, or Billboard will be watching an empty gate:

```sh
./install-hooks.py --codex-home ~/.codex-codey      # repeat --codex-home for several; --no-claude / --no-codex to skip one
```

Needs macOS 14+, the Swift toolchain (Xcode or Command Line Tools), python3 (for the installer), and Claude Code and/or a Codex CLI with hooks (0.15x or newer). To start it at login, add `Billboard.app` under System Settings → General → Login Items.

## Uninstall

All flights cancelled. Paste into Claude Code:

```text
Run ~/billboard/install-hooks.py --uninstall (with the same --codex-home I installed with, if
any), quit Billboard from its tram menu-bar icon, and delete ~/billboard.
```

Or by hand: `./install-hooks.py --uninstall`, then 🚊 → **Quit Billboard**.

## How it works

- **The hook.** `bin/billboard-hook` is a tiny Swift binary (~10 ms, so your tools don't notice). Claude Code calls it on `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse(Failure)`, `Notification`, `Stop(Failure)` and `SessionEnd`. Codex calls `billboard-hook codex` on `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse` and `Stop`. Either way it writes one small JSON file per session to `/tmp/claude-billboard/` with the state, a one-line activity, the folder, and the PID of the `claude` / `codex` process. Codex mostly works through the shell, so the hook translates: `sed -n … Board.swift` shows as "Reading Board.swift", `rg foo` as "Searching foo", an `apply_patch` as "Editing Board.swift +2".
- **Codex trust.** Codex only runs hooks you've trusted. The installer writes trust records for Billboard's own hooks into your Codex `config.toml` (in a clearly marked block, using the same hash Codex computes), so there's no `/hooks` review step. If a future Codex changes its hash recipe, it'll just ask you once.
- **The app.** `Billboard.app` reads that folder twice a second. It also skims each session's transcript for interrupts, because pressing Esc has no hook (`[Request interrupted by user]` for Claude, `turn_aborted` for Codex), and picks up session titles (Claude's AI title, Codex's `session_index.jsonl` thread name). Rows whose process has died are removed.
- **Logos.** The Claude and OpenAI marks are vector paths from [Simple Icons](https://simpleicons.org); they're trademarks of Anthropic and OpenAI, used here only to say which tool a row belongs to.
- **Privacy.** Nothing leaves your Mac. The only thing tracking you is your own guilt about that yellow row.

## Known delays

- Right after you click "Allow", the row can stay on NEEDS YOU until that tool call finishes. Claude Code has no "permission granted" hook, so the board can't know.
- A theme might be judging you. That's a feature.

## Development

```sh
./build.sh
# render a theme to PNG without opening a window:
Billboard.app/Contents/MacOS/Billboard --snapshot out.png --theme led --needs
Billboard.app/Contents/MacOS/Billboard --snapshot out.png --theme letter --at 0.3   # 0.3 s into a change
# fake sessions on the live board:
Billboard.app/Contents/MacOS/Billboard --demo
```

`Sources/hook` is the hook. In `Sources/app`, `Sessions.swift` reads the state, `Themes.swift` defines the theme protocol, each theme has its own file, and `main.swift` holds the panel, menu and preferences.
