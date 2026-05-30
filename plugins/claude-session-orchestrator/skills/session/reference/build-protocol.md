# Build Protocol — Worktree Sessions

> Paths/session/repo/branch come from `.claude/session-plugin.json`. The agent
> roster, owned file-lanes, and test commands are PROJECT-DECLARED in that config
> (`config.teams`, `config.layout`) and auto-injected into each worker's
> `.claude-bootstrap.md` by the dispatch scripts.

When a worktree session starts with a build task, the dispatch scripts write a
self-contained brief to `<worktree>/.claude-bootstrap.md` — the ONLY file the
worker is told to read on launch. That brief is generated from config by
`${CLAUDE_PLUGIN_ROOT}/scripts/lib/_session-brief.ps1`: it embeds the task, the
agent-team / file-lane rules synthesized from `config.teams`, the test commands
from `config.layout`, and the commit/push/PR contract. This document explains the
protocol that brief enforces.

---

## MANDATORY: Plan First

The build brief is a PRIMER — it tells you WHAT to build, not HOW. You MUST:
1. **Explore the codebase** — use the Explore agent or read files directly.
2. **Plan** — list every file you will create or modify and what each change does;
   identify conflicts and risks. (Use plan mode / `EnterPlanMode` where available.)
3. **Then build** — only after the plan is settled, start implementation.

DO NOT just follow the brief word-for-word. Understand the codebase first, then plan.
Stay focused on THIS task; if you find unrelated bugs, log them as separate issues —
do not pivot.

---

## MANDATORY: Use Agent Teams (split by ROLE / FILE-LANE, not by feature-slice)

Parallelize the build by **role / file-lane**, NOT by feature-slice. Each lane
owns a disjoint set of paths so concurrent agents never write the same files and
do not collide. This is the opposite of "agent A does feature 1 end-to-end, agent
B does feature 2 end-to-end" — that splits by slice and guarantees collisions in
shared layers.

**The roster is project-declared.** The plugin reads whatever the project puts in
`config.teams` and auto-injects it into the worker brief — this doc does not
hardcode any agent names. Each team entry can declare `ownsPaths` (the file lane),
`agents` (exact `subagent_type` names), and `skills`.

### Illustrative only — the monorepo-split example

The shipped `session-plugin.monorepo-split.json` example declares teams roughly like:

| Team | Owns paths (lane) | Agents (`subagent_type`) |
|------|-------------------|--------------------------|
| frontend | `frontend/components/**`, `frontend/app/**`, `frontend/lib/**`, `frontend/hooks/**` | `nextjs-frontend:component-builder-agent`, `nextjs-frontend:page-generator-agent`, `nextjs-frontend:api-route-generator-agent`, `nextjs-frontend:design-enforcer-agent`, `nextjs-frontend:supabase-integration-agent` (skills: `frontend-design`, `build-page`, `nextjs-frontend:design-system-enforcement`) |
| backend | `backend/api/routes/**`, `backend/services/**`, `backend/models/**` | `fastapi-backend:endpoint-generator-agent`, `fastapi-backend:database-architect-agent` |
| testing | (cross-cutting) | `frontend-test-generator`, `code-validator` |

This is **illustrative**. Your project's teams, lanes, and agent names come from
its own `config.teams`; the plugin injects exactly what the project declares.

### Hard rules (non-negotiable)

- **Never use `general-purpose`** for build work when a specialized agent is
  configured for that lane.
- **Launch independent agents in a SINGLE message** so they run concurrently.
  Give each DETAILED context (file paths, schemas, interfaces, the spec section).
- **If a needed specialized agent is unavailable** in this environment, print
  `BLOCKED: <agent> unavailable` and stop — do NOT silently fall back to
  `general-purpose`.
- **After the parallel build, run an API-contract verification pass**: frontend
  fetch types == route types == backend models; no drift, no `any`, no dead
  endpoints.

### Projects without a teams section

If a project declares no `config.teams`, the brief falls back to a **generic
single-Claude build**: build the task yourself, in layer order, testing as you go,
exploring the codebase first. You may still launch independent sub-agents for
genuinely parallel, non-overlapping work, but there is no required roster.

---

## MANDATORY: Run Real Tests (NOT just visual clicking)

After build steps, run the project's real test commands — the ones declared in
`config.layout` (per-part `testCmd`, surfaced in the worker brief). For the
monorepo-split example these resolve to things like a frontend `tsc --noEmit` +
unit run and a backend `pytest`, but **use whatever the project declares** — do
not hardcode commands here. Fix ALL failures before committing.

- **DO NOT** just click around and call it "testing."
- **DO NOT** skip tests because "the UI looks right."
- **DO NOT** create a PR with failing tests or type errors.

---

## MANDATORY: Dev Server via Script

**NEVER run the raw dev command (`pnpm dev` / `next dev` / etc.) directly** — it
blocks the terminal and times out. Always use the dev-server script, which reads
the port + dir from `config.devServer` and runs detached:

```
pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action start  -Dir "<wt>\<name>" -Config "<repo>/.claude/session-plugin.json"
pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action status -Dir "<wt>\<name>" -Config "<repo>/.claude/session-plugin.json"
pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action stop   -Dir "<wt>\<name>" -Config "<repo>/.claude/session-plugin.json"
```

See `commands-server.md` and `server-rules.md` for details.
