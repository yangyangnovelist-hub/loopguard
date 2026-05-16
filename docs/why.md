# Why loopguard

A point-by-point comparison of the existing loop-family projects, what each one ships, and where loopguard takes from them.

## The pain that produced this

Two failure modes from running Claude Code on real work:

1. **Mid-task confirmation halts**. You give a clear instruction. Claude does 60% of it, then stops and asks "Would you like me to proceed with X?" — restating your original request. Each halt costs round-trip latency, your attention, and tokens to re-read the conversation it just produced.

2. **Loops that hallucinate small tasks into a week of work**. You wrap the task in `/loop` or one of the OSS Ralph variants. It spends 3 minutes doing real work, then sits 30–60 min between iterations, then produces a "comprehensive refactor" that touched 40 files when you asked for 2.

Both failure modes have a common root: **the model has no clear stop condition** and **no constraint on how much surface area it's allowed to touch**.

## The loop family (real star counts)

| Repo | ⭐ | Contributes what |
|---|---|---|
| [snarktank/ralph](https://github.com/snarktank/ralph) | **19,136** | Canonical fresh-context-per-iter via bash + `claude -p`; `prd.json` with `passes: true` boolean; `progress.txt` accumulated learnings; AGENTS.md pattern |
| [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code) | **9,141** | Dual exit gate (verify + explicit `EXIT_SIGNAL`); `MAX_CALLS_PER_HOUR` rate limit; circuit-breaker thresholds (test-only %, no-progress, same-error, output-decline); session expiration |
| [AnandChowdhary/continuous-claude](https://github.com/AnandChowdhary/continuous-claude) | 1,335 | Cost cap (`--max-cost`), duration cap, completion threshold; `--review-provider claude\|codex` for cross-provider review; PR-based workflow |
| [iamfakeguru/agent-md](https://github.com/iamfakeguru/agent-md) | 942 | Agent directive format (Claude/Codex/Cursor/Windsurf/Aider) |
| [Dicklesworthstone/claude_code_agent_farm](https://github.com/Dicklesworthstone/claude_code_agent_farm) | 830 | File-based locks for 20+ parallel agents; stale-lock detection |
| [galz10/pickle-rick-extension](https://github.com/galz10/pickle-rick-extension) | 455 | Persona-driven SDLC enforcement; rigid iterative phases |
| [PageAI-Pro/ralph-loop](https://github.com/PageAI-Pro/ralph-loop) | 231 | Long-running task-list iterator (Ralph fork) |
| [jmilinovich/goal-md](https://github.com/jmilinovich/goal-md) | 138 | Karpathy autoresearch goal-spec format; constructed metrics |
| [agairola/securing-ralph-loop](https://github.com/agairola/securing-ralph-loop) | 4 | Security checks pre-commit, fix iteratively, escalate when stuck |
| Official Anthropic `ralph-loop` plugin | — | `--completion-promise` string-match exit |
| Official `/goal /loop /background /batch /schedule` | — | Native autonomy primitives (in-session) |

## Where each falls short

### snarktank/ralph (19k)
- Fresh context per iter ✓ (canonical pattern)
- `progress.txt` accumulates learnings ✓
- AGENTS.md updated each iter ✓
- **No cost cap** (only `--max-iterations`)
- **No scope guard** — relies on builder discipline + tests
- **No independent critic** — single-agent verification only

### frankbria/ralph-claude-code (9k)
- Dual exit gate (verify + EXIT_SIGNAL) ✓ — solves "tests pass but builder knows about TODO"
- `MAX_CALLS_PER_HOUR` ✓ — rate limit even when $ cap is fine
- Circuit breakers ✓ — `MAX_CONSECUTIVE_TEST_LOOPS=3`, `CB_NO_PROGRESS_THRESHOLD=3`, `CB_SAME_ERROR_THRESHOLD=5`
- Session expiration ✓
- **Uses Stop hook** — Anthropic GitHub issue #55754 documents Stop-hook misuse burning 50 min of session quota in a single shot (`{"continue": true}` = infinite loop)
- **No independent critic**
- **No scope guard** (only thrash detection)

### AnandChowdhary/continuous-claude (1.3k)
- Triple cost cap (`--max-runs`, `--max-cost`, `--max-duration`) ✓ (loopguard adopts this exactly)
- `--review-provider claude|codex` ✓ — cross-provider critic
- PR-based workflow ✓
- **Heavy for non-PR work** — requires GitHub PR infrastructure
- **No scope guard**
- **Single-pass review** (not council)

### Official ralph-loop (Anthropic plugin)
- Built-in to Claude Code ✓
- **Exit condition is literal string match on `--completion-promise`** — case, whitespace, punctuation off-by-one → never exits
- **Single shared context** across iters → Dex Horthy's "Dumb Zone" (contradictory info degrades model even before window fills)
- **No cost cap besides iters**
- **No critic, no scope guard, no thrash detect**

### Native `/goal /loop /background /batch /schedule`
- `/goal`: condition-based in-session — same-context, no cost cap, no scope, but `--background` composes well
- `/loop`: interval polling 1m–1h — different purpose (polling, not implementing)
- `/background`: detached session — compose with loopguard via `/background "bash scripts/loopguard.sh"`
- `/batch`: 5–30 parallel worktrees — compose with one loopguard per worktree
- `/schedule`: persistent cron — compose by cron-ing loopguard.sh

## What loopguard takes from where

| Layer | Borrowed from | Adapted how |
|---|---|---|
| 1. PRD discipline | snarktank/ralph + jmilinovich/goal-md | `prd.json` with `acceptance_criteria` + `affected_files` + `max_diff_lines` + `status` |
| 2. Fresh context per iter | snarktank/ralph (canonical) | `claude -p --no-session-persistence` per iter |
| 3. Triple cost cap | AnandChowdhary/continuous-claude | `MAX_ITER` + `--max-budget-usd` + `MAX_DURATION_S` |
| **3b. Rate cap** | **frankbria/ralph-claude-code** | **`MAX_CALLS_PER_HOUR` — prevents fast iters from blowing hourly quota even when $ cap looks fine** |
| 4a. Programmatic verifier | snarktank/ralph "feedback loops required" | `scripts/verify.sh` auto-detects Node/Rust/Go/Python |
| **4b. Dual exit gate** | **frankbria/ralph-claude-code** | **Builder must write `EXIT_SIGNAL: ready` AND verify must exit 0. Either alone is insufficient.** |
| 5. Independent critic | NOT in loop family — see below | `scripts/critic.sh` via `claude -p --bare` (cold-read, no auto-memory, no hooks) |
| **5b. Council of critics** | **NOT loop family — from [asdlc.io adversarial review](https://asdlc.io/patterns/adversarial-code-review/) + Apex-CodeGenesis council-of-critics + 2026 MAVEN paper** | **`CRITIC_COUNCIL=architect,secops,qa` runs parallel persona critics, AND-aggregated** |
| 6a. Failure log | snarktank/ralph `progress.txt` | `.loopguard/progress.md` tail-60 prepended to next iter's prompt |
| **6b. Cumulative learnings** | **snarktank/ralph AGENTS.md pattern** | **`LEARNINGS.md` — separate from failure log. Each passing iter appends a one-liner about non-obvious codebase facts. Future iters see all of it.** |
| 7. Scope guard | NOT in loop family — own contribution | `scripts/scope-check.sh` — diff size + whitelist + dep-file check + auto-revert |
| 8. Anti-thrash | frankbria/ralph-claude-code circuit breakers | `scripts/thrash-detect.sh` — sha256 + 80% line-overlap × 3 iters |

## What's **uniquely** new in loopguard (not borrowed)

1. **L7 Scope Guard** — no loop-family project I found enforces `max_diff_lines` + `affected_files` whitelist + auto-revert at the orchestrator level. The closest is snarktank's "tasks must fit one context window" guidance (advisory, not enforced).
2. **L5 Council-of-Critics integration** — borrowed from outside the loop family ([asdlc.io adversarial review pattern](https://asdlc.io/patterns/adversarial-code-review/), Apex-CodeGenesis, MAVEN paper) and wired into a Ralph-style fresh-context loop.
3. **`--bare` critic** — uses Anthropic's `--bare` flag (strips auto-memory, hooks, CLAUDE.md auto-load) for the critic, ensuring it's truly cold-reading.

Everything else is a careful stitching of existing patterns.

## Comparison matrix

| | Fresh ctx | Triple $ cap | Rate cap | Verifier | EXIT_SIGNAL | Critic | Council | Scope guard | Thrash | Learnings | License |
|---|---|---|---|---|---|---|---|---|---|---|---|
| snarktank/ralph (19k) | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | AGENTS.md | MIT |
| frankbria (9k) | ✗ (Stop hook) | partial | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ | MIT |
| continuous-claude (1.3k) | partial | ✓ | partial | ✓ | partial | ✓ (Codex) | ✗ | ✗ | partial | ✗ | MIT |
| Official ralph-loop | ✗ | ✗ | ✗ | weak | weak (string) | ✗ | ✗ | ✗ | ✗ | ✗ | — |
| Native `/goal` | ✗ | ✗ | ✗ | weak (Haiku) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | — |
| **loopguard** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (opt-in) | ✓ | ✓ | ✓ | MIT |

## The minimum-viable claim

If you write a PRD where each story:
- has 3–5 programmatically checkable acceptance criteria
- lists every file it should touch
- caps its own diff size at the right order of magnitude (~50 LOC tiny, ~300 LOC medium)

…and your `verify.sh` actually exits 0 iff the story is done…

then loopguard runs to completion or halts cleanly. It will not silently expand scope, burn unbounded cost, get stuck repeating the same fix, or trust a builder that quietly left a TODO behind.

That's the whole pitch. Everything else is documentation.
