# Server Commands — Detailed Steps

> Paths/session/repo/branch come from `.claude/session-plugin.json`. The dev
> server port and working dir come from `config.devServer` (`port`, `dir`).

All server operations use the `dev-server.ps1` script at:
```
${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1
```

**NEVER run `pnpm dev` / `next dev` (or the project's raw dev command) directly** —
they block the terminal and time out. The script launches the server as a DETACHED
background process and reads the port + dir from `config.devServer`.

Pass `-Config "<repo>/.claude/session-plugin.json"` so the script resolves config.

---

## `server-start`

Start the dev server as a DETACHED background process.

1. Determine worktree: `$ARGUMENTS[1]`, current directory, or ask user.

2. Run:
   ```
   pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action start -Dir "<wt>\<name>" -Config "<repo>/.claude/session-plugin.json"
   ```
   (Port defaults from `config.devServer.port`; the server runs in
   `config.devServer.dir` under the worktree.)

3. Parse output:
   - `DEV_SERVER_STARTED` — UP. Report PORT, PID, URL.
   - `DEV_SERVER_ALREADY_RUNNING` — already up. Report PORT and PID.
   - `DEV_SERVER_FAILED` — check log output.

---

## `server-check`

Check dev server state.

1. Determine worktree (same logic).

2. Run:
   ```
   pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action status -Dir "<wt>\<name>" -Config "<repo>/.claude/session-plugin.json"
   ```

3. Interpret against the port from `config.devServer.port`:
   - This worktree's server → "RUNNING on port <port>"
   - Different worktree → "CONFLICT: <other> using port <port>"
   - Unrelated process → "CONFLICT: <process> (PID) using port <port>"

4. If free: "Port <port> AVAILABLE"

5. Check the env files from `config.layout` mappings exist (server needs them).

6. Check `node_modules` from `config.layout` mappings exists.

See `server-rules.md` for the full detection/action table.

---

## `server-stop`

Stop the dev server.

1. Run:
   ```
   pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action stop -Dir "<wt>\<name>" -Config "<repo>/.claude/session-plugin.json"
   ```
   The script finds the process on the configured port, verifies it belongs to
   this worktree, then kills the parent + children. If the listening process does
   NOT belong to this worktree, it warns and does NOT kill — stop the other
   worktree first.

2. Verify the port is free after the kill.
