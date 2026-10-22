# Monoword for Claude Code

Read Claude's replies one word at a time.

`/monoword:on` does two things for the rest of the session. Every prompt carries a note that
makes Claude write the way it would talk: the point first, short sentences, no markdown, no
symbols that only make sense on a page. And every finished reply opens in the
[Monoword](https://github.com/Utkarsh-Mishra444/monoword) reader on your Mac, one word at a
time, at the speed you set there. `/monoword:off` ends it.

| Command | Does |
|---|---|
| `/monoword:on` | replies become plain spoken prose and each one opens in Monoword |
| `/monoword:off` | back to normal formatting; nothing opens |
| `/monoword:read` | open the previous reply in Monoword, mode on or off |

## Install

You need [Monoword.app](https://github.com/Utkarsh-Mishra444/monoword/releases/latest) installed
and opened once, so macOS knows the `monoword://` link. Then, in a terminal:

```sh
claude plugin marketplace add Utkarsh-Mishra444/monoword
claude plugin install monoword@monoword
```

or inside Claude Code: `/plugin marketplace add Utkarsh-Mishra444/monoword`, then
`/plugin install monoword@monoword`. To try it for one session without installing, from a clone
of this repository: `claude --plugin-dir ./claude-plugin`.

The plugin also runs in the Claude desktop app's Code sessions, which read the same settings as
the terminal. It does not run in claude.ai chat, where plugin hooks are ignored; there, select
the reply and double-tap the right ⌘ to read it in Monoword.

Uninstall: `claude plugin uninstall monoword@monoword`.

## How it works

- A `UserPromptSubmit` hook attaches [style.md](style.md) to every prompt while the mode is on.
  That file is the whole instruction; edit it if you want replies shaped differently.
- A `Stop` hook takes the finished reply (Claude Code hands it to hooks as
  `last_assistant_message`), saves it, and opens it with
  `open -g "monoword://read?file=…"`. The hook never blocks Claude from stopping, and it adds
  nothing to the conversation.
- The mode is per session. State lives in the plugin's data folder,
  `~/.claude/plugins/data/monoword/`: `sessions/<id>` holds `on` or `off`, and
  `replies/<id>.txt` holds the last finished reply of that session so `/monoword:read` can
  reopen it. Nothing leaves your Mac; Monoword itself has no network access.
- The scripts are bash and use `jq` when present, else `python3` (macOS 15 and later ship both;
  on macOS 14, `python3` comes with the Xcode Command Line Tools).

Monoword drops markdown markers on its own, so `/monoword:read` works on an ordinary formatted
reply too; the mode just makes the reply worth reading that way.
