// .claude/workflows/verify-contracts.js — named Workflow.
//
// Runs the independent Verifier's five mechanical checks (C1-C5) plus C2b
// against one or more beads' pre-registered acceptance contracts, one
// top-tier agent() call per bead, per knowledge-base/ACCEPTANCE_CONTRACTS.md.
// Invoke via the Workflow tool with:
//
//   { beads: [{ id: "proj-abc", redAt: "<sha>", greenAt: "<sha>" }, ...] }
//
// `args` is the Workflow tool's own global carrying this script's
// invocation input — there is no function-parameter entry point. The
// `typeof args !== 'undefined'` guard below keeps a plain `import()` of
// this module (e.g. tests/workflows.bats's meta-shape check) side-effect
// free: outside the Workflow tool, `args`/`agent`/`phase`/`pipeline`/
// `log` are never dereferenced, so loading the module never throws.

export const meta = {
  name: 'verify-contracts',
  description:
    'Run the five mechanical acceptance-contract checks (C1-C5) plus C2b ' +
    'against one or more beads, one verifier-grade agent() call per bead.',
  phases: ['Verify'],
};

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['id', 'verdict', 'checks', 'summary'],
  properties: {
    id: { type: 'string' },
    verdict: { type: 'string', enum: ['PASS', 'FAIL', 'TAMPERED', 'NO-CONTRACT'] },
    checks: {
      type: 'object',
      additionalProperties: false,
      required: ['C1', 'C2', 'C2b', 'C3', 'C4', 'C5'],
      properties: {
        C1: { type: 'string' },
        C2: { type: 'string' },
        C2b: { type: 'string' },
        C3: { type: 'string' },
        C4: { type: 'string' },
        C5: { type: 'string' },
      },
    },
    summary: { type: 'string' },
  },
};

function verifyPrompt(bead) {
  return (
    "You are the independent Verifier for one bead's pre-registered " +
    'acceptance contract, per knowledge-base/ACCEPTANCE_CONTRACTS.md.\n' +
    `Bead: ${bead.id}\n` +
    `RED-AT: ${bead.redAt}\n` +
    `GREEN-AT: ${bead.greenAt}\n` +
    'Run, and report evidence for, each of: C1 goalposts unmoved (bd ' +
    'history acceptance_criteria is unique); C2 frozen test not weakened ' +
    '(git diff RED-AT..HEAD on the FROZEN paths is empty); C2b red ' +
    'actually red (re-root CHECK into a disposable worktree at RED-AT, ' +
    'confirm it fails); C3 actually green (CHECK verbatim, clean tree); ' +
    'C4 honest (read the implementation diff excluding FROZEN paths for ' +
    'hardcoding, skips, or env detection); C5 not lazily closed (no ' +
    'human hand-off, no silently narrowed scope). ' +
    'Return exactly one verdict: PASS, FAIL, TAMPERED, or NO-CONTRACT.'
  );
}

if (typeof args !== 'undefined') {
  const { beads } = args || {};
  if (!Array.isArray(beads) || beads.length === 0) {
    throw new Error('verify-contracts: args.beads must be a non-empty array of {id, redAt, greenAt}');
  }

  phase('Verify');

  const verdicts = await pipeline(beads, (bead) =>
    agent(verifyPrompt(bead), {
      model: 'fable',
      phase: 'Verify',
      schema: VERDICT_SCHEMA,
      label: `verify: ${bead.id}`,
    })
  );

  log(JSON.stringify({ beadCount: beads.length, verdicts: verdicts.filter(Boolean) }, null, 2));
}
