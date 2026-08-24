# Claude Crew

> **What this answers:** what belongs where, and who owns it?
>
> Durable intent. Never implementation facts.

Reconstructed from the repository on 2026-08-23 — README, plugin and marketplace
manifests, the shipped skills and their reference docs, the worked example
configurations, the changelog, and open issue #9. Nothing here was taken from a
product brief, because none exists. Everything the code could not answer is
marked **OPEN** below rather than answered by inference.

## What this is

Claude Crew is a developer tool, distributed as a Claude Code plugin marketplace,
that turns one person into a crew. It spawns parallel Claude (or Codex, or other
CLI) workers, one per git worktree, in psmux windows on Windows; it drives them
on Claude Code's native `/loop`; and it runs a dedicated reviewer that verifies
each pull request before a human merges it. It is project-agnostic by design —
everything specific to a project lives in that project's own
`.claude/session-plugin.json`, and the runtime knows nothing about any particular
stack unless the config supplies it.

The product is the orchestration protocol, not the code the workers write.

## Actors

| Actor | What they are trying to do |
| :--- | :--- |
| Maintainer | Build and release crew itself. Currently a single person, which shapes every process decision here. |
| Adopting developer | Install crew into their own project, describe that project once in config, and get parallel workers without copying scripts per repo. |
| Orchestrator session | The Claude session that dispatches workers, polls their state, and reports what is in flight. |
| Worker agent | A Claude/Codex/other CLI process in one worktree, executing a generated brief and keeping a task list. Consumes the brief; does not merge. |
| Reviewer session | Verifies each worker's PR (tests plus code review) so the human merges an already-checked change. |
| The human merging | The only actor permitted to merge. This is a deliberate contract, not an oversight. |

## Modules

| Module | Outcome it owns | Owning domain | Capabilities |
| :--- | :--- | :--- | :--- |
| Session lifecycle | Start, resume, finish, and clean up parallel worktree build sessions. | Orchestration | S01 |
| Session configuration | One project-agnostic description of a project — layout, lanes, teams, commands — that every script reads. | Domain model | S06, S08 |
| Worker dispatch | Spawn a worker per worktree with the right CLI, environment and generated brief. | Orchestration | S01, S42 |
| Brief generation | Turn an issue or task into the instructions a worker actually executes, including the maintained task list mandate. | Orchestration | S06 |
| Monitoring | Answer "what is every worker doing right now" without attaching to each window. | Observability | S41 |
| Review gate | Verify a worker's PR before a human sees it. | Quality | S44 |
| Teardown | Remove worktrees, workers and servers safely, junction-first, without killing the host session. | Reliability | S38, S40 |
| Distribution | Ship crew as an installable plugin with an honest version and changelog. | Release | S45 |

## Boundaries

What crew deliberately does **not** do:

- **It never merges.** Workers open pull requests; a human merges them. The
  no-auto-merge contract is a stated product guarantee, and preview review
  before merge is part of the intended workflow.
- **It does not own project state.** Git owns branches and worktrees, psmux owns
  window state, and the adopting project owns its own config file. Crew holds no
  datastore, and adding one would mean keeping a second copy of what git already
  answers authoritatively.
- **It does not know your stack.** Any knowledge of Next.js, FastAPI, Supabase or
  any other technology must arrive through project config or detection. Issue #9
  exists because initialization still violates this in places.
- **It is Windows-first.** psmux and PowerShell are the runtime, declared openly
  in the README, the plugin description and the marketplace keywords.

## Open questions

Marked rather than answered, because nobody has decided them:

- **OPEN — which version is authoritative?** The changelog documents releases
  through 0.4.2; the marketplace manifest declares 0.2.2; the plugin manifest
  declares no version at all. Installers resolve the marketplace value, so two
  minor versions of documented work are currently invisible to anyone installing.
  Owned by S45.
- **OPEN — is Windows-only permanent, or current?** The dependency is real
  (psmux, PowerShell), but nothing states whether cross-platform is a non-goal or
  merely unbuilt. This decides whether the constraint is a boundary or a backlog
  item.
- **OPEN — how far does stack-agnosticism go?** Issue #9 sets the direction
  (templates and detection over hardcoded stacks) but does not settle whether
  crew ships curated templates for common stacks or only a generic schema.
- **OPEN — is there any intended audience beyond the maintainer?** The repo is
  public and installable, but nothing states whether external adopters are a goal.
  This changes how much the config contract must be stabilized and documented.
- **OPEN — what is the boundary with dev-lifecycle?** The two are independent
  today: crew contains no reference to dev-lifecycle, and dev-lifecycle contains
  no reference to psmux or crew. They compose naturally through GitHub issues —
  dev-lifecycle decides what to build and in what order, crew decides who builds
  it in parallel and where. But both claim worktree-per-issue (`devctl worktree
  add <n>` against crew's dispatch), and two tools creating the same worktree
  will collide. Settle which one owns worktree lifecycle before wiring them
  together; until then the seam is the issue, and nothing deeper.
