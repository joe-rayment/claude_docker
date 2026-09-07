#!/usr/bin/env bats
#
# gha-workflows-lint.bats -- every GitHub Actions workflow under
# .github/workflows/ must pass actionlint.
#
# This exists because a file can be valid YAML and invalid Actions at the
# same time: `PROJECT: ${{ runner.temp }}/...` in a job-level `env:` block
# parses fine under python3 yaml.safe_load, but the `runner` context is not
# available there, so GitHub refused the whole workflow -- run 34068515697
# ended in 0 seconds with zero jobs. A YAML parse is not a workflow check;
# actionlint is.
#
# Unrelated to scripts/workflow-lint.sh and tests/workflows.bats, which lint
# the Workflow tool's agent scripts rather than GitHub Actions.

REPO_ROOT="${BATS_TEST_DIRNAME:-.}"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

@test "every .github/workflows/*.yml passes actionlint" {
  if ! command -v actionlint >/dev/null 2>&1; then
    skip "actionlint is not on PATH -- install it (https://github.com/rhysd/actionlint) to run this check"
  fi

  local -a workflows=()
  local f
  for f in "$REPO_ROOT"/.github/workflows/*.yml; do
    [ -e "$f" ] || continue
    workflows+=("$f")
  done

  [ "${#workflows[@]}" -gt 0 ]

  run actionlint "${workflows[@]}"
  if [ "$status" -ne 0 ]; then
    printf 'actionlint failed (exit %s):\n%s\n' "$status" "$output" >&2
  fi
  [ "$status" -eq 0 ]
}
