# Monitor Command — Single Worktree Poll Cycle

> Paths/session/repo/branch come from `.claude/session-plugin.json` — substitute `<repo>`, `<wt>`, `<sess>`, `<gh>`, `<base>`.

**One poll cycle for one worktree agent.** Designed to run on a loop via `/loop 3m /session monitor <name>`.

This is the **core feedback loop** between the orchestrator and worktree agents. Without it, agents get sidetracked and build nothing.

## Prerequisites

psmux running with a `<sess>` session and a window per worktree (created by
`dispatch/psmux-dispatch.ps1`). No Windows Terminal keybindings needed — psmux has native
`send-keys` and `capture-pane`. Confirm with `psmux ls`.

---

## Full Protocol

### Step 1: Check if a PR already exists

```bash
gh pr list --repo <gh> --state open --base <base> --head "feature/<name>" --json number,title,url
```

If a PR exists → **DONE**. Report success, no further polling needed. Output:
```
MONITOR [<name>]: PR #<n> created — <url>
STATUS: COMPLETE — stop polling
```

### Step 2: Check if the psmux window exists

```bash
psmux list-windows -t <sess>
```
Look for a window matching `<name>`. If none → the worker is gone. Report:
```
MONITOR [<name>]: No psmux window found — agent may have crashed
STATUS: NEEDS ATTENTION
```

### Step 3: Read the worker's pane

```bash
psmux capture-pane -t <sess>:<name> -p
```

(`-p` prints the pane contents to stdout without attaching or stealing focus.)

### Step 4: Check git progress

```bash
git -C "<wt>/<name>" log --oneline -5 2>/dev/null
git -C "<wt>/<name>" diff --stat 2>/dev/null
```

Count commits ahead of `<base>` + uncommitted changes. This tells you if the agent has written any code.

### Step 5: Analyze and decide action

Combine terminal output + git progress to determine agent state:

| State | Terminal Signs | Git Signs | Action |
|-------|---------------|-----------|--------|
| **BUILDING** | Code output, file edits, tool calls | Uncommitted changes, new commits | No action — agent is working. Report progress. |
| **WAITING FOR INPUT** | "accept edits on", "Do you want to", permission prompt | — | Send `y` or appropriate response |
| **ASKING QUESTION** | Agent asks about requirements, architecture, approach | — | Answer based on the task brief in `.claude-bootstrap.md` and any spec the brief points to. |
| **SIDETRACKED** | Discussing unrelated topics, refactoring other code, reading random files | No new commits, no changes to expected files | Send redirect (see messages below) |
| **STUCK/NO PROGRESS** | Same output as last poll, or idle | No new commits for 2+ polls | Send nudge (see messages below) |
| **ERRORING** | Build errors, type errors, import errors, test failures | — | Send fix instructions (see messages below) |
| **DONE BUT NO PR** | "COMPLETE", idle, all files written | Multiple commits, no uncommitted changes | Send test gate command (see below) |
| **TESTS NOT RUN** | No evidence the project test commands were run in the terminal | Agent about to create PR | Send test enforcement message |
| **PR CREATED** | Shows PR URL / `WORKTREE_STATUS: COMPLETE` | — | Verify tests were run in terminal output, then stop monitoring |
| **BLOCKED** | `WORKTREE_STATUS: BLOCKED` + reason | — | Report the reason, stop nudging this worker |

### Step 6: Send message if needed

```bash
psmux send-keys -t <sess>:<name> "<message>" Enter
```

The trailing `Enter` submits it (no ConPTY keybinding hack required — this is native psmux).

### Message Templates

The exact test command in these templates comes from the project's test commands
(from `config.layout` — see [build-protocol.md](build-protocol.md)). Substitute it for
`<project test command>` below.

**Redirect (sidetracked):**
```
Focus on your task deliverables. Re-read .claude-bootstrap.md and the spec it points to for the unchecked items. Build by layer (L0→L5), then: git add -A && git commit -m '<type>(<name>): <description>' && git push -u origin feature/<name> && gh pr create --repo <gh> --base <base>
```

**Nudge (no progress):**
```
Status check — what are you working on? Re-read .claude-bootstrap.md for the unchecked items. If you're done, create the PR: git add -A && git commit -m '<type>(<name>): <description>' && git push -u origin feature/<name> && gh pr create --repo <gh> --base <base> --title '<title>'
```

**PR creation (done but no PR) — MUST include test gates:**
```
You're done building. Before creating the PR, run the FULL test suite: <project test command>. Fix ALL failures. Update the spec/tasks list (check off completed items). Only after tests pass: git add -A && git commit -m '<type>(<name>): <description>' && git push -u origin feature/<name> && gh pr create --repo <gh> --base <base> --title '<type>(<name>): <description>'
```

**Test enforcement (agent skipping tests):**
```
STOP — do NOT create a PR without running tests. Run: <project test command>. This is mandatory. Fix any failures before pushing.
```

**Error fix (build/type errors):**
```
You have build errors. Fix them before creating the PR. Run: <project test command> to see all errors, then fix each one.
```

**Permission prompt:**
```
y
```

### Step 7: Report

Output a single-line status:
```
MONITOR [<name>]: <STATE> | commits: <n> | uncommitted: <n> files | action: <what you did or "none">
```

---

## Integration with `/session start`

After `/session start <name>` dispatches the worker via `psmux-dispatch.ps1`, it MUST invoke:

```
/loop 3m /session monitor <name>
```

This starts the poll loop automatically. The loop runs every 3 minutes until:
- The agent creates a PR (monitor detects it and reports COMPLETE)
- The user manually stops the loop
- The psmux window disappears (agent crashed)

---

## Integration with `/session orchestrate poll`

`/session orchestrate poll` runs the full workflow (PRs + monitor + report + cleanup-after-merge)
for ALL active workers in a single pass. For terminal monitoring it runs the same analysis as
`/session monitor` but across every active worktree at once. The logic is identical — only the
scope differs. (The orchestrator never merges — see [commands-orchestrate.md](commands-orchestrate.md).)

---

## Tracking State Across Polls

To detect "no progress for 2+ polls", compare current git state with previous:
- Track commit count and last commit hash.
- If same hash for 2 consecutive polls → agent is stuck.
- If uncommitted file count is growing → agent is building.
- If uncommitted file count drops to 0 with new commits → agent committed, may be about to PR.
