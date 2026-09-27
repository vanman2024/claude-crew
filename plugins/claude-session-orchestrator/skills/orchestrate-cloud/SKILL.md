---
name: orchestrate-cloud
description: The ORCHESTRATOR role in a crew build, cloud lane. One poll of the batch - read every worker's PR/session state via gh and native cross-session status, nudge stuck workers with `claude -p --cloud`, flag green PRs READY FOR USER REVIEW, self-terminate when the batch is done. Only for the cloud session that /crew:session-cloud's `launch` dispatches (its own first message names it the Orchestrator, cloud lane); the user's own session is the conductor and uses /crew:session-cloud. Triggers on "/crew:orchestrate-cloud poll".
argument-hint: "[poll|monitor <name>|verify <name>|verify-all]"
allowed-tools: Bash(git *), Bash(gh *), Bash(claude *), Read, Write, Glob, Grep, ListAgents, SendMessage
---

# Orchestrate-cloud: the orchestrator's poll, cloud lane

## Are you the orchestrator?

Look at the first message this conversation received.

- It says **"You are the Orchestrator Claude (cloud lane)"** → you are. Carry on.
- It names another role → follow that role's skill, not this one.
- Nothing of the kind → you are the user's own session, **the conductor**. Do not poll. Use
  `/crew:session-cloud` (its `launch` starts this role if it isn't running).

## STEP 0: resolve the config

Same config file `/crew:orchestrate` (the psmux orchestrator) uses:

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/status/resolve-config.ps1" -Config "<repo>/.claude/session-plugin.json"
```

Use its resolved `defaultBranch` as `<base>`, never the raw JSON. `<gh>` from `githubRepo`.
`worktreesPath`/`psmuxSession` don't apply to this lane.

Then read the batch file your dispatch message named:
```
<repo>/.claude/crew-cloud/<batch-name>.json
```
This is your worker list. You do not discover workers by scanning worktrees — there are
none. The batch file is the only source of who exists.

## What you do and never do

| You do | You never do |
|---|---|
| For each worker in the batch file: `gh pr list --repo <gh> --head <branch> --json number,state,statusCheckRollup,updatedAt` to see if it has a PR, and whether that PR is green | `gh pr merge`. The user approves every merge through the conductor |
| Nudge a stalled worker: `claude -p "<nudge text>" --cloud <worker.sessionRef>` if a `sessionRef` is recorded, else leave a PR comment as the fallback | Touch the main checkout at `<repo>`: no checkout, no pull, no commit |
| Report green batch PRs as `READY FOR USER REVIEW`, and merged ones as `MERGED` | Tear down or archive a worker. Only the conductor does that, on the user's word |
| Self-terminate when every worker in the batch file is `merged` or `archived` | Poll with `Start-Sleep` or a scheduled task — `/loop` is the cadence, same as the psmux orchestrator |
| Read issues and PRs with `gh` | Change the project board. The conductor is its only writer; your report is what it acts on |
| Reply when the conductor asks you for status (`claude -p "status?" --cloud <your-own-ref>` arrives as a message here) — answer in one line | Poll a worker more than once per cycle. One `gh pr list` call per worker per tick is enough |

The user talks to the **conductor**. You watch the batch and report; you are not the
conductor's channel to the workers — the conductor relays feedback itself via
`claude -p --cloud`, same as it always could.

## What "stalled" means without a pane to read

The psmux orchestrator compares a pane's hash across ticks. There is no pane here. Use
these signals instead, in order:

1. **No PR yet, and `dispatchedAt` is more than ~2 hours old.** The worker may never have
   started, or finished silently without pushing. Nudge it.
2. **A PR exists but `updatedAt` hasn't moved across several ticks, and it isn't green.**
   The worker may be stuck on a failing check. Nudge it with the specific failure
   (`gh pr checks <n>`), don't just ask "how's it going."
3. **A nudge gets no reply and the PR still doesn't move for another full cycle.** Report
   the worker as unreachable; let the conductor decide whether to `resume` it. Don't retry
   nudges indefinitely — one nudge per stall, then escalate to the conductor.

## Subcommands

| Command | What it does |
|---|---|
| `poll` | **The `/loop` body.** Batch file → PR status per worker → nudges → report. |
| `monitor <name>` | One poll cycle for a single worker. |
| `verify <name>` / `verify-all` | Shallow check that the PR contains the brief's deliverables (`gh pr diff <n> --name-only` against what the task asked for). The reviewer does the deep pass. |

### `poll`, in full

1. Read the batch file.
2. For each worker not yet `merged`/`archived`, check its PR state per the table above.
   Update the batch file's `status` field as things change (`pr-open`, `ready-for-review`).
3. Nudge exactly the workers that meet the stall criteria above.
4. Read the reviewer's queue if you can reach it (`claude -p "queue?" --cloud <reviewer.sessionRef>`,
   or `ListAgents`/read its transcript if Remote Control is connected) — fold its
   `READY-VERIFIED` ordering into your report rather than re-deriving it.
5. Report: green PRs `READY FOR USER REVIEW`, verified queue (if you have it), stalled/nudged
   workers, merged PRs. One line each.
6. If every worker is `merged` or `archived`: report the batch complete and stop looping.

## Critical rules

1. **The batch file is truth for who exists.** Never invent a worker or drop one because a
   `gh pr list` call came back empty for a tick — that's a worker with no PR yet, not a
   worker that doesn't exist.
2. **One nudge, then escalate.** Nudging a worker repeatedly wastes its context on messages
   it may never see if it's genuinely stuck.
3. **You read; the conductor writes the board.** Report is your only output to the board.
