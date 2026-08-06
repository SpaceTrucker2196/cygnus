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

## 2026-07-24 — Dark-factory ops dashboard

- Repurposed cygnus into a general **dark-factory ops dashboard** (works
  on any repo; sloth is the first example). Verified end-to-end in the
  real GUI against `~/projects/sloth`: Dashboard shows 4 open / 31 closed
  issues (2 production-orders), latest CI "Passed", converge metrics,
  $4,834.99 token spend with sparkline, and recent ships with `closes #N`
  links — all from live `git`/`gh` + local files.
- **Sandbox dropped** (App/Cygnus.entitlements + project.yml): the app
  now shells out to the user's authenticated `git`/`gh`. Forfeits App
  Store distribution — fine for an internal ops tool.
- **CygnusKit additions**: FactoryTooling/ToolLocator/ProcessTooling
  (absolute-path resolution — a GUI app's PATH omits /opt/homebrew/bin;
  concurrent pipe drain; timeout; prompts disabled). FactoryModel value
  types + DocParsers/MarkdownDocument/WikiLink (pure). FactoryProvider/
  GitHubFactoryProvider + FactoryDocsProvider/FileDocsProvider (atomic
  write, policy guards: LEDGER read-only, METRICS append-only, no new
  root files, no path escape; optional named `git add` + commit, no
  push). WorkspaceStore gains per-repo FactoryState/Loadable + on-demand
  loaders mirroring analyze/apply/tasks.
- **Views**: RepoDetailView is now a section dispatcher (Dashboard /
  Workflow / Issues / Docs / Code Graph); the original graph moved to
  CodeGraphContainerView. Workflow diagrams are native SwiftUI (converge
  stage diagram + CI list), not the force-directed Canvas. Docs editor
  has edit/preview/split, three-state checklist round-trip, atomic save,
  optional commit. Markdown rendered on built-in AttributedString (no new
  dep). Auto-select first repo on launch (dashboard, not blank).
- **Post-sandbox resolution**: pathHint is now authoritative, bookmark a
  fallback for moved folders — also cut a pre-existing relaunch-test
  flake (~50% → ~12%). The residual RepoLoadingTests flake is a GRDB
  shared-directory race under parallel contention (passes in isolation),
  tracked alongside the known UI-test AX-tree issue.
- Tests: 64 CygnusKit + 30 CygnusCore + app unit tests green; a gated
  `EndToEndSlothTests` exercises the real stack against live sloth
  (`CYGNUS_E2E_SLOTH=1 swift test --filter EndToEndSlothTests`).

## 2026-07-24

- Removed 3D rendering. Both 3D paths (the parked RealityKit
  `SpaceGraphView`/`GraphSceneBuilder` and the active Canvas-projected
  `Orbit3DView`) and the `Layout3D` force-layout solver cost too much
  memory and time to render; deleted along with their tests
  (`SpaceSceneTests`, `Layout3DTests`). `ViewMode` is now Outline +
  Flat only; `DependencyGraphView` always renders `FlatGraphView`. The
  permanent 2D Flat renderer and its shared palette/legend/control-bar
  are untouched. CygnusCore + CygnusKit `swift test` green, warning-
  clean build. (UI test still blocked by this session's empty-AX-tree
  degradation — unrelated.)

## 2026-07-24 — memory ceiling, graph grouping, factory installer

- 5 GB hard memory ceiling after an OOM machine crash. Root causes:
  unbounded per-file extraction task group (N cores × full syntax
  trees) and the partial-snapshot builder retaining a second copy of
  all observations. Now: `IndexLimits` sliding window (≤ min(cores,6)
  concurrent parses, serializes past a 3.5 GB soft brake),
  `MemoryGovernor` (phys_footprint sampling; analyze refuses at cap,
  previews shed at 85%, sidebar meter), preview builder freezes past
  4k files. Throttle-and-shed by design — no setrlimit (fights
  RealityKit/Metal mappings). Verified: sloth full index 41 MB peak
  (CLI) / 287 MB (app), 137 MB settled. Env knobs:
  `CYGNUS_MEMORY_LIMIT_MB`, `CYGNUS_SOFT_MEMORY_MB`,
  `CYGNUS_MAX_EXTRACT_CONCURRENCY`.
- Flat view spatial grouping (`docs/views/flat-graph.md`): Area /
  Layer (Production–Tests–Modules) / Pattern (MVVM-MVC naming roles;
  convention reading, not inference — real detection is derived-layer
  work) / None. Deterministic ring anchors per cluster name keep
  spatial memory across re-analyses; padded convex-hull tinted
  regions; tests pinned gray, modules purple.
