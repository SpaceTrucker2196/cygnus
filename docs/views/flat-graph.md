# Flat graph view — the pattern visualizer

The 2D Canvas renderer. A disposable projection of the snapshot,
built to answer architecture questions at a glance: *what depends on
what, what's cyclic, what's tested, what does changing this touch.*
Nothing here feeds back into the graph.

## Visual grammar (all at once)

| Encoding | Means |
|---|---|
| node **color** | its group / role (see Grouping) |
| node **size** | connections (degree) — hubs are large |
| **halo** arc | test line-coverage, red → green, live |
| tinted **hull** | the group region, labeled |
| **amber** edge | on a dependency cycle |
| **arrowhead** | dependency direction (focus / cycle edges) |
| dimmed | outside the focused node's blast radius |

The legend (bottom-left) is this key.

## Content

Top bar **Content** picker (Flat only):

- **Code** — the file/module dependency graph (imports + file→file
  references).
- **Symbols** — the declaration → declaration reference graph
  (`core:refersToSymbol`, compiler-resolved). Needs an index build;
  empty state says so.

## Grouping

How nodes cluster spatially. First four are structural; the map is
computed once and drives color, hulls, and the layout anchors alike.

- **Area** *(default)* — project areas (`Sources/CygnusKit`).
- **Layer** — **Production** / **Tests** / **Modules**.
- **Pattern** — MVVM/MVC roles read from *naming* (Models, Views,
  ViewModels, Controllers, Services, Stores). Convention reading.
- **Role** — architectural role *inferred from structure*, name-free:
  **Core** (depended-upon, depends on little), **Hub** (both),
  **Entry** (depends on much, depended-upon by little), **Leaf**
  (barely connected). Computed from fan-in/fan-out over dependency
  edges. Corroborates or contradicts Pattern.
- **None** — pure force layout; color falls back to Area.

Anchors depend only on sorted cluster names, so groups keep their
directions across re-analyses (software-cartography stability).

## Patterns surfaced

- **Cycles** — iterative Tarjan SCC (stack-safe past 20k nodes) marks
  every edge on a dependency cycle; they draw amber always. The
  **Cycles** toggle (with a count) isolates them by dimming the rest.
- **Focus / blast radius** — click a node: its neighborhood
  (dependencies + dependents) stays lit, everything else dims, and
  incident edges gain direction arrows. Click empty space to clear.

## Coverage

Halos show test line-coverage; on by default (no data → no halo).
Source precedence: **live run** > single **attributed test** (from
the inspector) > loaded artifact (newest `swift test
--enable-code-coverage` / fastlane `scan` export).

**Run Coverage** runs the repo's test classes one at a time and
unions results into growing halos — coverage fills in on the 2D view
in real time, with per-class progress. The union is a monotonic lower
bound (per-class max), so it only ever grows.

## Established practice this follows

- Grouping as a switchable dimension (Sourcetrail); tests/externals
  segregated (pydeps/madge); cycle-finding as the first review lens
  (every DSM tool); focus+context blast radius (mental-map
  literature); stability-first anchors (Kuhn).

## Deliberately deferred

- Cluster collapse → super-node with aggregated edges (LOD past ~5k).
- Edge weight by reference count as thickness (data exists on
  reference edges; not yet threaded to `GraphSnapshot.Edge`).
- Bubble Sets hulls when convex regions overlap badly.
- DSM projection as the scale escape hatch.
