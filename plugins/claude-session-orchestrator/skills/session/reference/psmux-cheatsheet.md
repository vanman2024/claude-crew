# psmux Cheatsheet

Quick reference for **psmux** — the Windows tmux port (terminal multiplexer) the
session orchestrator uses to run a worker Claude per git worktree.

Placeholders (from `.claude/session-plugin.json`): `<sess>` = psmuxSession,
`<repo>` = repoPath, `<wt>` = worktreesPath, `<claudeCmd>` = claudeCmdPath.

---

## "Am I attached?" — look at the bottom of your terminal

If you see a **green status bar** like:

```
[<sess>] 0:main* 1:fix-403-
```

**You're attached.** That bar is psmux; the `*` marks the current window. No bar = a regular shell.

---

## Daily commands (run in any terminal)

| Command | What it does |
|---|---|
| `psmux ls` | List all sessions |
| `psmux attach -t <sess>` | Attach to a session |
| `psmux list-windows -t <sess>` | List the windows (workers) in a session |
| `psmux kill-session -t <sess>` | End a session (kills everything in it) |
| `psmux new -s <sess> -d` | Create a new detached session |

---

## Keybindings (press `Ctrl+B`, release, then the key)

| Keys | Action |
|---|---|
| `Ctrl+B` then `0..9` | Switch to window 0–9 |
| `Ctrl+B` then `n` / `p` | Next / previous window |
| `Ctrl+B` then `c` | Create new window |
| `Ctrl+B` then `,` | Rename current window |
| `Ctrl+B` then `d` | **Detach** (session keeps running in background) |
| `Ctrl+B` then `s` | Session chooser |
| `Ctrl+B` then `w` | Window chooser (visual list) |
| `Ctrl+B` then `?` | Show all keybindings |
| `Ctrl+B` then `%` | Split pane left/right |
| `Ctrl+B` then `"` | Split pane top/bottom |
| `Ctrl+B` then `arrows` | Move between panes |
| `Ctrl+B` then `z` | Zoom current pane (fullscreen toggle) |
| `Ctrl+B` then `[` | Scrollback mode (PgUp/PgDn/`g`/`G`/`/search`, `q` to exit) |

---

## "I'm lost" recovery

| Symptom | Fix |
|---|---|
| `sessions should be nested with care, unset PSMUX_SESSION to force` | You're already attached. Look for the green bar. Switch windows: `Ctrl+B` then a number. Leave: `Ctrl+B` then `d`. |
| Wrong window | `Ctrl+B` then a number, or `Ctrl+B + w` for a chooser. |
| Closed the terminal by accident | The session is still alive. Open any terminal: `psmux attach -t <sess>`. |
| Want to nuke a session and start over | `psmux kill-session -t <sess>` |
| Don't know what's running | `psmux ls` from any terminal |

---

## Closing things WITHOUT nuking everything

**Never use the terminal app's X button to close a psmux pane** — it tries to close the whole app ("Close all tabs?"). Use keybindings.

| To close... | Keys |
|---|---|
| **Just this pane** (others stay alive) | `Ctrl+B` then `x` → `y` |
| **Just this window** (other windows stay alive) | `Ctrl+B` then `&` → `y` |
| **Just disconnect** (everything keeps running) | `Ctrl+B` then `d` |
| Type `exit` in the pane's shell | Same as `Ctrl+B + x` |

Rule of thumb: the X button is for the OS terminal app, not for psmux content.

---

## Working with split panes

| Action | Keys |
|---|---|
| Split left/right | `Ctrl+B` then `%` |
| Split top/bottom | `Ctrl+B` then `"` |
| Move focus | `Ctrl+B` then arrows |
| Resize (1 step / 5 steps) | `Ctrl+B` then `Ctrl+arrow` / `Alt+arrow` |
| Zoom (toggle fullscreen) | `Ctrl+B` then `z` |
| Swap panes | `Ctrl+B` then `{` or `}` |
| Cycle preset layouts | `Ctrl+B` then `Space` |
| Pop pane into new window | `Ctrl+B` then `!` |

---

## Launching Claude in a psmux pane

The plugin's `dispatch/psmux-dispatch.ps1` does this for you with the full boot
handshake. The raw commands, for reference:

**Worker Claude** (in a worktree, will open a PR for review):
```powershell
& "<claudeCmd>" --dangerously-skip-permissions
```
The flag auto-approves tool uses — safe because the worker only touches its own
branch and you review the PR. Without it, every tool call blocks on approval and
parallel throughput dies.

**Orchestrator / direct main-repo Claude** (no PR safety gate): omit the flag.

**Why `& "<claudeCmd>"` and not just `claude`:** psmux's pwsh launches with
`-NoProfile`, which skips the user PATH that contains the npm bin dir — so bare
`claude` (and `claude.exe`) isn't found. The `claude.cmd` shim at the npm bin
level works. This is why `claudeCmdPath` in the config must be the full path to
`claude.cmd`.

**Also clear `CLAUDECODE` first** when launching by hand:
```powershell
$env:CLAUDECODE=$null; $env:CLAUDE_CODE_ENTRYPOINT=$null
```
Otherwise the worker thinks it's a nested sub-agent and its Task tool is disabled
(it can't spawn the specialized agent team).

---

## Peek at a worker without attaching

```powershell
psmux capture-pane -t <sess>:<window> -p
```
Prints the pane content to stdout — no focus change, no attach. This is how the
orchestrator polls workers.

## Send a message to a worker (no focus theft)

```powershell
psmux send-keys -t <sess>:<window> "<message>" Enter
```
If the worker is mid-tool, Claude can swallow the Enter — follow up with a
standalone `psmux send-keys -t <sess>:<window> "" Enter` and verify with
`capture-pane`.

---

## Sessions vs windows vs panes (mental model)

- **Session** — a named collection of windows (one per project: `<sess>`)
- **Window** — a tab-like container (one per worktree)
- **Pane** — a split inside a window (a shell, usually running Claude)

Typical orchestrator layout: one session per project, one window per worktree,
one pane per window (splits optional, for dev-server/test panes).

---

## Gotchas saved the hard way

- **Detaching never kills a session** — only `kill-session` does. Disconnect freely.
- **Closing an attached terminal = detach, not destroy.** The session lives on.
- **Don't auto-launch OS terminal tabs from scripts** — Windows steals focus from whatever you're typing.
- **Enable long-path support + use `pwsh`** (not legacy `powershell`) for `Remove-Item -Recurse -Force` on deep `node_modules` paths.

---

## When in doubt

```powershell
psmux ls           # what's alive
psmux ls -v        # verbose
psmux kill-server  # nuclear: ends ALL sessions
```