- `~/projects/DF_Template` created (own repo): bare dark-factory
  skeleton from the sloth survey, FIRST_RUN.md adaptation drill for
  insert-into-existing and fresh modes; uses the canonical 9-column
  ledger header ledger.py actually emits. App gained
  `FactoryInstaller` + Install Factory button (additive, never
  overwrites, reinstall no-op) shown when a repo lacks LEDGER.md.
- Dashboard previews: fastlane screenshot strip (ImageIO-downsampled
  thumbnails, capped 24) and Pages site as a 300-pt portrait
  letter-proportion thumbnail (renders at 800-pt viewport, scaled).
  Pages URL via `gh api …/pages`, `owner.github.io` fallback.
- Tests: 77 CygnusKit + 30 CygnusCore + app unit green. UI test
  runner still blocked by the automation-mode timeout (environment,
  pre-existing).
- **Root cause of the OOM crashes found and fixed** (the throttles
  above were necessary armor but not the disease): containment/
  declares edges form a DAG — the same declaration key is declared
  from several files (split originals + combined/generated copies,
  extensions) — and `SnapshotIndex.build` rebuilt every shared
  subtree once per path: exponential materialization, sampled live at
  25 GB and climbing, never returning. On the main actor that was
  also the launch-day beach ball. Fix: memoized build + cycle cut +
  duplicate-edge collapse. MeowPassword full-pipeline: stuck-forever
  → ready in 3.4 s / 65 MB peak; live multi-repo re-analysis peaks
  486 MB. En route: engine hard abort (4.5 GB, walk + extract),
  store cancels running analysis at the cap, walk excludes `build//
  SourcePackages/`, detached coalescing event pump (a plain Task in
  a @MainActor type inherits the main actor — the event loop was on
  the UI thread), and **no task spawning during App.init** (window
  suppression, again). Gated stress test:
  `CYGNUS_STRESS_REPO=<path> swift test --filter MemoryStressTests`.
  Debug lesson: `sample <pid>` on the runaway named the exact frame;
  theory kept pointing at the wrong layer.

## 2026-07-24 — v0.1.0, E6 close, crash root cause

- **v0.1.0 tagged** (S6 complete): all suites + Debug/Release
  warning-clean at tag time; notes in `docs/releases/v0.1.0.md`.
- E6 essentially complete: derived import rollups
  (`ImportRollupDeriver`), rename detection (exact blob + fuzzy
  same-filename, `core:renamedFrom` breadcrumb, `↷N` in notes),
  IndexStoreDB paper spike (`docs/spikes/indexstoredb.md` — adopt as
  optional provider, **owner dependency audit pending**).
- Sweep features: tests draw blue in the Flat view (nodes, edges,
  stronger cloud); inspector gained a source-code pane (anchor line
  highlighted, 512 KB cap); coverage-halo mode (llvm-cov artifact →
  per-node ring, default on; `make test` now always writes coverage);
  Fastlane detail card (lanes + Appfile + CI invocations).
- **App crash saga resolved.** Four identical SIGSEGVs in GRDB
  string binding. En route, two real bugs fixed (one workspace/pool
  per directory — GRDB forbids two pools on one file; cooperative
  cancellation in index) but the crashes continued. Headless
  ASan/TSan harness (CYGNUS_STRESS_REPOS concurrent analyses) came
  back clean — because the harness never ran subprocess tooling. TSan
  on the **running app** caught it in every session: ProcessRunner
  assigned its timeout task outside the lock after process.run(),
  racing the termination handler of fast-exiting children (every
  errored gh call); the torn reference corrupted heap blocks that
  crashed later in unrelated GRDB binds. Fix: install-or-cancel under
  the lock. Verified by absence: zero TSan reports post-fix.
  Debug lesson repeated: instrument the real thing (TSan the GUI
  app), not just the harness that's convenient.

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

## 2026-08-03 — CI Flow is a projection

- The CI Flow chart is now built from the graph
  (`CIFlow.projected(from:)`) whenever the repo has a snapshot; the
  capability scan's file parse remains only for the pre-analysis
  window. Differential tests pin graph-vs-file identity on the real
  Makefiles (cygnus, otter, sloth) and on fastlane triggers.
- The expansion-versus-spelling decision (Jeff, 2026-08-03): entity
  identity stays the expanded name (`sloth`); the file's spelling
  (`$(TARGET)`) rides along as `core:buildTargetVerbatim` and labels
  the chart. Pattern rules (`%.o`) are recorded and flagged
  (`core:buildPattern`); `.PHONY` too (`core:buildPhony`).
