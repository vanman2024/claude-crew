## What this changes

## Why

Closes #

<!-- Required, not optional. `Closes #N` here is the only thing that actually
     closes the issue when this merges — the same line in an issue body is
     inert, and closing a parent does not close its sub-issues. `devctl packet
     <n>` prints the exact line under HOW IT LANDS. Without it the issue stays
     open and somebody closes it by hand, or nobody does. -->

## How it was verified

<!-- Not "tests pass" — which tests, and what would have caught this before. -->

- [ ] `devctl test changed` — the tests covering what moved
- [ ] full-stack contract checked, if this spans frontend and backend
- [ ] blast radius confirmed with a text search, not only the graph

The graph misses dynamically imported tests, so its impact is a floor rather
than a ceiling. On this plugin that hid 211 coupled tests.
