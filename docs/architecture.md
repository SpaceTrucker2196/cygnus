# Cygnus — 3D Repository Visualization (Plan of Record)

## Context

Jeff shared a ChatGPT spec ("3D GitHub Repo Visualization") defining **Cygnus**: a tool that models a software *system* — not its files — as a **Knowledge Graph** built from repository evidence, rendered in 3D. The shared spec covers: (1) **Repository Model** — repos are raw evidence with stable IDs, immutable snapshots, Providers exposing facts only, an observation pipeline of atomic literal facts, incremental change detection, multi-repo Workspaces; (2) **Knowledge Graph** — canonical model of Entities / Relationships / typed Properties, three knowledge layers (Observed / Derived / Inferred) with full provenance, immutable revisions, visualizations as disposable projections; (3) **Entity System** — language-neutral vocabulary, physical vs logical entities separated, stable identity surviving refactors, plugin extensibility via namespaces.

**Decisions (Jeff, 2026-07-19):** native macOS Swift · graph-engine-first MVP · analyzers for **Swift, Python, C** · a real **river.io product** (factory conventions apply).

**Location:** `~/projects/cygnus/` — an empty lowercase dir already exists; APFS is case-insensitive, so use it as-is. Toolchain: Swift 6.3.3 / Xcode 26.6, Swift 6 language mode, strict concurrency `complete`, warnings-as-errors.

## Repo layout (one repo, two packages + app)

```
cygnus/
├── AGENTS.md (canonical) · CLAUDE.md (stub @AGENTS.md) · LEDGER.md · MISSION.md · FACTORY.md · PROGRESS.md · README.md · Makefile
├── project.yml                  # xcodegen authoritative; Cygnus.xcodeproj gitignored; io.river.cygnus; macOS 15+
├── CygnusCore/                  # THE ENGINE — SPM package, the product for the first phases
│   ├── Package.swift            # deps: GRDB.swift, swift-syntax, SwiftTreeSitter + tree-sitter-python/c (pinned)
│   ├── Sources/
│   │   ├── CygnusGraph/         # pure model: Entity, Relationship, PropertyBag, Provenance, Revision, GraphStore protocol (depends on nothing)
│   │   ├── CygnusStore/         # GRDB/SQLite impl (only target importing GRDB)
│   │   ├── CygnusProviders/     # RepositoryProvider protocol, discovery markers, LocalFS + Git providers, snapshot CAS
│   │   ├── CygnusObservation/   # Observation types, ObservationExtractor protocol, pipeline orchestration, incremental scoping
│   │   ├── CygnusExtractorSwift/  CygnusExtractorTS/   # SwiftSyntax; tree-sitter (Python, C)
│   │   ├── CygnusDerive/        # Deriver protocol + derived-layer passes (reads graph, writes derived facts only)
│   │   ├── CygnusQuery/         # subgraph fetch, projections, FTS search, diff, live observation
│   │   ├── CygnusEngine/        # facade API the app + CLI consume
│   │   └── cygnus/              # CLI harness: register / index / query / watch / verify
│   └── Tests/ (…Tests per target, Fixtures/ tiny sample repos: swift/ python/ c/)
├── Package.swift                # CygnusKit — app-side headless adapter package
├── Sources/CygnusKit/           # WorkspaceStore, AnalysisCoordinator, GraphSnapshot, GraphEngine protocol + FixtureGraphEngine, RepoAccessManager, LayoutEngine, workspace persistence
├── Tests/CygnusKitTests/        # hermetic, `swift test`, no Xcode
├── App/                         # SwiftUI app: Views/, Rendering/ (GraphRendererView seam, Canvas2DRenderer, RealityKitRenderer, ArcballCamera, EdgeMeshBuilder), entitlements, app tests
└── docs/ (architecture.md, schema.md, milestones.md, views/)
```

