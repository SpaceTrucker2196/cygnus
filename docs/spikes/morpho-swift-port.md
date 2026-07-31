# morpho → Swift: what to port, and what cygnus would do with it

Brief for the agent doing the Swift port (roadmap item **R1** in
`docs/milestones.md`). Written from a read of
`SpaceTrucker2196/morpho` at 2026-07-31.

The goal is not "port morpho". Most of morpho is an HDL — a compiler,
a parser, primitives, an interactive article — and cygnus needs none
of it. The goal is one thing: **`graphs_engine/src/main.c`, a 608-line
Barnes–Hut N-body layout engine**, which is the deferred work item
sitting in cygnus's roadmap since S4 ("Deferred: Barnes–Hut for
>2k-node scenes").

## Why this specific code is worth porting

cygnus's `LayoutEngine` (`Sources/CygnusKit/LayoutEngine.swift`) uses
Fruchterman–Reingold with grid-bucketed repulsion and a cutoff radius.
That is near-linear and fast, but the cutoff means **long-range
repulsion is discarded entirely** — beyond the radius, two nodes do
not know about each other. The visible consequence is that distinct
clusters do not push each other apart, so the global shape of a large
graph is mush even when local structure is right.

Barnes–Hut keeps long-range forces by approximating distant groups as
single bodies. That is the difference between a layout that is locally
tidy and one whose overall shape means something.

Three properties of morpho's implementation make it unusually
portable:

- **Stackless traversal.** The octree is threaded with a `node_next`
  rope, so the force kernel walks it with a flat `while` loop and no
  recursion. cygnus already requires this (`SnapshotIndex`,
  `stronglyConnectedComponents()` — deep graphs must not recurse), so
  the shapes agree.
- **Struct-of-arrays throughout.** Positions, forces, and node bounds
  are separate flat buffers, not arrays of structs.
- **SIMD that maps directly.** The kernel is `wasm_f32x4_*`
  intrinsics, which translate one-to-one to Swift's `SIMD4<Float>`,
  including the mask-and-select for the distance cutoff
  (`wasm_f32x4_lt` → `SIMDMask` + `replacing(with:where:)`).

## Port scope, in priority order

**P0 — the engine.** Roughly 350 of the 608 lines:

- `buildOctree` — bounds pass, Morton (Z-order) encode via `dilate3`,
  sort, `_buildNode`, `accumulateTree`.
- `calcMultibodyForce` — the Barnes–Hut kernel with `theta`.
- `linkForce` — spring attraction along edges.
- `applyChargeForces`, `updateNodes` — charge term and integration
  with velocity decay.
- `setTheta`, `setMaxSpeed` — tunables.

**P1 — the SoA storage layer.** The `DYNAMIC_BUFFER` macro becomes a
small Swift type over `UnsafeMutableBufferPointer` or
`ContiguousArray`. Do not skip this and back the engine with
dictionaries; the memory layout *is* the performance.

**P2 — `js/hex_layout.js` (`HexLayoutEngine`).** Deterministic grid
placement. Interesting to cygnus for a different reason than speed:
layout stability across re-analyses. cygnus deliberately anchors
clusters by sorted name so groups keep their screen direction between
runs; a grid assignment is a stronger version of the same idea.

**P3 — `setLinearCompensation` / `compensateVelocity`.** Stability
tuning. Port last, when there is something to tune.

**Skip entirely:** the WASM plumbing (`alloc`, the `WASM_EXPORT`
wrappers, `main.wasm`), `js/compiler.js`, `parser.js`, `primitives.js`,
`swissgl.js`, `viewer.js`, `article.js`, `tiny_morpho.py`. None of it
is layout.

## The contract cygnus needs

If the port satisfies this, cygnus can adopt it behind the existing
seam with no renderer changes. Current signature to match:

```swift
LayoutEngine(scene:seed:initial:clusters:focusCluster:)
    .frames(maxIterations:emitEvery:) -> AsyncStream<LayoutFrame>
// LayoutFrame.positions: [String: SIMD2<Double>]
```

Requirements that are not negotiable, because existing tests and
behaviour depend on them:

1. **Deterministic for a given input and seed.** cygnus's layout tests
   assert reproducibility. Morton ties must break consistently —
   morpho already packs the index into the low 32 bits of the sort key,
   which does this, so preserve it rather than "simplifying" the sort.
