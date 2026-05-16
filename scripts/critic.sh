#!/usr/bin/env bash
# critic.sh - independent cold-read reviewer for a story's plan OR diff.
#
# Usage:
#   ./scripts/critic.sh <story_id> <spec> [model] [persona] [target]
#
# Arguments:
#   story_id  - the story ID (for logging)
#   spec      - the spec text from PRD
#   model     - model to use (default: sonnet)
#   persona   - one of: generalist (default) | architect | secops | qa
#               Used by council.sh for multi-critic review. Each persona has
#               specialized framing — see CRITIC_PERSONAS below.
#   target    - one of: diff (default) | plan
#               diff = review `git diff HEAD`
#               plan = review .loopguard/plan.iter-N.md (Plan-first mode)
#
# Env vars:
#   PLAN_FILE - required when target=plan. Path to plan markdown.
#
# Stdout: first line is "PASS" or "FAIL: ...", then structured violations.
# Exit 0 always (loop reads stdout). Exit 1 on internal error only.
#
# Cold-read via `claude -p --bare` — strips auto-memory, hooks, CLAUDE.md.
# Borrowed pattern from asdlc.io adversarial review + MAVEN Skeptic-Researcher-Judge.

set -euo pipefail

STORY_ID="${1:?story id required}"
SPEC="${2:?spec required}"
MODEL="${3:-sonnet}"
PERSONA="${4:-generalist}"
TARGET="${5:-diff}"

# ─── Persona framing (council pattern from asdlc.io / Apex-CodeGenesis) ──────
case "$PERSONA" in
  generalist)
    PERSONA_BRIEF="You are a general code reviewer. Find ANY problems in the diff against the spec: spec deviations, bugs, scope creep, security issues."
    PERSONA_FOCUS="all three classes equally"
    ;;
  architect)
    PERSONA_BRIEF="You are an ARCHITECT reviewer. Your focus is design integrity, scope discipline, and abstraction quality. Other reviewers handle bugs and security."
    PERSONA_FOCUS="- Speculative abstractions or 'just in case' generality
- Refactors or cleanup not required by the spec
- New abstractions when the spec asked for a concrete change
- Dependencies added beyond what the spec authorized
- 'while I'm here' improvements to unrelated code
- Files touched that the spec didn't mention even if technically in the whitelist"
    ;;
  secops)
    PERSONA_BRIEF="You are a SECURITY reviewer. Your focus is exploitability. Other reviewers handle correctness and design."
    PERSONA_FOCUS="- Command injection (shell, SQL, NoSQL, template, LDAP)
- Path traversal / file write outside intended directory
- Auth bypass (missing checks, hardcoded creds, jwt mishandling)
- Secret exposure (env vars, tokens, keys leaked to logs/files/responses)
- Missing input validation at trust boundaries
- Unsafe deserialization, prototype pollution, ReDoS
- CSRF, XSS, SSRF in web code
- Dependency vulnerabilities introduced"
    ;;
  qa)
    PERSONA_BRIEF="You are a QA reviewer. Your focus is correctness and edge cases. Other reviewers handle design and security."
    PERSONA_FOCUS="- Off-by-one, fencepost errors
- Null/undefined dereference
- Race conditions, ordering bugs, async errors
- Missing edge cases the spec implies (empty input, max boundary, unicode, negative numbers, concurrent calls)
- Broken error paths (catch-and-ignore, wrong error type bubbled up)
- Test coverage gaps for the new behavior
- Logic that 'looks like' it implements the spec but actually doesn't for certain inputs"
    ;;
  *)
    echo "FAIL: unknown persona '$PERSONA'" >&2
    exit 1
    ;;
esac

