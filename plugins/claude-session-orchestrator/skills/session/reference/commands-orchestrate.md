# Orchestrate Command — Unified Workflow Loop

> Paths/session/repo/branch come from `.claude/session-plugin.json` — substitute `<repo>`, `<wt>`, `<sess>`, `<gh>`, `<base>`.

**YOU ARE THE ORCHESTRATOR.** Run from the dedicated orchestrator Claude spawned by
`dispatch/start-orchestrator.ps1` into `<sess>:orchestrator` — its own detached worktree at
`<wt>/orchestrator`, NOT the main repo at `<repo>`. (It is also runnable from the main
session, but the dedicated orchestrator is the intended host.)

Sub-commands: `orchestrate [dashboard|dispatch|poll|pull|cleanup|verify <name>|verify-all]`

---

## THE CONTRACTS (do NOT violate — these are load-bearing)

These six rules are the whole reason the orchestrator is safe to run autonomously. Every
sub-command below is written to honor them. Read them first.

1. **No auto-merge.** The orchestrator **NEVER** runs `gh pr merge`. It reports green PRs as
   `READY FOR USER REVIEW`. The user authorizes every merge through their conversational Claude
   ("merge it"). There is no exception, no "CI is green so I'll merge" shortcut.

2. **Batch-scoping.** "This batch" = PRs whose head branch matches an **ACTIVE git worktree
   under `<wt>/`**, excluding the infra worktrees (`<wt>/orchestrator`, `<wt>/reviewer`,
   `<wt>/review-checkout`). To compute the batch on every poll:
   - `git -C <repo> worktree list --porcelain` → all active worktrees + their branches (parse each `branch refs/heads/<name>` line).
   - **Skip** the infra worktrees: `<wt>/orchestrator`, `<wt>/reviewer`, `<wt>/review-checkout` (detached HEAD, no branch line — these are the orchestrator + reviewer, not workers).
   - `gh pr list --repo <gh> --state open --json number,title,headRefName,statusCheckRollup,mergeable` → all open PRs.
   - **Filter:** keep ONLY PRs whose `headRefName` matches one of the active worktree branches.

   PRs whose worktrees were already torn down are OUTSIDE scope. PRs from previous sessions,
   the user's own work, and any branch without a live worktree under `<wt>/` are NOT in the
   batch. Do NOT report them, do NOT consider merging them, do NOT include them in status.

3. **Do NOT auto-tear-down. Keep workers alive.** A merged PR does NOT make a worker disposable —
   the user keeps it alive to iterate (tell the worker to fix → push → re-review, or work the
   checked-out branch) or to give it more tasks, and the work is already on the remote regardless.
   Tear down via `teardown/close-worker.ps1` (junction-first: detaches the node_modules junction(s)
   BEFORE `git worktree remove`) **ONLY** when the USER explicitly says that worker is done. Never
   auto-clean after a merge; never tear down a worktree with an open PR.

4. **Self-terminate.** End the loop when there are **no live worker windows AND no open PRs from
   this batch**. Print a summary, exit the loop, exit Claude.

5. **Never touch the main repo's working state.** The orchestrator **NEVER** runs
   `git checkout` against `<repo>`, **NEVER** runs `git pull origin <base>` in `<repo>`, and
   **NEVER** modifies or commits in its own worktree. Read-only git is fine
   (`git -C <abs-path> fetch`, `git -C <abs-path> status`, `git -C <repo> worktree list`).

6. **`/loop` is the cron.** Polling is driven by `/loop <interval> /session orchestrate poll`.
   Never use Windows scheduled tasks or PowerShell `Start-Sleep` polling loops. The PS scripts'
   job ends after launching Claude; the recurring cadence is `/loop`.

---

## The Workflow (How Everything Fits Together)

```
DISPATCH → MONITOR/SEND → POLL PRs → REPORT READY → (USER MERGES) → CLEANUP → repeat
   │            │              │            │              │            │
   │            │              │            │              │            └─ close-worker.ps1 (junction-first)
   │            │              │            │              └─ user says "merge it" to their Claude
   │            │              │            └─ flag green batch PRs as READY FOR USER REVIEW
   │            │              └─ gh pr list + CI status, filtered to the batch
   │            └─ psmux capture-pane + psmux send-keys
   └─ psmux-dispatch.ps1 (worktree + psmux window + Claude worker)
```

