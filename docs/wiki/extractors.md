---
title: Extractors
summary: Which languages are actually supported, what an extractor may emit, and the naming trap in the target layout.
updated: 2026-07-31
---

# Extractors

An extractor reads one file and emits **observations** — literal facts
in the file's own terms. It never touches the store, never reads other
files, and never interprets. "File A imports module B" is in scope;
"A is the auth service" is not. See [[knowledge-graph]] for why that
line is load-bearing.

## What is actually supported

- **Swift** — `CygnusExtractorSwift`, built on swift-syntax. The
  richest extractor: real parsing, not pattern matching.
- **Python** — tree-sitter-python.
- **C** — tree-sitter-c (`.c` and `.h`).
- **Rust** — tree-sitter-rust.

Each extractor claims a file by language hint or extension, so a file
with no hint still routes correctly by suffix.

## The `CygnusExtractorTS` naming trap

Read the target name as historical. `CygnusExtractorTS` today holds
`TreeSitterExtractor` (the shared tree-sitter harness) plus the
Python, C, and Rust extractors. **There is no TypeScript grammar in
the dependency list and no TypeScript extractor** — the "TS" is
tree-sitter, not TypeScript.

Two consequences that have bitten:

- A `.ts` / `.tsx` / `.js` file gets no language hint from the
  provider and no extractor claims it. It appears in the graph as a
  file — its existence is a fact — with nothing declared inside it.
- Searching for "the TS extractor" finds a target that does not do
  what its name says. Adding real TypeScript support means a new
  pinned grammar dependency, and dependencies here need a MISSION.md
  audit recorded in `PROGRESS.md`.

## Build files

`CygnusExtractorBuild` reads Makefiles (`Makefile`, `GNUmakefile`,
`*.mk`) and fastlane Fastfiles, emitting one `core:buildRule`
observation per target and per declared dependency. Resolution turns
those into `core:buildTarget` entities and `core:builds` edges to the
files or sibling targets they name. See [[graph-projections]] for the
Build scene, and the overgrowth argument in [[visualization-ideas]]
for why the build belongs in the graph at all.

Two deliberate limits:

- A dependency that names nothing in the repository — an unexpanded
  variable, a tool on `PATH`, a generated file — produces **no edge**.
  The observation is still recorded, so the evidence is not lost, but
  the graph does not invent a target for it.
- Only *simple* variable assignments are expanded, one level deep. A
  recursively-defined variable stays verbatim rather than becoming a
  wrong answer.

Targets also carry their **recipe** — the commands they run, in
order, as a `core:buildSteps` property rather than one entity per
command. A step has no identity of its own, and minting thousands of
them would bloat the graph to say what an ordered list already says.
Order is the fact: a recipe is a sequence, and a set of commands would
not tell you what the target does.

### The duplicated parser, on purpose

`CygnusExtractorBuild.MakefileRules` and the app-side
`MakeFlowBuilder` (`Sources/CygnusKit/MakeFlow.swift`) both parse Make
rules, and that duplication is intentional for now.

They want different things. The extractor wants targets and
prerequisites — the coupling. The flow builder additionally wants
recipe command words and their order, because it draws a flowchart,
and its `CIFlow` model carries `column`/`row`: it is a rendering type
and does not belong in the engine.

The end state is better than either: once build facts are in the
graph, the CI Flow chart should be a **projection of the graph** like
every other view, and the second parser disappears.

**The blocker is gone as of 2026-08-03.** Recipes and their order are
in the graph, `CIFlow.from(snapshot:)` builds the chart from it, and
`CIFlowProjectionTests` diffs the two constructions against real
Makefiles. cygnus and otter project identically. Nothing is wired up
yet — the swap is one line, and it is blocked on a decision rather
than on work.

### The decision the swap needs

sloth's Makefile builds `$(TARGET)`, and the two sides disagree about
what to call it:

- The **graph** expands the variable and names the target `sloth`,
  because an entity needs an identity a later revision can match, and
  `$(TARGET)` is not one — it is a different string every time the
  variable changes.
- The **chart** keeps `$(TARGET)` verbatim, decided in 9342eea so that
  variable and pattern targets stay visible and the picture stays
  connected. It also draws `%.o`, which the graph deliberately has no
  entity for: a pattern rule describes a shape, not a thing.

Both are right for their own purpose and they cannot both be shown.
Swapping the chart onto the graph therefore *changes what a user
sees* — `sloth` instead of `$(TARGET)`, and no `%.o` row. Arguably an
improvement, since it names what actually gets built, but it is a
change to make on purpose rather than discover afterwards.

Three ways out, in increasing cost: accept the new labels; record the
verbatim name alongside the expanded one so the chart can choose; or
leave the chart parsing files forever and accept the duplication. The
test pins the current disagreement, so whichever is chosen, the
choice is visible.

## Adding a language

For a tree-sitter language: a pinned grammar dependency, a query, and
a normalization step that maps captures into cygnus vocabulary. The
grammar packages are pinned to exact versions deliberately — a
grammar bump silently changes node names and quietly changes what the
graph says.

Also update the provider's language-hint table, or the extractor will
only ever be reached by extension fallback.

## Where extraction stops

Extractors give you declarations and imports — the syntax baseline.
They cannot tell you that a call in one file lands on a definition in
another; that requires the compiler. See [[index-enrichment]].
