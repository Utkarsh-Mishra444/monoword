// The pure parts of the terminal player: reading a schedule, the fallback pacing, the band's
// layout and its text. Nothing here touches Claude Code, so `node --test` runs it as it is
// (claude-plugin/tests/player.test.mjs); band.mjs, the hooks module, does the rest.

export const WPM_MIN = 100
export const WPM_MAX = 1500
export const WPM_DEFAULT = 500

/** The speed from the plugin's settings.json text: a whole number from 100 to 1500, else 500. */
export function wpmFromSettings(text) {
  try {
    const wpm = JSON.parse(text)?.wpm
    if (Number.isInteger(wpm) && wpm >= WPM_MIN && wpm <= WPM_MAX) return wpm
  } catch {}
  return WPM_DEFAULT
}

/** A session file's word as a mode: "tty", "app" or "off". Plugin 1.0.0 wrote "on", which opened the app. */
export function modeFromFile(text) {
  const word = String(text ?? '').trim()
  if (word === 'tty') return 'tty'
  if (word === 'app' || word === 'on') return 'app'
  return 'off'
}

/** Claude Code's data folder name for a plugin id: every character but a letter, digit, _ or - becomes -. */
export function dataIdOf(pluginId) {
  return pluginId.replace(/[^A-Za-z0-9_-]/g, '-')
}

/**
 * Where the plugin's data folder can be, best guess first. An installed copy runs from
 * <plugins>/cache/<marketplace>/<plugin>/<version>, which names its id exactly. A copy loaded in
 * place (--plugin-dir, or a marketplace added from a folder) does not say how it was loaded, so
 * both ids are tried: <name>@inline and <name>@<name> (this repository's marketplace is named
 * after the plugin).
 */
export function dataDirCandidates({ root, name, home, configDir, cacheDir }) {
  const out = []
  const installed = /^(.*)\/cache\/([^/]+)\/([^/]+)\/[^/]+\/?$/.exec(root ?? '')
  if (installed) out.push(`${installed[1]}/data/${dataIdOf(`${installed[3]}@${installed[2]}`)}`)
  const plugins = cacheDir || `${configDir || `${home}/.claude`}/plugins`
  out.push(`${plugins}/data/${dataIdOf(`${name}@inline`)}`, `${plugins}/data/${dataIdOf(`${name}@${name}`)}`)
  return [...new Set(out)]
}

/**
 * Reads monoword-schedule's output: one flash a line, `shown<TAB>seconds<TAB>words`, comment
 * lines starting with #. Returns null unless every line parses and there is at least one flash.
 */
export function parseSchedule(stdout) {
  const flashes = []
  for (const line of String(stdout).split('\n')) {
    if (line === '' || line.startsWith('#')) continue
    const [text, secondsText, wordsText] = line.split('\t')
    const seconds = Number(secondsText)
    if (!text || !Number.isFinite(seconds) || seconds <= 0) return null
    const words = wordsText === undefined ? 1 : Number(wordsText)
    if (!Number.isInteger(words) || words < 0) return null
    flashes.push({ text, seconds, words })
  }
  if (flashes.length === 0) return null
  return finish(flashes, 'app')
}

/**
 * The fallback when monoword-schedule is not installed: simpler than the app's pacing. Every word
 * alone, held base x factor, the factor 1.5 for a word ending a sentence (. ! ?) and 1.25 for one
 * ending in , ; or :, else 1; base chosen so the whole text takes exactly words / wpm minutes.
 * No grouping, no adaptive pacing, no ease-in, no minimum flash.
 */
export function fallbackSchedule(text, wpm) {
  const words = String(text).split(/\s+/).filter((w) => /[\p{L}\p{N}]/u.test(w))
  const closers = `["'”’)\\]]*$`
  const sentenceEnd = new RegExp(`[.!?…]${closers}`, 'u')
  const clauseEnd = new RegExp(`[,;:]${closers}`, 'u')
  const factors = words.map((w) => (sentenceEnd.test(w) ? 1.5 : clauseEnd.test(w) ? 1.25 : 1))
  const total = (words.length * 60) / wpm
  const base = total / factors.reduce((a, b) => a + b, 0)
  return finish(words.map((w, i) => ({ text: w, seconds: base * factors[i], words: 1 })), 'fallback')
}

