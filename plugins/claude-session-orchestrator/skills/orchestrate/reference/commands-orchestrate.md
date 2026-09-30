# Orchestrate: the protocol

> Substitute `<repo>`, `<wt>`, `<sess>`, `<gh>`, `<base>` from `status/resolve-config.ps1`.

You run this **in the user's own session**. The workers are psmux windows; you are not. There is
no orchestrator window and no reviewer window. Watching, reviewing and steering are all yours.

```
DISPATCH ──► MONITOR (loop) ──► BROWSER REVIEW, one branch at a time ──► FINDINGS to worker ──┐
(/crew:session)   health, panes, PRs     playwright-cli + dev-lifecycle checks    + PR comment     │
                                                                                                   │
        ◄───────────────────────── worker fixes, pushes ◄──────────────────────────────────────────┘
REVIEWED + GREEN ──► user says "merge" / "pull it all in" ──► INTEGRATE into <base> ──► page-by-page review there
```

---

## `start`

1. **The batch.** `git -C <repo> worktree list --porcelain` for the worker worktrees under `<wt>/`,
   and `gh pr list --repo <gh> --state open --json number,title,headRefName,statusCheckRollup`
   for their PRs. The batch is the worker branches; nothing else is in scope.
2. **One task per worker** (`TaskCreate`). Subject: `<worker> — #<issue> <title>`. Put the issue's
   own checklist into it: `gh issue view <n> --repo <gh> --json body` and take its checkbox lines
   (acceptance criteria, the page order's gates). This list is what you check the work against,
   and what you tick off on the issue as it's proved. Mark a task `in_progress` while its worker
   builds, and `completed` only when every box is ticked with evidence.
3. **Start the monitor loop:**
   ```
   /loop 10m /crew:orchestrate poll
   ```
   Ten minutes is the default; the user may ask for another cadence. The loop is the schedule:
   no scheduled tasks, no `Start-Sleep`.
4. Tell the user what you're watching: one line per worker, with its issue and PR.

---

## `poll` (the loop body)

Do these in order, and keep the report short.

### 1. Health: is every worker up?

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/status/check-crew-health.ps1" -Config "<repo>/.claude/session-plugin.json" -Json
```

| State | Do |
|---|---|
| `running` | nothing, unless its `PaneHash` hasn't changed for two polls and it hasn't finished: then read the pane and nudge |
| `pending` | unsent text is blocking it; submit it (`psmux send-keys -t <sess>:<name> C-m`) if it's clearly intended, else clear it (`C-u`) |
| `dialog` | a first-run menu: `Down` until `❯` is on the Yes option, then `Enter`, then resend its brief line with `send-to-worker.ps1` |
| `exited` / `missing` | tell the user, and offer `/crew:session resume <name>` |

### 2. Progress: what is each worker doing?

`psmux capture-pane -t <sess>:<name> -p -S -40` for each worker. Nudge with
`send-to-worker.ps1` when a worker is stuck, erroring, asking a question its brief answers, or
done without a PR. Templates: [commands-monitor.md](commands-monitor.md). One clear instruction,
never a vague "status?".

**Is it running its skill?** A worker whose brief opens with `## 0. Your skill: /<skill>` (a
`Page:` issue gets `dev-lifecycle:page-web` or `dev-lifecycle:page-app`) must invoke that skill
first and follow it. Check the transcript, not the worker's own report:

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/status/check-worker-skills.ps1" -Config "<repo>/.claude/session-plugin.json"
```

`MISSING: <skill>` on a worker that has started building → stop it now, before more work piles
up on the wrong process: `send-to-worker.ps1` with "Stop. Invoke /<skill> with the Skill tool
and follow it from the step you have not done; keep what you built that the skill's steps
confirm." Check again next poll. It also lists every skill and agent the worker did call: a
step the skill names with no call behind it is not done, whatever the pane says.

**Parked at a gate?** `WORKTREE_STATUS: WAITING` means the skill stopped for the person (a
review board, a section canvas). Show the user the `LINK` and the `ASK`, and send their pick
back with `send-to-worker.ps1`. Never pick for them.

### 3. PRs: what changed?

`gh pr list --repo <gh> --state open --json number,headRefName,headRefOid,statusCheckRollup,mergeable`.
Note per worker: PR opened, new commits since you last reviewed (`headRefOid` changed), CI red,
or `mergeable` gone `CONFLICTING`. CI red or conflicting → tell the worker exactly that (for a
conflict: rebase onto `origin/<base>` and push).

### 4. Review the next branch (ONE per poll)

Pick **one** worker whose branch is ready and not yet reviewed at its current commit. Ready means
a PR exists, or the worker reports it's done. Prefer the one that has waited longest, and put a
PR whose files overlap another's after the one it overlaps. Then run the full browser review:
[browser-review.md](browser-review.md).

One branch per poll keeps the browser and the dev servers to one at a time, and each review
thorough. The next poll takes the next branch.

### 5. Keep the record true

- Tick the issue/PR checkboxes you proved in this review (evidence in the comment).
- Update the worker's task: its checklist items, and its status.
- The board, if configured: move items per the conductor's board protocol
  ([commands-board.md](../../session/reference/commands-board.md)).

### 6. Report

```
POLL 14:20
  health      4 running, 1 pending (fixed: submitted its brief)
  reviewed    #73 jobs-filters: 3 findings → sent to worker, PR commented
  waiting     #74 (new commits, next), #76 (CI running)
  verified    #71 (all boxes ticked; ready for your merge)
  skills      #75 MISSING dev-lifecycle:page-web → told to start it
  gate        #72 review board waiting on you: <link>
  stuck       none
