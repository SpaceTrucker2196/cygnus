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
- E2–E5 complete (28 tests green): CAS + LocalFS provider + manifest
  diff; SwiftSyntax extractor (decls/imports/nesting, extensions);
  tree-sitter python/c extractors (query-driven, ancestor-walk decl
  paths); Resolver (observations → assertions with provenance);
  `CygnusWorkspace` facade with parallel extraction and incremental
  indexing; projections (contains tree, dependency graph,
  neighborhood); CLI register/repos/index/query/revisions.
  Dogfood: GRDB cold index 3.4 s (2,920 files, 23.8k entities,
  38.8k edges), incremental no-op 0.6 s. Fixed en route: extension
  members attach to deepest existing ancestor (unknownEntity crash on
  GRDB); failed runs can't poison the diff baseline (revisions now
  reference their snapshot; baseline = last committed snapshot).
  Engine is ready for the UI (S-milestones).
- S1–S3 complete: CygnusKit wired to the real engine
  (`WorkspaceGraphEngine` adapter: register → index → snapshot
  projection), `WorkspaceStore` state machine, security-scoped
  bookmarks via `RepoAccess.withAccess`, workspace.json registry,
  `SnapshotIndex` (tree/adjacency/search built once per snapshot).
  App: repo sidebar (NSOpenPanel add, context menu), analysis
  progress with cancel, containment outline, entity inspector with
  clickable edges, ⌘F search. All three suites green; adapter e2e
  test runs the real engine on a fixture repo. First manual GUI run
  still pending (needs a human to pick a folder in the open panel).
  Next: S4 Flat Canvas graph view + LayoutEngine, then S5 RealityKit.
- S4 complete: `GraphScene` (dependency projection, degree),
  `LayoutEngine` (seeded deterministic Fruchterman–Reingold,
  progressive AsyncStream frames, cancellable, detached off main),
  `FlatGraphView` Canvas renderer (fit-to-bounds transform, zoom/pan,
  double-click reset, nearest-node selection synced with inspector,
  degree-sized nodes, adaptive labels), Outline|Graph toolbar picker.
  8 kit tests green incl. layout determinism.
- S5 complete: `Layout3D` (deterministic FR on a jittered sphere
  spiral, solved off-main), `SpaceGraphView`/`SpaceRenderView`
  (RealityView, PerspectiveCamera arcball with drag orbit + magnify
  zoom, selection highlight entity), `GraphSceneBuilder` (shared
  sphere mesh + per-kind UnlitMaterial → auto-instanced nodes;
  ALL edges baked into one prism mesh entity — never one entity per
  edge; InputTarget+Collision for tap picking). Outline|Flat|3D
  picker. App tests build the RealityKit scene and assert the
  one-edge-entity invariant. Deferred: manual 60 fps gate check,
  progressive 3D animation, LowLevelMesh dynamic edges.
- E6 partial: `cygnus verify` (cold rebuild vs incremental,
  test-proven clean after edit/add/delete), `store.diff(from:to:)` +
  `cygnus diff`, FSEvents `cygnus watch` (verified live: one revision
  per debounced change), no-op indexes no longer mint revisions.
- S6 partial: stale-bookmark → needs-relink state with Locate Folder
  flow, Settings scene (engine data location, version, on-device
  note), generated Cygnus-constellation app icon
  (tools/make_icon.swift → Assets.xcassets; black/white/HAL-red).
  Remaining for S6: Jeff's manual GUI run + 60 fps gate, then first
  tagged build. E6 remaining: derived-layer rollups, fuzzy renames,
  IndexStoreDB spike.

## 2026-07-20

- First real GUI run (Jeff): analysis + Flat view worked on an 846-
  node repo. Feedback fixed same day: system/external modules no
  longer charted (SystemModules lists + internal-by-directory-name
  detection, Filters toggle for third-party), per-area color coding
  with legend, zoom/label-size/label-mode control bar on both graph
  views.
- **RealityKit renderer parked.** RealityView GPU init crashed
  (EXC_BREAKPOINT in CoreRE PerFrameAllocatorGPUManager::init) on
  2026-07-19 and kernel-wedged an app process (unkillable, state SX)
  on 2026-07-20 on this machine. 3D mode is now `Orbit3DView`: the
  Layout3D solution perspective-projected onto the Canvas renderer
  (orbit/zoom/select, painter's order, depth attenuation).
  `SpaceGraphView`/`GraphSceneBuilder` remain in-tree for when the
  GPU issue is understood; do not re-enable without testing on a
  fresh boot.
- "Wouldn't load a repo" follow-up: RepoLoadingTests now drive the
  full add→bookmark→persist→analyze→relaunch→move/delete→relink path
  with the real engine. Caught + fixed: snapshots mixed all workspace
  repos (now scoped per repo); addRepository swallowed bookmark
  failures silently (now a visible failed state). Learned: bookmarks
  follow folder moves; only deletion needs relink. Operational note:
  launch the app via LaunchServices (`open`, Finder, Xcode) — a
  binary launched directly from a terminal can fail scoped-bookmark
  creation; and a kernel-wedged instance makes plain `open` time out
  (-1712) until reboot; `open -n` works around it.
- UI tests added (CygnusUITests: seeded repo → ready → all view
  modes → search → inspector). Findings from the hunt: the
  "unkillable" pid was suspended under Xcode's debugger (kill its
  debugserver to release); App-init side effects suppressed window
  creation (seeding moved to post-launch .task; WindowGroup now
  defaultLaunchBehavior(.presented) + restorationBehavior(.disabled));
  direct binary exec gets NO window on this OS — always launch via
  LaunchServices; XCUITest in this login session sees an empty AX
  tree (environment degradation — likely same session damage as the
  RealityKit incident). Validated live instead: seeded repo green-
  check + a real repo added through the panel and scanning. Rerun
  `make test` after reboot to confirm UI tests pass in a clean
  session.
