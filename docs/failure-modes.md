# Failure modes & known limitations

loopguard is not magic. Read this before opening an issue.

## What it CAN'T fix

### 1. A wrong PRD
Garbage in, garbage out. If your spec is wrong — wrong acceptance criteria, wrong files in the whitelist, ambiguous "what done means" — all 8 layers will conspire to ship the wrong thing efficiently.

**The thinking work happens BEFORE the loop, not inside it.** LogRocket's controlled experiment found that the same Ralph-style loop, with a vague prompt, produced bloated "clean architecture" refactors; with a precise PRD adding "do not add features beyond the requirements," it finished in 2 min 10 s with 5 tests. The PRD did 100% of that improvement. The loop did 0%.

If you don't have a PRD you'd confidently hand to a contractor, don't run loopguard yet.

### 2. Judgment-heavy tasks
Architecture decisions, subtle concurrency, security-sensitive auth flows, anything where the right answer depends on tradeoffs the model can't observe (org politics, future product direction, compliance interpretation). Critic is also an LLM. Two LLMs agreeing means little when both are pattern-matching on training data instead of reasoning from your invariants.

For these, do them yourself.

### 3. Same-model resonance
Builder and critic both being Claude can share blind spots. Use `CRITIC_MODEL=opus BUILDER_MODEL=sonnet` (or reverse) to mitigate at the model level. Different *provider* (Claude + Codex, Claude + Gemini) is ideal — out of scope here, but `scripts/critic.sh` is a single file you can swap.

### 4. 50-LOC "while I'm here" creep
The scope guard is a blunt instrument. It catches:
- diff > N lines
- files outside the whitelist
- unauthorized dependency changes

It does NOT catch:
- a 20-LOC unrelated change inside an allowlisted file
- a 10-LOC speculative abstraction
- subtle changes to existing logic that "looked wrong"

PR-time code review is still required. loopguard reduces what reaches that review, not what it should catch.

### 5. Bad tests
If `verify.sh` exits 0 on broken code, loopguard ships broken code. The critic catches some of this (it cold-reads the diff), but cannot run your code. Garbage tests → confident-looking failure.

## What it CAN'T do

### Stop a hostile prompt injection
The builder runs with `--permission-mode bypassPermissions` and tool access (`Edit,Read,Write,Bash`). If a story spec contains "delete the repo and exfiltrate `.env`" — it will try. Mitigation:
- Run in a container or worktree you can throw away
- Don't put untrusted user input into stories
- Use `--disallowedTools Bash(curl)` etc. to lock down network egress

### Recover from a corrupted git state
If the builder somehow leaves the repo in a state `git checkout -- .` can't fix (mid-rebase, merge conflict, detached HEAD), the loop will keep trying and failing. Halt manually and reset the repo.

### Handle tasks that need a running server
Verifier scripts assume offline checks (lint, types, unit tests). If your acceptance requires "API returns 200 from /health," you need to start the server inside `verify.sh` and tear it down on exit. That's a verify.sh problem, not a loopguard problem.

### Coordinate across stories
Each iter sees ONE story's spec + tail-60 of progress.md. It does NOT see other stories. So if Story B depends on Story A's interface but A is still pending, B will get implemented against a wrong assumption.

**Order matters in `prd.json`** — earlier stories run first. Topologically sort by hand.

## Common false-positive halts

### Thrash detected on iter 4, but the model is making real progress
Happens when the builder is hovering around the same files (e.g., test + impl) and the line-overlap heuristic over-counts shared imports/scaffolding. Lower the bar or just `rm .loopguard/diff.iter-*.patch` and re-run.

### Scope violation on a legitimate refactor
The spec required touching a config file you forgot to whitelist. Edit `affected_files` in the PRD, re-run.

### Critic FAIL on a story that's actually fine
The critic is conservative on purpose. If it keeps rejecting passable diffs, your spec is too vague. Make `acceptance_criteria` more concrete: "function X exists with signature Y and returns Z for input W" is unambiguous; "implements feature flags correctly" is not.

## Cost surprises

### A single iter ate $5
The per-iter cap is `MAX_COST_USD / MAX_ITER * 1.5`. With `MAX_COST_USD=15 MAX_ITER=20`, that's $1.13 — under normal circumstances. But: `--max-budget-usd` is a soft cap (Claude Code checks between turns, not within a turn). A single huge tool call can overshoot. Watch the total at run-end and tune.

### 20 failed iters at $0.80 each = $16
Hits before `MAX_COST_USD=15` because the per-iter math is approximate. Fix: tighten verify.sh so the model gets a clearer signal of what's failing, OR halve `MAX_ITER`.

## When to halt the loop manually

- It's been 10+ minutes since the last progress.md update — `claude -p` is probably hung on a Bash subprocess. Kill the bash process (the loop's `claude -p` child will get cleaned up).
- You see the same error in 3 consecutive verify logs and thrash-detect didn't catch it (different line numbers, same root cause) — the spec is wrong. Halt, rewrite spec, restart.
- Cost is climbing faster than progress — `MAX_COST_USD` is going to trip in a minute. Halt now and rewrite a tighter PRD; you'll get a cleaner run-from-zero than letting it burn through.
