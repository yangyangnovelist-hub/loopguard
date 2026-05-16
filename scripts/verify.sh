#!/usr/bin/env bash
# verify.sh - programmatic exit gate. Exit 0 = story really done.
#
# CUSTOMIZE THIS for your project. The defaults below auto-detect common stacks
# but you should pin this to whatever you actually trust as "done".
#
# Add or remove checks as needed. Order matters — put fast/cheap checks first.

set -euo pipefail

echo "[verify] starting"

# ─── Node/TS stack ───────────────────────────────────────────────────────────
if [[ -f package.json ]]; then
  if jq -e '.scripts.lint' package.json >/dev/null 2>&1; then
    echo "[verify] npm run lint"
    npm run lint --silent
  fi
  if [[ -f tsconfig.json ]]; then
    echo "[verify] tsc --noEmit"
    npx --no-install tsc --noEmit
  fi
  if jq -e '.scripts.test' package.json >/dev/null 2>&1; then
    echo "[verify] npm test"
    CI=1 npm test --silent
  fi
fi

# ─── Rust ────────────────────────────────────────────────────────────────────
if [[ -f Cargo.toml ]]; then
  echo "[verify] cargo check"
  cargo check --quiet
  echo "[verify] cargo test"
  cargo test --quiet
  echo "[verify] cargo clippy -- -D warnings"
  cargo clippy --quiet -- -D warnings
fi

# ─── Go ──────────────────────────────────────────────────────────────────────
if [[ -f go.mod ]]; then
  echo "[verify] go vet"
  go vet ./...
  echo "[verify] go test"
  go test ./...
fi

# ─── Python ──────────────────────────────────────────────────────────────────
if [[ -f pyproject.toml || -f requirements.txt ]]; then
  if command -v ruff >/dev/null 2>&1; then
    echo "[verify] ruff check"
    ruff check .
  fi
  if command -v mypy >/dev/null 2>&1 && [[ -f pyproject.toml ]]; then
    echo "[verify] mypy"
    mypy --ignore-missing-imports . || true
  fi
  if command -v pytest >/dev/null 2>&1; then
    echo "[verify] pytest"
    pytest -q
  fi
fi

# ─── Security (optional but recommended; non-fatal if not installed) ─────────
if command -v semgrep >/dev/null 2>&1; then
  echo "[verify] semgrep"
  semgrep scan --config=auto --error --quiet || {
    echo "[verify] semgrep found issues"
    exit 1
  }
fi

echo "[verify] all checks passed"
exit 0
