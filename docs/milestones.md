# cygnus — milestones

Engine (E) is the critical path; shell (S) runs in parallel against
`FixtureGraphEngine`. Sizes: S ≤ 1 session, M = 1–2, L = 2–4.

## Engine

- [x] **E0** — Scaffold + de-risk spikes: tree-sitter under Swift 6;
      GRDB interval-schema 1M-row benchmark (results in
      `docs/schema.md`). *(2026-07-19)*
- [x] **E1** — Graph model + store: schema, revision transactions,
      provenance links, append-only/isolation tests. *(2026-07-19)*
- [x] **E2** — Providers: LocalFS walk + CAS + manifest diff, git
      source_ref, `cygnus register`. *(2026-07-19)*
- [x] **E3** — Pipeline + Swift extractor + entity resolution;
      `cygnus index` on a real repo (GRDB: 2,920 files → 23.8k
      entities / 38.8k edges in 3.4 s cold). *(2026-07-19)*
- [x] **E4** — Python/C tree-sitter extractors; cross-language fixture
      indexed end-to-end. *(2026-07-19)*
- [x] **E5** — Incremental re-index via committed-snapshot manifest
      diff (0.6 s no-op on GRDB); query projections (contains tree,
      dependency graph, neighborhood); `CygnusWorkspace` facade.
      *Deferred to E6: FSEvents watch, `cygnus verify`, diff-between-
      revisions query, derived-layer rollups.* *(2026-07-19)*
- [ ] **E6** — Hardening: FSEvents watch, `cygnus verify`, revision
      diff query, derived rollups, fuzzy renames, IndexStoreDB spike.

## Shell

- [x] **S0** — Factory scaffold; packages + app build green. *(2026-07-19)*
- [ ] **S1** — Workspace shell: sidebar, bookmarks, persistence, relink.
- [ ] **S2** — Engine seam + fixture analysis + progress UI.
      *Interface checkpoint with E1.*
- [ ] **S3** — Outline + inspector + search.
- [ ] **S4** — Flat Canvas graph view + LayoutEngine.
- [ ] **S5** — RealityKit 3D. Perf gate: 60 fps @ 2k nodes / 6k edges.
- [ ] **S6** — Real-engine integration, dogfood, first tagged build.
