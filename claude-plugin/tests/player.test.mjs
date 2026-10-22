// Unit tests of the terminal player's pure parts: node --test claude-plugin/tests
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  cellWidth, clock, dataDirCandidates, doneText, fallbackSchedule, fitCells, layoutRow,
  modeFromFile, parseSchedule, progressText, wordNumber, wpmFromSettings,
} from '../hooks/player.mjs'

// The first lines of `monoword-schedule reply.txt 500` (the demo reply), then a pair, a split word
// and the comment line.
const TOOL_OUTPUT = [
  'The\t0.141531\t1',
  'sky\t0.164469\t1',
  'is\t0.122948\t1',
  'of the\t0.190000\t2',
  'photosynth-\t0.200000\t1',
  'esis.\t0.400000\t0',
  '# words 6\tflashes 6\ttotal 1.218948\twpm 500\treal 295.33\tchunk auto\tframes exact',
  '',
].join('\n')

test('parseSchedule reads the tool output', () => {
  const s = parseSchedule(TOOL_OUTPUT)
  assert.equal(s.source, 'app')
  assert.equal(s.flashes.length, 6)
  assert.deepEqual(s.flashes[3], { text: 'of the', seconds: 0.19, words: 2 })
  assert.equal(s.words, 6)
  assert.ok(Math.abs(s.total - 1.218948) < 1e-9)
  assert.ok(Math.abs(s.ends[1] - (0.141531 + 0.164469)) < 1e-12)
  assert.deepEqual(s.wordsBefore, [0, 1, 2, 3, 5, 6])
})

test('parseSchedule refuses what it cannot trust', () => {
  assert.equal(parseSchedule(''), null)
  assert.equal(parseSchedule('# words 0\n'), null)
  assert.equal(parseSchedule('word\tsoon\t1\n'), null)
  assert.equal(parseSchedule('word\t-1\t1\n'), null)
  assert.equal(parseSchedule('word\t0.1\tmany\n'), null)
  assert.equal(parseSchedule('\t0.1\t1\n'), null)
  // Two columns, as the brief's format has it: one word a flash.
  assert.equal(parseSchedule('one\t0.2\ntwo\t0.3\n').words, 2)
})

test('word numbers: a pair shows its first word, a later piece its word', () => {
  const s = parseSchedule(TOOL_OUTPUT)
  assert.deepEqual(s.flashes.map((_, i) => wordNumber(s, i)), [1, 2, 3, 4, 6, 6])
})

test('fallback pacing totals words / wpm exactly, pauses included', () => {
  const text = 'Hello there, world. This is a test; it ends here! Another line\n\nwith a paragraph: and more words \u2014 and a dash.'
  for (const wpm of [100, 333, 500, 1000, 1500]) {
    const s = fallbackSchedule(text, wpm)
    assert.equal(s.source, 'fallback')
    assert.ok(Math.abs(s.total - (s.words * 60) / wpm) < 1e-9, `${wpm}: ${s.total}`)
    assert.ok(Math.abs(s.flashes.reduce((t, f) => t + f.seconds, 0) - s.total) < 1e-12)
  }
})

test('fallback: sentence ends get half a base more, clause ends a quarter, lone punctuation is dropped', () => {
  const s = fallbackSchedule('One two, three. Four \u2014 "five!" six: seven', 600)
  assert.deepEqual(s.flashes.map((f) => f.text), ['One', 'two,', 'three.', 'Four', '"five!"', 'six:', 'seven'])
  const base = s.flashes[0].seconds
  const ratio = s.flashes.map((f) => Math.round((f.seconds / base) * 1000) / 1000)
  assert.deepEqual(ratio, [1, 1.25, 1.5, 1, 1.5, 1.25, 1])
})

test('fallback on empty text has no flashes', () => {
  assert.equal(fallbackSchedule('  \n \u2014 * ', 500).flashes.length, 0)
})

