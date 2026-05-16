---
name: loopguard
description: Bounded autonomous Claude Code dev loop. Triggers when the user wants a Ralph-style loop, is frustrated by mid-task confirmation halts, asks for "/loop on a real coding task", or needs a multi-story PRD implemented without the scope creep / cost burn / single-agent blind spots that plain Ralph variants suffer from. Adds 8 guardrails on top of fresh-context bash orchestration. Does NOT trigger for one-off bug fixes, single-file edits, pure Q&A, or pure SEO/content loops (those have their own skills).
---

# loopguard

> Ralph-loop with guardrails. Fresh context every iteration, scope-bounded per story, cost-capped end-to-end, programmatically verified, independently critiqued, and anti-thrash gated.

## When to invoke

Trigger when the user says any of:
- "run a loop on this", "ralph this", "auto-implement these stories"
- "Claude keeps stopping mid-task to ask me"
- "I want to walk away and come back to working code"
- Provides or asks to draft a multi-story PRD (≥2 independent stories)
- Complains about previous loop attempts burning cost or refactoring more than asked

Do NOT trigger for:
- Single-line edits or typos
- Pure conversation / explanation
- One-shot tasks that fit in a single context window without iteration
- SEO / content / domain-specific loops that have their own skill (`seo-geo-loop`, `site-launch-loop`, etc.) — those skills have their own discipline; loopguard is a generic code-execution loop

## The eight guardrails

| # | Layer | Purpose | Where |
|---|---|---|---|
| 1 | PRD discipline | One story = one context window | `prd.json` schema |
| 2 | Fresh context per iter | Kill Dumb-Zone drift | `claude -p` per builder call |
| 3 | Triple cost cap | iter, $, wall-clock | `MAX_ITER`, `--max-budget-usd`, `MAX_DURATION_S` |
| 4 | Programmatic verifier | "Done" requires exit 0, not self-report | `scripts/verify.sh` |
| 5 | Independent critic | Cold-read review of diff vs spec | `scripts/critic.sh` (uses `--bare`) |
| 6 | Failure context log | Next iter sees prior failure reason | `progress.md` prepended to prompt |
| 7 | Scope guard | Block diff > N lines or files outside whitelist | `scripts/scope-check.sh` (auto-revert) |
| 8 | Anti-thrash | Halt if 3 iters produce ≥80% same diff | `scripts/thrash-detect.sh` |

## How to use this skill in a Claude session

When the user invokes loopguard, follow this routing:

### Mode 1 — User has a PRD already

```
1. Read prd.json. Validate against templates/prd.template.json schema.
2. Run loopguard.sh with the PRD path:
     PRD=./prd.json MAX_ITER=20 MAX_COST_USD=15 ./loopguard.sh
3. Tail the loop output. Do not babysit — loopguard halts itself on:
   - all stories passed
   - max iter / cost / time
   - thrash detected (returns exit 2 — needs human)
4. On halt, summarize: which stories passed, which blocked, what next.
```

### Mode 2 — User has a vague task, no PRD

```
1. Convert the request to PRD. Each story must satisfy:
   - Implementable in one context window (≤300 LOC diff usually)
   - Has an `acceptance_criteria` list, each item programmatically checkable
   - Has an `affected_files` whitelist
   - Has a `max_diff_lines` cap
2. Show PRD to user — but per the user's standing rule "no questions, just loop",
   commit and start loopguard immediately. User can ctrl-c to revise.
```

### Mode 3 — User asks to debug a stuck loop

```
1. Read $STATE_DIR/progress.md (default .loopguard/progress.md).
2. Classify halt cause:
   - SCOPE VIOLATION → builder is over-reaching. Tighten max_diff_lines or split story.
   - VERIFY FAILED repeatedly → spec is ambiguous; rewrite acceptance_criteria more concretely.
   - CRITIC FAIL repeatedly → builder ↔ critic disagreement; usually critic is right, but if critic nitpicks check critic-prompt.md.
   - THRASH → model is stuck. Manual intervention required. Don't restart loop blindly.
3. Patch the PRD, then resume — story status stays `pending` so loop picks it up.
```

## PRD schema (canonical)

```json
{
  "project": "string",
  "stories": [
    {
      "id": "S-001",
      "spec": "One paragraph. What to build, why, and the single observable behavior change.",
      "acceptance_criteria": [
        "Programmatically checkable assertion #1",
        "scripts/verify.sh exits 0"
      ],
      "affected_files": ["src/foo.ts", "src/foo.test.ts"],
      "max_diff_lines": 200,
      "status": "pending"
    }
  ]
}
```

`status` ∈ `pending | passed`. `pending` includes "never tried" and "tried but failed" — loopguard retries until iter/cost cap.

## Cost-cap composition

Three caps; first to trip wins:

