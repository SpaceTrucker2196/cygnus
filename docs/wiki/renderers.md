---
title: Renderers
summary: The 2D Canvas graph and the Metal CI-flow chart — plus the GPU traps already paid for.
updated: 2026-07-31
---

# Renderers

Every visualization is a disposable projection of the graph
([[graph-projections]]), consuming immutable snapshot values and never
live engine objects.

## What is allowed

- **2D Canvas** — the "Flat" renderer. Permanent, not a placeholder.
  It is the pattern visualizer, and most architecture questions are
  answered faster in 2D than in 3D.
- **RealityKit** — the sanctioned 3D path, behind the
  `GraphRendererView` seam.
- **Metal** — the escape hatch, used directly by the CI-flow chart.
- **SceneKit is banned.** It is soft-deprecated upstream; do not
  reintroduce it.

## CI Flow (Metal)

A flowchart of the repo's build pipeline, from two sources feeding one
neutral flow model: fastlane Fastfiles (trigger → lane → actions, with
sub-lane calls wired across) and Makefiles (default goal → target →
recipe commands, with prerequisites as dependency edges). Every path
is a row of entry → group → ordered steps.

Rendering is SDF rounded-rect nodes, arrowed line-quad edges, and
CoreText-rasterized per-node label textures. The `MTKView` is
**paused**: it draws on demand — flow change, resize, pan, zoom,
select, or an animation frame while a build runs — and costs nothing
idle.

Makefile flows are runnable from the Run button; the pipeline runs for
real and nodes light up as their work executes, green on completion,
red on failure. Fastlane lanes are deliberately *not* runnable — a
lane can sign and upload, and that is not something a button press
should do by accident.

## GPU traps already paid for

Both of these were live bugs, not hypotheticals.

- **`setVertexBytes` caps at 4 KB and aborts past it.** Node and edge
  geometry went up that way, and any flow of real size (64 bytes per
  vertex) blew straight through the limit. Upload through an
  `MTLBuffer` with `setVertexBuffer` — no size limit. If you add
  geometry, assume it will grow.
- **Texture V must be inverted for label bitmaps.** A CoreGraphics
  bitmap's first byte row is the *top* of the text, and the view is
  y-down (`isFlipped`), so the top screen corner samples `v=0`, not
  `v=1`. Getting this backwards renders every label upside down —
  which looks like a font problem and is not.

## Subprocess streaming

Live build output arrives through a subprocess whose combined output
streams line-by-line via `AsyncStream`. One thread owns the read
handle for its whole life — that is the anti-crash invariant, learned
the hard way from race-y pipe draining — and the parent closes its
write end so EOF actually arrives when the child exits.

Node states are advanced by a frontier over the flow's steps, aligned
to a node whose label matches the program when it can. Heuristic, but
paced by real output rather than a timer.
