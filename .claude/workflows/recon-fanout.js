// .claude/workflows/recon-fanout.js — named Workflow.
//
// Fans a set of independent recon questions out to one scout-grade
// agent() call per question, in parallel, each returning typed findings
// anchored to file:line. Invoke via the Workflow tool with:
//
//   { questions: ["where is X configured?", "who calls Y?"], glob: "src/**/*.ts" }
//
// `glob`, if given, narrows the search scope named in each question's
// prompt; it is advisory (the agent still searches wherever it needs to
// answer honestly) rather than a hard filter enforced by this script.
//
// `args` is the Workflow tool's own global carrying this script's
// invocation input — there is no function-parameter entry point. The
// `typeof args !== 'undefined'` guard below keeps a plain `import()` of
// this module (e.g. tests/workflows.bats's meta-shape check) side-effect
// free: outside the Workflow tool, `args`/`agent`/`phase`/`pipeline`/
// `log` are never dereferenced, so loading the module never throws.

export const meta = {
  name: 'recon-fanout',
  description:
    'Fan out independent recon questions to one scout-grade agent() call ' +
    'per question, each returning typed findings anchored to file:line.',
  phases: ['Recon'],
};

// JSON-Schema-shaped: one result per question, each a list of concrete
// file:line findings (or an explicit negative result — "found nowhere" is
// as valuable as a hit, and must be stated rather than guessed).
const FINDING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['question', 'findings', 'negative'],
  properties: {
    question: { type: 'string' },
    negative: { type: 'boolean' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['file', 'line', 'note'],
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          note: { type: 'string' },
        },
      },
    },
  },
};

function reconPrompt(question, glob) {
  const scope = glob ? `Scope your search to files matching: ${glob}.\n` : '';
  return (
    'You are doing read-only recon for an orchestrator that will act on ' +
    'your findings without re-reading the files itself.\n' +
    scope +
    `Question: ${question}\n` +
    'Answer with concrete file:line references for every claim. If the ' +
    'answer is genuinely absent, set negative: true and say so rather ' +
    'than guessing.'
  );
}

if (typeof args !== 'undefined') {
  const { questions, glob } = args || {};
  if (!Array.isArray(questions) || questions.length === 0) {
    throw new Error('recon-fanout: args.questions must be a non-empty array of strings');
  }

  phase('Recon');

  const results = await pipeline(questions, (question) =>
    agent(reconPrompt(question, glob), {
      model: 'haiku',
      phase: 'Recon',
      schema: FINDING_SCHEMA,
      label: `recon: ${question}`,
    })
  );

  log(JSON.stringify({ questionCount: questions.length, results: results.filter(Boolean) }, null, 2));
}
