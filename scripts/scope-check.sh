#!/usr/bin/env bash
# scope-check.sh - Layer 7. Reject diffs that exceed the story's scope.
#
# Usage:
#   ./scripts/scope-check.sh <max_diff_lines> <affected_files_newline_list>
#
# Exit 0 = within scope. Exit 1 = violation (stdout names the violation).
#
# Checks:
#   1. Total diff lines (insertions + deletions) ≤ max_diff_lines
#   2. Every modified file is in the whitelist (supports * and ? glob patterns)
#   3. No new top-level dependency files appeared unless whitelisted
#      (package.json, Cargo.toml, go.mod, requirements.txt, pyproject.toml)

set -euo pipefail

MAX_DIFF_LINES="${1:?max_diff_lines required}"
AFFECTED_FILES="${2:?affected_files required (newline-separated)}"

# ─── 1. diff size ────────────────────────────────────────────────────────────
shortstat=$(git diff --shortstat 2>/dev/null || echo "")
ins=$(echo "$shortstat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
del=$(echo "$shortstat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)
total=$((ins + del))

if (( total > MAX_DIFF_LINES )); then
  echo "diff too large: $total lines (cap $MAX_DIFF_LINES)"
  exit 1
fi

# ─── 2. whitelist check (with glob support) ─────────────────────────────────
matches_whitelist() {
  local f="$1"
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    # shellcheck disable=SC2053
    if [[ "$f" == $pattern ]]; then
      return 0
    fi
  done <<< "$AFFECTED_FILES"
  return 1
}

# All changed files (including untracked, staged, modified, and deleted).
changed=$(git status --porcelain | awk '{print $NF}' | sort -u)

if [[ -z "$changed" ]]; then
  # No changes — the builder did nothing. Caller (critic) will catch this.
  exit 0
fi

violations=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if ! matches_whitelist "$f"; then
    violations+=("$f")
  fi
done <<< "$changed"

if (( ${#violations[@]} > 0 )); then
  echo "files outside whitelist:"
  printf '  - %s\n' "${violations[@]}"
  exit 1
fi

# ─── 3. unauthorized dependency changes ─────────────────────────────────────
dep_files=(package.json package-lock.json yarn.lock pnpm-lock.yaml Cargo.toml Cargo.lock go.mod go.sum requirements.txt pyproject.toml poetry.lock)
for dep in "${dep_files[@]}"; do
  if echo "$changed" | grep -qFx "$dep"; then
    if ! matches_whitelist "$dep"; then
      echo "unauthorized dependency change: $dep (not in affected_files)"
      exit 1
    fi
  fi
done

exit 0
