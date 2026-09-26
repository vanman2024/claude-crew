---
name: build
description: Build one feature in THIS session using the project's crew protocol — size the task, use the declared lane agents and skills, build the frontend<->backend seam, verify it in a real browser, review before the PR. Same protocol a dispatched worktree worker gets, without the worktree. Triggers on "/crew:build", "build this feature properly", "build X using the crew protocol", "use the lanes for this", or any feature build in a repo that has .claude/session-plugin.json.
---

# Build (in this session)

Applies this project's build protocol to the work you are about to do **right here**,
in the main checkout. No worktree, no psmux, no dispatch.

Use `/crew:session` instead when you want several features built in parallel, isolated
worktrees with an orchestrator watching them. The protocol is identical either way —
the worktree is only a delivery mechanism.

## Step 1 — load the protocol

Run this and follow what it prints. It is generated from the project's own
`.claude/session-plugin.json`, so the lanes, agents, skills, test commands and browser
tool are whatever THIS project declares:

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/build/protocol.ps1" -Task "<the task>"
```

If it errors with "Could not find .claude/session-plugin.json", this project has not
been set up yet — run `/crew:session-init` first, or pass `-Config <path>`.

## Step 2 — follow it

The output is not reference material. It is the protocol for this build:

1. **Size the task (S / M / L) and say so** — with one line of reasoning. This decides
   how much of the roster applies. Lane span is objective: a change spanning two lanes
   is at least M. When torn, pick the larger.
2. **Create the task list first**, seeded with one entry per REQUIRED item at your size.
3. **Run the lanes** — the declared agents, launched in a single message so they run
   concurrently, each staying inside the paths it owns.
4. **Build the seam.** If the task touches two lanes, the agent that owns the boundary
   between them is required. Two lanes built and not connected is an incomplete task.
5. **Verify it** — tests at the depth your size calls for, then actually run it and look
   at it if it is user-visible.
6. **Review before the PR**, then report in the shape the protocol prints and STOP.

## What this does NOT do

- No worktree, no branch ceremony, no psmux window.
- The dev server uses the project's CONFIGURED port. `-AutoPort` is for worktrees, where
  a second server would collide with the main checkout's.
- It does not merge and it does not tear anything down. You report; the human decides.
