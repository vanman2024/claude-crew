---
name: session-cloud
description: The CONDUCTOR role in a crew build, cloud lane - the user's own session. Dispatches parallel workers as native `claude --cloud` sessions instead of psmux windows, launches the cloud orchestrator and reviewer, relays the user's feedback into worker sessions via the native follow-up command, merges on the user's go-ahead into the detected integration branch, pulls merged work into the local checkout, and archives workers when the user says they are done. No psmux, no local worktrees for workers - driven by the same .claude/session-plugin.json as /crew:session. Triggers on "/crew:session-cloud", "dispatch to the cloud", "use cloud workers", "blast through these issues in the cloud".
argument-hint: "[status|plan|start|start-issues|launch|review-start|relay|local|merge|pull|done|list|resume] [name|issue-numbers|PR#]"
disable-model-invocation: false
allowed-tools: Bash(git *), Bash(gh *), Bash(claude *), Bash(node *), Bash(bash *), Read, Write, Edit, Glob, Grep, ListAgents, SendMessage, mcp__claude_ai_GitProjects__project_get, mcp__claude_ai_GitProjects__project_list, mcp__claude_ai_GitProjects__project_list_fields, mcp__claude_ai_GitProjects__project_search_items, mcp__claude_ai_GitProjects__github_resolve_issue, mcp__claude_ai_GitProjects__github_resolve_pull_request, mcp__claude_ai_GitProjects__project_add_item_with_fields, mcp__claude_ai_GitProjects__project_update_item_field, mcp__claude_ai_GitProjects__project_bulk_update_items
---

# Session-cloud: the conductor, cloud lane

