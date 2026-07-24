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
- [~] **E6** — Hardening. Done: FSEvents watch, `cygnus verify`,
      revision diff query, no-op-revision suppression *(2026-07-19)*.
      Remaining: derived rollups, fuzzy renames, IndexStoreDB spike.

## Shell

- [x] **S0** — Factory scaffold; packages + app build green. *(2026-07-19)*
- [x] **S1** — Workspace shell: sidebar with add/remove/re-analyze,
      security-scoped bookmarks, workspace.json persistence.
      *Deferred: stale-bookmark relink UX.* *(2026-07-19)*
- [x] **S2** — Engine seam wired to the real engine
      (`WorkspaceGraphEngine` over `CygnusWorkspace`), analysis
      progress UI with cancel/retry. *(2026-07-19)*
- [x] **S3** — Outline (containment tree), entity inspector with
      clickable in/out edges, search. *(2026-07-19)*
- [x] **S4** — Flat Canvas graph view + LayoutEngine (deterministic
      Fruchterman–Reingold, progressive frames, zoom/pan/select;
      Outline|Graph picker). *Deferred: Barnes–Hut for >2k-node
      scenes.* *(2026-07-19)*
- [x] **S5** — RealityKit 3D: shipped 2026-07-19, then **removed
      2026-07-24** — both 3D paths cost too much memory/time to
      render (PROGRESS.md). The `GraphRendererView` seam stays; 3D
      returns only behind it, gated by a real perf budget.
- [~] **S6** — Polish. Done: needs-relink flow, Settings scene,
      constellation app icon *(2026-07-19)*; 5 GB memory governor +
      engine hard abort + live meter; Flat-view spatial grouping
      (area/layer/pattern regions) *(2026-07-24)*. Remaining: manual
      GUI sweep (human), first tagged build.
- [~] **S7** — Dark-factory ops dashboard *(landed unplanned,
      2026-07-24)*: sections (Dashboard/Workflow/Issues/Docs),
      capability detection, ledger/metrics/commits/runs cards,
      fastlane screenshots + Pages previews, DF_Template installer.
      Remaining scope is the owner's call — candidates: issue actions
      from the app, converge triggering, multi-repo rollup view.
