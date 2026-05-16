#!/usr/bin/env bash
# loopguard - bounded autonomous Claude Code dev loop
#
# Usage:
#   PRD=./prd.json ./scripts/loopguard.sh
#
# Env vars (all optional):
#   PRD                  Path to PRD JSON (default: ./prd.json)
#   MAX_ITER             Hard iter cap (default: 20)
#   MAX_COST_USD         Total $ cap (default: 15)
#   MAX_DURATION_S       Wall-clock cap in seconds (default: 10800 = 3h)
#   MAX_CALLS_PER_HOUR   Rate limit on claude invocations (default: 60)
#                        Pattern from frankbria/ralph-claude-code: prevents
#                        fast iters from blowing through hourly quota even
#                        when $ cap looks fine.
#   STATE_DIR            Where logs/state live (default: ./.loopguard)
#   LEARNINGS_FILE       Cumulative codebase knowledge (default: $STATE_DIR/LEARNINGS.md)
#                        Pattern from snarktank/ralph: separate from failure
#                        log. Each passing iter appends what was non-obvious
#                        about the codebase. Future iters see it prepended.
#   VERIFY_SCRIPT        Programmatic exit gate (default: ./scripts/verify.sh)
#   CRITIC_SCRIPT        Independent reviewer (default: ./scripts/critic.sh)
#   COUNCIL_SCRIPT       Multi-critic council (default: ./scripts/council.sh)
#   CRITIC_COUNCIL       Comma-separated personas, e.g. "architect,secops,qa"
#                        If set, uses council.sh (parallel critics, AND-aggregated).
#                        If empty (default), uses single generalist critic.
#                        Pattern from asdlc.io adversarial review + MAVEN paper.
#   SCOPE_SCRIPT         Scope guard (default: ./scripts/scope-check.sh)
#   THRASH_SCRIPT        Anti-thrash (default: ./scripts/thrash-detect.sh)
#   BUILDER_MODEL        Model for builder (default: sonnet)
#   CRITIC_MODEL         Model for critic (default: sonnet — use different where possible)
#   ALLOWED_TOOLS        Tool gate for builder (default: "Edit,Read,Write,Bash")
#   AUTO_COMMIT          Commit after each passing iter (default: 1; set 0 to skip)
#
# Exits:
#   0 — done: all stories passed or nothing pending
#   1 — soft halt: hit iter / cost / duration / rate cap; resume by re-running
#   2 — hard halt: thrash detected; human intervention required
#   3 — config / precondition error

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
PRD="${PRD:-./prd.json}"
MAX_ITER="${MAX_ITER:-20}"
MAX_COST_USD="${MAX_COST_USD:-15}"
MAX_DURATION_S="${MAX_DURATION_S:-10800}"
MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-60}"
STATE_DIR="${STATE_DIR:-./.loopguard}"
LEARNINGS_FILE="${LEARNINGS_FILE:-$STATE_DIR/LEARNINGS.md}"
VERIFY_SCRIPT="${VERIFY_SCRIPT:-./scripts/verify.sh}"
CRITIC_SCRIPT="${CRITIC_SCRIPT:-./scripts/critic.sh}"
COUNCIL_SCRIPT="${COUNCIL_SCRIPT:-./scripts/council.sh}"
CRITIC_COUNCIL="${CRITIC_COUNCIL:-}"
SCOPE_SCRIPT="${SCOPE_SCRIPT:-./scripts/scope-check.sh}"
THRASH_SCRIPT="${THRASH_SCRIPT:-./scripts/thrash-detect.sh}"
BUILDER_MODEL="${BUILDER_MODEL:-sonnet}"
CRITIC_MODEL="${CRITIC_MODEL:-sonnet}"
ALLOWED_TOOLS="${ALLOWED_TOOLS:-Edit,Read,Write,Bash}"
AUTO_COMMIT="${AUTO_COMMIT:-1}"

PER_ITER_BUDGET=$(awk -v t="$MAX_COST_USD" -v n="$MAX_ITER" 'BEGIN{printf "%.2f", (t/n)*1.5}')

