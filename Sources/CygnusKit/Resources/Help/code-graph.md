# Code Graph

Two view modes, chosen top-left.

- **Outline** — the containment tree. Fastest way to find something by
  name.
- **Flat** — the 2D graph. Built to answer architecture questions:
  what depends on what, what is cyclic, what is tested, what does
  changing this touch.

Selection is shared: pick a node in Outline and Flat focuses it.

## Content

What the Flat graph charts.

- **Code** — files and modules joined by imports, plus
  compiler-resolved file-to-file references.
- **Callers** — class to class. Which class uses which, aggregated
  from symbol references. Needs an index build.
- **Symbols** — declaration to declaration, unaggregated. Needs an
  index build.

If Callers or Symbols is empty, the repository has not been built with
an index yet. Build it, then re-analyze — you do not need to change a
source file first.

## Show External Modules

Off by default. System frameworks are never charted, because every
file pointing at Foundation teaches you nothing. Turning this on adds
third-party dependencies. Modules whose name matches a directory in
the repo count as internal and are always charted.

## Grouping

How nodes cluster spatially. Color, hulls, and layout anchors all
follow the grouping.

- **Area** — project areas, from the directory layout.
- **Folder** — the containing folder.
- **Layer** — Production, Tests, Modules.
- **Pattern** — MVVM/MVC roles read from naming: Models, Views,
  ViewModels, Controllers, Services, Stores.
- **Role** — architectural role inferred from structure alone, no
  names involved: **Core** (depended on, depends on little), **Hub**
  (both), **Entry** (depends on much, depended on by little), **Leaf**
  (barely connected).
- **None** — pure force layout.

Running Pattern and Role together is the point: where the naming
convention and the actual structure disagree, one of them is lying.

Groups keep their screen directions across re-analyses, so the map
stays memorable instead of reshuffling every run.

## Interaction

- **Click a node** — focus it. Its dependencies and dependents stay
  lit, everything else dims, and incident edges gain direction arrows.
- **Click empty space** — clear the focus.
- **Double-click** — reset zoom and pan and clear the selection.
- **Drag** — pan.
- **Pinch** — zoom.
- **Click a legend group** — explode it: that group moves to center
  and the rest ring around it.

## Controls

- **Zoom** and **Label size** sliders.
- **Labels** — Auto, On, Off. Auto shows labels as space allows.
- **Legend** — show or hide the visual-grammar key.
- **Coverage** — per-node test-coverage rings.
- **Cycles** — isolate dependency cycles. The count is in the label;
  disabled when there are none.
- **Expand** — orbit each node's functions around it as selectable
  satellites, colored by coverage.
