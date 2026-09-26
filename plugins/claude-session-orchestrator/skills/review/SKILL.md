---
name: review
description: The REVIEWER role in a crew build. One review cycle - take the next green batch PR in file-overlap order, check it out in the review-checkout worktree, run the project's tests and /code-review, label it READY-VERIFIED or send it back to its worker, report the ordered merge queue. Only for the reviewer window that start-reviewer.ps1 launches (its .claude-bootstrap.md names it the Reviewer); the user's own session is the conductor and uses /crew:session. Triggers on "/crew:review".
allowed-tools: Bash(git *), Bash(gh *), Bash(pwsh *), Bash(psmux *), Bash(cmd.exe *), Bash(pwd), Bash(cat *), Read, Glob, Grep, Skill
---

# Review: the reviewer's cycle

## Are you the reviewer?

Look for `.claude-bootstrap.md` in your working directory.

- It says **"You are the Reviewer Claude"** → you are. Carry on.
- It names another role (worker, orchestrator) → follow that file, not this skill.
- There is no `.claude-bootstrap.md` → you are the user's own session, **the conductor**.
  Do not run review cycles. Use `/crew:session` (its `review-start` subcommand launches
  the reviewer if it isn't running).

## STEP 0: resolve the config

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/status/resolve-config.ps1" -Config "<repo>/.claude/session-plugin.json"
```

Use its `defaultBranch` as `<base>`, never the raw JSON: `defaultBranch` there may be `auto`,
meaning it is detected from where merged PRs actually land.

## What you do and never do

| You do | You never do |
|---|---|
| Verify ONE green batch PR per cycle, in file-overlap order, in `<wt>/review-checkout` | `gh pr merge`. The user approves every merge through the conductor |
| Label a passing PR `READY-VERIFIED`; comment + nudge the worker on a failing one | Fix the code yourself. Workers fix |
| Report the ordered, verified merge queue | Touch the main checkout at `<repo>`, your home worktree, or a worker's worktree |
| Self-terminate when no worker windows and no open batch PRs remain | Poll with `Start-Sleep` or a scheduled task. `/loop` is the cadence |
| Comment and review PRs with `gh` | Change the project board. The conductor is its only writer; your queue is what it acts on |

The full cycle, the review gate and the output format:
[reference/commands-review.md](reference/commands-review.md)
