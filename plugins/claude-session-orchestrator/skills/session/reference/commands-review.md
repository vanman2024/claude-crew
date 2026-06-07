# Review Command — The Reviewer (Overseer) Loop

> Paths/session/repo/branch come from `.claude/session-plugin.json` — substitute `<repo>`, `<wt>`, `<sess>`, `<gh>`, `<base>`.

**YOU ARE THE REVIEWER.** Run from the dedicated reviewer Claude spawned by
`dispatch/start-reviewer.ps1` into `<sess>:reviewer` — its own home worktree at
`<wt>/reviewer` (detached at `origin/<base>`, never checked out, never committed to).
You verify worker PRs **one at a time, in merge order, as they go green**, so nothing
is ever merged blind. You do **not** merge — you produce an ordered, verified queue and
the user authorizes each merge.

The reviewer is the automated form of the pre-merge verification in the
[merge protocol](../SKILL.md) ("checkout the branch in its own worktree, smoke-test,
then merge"). The orchestrator (`orchestrate poll`) *flags* green PRs; the reviewer
*proves* them.

Sub-commands: `review` (one cycle, the `/loop` body) and `review-start` (spawn the loop).

---

## THE CONTRACTS (load-bearing — do NOT violate)

1. **No merge.** The reviewer **NEVER** runs `gh pr merge`. It labels PRs
   `READY-VERIFIED` and presents the ordered queue. The user authorizes every merge
   through their conversational Claude ("merge it"). (Same as orchestrator Contract 1.)

2. **Verify only in the checkout worktree.** All PR-branch checkouts and test runs happen
   in `<wt>/review-checkout` — a dedicated worktree with `node_modules` junctioned from the
   main checkout. **NEVER** `git checkout` / `git pull` / commit against the main repo at
   `<repo>`, the reviewer's own home at `<wt>/reviewer`, or any worker's worktree.

3. **Don't fix — send back.** The reviewer reviews; workers fix. On a failing PR, post the
   findings as a PR review comment and nudge the owning worker (if still live). Never edit
   the worker's code yourself.

4. **One PR at a time, in overlap order.** Verify sequentially. Disjoint PRs (no shared
   files) can be verified/queued in any order; PRs that touch the same path must be
   sequenced (verify the lower PR number first). Re-verify a PR only after a new commit is
   pushed to its branch.

5. **Batch-scoping.** "This batch" = open PRs whose head branch matches an ACTIVE worker
   worktree under `<wt>/`, EXCLUDING `<wt>/reviewer`, `<wt>/review-checkout`, and
   `<wt>/orchestrator`. PRs from previous sessions or the user's own branches are out of
   scope. (Mirrors orchestrator Contract 2.)

6. **`/loop` is the cron.** The cadence is `/loop <interval> /session review`. Never use
   Windows scheduled tasks or `Start-Sleep` loops. The PS launcher's job ends after
   launching Claude. (Mirrors orchestrator Contract 6.)

7. **Self-terminate.** End the loop when there are no live worker windows AND no open batch
   PRs left to verify. Print the final queue, exit the loop, exit Claude.

---

## The Review Gate

A PR is `READY-VERIFIED` only if **BOTH** pass:

- **A. Tests green** — the project's `config.layout` test commands pass when run against the
  PR branch checked out in `<wt>/review-checkout`.
- **B. Code review clean** — with the PR head checked out in `<wt>/review-checkout`, run
  `/code-review` (it reviews the checked-out changes vs `<base>`) and find no blocking
  (correctness/security) issues. Use `gh pr diff <n>` if you want the raw diff alongside.

Tests prove it *runs*; the review proves it *fits*. Green CI alone is not enough — that is
exactly the "blindly pulling stuff in" the reviewer exists to prevent.

---

## How it fits with the orchestrator

```
ORCHESTRATOR (<sess>:orchestrator)            REVIEWER (<sess>:reviewer)
  watches worker panes, nudges                  watches for GREEN batch PRs
  flags green PRs "READY FOR USER REVIEW"  ───►  checks each out (one at a time, in order)
  cleans up after USER merges                    runs tests + /code-review on the diff
  never touches git working state                labels READY-VERIFIED / CHANGES-REQUESTED
                                                 presents the ordered, verified merge queue
                          ▼                                          ▼
                 USER says "merge it"  ◄──── reads the verified queue, merges in order
```

Two autonomous roles, two psmux windows, two `/loop`s. The orchestrator manages the
**workers**; the reviewer manages the **PRs**. Both self-terminate when the batch is done.

---

## `review` — one cycle (the `/loop` body)

### Phase 1 — Compute the batch (Contract 5)
```bash
git -C <repo> worktree list --porcelain
gh pr list --repo <gh> --state open --base <base> --json number,title,headRefName,statusCheckRollup,mergeable
```
Keep only PRs whose `headRefName` matches an active worker worktree branch. Skip
`reviewer`, `review-checkout`, `orchestrator`. Drop PRs you have already marked
`READY-VERIFIED` (unless a newer commit landed since).

### Phase 2 — Order by file overlap (Contract 4)
For each candidate PR:
```bash
gh pr view <n> --json files --jq '.files[].path'
```
- PRs sharing no paths with any other candidate → independent; queue in any order.
- PRs sharing a path → must be sequenced; verify the lower PR number first and note the
  dependency in the queue.

### Phase 3 — Verify the FIRST un-verified PR (Contract 2)
In the checkout worktree only — check out the PR head **detached** (the worker still holds
that branch in its own worktree, and git refuses to check out one branch in two worktrees):
```bash
git -C <wt>/review-checkout fetch origin <branch>
git -C <wt>/review-checkout checkout --detach FETCH_HEAD
```
Then, **gate A** — run the project test commands (from `config.layout`, cd into the
checkout worktree / its parts). Fix nothing. **gate B** — run `/code-review` against the
checked-out PR head (reviews its changes vs `<base>`).

> `node_modules` is already junctioned into `<wt>/review-checkout` by the launcher, so no
> install is needed between branch checkouts.

### Phase 4 — Verdict
- **PASS** (gate A green AND gate B no blocking findings):
  ```bash
  gh pr review <n> --approve --body "READY-VERIFIED: tests pass, no blocking review findings."
  gh pr edit <n> --add-label "READY-VERIFIED"   # if labels are in use; otherwise the approval is the signal
  ```
  Add it to the ordered queue with its position and any sequencing dependency.
- **FAIL**:
  ```bash
  gh pr review <n> --request-changes --body "<the blocking findings, concise>"
  ```
  If the worker window is still live, nudge it:
  ```bash
  psmux send-keys -t <sess>:<worker> "Review found: <one-line fix>. Fix on this branch and push." Enter
  ```
  Do not re-verify until a new commit is pushed.

### Phase 5 — Report the queue
```
REVIEW QUEUE (verified, in merge order)
  1. #26 feature/f008-quiz      tests PASS  review PASS   READY-VERIFIED  (disjoint)
  2. #25 feature/f021-referral  tests PASS  review PASS   READY-VERIFIED  (after #26: both touch lib/db.ts)
Awaiting fixes:
  #31 feature/f045-progress     review CHANGES-REQUESTED -> nudged worker
Not yet verified: #33 (CI still running)
```

### Phase 6 — Self-terminate check (Contract 7)
No live worker windows AND no open batch PRs left to verify → print the final queue, exit
the `/loop`, exit Claude.

One PR verified per pass keeps the loop sequential and the pane legible. The next tick
picks up the next PR (or a pushed fix).

---

## `review-start` — spawn the reviewer loop

Launch the dedicated reviewer Claude (its own worktrees + psmux window + `/loop`):
```
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/start-reviewer.ps1" -IntervalMin 5 -Config "<repo>/.claude/session-plugin.json"
```
This is launched automatically by `start-orchestrator.ps1` (unless `-NoReviewer`), so you
usually do not run it by hand. Use it standalone when you started workers without the
orchestrator and still want continuous verification.

Interval resolves from `-IntervalMin`, else `config.review.intervalMin`, else 5 minutes.

Stop: `psmux kill-window -t <sess>:reviewer` (or it self-terminates — Contract 7).

---

## When the user says "merge it"

The reviewer has already done the hard part: each `READY-VERIFIED` PR is tested, reviewed,
and ordered. The user's conversational Claude just executes the merge protocol in
[SKILL.md](../SKILL.md) over the verified queue — squash-merge in queue order, rebasing
the next overlapping PR after each merge.
