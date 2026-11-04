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
    if (e.path.endsWith('/inbox') && isQueued) {
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
  const reply = writes.find(w => w.path === `${root}/outbox/req-1.tmp`)
  expect(reply && JSON.parse(reply.text).text).toBe('Hello friend!')
  expect(runs).toContainEqual(['mv', `${root}/inbox/req-1.json`, `${root}/inbox/req-1.sess-1.claimed`])
  expect(runs).toContainEqual(['mv', '-f', `${root}/outbox/req-1.tmp`, `${root}/outbox/req-1.json`])
  const statuses = writes.filter(w => w.path === `${root}/sessions/sess-1.json`)
  expect(statuses.length).toBeGreaterThan(0)
  expect(JSON.parse(statuses[statuses.length - 1]!.text).activity).toBe('Editing app.ts')
})