# ─── Preconditions ───────────────────────────────────────────────────────────
log() { printf '[loopguard] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 3; }

command -v jq      >/dev/null || die "jq not found"
command -v claude  >/dev/null || die "claude CLI not found"
command -v git     >/dev/null || die "git not found"
[[ -f "$PRD" ]]    || die "PRD not found: $PRD"
[[ -x "$VERIFY_SCRIPT" ]] || die "verify script not executable: $VERIFY_SCRIPT"
[[ -x "$CRITIC_SCRIPT" ]] || die "critic script not executable: $CRITIC_SCRIPT"
[[ -x "$SCOPE_SCRIPT"  ]] || die "scope script not executable: $SCOPE_SCRIPT"
[[ -x "$THRASH_SCRIPT" ]] || die "thrash script not executable: $THRASH_SCRIPT"
if [[ -n "$CRITIC_COUNCIL" ]]; then
  [[ -x "$COUNCIL_SCRIPT" ]] || die "council script not executable: $COUNCIL_SCRIPT (set CRITIC_COUNCIL='' to disable)"
fi
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo (loopguard relies on git for revert + commit)"

mkdir -p "$STATE_DIR"
PROGRESS="$STATE_DIR/progress.md"
CALL_LOG="$STATE_DIR/call-times.log"
[[ -f "$PROGRESS" ]] || printf '# loopguard progress log\n\n' > "$PROGRESS"
[[ -f "$LEARNINGS_FILE" ]] || printf '# Cumulative codebase learnings\n\nNon-obvious things future iters should know. Appended by builder after each passing iter.\n\n' > "$LEARNINGS_FILE"
[[ -f "$CALL_LOG" ]] || touch "$CALL_LOG"

# ─── State ───────────────────────────────────────────────────────────────────
START_TIME=$(date +%s)
iter=0

log_failure() { printf '\n## iter %s FAIL — %s\n\n```\n%s\n```\n' "$1" "$2" "${3:-}" >> "$PROGRESS"; }
log_success() { printf '\n## iter %s PASS — story %s\n' "$1" "$2" >> "$PROGRESS"; }

# Rate-limit check (frankbria pattern): keep timestamps of recent claude calls
# in $CALL_LOG, prune entries older than 1 hour, halt if count >= cap.
rate_limit_check() {
  local now=$(date +%s)
  local one_hour_ago=$((now - 3600))
  # Prune old entries in place
  awk -v cutoff="$one_hour_ago" '$1 >= cutoff' "$CALL_LOG" > "$CALL_LOG.tmp" && mv "$CALL_LOG.tmp" "$CALL_LOG"
  local count=$(wc -l < "$CALL_LOG")
  if (( count >= MAX_CALLS_PER_HOUR )); then
    log "HALT: rate cap reached ($count claude calls in last hour, cap $MAX_CALLS_PER_HOUR)"
    return 1
  fi
  return 0
}

record_call() { date +%s >> "$CALL_LOG"; }

# Refuse to start on a dirty tree — loopguard auto-reverts on failure and
# would destroy user's work-in-progress.
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "working tree dirty — commit or stash before starting loopguard (it auto-reverts on failure)"
fi

if [[ -n "$CRITIC_COUNCIL" ]]; then
  log "starting v0.2: PRD=$PRD  MAX_ITER=$MAX_ITER  MAX_COST_USD=\$$MAX_COST_USD  council=[$CRITIC_COUNCIL]  rate=$MAX_CALLS_PER_HOUR/h"
else
  log "starting v0.2: PRD=$PRD  MAX_ITER=$MAX_ITER  MAX_COST_USD=\$$MAX_COST_USD  critic=single  rate=$MAX_CALLS_PER_HOUR/h"
fi

# ─── Main loop ───────────────────────────────────────────────────────────────
while [[ $iter -lt $MAX_ITER ]]; do
  iter=$((iter + 1))
  elapsed=$(($(date +%s) - START_TIME))

  # ─── Hard caps ─────────────────────────────────────────────────────────────
  if [[ $elapsed -gt $MAX_DURATION_S ]]; then
    log "HALT: max duration ${MAX_DURATION_S}s reached at iter $iter"
    exit 1
  fi
  if ! rate_limit_check; then
    exit 1
  fi

  # ─── Pick next pending story ───────────────────────────────────────────────
  story_id=$(jq -r '.stories[] | select(.status != "passed") | .id' "$PRD" | head -1)
  if [[ -z "$story_id" ]]; then
    log "DONE: all stories passed"
    exit 0
  fi

  story=$(jq -c --arg id "$story_id" '.stories[] | select(.id == $id)' "$PRD")
  spec=$(echo "$story" | jq -r '.spec')
  acceptance=$(echo "$story" | jq -r '.acceptance_criteria | map("- " + .) | join("\n")')
  affected=$(echo "$story" | jq -r '.affected_files | map("- " + .) | join("\n")')
  affected_raw=$(echo "$story" | jq -r '.affected_files | join("\n")')
  max_diff_lines=$(echo "$story" | jq -r '.max_diff_lines // 300')

  log "iter $iter — story $story_id (max_diff_lines=$max_diff_lines)"

  # ─── L6: failure context + cumulative learnings ───────────────────────────
  failure_ctx=""
  if [[ -s "$PROGRESS" ]]; then
    failure_ctx=$(tail -60 "$PROGRESS")
  fi
  learnings_ctx=""
  if [[ -s "$LEARNINGS_FILE" ]]; then
    learnings_ctx=$(cat "$LEARNINGS_FILE")
  fi

  # ─── L2: builder runs in fresh context ────────────────────────────────────
  IFS='' read -r -d '' prompt <<PROMPT || true
You are implementing ONE story from a multi-story PRD. Stay in scope.

## Story
ID: $story_id
Spec: $spec

## Acceptance criteria (ALL must pass)
$acceptance

## Affected files (whitelist — do not touch any other file)
$affected

## Hard scope limits
- max_diff_lines: $max_diff_lines (your total diff is capped; over this, the loop auto-reverts)
- NO refactors not required by the spec
- NO clean-architecture upgrades, NO speculative abstractions
- NO error handling for impossible cases (trust internal callers)
- NO comments explaining WHAT (good names do that)

## Codebase learnings from prior iters (treat as ground truth)
$learnings_ctx

## Previous iteration outcomes (do not repeat the failures)
$failure_ctx

## Definition of done — DUAL EXIT GATE
You must satisfy BOTH:
1. Run $VERIFY_SCRIPT and confirm it exits 0.
2. Write the literal token "EXIT_SIGNAL: ready" on its own line in your final response, ONLY when you have:
   - implemented the story end-to-end
   - confirmed verify exits 0
   - left no TODOs, no stubbed-out branches, no debug prints
   - confirmed 'git diff --shortstat' is under $max_diff_lines lines

If EITHER is false, do NOT write EXIT_SIGNAL: ready. The loop checks both gates; either alone is insufficient.

## Codebase learnings to record (REQUIRED after EXIT_SIGNAL)
After you write "EXIT_SIGNAL: ready", on the next line write:
LEARNINGS: <one short line — anything non-obvious about THIS codebase that future iters should know. Examples: "tests use vitest not jest", "linter is biome", "uses pnpm workspaces". If nothing non-obvious learned this iter, write "LEARNINGS: none". Keep it under 100 chars.>

Do NOT commit — the loop commits if all guardrails pass.
PROMPT

  builder_log="$STATE_DIR/builder.iter-$iter.log"
  record_call
  set +e
  claude -p "$prompt" \
    --model "$BUILDER_MODEL" \
    --allowedTools "$ALLOWED_TOOLS" \
    --permission-mode bypassPermissions \
    --no-session-persistence \
    --max-budget-usd "$PER_ITER_BUDGET" \
    --fallback-model sonnet \
    > "$builder_log" 2>&1
  builder_exit=$?
  set -e

  if [[ $builder_exit -ne 0 ]]; then
    log "iter $iter: builder exited $builder_exit (see $builder_log)"
    log_failure "$iter" "builder exit $builder_exit" "$(tail -20 "$builder_log")"
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    continue
  fi

  # ─── L7: scope guard ─────────────────────────────────────────────────────
  set +e
  scope_out=$("$SCOPE_SCRIPT" "$max_diff_lines" "$affected_raw" 2>&1)
  scope_exit=$?
  set -e
  if [[ $scope_exit -ne 0 ]]; then
    log "iter $iter: SCOPE VIOLATION — $scope_out"
    log_failure "$iter" "scope violation" "$scope_out"
    git diff > "$STATE_DIR/diff.iter-$iter.patch" 2>/dev/null || true
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    continue
  fi

  # ─── L4 part A: programmatic verifier ────────────────────────────────────
  verify_log="$STATE_DIR/verify.iter-$iter.log"
  set +e
  "$VERIFY_SCRIPT" > "$verify_log" 2>&1
  verify_exit=$?
  set -e
  if [[ $verify_exit -ne 0 ]]; then
    log "iter $iter: VERIFY FAILED (exit $verify_exit)"
    log_failure "$iter" "verify exit $verify_exit" "$(tail -30 "$verify_log")"
    git diff > "$STATE_DIR/diff.iter-$iter.patch" 2>/dev/null || true
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    continue
  fi

  # ─── L4 part B: EXIT_SIGNAL check (dual exit gate, frankbria pattern) ────
  # Tests passing alone is insufficient — builder might know about TODOs or
  # stubs the verifier can't catch. EXIT_SIGNAL: ready = builder vouches.
  if ! grep -qE '^EXIT_SIGNAL:[[:space:]]*ready' "$builder_log"; then
    log "iter $iter: NO EXIT_SIGNAL — builder did not vouch for completion (verify passed but builder withheld signal)"
    log_failure "$iter" "no EXIT_SIGNAL" "verify passed but builder did not write 'EXIT_SIGNAL: ready' on its own line"
    git diff > "$STATE_DIR/diff.iter-$iter.patch" 2>/dev/null || true
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    continue
  fi

  # ─── L5: critic (single or council) ──────────────────────────────────────
  record_call
  set +e
  if [[ -n "$CRITIC_COUNCIL" ]]; then
    critic_out=$("$COUNCIL_SCRIPT" "$story_id" "$spec" "$CRITIC_MODEL" "$CRITIC_COUNCIL" diff 2>&1)
  else
    critic_out=$("$CRITIC_SCRIPT" "$story_id" "$spec" "$CRITIC_MODEL" generalist diff 2>&1)
  fi
  critic_exit=$?
  set -e
  if [[ $critic_exit -ne 0 ]] || ! grep -qE '^(PASS|\[.*\] PASS)' <<< "$critic_out"; then
    log "iter $iter: CRITIC REJECTED"
    log_failure "$iter" "critic rejected" "$critic_out"
    git diff > "$STATE_DIR/diff.iter-$iter.patch" 2>/dev/null || true
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    continue
  fi

  # ─── L8: anti-thrash check ───────────────────────────────────────────────
  set +e
  "$THRASH_SCRIPT" "$STATE_DIR" "$iter"
  thrash_exit=$?
  set -e
  if [[ $thrash_exit -eq 0 ]]; then
    log "HARD HALT: thrash detected (3 iters ≥80% identical diff). Human intervention required."
    log_failure "$iter" "thrash detected" "see $STATE_DIR/diff.iter-*.patch"
    exit 2
  fi

  # ─── Record codebase learnings (snarktank pattern) ───────────────────────
  learning=$(grep -E '^LEARNINGS:' "$builder_log" | head -1 | sed 's/^LEARNINGS:[[:space:]]*//')
  if [[ -n "$learning" && "$learning" != "none" ]]; then
    printf -- '- (iter %s, story %s) %s\n' "$iter" "$story_id" "$learning" >> "$LEARNINGS_FILE"
    log "iter $iter: learning recorded — $learning"
  fi

  # ─── All gates passed — commit + mark story done ─────────────────────────
  if [[ "$AUTO_COMMIT" == "1" ]]; then
    git add -A
    git commit -m "story:$story_id pass [loopguard iter $iter]

Spec: $(echo "$spec" | head -c 120)

All guardrails passed:
- scope ≤ $max_diff_lines LOC, files in whitelist
- $VERIFY_SCRIPT exit 0
- builder EXIT_SIGNAL: ready
- independent critic: PASS${CRITIC_COUNCIL:+ (council: $CRITIC_COUNCIL)}"
  fi

  jq --arg id "$story_id" '(.stories[] | select(.id == $id)).status = "passed"' "$PRD" > "$PRD.tmp" && mv "$PRD.tmp" "$PRD"
  log_success "$iter" "$story_id"
  log "iter $iter: ✓ $story_id passed"
done

log "HALT: max iter ($MAX_ITER) reached"
exit 1
