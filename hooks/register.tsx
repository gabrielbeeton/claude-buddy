import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { ChatLine, Mood } from '../types'

type Engine = EngineInterface

const PANE = 'buddy'
const TITLE = 'Buddy'
const EYES = 'buddy:eyes'
const SHOT_DIR = '/tmp/claude-buddy'

// Bump a shape tag when that value's form changes: it declines what an
// earlier version stored, which outlives a reload.
const chat = atom({ plugin: 'buddy', key: 'chat' } as const, [] as ChatLine[], { shape: 'chat-1' })
const mood = atom({ plugin: 'buddy', key: 'mood' } as const, 'idle' as Mood, { shape: 'mood-1' })
const activity = atom({ plugin: 'buddy', key: 'activity' } as const, 'Napping. Nothing going on yet.', { shape: 'activity-1' })
const recent = atom({ plugin: 'buddy', key: 'recent' } as const, [] as string[], { shape: 'recent-2' })
const isReplying = atom({ plugin: 'buddy', key: 'isReplying' } as const, false, { shape: 'replying-1' })

// ------------------------------------------------------------ the pet (panel)
//
// The same sprite as the desktop app: Claude Code's orange creature on an
// 18 x 10 grid of 7-unit squares, in a 150 x 118 box.

const ORANGE = '#D97757'
const LIGHT = '#E8977A'
const SHADE = '#B65A3E'
const OUTLINE = '#2A1712'
const EYE = '#1E1410'
const S = 7
const X0 = 12
const TOP = 22
const GROUND = 92

type Box = [number, number, number, number]
const cell = (col: number, row: number, w: number, h: number): Box => [X0 + col * S, TOP + row * S, w * S, h * S]
const rect = ([x, y, w, h]: Box, fill: string, grow = 0) =>
  `<rect x="${x - grow}" y="${y - grow}" width="${w + 2 * grow}" height="${h + 2 * grow}" fill="${fill}"/>`
const move = (values: string, dur: string, begin = '0s', discrete = false) =>
  `<animateTransform attributeName="transform" type="translate" values="${values}" dur="${dur}" begin="${begin}" repeatCount="indefinite"${discrete ? ' calcMode="discrete"' : ''}/>`
const pulse = (dur: string, begin = '0s') =>
  `<animate attributeName="opacity" values="0.3;1;0.3" dur="${dur}" begin="${begin}" repeatCount="indefinite"/>`

