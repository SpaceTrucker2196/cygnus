# cygnus — mission

## 1. Charter

Cygnus turns repositories into understanding. It models the software
*system* represented by a repository — not the files — as a Knowledge
Graph, and renders that graph as a navigable 3D space.

The repository is not the product. The repository is raw evidence.
Cygnus exists to transform evidence into understanding.

A river.io product. Native macOS, Swift, local-first: analysis runs
on-device, no servers, no telemetry, no network entitlement in v1.

## 2. Sacred invariants

These are product rules, not implementation details. A feature that
crosses one of them is wrong even if it works.

1. **Every entity has a stable identity** that survives layout changes
   and, where possible, refactors. Identity is never a filename.
2. **Every relationship connects valid entities** and is a first-class
   object (direction, layer, confidence, provenance).
3. **Every derived fact is traceable** to the observations that
   support it. "Why does Cygnus believe this?" always has an answer.
4. **Every observation has provenance** (snapshot, blob hash, range,
   extractor + version).
5. **Every graph revision is immutable.** History is preserved;
   removal never erases it.
6. **Every visualization is a projection** — disposable, recomputable,
   never a second model.
7. **Every query executes against the graph.** No subsystem keeps an
   alternative representation of the software system.
8. **Plugins extend, never replace, the canonical model** (namespaced
   kinds and properties, not forks).
9. **Observed / derived / inferred are visibly distinct.** Users can
   always tell source-of-truth facts from analysis. Heuristic edges
   carry confidence; faking semantic understanding erodes trust and is
   forbidden.
10. **Directory structure is not architecture.** Physical and logical
    entities are separate; logical boundaries emerge from analysis.

## 3. Scope (MVP)

- Engine first: graph model, GRDB store with interval-versioned
  revisions, content-addressed snapshots, providers (local FS, git),
  observation pipeline, extractors for **Swift, Python, C**, derived
  layer (contains, imports, metrics), query surface, CLI harness.
- Shell: workspace app, outline + inspector + search, 2D Flat graph
  view, then RealityKit 3D. Perf gate: 60 fps at 2k nodes / 6k edges.

## 4. Non-goals (v1)

- No cloud analysis, accounts, or sync.
- No call graph until it can be truthful (IndexStoreDB enrichment).
- No write access to user repositories (read-only entitlement).
- No query language; a typed query API is enough for the viewer.

## 5. Dependency audits

| dependency | purpose | audit |
|---|---|---|
| GRDB.swift | SQLite store: migrations, Codable records, ValueObservation, WAL | 2026-07-19 — pure SPM, no transitive deps, MIT, local-only |
| swift-syntax | Swift extractor (source-level, no build needed) | 2026-07-19 — Apple/swiftlang first-party |
| SwiftTreeSitter + tree-sitter-python, tree-sitter-c | Python/C extractors, error-tolerant parsing | 2026-07-19 — pinned exact grammar versions; ABI churn is the known papercut |
| indexstore-db | Reference/call-edge enrichment (optional provider; swift-syntax stays the baseline) | 2026-07-24 — swiftlang first-party, Apache-2.0; no semver, pinned by revision to the toolchain-matching swift-6.3.3-RELEASE tag; C++ core + libIndexStore dylib coupling is the known papercut (docs/spikes/indexstoredb.md) |
