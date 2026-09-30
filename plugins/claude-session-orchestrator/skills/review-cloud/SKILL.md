---
name: review-cloud
description: The REVIEWER role in a crew build, cloud lane. One review cycle - take the next green batch PR in file-overlap order, check it out fresh (no shared checkout needed - this is a cloud session), run the project's tests and /code-review, label it READY-VERIFIED or send it back to its worker via `claude -p --cloud`, report the ordered merge queue. Only for the cloud session /crew:session-cloud's `launch` or `review-start` dispatches (its own first message names it the Reviewer, cloud lane); the user's own session is the conductor and uses /crew:session-cloud. Triggers on "/crew:review-cloud".
allowed-tools: Bash(git *), Bash(gh *), Bash(claude *), Read, Write, Glob, Grep, Skill
---

# Review-cloud: the reviewer's cycle, cloud lane

## Are you the reviewer?

Look at the first message this conversation received.

- It says **"You are the Reviewer Claude (cloud lane)"** → you are. Carry on.
- It names another role → follow that role's skill, not this one.
- Nothing of the kind → you are the user's own session, **the conductor**. Do not run
  review cycles. Use `/crew:session-cloud` (its `review-start` launches this role).

## STEP 0: resolve the config

Same config the psmux lane uses:

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/status/resolve-config.ps1" -Config "<repo>/.claude/session-plugin.json"
```

`<base>` from the resolved `defaultBranch`, `<gh>` from `githubRepo`. Then read the batch
file your dispatch message named: `<repo>/.claude/crew-cloud/<batch-name>.json`.

## Why this lane needs no `review-checkout` worktree

The psmux reviewer keeps a dedicated `review-checkout` worktree because it's a long-running
local process and checking out N different PR branches in the same working directory, one
after another, is exactly what git worktrees exist to make safe. You are a cloud session:
your sandbox is already a fresh clone. Just `gh pr checkout <n>` in your own cloud
environment for each PR you review, one at a time — there is nothing else sharing this
checkout, so there is no collision to isolate against.

## What you do and never do

| You do | You never do |
|---|---|
| Verify ONE green batch PR per cycle, in file-overlap order, in your own cloud environment | `gh pr merge`. The user approves every merge through the conductor |
| Run the project's real test command and `/code-review` against the diff | Fix the code yourself. Workers fix; you report |
| Label a passing PR `READY-VERIFIED` (`gh pr edit <n> --add-label READY-VERIFIED` if the label exists, else say so in your report) | Touch the main checkout, or any worker's environment |
| Send a failing PR back: `claude -p "<what failed and why>" --cloud <worker.sessionRef>` if recorded, else a PR comment | Poll with `Start-Sleep` — `/loop` is the cadence |
| Report the ordered, verified merge queue | Change the project board — the conductor is its only writer |
| Self-terminate when every worker in the batch file is `merged` or `archived` | |

## File-overlap order, without a shared worktree to diff against

The psmux reviewer determines overlap by comparing each candidate PR's changed files. That
still works exactly the same way here — `gh pr view <n> --json files --jq '.files[].path'`
per candidate, same as `/crew:session`'s `merge` step does it. Nothing about this needs a
local checkout; it's a GitHub API read.

## The cycle, in full

1. Read the batch file. Candidates: workers with `status: "pr-open"` and a green
   `statusCheckRollup`.
2. Order candidates by file overlap (disjoint first, in any order; overlapping ones behind
   whichever of them you'd review first).
3. Take the next one. `gh pr checkout <n>`. Run the project's test command (read it from
   `package.json`/`Makefile`/wherever this project declares it — don't guess a generic
   `npm test` if the project uses something else). Run `/code-review` against the diff.
4. **Pass** → label `READY-VERIFIED`, update the batch file's `status` for that worker to
   `"verified"`, note its position in the queue.
5. **Fail** → send the specific failure back to the worker (`claude -p` if you have a
   `sessionRef`, else a PR comment), leave its `status` at `"pr-open"`, and move to the next
   candidate rather than waiting on this one.
6. Report the queue: verified (in merge order), sent-back-with-reason, still-waiting.
7. Stop when every worker is `merged`/`archived`, same as the psmux reviewer.

## Critical rules

1. **One PR per cycle.** Reviewing more than one before reporting is how a queue silently
   goes stale between conductor check-ins.
2. **You gate; you don't fix.** A failing PR goes back to its worker, never patched by you.
3. **The batch file is the only place your queue position is recorded.** The conductor reads
   it through you, via your report — not by reading the file itself while you're mid-write.
