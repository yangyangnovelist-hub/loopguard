#!/usr/bin/env bash
# council.sh - Council-of-Critics aggregator.
#
# Runs multiple critic.sh invocations in parallel, each with a different
# persona. AND-aggregates: any single FAIL = council FAIL.
#
# Pattern from:
#   - asdlc.io adversarial code review (Architect / SecOps / QA + Moderator)
#   - Apex-CodeGenesis council-of-critics self-critique
#   - MAVEN paper Skeptic-Researcher-Judge multi-agent verification (2026)
#
# Usage:
#   ./scripts/council.sh <story_id> <spec> <model> <personas_csv> [target] [plan_file]
#
# personas_csv: comma-separated, e.g. "architect,secops,qa" or "generalist"
#
# Stdout: aggregated verdict — first line PASS or FAIL: <reason>, then each
# critic's full output annotated with [persona].
#
# Cost: linear in number of personas. 3 critics ≈ 3× single critic cost.
# Use council mode for important stories, single critic for routine ones.

set -euo pipefail

STORY_ID="${1:?story id required}"
SPEC="${2:?spec required}"
MODEL="${3:-sonnet}"
PERSONAS_CSV="${4:?personas required (e.g. architect,secops,qa)}"
TARGET="${5:-diff}"
PLAN_FILE_ARG="${6:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRITIC="$SCRIPT_DIR/critic.sh"

# Fan out — run each critic in a temp file so we can read all outputs after.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

pids=()
personas=()
IFS=',' read -ra persona_array <<< "$PERSONAS_CSV"

for persona in "${persona_array[@]}"; do
  persona=$(echo "$persona" | tr -d '[:space:]')
  out="$tmpdir/$persona.out"
  (
    if [[ "$TARGET" == "plan" ]]; then
      PLAN_FILE="$PLAN_FILE_ARG" "$CRITIC" "$STORY_ID" "$SPEC" "$MODEL" "$persona" plan > "$out" 2>&1
    else
      "$CRITIC" "$STORY_ID" "$SPEC" "$MODEL" "$persona" diff > "$out" 2>&1
    fi
  ) &
  pids+=("$!")
  personas+=("$persona")
done

# Wait for all critics
for pid in "${pids[@]}"; do
  wait "$pid" || true
done

# Aggregate — any FAIL = council FAIL
overall=PASS
fail_personas=()
for i in "${!personas[@]}"; do
  persona="${personas[$i]}"
  out="$tmpdir/$persona.out"
  if ! grep -qE '^\['"$persona"'\] PASS' "$out"; then
    overall=FAIL
    fail_personas+=("$persona")
  fi
done

if [[ "$overall" == "PASS" ]]; then
  echo "PASS: all ${#personas[@]} critics agreed (${PERSONAS_CSV})"
else
  printf 'FAIL: %d/%d critics rejected — %s\n' "${#fail_personas[@]}" "${#personas[@]}" "$(IFS=,; echo "${fail_personas[*]}")"
fi
echo
echo "─── Council breakdown ───"
for persona in "${personas[@]}"; do
  echo
  echo "### $persona"
  cat "$tmpdir/$persona.out"
done
exit 0
