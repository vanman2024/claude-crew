# Plan Command: a spec, but no issues yet

> Substitute `<repo>`, `<gh>`, `<base>` from `status/resolve-config.ps1` (see the skill's STEP 0).

The user hands you a spec (one file or several) and there are no issues for it yet, or only
some. Your job is to turn the spec into dispatchable GitHub issues **without adding anything
the spec doesn't say**. Workers build exactly what their issue says. An invented requirement
becomes real code, and a guessed field name becomes a real bug.

**Principle: split, don't write.** Your output is the spec's own content, cut into
one-worker pieces. Where the spec is silent, you ask; you don't fill in.

---

## Phase 1: Read, and check what already exists

1. Read every spec file IN FULL. Not a skim, not the headings.
2. Look for issues that already cover parts of it, so nothing is duplicated:
   ```
   gh issue list --repo <gh> --state all --search "<spec file name>" --json number,title,state,body --limit 50
   gh issue list --repo <gh> --state open --json number,title,labels --limit 100
   ```
   An open issue that covers a piece → reuse it (note its number). A closed one → that piece
   may already be built: check the code before planning it again.
3. **Too vague to split?** If the spec is a paragraph of intent with no concrete behaviour,
   STOP. Tell the user what's missing (screens, fields, endpoints, rules, acceptance) and ask.
   Don't draft a plan to fill the gap.

## Phase 2: Cut it into pieces

Cut along the spec's **own** structure: its sections, requirements or user stories. Each
piece should be:

- **One worker's job**: a coherent slice that ends in one PR.
- **One file-lane**: map it to `config.teams` `ownsPaths`. Two pieces that would edit the same
  files are either merged into one piece or sequenced (see waves).
- **Traceable**: it points to the exact spec section (heading or line range) it comes from.
  Everything in the piece comes from that text.

**Waves.** A piece that needs another's output goes in a later wave: schema before the API that
uses it, API before the screen that calls it. Wave 1 is everything with no unmet dependency.
Only wave 1 gets dispatched now.

## Phase 3: The no-invention rules

These are the whole point of this command. For every piece:

| The spec... | You write |
|---|---|
| States a requirement | It, quoted or closely paraphrased, with its section |
| States acceptance criteria | Them, copied |
| States **no** acceptance criteria for this piece | `Acceptance: not stated in the spec.` Plus an open question. Never make criteria up |
| Leaves a detail open (a field name, an endpoint path, an error message, a limit, a permission) | An **open question** for the user. Don't pick a value |
| Is contradicted by the code, or contradicts itself | An open question naming both sides |
| Doesn't mention it | Nothing. No "while we're here" refactors, no bonus features, no extra endpoints |

A piece with an open question that blocks building it is marked **`needs-decision`** and not
dispatched until the user answers. Pieces without blocking questions can go ahead.

## Phase 4: Show the plan, create nothing yet

Creating issues is visible to everyone on the repo, so the user approves first. Read the
project board's README first (`project_get`): if it requires fields on every item, include
them in the table, marked "not in spec" where the spec is silent. Show:

```
PLAN: specs/intake.md  →  5 pieces, 2 waves

 #  Piece                         Spec section          Lane      Wave  Depends on  Status
 1  Intake schema + migration     §2 Data model         backend   1     —           ready
 2  Intake API (create/list)      §3 API                backend   2     1           ready
 3  Intake form UI                §4 Form               frontend  2     2           needs-decision
 4  Phone validation              §4.2 Validation       frontend  2     3           ready
 5  Reuses #312 (email notice)    §5 Notifications      —         —     —           existing

Open questions (the spec doesn't say):
  Q1 (#3) §4 lists "contact details" but not which fields. Name, email, phone? Required?
  Q2 (#2) §3 says "paginated" but gives no page size.
```

Then wait. The user answers the questions, edits the cut, or says go. Put their answers into the
issues as the user's decision, marked as such (`Decision (user, <date>): ...`), not as spec text.

## Phase 5: Create the issues

Always write each body to a file and pass `--body-file`. Inline bodies get mangled by shell
quoting, which is what garbled the cross-links in an earlier run.

Body template. The header lines are read by the dispatcher (`Get-IssueBriefHints`), so keep
them exactly like this:

```markdown
Spec: specs/intake.md
Spec section: §4 Form
Mode: feature
Lane: frontend
Wave: 2
Depends on: #<n of piece 2>

## What the spec says
> (the spec text for this piece, verbatim)

## Acceptance (from the spec)
- (copied criteria, each with its spec reference)
  (or: "Not stated in the spec." plus the decision the user gave)

## Decisions
- (user answers to open questions, dated; omit the section if none)

## Out of scope
Anything not in the section quoted above.

Part of #<epic>
```

- `Mode: feature` for new pieces; `iteration` for a change to something that exists.
  The dispatcher briefs a `feature` worker to read the whole spec and build to it.
- Five pieces or more: create a **tracker** first (`[Tracker] <spec title>`, listing the waves),
  make each piece a real **sub-issue** of it, and give it its own board tab filtered to it
  (see [commands-board.md](commands-board.md), "Trackers"). Smaller plans skip the tracker.
- **Put every issue on the project board** as you create it (GitHub Projects MCP, never
  `gh project`; see [commands-board.md](commands-board.md)): Status **Ready** for wave 1 with no
  blocking question, **Backlog** for later waves and `needs-decision`. Set **Module** by reading
  the piece (a product module for feature work, a `Platform — …` area for plumbing) and
  `Dependency order` from the wave if the board has it. Never set Work type: the kind of change
  is the label. Fields the spec doesn't state (priority, dates, release slice) stay **empty**.
  List them in your summary as "to fill".
- Dependencies are written with real numbers, so create in wave order and fill `Depends on`
  as you go. After creating, `gh issue view <n>` each one and check the body rendered, with
  real numbers and no leftover placeholders.

## Phase 6: Dispatch wave 1 only

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch-issues.ps1" -Issues <wave-1 numbers> -Config "<repo>/.claude/session-plugin.json"
```

It prints `From issue: spec=... mode=feature` per issue; if that line is missing, the header
lines are malformed. Fix the issue body before the worker starts. Then `launch`.

Later waves: when all of a wave's dependencies have merged, tell the user that the next wave is
unblocked and dispatch it on their word. `status` checks for this on each tick.
