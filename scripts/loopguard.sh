#!/usr/bin/env bash
# loopguard - bounded autonomous Claude Code dev loop
#
# Usage:
#   PRD=./prd.json ./scripts/loopguard.sh
#
# Env vars (all optional):
#   PRD                Path to PRD JSON (default: ./prd.json)
#   MAX_ITER           Hard iter cap (default: 20)
#   MAX_COST_USD       Total $ cap (default: 15)
#   MAX_DURATION_S     Wall-clock cap in seconds (default: 10800 = 3h)
#   STATE_DIR          Where logs/state live (default: ./.loopguard)
#   VERIFY_SCRIPT      Programmatic exit gate (default: ./scripts/verify.sh)
#   CRITIC_SCRIPT      Independent reviewer (default: ./scripts/critic.sh)
#   SCOPE_SCRIPT       Scope guard (default: ./scripts/scope-check.sh)
#   THRASH_SCRIPT      Anti-thrash (default: ./scripts/thrash-detect.sh)
#   BUILDER_MODEL      Model for builder (default: sonnet)
#   CRITIC_MODEL       Model for critic (default: sonnet — use a different one if possible)
#   ALLOWED_TOOLS      Tool gate for builder (default: "Edit,Read,Write,Bash")
#   AUTO_COMMIT        Commit after each passing iter (default: 1; set 0 to skip)
#
# Exits:
#   0 — done: all stories passed or nothing pending
#   1 — soft halt: hit iter / cost / duration cap; resume by re-running
#   2 — hard halt: thrash detected; human intervention required
#   3 — config / precondition error

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
PRD="${PRD:-./prd.json}"
MAX_ITER="${MAX_ITER:-20}"
MAX_COST_USD="${MAX_COST_USD:-15}"
MAX_DURATION_S="${MAX_DURATION_S:-10800}"
STATE_DIR="${STATE_DIR:-./.loopguard}"
VERIFY_SCRIPT="${VERIFY_SCRIPT:-./scripts/verify.sh}"
CRITIC_SCRIPT="${CRITIC_SCRIPT:-./scripts/critic.sh}"
SCOPE_SCRIPT="${SCOPE_SCRIPT:-./scripts/scope-check.sh}"
THRASH_SCRIPT="${THRASH_SCRIPT:-./scripts/thrash-detect.sh}"
BUILDER_MODEL="${BUILDER_MODEL:-sonnet}"
CRITIC_MODEL="${CRITIC_MODEL:-sonnet}"
ALLOWED_TOOLS="${ALLOWED_TOOLS:-Edit,Read,Write,Bash}"
AUTO_COMMIT="${AUTO_COMMIT:-1}"

# Per-iter cost cap: total / iter, with 25% floor to allow occasional big steps
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
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo (loopguard relies on git for revert + commit)"

mkdir -p "$STATE_DIR"
PROGRESS="$STATE_DIR/progress.md"
[[ -f "$PROGRESS" ]] || printf '# loopguard progress log\n\n' > "$PROGRESS"

# ─── State ───────────────────────────────────────────────────────────────────
START_TIME=$(date +%s)
iter=0

log_failure() { printf '\n## iter %s FAIL — %s\n\n```\n%s\n```\n' "$1" "$2" "${3:-}" >> "$PROGRESS"; }
log_success() { printf '\n## iter %s PASS — story %s\n' "$1" "$2" >> "$PROGRESS"; }

# Stash untracked staged-but-uncommitted state so we have a clean rollback target.
# If user has dirty working tree, we refuse — they should commit first.
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "working tree dirty — commit or stash before starting loopguard (it auto-reverts on failure)"
fi

log "starting: PRD=$PRD  MAX_ITER=$MAX_ITER  MAX_COST_USD=\$$MAX_COST_USD  per_iter=\$$PER_ITER_BUDGET"

# ─── Main loop ───────────────────────────────────────────────────────────────
while [[ $iter -lt $MAX_ITER ]]; do
  iter=$((iter + 1))
  elapsed=$(($(date +%s) - START_TIME))

  # ─── Hard caps ─────────────────────────────────────────────────────────────
  if [[ $elapsed -gt $MAX_DURATION_S ]]; then
    log "HALT: max duration ${MAX_DURATION_S}s reached at iter $iter"
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

  # ─── Layer 6: failure context from prior iters ────────────────────────────
  failure_ctx=""
  if [[ -s "$PROGRESS" ]]; then
    failure_ctx=$(tail -60 "$PROGRESS")
  fi

  # ─── Layer 2: builder runs in fresh context ───────────────────────────────
  prompt=$(cat <<PROMPT
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
- NO "while I'm here" refactors, NO clean-architecture upgrades, NO speculative abstractions
- NO error handling for impossible cases (trust internal callers)
- NO comments explaining WHAT (good names do that)

## Previous iteration outcomes (do not repeat the failures)
$failure_ctx

## Definition of done
1. Implement the story end-to-end within the whitelist.
2. Run $VERIFY_SCRIPT and ensure it exits 0.
3. Confirm 'git diff --shortstat' shows ≤ $max_diff_lines insertions+deletions.

When all three are true, write a one-line summary of what you changed and stop. Do not commit — the loop will commit if all guardrails pass.
PROMPT
)

  builder_log="$STATE_DIR/builder.iter-$iter.log"
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

  # ─── Layer 7: scope guard (BEFORE expensive verify/critic) ────────────────
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

  # ─── Layer 4: programmatic verifier ───────────────────────────────────────
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

  # ─── Layer 5: independent critic ──────────────────────────────────────────
  set +e
  critic_out=$("$CRITIC_SCRIPT" "$story_id" "$spec" "$CRITIC_MODEL" 2>&1)
  critic_exit=$?
  set -e
  if [[ $critic_exit -ne 0 ]] || ! grep -qE '^(PASS|VERDICT: ?PASS)' <<< "$critic_out"; then
    log "iter $iter: CRITIC REJECTED"
    log_failure "$iter" "critic rejected" "$critic_out"
    git diff > "$STATE_DIR/diff.iter-$iter.patch" 2>/dev/null || true
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    continue
  fi

  # ─── Layer 8: anti-thrash (check now, BEFORE committing) ──────────────────
  set +e
  "$THRASH_SCRIPT" "$STATE_DIR" "$iter"
  thrash_exit=$?
  set -e
  if [[ $thrash_exit -eq 0 ]]; then
    log "HARD HALT: thrash detected (3 iters ≥80% identical diff). Human intervention required."
    log_failure "$iter" "thrash detected" "see $STATE_DIR/diff.iter-*.patch"
    exit 2
  fi

  # ─── All gates passed — commit + mark story done ─────────────────────────
  if [[ "$AUTO_COMMIT" == "1" ]]; then
    git add -A
    git commit -m "story:$story_id pass [loopguard iter $iter]

Spec: $(echo "$spec" | head -c 120)

Generated by loopguard. All guardrails passed:
- scope ≤ $max_diff_lines LOC, files in whitelist
- $VERIFY_SCRIPT exit 0
- independent critic: PASS"
  fi

  jq --arg id "$story_id" '(.stories[] | select(.id == $id)).status = "passed"' "$PRD" > "$PRD.tmp" && mv "$PRD.tmp" "$PRD"
  log_success "$iter" "$story_id"
  log "iter $iter: ✓ $story_id passed"
done

log "HALT: max iter ($MAX_ITER) reached"
exit 1
