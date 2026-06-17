---
name: session-init
description: Scaffold the per-project config for the session orchestrator. Creates .claude/session-plugin.json by detecting sane defaults (repo path, github repo, default branch, claude.cmd) and asking about layout (root vs monorepo-split) and optional agent teams. Triggers on "/session-init", "set up the session plugin", "initialize the worktree orchestrator", "configure session-plugin.json".
argument-hint: "(no args — interactive)"
disable-model-invocation: false
allowed-tools: Bash(git *), Bash(gh *), Bash(pwd), Bash(where.exe *), Bash(cmd.exe *), Read, Write, AskUserQuestion
---

# session-init — Scaffold `.claude/session-plugin.json`

Create the consuming project's config for the `session` skill. This is the ONE
file a project needs to use the orchestrator — no per-project script copies.
Write instructions FOR yourself (Claude): gather values, confirm, write the file.

## Step 1 — Detect defaults (do NOT ask for what you can detect)

Run these in the project the user is in:

```bash
git rev-parse --show-toplevel          # -> repoPath (absolute)
git rev-parse --abbrev-ref HEAD        # current branch (hint for defaultBranch)
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null   # -> origin's default branch (best source for defaultBranch)
gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null   # -> githubRepo (owner/name)
where.exe claude 2>/dev/null           # -> workerCmdPath candidate (prefer the .cmd)
```

Derive:
- `repoPath` = the toplevel path (Windows form, backslashes).
- `projectName` = the leaf folder name of repoPath (let the user override).
- `worktreesPath` = sibling dir `<repoParent>\<leaf>-worktrees` (the proven convention — worktrees live OUTSIDE the repo).
- `psmuxSession` = lowercased `projectName` with non-alphanumerics stripped.
- `defaultBranch` = origin's default branch if detected, else the current branch, else `main`.
- `githubRepo` = from `gh` if available, else ask.
- `workerCmdPath` = the `.cmd` from `where.exe claude`; if only a non-.cmd path is found, prefer `C:\Users\<you>\AppData\Roaming\npm\claude.cmd`. Confirm it exists.
- `workerCli` (optional) = which agent CLI the workers run. **Default: omit it (= the `claude` preset).** Only ask about this if the user wants non-Claude workers.
  - **Codex** is a verified preset: set `"workerCli": "codex"` and point `workerCmdPath` at the user's `codex.cmd` (e.g. `C:\Users\<you>\AppData\Roaming\npm\codex.cmd` — confirm via `where.exe codex.cmd`). It launches `--dangerously-bypass-approvals-and-sandbox --no-alt-screen`, auto-answers the trust-directory gate, and waits for the YOLO-mode header. The user must already be logged in (`codex login`).
  - **Other CLIs (Gemini/Qwen/…):** give `workerCli` an object with its real launch args + accept/ready patterns (see the "Worker CLI" section of the plugin README). Do NOT invent prompt strings for a CLI you can't verify — ask the user for them or start from the `generic` preset.

## Step 2 — Choose the layout (ask)

Use AskUserQuestion:

- **root** — single app at the repo root (one `node_modules`, env files at root). Ask for: env files (default `.env`, `.env.local`, `.env.test`), the `node_modules` dir (default `node_modules`), the test command (default `npx tsc --noEmit && pnpm test`), and dev-server port + dir (default port 3000, dir `.`).
- **monorepo-split** — multiple parts (e.g. `frontend/` + `backend/`). For each part ask: name, path, env files, `nodeModules` path (the parts that have one), optional `pythonVenv`, and `testCmd`. Use `<repo>` in a test command when it must reference the MAIN repo (e.g. a shared venv python: `& '<repo>\backend\.venv\Scripts\python.exe' -m pytest`). Dev-server port + dir (default port 3000, dir = the frontend-ish part path).

Show the two example configs for reference:
- `${CLAUDE_PLUGIN_ROOT}/examples/session-plugin.monorepo-split.json`
- `${CLAUDE_PLUGIN_ROOT}/examples/session-plugin.root.json`

## Step 3 — Agent teams (ask, optional)

`teams` is the project's **roster of its OWN specialized agents/skills** (from
installed plugins like `nextjs-frontend`, `fastapi-backend`, the `frontend-design`
skill, etc.) — NOT a native team feature. Declaring it makes workers use the right
agent per file lane instead of defaulting to `general-purpose`, which is the single
biggest lever on output quality. See `build-protocol.md` for the full rationale.

Ask whether the project has specialized agents to declare:

- **If yes**, gather `teams` as a map of `teamName → { ownsPaths[], agents[], skills[] }`.
  - `ownsPaths` = the file-lane globs that team owns (keep lanes disjoint).
  - `agents` = the EXACT `subagent_type` names (e.g. `nextjs-frontend:component-builder-agent`).
  - `skills` = skills that team should run (e.g. `frontend-design`).
  - **Only record agents the user confirms are actually installed.** `teams` names
    agents; it does not install them. If a named agent is missing at run time, the
    worker prints `BLOCKED: <agent> unavailable` rather than falling back. So
    confirm the agent-providing plugins are installed before listing their agents.
