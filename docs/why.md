# Why loopguard

A point-by-point comparison of the existing ralph-loop family, what each one misses, and what loopguard does instead.

## The pain that produced this

Two failure modes from running Claude Code on real work:

1. **Mid-task confirmation halts**. You give a clear instruction. Claude does 60% of it, then stops and asks "Would you like me to proceed with X?" — restating your original request. You type "yes," it does another 30%, stops again, asks again. Each halt costs round-trip latency, your attention, and tokens to re-read the conversation it just produced.

2. **Loops that hallucinate small tasks into a week of work**. You wrap the task in `/loop` or Ralph or one of the OSS variants. It spends 3 minutes doing real work, then sits for 30–60 minutes between iterations, then produces a "comprehensive refactor" that touched 40 files when you asked for 2.

Both failure modes have a common root: **the model has no clear stop condition** and **no constraint on how much surface area it's allowed to touch**.

## Where existing tools fall short

### Official `ralph-loop` (Anthropic plugin)
- Single shared context across iterations. Dex Horthy's "Dumb Zone" applies: even before the window is full, contradictory information (a bug and its failed fix attempt) degrades the model.
- Exit condition is a literal string match on `--completion-promise`. Case, whitespace, or punctuation off by one character → loop never exits.
- No cost cap besides `--max-iterations`.

### `frankbria/ralph-claude-code`
- Hardened (anti-thrash on test failures, MAX_CONSECUTIVE_TEST_LOOPS=3) but uses a Stop hook. GitHub issue #55754 documented a 50-minute / full-quota burn caused by Stop hook misuse: returning `{"continue": true}` is an infinite loop, and including the task description in the `reason` field causes Claude to "re-summarize" each turn, producing a deterministic dead-loop.
- No independent critic.
- Same-session, same context.

### `snarktank/ralph`
- The right idea — `claude -p` per iter for fresh context — but no cost cap, no independent critic, no scope guard. The README itself says "always set --max-iterations."

### `continuous-claude`
- Has cost cap and a Codex reviewer pass. Good.
- Tightly coupled to a GitHub PR workflow. Heavy for small or non-PR tasks.

### Anthropic's native `/goal`
- Condition-based autonomy. Evaluates the stop condition with Haiku each turn.
- Same session, same context, no cost cap, no scope guard. Built for tiny tasks ("until tests pass") not multi-story PRDs.

### Anthropic's `/background` and `/batch`
- Orthogonal mechanisms (detached session; parallel worktrees). You can compose loopguard with either: `/background "bash scripts/loopguard.sh"` for an unattended overnight run, or one loopguard-per-worktree for embarrassingly parallel PRDs.

## What loopguard adds

| Concern | loopguard mechanism |
|---|---|
| Scope creep (top complaint) | Story-level `max_diff_lines` cap + `affected_files` whitelist + auto-revert |
| Cost burn | Triple cap: iter, total $, wall-clock; per-iter `--max-budget-usd` from the math |
| "Looks done" | Programmatic `verify.sh` exit 0 — no string matching, no self-report |
| Single-agent blind spot | Independent critic via `claude -p --bare` with no auto-memory, no hooks, no prior context |
| Confirmation halts | `--permission-mode bypassPermissions` per iter — fresh context, no human-in-the-loop expectation |
| Stuck-on-same-fix | Anti-thrash on 3 consecutive failed iters with ≥80% line overlap |
| Context contamination | `--no-session-persistence` per iter; failure context comes in as `tail -60 progress.md`, not session state |
| Dumb Zone | Fresh context per iter; no accumulated bug/fix-attempt confusion |

## What it doesn't replace

- The PRD itself. Loopguard reads PRDs; it doesn't write them. The thinking work is yours.
- PR-time code review. Critic is fast and shallow.
- Domain skills. `seo-geo-loop`, `site-launch-loop`, `clone-website` etc. have their own discipline. Loopguard is the generic substrate for "implement these N coding stories;" the domain skills are for "implement this end-to-end workflow."

## The minimum-viable claim

If you write a PRD where each story:
- has 3–5 programmatically checkable acceptance criteria
- lists every file it should touch
- caps its own diff size at the right order of magnitude (~50 LOC for tiny, ~300 LOC for medium)

…then loopguard runs to completion or halts cleanly. It will not silently expand scope, burn unbounded cost, or get stuck repeating the same fix.

That's the whole pitch.
