# Flat graph view

The 2D Canvas renderer over the dependency scene. A disposable
projection of the snapshot — nothing here feeds back into the graph.

## Grouping

A segmented control (top bar) picks how nodes cluster spatially:

- **Area** *(default)* — project areas: top-level directory, one level
  deeper under source/test umbrella folders (`Sources/CygnusKit`).
- **Layer** — three bands: **Production**, **Tests**, **Modules**
  (imported targets). Tests are classified by directory
  (`Tests/`, `tests/`, `__tests__`, `UITests`, `spec/`…) or filename
  convention (`FooTests.swift`, `test_foo.py`, `foo_test.c`,
  `foo.spec.ts`).
- **Pattern** — architectural roles read from naming conventions
  (MVVM / MVC): **Models, Views, ViewModels, Controllers, Services,
  Stores**, plus Tests and Modules. This is convention *reading*
  (observable name/path facts), not architecture inference — real
  pattern detection belongs to the engine's derived layer.
- **None** — pure force layout; color still follows Area.

Grouping is projection state: it never touches the graph store.

## Layout

Fruchterman–Reingold with grid-bucketed repulsion (LayoutEngine).
Grouping adds a fixed **anchor per cluster** on a ring; members are
pulled toward their anchor (`clusterPull`), everything else keeps
plain gravity. Anchors depend only on sorted cluster names, so the
same groups always land in the same directions — spatial memory
survives re-analysis, relaunch, and grouping toggles (the software-
cartography stability principle; warm-start covers incremental
growth).

## Regions

Each cluster draws a padded convex-hull blob (screen-space hull,
wide round-join stroke + fill at 10% opacity) with the cluster name
above the topmost point. Background tint + label reads better at low
zoom than outlines alone (Graphviz cluster / CodeSee convention).
Pinned colors: Tests are always gray (desaturated by convention),
imported modules always purple; other clusters take stable sorted
hues.

## Established practice this follows

- Grouping as a user-switchable dimension over the same graph
  (Sourcetrail's namespace/file grouping toggle).
- Tests and externals segregated, not interleaved (pydeps
  `--cluster`, madge's exclude-by-default).
- Deterministic, stability-first positioning (Kuhn's software
  cartography; ELK "interactive" relayout).

## Candidates deliberately deferred

- Collapse-cluster-to-super-node with aggregated edge counts
  (Sourcetrail bundle nodes) — the LOD answer when scenes exceed
  ~5k nodes.
- Non-convex hulls (Bubble Sets) if convex regions overlap badly.
- DSM projection as the scale escape hatch (NDepend / IntelliJ).
