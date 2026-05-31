# Core Commands — Detailed Steps

> Paths/session/repo/branch come from `.claude/session-plugin.json` — substitute `<repo>`, `<wt>`, `<sess>`, `<gh>`, `<base>`.

These are the long-form steps behind `start`, `resume`, and `finish` in SKILL.md.
In almost all cases the heavy lifting (worktree create/reuse, env copy, node_modules
junction, psmux window, Claude launch + boot handshake, bootstrap) is done by
`dispatch/psmux-dispatch.ps1` in one call. The manual per-step flow below is documented
so you understand what the script does and can repair it by hand if needed.

## `start` — Full Protocol

Infer a kebab-case worktree name from conversation context, or use `$ARGUMENTS[1]`.
Pick a stable, descriptive name (e.g., `f008-quiz-assembly`, `checkout-flow`). The branch
defaults to `feature/<name>` and the psmux window is named `<name>`.

### Step 0: Check existing PRs + worktrees for this work

Before creating anything, check if work already exists. This prevents duplicate worktrees
and wasted dispatches:

```bash
# Check for an existing open PR on this branch
gh pr list --repo <gh> --state open --base <base> --json number,title,headRefName,statusCheckRollup --search "feature/<name>"

# Check for an already-merged PR
gh pr list --repo <gh> --state merged --base <base> --json number,title,headRefName --search "feature/<name>" --limit 5

# Check for an existing worktree
git -C <repo> worktree list
```

**Decision matrix:**

| Existing State | Action |
|----------------|--------|
| **Open PR, CI passing** | Report: "PR #N exists and CI is green — ready for user review. Tell me 'merge it' to land it." STOP. |
| **Open PR, CI failing** | Report: "PR #N exists but CI is failing. Resuming worktree to fix." Continue to Step 1 in resume/`-SkipDeps` mode. |
| **Open PR, CI running** | Report: "PR #N exists, CI still running. Wait or resume worktree." STOP. |
| **Merged PR** | Report: "feature/<name> was already merged in PR #N. Nothing to do." STOP. |
| **Existing worktree, no PR** | Report: "Worktree exists but no PR yet. Resuming." Continue in resume/`-SkipDeps` mode. |
| **No PR, no worktree** | Fresh start. Continue to Step 1. |

Also show a quick summary of ALL open PRs so you have full context:
```bash
gh pr list --repo <gh> --state open --base <base> --json number,title,headRefName,statusCheckRollup
```

---

### Step 0.5: `<base>` health gate — MANDATORY before ANY dispatch

**DO NOT skip this. A broken `<base>` means every worker fails CI.**

Run the project's test/typecheck/build commands (from `config.layout` — see
[build-protocol.md](build-protocol.md)) against the main checkout at `<repo>`. ALL must
pass before you create a worktree:

- **Typecheck** — run the project's typecheck command. If errors: fix them, commit, push. Do NOT proceed with type errors on `<base>`.
- **Build** — run the project's build command. If errors: fix them, commit, push.
- **Tests** — run the project's test command. Fix failures before dispatching.

The exact commands come from `config.layout`. If the project declares none, run whatever
test/typecheck commands the repo uses and confirm they're green.

**ALL gates green → proceed to Step 1. ANY gate red → fix `<base>` first.**

---

### Step 1: Verify location
```
git -C <repo> rev-parse --show-toplevel
git -C <repo> branch --show-current
```
Expected: the main checkout at `<repo>` on `<base>`. If not, STOP.

### Step 2: Kill stale processes
Kill any lingering processes whose command line references this worktree path
(`<wt>/<name>`). OK if none found. On a clean dispatch there usually are none.

### Step 3: Fetch latest
```
git -C <repo> fetch origin <base>
```

### Step 4: Create or detect worktree

**If the directory already exists:**
```
git -C "<wt>/<name>" rev-parse --git-dir
```
- Succeeds → healthy, skip creation, report "Resuming existing worktree".
- Fails → zombie. Detach any node_modules junction(s) first (`cmd /c rmdir` on the link),
  then remove the dir, then prune:
  ```
  git -C <repo> worktree prune
  ```
  Prefer `teardown/close-worker.ps1` for this — it does junction-first teardown safely.

