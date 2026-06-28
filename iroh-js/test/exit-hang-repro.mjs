// Reproduction for the downstream "exit 144 / SIGTERM at process teardown" bug.
//
// ROOT CAUSE (reproduced on Linux): a napi *async* method whose returned
// promise is never awaited / never resolves leaves a pending
// `napi_resolve_deferred` async resource that REFS the libuv event loop, so
// Node can never drain its loop and exit on its own. The host process then
// hangs at teardown and is killed by an external timeout (tinypool / vitest /
// CI) -> 128 + SIGTERM(15) = 144.
//
// Two things make this hard to find downstream, both confirmed here:
//   1. The ref is INVISIBLE to process._getActiveHandles()/_getActiveRequests()
//      (they report []), which is why the usual handle dump found nothing.
//   2. It only needs a worker that actually loaded the native module AND left
//      one such call dangling — pure-JS unresolved promises do NOT pin libuv.
//
// It IS visible via async_hooks as a live `napi_resolve_deferred` (see the
// `diagnose` scenario) — that is how to locate the exact offending call in a
// real test suite (or use the `why-is-node-running` package).
//
// Usage:
//   node test/exit-hang-repro.mjs <scenario>
// Scenarios (parent measures whether the child exits on its own in N seconds):
//   clean-bind-close   bind + close                -> exits 0   (control)
//   clean-bind-noclose bind, no close               -> exits 0   (control)
//   hang-online        ep.online() not awaited      -> HANG
//   hang-online-close  ep.online() then ep.close()  -> HANG (close does NOT cancel online())
//   hang-accept        ep.acceptNext() not awaited  -> HANG
//   ok-accept-close    ep.acceptNext() then close() -> exits 0 (close cancels acceptNext())
//   diagnose           show the async_hooks resource that pins the loop
//
// With no scenario, runs the whole matrix as a parent harness.
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname } from 'node:path'
import { createRequire } from 'node:module'

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)
const require = createRequire(import.meta.url)

const scenario = process.argv[2]

async function buildMinimal(iroh) {
  const b = iroh.Endpoint.builder()
  iroh.presetMinimal(b)
  b.alpns([Array.from(Buffer.from('exit-hang-repro/0'))])
  return await b.bind()
}

async function child(scenario) {
  const iroh = require('../index.js')
  const ep = await buildMinimal(iroh)
  switch (scenario) {
    case 'clean-bind-close':
      await ep.close()
      break
    case 'clean-bind-noclose':
      break
    case 'hang-online':
      ep.online().then(() => {}, () => {}) // fire-and-forget; never resolves offline
      break
    case 'hang-online-close':
      ep.online().then(() => {}, () => {})
      await ep.close() // does NOT cancel the pending online()
      break
    case 'hang-accept':
      ep.acceptNext().then(() => {}, () => {})
      break
    case 'ok-accept-close':
      ep.acceptNext().then(() => {}, () => {})
      await ep.close() // close() makes acceptNext() resolve(None) -> loop released
      break
    default:
      throw new Error(`unknown scenario ${scenario}`)
  }
  // No process.exit(): the whole point is to observe natural event-loop drain.
}

async function diagnose() {
  const async_hooks = await import('node:async_hooks')
  const iroh = require('../index.js')
  const alive = new Map()
  const hook = async_hooks.createHook({
    init: (id, type) => alive.set(id, type),
    destroy: (id) => alive.delete(id),
    promiseResolve: (id) => alive.delete(id),
  })
  hook.enable()
  const ep = await buildMinimal(iroh)
  ep.online().then(() => {}, () => {}) // the offender
  setTimeout(() => {
    hook.disable()
    const counts = {}
    for (const t of alive.values()) counts[t] = (counts[t] || 0) + 1
    console.log('still-alive async resources pinning the loop:', JSON.stringify(counts))
    console.log('--> `napi_resolve_deferred` is the invisible ref from the dangling async call.')
    process.exit(0)
  }, 300)
}

const ALL = [
  'clean-bind-close',
  'clean-bind-noclose',
  'hang-online',
  'hang-online-close',
  'hang-accept',
  'ok-accept-close',
]
const DEADLINE_MS = 4000

function runChild(spec) {
  return new Promise((resolve) => {
    const start = Date.now()
    const c = spawn(process.execPath, [__filename, spec], { stdio: ['ignore', 'ignore', 'ignore'] })
    let timedOut = false
    const t = setTimeout(() => {
      timedOut = true
      c.kill('SIGTERM')
    }, DEADLINE_MS)
    c.on('exit', (code, signal) => {
      clearTimeout(t)
      resolve({ spec, ms: Date.now() - start, code, signal, timedOut })
    })
  })
}

if (scenario === 'diagnose') {
  await diagnose()
} else if (scenario) {
  await child(scenario)
} else {
  const results = []
  for (const s of ALL) results.push(await runChild(s))
  console.log('\n==================== exit-hang matrix ====================')
  for (const r of results) {
    const v = r.timedOut ? `HANG -> SIGTERM after ${r.ms}ms` : `clean exit code=${r.code} in ${r.ms}ms`
    console.log(`${r.spec.padEnd(20)} ${v}`)
  }
  console.log('\nRun `node test/exit-hang-repro.mjs diagnose` to see the invisible pin.')
  process.exitCode = results.some((r) => r.timedOut) ? 1 : 0
}