function petSvg(m: Mood): string {
  const bob =
    m === 'working' ? move('0 0;0 -3;0 0', '0.5s')
    : m === 'thinking' ? move('0 0;0 -2;0 0', '1.8s')
    : m === 'looking' ? move('0 0;0 -1.5;0 0', '1.6s')
    : m === 'happy' ? ''
    : move('0 0;0 -2;0 0', '2.6s')
  const jump = m === 'happy' ? move('0 0;0 -14;0 0', '0.6s') : ''

  const body = cell(3, 0, 12, 8)
  const arms: [Box, string][] = [
    [cell(1, 4, 2, 2), m === 'happy' ? move('0 -14;0 0', '0.6s', '0s', true) : ''],
    [cell(15, 4, 2, 2), m === 'happy' ? move('0 0;0 -14', '0.6s', '0s', true) : ''],
  ]
  const legs: [Box, string][] = [4, 6, 11, 13].map((col, i) => [
    [X0 + col * S, TOP + 8 * S - 3, S, 2 * S + 3],
    m === 'working' ? move('0 0;0 -4;0 0', '0.32s', i % 2 ? '0.16s' : '0s') : '',
  ])

  const layer = (outline: boolean) =>
    legs.map(([box, motion]) => `<g>${motion}${rect(box, outline ? OUTLINE : ORANGE, outline ? 1.5 : 0)}${outline ? '' : rect([box[0], box[1] + box[3] - 2.5, box[2], 2.5], SHADE)}</g>`).join('') +
    `<g>${bob}${rect(body, outline ? OUTLINE : ORANGE, outline ? 1.5 : 0)}${
      outline ? '' : rect([body[0] + S, body[1], body[2] - 2 * S, S / 2], LIGHT) + rect([body[0], body[1] + body[3] - S / 2, body[2], S / 2], SHADE)
    }${arms.map(([box, wave]) => `<g>${wave}${rect(box, outline ? OUTLINE : ORANGE, outline ? 1.5 : 0)}</g>`).join('')}</g>`

  const eyes = [5, 12]
    .map(col => {
      const [x, y] = cell(col, 2, 1, 2)
      if (m === 'happy') {
        return `<path d="M${x - 0.5} ${y + 11} L${x + S / 2} ${y + 4} L${x + S + 0.5} ${y + 11}" stroke="${EYE}" stroke-width="2.6" fill="none" stroke-linecap="square"/>`
      }
      const blink =
        `<animate attributeName="height" values="14;14;2.5;14" keyTimes="0;0.92;0.96;1" dur="4.2s" repeatCount="indefinite"/>` +
        `<animate attributeName="y" values="${y};${y};${y + 11.5};${y}" keyTimes="0;0.92;0.96;1" dur="4.2s" repeatCount="indefinite"/>`
      return `<rect x="${x}" y="${y}" width="${S}" height="${2 * S}" fill="${EYE}">${blink}</rect>` +
        `<rect x="${x + 1}" y="${y + 1.5}" width="2.5" height="3" fill="#fff" opacity="0.85"/>`
    })
    .join('')
  const gaze =
    m === 'thinking' ? 'transform="translate(1.5 -3)"'
    : ''
  const scan = m === 'looking' ? move('-2.5 0;2.5 0;-2.5 0', '1.6s') : ''

  const extras =
    m === 'thinking'
      ? [0, 1, 2].map(i => `<rect x="${X0 + 15 * S + i * 7}" y="${TOP - 8}" width="4" height="4" fill="#F0E6DF">${pulse('1.1s', `${i * 0.2}s`)}</rect>`).join('')
      : m === 'happy'
        ? ([[4, 18], [134, 12], [139, 46], [2, 50]] as const)
            .map(([x, y], i) => `<path d="M${x + 2.5} ${y}h2.5v2.5h2.5v2.5h-2.5v2.5h-2.5v-2.5h-2.5v-2.5h2.5z" fill="#FFD9A8">${pulse('0.9s', `${i * 0.25}s`)}</path>`)
            .join('')
        : ''

  const light =
    m === 'working' ? ORANGE : m === 'happy' ? '#4CC38A' : m === 'thinking' || m === 'looking' ? '#8AB4F8' : '#9A9A9A'
  const pill = `<rect x="60" y="${GROUND + 12}" width="30" height="5" rx="2.5" fill="${light}" opacity="0.6">${
    m === 'working' || m === 'thinking' || m === 'looking' ? pulse('1s') : ''
  }</rect>`

  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 150 118" width="150" height="118" shape-rendering="crispEdges">` +
    `<ellipse cx="75" cy="${GROUND + 1}" rx="38" ry="3" fill="#000" opacity="0.22" shape-rendering="auto"/>` +
    `<g>${jump}${layer(true)}${layer(false)}<g>${bob}<g ${gaze}>${scan}${eyes}</g></g></g>` +
    extras +
    pill +
    `</svg>`
  )
}

const ASCII: Record<Mood, string[]> = {
  idle: [' ▐▛███▜▌   z', '▝▜█████▛▘', '  ▘▘ ▝▝'],
  working: [' ▐▛███▜▌  >_', '▝▜█████▛▘', '  ▝▘ ▘▝'],
  thinking: [' ▐▀███▀▌  ...', '▝▜█████▛▘', '  ▘▘ ▝▝'],
  looking: [' ▐█▛█▜█▌  oo', '▝▜█████▛▘', '  ▘▘ ▝▝'],
  happy: [' ▐^███^▌  ✦', '▝▜█████▛▘', '  ▝▘ ▘▝'],
}

const MOOD_WORD: Record<Mood, string> = {
  idle: 'Chilling',
  working: 'Watching Claude work',
  thinking: 'Thinking',
  looking: 'Looking at your screen',
  happy: 'Done!',
}

// ------------------------------------------------------- what Claude is doing

let isMainBusy = false
let lastTurnEndAt = 0
let happyTimer: { cancel: () => void } | undefined
const eyesAgents = new Set<string>()
const allowedShots = new Set<string>()
const waiting = new Map<string, (answer: string) => void>()
const finished = new Map<string, string>()

const base = (p: unknown) => (typeof p === 'string' ? p.split('/').pop() ?? p : '')
const clip = (s: string, n = 60) => (s.length > n ? s.slice(0, n - 1) + '…' : s)

