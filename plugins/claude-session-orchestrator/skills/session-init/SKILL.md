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
where.exe claude 2>/dev/null           # -> claudeCmdPath candidate (prefer the .cmd)
```

Derive:
- `repoPath` = the toplevel path (Windows form, backslashes).
- `projectName` = the leaf folder name of repoPath (let the user override).
- `worktreesPath` = sibling dir `<repoParent>\<leaf>-worktrees` (the proven convention — worktrees live OUTSIDE the repo).
- `psmuxSession` = lowercased `projectName` with non-alphanumerics stripped.
- `defaultBranch` = origin's default branch if detected, else the current branch, else `main`.
- `githubRepo` = from `gh` if available, else ask.
- `claudeCmdPath` = the `.cmd` from `where.exe claude`; if only a non-.cmd path is found, prefer `C:\Users\<you>\AppData\Roaming\npm\claude.cmd`. Confirm it exists.

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

## Step 4 — Write the config

Write `<repoPath>\.claude\session-plugin.json` (create `.claude` if needed) with
exactly the schema shown in the examples. Required top-level keys:
`projectName, repoPath, worktreesPath, psmuxSession, githubRepo, defaultBranch,
claudeCmdPath, layout`. Optional: `devServer`, `teams`.

Before writing, show the user the full JSON and confirm. After writing, validate
by loading it:

```bash
powershell.exe -ExecutionPolicy Bypass -Command ". '${CLAUDE_PLUGIN_ROOT}/scripts/lib/_session-config.ps1'; Get-SessionConfig -RepoPath '<repoPath>' | ConvertTo-Json -Depth 6"
```

If it throws, fix the field it names and re-write.

## Step 5 — Preflight + next steps

Check the environment the pipeline needs and report PASS/FAIL for each:
- `psmux ls` works (psmux installed)
- the `claudeCmdPath` file exists
- `gh auth status` is logged in
- the main repo has installed deps at each `nodeModules` mapping (workers junction these — if absent, tell the user to install in the main repo first)

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