# ─── Build the material to review ────────────────────────────────────────────
if [[ "$TARGET" == "plan" ]]; then
  PLAN_FILE="${PLAN_FILE:?PLAN_FILE env var required when target=plan}"
  if [[ ! -f "$PLAN_FILE" ]]; then
    echo "FAIL: plan file not found at $PLAN_FILE"
    exit 0
  fi
  material=$(cat "$PLAN_FILE")
  material_type="PLAN (no code yet — this is the builder's stated intent)"
  what_to_find="The plan should clearly enumerate: which files will be modified, what each change is, and how each acceptance criterion will be satisfied. Reject the plan if it is vague, over-scoped, or proposes changes beyond the spec."
else
  material=$(git diff HEAD 2>/dev/null || git diff)
  if [[ -z "$material" ]]; then
    echo "FAIL: no diff to review (builder produced no changes)"
    exit 0
  fi
  # Cap to keep critic cheap — 5000-line diff is itself a red flag.
  if [[ $(echo "$material" | wc -l) -gt 5000 ]]; then
    truncated=$(echo "$material" | head -5000)
    material="$truncated"$'\n\n[... diff truncated at 5000 lines — this alone is grounds for FAIL ...]'
  fi
  material_type="DIFF (git diff HEAD output)"
  what_to_find="The diff should implement the spec and nothing else. No refactors, no cleanup, no while-I-am-here improvements."
fi

# ─── Build the prompt ────────────────────────────────────────────────────────
IFS='' read -r -d '' prompt <<PROMPT || true
You are an INDEPENDENT code reviewer. You have NOT seen the builder work or any prior conversation. You cold-read a $material_type against a spec.

$PERSONA_BRIEF

Your bias is toward FAIL when in doubt. The builder gets another iteration if you fail it. You are not blocking forever. Favor false positives over false negatives.

## Story
ID: $STORY_ID

## Spec (the only thing the material should reflect)
$SPEC

## $material_type to review
<MATERIAL>
$material
</MATERIAL>

## Your specialized focus
$what_to_find

Specifically look for:
$PERSONA_FOCUS

## Output format (strict — the loop parses this)

Line 1 (mandatory): exactly one of
  VERDICT: PASS
  VERDICT: FAIL

If FAIL, then 1-5 structured violations in this format (one per finding):

  ## Violation N
  - file:line   <where (use spec.md if review target is plan)>
  - severity    <blocker | should-fix>
  - what        <one-line description of the defect>
  - why         <one-line impact: why it matters>
  - fix         <one-line suggested remediation>

If PASS, write a single short paragraph confirming the spec is satisfied and there are no findings in your specialty. Do not invent objections to look thorough.

## What NOT to flag
- Style, naming, comment-vs-no-comment, formatting (unless the spec required it)
- 'I would have done it differently' — only flag actual defects in your specialty
- Hypothetical future problems — only real, current defects
- Suggestions to add tests beyond what the spec required (unless you are the QA persona and the spec implies test coverage)

If the material is clean: VERDICT: PASS. Do not invent objections.
PROMPT

# ─── Run the critic in a hermetic, tool-free session ────────────────────────
output=$(claude -p "$prompt" \
  --model "$MODEL" \
  --bare \
  --disallowedTools "Edit,Write,Bash,Read" \
  --no-session-persistence \
  --output-format text \
  --max-budget-usd 1.50 2>&1) || {
  echo "FAIL: critic invocation failed"
  echo "$output" | head -3
  exit 0
}

# ─── Parse verdict ───────────────────────────────────────────────────────────
verdict_line=$(echo "$output" | grep -mE '^VERDICT:' | head -1)
if [[ -z "$verdict_line" ]]; then
  echo "FAIL: critic [$PERSONA] did not produce a parseable verdict"
  echo
  echo "$output" | head -20
  exit 0
fi

# Strip "VERDICT: " prefix so the loop's "^PASS" check works.
if [[ "$verdict_line" =~ ^VERDICT:\ *(.*)$ ]]; then
  echo "[$PERSONA] ${BASH_REMATCH[1]}"
else
  echo "[$PERSONA] $verdict_line"
fi
echo
# Print remainder (violations or PASS reasoning), cap at 60 lines to keep
# failure_ctx in progress.md from ballooning.
echo "$output" | grep -v '^VERDICT:' | head -60
exit 0