Dependency rules (enforced via target deps): CygnusGraph depends on nothing; extractors emit observations and never touch the store (spec's facts-vs-interpretation boundary made physical); CygnusDerive cannot import extractors/providers; app depends only on CygnusKit; CygnusKit depends on CygnusEngine. Until the engine lands, CygnusKit compiles standalone against its `GraphEngine` protocol + `FixtureGraphEngine` — repo green from first commit.

## Part A — Graph Engine (CygnusCore)

### Storage: SQLite via GRDB — single DB per workspace, WAL, interval-versioned schema
- Rejected: in-memory+Codable (dies at 10⁵–10⁶ observations, no partial load); custom append-only store (months rebuilding crash-safety/indexes/query); raw SQLite (GRDB adds Codable records, DatabaseMigrator, `ValueObservation` for live UI queries, WAL pooling — near-zero cost).
- **Immutable revisions relationally:** every fact row carries `valid_from`/`valid_to` revision interval; rows never mutate except closing `valid_to`. Revision commit = one transaction. "Graph at R" vs "current" = same query, different interval predicate. O(delta) per revision.
- DB at `~/Library/Application Support/Cygnus/workspaces/<id>/`; snapshot file contents in a content-addressed store (`cas/ab/cdef…`) beside the DB (dedup across revisions free, provenance anchored to blob hashes). FTS5 for symbol search.
- Schema (GRDB migrations): `repositories, snapshots, snapshot_files, revisions, entities(stable_key UNIQUE), entity_versions(interval), relationships(kind, layer, interval), observations(snapshot, blob, range, payload, extractor+version), provenance(fact→observation), entity_names_fts`. Partial indexes on `valid_to IS NULL` hot path.

### Data model
- Two-level identity: `EntityID` (DB surrogate) + `StableKey` (deterministic human-readable, e.g. `swift:type:<repo>/<module>.HTTPClient#<sig-hash>`; files are `phys:file:<repo>/<path>`). Swift StableKeys mirror USR structure so IndexStoreDB can later *merge* identities via an alias column.
- `EntityKind`/`RelationshipKind` are namespaced-string structs (`core:function`, `swift:actor`), **not enums** — the plugin-extensibility requirement. Three knowledge layers are a column on facts, not separate stores.
- `PropertyBag` = typed `[String: PropertyValue]` enum values, Codable to canonical JSON; extension properties namespaced.
- **Rename/move survival (tiered):** MVP ships tier 1 (exact blob-hash moves, provably correct) + tier 2 (git rename hints). Tier 3 fuzzy structural matching deferred to Phase 7 behind a confidence threshold, provenance-recorded, never across repos.

### Parsing
- **Swift: SwiftSyntax** — no build required, works on non-compiling checkouts (essential for arbitrary repos). Declarations, nesting, imports, extensions, signatures. **IndexStoreDB deferred** as an additive enricher (USRs, resolved refs, real call graph) when an index store exists. SourceKit-LSP rejected (interactive-editing tool, wrong shape for batch).
- **Python + C: tree-sitter via SwiftTreeSitter** — error-tolerant, one host runtime, declarative `.scm` queries per language (new language ≈ grammar + query file + vocabulary map). Pin grammar versions exactly (ABI churn is the known papercut); Phase-0 spike verifies Swift 6 strict-concurrency build.
- Common seam: `ObservationExtractor` protocol — per-file, pure, `Sendable`, parallelized via TaskGroup. Cross-file work (import resolution, linking) lives in resolution/derivation, keeping the observed layer honest.

### Pipeline
- **Snapshots:** manifest `path → SHA-256` + CAS blobs. LocalFS provider walks (gitignore-aware); Git provider snapshots a ref without touching the working tree (`ls-tree`/`cat-file`, OID→CAS) and reports rename hints/commit metadata as facts.
- **Incremental:** triggers = FSEvents (debounced ~500ms) / explicit / `git diff --name-status` fast-path; **authoritative diff is always manifest-vs-manifest** — missed events can't corrupt the graph. Scoped re-analysis: close intervals for the file's facts → re-extract → re-resolve affected entities → invalidate derived facts via the provenance table (provenance IS the invalidation index) → re-derive scoped (or whole-repo for derivers that can't scope — correct by brute force). One revision transaction. `cygnus verify` recomputes from scratch and diffs against incremental in CI.

### Derived layer MVP (in order)
1. **Contains hierarchy** (repo→dir→file→type→member; `core:containsPhysical` vs `core:declares` — physical/logical separation honored)
2. **Import/dependency graph** (file→module + module→module rollup; heuristic resolution carries confidence properties)
3. **Metrics as properties** (fan-in/out, LOC — gives 3D node sizing)
4. Call graph deferred — syntactic name-matching is noisy; real one comes with IndexStoreDB later.

### Query surface MVP (what the viewer needs, no query language yet)
`entity(stableKey:/id:)` · `search(name:)` (FTS5) · `neighborhood(of:kinds:direction:depth:limit:) -> Subgraph` · `containsTree(root:depth:)` · `dependencyGraph(scope:granularity:)` · `provenance(of:) -> ProvenanceChain` (inspector "why" panel — keeps provenance honest) · `diff(from:to:)` (cheap via intervals) · `observeSubgraph` (GRDB ValueObservation → live viewer updates).

## Part B — macOS App Shell

### Architecture
- **Single-window `NavigationSplitView`** workspace app (not document-based — data is derived, repos are folders; matches Xcode/Fork/Tower genre). Sidebar = repos + revisions; content = graph/analysis; `.inspector()` = entity inspector. `WindowGroup(for: RepoID.self)` escape hatch for multi-window later.
- **CygnusKit** (headless, hermetic tests): `WorkspaceStore` (`@MainActor @Observable` single source of truth), `AnalysisCoordinator` (actor owning engine; one cancellable analysis Task per repo; `AsyncThrowingStream<AnalysisEvent>` — phase/progress/counts/finished), `GraphSnapshot` (immutable `Sendable` render-ready projection: nodes, edges, adjacency — **renderers/inspector never touch live engine objects**), `GraphEngine` protocol + `FixtureGraphEngine` (shell demos on fixtures from day one; real engine = one-file conformance).

### Rendering
- **RealityKit** for 3D (SceneKit soft-deprecated — ban it in AGENTS.md). Ship a **2D SwiftUI Canvas "Flat" force-directed view first** (kept permanently as a mode). Nodes: instanced shared mesh+material per kind. Edges: **never one entity per edge** — batch per kind into a single `LowLevelMesh`. Hand-rolled arcball camera (~1 day). Picking via `RealityView` hit-testing.
- Layout in a renderer-agnostic `LayoutEngine` actor: Barnes-Hut (octree) with iteration budget + cooling, seeded by contains-tree radial/layered placement, cancellable/progressive.
- **Upgrade path:** `GraphRendererView` seam shared by both renderers; >5–10k nodes → LowLevelMesh impostors → MTKView renderer behind same seam. **Perf gate: 60fps at 2k nodes / 6k edges on Apple Silicon.**

### Screens
Sidebar (repos, status glyphs, NSOpenPanel add, re-analyze/remove/relink) · Analysis status (phase, progress, live counters, cancel/retry) · Graph view (Flat/3D + Dependencies/Contains pickers, kind filters, select/hover/focus) · Entity inspector (attributes, clickable in/out relationships for graph-walking, provenance chain, Reveal in Finder) · Search (⌘F over snapshot labels) · Outline view (contains-tree `OutlineGroup` — reliable non-3D path, selection synced).

### Sandboxing & persistence
Sandboxed, `files.user-selected.read-only`, **no network entitlement v1**. `RepoAccessManager`: NSOpenPanel → security-scoped bookmark → persist; stale-refresh; `withRepoAccess { }` balanced helper **active for the duration of engine analysis**; relink UX. Registered repos in versioned JSON `workspace.json`; graph data owned by CygnusCore; UI state via @AppStorage/@SceneStorage.

## Milestones

Engine is the critical path; shell runs in parallel on fixtures. (S ≤ 1 session, M = 1–2, L = 2–4.)

**Engine:** **E0** Scaffold + de-risk spikes — tree-sitter under Swift 6, GRDB interval-schema 1M-row benchmark (2–3 sessions) → **E1** Graph model + store, revision transactions, property-based append-only/isolation tests (3–4) → **E2** Providers, discovery, CAS, manifest diff, git provider, `cygnus register` (3) → **E3** Pipeline + Swift extractor + entity resolution; `cygnus index` on a real repo (e.g. GRDB itself) (4–5) → **E4** Python/C extractors + derivers with provenance invalidation (3–4) → **E5** Incremental watch + full query surface; perf pass (seconds-scale incremental commit, low-minutes cold index @ 5k files) (3) → **E6** Hardening/stretch: fuzzy renames, IndexStoreDB spike (2+).

**Shell (parallel from E0):** **S0** Factory scaffold, project.yml, empty app builds, `make test` green (S) → **S1** Workspace shell: sidebar, bookmarks, persistence, relink (M) → **S2** Engine seam + fixture analysis + progress UI — *interface checkpoint with engine at E1* (M) → **S3** Outline + inspector + search (useful browser already) (M) → **S4** Flat Canvas graph view + LayoutEngine (M) → **S5** RealityKit 3D, perf gate (L) → **S6** Real-engine integration + dogfood + first tagged build (M).

Total ≈ 23–28 engine sessions + 8–10 shell sessions with heavy parallelism.

## Hardest problems & mitigations
1. **Stable identity across renames** — tiered resolution (exact-hash → git hints → deferred fuzzy w/ confidence + provenance, never cross-repo); measure miss rate on real history before enabling tier 3.
2. **Incremental invalidation correctness** — provenance table as single invalidation index; unscopeable derivers re-run whole-repo; `cygnus verify` in CI.
3. **Syntax-only semantic poverty** — confidence + layer first-class and visible in UI; observation model designed so IndexStoreDB upgrades edges additively; MVP features (contains/imports/metrics) chosen to be truthful at syntax level.
4. RealityKit scaling / layout hairballs / grammar ABI churn / sandbox-scope-on-engine-thread — covered by renderer seam + batched meshes, Barnes-Hut + tree seeding, pinned grammars + Phase-0 spike, `withRepoAccess` helper.

## Verification
- Every milestone: `make test` green (CygnusCore `swift test`, CygnusKit hermetic tests, app tests via xcodebuild).
- E1: property-based tests — append-only invariants, revision isolation ("query at R never sees R+1").
- E3+: `cygnus index` a real third-party repo; `cygnus query contains/deps` output sanity-checked.
- E4/E5: mixed-language fixture workspace; incremental edit → assert only scoped facts regenerated; `cygnus verify` (scratch-vs-incremental diff) in CI on fixtures.
- E5: perf targets — incremental commit ≤ seconds, cold index low-minutes on 5k-file repo.
- S5: 60fps interaction at 2k-node perf fixture.
- S6 dogfood: analyze the cygnus repo itself + sloth-ios end-to-end in the real sandboxed app; verify counts, selection sync, provenance panel.
- Factory: LEDGER.md row appended per substantive commit (start billable sessions inside the repo, not ~/projects).
