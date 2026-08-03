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
- **Build** — build targets and the files they are declared to need.
  Makefile targets and fastlane lanes, read from the repository's own
  build files.

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
- **Owner** — who owns each file, from git history: an author's name,
  **Shared**, or **Unowned**.
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
- **Migration** — name two modules and see which files have moved.

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

## Tracking a migration

Half-finished migrations are invisible in a dependency graph, because
both halves look healthy on their own. **Migration** makes the front
visible: name the module you are moving away from and the one you are
moving to, and every file that imports either is coloured by where it
stands.

- **Migrated** — uses the new module only.
- **Not migrated** — still on the old one.
- **Straddling** — uses both. This is the remaining work, and it is
  the number that tells you a migration is genuinely in progress
  rather than merely begun.

Files importing neither module are left alone rather than coloured, so
the picture only ever shows what the migration actually touches.

Cygnus does not guess which module replaces which — you name the pair.
Deciding that two modules "serve the same role" is exactly the kind of
guess that produces confident nonsense, and it is knowledge you have
and the graph does not.

When nothing is left on the old module and nothing straddles, the old
one can go. That is the moment the panel is there to tell you about.

## Ownership, and the gaps in it

Cygnus reads your git history during analysis and records who has
committed to each file. **Owner** grouping colours the graph by that.

Three states, and the last two are the point:

- **An author's name** — one person holds most of that file's
  history. Clear ownership.
- **Shared** — several people work on it, none of them dominant.
- **Unowned** — nobody has committed to it in the history that was
  read.

Shared files are worth looking at first. Work that falls between two
owners is where nobody feels responsible, and it is where debt and
unpatched problems collect. A **Shared** region sitting on a boundary
between two owners' territory is the shape to look for; a shared
`Makefile` or a shared core header is the classic example.

Ownership is inferred, and deliberately conservative: a file is only
assigned an owner when one author holds at least 60% of its commits.
Below that, Cygnus says **Shared** rather than picking a winner —
"nobody clearly owns this" is an answer, not a failure to compute one.

Analysis reads the most recent 2,000 commits. Recent history is the
more honest signal anyway: who has touched something lately says more
about who owns it than who wrote it years ago. Merge commits are
excluded, so whoever merges does not appear to own everything.

## The Build view

Your build files are part of the system. A Makefile target that
compiles twenty source files couples those files to the build, and
that coupling is usually invisible until someone tries to change it —
at which point the build turns out to be the thing that has to move
first.

**Build** charts it: each Make target and fastlane lane is a node,
linked to the files it names and to the targets it depends on. Lanes
that call other lanes wire up the same way.

A dependency that names nothing in the repository draws no link.
Unexpanded variables, tools on your `PATH`, and generated files are
all common in build scripts, and inventing a node for them would be
inventing a fact.

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
