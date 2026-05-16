#!/usr/bin/env bash
# thrash-detect.sh - Layer 8. Detect when the model is stuck producing the same diff.
#
# Usage:
#   ./scripts/thrash-detect.sh <state_dir> <current_iter>
#
# Exit 0 = thrash detected (HARD HALT). Exit 1 = no thrash, keep going.
#
# Strategy:
#   - need at least 3 prior FAILED iters (diff.iter-N.patch artifacts from
#     scope/verify/critic rejection)
#   - if last 3 are byte-identical: clearly stuck
#   - else: compare line-set similarity. If pairwise overlap (N-1 vs N-2 and
#     N-2 vs N-3) both ≥80%, model is making the same wrong fix repeatedly.

set -euo pipefail

STATE_DIR="${1:?state_dir required}"
ITER="${2:?iter required}"

# Need ≥4 iters total (current is going to commit, so we look at iter-1..iter-3 patches)
if (( ITER < 4 )); then
  exit 1
fi

p1="$STATE_DIR/diff.iter-$((ITER-1)).patch"
p2="$STATE_DIR/diff.iter-$((ITER-2)).patch"
p3="$STATE_DIR/diff.iter-$((ITER-3)).patch"

# Patches only exist for FAILED iters (success path doesn't write them).
# If any of the 3 prior iters succeeded, no patch — that means progress, not thrash.
for p in "$p1" "$p2" "$p3"; do
  [[ -f "$p" ]] || exit 1
done

# Empty patches mean builder produced nothing — also a kind of stuck.
empty_count=0
for p in "$p1" "$p2" "$p3"; do
  if [[ ! -s "$p" ]]; then
    empty_count=$((empty_count + 1))
  fi
done
if (( empty_count >= 3 )); then
  echo "thrash: 3 consecutive empty diffs (builder produced nothing)"
  exit 0
fi

# Identical bytes — clearest signal.
h1=$(shasum -a 256 "$p1" | cut -d' ' -f1)
h2=$(shasum -a 256 "$p2" | cut -d' ' -f1)
h3=$(shasum -a 256 "$p3" | cut -d' ' -f1)
if [[ "$h1" == "$h2" && "$h2" == "$h3" ]]; then
  echo "thrash: byte-identical diff 3 iters in a row"
  exit 0
fi

# Fuzzy line overlap.
similarity_pct() {
  local a="$1" b="$2"
  local lines_a
  lines_a=$(wc -l < "$a")
  if (( lines_a == 0 )); then echo 0; return; fi
  local shared
  shared=$(comm -12 <(sort -u "$a") <(sort -u "$b") | wc -l)
  echo $(( shared * 100 / lines_a ))
}

sim_12=$(similarity_pct "$p1" "$p2")
sim_23=$(similarity_pct "$p2" "$p3")

if (( sim_12 >= 80 && sim_23 >= 80 )); then
  echo "thrash: ${sim_12}% / ${sim_23}% line overlap across last 3 failed iters"
  exit 0
fi

exit 1
