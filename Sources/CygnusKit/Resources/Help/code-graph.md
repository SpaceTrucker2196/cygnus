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
- **Option-click a node** — trace to it from the current selection.
  Only the route stays lit, and the readout gives its length. Option-
  click it again to clear.
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
- **Depth** — how many hops a selection lights up: 1, 2, 3, or All.
- **Naming** — ring nodes whose name claims a role their structure
  contradicts.
- **History** — compare two revisions and trend a metric across them.

## Depth, and why it defaults to 1

A whole-graph picture is often the least useful view of a system. Most
real questions are local — what does this touch, what would break if
it changed — and answering them means seeing a bounded neighborhood,
not everything at once.

**Depth** bounds the blast radius. One hop is what directly touches
the selection. Two is the level most migration work actually needs:
your dependencies and theirs. **All** shows the entire reachable set,
which is worth a look and rarely worth keeping on.

## Tracing a route

Focus answers "what touches this". Tracing answers "how does this
reach that" — select one node, option-click another, and only the
route between them stays lit.

The trace shows every *shortest* route, so equal-length alternates
appear together and you can see there is more than one way through.
Longer detours are left out.

"No route" is a real answer, not a failure. Two things you assumed
were connected turning out not to be is usually worth knowing.

## History

Every analysis commits a revision, and nothing is ever overwritten, so
the graph can be asked what it looked like at any past point.

**History** opens two things. **Compare revisions** picks an interval
and marks what it did: a green pip for a node that arrived, orange for
one whose content changed, and counts for what was removed and for
edges either way. The **trend** chart tracks one metric — nodes,
edges, cyclic edges, or unconnected nodes — across the recent
revisions.

The trend is the point. A single reading cannot tell you whether a
cleanup is working; a line across ten revisions can. Cycles and
unconnected nodes are the two worth watching, because both should be
falling if the work is going well.

Trends read the last twenty revisions, and each point is a full
projection of the graph as it stood, so a long history takes a moment
to draw.

## Naming conflicts

**Pattern** grouping reads roles from names; **Role** grouping infers
them from structure. The **Naming** toggle rings the nodes where those
two disagree: a `…Service` that nothing depends on, a `…View` that
everything does.

A conflict is not automatically a bug. It means the name and the
structure are telling different stories, and one of them is out of
date — which is exactly the kind of thing that goes unnoticed for
years.
