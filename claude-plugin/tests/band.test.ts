// The terminal player's hooks, run by `claude plugin test claude-plugin`: a finished reply in
// terminal mode plays word by word in the band, in no other mode; the controls; /monoword:read.
import { expect, mock, test } from 'claude-code/testing'

const HOME = '/home/reader'
const DATA = `${HOME}/.claude/plugins/data/monoword-inline`
const BAND = {
  plugin: 'monoword',
  component: 'AbovePrompt',
  surface: 'terminal',
  viewport: { columns: 100, rows: 30 },
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 95, scroll: { offset: 0, bodyRows: 9 }, view: {} },
} as const

const REPLY = 'One two, three. Four five.'
// Fallback pacing at 500 wpm: 5 words take 0.6 s; factors 1, 1.25, 1.5, 1, 1.5 on a base of 96 ms.
const HOLDS = [96, 120, 144, 96, 144]
let toasts: string[] = []

/** The plugin's data folder as the scripts leave it, the Monoword app not installed. */
function world(on: Parameters<Parameters<typeof test>[1]>[1], files: Record<string, string>, env: Record<string, string> = {}) {
  toasts = []
  const clock = mock.clock(on, { now: 1_000 })
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? HOME : env[e.name] }))
  on('fs.read', ($, e) => (e.path in files ? { value: files[e.path] } : { deny: 'ENOENT' }))
  on('fs.exists', ($, e) => ({ value: e.path in files }))
  on('session.id', () => ({ value: 'S1' }))
  on('classic.Stop', () => ({}))
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.render', () => ({ type: 'Text', props: {}, children: ['(empty band)'] }))
  return clock
}

async function shown(ui: { find: (q: object) => Promise<unknown> }, text: string | RegExp) {
  return ui.find({ type: 'Text', text })
}

test('terminal mode: a finished reply plays word by word, then the summary, then nothing', async ($, on) => {
  const clock = world(on, { [`${DATA}/sessions/S1`]: 'tty' })
  await $.classic.Stop({ session_id: 'S1', last_assistant_message: REPLY, stop_hook_active: false })
  await clock.settle()
  const ui = await $.ui.mount(BAND)
  expect(await shown(ui, 'One')).toBeDefined()
  expect(await shown(ui, /word 1 of 5 · 0:01 left/)).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'monoword-1' })).toBeDefined()
  const words = ['two,', 'three.', 'Four', 'five.']
  for (let i = 0; i < words.length; i++) {
    await clock.advance(HOLDS[i] - 1)
    expect(await shown(ui, i === 0 ? 'One' : words[i - 1])).toBeDefined()
    await clock.advance(1)
    expect(await shown(ui, words[i])).toBeDefined()
  }
  await clock.advance(HOLDS[4])          // the last word has had its time: it stays 2 s more
  expect(await shown(ui, 'five.')).toBeDefined()
  expect(await shown(ui, /0:00 left/)).toBeDefined()
  await clock.advance(2_000)
  expect(await shown(ui, /done · 5 words · 0:01/)).toBeDefined()
  await clock.advance(4_000)
  expect(await shown(ui, '(empty band)')).toBeDefined()
})

test('app mode and mode off: nothing plays in the band', async ($, on) => {
  const clock = world(on, { [`${DATA}/sessions/S1`]: 'app', [`${DATA}/sessions/S2`]: 'off' })
  await $.classic.Stop({ session_id: 'S1', last_assistant_message: REPLY, stop_hook_active: false })
  await $.classic.Stop({ session_id: 'S2', last_assistant_message: REPLY, stop_hook_active: false })
  await $.classic.Stop({ session_id: 'S3', last_assistant_message: REPLY, stop_hook_active: false })
  await clock.settle()
  const ui = await $.ui.mount(BAND)
  expect(await shown(ui, '(empty band)')).toBeDefined()
  expect(await shown(ui, 'One')).toBeUndefined()
})

