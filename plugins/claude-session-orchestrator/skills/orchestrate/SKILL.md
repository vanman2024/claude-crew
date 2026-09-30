---
name: orchestrate
description: The ORCHESTRATOR, run in the user's own session (the conductor) - never in a psmux window. Monitors every worker on a schedule until the batch is done, keeps one task per worker mirroring its issue's checklist, course-corrects workers in their psmux windows, and reviews each worker's branch ONE AT A TIME in a real browser with playwright-cli (widths, links, interactions, console, network) plus the dev-lifecycle verification and page skills and /code-review, then sends findings back to the worker and ticks the issue/PR. Review is part of this; there is no separate reviewer. Triggers on "/crew:orchestrate", "orchestrate them", "monitor the workers", "are you monitoring them", "check their work in the browser", "keep them on track".
argument-hint: "[start|poll|review <worker>|integrate|stop]"
allowed-tools: Bash(git *), Bash(gh *), Bash(pwsh *), Bash(psmux *), Bash(playwright-cli *), Bash(npm *), Bash(cmd.exe *), Bash(pwd), Bash(cat *), Read, Glob, Grep, Skill, TaskCreate, TaskUpdate, TaskList, TaskGet
---

# Orchestrate: you watch, check and steer the whole batch

## Where this runs

**In the user's own session**, the same one that dispatched the workers (`/crew:session`). You
are the conductor *and* the orchestrator. The only psmux windows are the **workers**; there is
no orchestrator window and no reviewer window, and you never launch one. Review is not a
separate role either: it is the browser review below.

If this session is a worker (it has a `.claude-bootstrap.md` in its working directory), stop:
workers don't orchestrate.

## STEP 0: resolve the config

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/status/resolve-config.ps1" -Config "<repo>/.claude/session-plugin.json"
```

`<base>` is the resolved `defaultBranch` (never the raw JSON, which may say `auto`). Substitute
`<repo>`, `<wt>` (worktreesPath), `<sess>` (psmuxSession), `<gh>` (githubRepo) the same way.

## Subcommands

| Command | What it does |
|---|---|
| `start` | Build the task list, then begin the monitor loop. Run once, after workers are dispatched |
| `poll` | One pass: health, progress, PRs, then the next browser review. The loop body |
| `review <worker>` | The browser review of one worker's branch, now |
| `integrate` | On the user's word: bring all green, reviewed PRs into `<base>` so everything is visible together, then review page by page there |
| `stop` | End the loop |

Full protocol: [reference/commands-orchestrate.md](reference/commands-orchestrate.md). The
browser review, step by step: [reference/browser-review.md](reference/browser-review.md). Nudge
templates: [reference/commands-monitor.md](reference/commands-monitor.md).

## The contract

| You do | You never do |
|---|---|
| Monitor on a schedule (`/loop`) and **stop the loop when the batch is done** | Launch an orchestrator or reviewer window, or poll with `Start-Sleep` |
| Keep **one task per worker**, with its issue's checklist items as the steps, and keep them true | Let your task list and the issue/PR checkboxes disagree |
| Review each worker's branch **one at a time**, in a real browser with `playwright-cli` (headed) | Use Claude in Chrome or gstack browse for this, unless the project's `browserVerify` says so |
| Run the checks the work is owed: the issue's checklist, the project's gates (CLAUDE.md, DESIGN.md, the spec), `dev-lifecycle:verify`, the `dev-lifecycle:page-web` / `page-app` checks for pages, `/code-review` | Fix a worker's code yourself. Workers fix; you tell them exactly what |
| Send findings back into the worker's window (`send-to-worker.ps1`) and onto the PR | Leave the user to find what you could have checked |
| Tick issue/PR checklist boxes only with evidence (a screenshot, a command's output) | Tick a box on a claim |
| Merge only on the user's word, into `<base>` | Merge because CI is green |