```
MAX_ITER             # default 20 — coarse safety net
MAX_COST_USD         # default 15 — passed to each `claude -p --max-budget-usd`
MAX_DURATION_S       # default 10800 (3h) — wall-clock guard
```

Per-iter cost cap (`--max-budget-usd` divided by `MAX_ITER`) prevents a single runaway iter from eating the whole budget.

## Why each layer (the antipatterns it prevents)

- **L1 PRD**: vague prompts cause confirmation halts (Claude defensively pauses when "done" is ambiguous). Concrete acceptance_criteria = clear stop condition.
- **L2 Fresh context**: snarktank-style. Avoids Dex Horthy "Dumb Zone" (context with contradictory info — a bug plus its failed fix attempts — degrades the model even below context-window limits).
- **L3 Triple cost cap**: reports of $400/month Claude Max plans burned in days using uncapped loops. `--max-budget-usd` is built into Claude Code now — use it.
- **L4 Verifier**: builder saying "DONE" or matching a completion-promise string is unreliable. Only `exit 0` from tests + lint + types + security scan counts.
- **L5 Independent critic**: single-agent self-review is blind. Run critic in `--bare` mode (no auto-memory, no hooks) with only spec + diff in context. Use a different model when possible (cheap second opinion).
- **L6 Failure log**: next iter must see *why* prior iter failed, or it repeats the mistake. Tail-50 of progress.md prepended to builder prompt.
- **L7 Scope guard**: the biggest single source of cost burn. Builder loves to "clean up while it's here". Auto-revert on diff > cap or files outside whitelist. No exceptions.
- **L8 Anti-thrash**: 3 iters producing ≥80% identical diff = model is stuck. Continuing burns money without progress. Halt and ask for human.

## Comparison to existing approaches

| Approach | Fresh context | Cost cap | Verifier | Critic | Scope guard | Thrash detect |
|---|---|---|---|---|---|---|
| Official ralph-loop | ✗ | ✗ | weak (completion-promise) | ✗ | ✗ | ✗ |
| frankbria/ralph-claude-code | ✗ (Stop hook) | partial | ✓ | ✗ | ✗ | partial |
| snarktank/ralph | ✓ | ✗ | weak | ✗ | ✗ | ✗ |
| continuous-claude | ✗ | ✓ | ✓ | ✓ (via Codex) | ✗ | ✗ |
| Anthropic native `/goal` | ✗ (same session) | ✗ | weak (Haiku eval) | ✗ | ✗ | ✗ |
| **loopguard** | ✓ | ✓ (triple) | ✓ | ✓ | ✓ | ✓ |

## Composes with native Claude Code commands

- `/goal` (condition-based autonomy in-session) — fine for tiny tasks; for ≥1 story use loopguard
- `/background` (detached session) — wrap loopguard.sh in `/background "bash loopguard.sh"` for hours-long unattended runs
- `/batch` (parallel worktrees) — orthogonal; can run one loopguard per worktree for embarrassingly parallel PRDs
- `/loop` (interval polling) — different purpose (poll status, not implement code)

## What loopguard does NOT fix

- **Bad PRD**: garbage in, garbage out. If your spec is wrong, all 8 layers conspire to ship the wrong thing efficiently. The thinking work happens *before* the loop.
- **Judgment-heavy tasks**: architecture decisions, subtle concurrency, auth/crypto. Critic is also an LLM; for these, do them yourself.
- **Same-model resonance**: builder and critic both being Claude can share blind spots. Use `CRITIC_MODEL=opus BUILDER_MODEL=sonnet` (or vice versa) to mitigate. Different *provider* is ideal but out of scope here.
- **50-LOC "while I'm here" creep**: the scope guard is a blunt instrument. A 20-LOC unrelated change inside the whitelist sneaks through. Code review still required at PR time.

## Halt-triage cheatsheet

```
exit 0  → success, all stories passed (or no stories pending)
exit 1  → max iter / cost / time hit. Resume by re-running.
exit 2  → thrash detected. STOP. Read .loopguard/diff.iter-*.patch. Likely:
          - spec contradiction
          - missing dependency / wrong test setup
          - critic and builder fighting over taste
          Manual patch the PRD, then resume.
```

## See also

- `scripts/loopguard.sh` — the orchestrator (the actual loop)
- `scripts/verify.sh` — verifier template (customize for your project)
- `scripts/critic.sh` — independent critic spawner
- `scripts/scope-check.sh` — Layer 7 implementation
- `scripts/thrash-detect.sh` — Layer 8 implementation
- `templates/prd.template.json` — PRD skeleton
- `templates/critic-prompt.md` — critic prompt (adversarial cold-read)
- `examples/` — two worked PRDs
- `docs/architecture.md` — deeper rationale
- `docs/failure-modes.md` — what can still go wrong