test('pause holds the word, resume goes on from it, restart begins again', async ($, on) => {
  const clock = world(on, { [`${DATA}/sessions/S1`]: 'tty' })
  await $.classic.Stop({ session_id: 'S1', last_assistant_message: REPLY, stop_hook_active: false })
  await clock.settle()
  const ui = await $.ui.mount(BAND)
  await clock.advance(100)               // "two," since 96 ms
  await ui.press({ key: 'monoword-1' })  // the strip's "1: pause"
  await clock.advance(5_000)
  expect(await shown(ui, 'two,')).toBeDefined()
  expect(await shown(ui, /^paused · word 2 of 5/)).toBeDefined()
  await $.command.run({ command: 'monoword-pause', args: '' })   // resume, by the command this time
  await clock.advance(115)               // 96 + 120 = 216 ms from the start, 100 of them before the pause
  expect(await shown(ui, 'two,')).toBeDefined()
  await clock.advance(1)
  expect(await shown(ui, 'three.')).toBeDefined()
  await $.command.run({ command: 'monoword-restart', args: '' })
  expect(await shown(ui, 'One')).toBeDefined()
  await $.command.run({ command: 'monoword-stop', args: '' })
  expect(await shown(ui, '(empty band)')).toBeDefined()
})

test('a new reply mid-play takes over', async ($, on) => {
  const clock = world(on, { [`${DATA}/sessions/S1`]: 'tty' })
  await $.classic.Stop({ session_id: 'S1', last_assistant_message: REPLY, stop_hook_active: false })
  await clock.settle()
  const ui = await $.ui.mount(BAND)
  await clock.advance(250)
  expect(await shown(ui, 'three.')).toBeDefined()
  await $.classic.Stop({ session_id: 'S1', last_assistant_message: 'Fresh words here.', stop_hook_active: false })
  await clock.settle()
  expect(await shown(ui, 'Fresh')).toBeDefined()
  expect(await shown(ui, /word 1 of 3/)).toBeDefined()
})

