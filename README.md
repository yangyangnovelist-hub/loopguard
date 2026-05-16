# loopguard

> Bounded autonomous Claude Code dev loop. Ralph-style fresh-context iteration with 8 guardrails the existing variants leave out: scope cap, cost cap, programmatic verifier, independent critic, anti-thrash, failure-context log.

## Why

Two things break the Claude Code dev-loop experience:

1. **Confirmation halts**: Claude stops mid-task to ask permission for steps you already authorized. Each halt costs latency, attention, and re-read tokens.
2. **Runaway loops**: wrap the task in `/loop` or one of the OSS Ralph variants and you get either a 40-file "comprehensive refactor" you didn't ask for, or a $400 month-of-Max-plan vaporized in days. Or both.

Both have the same root cause: no clear stop condition, no constraint on surface area.

loopguard fixes both by enforcing:
- one story per fresh-context `claude -p` call
- programmatic verifier (`scripts/verify.sh` exit 0) as the only "done" signal
- an independent critic (`claude -p --bare`) cold-reading the diff against the spec
- a scope guard that auto-reverts when the diff exceeds `max_diff_lines` or touches files outside the whitelist
- triple cost cap (iter, $, wall-clock)
- anti-thrash detection on 3 consecutive failed iters with ≥80% diff overlap

## Quick start

### 1. Install

```bash
git clone https://github.com/yangyangnovelist-hub/loopguard.git
cd loopguard
chmod +x scripts/*.sh
```

To use as a Claude Code skill (auto-loaded by name), symlink into your skills dir:

```bash
ln -s "$(pwd)" ~/.claude/skills/loopguard
```

### 2. Write a PRD

Copy `templates/prd.template.json` to `./prd.json` and fill it in:

```json
{
  "project": "todo-cli",
  "stories": [
    {
      "id": "S-001",
      "spec": "Add a --done flag to the list subcommand. When passed, only completed todos are printed.",
      "acceptance_criteria": [
        "scripts/verify.sh exits 0",
        "Running `node cli.js list --done` on the test fixture prints exactly 2 lines"
      ],
      "affected_files": ["src/cli.ts", "src/list.ts", "src/list.test.ts"],
      "max_diff_lines": 80,
      "status": "pending"
    }
  ]
}
```

Each story must be **implementable in one Claude Code context window**. Rule of thumb: ≤300 LOC diff. If it feels bigger, split it.

### 3. Run

From the root of YOUR project (not the loopguard repo):

```bash
PRD=./prd.json /path/to/loopguard/scripts/loopguard.sh
```

Or with custom caps:

```bash
PRD=./prd.json \
MAX_ITER=30 \
MAX_COST_USD=20 \
MAX_DURATION_S=14400 \
BUILDER_MODEL=sonnet \
CRITIC_MODEL=opus \
/path/to/loopguard/scripts/loopguard.sh
```

For unattended overnight runs, wrap in `/background`:

```
/background "cd ~/my-project && bash /path/to/loopguard/scripts/loopguard.sh"
```

### 4. Read the output

The loop self-terminates on:
- **exit 0** — all stories `status: passed` in the PRD. Done.
- **exit 1** — soft halt: hit `MAX_ITER` / `MAX_COST_USD` / `MAX_DURATION_S`. Re-run to resume.
- **exit 2** — hard halt: thrash detected (3 consecutive failed iters with ≥80% same diff). Human required. Read `.loopguard/diff.iter-*.patch`, patch the PRD, restart.

Per-iter logs live in `.loopguard/`. Failure summary in `.loopguard/progress.md`.

## The ten layers (v0.2)

