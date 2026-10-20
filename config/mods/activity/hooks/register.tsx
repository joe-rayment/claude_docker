import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { ActivityView } from '../types'

// The Activity pane (claude-orca-nnr): a one-page plain-English summary of what
// Claude Code is doing, beside the chat. The page is written by Haiku through
// the session's own client ($.model.complete); the template's scripts only
// build the request and shape the reply (scripts/activity-summarize.py
// --request / --reply) and draw the frame (scripts/activity.py --frame).
// Interactive sessions only: a headless session (claude -p, a worker) opens no
// pane, so no timer and no process ever starts there.

const PANE = 'activity'
const TICK_MS = 10_000 // redraw the frame
const SUMMARY_MS = 60_000 // ask for a new page
const MIN_GAP_MS = 20_000 // never two summarizer runs closer than this
const SCRIPT_TIMEOUT_MS = 30_000

const view = atom({ plugin: 'activity', key: 'view' } as const, {
  frame: '',
  isFailed: false,
} as ActivityView)

// Module state: timers, the pane's size (a render must not write state, so it
// leaves the size here) and the run bookkeeping. A hot reload drops them, and
// register runs again, which is fine: the next tick starts over.
let cwd = ''
let rows = 30
let cols = 70
let isRunning = false
let lastRun = 0
let lastSize = ''
let isSized = false // no summary until the pane has drawn once and told us its size
let timers: Timer[] = []
let ticks = 0

type Ctx = EngineInterface

const script = ($: Ctx, name: string) => `${$.plugin.root}/../../../scripts/${name}`

async function py($: Ctx, name: string, args: string[], stdin?: string): Promise<string> {
  try {
    const ran = await $.process.run(['python3', script($, name), ...args], {
      cwd: cwd || undefined,
      stdin,
      timeoutMs: SCRIPT_TIMEOUT_MS,
    })
    return ran.exitCode === 0 ? ran.stdout : ''
  } catch {
    return ''
  }
}

const sizeArgs = () => ['--rows', String(rows), '--cols', String(cols)]

async function showFrame($: Ctx, isFailed = false) {
  const out = await py($, 'activity.py', ['--frame', ...sizeArgs()])
  // The viewer's own footer ("... · q quits") means nothing in a pane.
  const frame = out.replace(/\s*·\s*q quits\s*$/, '').replace(/\s+$/, '')
  await update($, view, () => ({ frame, isFailed: isFailed || frame === '' }))
}

// One cycle: build the request, ask Haiku through the session's client, file
// the reply, then redraw. Any failure files an empty reply, which writes the
// deterministic page and backs off, so the pane never shows a blank.
async function summarize($: Ctx) {
  const size = sizeArgs()
  let isFailed = false
  try {
    const out = await py($, 'activity-summarize.py', ['--request', ...size])
    const req = out ? (JSON.parse(out.trim().split('\n').pop() ?? '{}') as Record<string, unknown>) : {}
    if (req.status === 'request') {
      let text = ''
      let why = 'the summary model did not answer'
      try {
        const answer = await $.model.complete({
          model: 'haiku',
          system: String(req.system ?? ''),
          prompt: String(req.user ?? ''),
          maxTokens: Number(req.max_tokens) || 600,
        })
        if (answer.isAnswered) text = answer.text
        else why = `the summary model did not answer (${String(answer.reason)})`
      } catch {
        // fall through with the empty reply
      }
      await py(
        $,
        'activity-summarize.py',
        ['--reply', '--model', 'haiku', ...(text.trim() ? [] : ['--why', why]), ...size],
        text,
      )
    } else if (out === '') {
      isFailed = true
    }
  } catch {
    isFailed = true
  }
  lastSize = size.join(' ')
  await showFrame($, isFailed)
}

async function isPlaced($: Ctx): Promise<boolean> {
  try {
    return (await $.ui.panes()).some(pane => pane.id === PANE && pane.isPlaced)
  } catch {
    return false
  }
}

async function tick($: Ctx, isSummaryDue: boolean) {
  if (!isSized || !(await isPlaced($))) return
  ticks += 1
  const now = Date.now()
  const isStale = lastSize !== sizeArgs().join(' ')
  const canRun = !isRunning && now - lastRun >= MIN_GAP_MS
  if (canRun && (lastRun === 0 || isSummaryDue || isStale)) {
    isRunning = true
    lastRun = now
    try {
      await summarize($)
    } finally {
      isRunning = false
      lastRun = Date.now()
    }
  } else if (!isRunning) {
    await showFrame($)
  }
}

function start($: Ctx) {
  stop()
  timers = [
    $.clock.every(TICK_MS, () => void tick($, false)),
    $.clock.every(SUMMARY_MS, () => void tick($, true)),
  ]
  void tick($, true)
}

function stop() {
  for (const timer of timers) timer.cancel()
  timers = []
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    if (e.isInteractive) {
      cwd = e.cwd
      await $.command.register({
        name: 'activity',
        description: 'Open the Activity pane: a plain-English summary of what Claude Code is doing',
      })
      lastRun = 0
      // On a narrow terminal the pane waits undrawn; every tick is a no-op until it is placed.
      void $.ui.open({ id: PANE, title: 'Activity' })
      start($)
    }

    return next(e)
  })

  on('command.run', { command: 'activity' }, async $ => {
    lastRun = 0
    await $.ui.open({ id: PANE, title: 'Activity' })
    start($)

    return { text: 'Activity pane opened.' }
  })

  on('ui.close', { id: PANE }, async ($, e, next) => {
    stop()

    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    rows = Math.max(4, e.props.scroll.bodyRows)
    cols = Math.max(20, e.props.bodyColumns)
    isSized = true
    const { frame, isFailed } = await read($, view)
    if (frame === '') {
      return (
        <Text dimColor>
          {isFailed ? 'Could not read what Claude Code is doing.' : 'Reading what Claude Code is doing…'}
        </Text>
      )
    }

    return (
      <Box flexDirection="column">
        {frame.split('\n').map(line => (
          <Text wrap="truncate">{line}</Text>
        ))}
      </Box>
    )
  })
}
