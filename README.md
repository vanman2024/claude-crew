# claude-crew

A Claude Code plugin marketplace for orchestrating crews of parallel Claude
workers.

## Plugins

| Plugin | Description |
|--------|-------------|
| [`claude-session-orchestrator`](plugins/claude-session-orchestrator) | Project-agnostic parallel-worktree build pipeline for Windows: spawn Claude workers in psmux windows across git worktrees, orchestrate them on Claude Code's native `/loop` with a no-auto-merge contract, and review their PRs. Driven entirely by a per-project `.claude/session-plugin.json`. |

## Use it

```
/plugin marketplace add vanman2024/claude-crew
/plugin install claude-session-orchestrator@claude-crew
```

Then, in a project you want to orchestrate:

```
/session-init        # scaffold .claude/session-plugin.json
/session list        # see worktrees + workers
```

See each plugin's own README for full docs.
