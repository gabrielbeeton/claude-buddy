// Tests the mod inside real Claude Code on this computer, standing in for the desktop
// app: it reads the session's status, then sends a chat message and a screen look
// through the inbox, the way the app does, and checks what comes back.
//   CLAUDE_BIN    the claude command (default "claude")
//   PLUGIN_DIR    the plugin's folder (default this repository)
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const pluginDir = process.env.PLUGIN_DIR ?? path.resolve(here, '..', '..')
const claudeBin = process.env.CLAUDE_BIN ?? 'claude'
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'buddy-e2e-'))
const root = path.join(home, '.claude', 'buddy')
const port = String(18700 + Math.floor(Math.random() * 200))
const releaseFile = path.join(home, 'release')
const apiLog = path.join(home, 'fake-api.log')
const claudeLog = path.join(home, 'claude.log')

const env = {
  ...process.env,
  HOME: home,
  USERPROFILE: home,
  CLAUDE_CONFIG_DIR: path.join(home, '.claude'),
  ANTHROPIC_API_KEY: 'test-key',
  ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`,
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
  DISABLE_AUTOUPDATER: '1',
  FAKE_API_PORT: port,
  FAKE_API_LOG: apiLog,
  RELEASE_FILE: releaseFile,
}

const failures = []
const check = (name, ok, detail = '') => {
  console.log(`${ok ? 'pass' : 'FAIL'}  ${name}${detail ? `: ${detail}` : ''}`)
  if (!ok) failures.push(name)
}
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
async function until(what, test, ms = 60000) {
  const end = Date.now() + ms
  while (Date.now() < end) {
    const value = test()
    if (value) return value
    await sleep(200)
  }
  throw new Error(`timed out waiting for ${what}`)
}
const readJson = file => {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    return undefined
  }
}
const listDir = dir => {
  try {
    return fs.readdirSync(dir)
  } catch {
    return []
  }
}

// One pixel, enough for the Read tool to take it as an image.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  'base64',
)

function post(id, request) {
  fs.mkdirSync(path.join(root, 'inbox'), { recursive: true })
  const temp = path.join(root, 'inbox', `${id}.tmp`)
  fs.writeFileSync(temp, JSON.stringify({ id, ...request }))
  fs.renameSync(temp, path.join(root, 'inbox', `${id}.json`))
}

const fakeApi = spawn(process.execPath, [path.join(here, 'fake-api.mjs')], { env, stdio: 'ignore' })
await sleep(500)

const output = fs.openSync(claudeLog, 'w')
const claude = spawn(
  claudeBin,
  ['-p', 'E2E-MAIN-TURN', '--plugin-dir', pluginDir, '--model', 'claude-haiku-5-5'],
  { env, cwd: home, stdio: ['ignore', output, output], shell: process.platform === 'win32' },
)
let claudeExited = false
claude.on('exit', () => (claudeExited = true))

let code = 1
try {
  const statusFile = await until('the session to report its status', () => {
    const name = listDir(path.join(root, 'sessions')).find(n => n.endsWith('.json'))
    if (!name) return undefined
    const file = path.join(root, 'sessions', name)
    return readJson(file)?.isBusy ? file : undefined
  })
  const status = readJson(statusFile)
  check('the session reports it is busy', status.isBusy === true, status.activity)
  check('the heartbeat is current', Date.now() - status.heartbeat < 15000)

  post('e2e-say', { kind: 'say', text: 'hi buddy', history: [] })
  const said = await until('a chat reply', () => readJson(path.join(root, 'outbox', 'e2e-say.json')))
  check('chat gets an answer', said.text === 'Hello friend! This is the test model.', said.text)

  fs.mkdirSync(path.join(root, 'shots'), { recursive: true })
  const shot = path.join(root, 'shots', 'e2e-look.png')
  fs.writeFileSync(shot, PNG)
  post('e2e-look', { kind: 'look', text: 'what do you see', image: shot, history: [] })
  const looked = await until('a look reply', () => readJson(path.join(root, 'outbox', 'e2e-look.json')), 120000)
  check('the eyes read the screenshot and answer', looked.text === 'I can see the test screen.', looked.text)

  fs.mkdirSync(path.join(root, 'shots'), { recursive: true })
  post('e2e-sneak', { kind: 'look', text: 'look', image: path.join(home, 'elsewhere.png'), history: [] })
  const sneak = await until('a refusal', () => readJson(path.join(root, 'outbox', 'e2e-sneak.json')))
  check('a look at any other file is refused', sneak.text.includes("couldn't find the screenshot"), sneak.text)

  const leftovers = listDir(path.join(root, 'inbox'))
  check('the inbox is left empty', leftovers.length === 0, leftovers.join(', '))

  fs.writeFileSync(releaseFile, 'done')
  await until('the session to end', () => claudeExited, 60000)
  await sleep(500)
  check('the session removes its status when it ends', !fs.existsSync(statusFile))
  code = failures.length ? 1 : 0
} catch (error) {
  console.log(`FAIL  ${error.message}`)
} finally {
  fs.writeFileSync(releaseFile, 'done')
  fakeApi.kill()
  claude.kill()
  if (code !== 0) {
    for (const [name, file] of [['fake api', apiLog], ['claude', claudeLog]]) {
      console.log(`---- ${name} log`)
      try {
        console.log(fs.readFileSync(file, 'utf8').slice(-4000))
      } catch {
        console.log('(none)')
      }
    }
  }
}
console.log(code === 0 ? 'ALL PASSED' : 'FAILED')
process.exit(code)
