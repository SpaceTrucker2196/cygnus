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
every other view, and the second parser disappears. That needs recipe
ordering in the graph, which is not there yet. Until then, one parser
serves the graph and one serves the chart, and this note is the
record of why.

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
