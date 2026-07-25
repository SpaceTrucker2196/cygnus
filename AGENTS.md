# cygnus — agent instructions

Repo-local rules for any coding agent (Claude Code, Copilot, Codex).
Build/infra runbook lives in `FACTORY.md`; charter in `MISSION.md`;
roadmap in `docs/milestones.md`; plan of record in `docs/architecture.md`.

## What cygnus is

A native macOS app (river.io) that models a software system — not its
files — as a **Knowledge Graph** built from repository evidence, and
renders it in 3D. Two products in one repo:

- **CygnusCore** — the graph engine. Repositories are raw evidence;
  Providers expose observable facts; an observation pipeline emits
  atomic literal facts; the graph holds Entities / Relationships /
  typed Properties across three knowledge layers (observed / derived /
  inferred) with full provenance and immutable revisions.
- **The app** — a SwiftUI shell + renderers. Every visualization is a
  disposable projection of the graph, never a second model.

## Architecture

- `CygnusCore/` — SPM package, the engine. Target dependency rules are
  load-bearing:
  - `CygnusGraph` depends on nothing (pure model + `GraphStore`
    protocol). Everyone depends on it.
  - `CygnusStore` is the **only** target that imports GRDB.
  - Extractors (`CygnusExtractorSwift`, `CygnusExtractorTS`) emit
    observations and never touch the store. Facts, not interpretation.
  - `CygnusDerive` reads the graph, writes derived-layer facts only.
    It cannot import extractors or providers.
  - `CygnusEngine` is the facade; the CLI (`cygnus`) and the app-side
    `CygnusKit` import only it.
- `Sources/CygnusKit/` — app-side headless adapter package (root
  `Package.swift`): `WorkspaceStore`, `AnalysisCoordinator`,
  `GraphSnapshot`, `GraphEngine` protocol + `FixtureGraphEngine`,
  `RepoAccessManager`, `LayoutEngine`. Hermetic tests, `swift test`,
  no Xcode required.
- `App/` — SwiftUI macOS app. Imports `CygnusKit` only. Generated into
  `Cygnus.xcodeproj` from `project.yml` via `xcodegen`.
- `docs/views/<name>.md` — per-view UI specs.

## Sacred invariants (from MISSION.md — do not cross)

- Rows in the graph store are **append-only**: never mutated except to
  close a `valid_to` revision interval. A revision commit is one
  transaction.
- Every derived or inferred fact carries provenance links to the
  observations that support it. The provenance table is the
  invalidation index — facts die with their observations.
- Observations are literal. "File A imports module B" is an
  observation; "this is the auth service" is not.
- Renderers and the inspector consume immutable `GraphSnapshot`
  values, never live engine objects.
- Directory structure is never assumed to equal architecture.

## Discipline

- **Tests must pass.** `make test` returns 0 (CygnusCore `swift test`,
  CygnusKit `swift test`, Xcode unit tests). Never commit a red test.
- **Strict concurrency.** Swift 6 language mode everywhere. No
  `nonisolated(unsafe)`. Cross-actor state is `Sendable` or doesn't
  cross.
- **Builds must be warning-clean.**
- **No SceneKit.** It is soft-deprecated. 3D rendering is RealityKit
  behind the `GraphRendererView` seam (Metal is the escape hatch).
  The 2D Canvas "Flat" renderer is permanent, not a placeholder.
- **Dependencies are pinned and audited.** Current allowed external
  deps: GRDB.swift, swift-syntax, SwiftTreeSitter + pinned grammar
  packages (tree-sitter-python, tree-sitter-c). Anything else needs a
  MISSION.md audit recorded in `PROGRESS.md`.
- **No mocks of real-data interfaces in production code.** Fakes live
  in `Tests/`; `FixtureGraphEngine` is the one sanctioned seam.

## Conventions

- **Commit messages.** Imperative subject, blank line, body explaining
  the *why*. `Co-Authored-By` trailer when an agent landed the change.
- **Branches.** Work on `main`. No long-running feature branches.
- **`git add` specific files.** Never `git add -A` or `git add .`.
- Don't commit `Cygnus.xcodeproj` (generated), `.build/`,
  `DerivedData/`, `*.xcuserdata`, `.DS_Store`.
- Don't add new files at repo root — everything has a home.
- Don't run destructive git ops without explicit user authorisation.

## SwiftUI conventions

- Views are small; a body over ~60 lines wants a child view.
- State lives in `WorkspaceStore` (`@MainActor @Observable`). Views
  observe; views don't own data.
- Security-scoped resource access goes through
  `RepoAccessManager.withRepoAccess { }` — never call
  `startAccessingSecurityScopedResource` bare.

## Token / Cost Ledger

The owner bills from `LEDGER.md` (exact, never estimated). After every
substantive commit: run `~/.claude/billing/ledger.py --append
--summary "<desc>"`, then commit `LEDGER.md` as its own
`chore(ledger): <sha>` commit. Never hand-author, estimate, or rewrite
rows (append-only); if the script can't produce a row, stop and
surface it. Start billable sessions **inside this repo**, not
`~/projects` (ledger.py can't attribute sessions launched from the
workspace root).

Reporting (optional, read-only): `ledger.py --energy-total` estimates
the rough datacenter energy (kWh) behind the whole ledger;
`--energy` adds a per-row estimate to a `--dry-run`/`--append`
breakdown. Order-of-magnitude only — the coefficients are documented
in the script; never write the estimate into a ledger row.

## User context

User: Jeff Kunzelman (`SpaceTrucker2196` on GitHub). river.io LLC.