**Create:**
```
git -C <repo> worktree add "<wt>/<name>" -b "feature/<name>" origin/<base>
```
If the branch already exists: `git -C <repo> worktree add "<wt>/<name>" "feature/<name>"`

### Step 5: Copy environment files
Copy the env files declared in `config.layout` from `<repo>` into the matching paths under
`<wt>/<name>`. `psmux-dispatch.ps1` does this automatically (it skips files that already
exist in the worktree).

### Step 6: Wire dependencies — JUNCTION, do NOT install
**Junction the node_modules dir(s) (from `config.layout`) from the main checkout into the
worktree. Do NOT run an install in the worker.** This avoids GB-scale duplication and a long
install wait per worktree. Backend (if any) uses the main venv python by absolute path; there
is no per-worktree venv. `psmux-dispatch.ps1` handles all of this (skip with `-SkipDeps` when
reusing a warm worktree).

### Step 7: Install orchestrator hooks (optional)
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status/install-worktree-hooks.sh" "<wt>/<name>"
```
Optional — psmux `capture-pane` is the primary status channel.

### Step 8: Verify
```
git -C "<wt>/<name>" rev-parse --git-dir
git -C "<wt>/<name>" status --porcelain
```
Confirm the project's entry files / package manifests exist. If ANY check fails, STOP.

### Steps 4-8 consolidated: `dispatch/psmux-dispatch.ps1`

`psmux-dispatch.ps1` does the whole interactive dispatch in one call: creates the worktree
off `origin/<base>` (or reuses a healthy one), copies env files (from `config.layout`),
junctions node_modules from the main checkout (no install), writes `.claude-bootstrap.md`,
ensures the `<sess>` psmux session, adds a window for the worktree, launches the
**worker CLI** and runs its **boot handshake**, then sends the bootstrap message.
You do NOT need the old per-step WT flow.

The launch + handshake are driven by the resolved `workerCli` profile (see the
plugin README's "Worker CLI" section), so this step is CLI-agnostic. The default
`claude` profile launches `claude.cmd --dangerously-skip-permissions`, clears
`CLAUDECODE`, auto-picks "2" on the accept screen, and waits for the "bypass
permissions on" footer; a custom profile supplies its own args / env-clearing /
accept+ready patterns.

**Decide the task, then dispatch.** Prefer the `-Task "<desc>"` form — the script generates
the full brief AND auto-injects the project's agent-team / file-lane rules (from
`config.teams`), the project test commands (from `config.layout`), and the commit/push/PR
contract:

```bash
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch.ps1" -Name "<name>" -Task "<description + spec ref>" -Config "<repo>/.claude/session-plugin.json"
```

The task body should point the worker at **the task brief and any spec the brief points to**:
e.g. "Build the X flow per the spec at `<path>`; the unchecked items in its tasks list are
your work." The script writes this into `.claude-bootstrap.md`, which is the ONLY thing the
worker is told to read on launch.

For a hand-written brief instead of an auto-generated one, use `-Bootstrap "<markdown>"`
(inline) or `-BootstrapFile "<path-to-brief.md>"`:
```bash
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch.ps1" -Name "<name>" -BootstrapFile "<path-to-brief.md>" -Config "<repo>/.claude/session-plugin.json"
```

To re-dispatch into an existing warm worktree (skip the dep junction step):
```bash
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch.ps1" -Name "<name>" -Task "<desc>" -SkipDeps -Config "<repo>/.claude/session-plugin.json"
```

Optional overrides: `-Branch <branch>` (default `feature/<name>`), `-Session <sess>`,
`-BaseRef <ref>` (default `origin/<base>`), `-Title "<task title>"`,
`-IssueNumber <n>` (adds `Closes #<n>` to the PR contract).

If no spec/brief exists yet, tell the user — do NOT build without one.

