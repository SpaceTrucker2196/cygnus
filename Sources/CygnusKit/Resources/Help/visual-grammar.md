# Visual Grammar

Everything in the Flat graph is drawn at once, so each encoding means
exactly one thing. The legend in the bottom-left corner is this key.

- **Node color** — its group or role, following the current Grouping.
- **Node size** — how many connections it has. Hubs are large.
- **Halo arc** — test line-coverage, red through green, filling in
  live while a suite runs.
- **Tinted hull** — a group region, labeled with the group name.
- **Amber edge** — this edge lies on a dependency cycle. Amber always,
  whether or not the Cycles filter is on.
- **Edge thickness** — how many references the edge aggregates.
  Structural edges are thin; a heavily-used dependency is thick.
- **Arrowhead** — dependency direction, drawn on focused and cyclic
  edges.
- **Dimmed** — outside the focused node's blast radius.
- **Blue** — test code: nodes, their connecting lines, and the test
  cloud.

## Reading it

**Cycles** are the first architecture smell worth looking for. They
are computed as strongly-connected components, so what you see is a
real cycle, not a heuristic. The Cycles toggle isolates them by
dimming everything else.

**Blast radius** answers "what does changing this touch". Click a node
and read what stays lit.

**Coverage plus structure together** is the view that is hard to get
anywhere else: a large, central, red-haloed node is a hub that
everything depends on and nothing tests.
