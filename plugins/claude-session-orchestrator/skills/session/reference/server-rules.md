# Server State Rules

> Paths/session/repo/branch come from `.claude/session-plugin.json`. The dev
> server port comes from `config.devServer.port`; `node_modules` and env-file
> locations come from `config.layout` mappings (per-part `nodeModules` /
> `envFiles`). The package manager and dev/install commands are the project's own.

Applies to ALL session commands. When encountering server-related issues:

| Issue | Detection | Action |
|-------|-----------|--------|
| Port in use by stale process | `netstat` + `wmic` shows an old session on `config.devServer.port` | Kill the specific PID **only** (via `kill-port.ps1 -Port <port>`) — never by name |
| Port in use by different worktree | `wmic` command line shows a different worktree path under `<wt>` | Warn user — stop the other worktree's server first |
| Port in use by non-dev process | `tasklist` shows a process unrelated to the dev runtime | Warn — do NOT kill |

> **NEVER kill processes by name.** Claude Code, the orchestrator, the reviewer, and
> every worktree's dev server are all `node.exe` — so `taskkill /IM node.exe`,
> `Stop-Process -Name node`, `Get-Process node | Stop-Process`, `killall/pkill node`,
> or a blanket `npx kill-port` sweep will kill the running Claude Code session itself
> (and the whole crew) at once. Always free a port by the **single owning PID** on the
> **specific port** — `kill-port.ps1 -Port <port>` does exactly that.
| Server not running when needed | `netstat` empty on the configured port | Tell user to run `server-start` |
| Env file missing | A file from `config.layout` `envFiles` is absent | Copy it from the main repo at `<repo>` |
| `node_modules` missing | The dir from `config.layout` `nodeModules` is absent | Run the project's full install (no `--prefer-offline`) |
| `Cannot find native binding` | A prior `--prefer-offline` install skipped optional deps | Delete `node_modules` + build cache, re-run the project's full install |

The dev server itself is always started/stopped via
`${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1` (see `commands-server.md`),
never the raw dev command.