function describe(tool: string, input: unknown): string {
  const i = (input ?? {}) as Record<string, unknown>
  const str = (k: string) => (typeof i[k] === 'string' ? (i[k] as string) : '')
  switch (tool) {
    case 'Bash':
      return `Running ${clip(str('description') || str('command')) || 'a command'}`
    case 'Read':
      return `Reading ${base(i.file_path)}`
    case 'Edit':
    case 'MultiEdit':
      return `Editing ${base(i.file_path)}`
    case 'Write':
      return `Writing ${base(i.file_path)}`
    case 'Grep':
    case 'Glob':
      return `Searching for ${clip(str('pattern'), 40)}`
    case 'WebSearch':
      return `Searching the web: ${clip(str('query'), 40)}`
    case 'WebFetch':
      return `Reading a web page`
    case 'Agent':
    case 'Task':
      return `Sending a helper: ${clip(str('description'), 40)}`
    default:
      if (tool.startsWith('mcp__')) return `Using ${tool.split('__').slice(1).join(' › ')}`
      return `Using ${tool}`
  }
}

// ------------------------------------------------------- the desktop bridge
//
// The desktop app (Buddy.app) and this mod share ~/.claude/buddy:
//   sessions/<sid>.json  this session's status, rewritten every few seconds
//   inbox/<id>.json      what the person said to the desktop pet
//   outbox/<id>.json     Buddy's reply
//   shots/<id>.png       a screenshot the app took for a "look" request
//   quit                 asks the app to quit (/buddy bye)

let home = ''
let root = ''
let sid = ''
let ticker: ReturnType<Engine['clock']['every']> | undefined
let ticks = 0
let isPolling = false
let isDirty = true

const SAFE_ID = /^[A-Za-z0-9-]{1,80}$/

type DeskRequest = { id?: unknown; kind?: unknown; text?: unknown; image?: unknown; history?: unknown }

async function startBridge($: Engine) {
  home = (await $.env.get('HOME')) ?? ''
  if (!home) return
  root = `${home}/.claude/buddy`
  await $.process.run(['mkdir', '-p', `${root}/sessions`, `${root}/inbox`, `${root}/outbox`, `${root}/shots`])
  ticker?.cancel()
  ticker = $.clock.every(1000, () => {
    void tick($)
  })
  await writeStatus($)
}

async function tick($: Engine) {
  ticks++
  try {
    if (isDirty || ticks % 4 === 0) await writeStatus($)
    await pollInbox($)
  } catch {
    // try again next second
  }
}

async function writeStatus($: Engine) {
  if (!root) return
  if (!sid) sid = await $.session.id()
  if (!SAFE_ID.test(sid)) return
  isDirty = false
  const status = {
    v: 1,
    sid,
    heartbeat: await $.clock.now(),
    isBusy: isMainBusy,
    activity: await read($, activity),
    lastTurnEndAt,
  }
  await $.fs.write(`${root}/sessions/${sid}.json`, JSON.stringify(status))
}

function markDirty($: Engine) {
  isDirty = true
  void writeStatus($).catch(() => undefined)
}

async function pollInbox($: Engine) {
  if (isPolling || !root || !sid) return
  isPolling = true
  try {
    const entries = await $.fs.list(`${root}/inbox`)
    for (const entry of entries) {
      if (entry.kind !== 'file' || !entry.name.endsWith('.json')) continue
      const id = entry.name.slice(0, -5)
      if (!SAFE_ID.test(id)) continue
      // Claim it: only one session wins the rename.
      const claimed = `${root}/inbox/${id}.${sid}.claimed`
      const moved = await $.process.run(['mv', `${root}/inbox/${entry.name}`, claimed])
      if (moved.exitCode !== 0) continue
      let request: DeskRequest | undefined
      try {
        request = JSON.parse(await $.fs.read(claimed)) as DeskRequest
      } catch {
        request = undefined
      }
      await $.process.run(['rm', '-f', claimed])
      if (!request || typeof request !== 'object') continue
      const text = await answerDesk($, id, request)
      await $.fs.write(`${root}/outbox/${id}.tmp`, JSON.stringify({ id, text }))
      await $.process.run(['mv', '-f', `${root}/outbox/${id}.tmp`, `${root}/outbox/${id}.json`])
    }
  } finally {
    isPolling = false
  }
}

function cleanHistory(raw: unknown): ChatLine[] {
  if (!Array.isArray(raw)) return []
  return raw
    .filter((l): l is { who: string; text: string } => !!l && typeof l === 'object' && typeof l.text === 'string')
    .map(l => ({ who: l.who === 'me' ? 'me' : 'buddy', text: l.text.slice(0, 2000) }) as ChatLine)
    .slice(-14)
}