### Full Loop (when `orchestrate poll` runs):

1. **Compute the batch** (see Contract 2) — active worktree branches ∩ open PRs.
2. **Read agent terminals** — what is each live worker doing right now?
3. **Send messages** — nudge stuck agents, tell done agents to test + create PRs.
4. **Check open PRs (batch-scoped)** — which have passing CI?
5. **Report green PRs as READY FOR USER REVIEW** — never merge (Contract 1).
6. **Cleanup** — for any batch PR observed merged by the user, tear down via `close-worker.ps1` (Contract 3).
7. **Self-terminate check** — no live workers AND no open batch PRs → summarize and exit (Contract 4).
8. **Report** — compact summary of what happened this poll.

---

## `orchestrate` / `orchestrate dashboard`

Status dashboard of the batch: active worktrees + their open PRs + live workers.

### Steps

1. Active worktrees + branches:
   ```
   git -C <repo> worktree list --porcelain
   ```
2. Open PRs, then filter to the batch (Contract 2):
   ```
   gh pr list --repo <gh> --state open --base <base> --json number,title,headRefName,mergeable,statusCheckRollup
   ```
3. Live workers:
   ```
   psmux list-windows -t <sess>
   ```
4. Display the combined dashboard (skip the `orchestrator` window itself):
   ```
   ORCHESTRATOR DASHBOARD
   ======================
   Open PRs (this batch):
     #26  feature/f008-quiz   Lint OK  Types OK  Build OK    → READY FOR USER REVIEW

   Active Worktrees:
     f008-quiz      window: <sess>:f008-quiz   commits: 3   status: idle

   psmux windows: f008-quiz, f021-referral
   ```

---

## `orchestrate dispatch`

Launch new worktree sessions. Alias for `/session start <name>`, batch-friendly.

1. Determine the next pieces to build (from the spec/brief the user pointed you at — see
   the task brief in `.claude-bootstrap.md` and any spec it references).
2. For each piece to dispatch:
   ```
   /session start <name>
   ```
   (which runs `dispatch/psmux-dispatch.ps1` — worktree + psmux window + Claude worker + bootstrap)
3. Each becomes a `<sess>:<name>` psmux window, addressable by `capture-pane`/`send-keys`.
4. Report what was launched + the attach command (`psmux attach -t <sess>`).

For an issue-backlog blast, prefer `/session start-issues <n> <n> ...`
(`dispatch/psmux-dispatch-issues.ps1`).

---

## `orchestrate poll`

**THE MAIN LOOP.** Compute the batch, monitor agents, send messages, report green PRs as
READY FOR USER REVIEW, clean up after user-merged PRs. **No merging.**

### Phase 1: Compute the batch (Contract 2)

```bash
git -C <repo> worktree list --porcelain
gh pr list --repo <gh> --state open --base <base> --json number,title,headRefName,statusCheckRollup,mergeable
```
Keep only PRs whose `headRefName` matches an active worktree branch (excluding `orchestrator`).
Everything else is out of scope for this poll.

### Phase 2: Read Panes & Send Messages