function finish(flashes, source) {
  // ends[i]: seconds from the start until flash i is replaced; starts[i]: until it shows.
  const ends = []
  const before = []
  let t = 0
  let w = 0
  for (const f of flashes) {
    before.push(w)
    w += f.words
    t += f.seconds
    ends.push(t)
  }
  return { flashes, ends, wordsBefore: before, words: w, total: t, source }
}

/** The number of the word on screen, from 1: a pair shows its first word, a later piece of a split word its word. */
export function wordNumber(schedule, index) {
  const f = schedule.flashes[index]
  return Math.max(1, schedule.wordsBefore[index] + (f.words > 0 ? 1 : 0))
}

/** m:ss, rounded up for time left and to the nearest second otherwise. */
export function clock(seconds, { up = false } = {}) {
  const s = Math.max(0, up ? Math.ceil(seconds - 1e-9) : Math.round(seconds))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

/**
 * "word 37 of 212 · 0:21 left": the time left is the schedule's, from the start of this flash
 * (0 once the last flash has had its time).
 */
export function progressText(schedule, index, { paused = false, finished = false } = {}) {
  const left = finished ? 0 : schedule.total - (index > 0 ? schedule.ends[index - 1] : 0)
  const text = `word ${wordNumber(schedule, index)} of ${schedule.words} · ${clock(left, { up: true })} left`
  return paused ? `paused · ${text}` : text
}

/** "done · 212 words · 0:25", the time being how long the reading took, pauses left out. */
export function doneText(words, seconds) {
  return `done · ${words} ${words === 1 ? 'word' : 'words'} · ${clock(seconds)}`
}

/** Terminal cells a string takes: 2 for wide and emoji characters, 0 for combining marks. */
export function cellWidth(text) {
  let n = 0
  for (const ch of String(text)) {
    const c = ch.codePointAt(0)
    if (c < 32 || (c >= 0x7f && c < 0xa0)) continue
    if (/\p{Mn}|\p{Me}|​|‌|‍|️/u.test(ch)) continue
    n += isWide(c) ? 2 : 1
  }
  return n
}

function isWide(c) {
  return (
    (c >= 0x1100 && c <= 0x115f) || (c >= 0x2e80 && c <= 0x303e) || (c >= 0x3041 && c <= 0x33ff) ||
    (c >= 0x3400 && c <= 0x4dbf) || (c >= 0x4e00 && c <= 0x9fff) || (c >= 0xa000 && c <= 0xa4cf) ||
    (c >= 0xac00 && c <= 0xd7a3) || (c >= 0xf900 && c <= 0xfaff) || (c >= 0xfe30 && c <= 0xfe4f) ||
    (c >= 0xff00 && c <= 0xff60) || (c >= 0xffe0 && c <= 0xffe6) || (c >= 0x1f300 && c <= 0x1f64f) ||
    (c >= 0x1f900 && c <= 0x1f9ff) || (c >= 0x1f680 && c <= 0x1f6ff) || (c >= 0x20000 && c <= 0x3fffd)
  )
}

/** Cuts text to at most `cells` cells, ending in an ellipsis when it had to cut. */
export function fitCells(text, cells) {
  if (cellWidth(text) <= cells) return text
  if (cells <= 0) return ''
  let out = ''
  for (const ch of String(text)) {
    if (cellWidth(out + ch) > cells - 1) break
    out += ch
  }
  return out + '…'
}

/**
 * One row of the band, `width` cells: the word centred on the whole width, the controls at the
 * left and the progress at the right, each dropped (controls first) when it would crowd the word.
 * `controls` is the cells the controls take. Returns the cells of padding around the word.
 */
export function layoutRow({ width, word, controls = 0, right = '' }) {
  const shown = fitCells(word, Math.max(1, width))
  const w = cellWidth(shown)
  const start = Math.max(0, Math.floor((width - w) / 2))
  let rightText = right
  let r = cellWidth(rightText)
  let c = controls
  if (start + w + 1 + r > width) { rightText = ''; r = 0 }
  if (c > 0 && c + 1 > start) c = 0
  return {
    word: shown,
    controls: c > 0,
    beforeWord: start - c,
    afterWord: Math.max(0, width - start - w - r),
    right: rightText,
  }
}