test('the app timing is used when monoword-schedule is there and not quarantined', async ($, on) => {
  const tool = '/opt/monoword-schedule'
  const clock = world(on, { [`${DATA}/sessions/S1`]: 'tty', [`${DATA}/settings.json`]: '{"wpm": 700}', [tool]: '' }, { MONOWORD_SCHEDULE: tool })
  const runs: { argv: readonly string[]; stdin?: string }[] = []
  on('process.run', ($, e) => {
    runs.push({ argv: e.argv, stdin: e.init?.stdin })
    if (e.argv[0] === 'xattr') {
      return { value: { exitCode: 1, stdout: '', stderr: 'No such xattr: com.apple.quarantine\n', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    return { value: { exitCode: 0, stdout: 'One\t0.2\t1\ntwo, three.\t0.5\t2\n# words 3\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  await $.classic.Stop({ session_id: 'S1', last_assistant_message: REPLY, stop_hook_active: false })
  await clock.settle()
  expect(runs.map((r) => r.argv)).toEqual([['xattr', '-p', 'com.apple.quarantine', tool], [tool, '-', '700', '--chunk', 'auto']])
  expect(runs[1].stdin).toBe(REPLY)
  expect(toasts).toEqual([])
  const ui = await $.ui.mount(BAND)
  await clock.advance(200)
  expect(await shown(ui, 'two, three.')).toBeDefined()
  expect(await shown(ui, /word 2 of 3 · 0:01 left/)).toBeDefined()
})

// Before the test above: the note is module state, shown once per session, and this is the first
// test in which the tool is found at all.
test('a quarantined monoword-schedule is left alone: the fallback paces, and the strip says so once', async ($, on) => {
  const tool = `${HOME}/Applications/Monoword.app/Contents/MacOS/monoword-schedule`
  const clock = world(on, { [`${DATA}/sessions/S1`]: 'tty', [tool]: '' })
  const runs: (readonly string[])[] = []
  on('process.run', ($, e) => {
    runs.push(e.argv)
    return { value: { exitCode: 0, stdout: '0083;68f91c2a;Safari;8C7D1D3E-0000-4000-8000-000000000000\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  await $.classic.Stop({ session_id: 'S1', last_assistant_message: REPLY, stop_hook_active: false })
  await clock.settle()
  expect(runs).toEqual([['xattr', '-p', 'com.apple.quarantine', tool]])
  expect(toasts).toEqual([
    `Monoword's timing tool is still under macOS quarantine, so the strip paces the words itself. To use the app's timing, run once: xattr -dr com.apple.quarantine "${HOME}/Applications/Monoword.app"`,
  ])
  const ui = await $.ui.mount(BAND)
  expect(await shown(ui, 'One')).toBeDefined()
  await clock.advance(HOLDS[0] - 1)
  expect(await shown(ui, 'One')).toBeDefined()
  await clock.advance(1)                 // the fallback's 96 ms, not the tool's timing
  expect(await shown(ui, 'two,')).toBeDefined()
  await $.classic.Stop({ session_id: 'S1', last_assistant_message: 'Again now.', stop_hook_active: false })
  await clock.settle()
  expect(await shown(ui, 'Again')).toBeDefined()
  expect(toasts.length).toBe(1)
})

test('/monoword:read plays the saved reply in terminal mode, and leaves app mode to its script', async ($, on) => {
  const clock = world(on, { [`${DATA}/sessions/S1`]: 'tty', [`${DATA}/replies/S1.txt`]: 'Saved reply text.\n' })
  on('command.run', () => ({ text: 'the script ran' }))
  const answer = await $.command.run({ command: 'monoword:read', args: '' })
  expect(answer.text).toBeUndefined()      // no transcript row: Claude does not read about it
  await clock.settle()
  const ui = await $.ui.mount(BAND)
  expect(await shown(ui, 'Saved')).toBeDefined()
})

test('/monoword:read in app mode runs the command as before', async ($, on) => {
  world(on, { [`${DATA}/sessions/S1`]: 'app', [`${DATA}/replies/S1.txt`]: 'Saved reply text.\n' })
  on('command.run', () => ({ text: 'the script ran' }))
  const answer = await $.command.run({ command: 'monoword:read', args: '' })
  expect(answer.text).toBe('the script ran')
})

test('/monoword:speed runs its script itself once the data folder is known', async ($, on) => {
  world(on, { [`${DATA}/sessions/S1`]: 'tty' })
  const runs: (readonly string[])[] = []
  on('process.run', ($, e) => {
    runs.push(e.argv)
    return { value: { exitCode: 0, stdout: 'The terminal player now reads at 700 words a minute.\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('command.run', () => ({ text: 'the command ran through the model' }))
  const answer = await $.command.run({ command: 'monoword:speed', args: '700' })
  expect(answer.text).toBeUndefined()
  expect(toasts).toEqual(['The terminal player now reads at 700 words a minute.'])
  expect(runs.length).toBe(1)
  expect(runs[0][0]).toBe('bash')
  expect(runs[0][1]).toMatch(/scripts\/speed\.sh$/)
  expect(runs[0].slice(2)).toEqual(['700', DATA])
})

test('/monoword:align runs its script itself and moves the word on screen at once', async ($, on) => {
  const files: Record<string, string> = { [`${DATA}/sessions/S1`]: 'tty' }
  const clock = world(on, files)
  const runs: (readonly string[])[] = []
  on('process.run', ($, e) => {
    runs.push(e.argv)
    files[`${DATA}/settings.json`] = '{"align": "left"}'      // what align.sh leaves behind
    return { value: { exitCode: 0, stdout: 'The word now starts at the left of the strip, at the same column every time.\n', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('command.run', () => ({ text: 'the command ran through the model' }))
  await $.classic.Stop({ session_id: 'S1', last_assistant_message: REPLY, stop_hook_active: false })
  await clock.settle()
  const ui = await $.ui.mount(BAND)
  // Centred at 95 columns: 46 cells before "One", 29 of them the controls, then 17 of padding.
  expect(await ui.find({ type: 'Text', text: /^ {17}$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^ {2}$/ })).toBeUndefined()
  const answer = await $.command.run({ command: 'monoword:align', args: 'left' })
  expect(answer.text).toBeUndefined()
  expect(toasts).toEqual(['The word now starts at the left of the strip, at the same column every time.'])
  expect(runs[0][1]).toMatch(/scripts\/align\.sh$/)
  expect(runs[0].slice(2)).toEqual(['left', DATA])
  // Left: a two-cell margin, then the word, then the padding up to the progress and the controls.
  expect(await ui.find({ type: 'Text', text: /^ {2}$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^ {17}$/ })).toBeUndefined()
  expect(await shown(ui, 'One')).toBeDefined()
})

test('/monoword:speed before the session has any Monoword file runs the command as written', async ($, on) => {
  world(on, {})
  on('command.run', () => ({ text: 'the command ran through the model' }))
  const answer = await $.command.run({ command: 'monoword:speed', args: '700' })
  expect(answer.text).toBe('the command ran through the model')
})

test('/monoword:read with nothing saved says so in a toast', async ($, on) => {
  world(on, { [`${DATA}/sessions/S1`]: 'tty' })
  on('command.run', () => ({ text: 'the script ran' }))
  const answer = await $.command.run({ command: 'monoword:read', args: '' })
  expect(answer.text).toBeUndefined()
  expect(toasts).toEqual(['There is no saved reply yet. Ask something first, then run /monoword:read.'])
})
