# cygnus — progress

## 2026-07-19

- Plan of record agreed (see `docs/architecture.md`): graph-engine-first
  MVP, GRDB interval-versioned store, SwiftSyntax + tree-sitter
  extractors (Swift/Python/C), SwiftUI shell with Canvas Flat view then
  RealityKit 3D behind a renderer seam.
- E0/S0 scaffold: repo initialized, factory files, CygnusCore +
  CygnusKit packages, xcodegen app shell.
- Dependency audits recorded in MISSION.md §5 (GRDB, swift-syntax,
  SwiftTreeSitter + grammars).
- E0 spike (tree-sitter): python + c grammars parse under Swift 6,
  including error-tolerant recovery. tree-sitter-python pinned exact
  at 0.23.6 — 0.25.0's manifest drops the external scanner under
  SwiftPM's sandbox (relative-path probe) and fails to link.
- E0 spike (storage): interval-schema benchmark green — 43 µs current
  neighborhood lookups, 171 ms for a 10k-fact revision commit at 1M
  rows. Numbers in docs/schema.md. E0 complete.
- E1 complete: `GraphStore` protocol + assertion types in CygnusGraph
  (Observation moved into the canonical model), full schema as GRDB
  migrations, `SQLiteGraphStore` with one-transaction revision
  commits, upsert/dedupe semantics, FTS name search, provenance
  links. 16 tests green incl. revision isolation, time travel, and
  atomic rollback on unknown-entity assertion.
