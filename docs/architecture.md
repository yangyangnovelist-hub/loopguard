# Architecture

loopguard is a thin bash orchestrator + four small validation scripts wrapped around `claude -p`. The only state it owns is a PRD JSON file and a `.loopguard/` directory of per-iteration logs.

## Sequence per iteration

```
                  ┌─────────────────────────────────────┐
                  │  pick first pending story from PRD  │
                  └────────────────┬────────────────────┘
                                   │
                                   ▼
       ┌──────────────────────────────────────────────────────┐
       │  build prompt: spec + acceptance + whitelist +       │
       │  max_diff_lines + tail-60(progress.md)               │
       └────────────────┬─────────────────────────────────────┘
                        ▼
       ┌──────────────────────────────────────────────────────┐
       │  L2 fresh context:                                    │
       │  claude -p --no-session-persistence --max-budget-usd │
       │       --permission-mode bypassPermissions             │
       └────────────────┬─────────────────────────────────────┘
                        │ builder finishes
                        ▼
                  ┌──────────────┐
                  │ L7 scope-check│──fail──┐
                  └─────┬─────────┘        │
                        │pass              │
                        ▼                  │
                  ┌──────────────┐         │
                  │ L4 verify.sh │──fail──┤
                  └─────┬────────┘        │
                        │exit 0           │
                        ▼                  │
                  ┌──────────────┐         │
                  │ L5 critic.sh │──fail──┤
                  └─────┬────────┘        │
                        │PASS              │
                        ▼                  ▼
                  ┌──────────────┐    ┌────────────────────┐
                  │ L8 thrash?   │    │ revert + save diff │
                  └─────┬────────┘    │ to .loopguard/     │
                        │no           │ log failure        │
                        ▼             └─────────┬──────────┘
                  ┌──────────────┐              │
                  │ git commit + │              │
                  │ mark passed  │              ▼
                  └──────────────┘    ┌────────────────────┐
                                      │ L8 thrash check    │
                                      │ on 3rd consecutive │
                                      │ fail               │
                                      └─────────┬──────────┘
                                                │thrash → exit 2
                                                │no thrash → next iter
```

## Why this order

1. **scope-check before verify** — verify is expensive (runs your whole test suite). If the builder went off the rails and modified 50 files, fail fast.
2. **verify before critic** — if tests don't pass, the diff isn't ready for review at all. Critic burns tokens reading something that doesn't compile/run.
3. **critic before thrash** — thrash is computed against *failed* diffs. A passing diff resets the counter implicitly (no patch artifact is saved on success).
4. **thrash on 3rd consecutive fail, not 3rd total fail** — only `diff.iter-N.patch` files are inspected. Successful iters break the chain because they don't write a patch.

## File layout

```
loopguard/
├── SKILL.md                     # for Claude Code Skill auto-loading
├── README.md                    # public-facing
├── LICENSE                      # MIT
├── scripts/
│   ├── loopguard.sh             # orchestrator (~150 LOC)
│   ├── verify.sh                # programmatic gate (auto-detects Node/Rust/Go/Python)
│   ├── critic.sh                # spawns `claude -p --bare` reviewer
│   ├── scope-check.sh           # diff size + whitelist + dep-file check
│   └── thrash-detect.sh         # identical-bytes + 80% line-overlap detection
├── templates/
│   ├── prd.template.json        # skeleton PRD
│   ├── prd.schema.json          # JSON Schema for validation
│   └── critic-prompt.md         # canonical critic prompt (for audit)
├── examples/
│   ├── prd-minimal.json         # 2-story example
│   └── prd-feature-flag.json    # 4-story example
└── docs/
    ├── architecture.md          # this file
    ├── failure-modes.md         # what can still go wrong
    ├── why.md                   # rationale & comparison
    └── integration.md           # composing with /goal, /background, /batch
```

## State per run

```
.loopguard/
├── progress.md                  # human-readable + machine-tailable failure log
├── builder.iter-1.log           # full builder stdout/stderr
├── builder.iter-2.log
├── verify.iter-2.log            # only on failed verify
├── diff.iter-2.patch            # only on failed iter (for thrash-detect to compare)
├── diff.iter-3.patch
└── ...
```

`.loopguard/` should be in `.gitignore`. Patches and logs are local artifacts, not source.

## The eight layers, mapped to code

| Layer | File | Function |
|---|---|---|
| 1. PRD discipline | `templates/prd.schema.json` | enforced at PRD authoring time |
| 2. Fresh context | `scripts/loopguard.sh:90` | `claude -p --no-session-persistence` per iter |
| 3. Triple cost cap | `scripts/loopguard.sh:62`, `:96` | `MAX_ITER`/`MAX_DURATION_S` env, `--max-budget-usd` flag |
| 4. Verifier | `scripts/verify.sh` | user-customizable; default auto-detects stack |
| 5. Critic | `scripts/critic.sh` | `claude -p --bare` cold read |
| 6. Failure log | `scripts/loopguard.sh:82` | `tail -60 progress.md` prepended to builder prompt |
| 7. Scope guard | `scripts/scope-check.sh` | diff-line cap + glob whitelist + dep-file check |
| 8. Anti-thrash | `scripts/thrash-detect.sh` | bytewise hash + 80% line overlap across 3 iters |

## Cost math

If you set `MAX_COST_USD=15` and `MAX_ITER=20`, each iter's `--max-budget-usd` is set to `(15 / 20) * 1.5 = $1.125`. The 1.5× multiplier gives some headroom for a hard iter (the loop-level cap still bounds the run).

In practice, sonnet builder + sonnet critic on a 200-LOC story costs around $0.30–$0.80 per *successful* iter. Failed iters cost ~$0.40–$1.00 each (you still pay for the builder and any verify/critic runs before revert). A 4-story PRD with 1.5 avg iters per story tends to land at $3–$7 total.

## What this is NOT

- Not a replacement for code review at PR time. Critic is fast but shallow.
- Not safe to run on `main` without `--dangerously-skip-permissions` understood. The loop uses `--permission-mode bypassPermissions`. Run in a worktree, in a container, or on a branch you're willing to throw away.
- Not designed for tasks with no programmatic verifier. If you can't write a `verify.sh` that exits 0 ↔ "story really done", loopguard cannot help you.
