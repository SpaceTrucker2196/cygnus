---
title: Index Enrichment
summary: Compiler-resolved reference edges from a built index store — what they unlock, and the two very different places the store hides.
updated: 2026-07-31
---

# Index Enrichment

Extractors can see that a file declares `Foo` and that another file
mentions `Foo`. They cannot prove those are the same `Foo`. The
compiler already did that work and wrote it down: the **index store**
(`-index-store-path` artifacts) holds definition, reference, and call
occurrences keyed by USR.

Reading it produces two edge kinds that syntax alone cannot support:

- `core:references` — file → file, with a reference count that drives
  edge thickness.
- `core:refersToSymbol` — declaration → declaration, the actual
  caller/callee wiring.

Without them, the Code view has only imports to work with, and the
Callers and Symbols views are empty. See [[graph-projections]].

## Where the store lives

This is the part that surprises people, and it is the difference
between a repo that renders richly and one that renders as a handful
of nodes.

**SPM packages** keep it in-tree, at
`.build/<triple>/debug/index/store`. The root package and first-level
nested packages are both checked. Nothing outside the repo is
involved, so it works on a fresh clone the moment you build.

**Xcode projects** keep it nowhere near the repo — under
`~/Library/Developer/Xcode/DerivedData/<Name>-<hash>/Index.noindex/DataStore`.
The repo carries no pointer to it and the directory name embeds a
hash of the workspace path, so it cannot be guessed from the repo
name. The mapping back is each build directory's `info.plist`, whose
`WorkspacePath` names the `.xcodeproj` or `.xcworkspace` it was built
from: a build directory belongs to this repo when that path lies
inside the repo root.

Two containers are searched, and in-tree wins because it is
unambiguously this checkout's:

1. `<root>/.build/…` — SPM.
2. Xcode's shared DerivedData, filtered by `WorkspacePath`, plus
   `<root>/DerivedData` for the "relative to workspace" build setting
   (which may write no `info.plist` at all — that layout is ours by
   construction).

When a repo has several matching build directories — a renamed
project, a workspace and a project side by side — the most recently
accessed wins.

Containment is checked on path-component boundaries. A plain prefix
test lets `nighthawk-iOS-old` claim `nighthawk-iOS`'s store, which
would silently attribute one repo's references to another.

## Staleness

An index store keeps units for files that no longer exist. Only
references between files in the current snapshot are evidence about
it, so ghosts are filtered at the point of use rather than trusted.

Enrichment also runs on a source no-op, because a build can happen
between analyses. See [[analysis-pipeline]].

It does **not** run when neither the store nor the snapshot has moved.
That guard exists because the original rule — "re-run whenever the
source did not change" — watched the wrong thing. Measured on
2026-08-03, nighthawk-iOS spent 30 s of a 30.3 s analysis inside an
Xcode index store, for 113 files, and paid it again on every
re-analysis. What matters is whether the *store* was rebuilt, not
whether the source changed, so the workspace keeps a small
`enrichment-state.json` fingerprinting the store's unit and record
directories. Re-analysis of an unchanged repo went from 30 s to 0.1 s;
building the project still changes the fingerprint and still brings
new symbols in.

The fingerprint is written *before* the read, not after: a store that
makes the reader hang must not be retried on every analysis forever.

## When it is only partial

Worse than missing, because it is silent. An index store covers the
targets that produced it, and a repository built two ways — an Xcode
app plus SwiftPM packages — has two indexes where cygnus reads one.
Callers and Symbols then draw a confident picture of part of the code.

`GraphScene.referenceCoverage(from:)` reports how many source files
the reference data provably reaches, and the app shows it under those
views when it is not everything. It is a **lower bound** by
construction: a file with no references either way is either one the
index never saw or one that genuinely connects to nothing, and those
are indistinguishable. That same ambiguity is why dead-code detection
was refused — see [[visualization-ideas]].

Measured on cygnus: the SwiftPM packages are covered, the app target
is not.

## When it is missing

Nothing fails. The graph degrades to the syntax baseline and the
Symbols view says so. If a repo looks emptier than it should, check
whether it has ever been built — that is the first question, not the
last. See [[troubleshooting]].
