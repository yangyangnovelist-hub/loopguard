#!/usr/bin/env bash
# critic.sh - independent cold-read reviewer for a single story's diff.
#
# Usage:
#   ./scripts/critic.sh <story_id> <spec> [model]
#
# Stdout: first line is "PASS: ..." or "FAIL: ...", followed by reasoning.
# Exit 0 always (the loop reads stdout to decide). Exit 1 only on internal error.
#
# Runs `claude -p --bare` so the critic has NO auto-memory, NO hooks, NO prior
# context. It cold-reads spec + diff only. This is the key to escaping the
# single-agent blind spot.

set -euo pipefail

STORY_ID="${1:?story id required}"
SPEC="${2:?spec required}"
MODEL="${3:-sonnet}"

diff_content=$(git diff HEAD 2>/dev/null || git diff)
if [[ -z "$diff_content" ]]; then
  echo "FAIL: no diff to review (builder produced no changes)"
  exit 0
fi

# Cap diff size — over 5000 lines is a red flag anyway; truncate to keep critic cheap.
if [[ $(echo "$diff_content" | wc -l) -gt 5000 ]]; then
  truncated=$(echo "$diff_content" | head -5000)
  diff_content="$truncated"$'\n\n[... diff truncated at 5000 lines — this alone is grounds for FAIL ...]'
fi

IFS='' read -r -d '' prompt <<PROMPT || true
You are an INDEPENDENT code reviewer. You have NOT seen the builder's work or any prior conversation. You are cold-reading a diff against a spec.

Your bias is toward FAIL when in doubt. The builder gets another iteration if you fail it — you are not blocking forever. Be conservative.

## Story
ID: $STORY_ID

## Spec (the only thing the diff should implement)
$SPEC

## Diff to review (everything between the DIFF tags)
<DIFF>
$diff_content
</DIFF>

## Find three classes of problem

1. **Spec deviation** — does the diff actually implement the spec, or only "look like" it?
2. **Real bugs** — off-by-one, null deref, race, missing edge case, broken error path, security issue (injection, auth bypass, secret leak)
3. **Scope creep** — anything in the diff NOT required by the spec. Refactors, unrelated fixes, "while I'm here" improvements, speculative abstractions, dead code, new dependencies the spec didn't authorize.

## Output format (strict)

Reply with EXACTLY this format:

VERDICT: PASS
or
VERDICT: FAIL — <one-line reason>

Then 1-3 short paragraphs of reasoning. Cite specific file:line where possible.

## What NOT to flag

- Style, naming, comment-vs-no-comment, formatting (unless the spec required it)
- "I would have done it differently" — only flag actual defects
- Hypothetical future problems — only flag real, current defects
- Suggestions to add tests beyond what the spec required

If the diff cleanly implements the spec with no bugs and no scope creep: VERDICT: PASS. Don't invent objections to look thorough.
PROMPT

# --bare strips auto-memory, hooks, CLAUDE.md auto-load — pure cold read.
# --disallowedTools "*" prevents the critic from accidentally writing files.
# --no-session-persistence keeps it ephemeral.
output=$(claude -p "$prompt" \
  --model "$MODEL" \
  --bare \
  --disallowedTools "Edit,Write,Bash,Read" \
  --no-session-persistence \
  --output-format text \
  --max-budget-usd 1.50 2>&1) || {
  echo "FAIL: critic invocation failed: $output" | head -3
  exit 0
}

# Normalize: prefer first line starting with VERDICT or PASS/FAIL.
verdict_line=$(echo "$output" | grep -mE '^(VERDICT:|PASS|FAIL)' | head -1)
if [[ -z "$verdict_line" ]]; then
  # Critic didn't follow format — treat as FAIL with the raw output for context.
  echo "FAIL: critic did not produce a parseable verdict"
  echo
  echo "$output" | head -20
  exit 0
fi

# Strip "VERDICT: " prefix if present, so the loop's "^PASS" check works.
if [[ "$verdict_line" =~ ^VERDICT:\ *(.*)$ ]]; then
  echo "${BASH_REMATCH[1]}"
else
  echo "$verdict_line"
fi
echo
echo "$output" | grep -v -E '^(VERDICT:|PASS|FAIL)' | head -40
exit 0
