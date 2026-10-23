// Monoword's terminal player, a Claude Code mod: while /monoword:on is on (terminal mode), each
// finished reply plays one word at a time in the band directly above the prompt.
//
// The mode, the speed and the saved reply live in the plugin's data folder, written by the
// plugin's scripts (mode.sh is the only writer of sessions/<id>). This module reads them; the only
// file it writes is last-play.json there, and only with MONOWORD_DEBUG=1. It makes no network
// requests and opens nothing; the only programs it runs are monoword-schedule, xattr (to see
// whether that tool is quarantined) and the plugin's own speed.sh and align.sh.
//
// Timing: monoword-schedule (the app's own timing code, from the Monoword app or
// $MONOWORD_SCHEDULE) when it is there, else the simpler fallback in player.mjs. Each word change
// is armed for its absolute time from the start (start + the holds before it), so timer lateness
// does not add up, and the band is redrawn once per word.

import {
  alignFromSettings, bandRow, dataDirCandidates, doneText, fallbackSchedule, layoutRow,
  modeFromFile, parseSchedule, progressText, wpmFromSettings, cellWidth,
} from './player.mjs'

const HOLD_LAST_MS = 2000
const SHOW_DONE_MS = 4000
const TOOL = 'monoword-schedule'

// The playback on screen, or null. Module state on purpose: a reload of the module drops its
// timers, and the band should then go empty rather than show a word that never changes.
let playing = null
let generation = 0
const dataDirs = new Map()      // session id -> the data folder its session file is in

