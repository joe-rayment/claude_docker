import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { ActivityView } from '../types'

// The Activity pane (claude-orca-nnr): a one-page plain-English summary of what
// Claude Code is doing, in a narrow sidebar beside the chat. The page is
// written by Haiku through the session's own client ($.model.complete); the
// template's scripts only build the request and shape the reply
// (scripts/activity-summarize.py --request / --reply) and lay out the page
// (scripts/activity.py --frame).
//
// It changes only when a turn of the main chat ends -- never on a timer -- so
// nothing is spent while nothing happens, and the text holds still while the
// person reads it. ctrl+q (config/claude-keybindings.json) or /activity
// toggles it; hidden, it is fully off: no summary, no model call, and it opens
// again on the one-line intro, keeping nothing. Interactive sessions only: a
// headless one (claude -p, a worker) opens no pane, so no process starts there.

const PANE = 'activity'
const SCRIPT_TIMEOUT_MS = 30_000
const SETTLE_MS = 2_000 // after a turn ends, before its transcript is read
const SIDEBAR_COLS = 44 // a narrow sidebar on the right (docks only under the fullscreen tui)
const OPEN = { id: PANE, title: 'Activity', columns: SIDEBAR_COLS }

const INTRO = 'What Claude is doing, after each reply.'
const HINT = ['ctrl+q hides this']

const view = atom({ plugin: 'activity', key: 'view' } as const, {
  frame: '',
  isFailed: false,
} as ActivityView)

// Module state: whether the pane is open, the pane's size (a render must not
// write state, so it leaves the size here) and the run bookkeeping. A hot
// reload drops them and session.start sets them again.
type Ctx = EngineInterface
let isOpen = false
let cwd = ''
let rows = 30
let cols = SIDEBAR_COLS
let isRunning = false
let isOwed = false // a turn ended while a summary was running

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

// The hint and the blank row above it take the pane's last rows; the page gets the rest.
const sizeArgs = () => ['--rows', String(Math.max(4, rows - HINT.length - 1)), '--cols', String(cols)]

async function showFrame($: Ctx, isFailed: boolean) {
  const out = await py($, 'activity.py', ['--frame', ...sizeArgs()])
  // Drop the viewer's own footer ("updated 40 s ago · haiku · q quits"): the
  // pane does not redraw on a clock, so an age would only go stale, and it is
  // not closed with q. The hint line takes its place.
  const lines = out.replace(/\s+$/, '').split('\n')
  if (/q quits\s*$/.test(lines[lines.length - 1] ?? '')) lines.pop()
  const frame = lines.join('\n').replace(/\s+$/, '')
  await update($, view, () => ({ frame, isFailed: isFailed || frame === '' }))
}

// One cycle: build the request, ask Haiku through the session's client, file
// the reply, then lay the page out. A failed call files an empty reply, which
// writes the deterministic page and backs off, so the pane never goes blank.
async function summarize($: Ctx) {
  const size = sizeArgs()
  let isFailed = false
  try {
    const out = await py($, 'activity-summarize.py', ['--request', ...size])
    const req = out ? (JSON.parse(out.trim().split('\n').pop() ?? '{}') as Record<string, unknown>) : {}
    if (req.status === 'unchanged' || req.status === 'busy') return
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
  await showFrame($, isFailed)
}

async function isPlaced($: Ctx): Promise<boolean> {
  try {
    return (await $.ui.panes()).some(pane => pane.id === PANE && pane.isPlaced)
  } catch {
    return false
  }
}

// Summarize once, now -- nothing at all while the pane is hidden, or placed
// nowhere (a terminal too narrow to seat it). Turns that end during a run
// make one more run once it is done.
async function refresh($: Ctx) {
  if (!isOpen || !(await isPlaced($))) return
  if (isRunning) {
    isOwed = true
    return
  }
  isRunning = true
  isOwed = false
  try {
    await summarize($)
  } finally {
    isRunning = false
  }
  if (isOwed && isOpen) void refresh($)
}

async function show($: Ctx) {
  isOpen = true
  isOwed = false
  await update($, view, () => ({ frame: '', isFailed: false }))
  // On a terminal under 144 columns (110 once asked) the pane waits undrawn.
  await $.ui.open(OPEN)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    if (e.isInteractive) {
      cwd = e.cwd
      await $.command.register({
        name: 'activity',
        description: 'Show or hide the Activity sidebar (ctrl+q)',
      })
      await show($)
    }

    return next(e)
  })

  // The only trigger: the end of a main-chat turn. A subagent's turn
  // (agentId set) is part of the main turn that spawned it. The summary runs
  // from a timer of its own so it outlives this hook's dispatch, a moment
  // after the end so the turn's last message is in the transcript it reads.
  on('turn.complete', async ($, e, next) => {
    const ended = await next(e)
    if (isOpen && e.agentId === undefined) $.clock.after(SETTLE_MS, () => void refresh($))

    return ended
  })

  // A toggle, quiet either way: the sidebar appearing or going is the answer.
  on('command.run', { command: 'activity' }, async $ => {
    if (isOpen) await $.ui.close({ id: PANE })
    else await show($)

    return {}
  })

  // However it goes (this toggle, the pane's own close mark), hidden is off.
  on('ui.close', { id: PANE }, async ($, e, next) => {
    isOpen = false
    isOwed = false

    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    rows = Math.max(4, e.props.scroll.bodyRows)
    cols = Math.max(20, e.props.bodyColumns)
    const { frame, isFailed } = await read($, view)
    const body =
      frame !== ''
        ? frame.split('\n').map(line => <Text>{line}</Text>)
        : isFailed
          ? [<Text dimColor>Could not read what Claude Code is doing.</Text>]
          : [<Text dimColor>{INTRO}</Text>]

    return (
      <Box flexDirection="column" flexGrow={1}>
        <Box flexDirection="column" flexGrow={1}>
          {body}
        </Box>
        <Text> </Text>
        {HINT.map(line => (
          <Text dimColor>{line}</Text>
        ))}
      </Box>
    )
  })
}