```

### 7. Stop when done

The batch is done when every worker's PR is merged or closed, or the user says so. Then stop the
loop, mark the remaining tasks, and give the user a final summary: what merged, what's open, and
which issues still have unticked boxes.

---

## `integrate`: "pull it all in"

On the user's word only. They want to see all the work together, on their machine.

1. Take the PRs you've reviewed and that are green. Order them by file overlap: disjoint PRs in
   any order, overlapping ones sequenced.
2. Merge each into `<base>`: `gh pr merge <n> --repo <gh> --squash`, or the project's own merge
   method from its CLAUDE.md. Re-check `mergeable` after every merge; a PR that turns
   `CONFLICTING` goes back to its worker to rebase.
3. Pull `<base>` into the main checkout (`/crew:session pull`), start its dev server on the
   project's port, and tell the user the URL.
4. **Review there, page by page**: the browser review against the integrated branch, one page at a
   time, checking links across pages as well as within them. Findings go back to the worker that
   owns the page, or into a new issue when that worker is gone.
5. Workers stay alive after merge. Teardown is the user's call (`/crew:session done`).

---

## `review <worker>`

The browser review of one worker's branch, now, outside the loop:
[browser-review.md](browser-review.md).

## `stop`

End the loop and report where everything stands.

---

## Scripts and tools

| Tool | Use |
|---|---|
| `status/check-crew-health.ps1 -Json` | every worker's state: running / pending / dialog / exited / missing |
| `status/check-worker-skills.ps1 [-Name <w>] [-Required a,b] [-Json]` | from the transcripts: did each worker invoke its brief's skill, and which skills and agents it called |
| `psmux capture-pane -t <sess>:<name> -p -S -40` | read a worker's pane |
| `dispatch/send-to-worker.ps1 -Name <name> -Message "<one line>"` | tell a worker something, verified submitted |
| `server/dev-server.ps1` / `backend-server.ps1 -AutoPort -Dir <wt>/<name>` | run a worker's branch beside the user's own servers |
| `playwright-cli` | the browser (see browser-review.md) |
| `gh issue view`, `gh pr view/diff/comment/review/edit` | the issue's checklist and the PR record |
