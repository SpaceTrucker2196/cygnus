# cygnus — storage schema

## Decision (E0, validated)

SQLite via GRDB, one database per workspace, WAL mode, interval-
versioned append-only schema: every fact row carries a
`[valid_from, valid_to)` revision interval; rows are never mutated
except to close `valid_to`; a revision commit is one transaction.
"Current graph" is `valid_to IS NULL` (covered by partial indexes);
"graph at revision R" is the same query with an interval predicate.

Prototype: `CygnusCore/Sources/CygnusStore/SchemaPrototype.swift`.
The full schema (entities, entity_versions, observations, provenance,
snapshots, FTS) lands in E1 as GRDB migrations.

## E0 benchmark (`cygnus bench`)

M-series Mac, 2026-07-19, release build, on-disk WAL, deterministic
seed. 50k entities, 1M relationships (~20% retracted) across 100
revisions:

| operation | result |
|---|---|
| insert 1M relationships (100k/tx batches) | 8.4 s |
| current neighborhood lookup (partial index) | 43 µs avg (1000 lookups, 16k edges) |
| as-of historical neighborhood lookup | 18 µs avg |
| full current-edge COUNT (800k rows) | 20 ms |
| revision commit: retract 5k + assert 5k, one tx | 171 ms |
| database size | 101 MiB |

Read: the E5 targets (incremental commit ≤ seconds, cold index of a
5k-file repo in low minutes) have order-of-magnitude headroom —
storage will not be the bottleneck; extraction will. Viewer-facing
neighborhood queries are effectively free at MVP scale.

## Invariants the schema must keep (MISSION.md §2)

- Append-only discipline (no UPDATE except closing `valid_to`).
- Partial indexes on the `valid_to IS NULL` hot path.
- Provenance is join-shaped and doubles as the incremental
  invalidation index.
- Snapshot blobs live in the content-addressed store beside the DB
  (`cas/ab/cdef…`), never as SQLite blobs.
