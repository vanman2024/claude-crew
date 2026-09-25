# The Project Board: GitHub Projects, kept in step with the build

> Substitute `<repo>`, `<gh>` (owner/name), `<base>` from `status/resolve-config.ps1`, which
> also prints `githubProject` (the board: `ownerKind`, `owner`, `number`).

## Which tool for what

| Thing | Tool | Never |
|---|---|---|
| Issues and pull requests: create, view, edit, comment, merge | **`gh` CLI** (`gh issue ...`, `gh pr ...`) | The GitHub MCP / plugin tools for these |
| The project board: items, Status and other fields, status updates | **GitHub Projects MCP** (`mcp__claude_ai_GitProjects__*`) | `gh project ...` |

One writer: only the **conductor** changes the board. The orchestrator, reviewer and workers
never touch it. They report; the conductor reflects what they report onto the board.

**If the GitHub Projects MCP isn't connected**, say so plainly ("the GitHub Projects connector
isn't available, so the board isn't being updated") and carry on with the build. Do not fall
back to `gh project`, and do not skip the board silently.

**No board configured** (`githubProject` missing from the resolved config): find it once with
`project_list` (owner = the repo owner, `USER` or `ORGANIZATION`) and pick the board whose
title or readme names this repo or product. If exactly one fits, tell the user which one and
offer to save it to `.claude/session-plugin.json` as
`"githubProject": { "ownerKind": "USER", "owner": "<login>", "number": <n> }`. If none or
several fit, ask.

## Once per session: learn the board

```
project_get          project: { owner_kind, owner_login, number }   -> the project node id
project_list_fields  project: { ... }                               -> field ids + option ids
```

Read the board's **README** from `project_get`. It states that board's own rules, for example
which fields every item must carry. Follow them.

Keep the ids you need: the `Status` field and its option ids, plus any other single-select
fields you will set (`Module`, `Phase`, `Priority`). Option ids differ between boards even
when the names match, so never reuse ids from another board.

## Putting an issue on the board, or finding its item

```
github_resolve_issue           repository_owner, repository_name, issue_number  -> content id (node id)
project_add_item_with_fields   project_id, content_id, field_values: [...]      -> item id
```

Adding an issue that is already on the board returns its existing item (`created=false`) rather
than a duplicate. So this pair is also how you **find** the item for issue #N. For a pull
request, use `github_resolve_pull_request`.

To change fields on an item you already have: `project_update_item_field` (one item), or
`project_bulk_update_items` (the same value on up to 25 items, e.g. moving a whole wave).

## Status: what the build does to the board

Map by the option **name** on this board. Boards in this family use
`Backlog / Todo / Ready / In Progress / In review / Staging / Verified / Done`.

| Build event | Status | Who notices |
|---|---|---|
| `plan` creates a wave-1 issue with no open questions | **Ready** | conductor, when creating it |
| `plan` creates a later-wave or `needs-decision` issue | **Backlog** | conductor, when creating it |
| A worker is dispatched on the issue (`start-issues`, `start`) | **In Progress** | conductor, right after dispatch |
| The worker opens its PR | **In review** | conductor's `status` tick (sees the PR via `gh pr list`) |
| The PR merges into `<base>` and `<base>` is a staging branch (`staging`, `develop`, `dev`) | **Staging** | conductor, right after `merge` |
| The PR merges into `<base>` and `<base>` is the production branch (`main`/`master`) | **Done** | conductor, right after `merge` |
| Verified on staging / promoted | **Verified** / **Done** | the user says so; the crew never claims verification |

Only move an item forward along that list, and only to an option that exists on this board.
If the board lacks an option (e.g. no `Staging`), use the next one that exists and say so.
Never move an item backwards unless the user asks.

## Classifying an item: you read it, you decide; nothing is copied

Scripts build a board's structure. **You** classify the items, by reading each one. Never copy a
label into a field: that is how a board ended up saying everything twice (see dev-lifecycle's
`catalog/github-project.yaml`, CLASSIFICATION).

| Field | What you set |
|---|---|
| **Module** | One value from the board's fixed list. **Feature work**: the product module it serves (the product's module registry). **Plumbing**: the `Platform — …` area of the architecture plane it builds (Surfaces & Routing, Trust & Contracts, Work & Correctness, Integrations, Operations, AI). Which list the value comes from *is* feature vs plumbing. Nothing fits → leave it empty and say so; never add an option |
| **Work type** | **Don't.** The kind of change lives on the label only (`bug`, `enhancement`, `refactor`, `chore`, `discovery`). If a board still has a Work type field, leave it alone; it's being retired |
| `Phase` | `Develop` for build work dispatched to workers, if the board has Phase |
| `Dependency order` | the plan's wave number, if the board has this field |
| Priority, dates, Release slice, Product | only when the spec, the issue or the user states it. Otherwise **leave empty** and list it as "to fill" |

Never guess a priority, a date or a module to satisfy a board rule. An empty field the user can
see is better than a plausible wrong one.

## Trackers: how a large piece is organized and seen

All work lives on the one board. A **large** piece (a spec that splits into several issues, an
audit, a release push) gets a tracker. A small one doesn't: a tab for every epic is noise.

1. **The tracker issue:** `gh issue create --title "[Tracker] <what>" --body-file <file>`. Its body
   is the checklist and the source of truth for the piece.
2. **Real sub-issues**, not a list of links, through `gh`:
   ```
   id=$(gh api repos/<owner>/<repo>/issues/<child#> --jq .id)
   gh api -X POST repos/<owner>/<repo>/issues/<tracker#>/sub_issues -F sub_issue_id=$id
   ```
3. **Its own tab on the board**, through the Projects MCP (`gh` has no view command):
   `project_create_view` (name: the tracker's subject, layout `BOARD_LAYOUT`), then
   `project_update_view` with `filter_text: "parent-issue:<owner>/<repo>#<tracker#>"`.

The tracker itself goes on the board too, in the same Module as its pieces.

## Reading the board for `status`

`project_search_items` with a query such as `is:open repo:<gh>` lists the batch's items with
their Status. Compare them with what is actually true (`gh pr list`, the orchestrator's report).
Where the board is behind (a PR is open but the item still says In Progress), advance it and
mention the change in one line.
