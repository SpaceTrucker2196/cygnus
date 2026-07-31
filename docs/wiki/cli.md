---
title: The cygnus CLI
summary: The headless harness — the fastest way to exercise the engine without the app, and the first tool to reach for when the UI looks wrong.
updated: 2026-07-31
---

# The cygnus CLI

`cygnus` is the engine harness. When the app shows something
surprising, the CLI answers "is this the engine or the UI?" in about
a minute — which is almost always the right first question. See
[[troubleshooting]].

Build it with `swift build --product cygnus` from `CygnusCore/`.

## Workspace location

The workspace directory is `$CYGNUS_WORKSPACE`, falling back to
Application Support. Set it to a scratch path to investigate without
touching the app's own workspace:

```
export CYGNUS_WORKSPACE=/tmp/ws-scratch
```

The app's engine data lives inside its container, separate from the
CLI default — so indexing a repo on the CLI does **not** update what
the app shows, and vice versa. Re-analyze in the app to see engine
changes there.

## Commands

```
register <path>    register a repository in the workspace
repos              list registered repositories
index              snapshot + analyze all registered repositories
query contains     print the containment tree
query deps         print the import graph
revisions          list graph revisions
diff <r1> <r2>     what changed between two revisions
verify             full rebuild vs incremental graph, per repository
watch              continuous incremental analysis (FSEvents)
bench              interval-schema storage benchmark
```

## Reading the output

`index` prints one line per repo:

```
nighthawk-iOS: revision 3, 104 files (104 changed), 578 entities, 770 edges asserted [0.4s]
```

`revisions` is the analysis history in readable form, and the notes
name the phase that produced each one:

```
r1  index nighthawk-iOS: +104 ~0 -0
r2  derive nighthawk-iOS: import rollups
r3  enrich: 38 file + 112 symbol reference edges
```

A missing `enrich` revision means [[index-enrichment]] found no index
store — the single most common reason a repo looks emptier than it
should.

`query deps` prints the import graph as `from → to` lines, which is
the fastest way to see what a repo actually imports before arguing
about what the graph *should* show.

## verify

`verify` rebuilds each repository from scratch and compares the result
against the incrementally-maintained graph. Incremental analysis is
the part most likely to drift silently; this is how that gets caught.
