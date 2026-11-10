import { expect, mock, test } from 'claude-code/testing'

const PANE = {
  plugin: 'buddy',
  component: 'Pane',
  requestId: 'buddy',
  props: {
    title: 'Buddy',
    isFocused: false,
    bodyColumns: 50,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

// The engine spells file paths for the computer the tests run on, so a Mac path looks
// different on a Windows PC and a Windows path looks different on a Mac: compare by the end.
const isPath = (path: string, end: string) => path.replace(/\\/g, '/').endsWith(end)

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function engine(on: any) {
  on('command.register', () => ({ value: { command: 'buddy' } }))
  on('agent.register', () => ({ value: { agent: 'buddy:eyes' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: {} }))
}

test('the panel shows the pet and what Claude is doing, on every surface', async ($, on) => {
  engine(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'Bash', command: 'npm test', description: 'Run the tests' })

  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /Run the tests/ }))?.text).toContain('Running Run the tests')
    expect(await ui.find({ type: 'Button', text: /Look at my screen/ })).toBeTruthy()
    await ui.unmount()
  }
})

test('the desktop draws the pixel pet as an animated SVG', async ($, on) => {
  engine(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const pet = await ui.find({ type: 'Svg' })
  expect(pet).toBeTruthy()
  await ui.unmount()
})

test('the desktop pet gets a reply, and sees what Claude is doing', async ($, on) => {
  engine(on)
  mock.env(on, { HOME: '/Users/test' })
  const clock = mock.clock(on, { now: 1_000_000 })
  const runs: string[][] = []
  const writes: { path: string; text: string }[] = []
  let isQueued = true
  on('session.id', () => ({ value: 'sess-1' }))
  on('process.run', (_: unknown, e: { argv: readonly string[] }) => {
    runs.push([...e.argv])
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.list', (_: unknown, e: { path: string }) => {
    if (isPath(e.path, '/Users/test/.claude/buddy/inbox') && isQueued) {
      isQueued = false
      return { value: [{ name: 'req-1.json', kind: 'file', size: 10, mtimeMs: 0, isLink: false }] }
    }
    return { value: [] }
  })
  on('fs.read', () => ({ value: JSON.stringify({ id: 'req-1', kind: 'say', text: 'hi buddy', history: [] }) }))
  on('fs.write', (_: unknown, e: { path: string; text: string }) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('model.complete', () => ({
    value: {
      isAnswered: true,
      text: 'Hello friend!',
      usage: { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
    },
  }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: '/x/app.ts', old_string: 'a', new_string: 'b' })
  await clock.advance(2500)

  const root = '/Users/test/.claude/buddy'
  const reply = writes.find(w => isPath(w.path, `${root}/outbox/req-1.tmp`))
  expect(reply && JSON.parse(reply.text).text).toBe('Hello friend!')
  expect(runs).toContainEqual(['mv', `${root}/inbox/req-1.json`, `${root}/inbox/req-1.sess-1.claimed`])
  expect(runs).toContainEqual(['mv', '-f', `${root}/outbox/req-1.tmp`, `${root}/outbox/req-1.json`])
  const statuses = writes.filter(w => isPath(w.path, `${root}/sessions/sess-1.json`))
  expect(statuses.length).toBeGreaterThan(0)
  expect(JSON.parse(statuses[statuses.length - 1]!.text).activity).toBe('Editing app.ts')
})

const ranFine = { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
const WINDOWS = { OS: 'Windows_NT', USERPROFILE: 'C:\\Users\\test', LOCALAPPDATA: 'C:\\Users\\test\\AppData\\Local' }
const WINDOWS_ROOT = 'C:/Users/test/.claude/buddy'
const WINDOWS_ROOT_NATIVE = 'C:\\Users\\test\\.claude\\buddy'

test('on Windows the pet gets a reply through Windows paths and tools, never mv or rm', async ($, on) => {
  engine(on)
  mock.env(on, WINDOWS)
  const clock = mock.clock(on, { now: 1_000_000 })
  const runs: { argv: string[]; cwd?: string }[] = []
  const writes: { path: string; text: string }[] = []
  let isQueued = true
  on('session.id', () => ({ value: 'sess-1' }))
  on('process.run', (_: unknown, e: { argv: readonly string[]; init?: { cwd?: string } }) => {
    runs.push({ argv: [...e.argv], cwd: e.init?.cwd })
    return { value: ranFine }
  })
  on('fs.list', (_: unknown, e: { path: string }) => {
    if (isPath(e.path, `${WINDOWS_ROOT}/inbox`) && isQueued) {
      isQueued = false
      return { value: [{ name: 'req-1.json', kind: 'file', size: 10, mtimeMs: 0, isLink: false }] }
    }
    return { value: [] }
  })
  on('fs.read', () => ({ value: JSON.stringify({ id: 'req-1', kind: 'say', text: 'hi buddy', history: [] }) }))
  on('fs.write', (_: unknown, e: { path: string; text: string }) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('model.complete', () => ({
    value: {
      isAnswered: true,
      text: 'Hello friend!',
      usage: { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
    },
  }))

  await $.session.start({ cwd: 'C:\\work', surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: 'C:\\work\\app.ts', old_string: 'a', new_string: 'b' })
  await clock.advance(2500)

  const reply = writes.find(w => isPath(w.path, `${WINDOWS_ROOT}/outbox/req-1.tmp`))
  expect(reply && JSON.parse(reply.text).text).toBe('Hello friend!')
  const inbox = `${WINDOWS_ROOT_NATIVE}\\inbox`
  const outbox = `${WINDOWS_ROOT_NATIVE}\\outbox`
  expect(runs).toContainEqual({ argv: ['cmd', '/c', 'move', '/Y', 'req-1.json', 'req-1.sess-1.claimed'], cwd: inbox })
  expect(runs).toContainEqual({ argv: ['cmd', '/c', 'del', '/f', '/q', 'req-1.sess-1.claimed'], cwd: inbox })
  expect(runs).toContainEqual({ argv: ['cmd', '/c', 'move', '/Y', 'req-1.tmp', 'req-1.json'], cwd: outbox })
  expect(runs.filter(r => ['mv', 'rm', 'mkdir'].includes(r.argv[0]!))).toEqual([])
  const statuses = writes.filter(w => isPath(w.path, `${WINDOWS_ROOT}/sessions/sess-1.json`))
  expect(JSON.parse(statuses[statuses.length - 1]!.text).activity).toBe('Editing app.ts')
})

test('/buddy starts the desktop pet that belongs to the computer', async ($, on) => {
  engine(on)
  mock.env(on, WINDOWS)
  mock.clock(on)
  const runs: string[][] = []
  on('session.id', () => ({ value: 'sess-1' }))
  on('fs.write', () => ({ value: undefined }))
  on('fs.list', () => ({ value: [] }))
  on('fs.exists', (_: unknown, e: { path: string }) => ({ value: isPath(e.path, 'C:/Users/test/AppData/Local/Buddy/Buddy.exe') }))
  on('process.run', (_: unknown, e: { argv: readonly string[] }) => {
    runs.push([...e.argv])
    return { value: ranFine }
  })

  await $.session.start({ cwd: 'C:\\work', surface: 'desktop', isInteractive: true })
  const answer = await $.command.run({ command: 'buddy', args: '' } as never)

  expect(answer.text).toContain('bottom-right corner')
  expect(runs).toContainEqual([
    'powershell.exe',
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    "Start-Process -FilePath 'C:\\Users\\test\\AppData\\Local\\Buddy\\Buddy.exe'",
  ])
})

test('/buddy on a Mac still opens Buddy.app the way it did', async ($, on) => {
  engine(on)
  mock.env(on, { HOME: '/Users/test' })
  mock.clock(on)
  const runs: string[][] = []
  on('session.id', () => ({ value: 'sess-1' }))
  on('fs.write', () => ({ value: undefined }))
  on('fs.list', () => ({ value: [] }))
  on('fs.exists', (_: unknown, e: { path: string }) => ({ value: isPath(e.path, '/Users/test/Applications/Buddy.app') }))
  on('process.run', (_: unknown, e: { argv: readonly string[] }) => {
    runs.push([...e.argv])
    return { value: ranFine }
  })

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const answer = await $.command.run({ command: 'buddy', args: '' } as never)

  expect(answer.text).toContain('bottom-right corner')
  expect(runs).toContainEqual(['open', '/Users/test/Applications/Buddy.app'])
  expect(runs.filter(r => r[0] === 'powershell.exe' || r[0] === 'cmd')).toEqual([])
})

test('/buddy says where the pet lives on a computer with no desktop app', async ($, on) => {
  engine(on)
  mock.env(on, { HOME: '/home/test' })
  mock.clock(on)
  on('session.id', () => ({ value: 'sess-1' }))
  on('fs.write', () => ({ value: undefined }))
  on('fs.list', () => ({ value: [] }))
  on('fs.exists', () => ({ value: false }))
  on('process.run', () => ({ value: ranFine }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const answer = await $.command.run({ command: 'buddy', args: '' } as never)

  expect(answer.text).toContain('runs on Mac and Windows')
})

test('on Windows a look request must name its own screenshot, however the path is spelled', async ($, on) => {
  engine(on)
  mock.env(on, WINDOWS)
  const clock = mock.clock(on, { now: 1_000_000 })
  const writes: { path: string; text: string }[] = []
  const prompts: string[] = []
  const queue = ['req-2.json', 'req-3.json']
  const requests: Record<string, object> = {
    'req-2': { id: 'req-2', kind: 'look', text: 'what do you see', image: `${WINDOWS_ROOT_NATIVE}\\SHOTS\\req-2.png` },
    'req-3': { id: 'req-3', kind: 'look', text: 'what do you see', image: 'C:\\Users\\test\\Documents\\secret.png' },
  }
  on('session.id', () => ({ value: 'sess-1' }))
  on('process.run', () => ({ value: ranFine }))
  on('fs.exists', () => ({ value: true }))
  on('fs.list', (_: unknown, e: { path: string }) => {
    const next = isPath(e.path, `${WINDOWS_ROOT}/inbox`) ? queue.shift() : undefined
    return { value: next ? [{ name: next, kind: 'file', size: 10, mtimeMs: 0, isLink: false }] : [] }
  })
  on('fs.read', (_: unknown, e: { path: string }) => ({
    value: JSON.stringify(e.path.includes('req-2') ? requests['req-2'] : requests['req-3']),
  }))
  on('fs.write', (_: unknown, e: { path: string; text: string }) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('agent.spawn', (_: unknown, e: { prompt: string }) => {
    prompts.push(e.prompt)
    return { model: 'haiku', agentId: 'eyes-1' }
  })

  await $.session.start({ cwd: 'C:\\work', surface: 'desktop', isInteractive: true })
  await clock.advance(3100)

  // The eyes are told the path in Windows' spelling, and only about the real screenshot.
  expect(prompts).toEqual([`Screenshot path: ${WINDOWS_ROOT_NATIVE}\\shots\\req-2.png\nThe user asked: what do you see`])
  const refused = writes.find(w => isPath(w.path, `${WINDOWS_ROOT}/outbox/req-3.tmp`))
  expect(refused && JSON.parse(refused.text).text).toContain("couldn't find the screenshot")
})