**CRITICAL**: Never `cd` into the worktree from the main/orchestrator session. The psmux
window's shell is already rooted there. Watch it with `psmux capture-pane -t <sess>:<name> -p`.

### Step 9: Report
Branch, worktree path, psmux target (`<sess>:<name>`), and the attach command
(`psmux attach -t <sess>`).

### Step 10: Auto-start monitoring loop

**CRITICAL — Do NOT skip this step.** After dispatch, immediately start the monitor loop:

```
/loop 3m /session monitor <name>
```

This invokes `/session monitor <name>` every 3 minutes. The monitor:
1. Checks if a PR exists for `feature/<name>` → if yes, reports COMPLETE.
2. Reads the worker's pane via `psmux capture-pane -t <sess>:<name> -p`.
3. Checks git progress (commits ahead of `<base>`, uncommitted changes).
4. Analyzes agent state (building, stuck, sidetracked, erroring, done).
5. Sends corrective instructions via `psmux send-keys -t <sess>:<name> "<msg>" Enter` when needed.
6. Reports status.

See [commands-monitor.md](commands-monitor.md) for the full protocol.

**The orchestrator's job is NOT done when the terminal opens.** The loop runs automatically
until PR creation or user intervention.

---

## `resume` — Full Protocol

### Steps 1-2: Verify + identify
```
git -C <repo> rev-parse --show-toplevel && git -C <repo> branch --show-current
git -C <repo> worktree list
```

### Step 3: Health-check
```
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/status/check-worktree-health.ps1" -Name "<name>" -Config "<repo>/.claude/session-plugin.json"
```
Or by hand:
```
git -C "<wt>/<name>" rev-parse --git-dir
git -C "<wt>/<name>" status --porcelain
```
Check: package manifests, the node_modules junction(s), env files.

### Step 4: Repair
- `rev-parse` fails → offer to tear down (`close-worker.ps1`) + recreate via `start`.
- node_modules junction missing → re-dispatch (the junction step recreates it) or re-junction manually.
- .env missing → copy from `<repo>`.

### Step 5: Re-dispatch psmux window + report
```
git -C "<wt>/<name>" log --oneline -3
```
Check for a live window: `psmux list-windows -t <sess>` and look for `<name>`.
- If the window exists, just `psmux capture-pane -t <sess>:<name> -p` to see state, then `send-keys` to nudge.
- If no window, re-add one and relaunch Claude (`-SkipDeps` since deps are already wired):
  ```bash
  powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch.ps1" -Name "<name>" -Task "<desc>" -SkipDeps -Config "<repo>/.claude/session-plugin.json"
  ```
Report branch, last commits, repairs.

---

## `finish` — Full Protocol

### Step 1: Check uncommitted changes
```
git -C "<wt>/<name>" status --porcelain
```
If changes exist, commit them with a `<type>(<name>): description` message.

### Step 2: Run tests
Run **the project's test commands (from `config.layout` — see [build-protocol.md](build-protocol.md))**
in the worktree. These typically auto-detect which layers to run based on changed files
(backend → its test runner; frontend → typecheck + unit + build; both → all layers).

Fix ALL failures. Do NOT proceed with failing tests.

### Step 3: Rebase
```
git -C "<wt>/<name>" fetch origin <base>
git -C "<wt>/<name>" rebase origin/<base>
```
If conflicts, STOP. Do NOT force push.

### Step 4: Push
```
git -C "<wt>/<name>" push -u origin "feature/<name>"
```

### Step 5: Create PR
```
gh pr create --repo <gh> --head "feature/<name>" --base <base> --title "<type>(<name>): description" --body "Completed by worktree agent"
```
Skip if a PR already exists.

### Step 6: Report
PR URL, branch, commit count.

**IMPORTANT**: `finish` does NOT merge, does NOT touch `<base>`, does NOT remove worktrees.
Only: commit → test → rebase → push → PR → report.
Merging + cleanup → `/session pull` (after the user authorizes the merge).