- New evidence: `.github/workflows/*.yml` extracted
  (`core:ciInvocation` → `core:invokes` edge from workflow file to
  lane), which required letting `.github` through LocalFSProvider's
  hidden-entry filter — the workflows never reached the manifest at
  all before.
- Fixed en route: recipe attachment dropped verbatim/pattern flags on
  reconstruction; `MakefileRules.expand` resolved nested variables
  only when dictionary order cooperated (now a bounded deterministic
  fixpoint); step labels converge on expansion in both constructions
  (`sloth_test`, and unresolved `$(MAKE)` reads `MAKE`).

## 2026-08-05 — Phase 0 for the retrieval layer

Groundwork for a tiered retrieval surface (E7, planned): expose what
the graph already knows as agent tools. Three prerequisite defects,
each independently shippable.

- **`DeclarationLocator` lifted** out of `CygnusEngine/Workspace.swift`
  into `CygnusQuery`, public, with a `build(store:repository:at:)`
  factory. Reference enrichment used it to attribute a compiler
  occurrence to its enclosing symbol; retrieval needs the same map to
  attribute a search hit to a graph entity, which is what lets a
  result carry a stable key and a provenance chain instead of a bare
  file offset. No behaviour change.
- **N+1 removed from `Projections.neighborhood`.** It resolved one
  entity per discovered node *inside* the BFS edge loop; against the
  serialized `DatabaseQueue` a depth-2 walk off a hub symbol issued
  hundreds of blocking queries. Each level now resolves its endpoints
  in one `entities(ids:)` call, sorted by stable key so downstream
  truncation is deterministic.
- **`refersToSymbol` no longer conflates references with calls.**
  `IndexStoreReader` queried `roles: [.reference, .call]` and dropped
  the distinction, though `Occurrence` already computed `isCall`.
  `FileReference` now carries it, enrichment aggregates
  `core:callCount` beside `core:referenceCount`, and the retract
  identity string became `#count/calls`.

  Measured on cygnus itself: **1,547 symbol edges, of which 1,436
  (93%) have zero calls** — 2,360 cross-file reference occurrences
  against 141 calls. A `callers_of` built on the collapsed data would
  have been wrong the overwhelming majority of the time, which is the
  "faking semantic understanding" MISSION invariant 9 forbids. Edges
  written before this change carry no call count and read as `?`, so
  the first enrichment after it retracts and re-asserts every symbol
  edge exactly once — deliberate, and bounded by including the count
  in the identity string.

New `QueryTests` target (11 tests) — `CygnusQuery` had no test target
at all, which is how the N+1 survived.