test('progress and done text', () => {
  const s = parseSchedule(TOOL_OUTPUT)
  assert.equal(progressText(s, 0), 'word 1 of 6 · 0:02 left')
  assert.equal(progressText(s, 5, { paused: true }), 'paused · word 6 of 6 · 0:01 left')
  assert.equal(progressText(s, 5, { finished: true }), 'word 6 of 6 · 0:00 left')
  assert.equal(doneText(212, 25.4), 'done · 212 words · 0:25')
  assert.equal(doneText(1, 0.4), 'done · 1 word · 0:00')
  assert.equal(clock(61, { up: true }), '1:01')
  assert.equal(clock(60.2, { up: true }), '1:01')
  assert.equal(clock(59.5), '1:00')
})

test('cell widths: wide characters take two cells, combining marks none', () => {
  assert.equal(cellWidth('sky'), 3)
  assert.equal(cellWidth('空'), 2)
  assert.equal(cellWidth('\u{1F680}'), 2)
  assert.equal(cellWidth('é'), 1)
  assert.equal(fitCells('abcdefgh', 5), 'abcd…')
  assert.equal(fitCells('abc', 5), 'abc')
})

test('the word is centred on the whole width, controls and progress beside it', () => {
  for (const width of [155, 120, 75, 40]) {
    for (const word of ['a', 'sky', 'wavelength', 'photosynthesis']) {
      const right = 'word 37 of 212 · 0:21 left'
      const row = layoutRow({ width, word, controls: 27, right })
      const controls = row.controls ? 27 : 0
      const start = controls + row.beforeWord
      // Centred: the cells left of the word and right of it differ by at most one.
      const after = width - start - cellWidth(row.word)
      assert.ok(Math.abs(start - after) <= 1, `${width} ${word}: ${start} vs ${after}`)
      const used = start + cellWidth(row.word) + (row.right ? row.afterWord + cellWidth(row.right) : 0)
      assert.ok(used <= width, `${width} ${word}: ${used} cells`)
      if (row.right) assert.equal(used, width)
    }
  }
  // Narrow: the controls go first, then the progress.
  const narrow = layoutRow({ width: 40, word: 'wavelength', controls: 27, right: 'word 37 of 212 · 0:21 left' })
  assert.equal(narrow.controls, false)
  assert.equal(narrow.right, '')
  const wide = layoutRow({ width: 155, word: 'wavelength', controls: 27, right: 'word 37 of 212 · 0:21 left' })
  assert.equal(wide.controls, true)
  assert.notEqual(wide.right, '')
})

test('settings, modes and data folders', () => {
  assert.equal(wpmFromSettings('{"wpm": 700}'), 700)
  assert.equal(wpmFromSettings('{"wpm": 99}'), 500)
  assert.equal(wpmFromSettings('{"wpm": 600.5}'), 500)
  assert.equal(wpmFromSettings('not json'), 500)
  assert.equal(wpmFromSettings(undefined), 500)
  assert.equal(modeFromFile('tty'), 'tty')
  assert.equal(modeFromFile('app\n'), 'app')
  assert.equal(modeFromFile('on'), 'app')
  assert.equal(modeFromFile('off'), 'off')
  assert.equal(modeFromFile(undefined), 'off')
  assert.deepEqual(
    dataDirCandidates({ root: '/Users/u/.claude/plugins/cache/monoword/monoword/1.1.0', name: 'monoword', home: '/Users/u' }),
    ['/Users/u/.claude/plugins/data/monoword-monoword', '/Users/u/.claude/plugins/data/monoword-inline'],
  )
  assert.deepEqual(
    dataDirCandidates({ root: '/Users/u/SpeedRead/claude-plugin', name: 'monoword', home: '/Users/u' }),
    ['/Users/u/.claude/plugins/data/monoword-inline', '/Users/u/.claude/plugins/data/monoword-monoword'],
  )
  assert.deepEqual(
    dataDirCandidates({ root: '/x/plugin', name: 'monoword', home: '/Users/u', cacheDir: '/c' }),
    ['/c/data/monoword-inline', '/c/data/monoword-monoword'],
  )
})
