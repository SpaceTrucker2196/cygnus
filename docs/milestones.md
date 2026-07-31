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
      revision diff query, no-op-revision suppression *(2026-07-19)*;
      derived import rollups (`ImportRollupDeriver`: per-directory
      `core:dependsOn` module aggregates with counts + observation
      provenance, run as its own revision inside `index`); rename
      detection (exact blob-match + fuzzy same-filename, one-to-one
      unambiguous only; `core:renamedFrom` breadcrumb on the moved
      entity); IndexStoreDB spiked, audited, and **adopted**
      (`CygnusExtractorIndex.IndexStoreReader`, pinned
      swift-6.3.3-RELEASE; smoke resolves real references on
      cygnus's own store) *(2026-07-24)*. **E6 complete.** Next
      engine order: occurrence observations → derived reference
      edges.

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
- [x] **S6** — Polish. Needs-relink flow, Settings scene,
      constellation app icon *(2026-07-19)*; 5 GB memory governor +
      engine hard abort + live meter; Flat-view spatial grouping
      (area/layer/pattern regions); owner GUI sweep (blue tests
      treatment, inspector code pane, workspace-cache crash fix);
      **v0.1.0 tagged** *(2026-07-24)*.
- [~] **S7** — Dark-factory ops dashboard *(landed unplanned,
      2026-07-24)*: sections (Dashboard/Workflow/Issues/Docs),
      capability detection, ledger/metrics/commits/runs cards,
      fastlane screenshots + Fastlane settings card + Pages previews,
      DF_Template installer; portfolio overview (aggregate spend /
      issues + per-repo cards when no repo is selected); coverage
      halos with per-test attribution; issue actions (create
      production orders, comment, close/reopen via `gh`). Remaining
      candidate: converge triggering from the app.
- [~] **S8** — Visualization from *Kill It With Fire* (plan:
      `docs/wiki/visualization-ideas.md`). Done: scoped lenses —
      depth-limited focus, shortest-path tracing, naming-vs-structure
      conflicts; revision deltas on the graph and metric trends over
      revisions *(2026-07-31)*. Remaining: overgrowth (build/CI files
      as graph nodes), ownership + responsibility gaps as engine
      facts.

## Research

- [ ] **R1** — **morpho** (`SpaceTrucker2196/morpho`, MorphoHDL):
      evaluate for cygnus's layout and rendering. Not a code-graph
      tool — an HDL that grows circuits by recursive graph rewriting —
      but it solves *our* hardest rendering problems at a scale we
      have not reached. Upstream is Google's Apache-2.0 MorphoHDL
      (JS/WASM/C); the fork is described as "Swift Port", so the
      porting question below may already be answered there.

      What is actually worth taking, in order of value:

      - `graphs_engine/src/main.c` — a **Barnes–Hut** N-body layout:
        Morton-code (Z-order) sort into an implicit octree, SIMD
        (`f32x4`) force accumulation, struct-of-arrays buffers,
        tunable `theta`, 3D (x/y/z), 65,536 points. This is exactly
        the "Deferred: Barnes–Hut for >2k-node scenes" note left in
        **S4**. Our `LayoutEngine` uses grid-bucketed repulsion with a
        cutoff radius — near-linear but approximate in a different
        way, and it drops long-range structure that Barnes–Hut keeps.
      - **Struct-of-arrays layout** as a discipline. Morpho's compiler
        and layout engine are both SoA for cache locality; our layout
        frames are arrays of structs. This is the same lesson the
        Metal work already learned the hard way about buffer uploads.
      - `hex_layout.js` — deterministic grid placement, a candidate
        for stable "software cartography" positions that survive
        re-analysis better than force layout alone.
      - The **recursive growth** model: cells rewritten into subcells
        with widths inferred rather than fixed. Cygnus has the same
        shape in containment (repo → directory → file → declaration)
        and currently flattens it. Worth asking whether the graph
        should be *grown* at a level of detail rather than projected
        whole — which is also the answer to the book's complaint about
        whole-graph rendering.
      - Signal propagation visualization, as prior art for animating
        flow along edges — we already animate a build through the CI
        flow, and dependency/blast-radius propagation is the same
        idiom.

      Constraints to settle before adopting anything: it is Apache 2.0
      with Google LLC copyright and an explicit "not an officially
      supported Google product" disclaimer, and the runtime is
      JS/WASM/C. Taking the C engine directly means a new external
      dependency and a **MISSION.md audit recorded in `PROGRESS.md`**;
      porting the algorithm to Swift instead means no dependency and
      no WASM in the app. Default to the port — `LayoutEngine` is
      pure Swift and hermetically tested, and Barnes–Hut is ~200
      lines of it.

      Output: a spike doc under `docs/spikes/` with a measured
      comparison against the current layout on a real repo (frame
      time and layout quality at 2k, 10k, 25k nodes), then a decision
      recorded either way.
