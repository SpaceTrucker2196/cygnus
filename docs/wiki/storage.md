---
title: Storage
summary: Interval-versioned append-only SQLite via GRDB — and why the on-disk store deliberately gives up concurrent readers.
updated: 2026-07-31
---

# Storage

SQLite through GRDB, one database per workspace, WAL mode. The full
schema decision and the E0 benchmark live in `docs/schema.md`; this
page is the reasoning you need before touching the store.

`CygnusStore` is the **only** target that imports GRDB. That is a
dependency rule, not a preference: it keeps the model
(`CygnusGraph`) free of any storage vocabulary, which is what lets
everything else depend on the model without inheriting a database.

## Interval versioning

Every fact row carries a `[valid_from, valid_to)` revision interval.

- Rows are never mutated except to close `valid_to`.
- A revision commit is one transaction.
- The current graph is `valid_to IS NULL`, covered by partial indexes.
- The graph *at* revision R is the same query with an interval
  predicate.

So history is a property of the schema rather than a feature bolted
on top: retraction is closing an interval, and nothing is ever
overwritten. See [[knowledge-graph]].

Provenance is join-shaped and doubles as the incremental invalidation
index — the reason derived facts do not need a cleanup pass.

## DatabaseQueue, not DatabasePool

The on-disk store uses a serialized `DatabaseQueue`. This is a
correctness fix, and it is easy to "optimize" back into a crash.

A recurring `EXC_BAD_ACCESS` on a `GRDB.DatabasePool.reader` thread
reproduced **only** in the GUI's interleaved access pattern — never
headless, never in tests, because tests use the in-memory
`DatabaseQueue`. Serializing on a queue removes the pooled readers
entirely. Concurrent reads buy nothing here: analysis is effectively
one-at-a-time.

Two related invariants from the same family of bugs:

- One workspace per directory, process-wide. Two pools on one database
  file in one process is a programmer error.
- Projection reads are serialized with index writes on the workspace
  actor; reading off-actor raced writes from a concurrent analysis.

The pattern to notice: every one of these bugs was invisible to the
test suite and obvious in the running app. See
`verify-live-in-running-app` in practice — tests passing was never the
bar.

## Working on the store

- Never add an `UPDATE` that changes a fact. Closing `valid_to` is the
  only legal mutation.
- Keep the partial indexes on the `valid_to IS NULL` hot path; the
  current-graph query is the one everything else waits on.
- New external dependencies need a MISSION.md audit recorded in
  `PROGRESS.md`.