async function answerDesk($: Engine, id: string, request: DeskRequest): Promise<string> {
  const text = typeof request.text === 'string' ? request.text.slice(0, 2000) : ''
  if (request.kind === 'look') {
    const expected = `${root}/shots/${id}.png`
    if (request.image !== expected || !(await $.fs.exists(expected))) {
      return "*(I couldn't find the screenshot to look at.)*"
    }
    return peek($, text || 'What do you see on my screen?', expected)
  }
  if (!text) return '*(I didn’t catch that.)*'
  return think($, cleanHistory(request.history), text)
}

// ----------------------------------------------------------------- talking

const PERSONA = `You are Buddy, a tiny orange pixel creature (the Claude Code mascot) who lives in the corner of the user's screen and in a side panel of their Claude app, keeping them company while Claude (the main assistant) works.
Personality: warm, curious, a little cheeky, never mean. Keep replies short: 1-3 sentences, plain text or light markdown, no headings.
You can see a live log of what Claude is doing (below). You cannot run tools, edit files or do the work yourself: if the user wants real work done, cheerfully tell them to ask Claude in the main chat.
If the user wants you to look at their screen, tell them to press the eye button or just say "look".`

const LOOK_WORDS = /\b(look|screen|see (this|that|what)|what'?s on)\b/i

async function think($: Engine, history: ChatLine[], text: string): Promise<string> {
  try {
    const log = await read($, recent)
    const now = isMainBusy ? await read($, activity) : 'Nothing. Claude is idle, waiting for the user.'
    const transcript = [...history.slice(-14), { who: 'me', text }]
      .map(l => `${l.who === 'me' ? 'User' : 'Buddy'}: ${l.text}`)
      .join('\n')
    const r = await $.model.complete({
      model: 'haiku',
      system: PERSONA,
      prompt: `What Claude is doing right now: ${now}\nRecent activity:\n${log.map(x => `- ${x}`).join('\n') || '- (nothing yet)'}\n\nConversation so far:\n${transcript}\n\nReply as Buddy to the user's last message.`,
      maxTokens: 300,
      timeoutMs: 30000,
    })
    return r.isAnswered ? r.text.trim() : `*(Buddy's brain fizzled: ${r.reason}. Try again?)*`
  } catch (err) {
    return `*(Couldn't think: ${String(err)})*`
  }
}

// Spawns Buddy's eyes on one screenshot and waits for what they saw.
async function peek($: Engine, question: string, path: string): Promise<string> {
  allowedShots.add(path)
  try {
    const spawned = await $.agent.spawn({
      subagentType: EYES,
      description: 'Buddy looks at your screen',
      prompt: `Screenshot path: ${path}\nThe user asked: ${question}`,
    })
    if (!('agentId' in spawned) || !spawned.agentId) {
      return `*(My eyes wouldn't open: ${'deny' in spawned ? String(spawned.deny) : 'no reason given'})*`
    }
    const id = spawned.agentId
    eyesAgents.add(id)
    const seen = await new Promise<string>(resolve => {
      const early = finished.get(id)
      if (early !== undefined) {
        finished.delete(id)
        return resolve(early)
      }
      const timer = $.clock.after(120000, () => resolve(''))
      waiting.set(id, answer => {
        timer.cancel()
        resolve(answer)
      })
    })
    waiting.delete(id)
    return seen.trim() || "*(I squinted but couldn't make anything out. Try again?)*"
  } catch (err) {
    return `*(Something went wrong while looking: ${String(err)})*`
  } finally {
    allowedShots.delete(path)
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({
      name: 'buddy',
      description: 'Wake Buddy on your desktop (or: /buddy panel, /buddy bye)',
    })
    try {
      await $.agent.register({
        name: 'eyes',
        description: "Buddy's eyes: describes a screenshot of the user's screen.",
        prompt:
          "You are the eyes of Buddy, a small friendly companion. You'll be given a path to a screenshot of the user's screen and their question. Use the Read tool on that exact path, look carefully, then answer the question in Buddy's voice: warm, a bit playful, 2-5 short sentences. Mention concrete things you can see (apps, text, errors). Never invent details you can't see. Your final message is the answer itself, nothing else.",
        tools: ['Read'],
        model: 'haiku',
      })
    } catch {
      // the session has not bound yet; looking then explains itself
    }
    try {
      await startBridge($)
    } catch {
      // the desktop pet just stays asleep
    }
    return started
  })

  on('session.end', async ($, e, next) => {
    try {
      if (root && sid) await $.process.run(['rm', '-f', `${root}/sessions/${sid}.json`])
    } catch {
      // the app ignores a stale status after a few seconds anyway
    }
    sid = '' // after /clear the session goes on under a new id
    if (e.reason !== 'clear') {
      ticker?.cancel()
      ticker = undefined
    }
    return next(e)
  })

  // The eyes are Buddy's alone; the main model never sees the agent type.
  on('agent.offer', { agent: EYES }, () => ({ isOffered: false }))

  // The eyes may read the screenshot Buddy is looking at, and nothing else.
  on('tool.check', async ($, e, next) => {
    if (!e.agentId || !eyesAgents.has(e.agentId)) return next(e)
    const path = (e.input as { file_path?: unknown } | undefined)?.file_path
    if (e.tool === 'Read' && typeof path === 'string' && allowedShots.has(path)) {
      return { decision: 'allow', reason: 'Buddy is reading the screenshot it was asked to look at.' }
    }
    return { decision: 'deny', reason: 'Buddy may only read its own screenshot.' }
  })

  on('command.run', { command: 'buddy' }, async ($, e) => {
    const said = e.args.trim()
    if (!home) home = (await $.env.get('HOME')) ?? ''
    if (said === 'panel') {
      await $.ui.open({ id: PANE, title: TITLE, focus: true })
      return { text: 'Buddy panel opened.' }
    }
    if (said === 'bye' || said === 'quit') {
      if (root) await $.fs.write(`${root}/quit`, 'bye')
      return { text: 'Buddy waved goodbye. Type /buddy to bring it back.' }
    }
    if (said) {
      await $.ui.open({ id: PANE, title: TITLE, focus: true })
      void say($, said)
      return { text: 'Buddy heard you. Check the Buddy panel.' }
    }
    const app = home ? `${home}/Applications/Buddy.app` : ''
    if (app && (await $.fs.exists(app))) {
      const opened = await $.process.run(['open', app])
      if (opened.exitCode === 0) {
        return { text: 'Buddy is on your desktop, in the bottom-right corner. Click it to chat, drag it anywhere, right-click for more.' }
      }
    }
    await $.ui.open({ id: PANE, title: TITLE, focus: true })
    return { text: "Buddy's desktop pet isn't installed yet. Type /buddy:setup and Claude will build it for your Mac (about a minute). Meanwhile, here's the Buddy panel." }
  })

  // ---- live status

  on('turn.start', async ($, e, next) => {
    if (!e.agentId) {
      isMainBusy = true
      happyTimer?.cancel()
      try {
        if (!(await read($, isReplying))) await update($, mood, () => 'working' as Mood)
        await update($, activity, () => 'Claude is thinking about your request…')
        markDirty($)
      } catch {
        // decoration only
      }
    }
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    if (!(e.agentId && eyesAgents.has(e.agentId))) {
      try {
        const what = (e.agentId ? '(helper) ' : '') + describe(e.tool, e)
        await update($, activity, () => what)
        await update($, recent, list => [...list, what].slice(-6))
        markDirty($)
      } catch {
        // Buddy's status is decoration: never let it hold up a real tool call
      }
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId) {
      if (eyesAgents.has(e.agentId)) {
        const hand = waiting.get(e.agentId)
        if (hand) hand(e.answer)
        else finished.set(e.agentId, e.answer)
      }
      return done
    }
    isMainBusy = false
    lastTurnEndAt = await $.clock.now()
    await update($, activity, () => (e.isAborted ? 'Claude stopped. Waiting for you.' : 'Claude is done. Your turn!'))
    markDirty($)
    if (!(await read($, isReplying))) {
      await update($, mood, () => 'happy' as Mood)
      happyTimer?.cancel()
      happyTimer = $.clock.after(5000, () => {
        void (async () => {
          if ((await read($, mood)) === 'happy') await update($, mood, () => 'idle' as Mood)
        })()
      })
    }
    return done
  })

  // ---- the side panel (/buddy panel)

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    const { Box, Text, Button, Markdown } = ui
    const lines = await read($, chat)
    const m = await read($, mood)
    const now = await read($, activity)
    const log = await read($, recent)
    const replying = await read($, isReplying)
    const Input = 'Input' in ui ? ui.Input : undefined
    const Svg = 'Svg' in ui ? ui.Svg : undefined

    return (
      <Box flexDirection="column" gap={1}>
        <Box flexDirection="column" alignItems="center">
          {Svg ? (
            <Svg source={petSvg(m)} alt={`Buddy, ${MOOD_WORD[m].toLowerCase()}`} width={180} isInteractive />
          ) : (
            <Box flexDirection="column">
              {ASCII[m].map(row => (
                <Text color={ORANGE}>{row}</Text>
              ))}
            </Box>
          )}
          <Text bold>{MOOD_WORD[m]}</Text>
        </Box>

        <Box flexDirection="column">
          <Text>
            <Text color={isMainBusy ? ORANGE : undefined}>{isMainBusy ? '● ' : '○ '}</Text>
            {now}
          </Text>
          {log
            .slice(0, -1)
            .slice(-4)
            .map(row => (
              <Text dimColor>  {row}</Text>
            ))}
        </Box>

        <Box flexDirection="column" gap={1}>
          {lines.length === 0 && (
            <Text dimColor>Say hi! Ask me anything, or press "Look at my screen" and I'll tell you what I see.</Text>
          )}
          {lines.slice(-30).map(line =>
            line.who === 'me' ? (
              <Text>
                <Text bold>You: </Text>
                {line.text}
              </Text>
            ) : (
              <Box flexDirection="column">
                <Text bold color={ORANGE}>Buddy:</Text>
                <Markdown text={line.text} />
              </Box>
            ),
          )}
          {replying && <Text dimColor>Buddy is {m === 'looking' ? 'looking…' : 'typing…'}</Text>}
        </Box>

        {Input && (
          <Input
            key="buddy-say"
            placeholder="Talk to Buddy…"
            submitLabel="send"
            value=""
            autoFocus
            onSubmit={value => void say($, value)}
          />
        )}
        <Box flexDirection="row" gap={1}>
          <Button variant="primary" onPress={() => void look($, 'What do you see on my screen?')}>
            Look at my screen
          </Button>
          <Button dimColor onPress={() => void update($, chat, () => [])}>
            Clear chat
          </Button>
        </Box>
        <Text dimColor>Buddy also lives on your desktop: type /buddy.</Text>
      </Box>
    )
  })
}

