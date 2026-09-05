#!/usr/bin/env node
//
// Validates a generated srt settings file against the pinned
// @anthropic-ai/sandbox-runtime zod schema -- used by
// tests/sandbox-config.bats (S2, claude-orca-3sk.14) so "the JSON looks
// right" is checked against the real package's own SandboxRuntimeConfigSchema,
// not our own understanding of its shape. Run with the REAL node (see
// ensure_real_srt/$ORIGINAL_PATH in tests/helpers/setup.bash), never the
// bats stub.
//
// Usage: node validate-srt-schema.mjs <path-to-sandbox-runtime/dist/index.js> <path-to-settings.json>

import { readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const [, , indexPath, settingsPath] = process.argv

if (!indexPath || !settingsPath) {
  console.error('usage: validate-srt-schema.mjs <index.js> <settings.json>')
  process.exit(2)
}

const { SandboxRuntimeConfigSchema } = await import(pathToFileURL(indexPath).href)
const settings = JSON.parse(readFileSync(settingsPath, 'utf8'))
const result = SandboxRuntimeConfigSchema.safeParse(settings)

if (!result.success) {
  console.error(result.error.message)
  process.exit(1)
}

console.log('VALID')