1. List live workers:
   ```
   psmux list-windows -t <sess>
   ```
   Skip the infra windows: `orchestrator` and `reviewer`.

   **Headless build-ahead workers** (dispatched via `dispatch-codex.ps1`) are background
   processes, NOT psmux windows — `capture-pane` cannot see them. Enumerate them
   separately and fold them into the report + the self-terminate check:
   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/status/check-headless-workers.ps1" -Config "<repo>/.claude/session-plugin.json" -Json
   ```
   Each row reports `State` (RUNNING/COMPLETE/BLOCKED/EXITED) + `PR`. You cannot nudge a
   headless worker (no pane); if one is `BLOCKED` or `EXITED`, report it and let the user
   decide (re-dispatch / inspect its `Log`). A `COMPLETE` row with a PR feeds the same
   "READY FOR USER REVIEW" path as a psmux worker's PR.
2. For each worker window:
   ```
   psmux capture-pane -t <sess>:<name> -p
   ```
3. Analyze pane content and decide action:

   | Terminal Shows | Action |
   |---------------|--------|
   | "accept edits on" / waiting for input | Send `y` / acceptance |
   | Error messages / build failures | Send fix instructions |
   | `WORKTREE_STATUS: COMPLETE` / PR created / idle | No action needed |
   | `WORKTREE_STATUS: BLOCKED` + reason | Report the reason, stop nudging this worker |
   | Agent asking a question | Answer from the task brief in `.claude-bootstrap.md` and any spec it points to |
   | No progress for 2+ polls | Send nudge |
   | Done but no PR | Send: test + commit + push + PR command (project test commands from `config.layout`) |

4. Send via:
   ```
   psmux send-keys -t <sess>:<name> "<message>" Enter
   ```
   (See [commands-monitor.md](commands-monitor.md) for the message templates.)

### Phase 3: Report PR status — NEVER merge (Contract 1)

For each batch PR:
- **All checks passing + mergeable** → report it as `READY FOR USER REVIEW` with its number and URL. **Do NOT run `gh pr merge`.** The user authorizes the merge through their conversational Claude.
- **CI failing** → report it and nudge the owning worker to fix (the worker rebases/fixes in its own worktree; the orchestrator does NOT touch git in `<repo>` — Contract 5).
- **CI still running** → note it; the next poll will catch it.

### Phase 4: Verify Work (optional — the reviewer does the deep pass)

> The **reviewer** (`/session review`, spawned by `start-reviewer.ps1` alongside this
> orchestrator) does the real pre-merge verification: it checks each green PR out in its
> own `review-checkout` worktree, runs the project tests + `/code-review`, and labels it
> `READY-VERIFIED`. The orchestrator's verify below is a *shallow* deliverable-existence
> check; leave the deep gate to the reviewer and don't duplicate it. See
> [commands-review.md](commands-review.md).

For batch PRs, optionally verify the agent built what the brief asked:
1. Read the task brief (`.claude-bootstrap.md`) and any spec it points to — extract key deliverables.
2. Check each deliverable exists in the PR diff:
   ```
   gh pr diff <number> --name-only
   ```
3. Flag missing deliverables in the report (and optionally nudge the worker if it's still live).

### Phase 5: Review routing — tell the user HOW to review each green PR (Contracts 3 + 11)

Do **NOT** auto-tear-down merged workers — keep them alive (Contract 3). Instead, for each green
batch PR, classify it by lane and tell the user how to review it:
```bash
gh pr diff <n> --name-only          # compare paths against config.teams ownsPaths
```
- **Frontend-only** (every changed path in the frontend lane) → report "review on the Vercel
  preview" with the PR/preview URL. No local checkout.
- **Backend / full-stack** (any backend-lane path) → report it **needs a local checkout** so the
  user can run it on 3000/8000 (a preview can't exercise backend). Offer to fetch + check the branch
  out into the `review-checkout` worktree and `server-start` it.

Teardown is **user-driven only**: run `close-worker.ps1` (junction-first — detaches the
node_modules junction(s) BEFORE `git worktree remove`, kills the window, prunes) **only** when the
user explicitly says a worker is done. Never raw `git worktree remove` a worktree whose junctions are
still attached. Keep workers alive after merge for iteration.

### Phase 6: Self-terminate check (Contract 4)

If there are **no live worker windows, no RUNNING headless workers (check-headless-workers.ps1),
AND no open batch PRs**, print a final summary, exit the `/loop`, and exit Claude. Otherwise
continue. (Headless workers count as "live" while RUNNING — do not self-terminate out from under
a Codex worker that is still building.)

### Phase 7: Report

Print a compact summary:
```
POLL RESULTS
============
Ready for review:  #26 f008-quiz (CI green), #25 f021-referral (CI green)
Agents:            f008-quiz (idle, done), f045-progress (building)
Sent:              f045-progress ← "status check" nudge
Cleaned:           f008-quiz (PR merged by user → torn down via close-worker)
Blocked:           none
Out of scope:      (ignored — not in this batch)
```

---

## `orchestrate pull`

Alias for `/session pull` — show the PR dashboard, then (on the user's go) merge + pull +
cleanup. This is a **user-driven** command, not part of the autonomous loop: the orchestrator
itself never merges (Contract 1). See [commands-pull.md](commands-pull.md).

---

## `orchestrate cleanup`

Force-clean ALL worktree directories regardless of state (nuclear — confirm with the user first):

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/teardown/nuke-worktrees.ps1" -Config "<repo>/.claude/session-plugin.json"
psmux kill-session -t <sess>   # also tear down the psmux session
git -C <repo> worktree prune
```

