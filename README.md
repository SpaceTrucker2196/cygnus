# cygnus

**See your codebase as a knowledge graph.**

Cygnus is a native macOS app that models a software system — *not its
files* — as a knowledge graph built from repository evidence, and
renders it as a 2D pattern visualizer. Cycles, coverage, callers, and
architectural roles, all in one view.

[![site](https://img.shields.io/badge/site-cygnus-00e5ff)](https://spacetrucker2196.github.io/cygnus/)
![platform](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)
[![license](https://img.shields.io/badge/license-MIT-7c4dff)](LICENSE)

→ **[spacetrucker2196.github.io/cygnus](https://spacetrucker2196.github.io/cygnus/)**

---

## Evidence, not guesses

Repositories are raw evidence. Cygnus emits atomic, *literal*
observations — "file A imports module B", "this declaration references
that one" — into an **append-only knowledge graph** with full
provenance. Derived facts die with the observations that support them.
Every visualization is a disposable projection of that graph, never a
second model.

## The 2D pattern visualizer

A dense, evidence-backed picture that reads at a glance — the first
architecture smells jump out, and one click drills to the blast radius.

| Channel | Encodes |
|---|---|
| node **color / size** | group or inferred role · size = connections (hubs are big) |
| **amber edges** | dependency **cycles** (Tarjan SCC — the first smell to find) |
| **coverage rings** | per-function test coverage, red → green, filled live as tests run |
| **test links** | test → code, colored by that test's pass / partial / fail verdict |
| **focus & flow** | click a node → zoom its blast radius; direction arrows, the rest dims |

- **Grouping, five ways** — Area · Folder · Layer · Pattern (MVVM/MVC
  by name) · Role (Core / Hub / Entry / Leaf, *inferred from the
  dependency flow*).
- **Callers & symbols** — file dependencies, the class-to-class caller
  graph, or the raw declaration reference graph, weighted by reference
  count.
- **Expand** — orbit a node's functions as coverage-colored satellites;
  read them in a side panel with jump-to-source and syntax highlighting.
- **Live coverage** — run the suite from the graph and watch halos grow
  green, class by class.

## Languages

Source-level extraction — no build required, error-tolerant on
checkouts that don't even compile:

**Swift** (swift-syntax) · **Python** · **C** · **Rust** (tree-sitter).

Optional reference/caller enrichment resolves real edges from the
compiler's index store (IndexStoreDB) — the architecture as the
compiler sees it.

## Also: a dark-factory ops dashboard

Every repository doubles as an operations console — production orders
(GitHub issues), CI status, token-cost ledger, converge throughput —
driven by your own `git` and `gh`, with a fastlane screenshot strip
and a live GitHub Pages preview per repo.

## Architecture

- **`CygnusCore/`** — the engine (SPM). `CygnusGraph` (pure model),
  `CygnusStore` (the only target that imports GRDB), extractors,
  `CygnusDerive`, `CygnusEngine` facade, and the `cygnus` CLI.
- **`Sources/CygnusKit/`** — app-side headless adapter: `WorkspaceStore`,
  graph projections, layout engine, coverage. Hermetic tests, no Xcode.
- **`App/`** — SwiftUI macOS app. Imports `CygnusKit` only; generated
  into `Cygnus.xcodeproj` from `project.yml` via `xcodegen`.

Swift 6 strict concurrency throughout, a hard 5 GB memory ceiling so a
pathological repo can't take the machine down, and a Metal-free 2D
renderer that stays fluid at real-repo scale.

## Build & run

```sh
make test     # engine + kit + app tests
make build    # the macOS app (needs xcodegen + Xcode 26.6+)
```

Or drive the engine headless — the fastest way to exercise the pipeline:

```sh
cd CygnusCore
swift run cygnus register ~/path/to/repo
swift run cygnus index
```

## Where to read next

`MISSION.md` (charter) · `docs/architecture.md` (plan of record) ·
`FACTORY.md` (build runbook) · `docs/views/flat-graph.md` (the
visualizer spec) · `docs/milestones.md` (roadmap).

## License

MIT © [river.io LLC](https://river.io). See [LICENSE](LICENSE).
