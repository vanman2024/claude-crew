# Preview-Environment Commands — Detailed Steps

> The **preview env** is ONE persistent worktree that cycles PR branches for live
> human review. It is the LOCAL analog of the Vercel preview in the Merge protocol —
> for **backend / full-stack** PRs (which a Vercel preview can't exercise). Distinct
> from the `review` / `review-start` commands, which are the automated *reviewer*
> (overseer) that verifies PRs with tests + `/code-review`. This is a place a human
> looks at and iterates on a running PR.

All preview operations use one script:
```
${CLAUDE_PLUGIN_ROOT}/scripts/server/preview-server.ps1
```

Pass `-Config "<repo>/.claude/session-plugin.json"` so it resolves config.

## Why it exists (vs. worker worktrees)

- **Worker** worktrees junction `node_modules` from the main repo and never install,
  so a second `next dev` against them would collide with the main repo's cache.
- The **preview** worktree gets **REAL installs** (pnpm + a python `.venv`) **once**,
  so its dev servers run safely **alongside** your main repo's, on **derived ports**.
- Servers run as named psmux windows (`preview-fe` / `preview-be`) — persistent
  across CLI calls, inspectable via `capture-pane`, killable by name. No daemon.
- **Never** binds the main `devServer` port. Frontend = `devServer.port + portOffset`;
  backend = `backendBasePort` (default 8000) `+ portOffset`. Default offset: `100`
  (so `3000 → 3100`, `8000 → 8100`).

## Config (`previewServer`, all optional)

```jsonc
"previewServer": {
  "portOffset": 100,
  "worktreeName": "_preview",
  "frontend": {
    "dir": "frontend",                                   // else config.devServer.dir
    "installCmd": "pnpm install",                        // else auto-detected from the lockfile
    "devCmd": "npx next dev -p {port} -H 0.0.0.0"        // {port} = derived frontend port
  },
  "backend": {
    "dir": "backend",                                    // else auto-derived from the venv layout part
    "venv": ".venv",
    "basePort": 8000,
    "installCmd": ".venv\\Scripts\\pip.exe install -r requirements.txt",
    "devCmd": ".venv\\Scripts\\python.exe -m uvicorn app.main:app --port {port}"
  }
}
```

If `previewServer` is omitted entirely, the frontend still works from `devServer`.
The backend is auto-derived from a `monorepo-split` layout part that declares
`pythonVenv` — but it has **no safe default dev command**, so set `backend.devCmd`
(use `{port}`) to actually serve the backend; otherwise the env boots frontend only.

---

## `preview-start <PR# | branch>`

Ensure the preview worktree + real deps exist (install **only if missing**), check
out the branch, boot the frontend + backend on the derived ports.

```
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/preview-server.ps1" -Action start -Ref <PR# | branch> -Config "<repo>/.claude/session-plugin.json"
```

Steps the script runs:
1. Resolve `<PR#>` → head branch via `gh pr view <n> --json headRefName` (a branch
   name passes through).
2. Create `<wt>\_preview` once (detached at `origin/<base>`) + copy env files. Reused
   forever after.
3. `git checkout -B <branch>` (falls back to detached `origin/<branch>` if that branch
   is checked out in another worktree).
4. Real install **once**: detach any stale `node_modules` junction → `pnpm install`;
   create the python `.venv` + `pip install`. Skipped when already present.
5. `kill-port` the derived ports, then boot `preview-fe` / `preview-be` psmux windows.
6. Poll the frontend for readiness.

Parse the output: `PREVIEW_STARTED` (or `PREVIEW_STARTED_FRONTEND_NOT_READY`),
`FRONTEND_URL`, `BACKEND_URL`, `BRANCH`. Report the URLs to the user.

---

## `preview-switch <PR# | branch>`

The iteration loop. Check out a different PR in the **same** worktree; **leave the
servers running** so they hot-reload — no reinstall.

```
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/preview-server.ps1" -Action switch -Ref <PR# | branch> -Config "<repo>/.claude/session-plugin.json"
```

Output: `PREVIEW_SWITCHED`, the new `BRANCH`, and whether the frontend window is still
up. If it reports the window down, run `preview-start` to (re)boot.

---

## `preview-stop`

Kill the `preview-fe` / `preview-be` windows and free the derived ports
(`kill-port` backstop). The worktree + its installed deps stay on disk for next time.

```
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/preview-server.ps1" -Action stop -Config "<repo>/.claude/session-plugin.json"
```

Output: `PREVIEW_STOPPED` + the freed ports.

---

## `preview-status`

Show which branch is loaded and whether the servers are up.

```
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/preview-server.ps1" -Action status -Config "<repo>/.claude/session-plugin.json"
```

Output: `PREVIEW_STATUS` with `BRANCH`, `FRONTEND_PORT`/`FRONTEND_WINDOW`/`FRONTEND_HTTP`
(+ backend equivalents), or `PREVIEW_NOT_INITIALIZED` if the env has never been started.

---

## Rules

- **Derived ports only.** Never bind the main `devServer` port (3000) or its backend
  (8000). The whole point is to not disturb the user's own coding session.
- **One preview worktree per session** (`_preview`), reused for every PR — not one per PR.
- **Real install, once.** The preview worktree must have its own `node_modules` +
  `.venv` (not a junction), or a second dev server collides with the main repo's cache.
- **Servers are psmux windows.** Inspect with `psmux capture-pane -t <sess>:preview-fe -p`;
  never run the raw dev command in the foreground (it blocks the terminal).