For routine post-merge teardown of a single worker, prefer `teardown/close-worker.ps1` (Contract 3) —
`nuke-worktrees.ps1` is for blowing everything away.

---

## `orchestrate verify <name>`

Check built code against the brief's requirements.

### Steps

1. Read the task brief (`<wt>/<name>/.claude-bootstrap.md`) and any spec it points to.
2. Extract the deliverables list.
3. For each deliverable, verify file existence and feature checks (the project test commands from `config.layout` cover typecheck/build).
4. Display the scorecard:
   ```
   VERIFICATION: f008-quiz
   ===============================
   [PASS] Quiz assembly component
   [PASS] Question bank API
   [FAIL] Timer integration — not found
   [PASS] Typecheck passes
   Score: 3/4
   ```
5. If the agent is still running → send the missing items as a `send-keys` nudge.

---

## `orchestrate verify-all`

Run verify for ALL active batch worktrees / open batch PRs.

Display a matrix:
```
VERIFICATION MATRIX
===================
Feature              Types  Build  Deliverables  Score
─────────────────    ─────  ─────  ────────────  ─────
f008-quiz            PASS   PASS   3/4           75%
f021-referral        PASS   PASS   5/5           100%
```

---

## Commands Reference (psmux + scripts)

| Command / Script | Purpose |
|--------|---------|
| `psmux list-windows -t <sess>` | List live worker windows |
| `psmux capture-pane -t <sess>:<name> -p` | Read a worker's pane (no focus steal) |
| `psmux send-keys -t <sess>:<name> "<msg>" Enter` | Send a message / nudge |
| `dispatch/psmux-dispatch.ps1` | Dispatch a worktree worker (`-Name` + `-Task`/`-Bootstrap`/`-BootstrapFile`) |
| `dispatch/psmux-dispatch-issues.ps1` | Bulk dispatch one worker per GitHub issue (`-Issues 510,511,512`) |
| `dispatch/start-orchestrator.ps1` | Spawn the dedicated orchestrator Claude + its `/loop` (`-IntervalMin 5`) |
| `teardown/close-worker.ps1` | **Junction-first** post-merge teardown of one worker (`-Name <name>`) |
| `psmux kill-window -t <sess>:<name>` | Close one worker window (prefer `close-worker.ps1` for full teardown) |
| `psmux kill-session -t <sess>` | Tear down the whole session |
| `teardown/nuke-worktrees.ps1` | Kill all processes + delete all worktree dirs (nuclear) |
| `teardown/kill-worktree-agents.ps1` | Kill just the worker processes in worktrees |
| `teardown/cleanup-worktrees.ps1` | Gentler cleanup without process killing |
| `status/check-worktree-health.ps1` | Health check (git, deps, env). `-Name <n>` or `-All` |
| `util/force-remove-dir.ps1` | pwsh long-path-safe recursive delete |

---

## Using with /loop

The orchestrator's poll cadence IS `/loop` (Contract 6). The dedicated orchestrator Claude
(spawned by `start-orchestrator.ps1`) starts it itself:
```
/loop 5m /session orchestrate poll
```

Each tick:
- Computes the batch (Contract 2).
- Reads and nudges live workers.
- Reports green batch PRs as READY FOR USER REVIEW (never merges — Contract 1).
- Cleans up worktrees whose PRs the user has merged, via `close-worker.ps1` (Contract 3).
- Self-terminates when no workers and no open batch PRs remain (Contract 4).

The loop is session-only — it dies when Claude exits. Never replace it with a scheduled task
or a `Start-Sleep` loop.