**`make test` is red, and it was red before this work.**
`CygnusUITests.testLoadRepoBrowseAllViewModes` fails; verified by
stashing every change and reproducing at HEAD. The full AX tree under
XCUITest is `Application → MenuBar + TouchBar` with no window, so the
"seeded repo row missing" message is misleading — the window is
missing, not the row. Launched through LaunchServices with
`--uitest-seed-repo` the app creates a window and seeds correctly
(`engine/graph.sqlite` + CAS + `workspace.json` written). No crash
reports, no second instance, no stale saved state. This is the same
session degradation recorded on 2026-07-24 ("XCUITest in this login
session sees an empty AX tree"), whose recorded remedy is to re-run
`make test` after a reboot. Engine and kit suites are green (95 tests),
`cygnus verify` clean, build warning-clean.

Follow-ups not done here: `SQLiteGraphStore.entities(ids:)` builds an
unbounded `IN (?,…)` list (throws past SQLite's 32,766-variable cap —
loud, not silent; `containsTrees` already passes every entity, so the
exposure predates this), `core:isCall`/`core:callCount` want constants
in `PayloadKeys.swift`, and no test yet asserts `core:callCount`
reaches the edge or that the identity change churns each edge exactly
once and then stabilises.

## 2026-08-05 — Phase 1: lexical retrieval over CAS blobs

The engine could find a symbol by name and walk its edges, but had no
way to answer "where does this text appear" — FTS5 covered entity
names only, never source. That gap is closed, with no new dependency:
`Package.swift`'s `dependencies:` array is unchanged.

- **`v3-retrieval` migration.** `source_search` (FTS5, `body` +
  `body_split`, `tokenize = 'unicode61 tokenchars ''_$'''`),
  `source_indexed_blob` as the index ledger, and
  `idx_snapshot_files_blob` — that last one is load-bearing:
  `snapshot_files` is `WITHOUT ROWID` keyed `(snapshot_id, path)`, so
  every retrieval join scanned it end to end without an index on
  `blob_hash`. It would have shown up as inexplicably slow search
  rather than as a bug.
- **Everything keyed by blob hash, never path.** Unchanged, renamed
  and reverted files all cost zero; the same vendored file in two
  repos is indexed once. The incremental update is the set difference
  `manifest blobs − indexed blobs` and nothing else — stricter than
  `changedOrAdded`, because it also catches blobs a previous run
  failed on. `cygnus watch` needed no changes at all, which is the
  evidence the primitive was right.
- **Paths arrive at query time** via a `snapshot_files` join against
  each repo's newest committed snapshot. That join is the invalidation
  mechanism and it is stronger than a sweep: a blob that has left the
  tree cannot surface even before its rows are pruned. Staleness is
  impossible by construction. `pruneOrphanBlobs` reclaims space and
  never changes a result.
- **The split column.** `unicode61` makes `withThrowingTaskGroup` one
  token, so "task group" matched nothing. Every window is indexed
  twice — verbatim, and with identifiers broken at case/underscore/
  digit boundaries — weighted `bm25(source_search, 1.0, 0.4)` so exact
  still beats split. Measured on cygnus: **7 of 10 windows matching
  `Throwing`, and 8 matching `Deriver`, are reachable only through the
  split column.** Without it the tier finds only what you could
  already spell.
- **Citations are exact, not window-sized.** Windows are 60 lines with
  no overlap (overlap inflates the index and double-counts BM25); at
  query time the window is re-read from the CAS, the matching line
  located, and that line cited with two lines of context.
- **Two blobs that would have taken the indexer down**, both verified
  against this repo before writing the code: `LocalFSProvider` records
  files over its 4 MB cap with the hash of *empty* content and never
  stores the bytes, so it is in every manifest and absent from the CAS
  and reading it throws — skipped by identity, not discovered by
  crashing. And text-ness is decodability, not the language hint,
  which is nil for `.toml`, `.sh` and an extensionless `Makefile`.

Measured on cygnus: 230 files → 223 indexed blobs, 27,671 lines, 577
windows. Re-index of an unchanged tree writes zero rows. `cygnus
verify` clean — the retrieval pass mints no revision and asserts no
facts, and runs before enrichment so search freshness never waits on a
slow index-store read.

`cygnus search <text> [n]` added to the CLI. 23 new tests
(`RetrievalTests`); engine suite now 118. Design and the reasoning
behind the rejections (ripgrep, ANN indexes, overlap) in
`docs/wiki/retrieval.md`.

## 2026-08-06 — Phase 2: the structural entry points

Almost all of this was wrapping query methods that already existed and
were already tested but had no single-call entry point. The data was
there; the door wasn't.

- **`CygnusQuery/Lookups.swift`** — `definitions`, `references`,
  `callers`, `symbols(in:)`, `blastRadius`.
- **`CygnusQuery/Centrality.swift`** — weighted PageRank, ~70 lines,
  no dependencies, deterministic by construction (fixed iterations,
  sorted node order, dangling rank redistributed rather than leaked).
  It exists so that truncating an answer to a token budget drops the
  least important results instead of whichever the hash order
  surfaced.
- **`CygnusRetrieval/SpanReader.swift`** — reads a line range from the
  **snapshot**, not the working tree, because every line number cygnus
  produces refers to a blob in the CAS. When the file on disk no
  longer hashes to that blob the snapshot's text is returned *and the
  drift is reported*. Verified live: `span` on a file edited after
  indexing reports `[stale: working tree has drifted from this
  snapshot]`. Capped at 400 lines, and says when it capped.
- **`SQLiteGraphStore+Retrieval.swift`** — kind-filtered name search
  (the existing `searchNames` returns directories and modules too,
  which makes it wrong for "where is X defined"), exact-match ranking
  ahead of prefix, `currentBlob(forPath:)`, `resolvedEntities(anchoredIn:)`,
  and `hasCompilerReferences`.

**The rule the whole phase is built around: never return a confident
empty answer.** "Nothing calls this" and "this repository was never
built, so nothing can be known about what calls it" are different
facts, and a tool that collapses them will eventually talk an agent
into deleting live code. `ReferenceAnswer` therefore carries
`evidence: .compiler | .unavailable`, and the CLI prints "unknown —
this repository has no compiler-resolved symbol edges" rather than
"none". Two tests pin exactly this pair.

Phase 0's call/reference split pays off here for the first time.
Live on cygnus: `refs DeclarationLocator` returns the type reference in
`enrichReferences` (1 reference, 0 calls); `callers DeclarationLocator`
correctly returns none — and because the repo *has* compiler edges,
that "none" is a real answer rather than ignorance.

`cygnus def|refs|callers|radius|span` added. 21 new tests (139 engine,
184 kit). `cygnus verify` clean after re-index.
