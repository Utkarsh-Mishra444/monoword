# Monoword for Claude Code

Read Claude's replies one word at a time.

`/monoword:on` does two things for the rest of the session. Every prompt carries a note that
makes Claude write the way it would talk: the point first, short sentences, no markdown, no
symbols that only make sense on a page. And every finished reply plays one word at a time in a
strip directly above the prompt, in the terminal itself. `/monoword:off` ends it.

| Command | Does |
|---|---|
| `/monoword:on` | replies become plain spoken prose and play word by word above the prompt |
| `/monoword:on app` | the same prose, and each reply opens in the [Monoword](https://github.com/Utkarsh-Mishra444/monoword) app on your Mac instead |
| `/monoword:off` | back to normal formatting; nothing plays or opens |
| `/monoword:read` | play the previous reply again: above the prompt, or in the app in app mode; with the mode off, in the app if it is installed, else above the prompt |
| `/monoword:speed 600` | the strip's speed in words a minute, pauses included, 100 to 1500 (500 to start with); the app keeps its own setting |
| `/monoword:align left` | where the word sits in the strip: `left` (every word starts at the same column), `center` (to start with) or `right` (every word ends at the same column) |

## Terminal mode

While a reply plays, the strip shows the word in bold in the middle of the line, with the
controls on the left and where you are on the right:

```
1: pause  2: restart  3: stop                 sky                 word 37 of 212 · 0:21 left
```

The last word stays two seconds, then `done · 212 words · 0:25` (how long the reading took,
pauses left out) shows for a few seconds and the strip is empty again. A reply that finishes
while another is playing takes over. You can type your next prompt while a reply plays.

Controls, none of which goes through Claude:

- Type `1`, `2` or `3` alone into the empty prompt and wait a moment: pause or resume, restart,
  stop. The digit is taken by the strip, not left in the prompt.
- `/monoword-pause` (pause or resume), `/monoword-restart` and `/monoword-stop`. They run at once,
  even while Claude is working.
- ctrl+x tab puts the keyboard on the strip; ctrl+x ctrl+a, or the `[-]` at its right end, folds
  it away. Both are Claude Code's own.

`/monoword:read`, `/monoword:speed` and `/monoword:align` take no turn from Claude in terminal
mode either: the strip answers them itself, with a short note in a toast where there is something
to say, and Claude does not see them. A new alignment moves the word that is on screen at once;
at the left or the right the controls and the progress move to the other side, two cells in from
the edge:

```
  sky                                        word 37 of 212 · 0:21 left  1: pause  2: restart  3: stop
```

The size of the word is your terminal's font size (Cmd and plus in most terminals); a strip is
drawn in character cells and has no font size of its own.

**Speed.** 500 wpm means 500 words a minute with the pauses included. When the plugin finds
`monoword-schedule`, the small command line tool that ships inside Monoword.app from app version
1.1 (`Contents/MacOS/monoword-schedule`), the strip uses the app's own timing, the same code the
app runs: rarer and longer words a little longer, two tiny function words sharing a flash ("of
the"), a beat at sentence ends, an ease-in over the first words, markdown markers dropped. It
looks in `$MONOWORD_SCHEDULE`, then in `Monoword.app/Contents/MacOS/` under `~/Applications` and
`/Applications`.

The plugin runs the tool only when the file carries no macOS quarantine mark (an app unzipped from
a download carries one on every file inside it), so macOS never puts up a dialog about it. While
the tool is quarantined the strip paces the words itself and says so once per session. To use the
app's timing, clear the mark once:

```sh
xattr -dr com.apple.quarantine /Applications/Monoword.app
```

An app built from source carries no mark. Without the app, build the tool alone from a clone of
this repository and point the variable at it:

```sh
swift build -c release --product monoword-schedule
export MONOWORD_SCHEDULE="$PWD/.build/release/monoword-schedule"
```

Without the tool the strip paces the words itself, more simply than the app: every word alone,
a word that ends a sentence held 1.5 times as long as a plain word and one that ends in a comma,
semicolon or colon 1.25 times, all scaled so the reply still takes exactly words / wpm minutes.
No adaptive pacing, no pairs, no ease-in, and markdown markers stay in.

**Where it runs.** The strip is a Claude Code mod (`hooks/band.mjs`) and needs Claude Code
2.1.287 or later. Mods draw in a terminal session; per Claude Code's documentation they also draw
in the Code tab of the Claude desktop app (not tested with this plugin). They do not draw under
`claude -p` or the Agent SDK, in cloud sessions, or in WSL sessions of the desktop app, so nothing
plays there; use `/monoword:on app` instead.

## App mode

`/monoword:on app` opens every finished reply in the Monoword reader on your Mac, at the speed you
set there. You need [Monoword.app](https://github.com/Utkarsh-Mishra444/monoword/releases/latest)
installed and opened once, so macOS knows the `monoword://` link. App mode is what `/monoword:on`
did in version 1.0 of this plugin.

## Install

In a terminal:

```sh
claude plugin marketplace add Utkarsh-Mishra444/monoword
claude plugin install monoword@monoword
```

or inside Claude Code: `/plugin marketplace add Utkarsh-Mishra444/monoword`, then
`/plugin install monoword@monoword`. To try it for one session without installing, from a clone
of this repository: `claude --plugin-dir ./claude-plugin`.

The plugin's hooks also run in the Claude desktop app's Code sessions, which read the same
settings as the terminal. It does not run in claude.ai chat, where plugin hooks are ignored;
there, select the reply and double-tap the right ⌘ to read it in Monoword.

Uninstall: `claude plugin uninstall monoword@monoword`.

## How it works

- A `UserPromptSubmit` hook attaches [style.md](style.md) to every prompt while the mode is on,
  in both modes. That file is the whole instruction; edit it if you want replies shaped
  differently.
- A `Stop` hook takes the finished reply (Claude Code hands it to hooks as
  `last_assistant_message`) and saves it for `/monoword:read`. In app mode it then opens it with
  `open -g "monoword://read?file=…"`; in terminal mode it opens nothing. It never blocks Claude
  from stopping and adds nothing to the conversation.
- The mod, `hooks/band.mjs`, hooks the same Stop event inside Claude Code. In terminal mode it
  gets the timetable of the reply from `monoword-schedule` (or the simpler pacing above) and
  plays it: each word change is timed from the start of the reply, so late timers do not add up,
  and the strip is redrawn once per word. It reads the plugin's data folder and runs
  `monoword-schedule` and the plugin's own `speed.sh`; it makes no network requests and opens
  nothing. With `MONOWORD_DEBUG=1` in the environment it writes `last-play.json` to the data
  folder: when each word actually changed against when it was due.
- The mode is per session. State lives in the plugin's data folder under
  `~/.claude/plugins/data/` (`monoword-monoword/` when installed from this marketplace,
  `monoword-inline/` with `--plugin-dir`): `sessions/<id>` holds `tty`, `app` or `off` (written
  only by `scripts/mode.sh`; an `on` left by version 1.0 counts as `app`), `replies/<id>.txt`
  holds the last finished reply of that session, and `settings.json` holds the strip's speed and
  alignment.
  Nothing leaves your Mac; Monoword itself has no network access.
- The scripts are bash and use `jq` when present, else `python3` (macOS 15 and later ship both;
  on macOS 14, `python3` comes with the Xcode Command Line Tools).

Tests: `node --test claude-plugin/tests/player.test.mjs` (the strip's layout, text and fallback
pacing) and `claude plugin test claude-plugin` (its hooks, against Claude Code's own test kit).
