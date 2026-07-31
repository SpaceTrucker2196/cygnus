---
title: Troubleshooting
summary: Symptoms we have actually diagnosed, with the real cause and the check that distinguishes it from the plausible-sounding wrong answer.
updated: 2026-07-31
---

# Troubleshooting

The method first, because it has repeatedly beaten theorizing:

1. **Reproduce headlessly.** Index the repo in a scratch workspace
   with the [[cli]]. If the engine's counts are healthy, the bug is in
   the projection or the UI, and you have just halved the search.
2. **Read the revision list.** `cygnus revisions` names the phase that
   produced each revision; a missing phase is the answer more often
   than a wrong one.
3. **Check the live app, not the tests.** Several of the worst bugs
   here were invisible to a green suite and obvious in the running
   process.

## A repo shows only a couple of nodes in Code view

Diagnosed on `nighthawk-iOS`, and worth walking through because every
step generalizes.

The engine was fine — 104 files, 578 entities, 770 edges. The Code
scene was throwing the rest away. Two causes stacked:

- **Every import was an Apple framework.** System modules are never
  charted ([[graph-projections]]), and nodes used to be derived from
  surviving edges alone, so files with no charted edge disappeared
  entirely. A single `Tests → AppModule` edge survived: two nodes.
- **No compiler-resolved references existed.** The repo is an Xcode
  project, and index-store discovery only looked in SPM's `.build`.
  Its real index sat in DerivedData, unread. See
  [[index-enrichment]].

Both are fixed. If something similar appears again, the checks in
order are: does `cygnus query deps` show only system frameworks; does
`cygnus revisions` include an `enrich` line; has the project ever been
built.

Note the near-miss: "it must be a recent regression" was wrong. The
projection code had not changed in months — the contrast was against
SPM repos, which get enrichment for free.

## Callers or Symbols is empty

Both scenes are built entirely from `core:refersToSymbol`, which only
exists after [[index-enrichment]]. Build the project, then re-analyze.
Enrichment runs even when no source file changed, precisely so this
works.

## A TypeScript or JavaScript file has nothing in it

There is no TypeScript extractor, despite the `CygnusExtractorTS`
target name. The file charts as a file and declares nothing. See
[[extractors]].

## The app crashes during analysis

If the crash is an `EXC_BAD_ACCESS` on a GRDB reader thread, the
on-disk store has been switched back to a `DatabasePool`. It must be a
serialized `DatabaseQueue` — the crash reproduces only under the GUI's
interleaved access, never headless, never in tests. See [[storage]].

For any resource-shaped bug, measure the live process before
theorizing: `footprint <pid>` for memory, `sample <pid>` to name a
runaway frame. Three rounds of plausible-theory fixes once missed a
bug that a single `sample` named exactly.

## The CI-flow chart aborts on a large repo

Geometry uploaded via `setVertexBytes` exceeds its 4 KB cap. Use an
`MTLBuffer`. See [[renderers]].

## Every flow label is upside down

Texture V orientation, not fonts. See [[renderers]].

## A repo says it needs relinking

The security-scoped bookmark no longer resolves — the folder moved or
was deleted. Re-pick it; there is no way to repair a bookmark to a
path that is gone.

## The CLI and the app disagree

They keep separate workspaces by design: the app's engine data lives
in its container, the CLI's under `$CYGNUS_WORKSPACE` or Application
Support. Indexing on the CLI never changes what the app shows.
Re-analyze in the app.