// --------------------------------------------------------- panel behaviour

async function settle($: Engine) {
  await update($, isReplying, () => false)
  await update($, mood, () => (isMainBusy ? 'working' : 'idle') as Mood)
}

async function say($: Engine, raw: string) {
  const text = raw.trim()
  if (!text || (await read($, isReplying))) return
  const history = await read($, chat)
  await update($, chat, list => [...list, { who: 'me', text } as ChatLine].slice(-60))
  if (LOOK_WORDS.test(text)) return look($, text, true)

  await update($, isReplying, () => true)
  await update($, mood, () => 'thinking' as Mood)
  try {
    const reply = await think($, history, text)
    await update($, chat, list => [...list, { who: 'buddy', text: reply } as ChatLine].slice(-60))
  } finally {
    await settle($)
  }
}

async function look($: Engine, question: string, alreadyAsked = false) {
  if (await read($, isReplying)) return
  if (!alreadyAsked) await update($, chat, list => [...list, { who: 'me', text: question } as ChatLine].slice(-60))
  await update($, isReplying, () => true)
  await update($, mood, () => 'looking' as Mood)

  const path = `${SHOT_DIR}/screen-${await $.clock.now()}.png`
  let reply: string
  try {
    await $.process.run(['mkdir', '-p', SHOT_DIR])
    const cap = await $.process.run(['screencapture', '-x', '-C', '-t', 'png', path], { timeoutMs: 15000 })
    if (cap.exitCode !== 0) {
      reply =
        "I couldn't take a peek. On a Mac, give the Claude app **Screen Recording** permission in System Settings › Privacy & Security, then try again."
    } else {
      await $.process.run(['sips', '-Z', '1600', path], { timeoutMs: 15000 })
      reply = await peek($, question, path)
    }
  } catch (err) {
    reply = `*(Something went wrong while looking: ${String(err)})*`
  } finally {
    void $.process.run(['rm', '-f', path]).catch(() => undefined)
  }
  await update($, chat, list => [...list, { who: 'buddy', text: reply } as ChatLine].slice(-60))
  await settle($)
}
