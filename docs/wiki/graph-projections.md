---
title: Graph Projections
summary: Scenes are disposable views of a snapshot — and the charting rules decide which nodes you actually see.
updated: 2026-07-31
---

# Graph Projections

Renderers never see the graph. They see a `GraphSnapshot` — an
immutable value projected out of the store — and from it a
`GraphScene`, the renderable subset. Scenes are computed, disposable,
and never a second model. Change how something looks by changing the
projection, never by writing back.

## Snapshot

A snapshot is one repository's current graph: containment,
declaration, import, and reference edges owned by the repo, plus the
shared module entities they point at. The workspace holds many repos
in one store; a snapshot never mixes them.

## The three scenes

Selected by the **Content** picker in the Flat view.

- **Code** — the file/module dependency graph: imports plus
  compiler-resolved file → file references.
- **Callers** — class → class. Each symbol reference is lifted to the
  types enclosing its endpoints and aggregated, so a class links to
  every class it calls into. Needs [[index-enrichment]].
- **Symbols** — declaration → declaration, raw. Also needs enrichment.

## Charting rules (Code)

This is where nodes disappear, so it is worth stating exactly.

**Modules** are filtered:

- System modules — Apple frameworks, language runtimes — are *never*
  charted. Nobody learns anything from every file pointing at
  Foundation.
- Internal modules, meaning a module name matching a directory in the
  repo, are always charted.
- Everything else is third-party, charted only when **Show External
  Modules** is on.

**Files** always chart, and a source file charts *whether or not it is
wired*. This was the fix for a real failure: nodes used to be derived
from surviving edges alone, so a file whose every import was an Apple
framework had no charted edge and vanished. An Xcode app importing
only SwiftUI and Foundation rendered as two nodes. Absence of a
charted import is not absence of code.

"Source file" is read off the evidence, not off a hardcoded extension
list: a file charts when it **declares something**. That keeps
READMEs, JSON, and asset catalogs out without maintaining a language
table in the renderer.

## Patterns computed on the scene

- **Degree** — connections within the scene. Renderers size nodes by
  it, so hubs are large.
- **Cycles** — iterative Tarjan SCC (explicit work stack; deep graphs
  must not blow the call stack). Every edge on a dependency cycle is
  marked and drawn amber.
- **Grouping** — Area, Folder, Layer, Pattern, Role, or None. Cluster
  anchors depend only on sorted cluster names, so groups keep their
  screen directions across re-analyses. That stability is
  deliberate: a map you can build a memory of is worth more than an
  optimal layout that reshuffles every run.

**Pattern** grouping reads MVVM/MVC roles from naming convention;
**Role** infers structural roles from fan-in/fan-out alone — Core,
Hub, Entry, Leaf — with no name involved. Running both is the point:
where convention and structure disagree, one of them is lying.

See [[renderers]] for how this is drawn, and `docs/views/flat-graph.md`
for the full visual grammar.
