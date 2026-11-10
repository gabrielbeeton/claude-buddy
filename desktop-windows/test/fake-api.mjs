// A stand-in for the Claude API, so the whole path (real Claude Code, the real mod,
// the real desktop app) can be tested without an account. It answers Buddy's chat,
// walks Buddy's eyes through reading the screenshot, and holds the session's own
// turn open until RELEASE_FILE appears, which keeps the session alive for the test.
import fs from 'node:fs'
import http from 'node:http'

const port = Number(process.env.FAKE_API_PORT ?? 8765)
const releaseFile = process.env.RELEASE_FILE
const logFile = process.env.FAKE_API_LOG

export const CHAT_REPLY = 'Hello friend! This is the test model.'
export const EYES_REPLY = 'I can see the test screen.'

const log = line => {
  if (logFile) fs.appendFileSync(logFile, `${new Date().toISOString()} ${line}\n`)
}

const usage = { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 }
const message = (blocks, stop) => ({
  id: `msg_${Date.now()}`,
  type: 'message',
  role: 'assistant',
  model: 'fake-model',
  content: blocks,
  stop_reason: stop,
  stop_sequence: null,
  usage,
})

function sse(res, event, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify({ type: event, ...data })}\n\n`)
}

function streamBlocks(res, blocks, stop) {
  blocks.forEach((block, index) => {
    if (block.type === 'text') {
      sse(res, 'content_block_start', { index, content_block: { type: 'text', text: '' } })
      sse(res, 'content_block_delta', { index, delta: { type: 'text_delta', text: block.text } })
    } else {
      sse(res, 'content_block_start', { index, content_block: { type: 'tool_use', id: block.id, name: block.name, input: {} } })
      sse(res, 'content_block_delta', { index, delta: { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } })
    }
    sse(res, 'content_block_stop', { index })
  })
  sse(res, 'message_delta', { delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 1 } })
  sse(res, 'message_stop', {})
  res.end()
}

function startStream(res) {
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
  sse(res, 'message_start', { message: { ...message([], null), usage } })
}

function answer(res, body, blocks, stop) {
  if (body.stream) {
    startStream(res)
    streamBlocks(res, blocks, stop)
  } else {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify(message(blocks, stop)))
  }
}

const released = () => !releaseFile || fs.existsSync(releaseFile)

function holdThenAnswer(res, body) {
  const blocks = [{ type: 'text', text: 'done' }]
  if (body.stream) startStream(res)
  const timer = setInterval(() => {
    if (!released()) {
      if (body.stream) res.write('event: ping\ndata: {"type":"ping"}\n\n')
      return
    }
    clearInterval(timer)
    log('main turn released')
    if (body.stream) streamBlocks(res, blocks, 'end_turn')
    else {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify(message(blocks, 'end_turn')))
    }
  }, 500)
}

function textsOf(messages) {
  const texts = []
  for (const m of messages ?? []) {
    if (typeof m.content === 'string') texts.push(m.content)
    else for (const block of m.content ?? []) if (block.type === 'text') texts.push(block.text)
  }
  return texts
}

const hasToolResult = messages =>
  (messages ?? []).some(m => Array.isArray(m.content) && m.content.some(b => b.type === 'tool_result'))

const server = http.createServer((req, res) => {
  let raw = ''
  req.on('data', chunk => (raw += chunk))
  req.on('end', () => {
    const url = req.url ?? ''
    if (req.method !== 'POST' || !url.startsWith('/v1/messages')) {
      log(`${req.method} ${url}`)
      res.writeHead(200, { 'content-type': 'application/json' })
      return res.end('{"data":[],"has_more":false}')
    }
    if (url.startsWith('/v1/messages/count_tokens')) {
      res.writeHead(200, { 'content-type': 'application/json' })
      return res.end('{"input_tokens":1}')
    }
    const body = JSON.parse(raw)
    const all = JSON.stringify(body)
    if (all.includes('You are the eyes of Buddy')) {
      if (hasToolResult(body.messages)) {
        log('eyes: answering')
        return answer(res, body, [{ type: 'text', text: EYES_REPLY }], 'end_turn')
      }
      const found = textsOf(body.messages).join('\n').match(/Screenshot path: (.+)/)
      log(`eyes: reading ${found?.[1]}`)
      const read = { type: 'tool_use', id: `toolu_${Date.now()}`, name: 'Read', input: { file_path: found?.[1] ?? '' } }
      return answer(res, body, [read], 'tool_use')
    }
    if (all.includes('You are Buddy')) {
      log('chat: answering')
      return answer(res, body, [{ type: 'text', text: CHAT_REPLY }], 'end_turn')
    }
    if (all.includes('E2E-MAIN-TURN') && (body.tools?.length ?? 0) > 0) {
      log('main turn: holding')
      return holdThenAnswer(res, body)
    }
    log('other call: answering')
    return answer(res, body, [{ type: 'text', text: 'ok' }], 'end_turn')
  })
})

server.listen(port, '127.0.0.1', () => log(`listening on ${port}`))
