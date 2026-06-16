# Server State Rules

> Paths/session/repo/branch come from `.claude/session-plugin.json`. The dev
> server port comes from `config.devServer.port`; `node_modules` and env-file
> locations come from `config.layout` mappings (per-part `nodeModules` /
> `envFiles`). The package manager and dev/install commands are the project's own.

Applies to ALL session commands. When encountering server-related issues:

| Issue | Detection | Action |
|-------|-----------|--------|
| Port in use by stale process | `netstat` + `wmic` shows an old session on `config.devServer.port` | Kill the specific PID |
| Port in use by different worktree | `wmic` command line shows a different worktree path under `<wt>` | Warn user — stop the other worktree's server first |
| Port in use by non-dev process | `tasklist` shows a process unrelated to the dev runtime | Warn — do NOT kill |
| Server not running when needed | `netstat` empty on the configured port | Tell user to run `server-start` |
| Env file missing | A file from `config.layout` `envFiles` is absent | Copy it from the main repo at `<repo>` |
| `node_modules` missing | The dir from `config.layout` `nodeModules` is absent | Run the project's full install (no `--prefer-offline`) |
| `Cannot find native binding` | A prior `--prefer-offline` install skipped optional deps | Delete `node_modules` + build cache, re-run the project's full install |

The dev server itself is always started/stopped via
`${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1` (see `commands-server.md`),
never the raw dev command.

## Preview environment (live PR review) — separate ports, separate worktree

The `preview` commands (`scripts/server/preview-server.ps1`, see
`commands-preview.md`) run a **persistent, branch-cycling** review env that must NOT
collide with the main session's server:

| Rule | Why |
|------|-----|
| **Derived ports only** — frontend `config.devServer.port + previewServer.portOffset` (default 100), backend `backendBasePort` (default 8000) `+ portOffset`. NEVER bind the main 3000/8000. | The user keeps coding on 3000/8000; the preview is a *second* pair of servers. |
| **One `_preview` worktree, reused** for every PR (cycle branches with `preview-switch`), not one per PR. | One install, ever; no CPU spike from N live servers. |
| **REAL install in the preview worktree** (`node_modules` + python `.venv`), NOT a junction. Detach any stale junction first (`rmdir`, removes the link not the target). | A junctioned `node_modules` shares the main repo's cache — a second `next dev` collides. The preview env needs its own deps. |
| **Servers run as psmux windows** (`preview-fe` / `preview-be`); inspect with `capture-pane`. | Persistent across CLI calls, killable by name; no foreground-blocking dev command, no extra daemon. |
