---
title: The Analysis Pipeline
summary: Snapshot, extract, resolve, derive, enrich, commit — what each phase reads, what it is allowed to write, and where the memory ceiling bites.
updated: 2026-07-31
---

# The Analysis Pipeline

One `index` run takes a repository from files on disk to a committed
revision of the graph. The phases are ordered by what they are allowed
to touch, which is also the order of increasing interpretation. The
app reports them by name in the analysis banner: *scanning*,
*extracting*, *resolving*, *committing*.

## 1. Snapshot

A provider walks the working tree and produces a manifest: every file
with its path, size, content hash, and a language hint from the
extension. Contents land in a content store keyed by hash, so
unchanged files cost nothing to re-analyze.

The walk skips `.git`, `.build`, `.swiftpm`, `DerivedData`,
`node_modules`, and the innards of `.xcodeproj` / `.xcworkspace`
bundles. Files over the ingest size cap still appear in the manifest —
their existence is a fact — but their contents are not read.

The walk takes a **budget** closure, checked once per captured file,
and throwing from it aborts the walk. This exists because a 5 GB
working tree is ingested here, before extraction has even started; a
walk that cannot be stopped is a walk that can exhaust memory before
any analysis happens. The app passes its hard ceiling.

## 2. Extract

Each file goes to whichever extractor claims its language, which emits
**observations** — literal facts, in the file's own terms. Extractors
never touch the store and never interpret. See [[extractors]].

## 3. Resolve

Observations become entities and relationships with stable keys.
Module names resolve to `<language>:module:<name>` keys, so the same
module referenced from three files is one node. The language hint from
the manifest is recorded as a property here.

## 4. Derive

Derivers are pure passes: read current facts, return the changes that
bring the derived layer up to date, and let the caller commit. They
never write observations and never read providers.

`ImportRollupDeriver` is the one to reason from: for every directory,
one `core:dependsOn` edge per module imported anywhere in its subtree,
with the aggregate count as a property. Each rollup edge is supported
by the union of the observation ids behind the file-level imports it
aggregates — so rollups die with their imports, automatically. That
provenance discipline is the whole point; see [[knowledge-graph]].

## 5. Enrich

Reference enrichment reads a compiled index store and asserts
compiler-resolved `core:references` (file → file) and
`core:refersToSymbol` (declaration → declaration) edges. It is
optional by design: a repo without a build degrades to the syntax
baseline rather than failing.

Two details worth knowing:

- Enrichment runs **even when no source file changed**. An index store
  can appear between runs (someone built the project), and enrichment
  reads the store, not the source — without this, symbols would never
  show up after a build.
- Index stores keep units for deleted files. Only references between
  files in the *current* snapshot are evidence about it, so ghosts
  from an old build are filtered out.

See [[index-enrichment]] for where the store lives.

A second enrichment pass reads **git authorship** on the same
best-effort contract: one observation per (commit, file) touch,
derived `core:authoredBy` edges carrying commit counts, and inferred
`core:ownedBy` where a single author holds at least 60% of a file's
history. Below that threshold a file is *shared* and gets no owner —
which is the finding, not a gap in the computation. Merge commits are
excluded, so whoever merges does not appear to own everything, and
only the most recent 2,000 commits are read: this is the first
history-sized data the graph holds, and recent history is the more
honest ownership signal anyway.

## 6. Commit

One revision, one transaction. The revision note says what happened
(`index nighthawk-iOS: +104 ~0 -0`, `derive …: import rollups`,
`enrich: 38 file + 112 symbol reference edges`), which makes
`cygnus revisions` a readable history of the analysis itself. See
[[cli]].

## Incremental runs

A re-index diffs the new manifest against the last one and analyzes
only what changed. When the diff is empty the pipeline short-circuits
to the enrichment check above — no empty revision is committed.

## Concurrency and memory

- One `CygnusWorkspace` per directory, process-wide. A workspace owns
  a database pool, and two pools on one database file in one process
  is a programmer error — concurrent analyses each building their own
  workspace was a real crash, not a theoretical one.
- Projection reads are serialized with index writes on the workspace
  actor. The store is shared across repos, and reading it off-actor
  raced writes from a concurrent analysis.
- The app enforces a hard memory ceiling and surfaces it as the
  sidebar meter.
