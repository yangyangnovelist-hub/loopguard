# Integration with Claude Code native commands

loopguard is a bash orchestrator that calls `claude -p` per iter. It composes with — and does not duplicate — Anthropic's native autonomy commands.

## Native command map

| Command | Purpose | Composes with loopguard? |
|---|---|---|
| `/goal` | Condition-based autonomy in-session | No (overlapping) |
| `/loop` | Interval polling (1m–1h, status checks) | No (different purpose) |
| `/background` | Detached session, hours-long | **Yes** — wrap loopguard.sh |
| `/batch` | 5–30 parallel worktrees, one PR each | **Yes** — one loopguard per worktree |
| `/schedule` | Cron-based persistent task | **Yes** — cron a loopguard.sh run |

## Composition recipes

### A. Hours-long unattended run
```
/background "cd ~/my-project && bash scripts/loopguard.sh"
```
Detaches the loop so you can close the terminal. Status visible in `claude agents`. Loop self-halts on iter/cost/time/thrash.

### B. Parallel PRDs across worktrees
```bash
# Create 3 worktrees, one per PRD
git worktree add ../wt-auth   prd-auth-branch
git worktree add ../wt-search prd-search-branch
git worktree add ../wt-billing prd-billing-branch

# Run loopguard in each (separate terminals, or use /batch's spawning logic)
for wt in ../wt-*; do
  (cd "$wt" && PRD=./prd.json MAX_COST_USD=10 bash scripts/loopguard.sh) &
done
wait
```
Each loop is independent; failures isolate to one worktree. Total $ = sum of caps.

### C. Nightly run on cron
```
# crontab -e
0 2 * * * cd /Users/yourname/my-project && bash scripts/loopguard.sh > .loopguard/cron.log 2>&1
```
Couple with a tight PRD that only contains "Friday's leftover stories" so the nightly run is bounded.

### D. Scheduled via Claude Code `/schedule`
```
/schedule "0 2 * * *" "cd ~/my-project && bash scripts/loopguard.sh"
```
Same as cron but managed by Claude Code itself. Survives restarts (cron does too, but this keeps everything in one tool).

## When to NOT use loopguard with native commands

### `/goal` for "until tests pass" on a single tiny fix
Use `/goal` directly. loopguard's PRD discipline is overhead for a one-story task.

### `/loop 5m "check deploy status"`
Different purpose (polling, not implementing). Use `/loop`.

### Inside another skill's flow
`seo-geo-loop`, `site-launch-loop` etc. have their own loop discipline. Don't nest loopguard inside them; you'll end up with double accounting.

## Settings recommendations

Add to `~/.claude.json` or `.claude/settings.json` for the project:

```json
{
  "autoCompactEnabled": false
}
```

Disables auto-compact, which has been documented as a major cause of mid-session "lobotomization" — the model loses constraints and skill context around 80% window usage. Manual `/compact` with focused instructions is strictly better; loopguard bypasses both since each iter gets a fresh window anyway.

## What about hooks?

Don't use Stop hooks with loopguard. They were the root cause of Anthropic issue #55754 (50-min runaway burn). loopguard's fresh-context-per-iter design makes them unnecessary and risky.

PostToolUse hooks for things like enforcing a plan template are fine — they affect the builder's behavior inside one iter, not the iter loop itself.
