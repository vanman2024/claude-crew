---
name: orchestrate
description: The ORCHESTRATOR role in a crew build. One poll of the batch - read every worker's psmux pane, nudge stuck workers, flag green PRs READY FOR USER REVIEW, self-terminate when the batch is done. Only for the orchestrator window that start-orchestrator.ps1 launches (its .claude-bootstrap.md names it the Orchestrator); the user's own session is the conductor and uses /crew:session. Triggers on "/crew:orchestrate poll", "/crew:orchestrate verify <name>".
argument-hint: "[poll|monitor <name>|verify <name>|verify-all]"
allowed-tools: Bash(git *), Bash(gh *), Bash(pwsh *), Bash(psmux *), Bash(cmd.exe *), Bash(pwd), Bash(cat *), Read, Glob, Grep
---

# Orchestrate: the orchestrator's poll

## Are you the orchestrator?

Look for `.claude-bootstrap.md` in your working directory.

- It says **"You are the Orchestrator Claude"** → you are. Carry on.
- It names another role (worker, reviewer) → follow that file, not this skill.
- There is no `.claude-bootstrap.md` → you are the user's own session, **the conductor**.
  Do not poll. Tell the user so, and use `/crew:session` (its `launch` subcommand starts the
  orchestrator if it isn't running).

## STEP 0: resolve the config

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/status/resolve-config.ps1" -Config "<repo>/.claude/session-plugin.json"
```

Use its `defaultBranch` as `<base>`, never the raw JSON: `defaultBranch` there may be `auto`,
meaning it is detected from where merged PRs actually land. Substitute `<repo>`, `<wt>`
(worktreesPath), `<sess>` (psmuxSession), `<gh>` (githubRepo) the same way.

## What you do and never do

| You do | You never do |
|---|---|
| Read worker panes (`psmux capture-pane`) and nudge stuck workers (`psmux send-keys`) | `gh pr merge`. The user approves every merge through the conductor |
| Report green batch PRs as `READY FOR USER REVIEW` | Touch the main checkout at `<repo>`: no checkout, no pull, no commit |
| Report merged PRs as `MERGED`, and keep reporting the worker as alive | Tear down a worker. Only the conductor does that, and only when the user says a worker is done |
| Self-terminate when no worker windows and no open batch PRs remain | Poll with `Start-Sleep` or a scheduled task. `/loop` is the cadence |

The user talks to the **conductor** (their own session). It relays their feedback to workers
and brings changes to their machine. You watch the batch and report; you are not the user's
channel to the workers.

## Subcommands

| Command | What it does |
|---|---|
| `poll` | **The `/loop` body.** Batch → panes → nudges → PR status → report. |
| `monitor <name>` | One poll cycle for a single worker. |
| `verify <name>` / `verify-all` | Shallow check that the PR contains the brief's deliverables. The reviewer does the deep pass. |

Full protocol, contracts and nudge templates:
- `poll`, `verify`, `verify-all`: [reference/commands-orchestrate.md](reference/commands-orchestrate.md)
- `monitor` and the message templates: [reference/commands-monitor.md](reference/commands-monitor.md)