| # | Layer | Provenance | Where |
|---|---|---|---|
| 1 | PRD discipline | snarktank/ralph (19k) + jmilinovich/goal-md | `templates/prd.schema.json` |
| 2 | Fresh context per iter | snarktank/ralph (canonical) | `claude -p --no-session-persistence` |
| 3 | Triple cost cap (iter / $ / time) | AnandChowdhary/continuous-claude (1.3k) | env vars + `--max-budget-usd` |
| **3b** | **Rate cap (calls/hour)** | **frankbria/ralph-claude-code (9k)** | `MAX_CALLS_PER_HOUR` |
| 4a | Programmatic verifier | snarktank "feedback loops" | `scripts/verify.sh` |
| **4b** | **Dual exit gate (`EXIT_SIGNAL`)** | **frankbria (9k)** | builder prompt + grep in loop |
| 5 | Independent critic (`--bare`) | own integration of `claude -p --bare` | `scripts/critic.sh` |
| **5b** | **Council of critics (opt-in)** | **asdlc.io adversarial review + Apex-CodeGenesis + MAVEN paper 2026** | `scripts/council.sh` |
| 6a | Failure log | snarktank `progress.txt` | `.loopguard/progress.md` tail-60 |
| **6b** | **Cumulative learnings** | **snarktank AGENTS.md pattern** | `.loopguard/LEARNINGS.md` |
| 7 | Scope guard (own) | uniquely loopguard's | `scripts/scope-check.sh` |
| 8 | Anti-thrash | frankbria circuit breakers | `scripts/thrash-detect.sh` |

See [`docs/why.md`](docs/why.md) for the full project-by-project comparison with real star counts, and [`docs/architecture.md`](docs/architecture.md) for the per-iter sequence diagram.

## Comparison (real star counts)

| | ⭐ | Fresh ctx | $ cap | Rate cap | Verifier | EXIT_SIGNAL | Critic | Council | Scope | Thrash | Learnings |
|---|---|---|---|---|---|---|---|---|---|---|---|
| [snarktank/ralph](https://github.com/snarktank/ralph) | 19k | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | AGENTS.md |
| [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code) | 9k | ✗ Stop-hook | partial | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ |
| [continuous-claude](https://github.com/AnandChowdhary/continuous-claude) | 1.3k | partial | ✓ | partial | ✓ | partial | ✓ Codex | ✗ | ✗ | partial | ✗ |
| Official ralph-loop | — | ✗ | ✗ | ✗ | weak | weak | ✗ | ✗ | ✗ | ✗ | ✗ |
| Native `/goal` | — | ✗ | ✗ | ✗ | weak | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **loopguard** | new | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ opt-in | ✓ | ✓ | ✓ |

## What it WON'T fix

- Bad PRDs. The thinking work is yours.
- Judgment calls (architecture, subtle concurrency, auth). Critic is also an LLM.
- Cross-story coordination. Stories run sequentially in PRD order; order them yourself.
- Tests that pass on broken code. Verifier is only as good as the tests you point it at.

See [`docs/failure-modes.md`](docs/failure-modes.md) for full known-limitations list.

## Requires

- Claude Code CLI (`claude`) authenticated
- `git`, `jq`, `bash` 4+
- A project where tests/lint/types run in under ~60s (verify.sh runs every passing iter; slow tests = expensive loop)
- Either `--dangerously-skip-permissions` understood (run in worktree / container / branch you can throw away) or you've audited the `Edit,Read,Write,Bash` tool set

## Repo layout

```
loopguard/
├── SKILL.md                # Claude Code skill prompt
├── README.md
├── LICENSE                 # MIT
├── scripts/
│   ├── loopguard.sh        # main orchestrator
│   ├── verify.sh           # programmatic exit gate (auto-detects stack)
│   ├── critic.sh           # spawns --bare critic
│   ├── scope-check.sh      # diff size + whitelist + dep-file guard
│   └── thrash-detect.sh    # 3-iter overlap halt
├── templates/
│   ├── prd.template.json
│   ├── prd.schema.json
│   └── critic-prompt.md    # canonical critic prompt
├── examples/
│   ├── prd-minimal.json    # 2-story example
│   └── prd-feature-flag.json
└── docs/
    ├── architecture.md
    ├── failure-modes.md
    ├── why.md
    └── integration.md      # composing with /goal, /background, /batch, /schedule
```

## License

MIT. See [LICENSE](LICENSE).

## Contributing

PRs welcome. The most useful contributions right now:
- a `verify.sh` template for stacks I missed (Elixir, Ruby, .NET)
- a `critic.sh` variant that uses a different provider (Codex, Gemini) for second-opinion diversity
- a real-world PRD example that shipped (with diff stats and final $ spent)

Open an issue first for anything that changes `loopguard.sh` itself — the surface area is small on purpose.