2. **Warm-startable.** Callers pass previous positions; new nodes join
   an existing layout instead of restarting it. This is what keeps the
   graph from exploding on every re-analysis.
3. **Progressive and cancellable.** Emit frames during solve; stop
   promptly on cancellation. The engine should expose a `step()` so
   the async streaming stays in cygnus, not in the port.
4. **Room for extra force terms.** cygnus adds cluster-anchor and
   focus-cluster forces. Do not hard-code the force list; let a caller
   contribute an additional per-node force before integration.
5. **2D without paying for 3D.** morpho is 3D (`x`/`y`/`z` buffers).
   cygnus's Flat view is 2D, and 3D was *removed* in S5 for cost. Make
   dimensionality a compile-time choice (a 2D and 3D specialization),
   not a runtime `if`, and never allocate the z buffer in 2D.
6. **`Float` internally, converted at the boundary.** cygnus stores
   `SIMD2<Double>`. Do not widen the engine to `Double` — the SIMD
   lane count and cache behaviour are the entire reason to do this.

## Package shape

Build it as a **standalone, dependency-free Swift package** with one
target and no platform assumptions. Two reasons: it is reusable beyond
cygnus, and it keeps the adoption decision open. Under cygnus's rules
(`AGENTS.md`) a new external dependency requires a MISSION.md audit
recorded in `PROGRESS.md`; a dependency-free single target can also
simply be vendored if that audit says no. Do not make that choice
harder by pulling in a package manager graph.

## Licensing — do this first, not last

Upstream is **Apache 2.0, © Google LLC**, with an explicit "not an
officially supported Google product" disclaimer. A Swift port is a
derivative work, so:

- Keep the Apache 2.0 licence text in the port.
- Preserve the upstream copyright notice on ported files.
- State prominently that the files are modified — Apache 2.0 §4(b)
  requires carrying "prominent notices stating that You changed the
  Files". A header naming the original file (`graphs_engine/src/main.c`)
  and describing the change ("ported from C to Swift") satisfies this.
- Add a `NOTICE` file.

## Acceptance

Do not accept "it looks about right on screen".

**Parity against the C.** Build the reference natively — `build.sh`
targets wasm via zig, but `clang -O2 src/main.c` compiles for the host
with the SIMD path off. For a seeded pseudo-random point cloud, feed
identical positions and edges to both, run one step, and compare force
vectors. They should agree to within float epsilon accumulated over
the traversal; a divergence larger than that means the octree or the
`node_next` rope was mis-ported, which is exactly the bug that is
invisible on screen.

**Benchmarks, recorded as numbers.** Frame time and total settle time
at 2k, 10k, 25k, and 65k nodes, against cygnus's current
`LayoutEngine` at the same sizes. 65k is morpho's stated ceiling —
find out what happens above it rather than assuming.

**Quality, not just speed.** Barnes–Hut is worth adopting only if the
layout is *better*, so measure something: total edge length, edge
crossings on a fixed graph, or cluster separation. Speed alone would
be satisfied by doing less work.

**Determinism.** Same input plus same seed produces bit-identical
positions across runs and across machines with the same toolchain.

## What cygnus does with it afterwards

Sequenced so each step is independently useful:

1. Swap it in behind `LayoutEngine` for the Flat view and compare on a
   real repo — cygnus itself, then a large one.
2. If the shape is better, revisit the **S5** 3D removal. 3D was cut
   because both paths cost too much memory and time; a layout engine
   that solves 3D at this scale changes one half of that argument, but
   not the rendering half. Do not treat this as permission to bring
   back RealityKit.
3. Consider the P2 hex layout for stable positions across revisions —
   which pairs directly with the revision-delta view, where a node
   jumping across the screen between two revisions is noise that hides
   the actual change.

## The idea worth stealing that is not code

morpho grows circuits by **recursive rewriting**: a cell is replaced by
subcells, and bus widths are inferred rather than declared, so a
structure has no fixed size until it is grown.

cygnus has the same shape and throws it away — containment runs repo →
directory → file → declaration, and the Flat view flattens it into one
undifferentiated node set. A graph that is *grown to a level of detail*
rather than projected whole is a direct answer to the objection in
`docs/wiki/visualization-ideas.md` that whole-graph rendering is "a lot
of work without a lot of payoff".

That is a cygnus design change rather than a port task, so it is out of
scope here — but it is the reason to read morpho's `grower.js` while
porting, and to write down what you learn.