export function register(on) {
  // Controls that never go through the model, and run even while Claude is working. A name some
  // other plugin already took is skipped; the strip's own buttons (1, 2, 3) still work then.
  on('session.start', async ($, e, next) => {
    try {
      await $.command.register({ name: 'monoword-pause', description: 'Monoword: pause or resume the reply playing above the prompt', immediate: true })
    } catch {}
    try {
      await $.command.register({ name: 'monoword-restart', description: 'Monoword: play the reply above the prompt again from its first word', immediate: true })
    } catch {}
    try {
      await $.command.register({ name: 'monoword-stop', description: 'Monoword: stop the reply playing above the prompt and clear the strip', immediate: true })
    } catch {}
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    stop($)
    return next(e)
  })

  // A reply finished: in terminal mode, play it. Runs before the plugin's own Stop script, which
  // saves the reply and, in app mode only, opens it in the app.
  on('classic.Stop', async ($, e, next) => {
    try {
      await replyFinished($, e)
    } catch {
      // Never in the way of the turn ending.
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  // /monoword:read in terminal mode (or with the mode off and no app installed) plays the saved
  // reply here, with no model turn; in app mode the command's script opens it in the app.
  on('command.run', { command: 'monoword:read' }, async ($, e, next) => {
    const sid = await $.session.id()
    const dir = await findDataDir($, sid)
    const mode = dir ? await readMode($, dir, sid) : 'off'
    if (mode === 'app' || (mode === 'off' && (await appInstalled($)))) return next(e)
    // Answered with {} and a toast, not a transcript row, so Claude does not read about it.
    const text = dir ? await readText($, `${dir}/replies/${sid}.txt`) : undefined
    if (!text || !text.trim()) {
      $.ui.toast('There is no saved reply yet. Ask something first, then run /monoword:read.')
      return {}
    }
    const settings = dir ? await readText($, `${dir}/settings.json`) : ''
    $.clock.after(0, () => {
      return start($, text, wpmFromSettings(settings), dir, alignFromSettings(settings))
    })
    return {}
  }).catch(($, e, next) => next(e))

  // /monoword:speed and /monoword:align: once this session's data folder is known, the mod runs
  // the command's own script and shows its answer in a toast, so the change takes no model turn
  // and Claude does not read about it; else the command runs as written. A new alignment moves
  // the word that is on screen at once.
  on('command.run', { command: 'monoword:speed' }, async ($, e, next) => {
    const dir = await findDataDir($, await $.session.id())
    if (!dir) return next(e)
    const run = await $.process.run(['bash', `${$.plugin.root}/scripts/speed.sh`, e.args ?? '', dir], { timeoutMs: 10000 })
    if (run.exitCode !== 0 || !run.stdout.trim()) return next(e)
    $.ui.toast(run.stdout.trim(), { timeoutMs: 6000 })
    return {}
  }).catch(($, e, next) => next(e))

  on('command.run', { command: 'monoword:align' }, async ($, e, next) => {
    const dir = await findDataDir($, await $.session.id())
    if (!dir) return next(e)
    const run = await $.process.run(['bash', `${$.plugin.root}/scripts/align.sh`, e.args ?? '', dir], { timeoutMs: 10000 })
    if (run.exitCode !== 0 || !run.stdout.trim()) return next(e)
    if (playing) {
      playing.align = alignFromSettings(await readText($, `${dir}/settings.json`))
      $.ui.invalidate('ui.render')
    }
    $.ui.toast(run.stdout.trim(), { timeoutMs: 6000 })
    return {}
  }).catch(($, e, next) => next(e))

  on('command.run', { command: 'monoword-pause' }, async ($) => {
    await togglePause($)
    return {}
  })
  on('command.run', { command: 'monoword-restart' }, async ($) => {
    await restart($)
    return {}
  })
  on('command.run', { command: 'monoword-stop' }, async ($) => {
    stop($)
    return {}
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const p = playing
    if (!p || e.props.hasSurvey) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    const width = Math.max(1, e.props.bodyColumns)

    if (p.phase === 'done') {
      const row = layoutRow({ width, word: doneText(p.schedule.words, p.readSeconds) })
      return Box({
        flexDirection: 'row',
        children: [Text({ wrap: 'truncate', dimColor: true, children: [' '.repeat(row.beforeWord) + row.word] })],
      })
    }

    const paused = p.phase === 'paused'
    const index = p.index
    const buttons = [
      ['1', paused ? 'play' : 'pause', () => togglePause($)],
      ['2', 'restart', () => restart($)],
      ['3', 'stop', () => stop($)],
    ]
    const gap = 2
    // The cells the controls take as drawn: "1: pause", two spaces, "2: restart", ...
    const controlCells = buttons.reduce((n, [k, label]) => n + cellWidth(`${k}: ${label}`), 0) + gap * (buttons.length - 1)
    const row = bandRow({
      width,
      align: p.align,
      word: p.schedule.flashes[index].text,
      controls: controlCells,
      right: progressText(p.schedule, index, { paused, finished: p.phase === 'holding' }),
    })
    const children = row.segments.map((segment) => {
      if (segment === 'controls') {
        return Box({
          flexDirection: 'row',
          columnGap: gap,
          children: buttons.map(([hotkey, label, onPress]) =>
            Button({ key: `monoword-${hotkey}`, label, hotkey, plain: true, dimColor: true, onPress })),
        })
      }
      if (segment === 'word') return Text({ wrap: 'truncate', bold: true, children: [row.word] })
      if (segment.text !== undefined) return Text({ wrap: 'truncate', dimColor: true, children: [segment.text] })
      return Text({ wrap: 'truncate', children: [' '.repeat(segment.pad)] })
    })
    return Box({ flexDirection: 'row', children })
  })
}

// ---------------------------------------------------------------------------------------------
// Reading the plugin's data folder

async function candidates($) {
  return dataDirCandidates({
    root: $.plugin.root,
    name: $.plugin.name,
    home: await $.env.get('HOME'),
    configDir: await $.env.get('CLAUDE_CONFIG_DIR'),
    cacheDir: await $.env.get('CLAUDE_CODE_PLUGIN_CACHE_DIR'),
  })
}

/**
 * The data folder this session's scripts write to: the first candidate holding its sessions/<id>
 * or replies/<id>.txt (session ids are unique, so only one does). Stops at the first hit, so a
 * copy loaded with --plugin-dir never looks into an installed copy's folder once it has found
 * its own.
 */
async function findDataDir($, sid) {
  if (dataDirs.has(sid)) return dataDirs.get(sid)
  for (const dir of await candidates($)) {
    for (const file of [`${dir}/sessions/${sid}`, `${dir}/replies/${sid}.txt`]) {
      if (await $.fs.exists(file)) {
        dataDirs.set(sid, dir)
        return dir
      }
    }
  }
  return undefined
}

async function readText($, path) {
  return $.fs.read(path).catch(() => undefined)
}

/** As the scripts read it (common.sh): sessions/<id>, else sessions/default, else off. */
async function readMode($, dir, sid) {
  const own = await readText($, `${dir}/sessions/${sid}`)
  if (own !== undefined) return modeFromFile(own)
  return modeFromFile(await readText($, `${dir}/sessions/default`))
}

async function appInstalled($) {
  const home = await $.env.get('HOME')
  if (await $.fs.exists(`${home}/Applications/Monoword.app`)) return true
  return $.fs.exists('/Applications/Monoword.app')
}

// ---------------------------------------------------------------------------------------------
// Playback

async function replyFinished($, e) {
  const text = e.last_assistant_message
  const sid = e.session_id
  if (typeof text !== 'string' || !text.trim() || typeof sid !== 'string') return
  const dir = await findDataDir($, sid)
  if (!dir || (await readMode($, dir, sid)) !== 'tty') return
  // After /monoword:read run by its script (the mod was not answering it), this reply is only the
  // confirmation; the Stop script skips saving it, and it is not played either.
  if ((await readText($, `${dir}/sessions/${sid}.skip`))?.trim() === '1') return
  const settings = await readText($, `${dir}/settings.json`)
  $.clock.after(0, () => {
    return start($, text, wpmFromSettings(settings), dir, alignFromSettings(settings))
  })
}

/**
 * monoword-schedule: $MONOWORD_SCHEDULE, else inside the Monoword app (shipped there from app
 * version 1.1), else none. A copy macOS still holds under quarantine (an app unzipped from a
 * download) is never run, so no dialog about it can come up: the strip says so once per session
 * and paces the words itself.
 */
async function findTool($) {
  const home = await $.env.get('HOME')
  const env = await $.env.get('MONOWORD_SCHEDULE')
  const paths = [env, `${home}/Applications/Monoword.app/Contents/MacOS/${TOOL}`, `/Applications/Monoword.app/Contents/MacOS/${TOOL}`]
  for (const path of paths) {
    if (!path || !(await $.fs.exists(path))) continue
    if (await quarantined($, path)) {
      noteQuarantine($, path)
      continue
    }
    return path
  }
  return undefined
}

/** True when the file carries macOS's quarantine mark (the com.apple.quarantine attribute). */
async function quarantined($, path) {
  try {
    const run = await $.process.run(['xattr', '-p', 'com.apple.quarantine', path], { timeoutMs: 3000 })
    return run.exitCode === 0
  } catch {
    return false
  }
}

let quarantineNoted = false     // module state: the note shows once per session
function noteQuarantine($, path) {
  if (quarantineNoted) return
  quarantineNoted = true
  const app = path.replace(/\/Contents\/MacOS\/[^/]+$/, '')
  $.ui.toast(`Monoword's timing tool is still under macOS quarantine, so the strip paces the words itself. To use the app's timing, run once: xattr -dr com.apple.quarantine "${app}"`, { timeoutMs: 12000 })
}

async function buildSchedule($, text, wpm) {
  const tool = await findTool($)
  if (tool) {
    try {
      const run = await $.process.run([tool, '-', String(wpm), '--chunk', 'auto'], { stdin: text, timeoutMs: 15000 })
      const schedule = run.exitCode === 0 ? parseSchedule(run.stdout) : null
      if (schedule) return schedule
    } catch {
      // Could not start, or too slow: the fallback below.
    }
  }
  return fallbackSchedule(text, wpm)
}

async function start($, text, wpm, dir, align = 'center') {
  const gen = ++generation
  const schedule = await buildSchedule($, text, wpm)
  if (gen !== generation) return          // a newer reply, or a stop, came in meanwhile
  cancel(playing)
  if (schedule.flashes.length === 0) {
    playing = null
    $.ui.invalidate('ui.render')
    return
  }
  const now = await $.clock.now()
  if (gen !== generation) return
  playing = { gen, schedule, wpm, dir, align, index: 0, t0: now, phase: 'playing', timer: null, elapsedAtPause: 0, changes: [now], pauses: 0 }
  $.ui.invalidate('ui.render')
  await arm($, playing)
}

/** Sets the timer for the end of the flash on screen, at its absolute time from the start. */
async function arm($, p) {
  if (p !== playing || p.phase !== 'playing') return
  const now = await $.clock.now()
  if (p !== playing || p.phase !== 'playing') return
  // Whole milliseconds: the target stays absolute, so the rounding never adds up.
  const due = p.t0 + p.schedule.ends[p.index] * 1000
  p.timer = $.clock.after(Math.max(0, Math.round(due - now)), () => {
    return step($, p)
  })
}

async function step($, p) {
  if (p !== playing || p.phase !== 'playing') return
  const now = await $.clock.now()
  if (p !== playing || p.phase !== 'playing') return
  p.changes.push(now)
  if (p.index + 1 < p.schedule.flashes.length) {
    p.index += 1
    $.ui.invalidate('ui.render')
    await arm($, p)
    return
  }
  // The last word stays two seconds, then the summary a few more, then the band is empty again.
  p.phase = 'holding'
  p.readSeconds = (now - p.t0) / 1000
  $.ui.invalidate('ui.render')
  p.timer = $.clock.after(HOLD_LAST_MS, () => {
    if (p !== playing) return
    p.phase = 'done'
    $.ui.invalidate('ui.render')
    p.timer = $.clock.after(SHOW_DONE_MS, () => {
      if (p !== playing) return
      playing = null
      $.ui.invalidate('ui.render')
    })
  })
  await writeDebug($, p)
}

async function togglePause($) {
  const p = playing
  if (!p) return
  const now = await $.clock.now()
  if (p !== playing) return
  if (p.phase === 'playing') {
    cancel(p)
    p.phase = 'paused'
    p.elapsedAtPause = now - p.t0
    p.pauses += 1
  } else if (p.phase === 'paused') {
    p.phase = 'playing'
    p.t0 = now - p.elapsedAtPause       // the time paused is left out of the schedule and of the total
    await arm($, p)
  } else {
    return
  }
  $.ui.invalidate('ui.render')
}

async function restart($) {
  const p = playing
  if (!p) return
  const now = await $.clock.now()
  if (p !== playing) return
  cancel(p)
  p.index = 0
  p.t0 = now
  p.phase = 'playing'
  p.changes = [now]
  $.ui.invalidate('ui.render')
  await arm($, p)
}

function stop($) {
  generation += 1
  cancel(playing)
  playing = null
  $.ui.invalidate('ui.render')
}

function cancel(p) {
  if (p?.timer) p.timer.cancel()
  if (p) p.timer = null
}

/** With MONOWORD_DEBUG=1: when and how each word changed, against the schedule, in <data>/last-play.json. */
async function writeDebug($, p) {
  if ((await $.env.get('MONOWORD_DEBUG')) !== '1' || !p.dir) return
  const t0 = p.changes[0]
  const report = {
    source: p.schedule.source,
    wpm: p.wpm,
    words: p.schedule.words,
    flashes: p.schedule.flashes.length,
    scheduleSeconds: p.schedule.total,
    readSeconds: p.readSeconds,
    pauses: p.pauses,
    // Per word change: ms after the first word showed, and the scheduled ms (only without pauses).
    changes: p.changes.map((t, i) => ({ i, actualMs: t - t0, dueMs: i === 0 ? 0 : p.schedule.ends[i - 1] * 1000, shown: p.schedule.flashes[i]?.text ?? null })),
  }
  await $.fs.write(`${p.dir}/last-play.json`, JSON.stringify(report, null, 1)).catch(() => {})
}