**This is `/crew:session`'s sibling, not its replacement.** Same four roles, same
governance (no-auto-merge, only the conductor merges, only on the user's word). The only
thing that changes is what runs a worker: a `claude --cloud` session instead of a psmux
window over a local worktree. Nothing in `/crew:session` or its scripts is touched by this
skill existing. Pick this lane when the batch is wide (tens of workers, not 3-5) or the user
wants to close their laptop — `/crew:session`'s psmux lane is still the right call for a
build the user wants to watch on this machine.

## Which role are you? Check this first

Look at the first message a fresh conversation received.

- **It opens with "You are the Orchestrator Claude (cloud lane)" or "You are the Reviewer
  Claude (cloud lane)"** → you are that role. Use `/crew:orchestrate-cloud` or
  `/crew:review-cloud`. Stop reading here.
- **Neither** → you are the **conductor**: the user's own session, in their main checkout.
  Everything below is yours.

## The four roles, cloud lane

| Role | Where | Job | Merges? Touches the main checkout? |
|---|---|---|---|
| Workers | one `claude --cloud` session per piece of work | Build one piece, open a PR | No |
| Orchestrator | one `claude --cloud` session, dispatched once per batch, loops itself | Poll workers, nudge stuck ones, flag green PRs `READY FOR USER REVIEW` | No |
| Reviewer | one `claude --cloud` session, dispatched once per batch, loops itself | Test + `/code-review` each green PR, label `READY-VERIFIED`, order the merge queue | No |
| **Conductor (you)** | The user's session, main checkout | **Everything that involves the user or their machine** | **Yes, the only one** |

Workers, orchestrator and reviewer are all cloud sessions now — none of them run on this
machine, none of them need this machine awake. Only you do.

### What the conductor does, in the order it usually happens

0. **Plan**, when the user brings a spec and there are no issues for it yet (`plan`) — identical
   protocol to `/crew:session`'s `plan`: cut the spec into issues without inventing anything,
   show the plan, create on the user's word.
1. **Dispatch** workers (`start`, `start-issues`) and make sure the cloud orchestrator and
   reviewer are running (`launch`).
2. **Watch the batch**: `/loop 10m /crew:session-cloud status`, started by `launch`.
3. **Relay** the user's feedback into the right worker's cloud session (`relay`).
4. **Bring changes local** so the user can see them before merge (`local`) — unchanged from
   `/crew:session`: a cloud worker's branch is a normal GitHub branch, checked out and run
   the same way.
5. **Merge** when the user says so, into `<base>`, in overlap order (`merge`) — identical
   protocol to `/crew:session`'s `merge`.
6. **Pull** merged work into the main checkout (`pull`) — identical to `/crew:session`.
7. **Archive** a worker's cloud session only when the user says it is done (`done`).

**GitHub:** unchanged from `/crew:session` — issues and PRs through `gh`, the board through
the GitHub Projects MCP, never `gh project`. You are still the board's only writer.

## STEP 0: resolve the config

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/status/resolve-config.ps1" -Config "<repo>/.claude/session-plugin.json"
```

Same config file `/crew:session` uses. `worktreesPath` and `psmuxSession` are ignored in
this lane — nothing to substitute them into. Everything else is identical:
- `<repo>` → `repoPath`, `<gh>` → `githubRepo`
- `<base>` → the resolved `defaultBranch` (never the raw JSON value; see `/crew:session`'s
  STEP 0 for what `auto` means)
- the board → `githubProject`
- lane ownership → `teams.*.ownsPaths`, read the same way

No config yet → tell the user to run `/crew:session-init` (unchanged; that skill's output
works for both lanes).

## The batch state file — the one piece of new bookkeeping this lane needs

psmux workers are enumerable from `git worktree list` and `psmux list-windows`. A cloud
worker has neither — it exists only as a cloud session and, once it pushes, a branch and a
PR. Something has to remember which cloud sessions belong to *this* batch, so `status`,
`relay <name>` and `done <name>` can find them again. That something is a plain JSON file,
read and written directly with your own Read/Write/Edit tools — no script needed for this,
it is just a list:

```
<repo>/.claude/crew-cloud/<batch-name>.json
```

```json
{
  "batch": "<batch-name>",
  "base": "<base>",
  "orchestrator": { "sessionRef": "<url-or-id-or-null>", "dispatchedAt": "<iso timestamp>" },
  "reviewer":     { "sessionRef": "<url-or-id-or-null>", "dispatchedAt": "<iso timestamp>" },
  "workers": [
    {
      "name": "<worker-name>",
      "task": "<one-line task the worker was given>",
      "issue": 510,
      "sessionRef": "<url-or-id-or-null>",
      "prNumber": null,
      "dispatchedAt": "<iso timestamp>",
      "status": "dispatched|pr-open|ready-for-review|verified|merged|archived"
    }
  ]
}
```

`<batch-name>` is whatever you're calling this build (`start-issues`'s issue range, or the
spec's slug). One batch file per concurrent build; the conductor is the only writer, same
rule as the project board.

This is disposable, recompilable-from-GitHub state, the same category as dev-lifecycle's
`.work/`: if it disagrees with `gh pr list`, GitHub is right. Tell the user to add
`.claude/crew-cloud/` to the project's own `.gitignore` the first time this lane runs there.

### Capturing `sessionRef` honestly

**This is not fully scriptable, and pretending otherwise produces a batch file full of
`null`s nobody notices.** `claude --cloud "<task>"` prints a live provisioning checklist and,
once the session exists, names it — capture that output and look for a `claude.ai/code/`
URL or a `session_…`/`cse_…` id in it. When you get one, record it. When you don't (the
output didn't contain a clean id, or you couldn't tell), record `sessionRef: null` and don't
guess. A `null` ref is still recoverable two ways: `gh pr list --repo <gh> --json number,headRefName,title,createdAt` once the worker pushes (branches/PRs are the durable, GitHub-side identity), or asking the user to run `claude --teleport` and pick it from the session picker by name/timestamp. Tell the user plainly when a ref didn't capture — don't report `DISPATCHED` as if it fully succeeded.

## Quick Reference

| Command | What it does |
|---------|-------------|
| `status` | Batch health: read the batch file, check each worker's PR state via `gh`, read the orchestrator/reviewer's last report |
| `plan <spec...>` | Identical to `/crew:session`'s `plan` |
| `start <name>` | One cloud worker for one piece of work, then `launch` if the orchestrator isn't up |
| `start-issues <n> <n> ...` | Bulk — one cloud worker per GitHub issue |
| `launch` | Dispatch the cloud orchestrator (+ reviewer) if they aren't recorded as running in the batch file |
| `review-start` | Dispatch only the cloud reviewer |
| `relay <worker> "<msg>"` | Queue the user's feedback into a worker's cloud session |
| `local <worker\|PR#>` | Check out the worker's branch locally to look at it — same as `/crew:session`'s `local` |
| `merge <PR#...>` | Identical merge protocol to `/crew:session` |
| `pull` | Identical to `/crew:session` |
| `done <worker>` | Archive a worker's cloud session. Only when the user says so |
| `list` | Batch file contents + live PR state per worker |
| `resume <name>` | Re-dispatch a worker whose cloud session was lost, from its last known task + issue |

---

## `status`: is the batch actually moving?

The conductor's watchdog, and the body of `/loop 10m /crew:session-cloud status`.

1. **Read the batch file.** For every worker still short of `merged`/`archived`:
   - `gh pr list --repo <gh> --head <expected-branch-name> --json number,state,statusCheckRollup,updatedAt` —
     a PR that exists means the worker got there; note its number in the batch file if not
     already recorded.
   - No PR yet and `dispatchedAt` is more than a couple of hours old → the worker may be
     stalled or its `sessionRef` was never captured. Nudge it (see `relay`) if you have a
     `sessionRef`; otherwise say so and ask the user whether to `resume` it.
2. **Read the orchestrator's and reviewer's last report.** If you have their `sessionRef`,
   `claude -p "give me a one-line status" --cloud <sessionRef>` queues the ask; its answer
   arrives as a message to this session (native cross-session delivery — no polling needed,
   the reply comes to you). If Remote Control is connected, `ListAgents` also shows them
   directly, with their live state.
3. **Board in step?** Same as `/crew:session`: `project_search_items` for the batch, advance
   what's behind reality.
4. **Report**, one line each: fixed/nudged, ready for review, verified queue, blocked
   workers, merged PRs. Nothing new and nothing fixed → say so in one line.
5. **Stop the loop** when every worker in the batch file is `merged` or `archived` and the
   orchestrator/reviewer have nothing left to watch.

## `start <name>`

1. **Check existing state**: `gh pr list --repo <gh>` for a PR on the expected branch. One
   already exists and is green → report and STOP, same guard as `/crew:session`.
2. Decide the task (description or spec pointer) and write the batch file entry
   (`status: "dispatched"`) before dispatching, so a captured-`null` ref still leaves a
   record.
3. Dispatch:
   ```
   claude --cloud "<the same brief /crew:session's psmux-dispatch.ps1 would build: task + spec ref + this project's teams.<lane>.ownsPaths + the test/commit/PR contract with 'branch from <base>, target <base>, never merge, tell me when the PR is open'>"
   ```
   Build the brief text yourself, the same shape `_session-brief.ps1` builds for the psmux
   lane — reuse that file's wording by reading it, don't invent a differently-worded
   contract for this lane.
4. Capture the session reference per the section above; update the batch file.
5. Report: task, batch file entry, and that this worker is now cloud-hosted (nothing to
   `psmux attach` to — checking on it happens through `status` or the claude.ai/code URL if
   one was captured).
6. `launch` if the orchestrator isn't recorded as running.

## `start-issues <n> <n> ...`

Same per-issue shape as `/crew:session`'s bulk dispatch: `gh issue view` (skip if not OPEN)
→ branch name `fix/<n>-<slug>` → brief (issue body + team rules + `Closes #<n>` contract) →
`start <fix/<n>-<slug>>` for each. Report the per-issue table, move each dispatched issue's
board item to **In Progress**, then `launch`.

## `launch`

Skip either role already recorded as running in the batch file with a live `sessionRef`
(check with `claude -p "still there?" --cloud <sessionRef>` if in doubt — a failed send means
it's gone, re-dispatch).

```
claude --cloud "You are the Orchestrator Claude (cloud lane) for the <project> batch <batch-name>. Read <repo>/.claude/crew-cloud/<batch-name>.json for the worker list. Follow /crew:orchestrate-cloud exactly. Loop your own poll every few minutes until the batch is done, then stop."
```

And, unless `-NoReviewer`:

```
claude --cloud "You are the Reviewer Claude (cloud lane) for the <project> batch <batch-name>. Read <repo>/.claude/crew-cloud/<batch-name>.json for the worker list. Follow /crew:review-cloud exactly. Loop your own review cycle every few minutes until the batch is done, then stop."
```

Record both `sessionRef`s in the batch file. Verify they came up: a minute later,
`claude -p "status?" --cloud <sessionRef>` each and confirm a reply arrives. Then start your
own watchdog if it isn't running: `/loop 10m /crew:session-cloud status`.

## `review-start`

Only the reviewer, same brief shape as in `launch`.

## `relay <worker> "<message>"`

1. **Find the worker** in the batch file by name, branch, issue or PR number.
2. **Send it**:
   ```
   claude -p "<message>" --cloud <worker's sessionRef>
   ```
   This is the documented, cross-machine-safe way to queue a follow-up into a running cloud
   session — it works from this session's own Bash tool, no keystroke simulation, nothing to
   verify was "submitted" the way `send-to-worker.ps1` has to for a psmux pane. It queues and
   returns; the worker reads it at its next turn or between tool calls.
3. No `sessionRef` recorded → find the worker's PR instead (`gh pr list`) and leave a PR
   comment with the feedback (`gh pr comment <n> --body "..."`) as the fallback channel; say
   plainly that you used the fallback because the session ref was never captured.
4. Tell the user what you sent, and that the worker will act on it at its own next turn —
   there's no pane to re-check a minute later in this lane; `status` on a later tick is how
   you'll see it landed (new commit, updated `updatedAt` on the PR).

## `local <worker|PR#>` / `merge <PR#...>` / `pull`

**Identical to `/crew:session`.** A cloud worker's branch is an ordinary GitHub branch;
nothing about checking it out locally, merging it, or pulling it into the main checkout
changes because the worker that built it ran in the cloud. Follow `/crew:session`'s
protocol for these three verbatim, substituting nothing.

## `done <worker>`

Archive the worker's cloud session (tell the user to do it from claude.ai/code if you have
no way to do it from the CLI, or ask them to confirm before you consider it done) and mark
`status: "archived"` in the batch file. Only when the user says that worker is done. Never
after a merge by default — same rule as `/crew:session`.

## `list`

Read the batch file; for each worker, `gh pr view <n> --json state,statusCheckRollup,mergedAt`
if a PR number is recorded. Table: Name, Task, PR#, State, Status.

## `resume <name>`

The batch file has the worker's last known `task`/`issue`/`prNumber` even if `sessionRef` is
stale or was never captured. If a PR already exists and is still open, there is nothing to
resume — relay into it via a PR comment instead. If no PR exists and the session is
unreachable, re-`start <name>` with the same task; note in the batch file that this is a
second dispatch for that name.

---

## Critical Rules

1. **This lane never touches `/crew:session`'s scripts, worktrees, or psmux windows.** They
   are independent. A project can run both at once for different batches.
2. **`claude --cloud` and `claude -p "<msg>" --cloud <ref>` are run directly from Bash.**
   No PowerShell wrapper exists or is needed for this lane — there is no pane to inject
   keystrokes into.
3. **The batch file is the only state this lane keeps**, and the conductor is its only
   writer, same discipline as the project board.
4. **A `null` `sessionRef` is reported, never hidden.** Recovery is `gh pr list` or
   `--teleport`, not a silent retry loop.
5. **Only the conductor merges**, and only on the user's word — unchanged.
6. **Workers, orchestrator and reviewer all run `--dangerously-skip-permissions`-equivalent
   autonomy in the cloud** (cloud sessions default to auto mode for tool calls); the
   conductor does not.
7. **`gh` for issues and PRs; the GitHub Projects MCP for the board; never `gh project`.**
   Only the conductor writes to the board — unchanged.
8. **Never check a PR branch out in the main checkout.** Same rule as `/crew:session`.

## See also

- `/crew:session` — the psmux lane this mirrors; read it for `plan`, `local`, `merge`, `pull`
  in full, since those three are unchanged verbatim.
- `/crew:orchestrate-cloud`, `/crew:review-cloud` — the other two cloud-lane roles.