- **If no** specialized agents yet, OMIT the `teams` section — the plugin falls
  back to a generic single-Claude build flow.

To make this concrete, offer the user this fresh-project template (adjust to what
they actually have installed) — a Next.js + Supabase example:

```jsonc
"teams": {
  "frontend": {
    "ownsPaths": ["app/**", "components/**", "lib/**", "hooks/**"],
    "agents": [
      "nextjs-frontend:component-builder-agent",
      "nextjs-frontend:page-generator-agent",
      "nextjs-frontend:api-route-generator-agent",
      "nextjs-frontend:supabase-integration-agent"
    ],
    "skills": ["frontend-design", "nextjs-frontend:design-system-enforcement"]
  },
  "data":    { "ownsPaths": ["supabase/migrations/**"], "agents": ["fastapi-backend:database-architect-agent"] },
  "testing": { "agents": ["frontend-test-generator", "code-validator"] }
}
```

## Step 4 — Data-flow map (ask, optional)

A `dataFlow` map is the single strongest lever against cross-lane redundancy:
without it, each parallel lane invents its own version of the same entity (the
"seventeen versions of one object" problem). When declared, the SAME map is injected
into every worker's brief as a shared contract. See `build-protocol.md` for the
rationale. (When omitted, each worker is told to map the flow itself before planning
— so this is purely an upgrade, never required.)

Ask if the user wants to declare a canonical data-flow map now. If yes, capture it
as a top-level `dataFlow` — a plain string, or an object with `entities` / `flows` /
`notes`:

```jsonc
"dataFlow": {
  "entities": ["User", "Order", "Payment", "Receipt", "Notification"],
  "flows": [
    "User creates Order -> Order created (status: pending)",
    "Order triggers Payment -> Payment charges provider",
    "Payment success -> Order.status = paid, DB updated",
    "Order paid -> Notification sends Receipt to User"
  ],
  "notes": "One Order per checkout. Payment is the only writer of Order.status."
}
```

Keep it to a 60-second outline (entities, source, destination, what changes) — not a
giant architecture doc. It can be hand-edited in the config any time.

## Step 5 — Write the config

Write `<repoPath>\.claude\session-plugin.json` (create `.claude` if needed) with
exactly the schema shown in the examples. Required top-level keys:
`projectName, repoPath, worktreesPath, psmuxSession, githubRepo, defaultBranch,
workerCmdPath, layout`. Optional: `devServer`, `teams`, `dataFlow`, `review`, `workerCli`,
`worktreeDeps`, `previewServer`.

> `worktreeDeps` (optional) controls how each worker worktree gets its `node_modules`:
> `"junction"` (default) shares the main checkout's `node_modules` via a junction — fast and
> low-disk, fine for build/test-only workers, but a second `next dev` collides on the shared
> dir. `"install"` does a REAL per-worktree install (with pnpm, hardlinks from the global
> store, so cheap after the first) — use it when each worktree runs its own dev server /
> Playwright. Default to `"install"` for dev-server-per-worktree workflows.

> `review` (optional) configures the **reviewer** (overseer) loop that verifies each PR
> (tests + `/code-review`) before you merge. Shape: `{ "intervalMin": 5 }`. Omit it for the
> 5-minute default. The reviewer is auto-launched alongside the orchestrator.

Before writing, show the user the full JSON and confirm. After writing, validate
by loading it:

```bash
powershell.exe -ExecutionPolicy Bypass -Command ". '${CLAUDE_PLUGIN_ROOT}/scripts/lib/_session-config.ps1'; Get-SessionConfig -RepoPath '<repoPath>' | ConvertTo-Json -Depth 6"
```

If it throws, fix the field it names and re-write.

## Step 6 — Preflight + next steps

Check the environment the pipeline needs and report PASS/FAIL for each:
- `psmux ls` works (psmux installed)
- the `workerCmdPath` file exists
- `gh auth status` is logged in
- the main repo has installed deps at each `nodeModules` mapping (when `worktreeDeps` is `"junction"`, workers junction these — if absent, tell the user to install in the main repo first; with `"install"` each worktree installs its own, so the main checkout's deps are not required)

Then print the next steps:

```
Config written: <repoPath>\.claude\session-plugin.json

Try it:
  /session list
  /session start <feature-name>
  /session start-issues 510 511 512
  /session orchestrate           (dashboard)

Launch the autonomous orchestrator (its own window, /loop polling, no auto-merge):
  powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/start-orchestrator.ps1" -Config "<repoPath>\.claude\session-plugin.json"
```

## Notes

- Do NOT commit secrets — `.claude/session-plugin.json` holds only paths and the
  github repo slug, no tokens. It's safe to commit so the whole team shares it.
- Re-running `/session-init` updates the file (show a diff and confirm before overwriting an existing config).

