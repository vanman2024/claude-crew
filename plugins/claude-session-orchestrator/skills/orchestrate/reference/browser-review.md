# Browser review: one worker's branch, checked for real

> Substitute `<repo>`, `<wt>`, `<sess>`, `<gh>`, `<base>` from `status/resolve-config.ps1`.

This is the review. There is no separate reviewer: you do it, in the user's session, on one
branch at a time. A green CI run proves the code compiles and the tests pass. It doesn't prove the
page renders real data, the links go somewhere, the controls work, or it follows the design.
This does.

## 1. Know what it's supposed to be

- **The issue:** `gh issue view <n> --repo <gh> --json title,body`. Its checkbox list is what you
  check against. Its `Spec:` line names the spec; read that too.
- **The project's gates:** the repo's `CLAUDE.md` (a page order, a definition of done), `DESIGN.md`,
  and the docs the spec points to. Use the project's own rules, not generic ones.
- **The diff:** `gh pr diff <n> --repo <gh> --name-only`, then the parts that matter.

## 2. Static checks

In the worker's own worktree (`<wt>/<name>`), never the main checkout:
- The project's checks from `config.layout` (lint, typecheck, tests, build), or what its CLAUDE.md
  names as the pre-merge hook.
- `/code-review` on the branch's changes against `<base>`: correctness and security findings.

## 3. Run it

From the worker's worktree, beside the user's own servers (`-AutoPort` picks a free port):
```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action start -AutoPort -Dir "<wt>/<name>" -Config "<repo>/.claude/session-plugin.json"
```
Add `backend-server.ps1 -AutoPort` first, and pass its URL as `-ApiUrl`, when the change touches
the backend. A frontend-only PR with a working Vercel preview can be reviewed on the preview URL
instead. `{url}` below is whichever one you're using.

## 4. Look at it in a real browser

Use the project's `browserVerify` steps when it declares them. Otherwise use **`playwright-cli`,
headed**, never Claude in Chrome, with one named session per worker so reviews don't collide:

```
playwright-cli -s=<name> open {url} --headed --browser chrome
playwright-cli -s=<name> resize 390 844     # then 768 1024, then 1440 900
playwright-cli -s=<name> snapshot           # the page structure, with element refs
playwright-cli -s=<name> screenshot         # evidence for the PR
playwright-cli -s=<name> console            # errors
playwright-cli -s=<name> network            # failed requests
```

At **each width** (390, 768, 1440), and in light and dark mode if the site has both:

| Check | How |
|---|---|
| **It renders real data** | read the page (`snapshot`, or `eval` on the values). Placeholder, fixture or zero values where real ones belong are a finding |
| **Nothing is broken underneath** | `network`: any 4xx/5xx is a finding, even when the page looks fine, since that's a silent fallback. `console`: any error is a finding |
| **Layout holds** | no horizontal scroll; nothing overlapping or cut off; tap targets usable at 390 |
| **Links go somewhere** | collect the page's links (`eval "[...document.links].map(a => a.href)"`), then `goto` each internal one: a 404, an error page or a wrong destination is a finding |
| **Interactions work** | exercise what the issue says the page does: `click`, `fill`, `select` on search, filters, forms, menus, pagination. Each one must do what the spec says |
| **It follows the design** | against DESIGN.md and the spec's screens: typography, spacing, colour tokens, components reused rather than reinvented |

Signed-in pages: sign in with the project's test account the way its testing docs say (for Clerk,
its testing-token flow), save it once with `playwright-cli -s=<name> state-save <file>`, and
`state-load` it for later reviews. Never use the user's own account.

## 5. The skills the work is owed

First, did the worker run its own skill? `check-worker-skills.ps1 -Name <worker>`: a
`MISSING` skill, or a step the skill names with no call behind it, is a finding like any other.
Approving a page built without `page-web` / `page-app` is how the mechanicjobs pages shipped
flat.

- **`dev-lifecycle:verify`**: verify the change against its issue and spec.
- **A page** → the checks in `dev-lifecycle:page-web` (public page) or `dev-lifecycle:page-app`
  (signed-in screen): design enforcement against DESIGN.md, web design guidelines, motion review
  when it animates, and the SEO checks for public pages. Run the steps the project's page order
  lists, in its order.
- **Anything else the issue's checklist names.** The checklist is the contract.

## 6. Verdict, and where it goes

**Findings** (anything above that failed):
1. Send the worker ONE message with all of them: what's wrong, where (URL, width, element), what
   done looks like, and "fix on this branch and push; I'll re-review the new commit".
   ```
   pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/send-to-worker.ps1" -Name <name> -Message "<the findings, one line>" -Config "<repo>/.claude/session-plugin.json"
   ```
2. Put the same findings on the PR, with screenshots: `gh pr review <n> --request-changes --body-file <file>`.
3. Re-review only after a new commit lands.

**Nothing found:**
1. Tick the issue's checkboxes you proved, each with its evidence (the screenshot, the output).
2. Approve on the PR with what you checked: `gh pr review <n> --approve --body-file <file>`.
3. Mark the worker's task `completed` once every box is ticked, and tell the user it's ready for
   their merge.

## 7. Clean up

`playwright-cli -s=<name> close`, and stop the dev server(s) you started
(`dev-server.ps1 -Action stop -Port <n>`). One branch's servers and browser at a time.
