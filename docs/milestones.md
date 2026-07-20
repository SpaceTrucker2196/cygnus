# cygnus — milestones

Engine (E) is the critical path; shell (S) runs in parallel against
`FixtureGraphEngine`. Sizes: S ≤ 1 session, M = 1–2, L = 2–4.

## Engine

- [ ] **E0** — Scaffold + de-risk spikes: tree-sitter under Swift 6;
      GRDB interval-schema 1M-row benchmark. *(scaffold done 2026-07-19;
      spikes open)*
- [ ] **E1** — Graph model + store: schema, revision transactions,
      provenance links, property-based append-only/isolation tests.
- [ ] **E2** — Providers: discovery, LocalFS + git, CAS, manifest diff,
      `cygnus register`.
- [ ] **E3** — Pipeline + Swift extractor + entity resolution;
      `cygnus index` on a real repo.
- [ ] **E4** — Python/C extractors + derivers (contains, imports,
      metrics) with provenance-driven invalidation.
- [ ] **E5** — Incremental watch + full query surface + perf pass.
- [ ] **E6** — Hardening: fuzzy renames, IndexStoreDB spike.

## Shell

- [x] **S0** — Factory scaffold; packages + app build green. *(2026-07-19)*
- [ ] **S1** — Workspace shell: sidebar, bookmarks, persistence, relink.
- [ ] **S2** — Engine seam + fixture analysis + progress UI.
      *Interface checkpoint with E1.*
- [ ] **S3** — Outline + inspector + search.
- [ ] **S4** — Flat Canvas graph view + LayoutEngine.
- [ ] **S5** — RealityKit 3D. Perf gate: 60 fps @ 2k nodes / 6k edges.
- [ ] **S6** — Real-engine integration, dogfood, first tagged build.
